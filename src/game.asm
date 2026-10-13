; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Alex Moncks
; ============================================================================
; game.asm - the match: the frame loop and the round
;
; A frame (30 a second: a page is shown for at least two vertical blanks):
;   frame_begin   waits for the page drawn before to be on show, then starts
;                 the sky and the ground of the hidden page (four fills)
;   logic         one tick of the round, while the V9968 fills
;   hud_bars      the life bars, when they changed
;   scene_draw    the ring and the fighters (geo3d), then geo_wait
;   msg_draw      the message, over the picture
;   frame_end     asks for the page to be shown at the next blank
; ============================================================================

GS_INTRO:   equ 0               ; the fighters walk in
GS_READY:   equ 1               ; ROUND 1
GS_GO:      equ 2               ; FIGHT!
GS_FIGHT:   equ 3
GS_KO:      equ 4               ; one of them is down
GS_WIN:     equ 5               ; the winner's pose

START_X:    equ 236             ; where they come in from
MARK_X:     equ 64              ; where they stop
CAM_MAX:    equ 104             ; the camera stays this close to the middle

game_run:
        call wait_ce
        call hud_init
        call round_init
gr_1:   call frame_begin
        ld a, (dbg_freeze)
        or a
        call z, logic
        call hud_bars
        call scene_draw
        call geo_wait
        call msg_draw
        call frame_end
        ; a new press of the trigger in the demo: play; RETURN: the title
        ld a, (gm_demo)
        or a
        jr z, gr_2
        ld a, (in_cur)
        and 0x10
        jr z, gr_2
        xor a
        ld (gm_demo), a
        ld a, 0xFF
        ld (in_prev), a
        call round_init
        jr gr_1
gr_2:   ld a, (in_cur)
        rlca                        ; IN_START
        jr nc, gr_1
        ret

; ---------------------------------------------------------------- the frame
frame_begin:
        call flip_sync
fb_work:                            ; (the tests time a frame's work from here to frame_end)
        ld a, (buf)
        ld (txt_page), a
        ld hl, bg_boxes
        ld b, 4
fb_1:   push bc
        call box
        pop bc
        djnz fb_1
        ret

bg_boxes:                           ; x, y, width (0 = 256), height, colour
        db 0, VIEW_Y0, 0, (HORIZON - VIEW_Y0) / 3, COL_SKY0
        db 0, VIEW_Y0 + (HORIZON - VIEW_Y0) / 3, 0, (HORIZON - VIEW_Y0) / 3, COL_SKY1
        db 0, VIEW_Y0 + 2 * ((HORIZON - VIEW_Y0) / 3), 0, HORIZON - VIEW_Y0 - 2 * ((HORIZON - VIEW_Y0) / 3), COL_SKY2
        db 0, HORIZON, 0, 212 - HORIZON, COL_GROUND

frame_end:
        ld hl, (st_frames)
        inc hl
        ld (st_frames), hl
        ; 30 frames a second: no flip in the blank right after the last one
fe_1:   ld hl, (vcount)
        ld de, (flip_vc)
        or a
        sbc hl, de
        jr z, fe_1
        ; fall through
; flip_ask: show the page just drawn at the next vertical blank. flip_sync:
; wait for that and take the other page for drawing.
flip_ask:
        call wait_ce
        ld a, (buf)
        rrca
        rrca
        rrca
        or 0x1F
        ld (flip_r2), a
        ld a, 1
        ld (flip_pend), a
        ld (flip_req), a
        ret
flip_sync:
        ld a, (flip_pend)
        or a
        ret z
        xor a
        ld (flip_pend), a
        ld bc, 0                    ; (no interrupt in about 1 s: flip here)
fl_1:   ld a, (flip_req)
        or a
        jr z, fl_2
        dec bc
        ld a, b
        or c
        jr nz, fl_1
        ld (flip_req), a
        ld a, (flip_r2)
        ld b, 2
        call wreg
fl_2:   ld a, (buf)
        xor 1
        ld (buf), a
        ret

; ---------------------------------------------------------------- the round
round_init:
        ld ix, ft0
        ld hl, -START_X
        xor a
        call ri_one
        ld a, (gm_demo)
        ld (ft0 + FT_CPU), a
        ld ix, ft1
        ld hl, START_X
        ld a, 1
        call ri_one
        ld a, 1
        ld (ft1 + FT_CPU), a
        xor a
        ld (gm_state), a
        ld (gm_msg), a
        ld a, 2
        ld (hud_dirty), a
        ret
; IX -> fighter, HL = x, A = slot (its facing and its character)
ri_one: ld (ix + FT_X), l
        ld (ix + FT_X + 1), h
        ld (ix + FT_FACING), a
        ld (ix + FT_CHAR), a
        ld (ix + FT_HP), HP_MAX
        ld (ix + FT_STATE), ST_AUTO
        xor a
        ld (ix + FT_INTENT), a
        ld (ix + FT_AIT), a
        ld (ix + FT_AICMD), a
        ld a, AN_WALK_F
        jp anim_force

; one tick
logic:
        ld a, (gm_state)
        or a
        jp z, lg_intro
        dec a
        jp z, lg_ready
        dec a
        jp z, lg_go
        dec a
        jp z, lg_fight
        dec a
        jp z, lg_ko
        jp lg_win

; the walk in: forwards until the mark
lg_intro:
        ld ix, ft0
        ld de, SPEED_F
        call ft_move
        ld ix, ft1
        ld de, SPEED_F
        call ft_move
        call both_update
        ld hl, (ft1 + FT_X)
        ld de, MARK_X + 1
        call lt_s
        jp nc, lg_cam
        ld ix, ft0
        ld a, AN_IDLE
        call anim_force
        ld ix, ft1
        ld a, AN_IDLE
        call anim_force
        ld a, GS_READY
        ld b, 40
        ld c, MSG_ROUND
        jp lg_next

lg_ready:
        call both_update
        call lg_count
        jp nz, lg_cam
        ld a, SFX_BELL
        call sfx_play
        ld a, GS_GO
        ld b, 22
        ld c, MSG_FIGHT
        jp lg_next

lg_go:  call both_update
        call lg_count
        jp nz, lg_cam
        ld a, ST_FREE
        ld (ft0 + FT_STATE), a
        ld (ft1 + FT_STATE), a
        ld a, 0xFF
        ld (in_prev), a             ; a key held since before does not hit
        ld a, GS_FIGHT
        ld b, 0
        ld c, 0
        ; fall through
; A = the next state, B = its timer, C = its message
lg_next:
        ld (gm_state), a
        ld a, b
        ld (gm_timer), a
        ld a, c
        ld (gm_msg), a
        jp lg_cam

lg_fight:
        ld a, (ft0 + FT_CPU)
        or a
        jr nz, lf_1
        call human_intent
        jr lf_2
lf_1:   ld ix, ft0
        ld iy, ft1
        call ai_think
lf_2:   ld a, (ft1 + FT_CPU)        ; (0 only in the tests: it stands still)
        or a
        jr z, lf_2b
        ld ix, ft1
        ld iy, ft0
        call ai_think
lf_2b:  call both_update
        ; someone down?
        ld a, (ft0 + FT_HP)
        or a
        ld b, 1                     ; the winner's slot
        jr z, lf_3
        ld a, (ft1 + FT_HP)
        or a
        jp nz, lg_cam
        ld b, 0
lf_3:   ld a, b
        ld (gm_winner), a
        xor a
        ld (ft0 + FT_INTENT), a
        ld (ft1 + FT_INTENT), a
        ld a, GS_KO
        ld b, 50
        ld c, MSG_KO
        jp lg_next

; the camera: half way between the two, inside the ring
lg_cam: ld hl, (ft0 + FT_X)
        ld de, (ft1 + FT_X)
        add hl, de
        sra h
        rr l
        ld de, CAM_MAX
        call clamp_s
        ld (cam_x), hl
        ret

lg_ko:  call both_update
        call lg_count
        jp nz, lg_cam
        ; the winner's pose
        ld ix, ft0
        ld a, (gm_winner)
        or a
        jr z, lk_1
        ld ix, ft1
lk_1:   ld (ix + FT_STATE), ST_WIN
        ld a, AN_WIN
        call anim_force
        ld a, (gm_winner)
        add a, MSG_WIN0
        ld c, a
        ld a, GS_WIN
        ld b, 100
        jp lg_next

lg_win: call both_update
        call lg_count
        jp nz, lg_cam
        call round_init
        jp lg_cam

; the state's timer: Z when it runs out
lg_count:
        ld hl, gm_timer
        dec (hl)
        ret

both_update:
        ld ix, ft0
        ld iy, ft1
        call ft_update
        ld ix, ft1
        ld iy, ft0
        jp ft_update
