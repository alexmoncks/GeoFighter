; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Alex Moncks
; ============================================================================
; fighter.asm - a fighter: animation, moves, hits, the machine's play
;
; A fighter is a block of FT_SIZE bytes (ft0 on the left, looking right;
; ft1 on the right). What it shows is one pose number (FT_POSE): the
; animation table (out/inc/tables.asm) says which poses an animation plays
; and for how many ticks each. A tick is a shown frame (30 a second).
; What it does comes from what is held (FT_INTENT, CI_* bits) and from what
; was pressed in this tick (FT_PRESS, KP_* bits), both written by the
; player's keys or by ai_think.
;
; The moves (move_tab, from tools/gen_fighter.py) have a height:
;   high   the punch: goes over a crouch; the standing guard stops it
;   mid    the kick: either guard stops it
;   low    the low punch, the sweep: miss a fighter in the air; only the
;          crouching guard stops them
;   over   the flying kick, the punch from above: only the standing guard
; A sidestep takes its fighter out of the line of any of them, and turns
; the fight's axis (gm_axis): the ring turns under the two fighters.
; ============================================================================

FT_X:       equ 0               ; word: position in the ring
FT_HP:      equ 2
FT_STATE:   equ 3               ; ST_*
FT_ANIM:    equ 4               ; AN_*
FT_STEP:    equ 5
FT_TICK:    equ 6
FT_POSE:    equ 7
FT_INTENT:  equ 8               ; CI_* bits: what is held
FT_FACING:  equ 9               ; 0 looks right, 1 looks left (also the slot)
FT_CHAR:    equ 10
FT_AIT:     equ 11              ; the machine: ticks until it thinks again
FT_AICMD:   equ 12              ; ... and the intent it holds meanwhile
FT_MOVE:    equ 13              ; the attack in progress (MV_*); in a jump, the one to come
FT_CPU:     equ 14              ; 1: the machine plays it
FT_PRESS:   equ 15              ; KP_* bits: what was pressed in this tick
FT_SIZE:    equ 16

ST_FREE:    equ 0               ; stands, walks, crouches or guards as the intent says
ST_ATTACK:  equ 1
ST_STUN:    equ 2               ; took a hit or blocked one: until the animation ends
ST_KO:      equ 3
ST_WIN:     equ 4
ST_AUTO:    equ 5               ; the round moves it (the opening shot)
ST_JUMP:    equ 6
ST_STEP:    equ 7               ; a sidestep

CI_FWD:     equ 0
CI_BACK:    equ 1
CI_GUARD:   equ 2
CI_CROUCH:  equ 3
CM_FWD:     equ 1               ; the same as masks
CM_BACK:    equ 2
CM_GUARD:   equ 4
CM_CROUCH:  equ 8

KP_PUNCH:   equ 0
KP_KICK:    equ 1
KP_JUMP:    equ 2
KP_STEPU:   equ 3               ; a sidestep up the screen
KP_STEPD:   equ 4               ; ... and down
KM_PUNCH:   equ 1               ; the same as masks
KM_KICK:    equ 2
KM_JUMP:    equ 4
KM_STEPU:   equ 8
KM_STEPD:   equ 16

NO_MOVE:    equ 0xFF            ; FT_MOVE in a jump with no attack chosen
SPEED_F:    equ 4               ; units a tick, forwards
SPEED_B:    equ 3
PUSH_HIT:   equ 18              ; how far a hit pushes back
PUSH_BLOCK: equ 7
TAP_WIN:    equ 9               ; ticks a second tap has to come in
GUARD_NEAR: equ 130             ; walking back guards an attack from this near

; ---------------------------------------------------------------- animation
; IX -> fighter -> HL -> its animation's entry (first pose, steps, ticks, mode)
anim_ptr:
        ld a, (ix + FT_ANIM)
        add a, a
        add a, a
        ld l, a
        ld h, 0
        ld de, anim_tab
        add hl, de
        ret

; A = animation: start it, unless it is the one running
anim_set:
        cp (ix + FT_ANIM)
        ret z
; A = animation: start it from its first pose
anim_force:
        ld (ix + FT_ANIM), a
        xor a
        ld (ix + FT_STEP), a
        ld (ix + FT_TICK), a
anim_pose:
        call anim_ptr
        ld a, (hl)
        add a, (ix + FT_STEP)
        ld (ix + FT_POSE), a
        ret

; A = animation: at its last pose
anim_last:
        ld (ix + FT_ANIM), a
        call anim_ptr
        inc hl
        ld a, (hl)
        dec a
        ld (ix + FT_STEP), a
        ld (ix + FT_TICK), 0
        jr anim_pose

; one tick -> A = 1 when a play-once animation has just ended, else 0
anim_tick:
        call anim_ptr
        inc hl
        ld b, (hl)                  ; steps
        inc hl
        ld c, (hl)                  ; ticks per step
        inc hl
        ld d, (hl)                  ; mode
        ld a, (ix + FT_TICK)
        inc a
        cp c
        jr c, at_keep
        ld (ix + FT_TICK), 0
        ld a, (ix + FT_STEP)
        inc a
        cp b
        jr c, at_step
        ld a, d                     ; past the last step
        or a
        jr z, at_loop
        dec a
        jr z, at_once
        dec a
        jr z, at_hold
        ld a, b                     ; 3: loop the last 4 steps
        sub 4
        jr at_step
at_loop:
        xor a
        jr at_step
at_hold:
        ld a, b
        dec a
        jr at_step
at_once:
        ld a, b
        dec a
        ld (ix + FT_STEP), a
        call anim_pose
        ld a, 1
        ret
at_step:
        ld (ix + FT_STEP), a
        call anim_pose
        xor a
        ret
at_keep:
        ld (ix + FT_TICK), a
        xor a
        ret

; A = animation, B = its step -> carry: that is in the air (the jump and
; the two attacks from it are AN_JUMP, AN_JUMP + 1, AN_JUMP + 2)
air_q:  cp AN_JUMP
        ccf
        ret nc
        cp AN_JPUNCH + 1
        ret nc
        ld a, b
        cp JUMP_AIR0
        ccf
        ret nc
        cp JUMP_AIR1 + 1
        ret

; -> A = how far apart the two are (255: that or more)
dist:   ld hl, (ft1 + FT_X)
        ld de, (ft0 + FT_X)
        or a
        sbc hl, de
        ld a, h
        or a
        ld a, l
        ret z
        ld a, 255
        ret

; ---------------------------------------------------------------- one tick
; IX -> the fighter, IY -> the other one
ft_update:
        ld a, (ix + FT_STATE)
        or a
        jp z, fu_free
        cp ST_AUTO
        jp z, anim_tick
        cp ST_JUMP
        call z, fu_jump
        call air_drift
        call anim_tick
        ld b, a
        ld a, (ix + FT_STATE)
        cp ST_ATTACK
        jr nz, fu_2
        push bc
        call ft_hitcheck
        pop bc
        jr fu_1
fu_2:   cp ST_STEP
        jr nz, fu_1
        ld a, b
        or a
        jp z, step_turn
fu_1:   ld a, b
        or a
        ret z
        ld a, (ix + FT_STATE)       ; the animation ended
        cp ST_KO
        ret z
        cp ST_WIN
        ret z
        ld (ix + FT_STATE), ST_FREE
        ; back to where it came from: the crouch, the guard or the stance
        ld a, (ix + FT_ANIM)
        ld c, AN_CROUCH
        cp AN_CBLOCK
        jr z, fu_3
        cp AN_LOWP
        jr z, fu_3
        cp AN_SWEEP
        jr z, fu_3
        ld c, AN_GUARD
        cp AN_BLOCKHIT
        jr z, fu_3
        ld a, AN_IDLE
        jp anim_force
fu_3:   ld a, c
        jp anim_last

; the keys during a jump
fu_jump:
        ld c, (ix + FT_PRESS)
        ld a, (ix + FT_STEP)
        cp JUMP_AIR0 + 1
        jr nc, fj_1
        bit KP_STEPU, c
        jr z, fj_1
        xor a                       ; up again, this early: it was a double tap
        jp ft_step
fj_1:   ld a, (ix + FT_MOVE)
        inc a
        jr nz, fj_3                 ; an attack is already chosen
        ld a, (ix + FT_STEP)
        cp JUMP_AIR1 - 1
        ret nc                      ; too late for one
        ld a, MV_JPUNCH
        bit KP_PUNCH, c
        jr nz, fj_2
        ld a, MV_JKICK
        bit KP_KICK, c
        ret z
fj_2:   ld (ix + FT_MOVE), a
fj_3:   ; once in the air the jump becomes the attack, at the same step
        ld a, (ix + FT_STEP)
        cp JUMP_AIR0
        ret c
        ld a, (ix + FT_MOVE)
        call move_ptr
        ld a, (hl)
        ld (ix + FT_ANIM), a
        ld (ix + FT_STATE), ST_ATTACK
        call anim_pose
        ld a, SFX_SWING
        jp sfx_play

; in the air the fighter still goes forwards or backwards
air_drift:
        ld a, (ix + FT_ANIM)
        ld b, (ix + FT_STEP)
        call air_q
        ret nc
        ld c, (ix + FT_INTENT)
        ld de, SPEED_F
        bit CI_FWD, c
        jp nz, ft_move
        ld de, -SPEED_B
        bit CI_BACK, c
        jp nz, ft_move
        ret

; A = 0: a sidestep up the screen, 1: down. Up is at the left of the
; fighter that looks right, and at the right of the other one.
ft_step:
        xor (ix + FT_FACING)
        ld a, AN_STEP_L
        jr z, fs_1
        ld a, AN_STEP_R
fs_1:   ld (ix + FT_STATE), ST_STEP
        call anim_force
        ld a, SFX_SWING
        jp sfx_play

; the ring turns under a sidestep: one notch a tick while the fighter is
; out of the line (every step of the animation but the first: STEP_TURN
; notches in all)
step_turn:
        ld a, (ix + FT_STEP)
        or a
        ret z
        ld a, (ix + FT_ANIM)
        cp AN_STEP_L
        ld a, (gm_axis)
        jr z, stt_1
        inc a
        inc a
stt_1:  dec a
        and AXIS_N - 1
        ld (gm_axis), a
        ret

fu_free:
        ld c, (ix + FT_INTENT)
        ld b, (ix + FT_PRESS)
        bit KP_STEPU, b
        jr z, ff_0
        xor a
        jr ft_step
ff_0:   bit KP_STEPD, b
        jr z, ff_j
        ld a, 1
        jr ft_step
ff_j:   bit KP_JUMP, b
        jr z, ff_c
        ; a jump; with the punch or the kick, the attack from the air
        ld a, NO_MOVE
        bit KP_PUNCH, b
        jr z, ff_j1
        ld a, MV_JPUNCH
ff_j1:  bit KP_KICK, b
        jr z, ff_j2
        ld a, MV_JKICK
ff_j2:  ld (ix + FT_MOVE), a
        ld (ix + FT_STATE), ST_JUMP
        ld a, AN_JUMP
        jp anim_force
ff_c:   bit CI_CROUCH, c
        jr z, ff_g
        ; crouching: the guard, and the low moves
        ld a, MV_LOWP
        bit KP_PUNCH, b
        jr nz, ft_attack
        ld a, MV_SWEEP
        bit KP_KICK, b
        jr nz, ft_attack
        ld a, AN_CROUCH
        jr ff_hold
ff_g:   bit CI_GUARD, c
        jr z, ff_1
ff_gd:  ld a, AN_GUARD
ff_hold:
        call anim_set
        jp anim_tick
ff_1:   ld a, MV_PUNCH
        bit KP_PUNCH, b
        jr nz, ft_attack
        ld a, MV_KICK
        bit KP_KICK, b
        jr nz, ft_attack
        bit CI_FWD, c
        jr z, ff_4
        ld a, AN_WALK_F
        call anim_set
        ld de, SPEED_F
        call ft_move
        jp anim_tick
ff_4:   bit CI_BACK, c
        jr z, ff_5
        ; walking away from an attack is a guard
        ld a, (iy + FT_STATE)
        cp ST_ATTACK
        jr nz, ff_4b
        call dist
        cp GUARD_NEAR
        jr c, ff_gd
ff_4b:  ld a, AN_WALK_B
        call anim_set
        ld de, -SPEED_B
        call ft_move
        jp anim_tick
ff_5:   ld a, AN_IDLE
        call anim_set
        jp anim_tick

; A = the move (MV_*): start it
ft_attack:
        ld (ix + FT_MOVE), a
        call move_ptr
        ld a, (hl)
        ld (ix + FT_STATE), ST_ATTACK
        call anim_force
        ld a, SFX_SWING
        jp sfx_play

; A = move -> HL -> its entry: animation, hit step, reach, damage, height
move_ptr:
        ld l, a
        add a, a
        add a, a
        add a, l
        ld l, a
        ld h, 0
        ld de, move_tab
        add hl, de
        ret

; DE = how far to go forwards (negative: backwards). The fighters stay in
; the ring and at least MIN_SEP apart.
ft_move:
        ld a, (ix + FT_FACING)
        or a
        call nz, neg_de             ; looking left: forwards is -x
        ld l, (ix + FT_X)
        ld h, (ix + FT_X + 1)
        add hl, de
        ld de, WALK_X
        call clamp_s
        ld (ix + FT_X), l
        ld (ix + FT_X + 1), h
        ; fall through
; keep ft1 at least MIN_SEP to the right of ft0: the one that moved gives way
sep_fix:
        ld hl, (ft1 + FT_X)
        ld de, (ft0 + FT_X)
        or a
        sbc hl, de
        ld de, MIN_SEP
        call lt_s
        ret nc
        ld a, (ix + FT_FACING)
        or a
        jr nz, sf_1
        ld hl, (ft1 + FT_X)
        ld de, -MIN_SEP
        add hl, de
        ld (ft0 + FT_X), hl
        ret
sf_1:   ld hl, (ft0 + FT_X)
        ld de, MIN_SEP
        add hl, de
        ld (ft1 + FT_X), hl
        ret

; the attack lands on the first tick of its hit step, when the other one is
; within reach and in its way: the guard that goes with the move's height
; stops it, otherwise it takes life away
ft_hitcheck:
        ld a, (ix + FT_TICK)
        or a
        ret nz
        ld a, (ix + FT_MOVE)
        call move_ptr
        inc hl
        ld a, (ix + FT_STEP)
        cp (hl)
        ret nz
        inc hl
        ld c, (hl)                  ; reach
        inc hl
        ld b, (hl)                  ; damage
        inc hl
        push hl
        call dist                   ; (MIN_SEP or more)
        pop hl
        ld e, a
        ld a, c
        cp e
        ret c                       ; out of reach
        ld d, b                     ; D = damage
        ld e, (hl)                  ; E = height
        ld a, (iy + FT_STATE)
        cp ST_KO
        ret z
        cp ST_AUTO
        ret z
        cp ST_WIN
        ret z
        cp ST_STEP
        jr nz, fh_0
        ld a, (iy + FT_STEP)        ; a sidestep: out of the line in its middle steps
        dec a
        cp 3
        ret c
fh_0:   ld c, (iy + FT_ANIM)
        ld b, 0
        ld hl, anim_fl
        add hl, bc
        ld b, (hl)                  ; B = 1 crouching, 2 standing guard, 4 crouching guard
        ld a, e
        or a
        jr nz, fh_m
        bit 0, b                    ; high: over a crouch
        ret nz
        bit 1, b
        jr nz, fh_block
        jr fh_hit
fh_m:   dec a
        jr nz, fh_l
        ld a, b                     ; mid: either guard
        and 6
        jr nz, fh_block
        jr fh_hit
fh_l:   dec a
        jr nz, fh_o
        push bc                     ; low: under a jump
        ld a, (iy + FT_ANIM)
        ld b, (iy + FT_STEP)
        call air_q
        pop bc
        ret c
        bit 2, b
        jr nz, fh_block
        jr fh_hit
fh_o:   bit 1, b                    ; from above: the standing guard only
        jr nz, fh_block
fh_hit: ld a, 2
        ld (hud_dirty), a
        ld a, (iy + FT_HP)
        sub d
        jr nc, fh_2
        xor a
fh_2:   ld (iy + FT_HP), a
        or a
        jr z, fh_ko
        ld a, SFX_HIT
        call sfx_play
        ld b, ST_STUN
        ld c, AN_HIT
        ld de, -PUSH_HIT
        jr fh_react
fh_ko:  ld a, SFX_KO
        call sfx_play
        ld b, ST_KO
        ld c, AN_KO
        ld de, -PUSH_HIT
        jr fh_react
fh_block:
        ld c, AN_BLOCKHIT
        bit 0, b
        jr z, fh_b1
        ld c, AN_CBLOCK
fh_b1:  ld a, SFX_BLOCK
        call sfx_play
        ld b, ST_STUN
        ld de, -PUSH_BLOCK
fh_react:
        ; the other one: state B, animation C, pushed back by DE
        push ix
        push iy
        pop ix
        ld (ix + FT_STATE), b
        push de
        ld a, c
        call anim_force
        pop de
        call ft_move
        pop ix
        ret

; ---------------------------------------------------------------- the machine
; IX -> the fighter, IY -> the other one: writes FT_INTENT and FT_PRESS
ai_think:
        ld a, (ix + FT_AIT)
        or a
        jr z, ai_new
        dec (ix + FT_AIT)
        ld a, (ix + FT_AICMD)
        ld (ix + FT_INTENT), a
        ld (ix + FT_PRESS), 0
        ret
ai_new: call dist
        ld c, a                     ; C = the distance (255: far)
        ; the other one is attacking within reach: the guard that stops its
        ; move, most of the times, or a sidestep out of its way
        ld a, (iy + FT_STATE)
        cp ST_ATTACK
        jr nz, ai_2
        ld a, c
        cp 120
        jr nc, ai_2
        call rand
        cp 28
        jp c, ai_side
        cp 170
        jr nc, ai_2
        ld a, (iy + FT_MOVE)
        call move_ptr
        ld de, 4
        add hl, de
        ld a, (hl)
        cp LV_LOW
        ld a, CM_GUARD
        jr nz, ai_1
        ld a, CM_CROUCH
ai_1:   ld b, 9
        jp ai_hold
ai_2:   ld a, c
        cp 92
        jr c, ai_near
        ; far: walk in, with a pause now and then; from the right distance
        ; the flying kick, sometimes
        cp 136
        jr nc, ai_walk
        call rand
        cp 26
        jr nc, ai_walk
        ld a, CM_FWD
        ld e, a
        ld c, KM_JUMP + KM_KICK
        ld b, 16
        jp ai_set
ai_walk:
        call rand
        cp 36
        jr c, ai_wait
        cp 40
        jr c, ai_side
        and 3
        add a, 2
        ld b, a
        ld a, CM_FWD
        jr ai_hold
ai_near:
        call rand
        cp 66
        jr c, ai_punch
        cp 120
        jr c, ai_kick
        cp 146
        jr c, ai_lowp
        cp 178
        jr c, ai_sweep
        cp 204
        jr c, ai_back
        cp 224
        jr c, ai_guard
        cp 238
        jr c, ai_duck
        cp 246
        jr c, ai_side
ai_wait:
        xor a
        ld b, 7
        jr ai_hold
ai_punch:
        xor a
        ld c, KM_PUNCH
        jr ai_once
ai_kick:
        xor a
        ld c, KM_KICK
        jr ai_once
ai_lowp:
        ld a, CM_CROUCH
        ld c, KM_PUNCH
        jr ai_once
ai_sweep:
        ld a, CM_CROUCH
        ld c, KM_KICK
        jr ai_once
ai_back:
        ld a, CM_BACK
        ld b, 8
        jr ai_hold
ai_guard:
        ld a, CM_GUARD
        ld b, 12
        jr ai_hold
ai_duck:
        ld a, CM_CROUCH
        ld b, 12
        jr ai_hold
; a sidestep: up or down as bit 0 of A (a random number) says
ai_side:
        rrca
        ld c, KM_STEPU
        jr nc, ai_s1
        ld c, KM_STEPD
ai_s1:  xor a
        ld e, a
        ld b, 10
        jr ai_set
; A = intent and C = presses of this tick only, then a pause
ai_once:
        ld d, a
        call rand
        and 15
        add a, 9
        ld b, a
        ld a, d
        ld e, 0
        jr ai_set
; A = intent, held for B more ticks
ai_hold:
        ld e, a
        ld c, 0
; A = intent and C = presses of this tick, E = intent of the next B ticks
ai_set: ld (ix + FT_INTENT), a
        ld (ix + FT_AICMD), e
        ld (ix + FT_PRESS), c
        ld (ix + FT_AIT), b
        ret

; ---------------------------------------------------------------- the player
; the keys -> ft0's intent and presses. Punch, kick and jump need a new
; press. A second press of up within TAP_WIN ticks is a sidestep up (the
; jump the first one started is taken back, fu_jump); the same with down.
human_intent:
        ld a, (in_cur)
        ld c, a
        ld a, (in_prev)
        cpl
        and c
        ld d, a                     ; D = keys pressed since the last tick
        ld a, c
        ld (in_prev), a
        ld hl, tap_u
        call hu_dec
        inc hl                      ; tap_d
        call hu_dec
        ld b, 0                     ; held
        ld e, 0                     ; pressed
        bit IN_RIGHT, c
        jr z, hu_1
        set CI_FWD, b
hu_1:   bit IN_LEFT, c
        jr z, hu_2
        set CI_BACK, b
hu_2:   bit IN_G, c
        jr z, hu_3
        set CI_GUARD, b
hu_3:   bit IN_DOWN, c
        jr z, hu_4
        set CI_CROUCH, b
hu_4:   bit IN_A, d
        jr z, hu_5
        set KP_PUNCH, e
hu_5:   bit IN_B, d
        jr z, hu_6
        set KP_KICK, e
hu_6:   bit IN_UP, d
        jr z, hu_8
        ld hl, tap_u
        ld a, (hl)
        or a
        jr z, hu_7
        ld (hl), 0
        set KP_STEPU, e
        jr hu_8
hu_7:   ld (hl), TAP_WIN
        set KP_JUMP, e
hu_8:   bit IN_DOWN, d
        jr z, hu_10
        ld hl, tap_d
        ld a, (hl)
        or a
        jr z, hu_9
        ld (hl), 0
        set KP_STEPD, e
        jr hu_10
hu_9:   ld (hl), TAP_WIN
hu_10:  ld a, b
        ld (ft0 + FT_INTENT), a
        ld a, e
        ld (ft0 + FT_PRESS), a
        ret
hu_dec: ld a, (hl)
        or a
        ret z
        dec (hl)
        ret
