; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Alex Moncks
; ============================================================================
; fighter.asm - a fighter: animation, moves, hits, the machine's play
;
; A fighter is a block of FT_SIZE bytes (ft0 on the left, looking right;
; ft1 on the right). What it shows is one pose number (FT_POSE): the
; animation table (out/inc/tables.asm) says which poses an animation plays
; and for how many ticks each. A tick is a shown frame (30 a second).
; What it does comes from its intent (FT_INTENT, CI_* bits), written by the
; player's keys or by ai_think.
; ============================================================================

FT_X:       equ 0               ; word: position in the ring
FT_HP:      equ 2
FT_STATE:   equ 3               ; ST_*
FT_ANIM:    equ 4               ; AN_*
FT_STEP:    equ 5
FT_TICK:    equ 6
FT_POSE:    equ 7
FT_INTENT:  equ 8               ; CI_* bits
FT_FACING:  equ 9               ; 0 looks right, 1 looks left (also the slot)
FT_CHAR:    equ 10
FT_AIT:     equ 11              ; the machine: ticks until it thinks again
FT_AICMD:   equ 12              ; ... and the intent it holds meanwhile
FT_MOVE:    equ 13              ; the attack in progress: 0 punch, 1 kick
FT_CPU:     equ 14              ; 1: the machine plays it
FT_SIZE:    equ 16

ST_FREE:    equ 0               ; stands, walks or guards as the intent says
ST_ATTACK:  equ 1
ST_STUN:    equ 2               ; took a hit or blocked one: until the animation ends
ST_KO:      equ 3
ST_WIN:     equ 4
ST_AUTO:    equ 5               ; the round moves it (the walk into the ring)

CI_FWD:     equ 0
CI_BACK:    equ 1
CI_PUNCH:   equ 2
CI_KICK:    equ 3
CI_GUARD:   equ 4
CM_FWD:     equ 1               ; the same as masks
CM_BACK:    equ 2
CM_PUNCH:   equ 4
CM_KICK:    equ 8
CM_GUARD:   equ 16

SPEED_F:    equ 4               ; units a tick, forwards
SPEED_B:    equ 3
PUSH_HIT:   equ 18              ; how far a hit pushes back
PUSH_BLOCK: equ 7

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

; ---------------------------------------------------------------- one tick
; IX -> the fighter, IY -> the other one
ft_update:
        ld a, (ix + FT_STATE)
        or a
        jr z, fu_free
        cp ST_AUTO
        jp z, anim_tick
        call anim_tick
        ld b, a
        ld a, (ix + FT_STATE)
        cp ST_ATTACK
        jr nz, fu_1
        push bc
        call ft_hitcheck
        pop bc
fu_1:   ld a, b
        or a
        ret z
        ld a, (ix + FT_STATE)       ; the animation ended
        cp ST_KO
        ret z
        cp ST_WIN
        ret z
        ld (ix + FT_STATE), ST_FREE
        ld a, AN_IDLE
        jp anim_force

fu_free:
        ld c, (ix + FT_INTENT)
        bit CI_GUARD, c
        jr z, ff_1
        ld a, AN_GUARD
        call anim_set
        jp anim_tick
ff_1:   bit CI_PUNCH, c
        jr z, ff_2
        ld (ix + FT_MOVE), 0
        ld a, AN_PUNCH
        jr ff_att
ff_2:   bit CI_KICK, c
        jr z, ff_3
        ld (ix + FT_MOVE), 1
        ld a, AN_KICK
ff_att: ld (ix + FT_STATE), ST_ATTACK
        call anim_force
        ld a, SFX_SWING
        jp sfx_play
ff_3:   bit CI_FWD, c
        jr z, ff_4
        ld a, AN_WALK_F
        call anim_set
        ld de, SPEED_F
        call ft_move
        jp anim_tick
ff_4:   bit CI_BACK, c
        jr z, ff_5
        ld a, AN_WALK_B
        call anim_set
        ld de, -SPEED_B
        call ft_move
        jp anim_tick
ff_5:   ld a, AN_IDLE
        call anim_set
        jp anim_tick

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
; within reach: a guard stops it, otherwise it takes life away
ft_hitcheck:
        ld a, (ix + FT_TICK)
        or a
        ret nz
        ld a, (ix + FT_MOVE)
        or a
        ld bc, MV_PUNCH_STEP * 256 + MV_PUNCH_REACH
        ld d, MV_PUNCH_DMG
        jr z, fh_1
        ld bc, MV_KICK_STEP * 256 + MV_KICK_REACH
        ld d, MV_KICK_DMG
fh_1:   ld a, (ix + FT_STEP)
        cp b
        ret nz
        push de
        ld hl, (ft1 + FT_X)
        ld de, (ft0 + FT_X)
        or a
        sbc hl, de                  ; the distance: MIN_SEP or more
        pop de
        ld a, h
        or a
        ret nz
        ld a, c
        cp l
        ret c                       ; out of reach
        ld a, (iy + FT_STATE)
        cp ST_KO
        ret z
        cp ST_AUTO
        ret z
        ld a, (iy + FT_ANIM)
        cp AN_GUARD
        jr z, fh_block
        cp AN_BLOCKHIT
        jr z, fh_block
        ; a hit
        ld a, 2
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
        ld a, SFX_BLOCK
        call sfx_play
        ld b, ST_STUN
        ld c, AN_BLOCKHIT
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
; IX -> the fighter, IY -> the other one: writes FT_INTENT
ai_think:
        ld a, (ix + FT_AIT)
        or a
        jr z, ai_new
        dec (ix + FT_AIT)
        ld a, (ix + FT_AICMD)
        ld (ix + FT_INTENT), a
        ret
ai_new: ; C = the distance (255: far)
        ld hl, (ft1 + FT_X)
        ld de, (ft0 + FT_X)
        or a
        sbc hl, de
        ld c, l
        ld a, h
        or a
        jr z, ai_1
        ld c, 255
ai_1:   ; the other one is attacking within reach: guard, most of the times
        ld a, (iy + FT_STATE)
        cp ST_ATTACK
        jr nz, ai_2
        ld a, c
        cp 112
        jr nc, ai_2
        call rand
        cp 150
        jr nc, ai_2
        ld a, CM_GUARD
        ld b, 9
        jr ai_hold
ai_2:   ld a, c
        cp 90
        jr c, ai_near
        ; far: walk in, with a pause now and then
        call rand
        cp 36
        jr c, ai_wait
        and 3
        add a, 2
        ld b, a
        ld a, CM_FWD
        jr ai_hold
ai_wait:
        xor a
        ld b, 7
        jr ai_hold
ai_near:
        call rand
        cp 92
        jr c, ai_punch
        cp 164
        jr c, ai_kick
        cp 206
        jr c, ai_back
        cp 232
        jr c, ai_guard
        jr ai_wait
ai_punch:
        ld a, CM_PUNCH
        jr ai_once
ai_kick:
        ld a, CM_KICK
ai_once:                            ; this tick only, then a pause
        ld (ix + FT_INTENT), a
        ld (ix + FT_AICMD), 0
        call rand
        and 15
        add a, 9
        ld (ix + FT_AIT), a
        ret
ai_back:
        ld a, CM_BACK
        ld b, 8
        jr ai_hold
ai_guard:
        ld a, CM_GUARD
        ld b, 12
; A = intent, held for B more ticks
ai_hold:
        ld (ix + FT_INTENT), a
        ld (ix + FT_AICMD), a
        ld (ix + FT_AIT), b
        ret

; the player's keys -> ft0's intent. Punch and kick need a new press.
human_intent:
        ld a, (in_cur)
        ld c, a
        ld a, (in_prev)
        cpl
        and c
        ld d, a                     ; D = keys pressed since the last tick
        ld a, c
        ld (in_prev), a
        ld b, 0
        bit IN_RIGHT, c
        jr z, hu_1
        set CI_FWD, b
hu_1:   bit IN_LEFT, c
        jr z, hu_2
        set CI_BACK, b
hu_2:   bit IN_DOWN, c
        jr z, hu_3
        set CI_GUARD, b
hu_3:   bit IN_G, c
        jr z, hu_4
        set CI_GUARD, b
hu_4:   bit IN_A, d
        jr z, hu_5
        set CI_PUNCH, b
hu_5:   bit IN_B, d
        jr z, hu_6
        set CI_KICK, b
hu_6:   ld a, b
        ld (ft0 + FT_INTENT), a
        ret
