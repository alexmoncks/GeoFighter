; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Alex Moncks
; ============================================================================
; hud.asm - text, the status bar, the messages, the title
;
; Text is written straight into VRAM (1 byte a pixel) from the MSX's own
; 8 x 8 font (CGTABL), each dot 1 or 2 pixels wide and high (txt_scale), in
; txt_fg on txt_bg, on page txt_page (as in MSX WOLF). That takes about
; 0.2 ms a character, too slow for the game loop, so:
;   - the status bar (rows 0..19 of both pages) is drawn once a round; only
;     the life bars change, with HMMV fills, on the pages marked in hud_dirty;
;   - the messages (ROUND 1, FIGHT!, K.O., ... WINS) are drawn once at boot
;     in the rows of the two pages that are never shown (212 up) and copied
;     over the picture by the V9968 (LMMM + TIMP: colour 0 is a hole).
; Nothing here may run while geo3d is drawing.
; ============================================================================

HP_MAX:     equ 100                 ; 1 pixel of bar per point
BAR0_X:     equ 14                  ; the left bar: 14..113
BAR1_X:     equ 142                 ; the right bar: 142..241
BAR_Y:      equ 11
BAR_H:      equ 6
MSG_Y:      equ 84                  ; where a message goes on the screen

; HL -> text (0 ends), E = x, D = y
txt_put:
        ld (tx_str), hl
        ld (tx_xy), de
        xor a
        ld (tx_row), a
tp_row: ld a, (txt_scale)
        ld b, a
tp_rep: push bc
        ld a, (txt_page)
        ld c, a
        ld hl, (tx_xy)
        call vaddr_w
        ld hl, (tx_str)
tp_ch:  ld a, (hl)
        or a
        jr z, tp_eol
        inc hl
        push hl
        ld l, a
        ld h, 0
        add hl, hl
        add hl, hl
        add hl, hl
        ld de, (txt_font)
        add hl, de
        ld a, (tx_row)
        ld e, a
        ld d, 0
        add hl, de
        ld d, (hl)                  ; the glyph's row
        ld hl, (txt_fg)             ; L = ink, H = paper
        ld b, 8
        ld a, (txt_scale)
        dec a
        jr nz, tp_w
tp_n:   rlc d
        ld a, h
        jr nc, tp_n1
        ld a, l
tp_n1:  out (VDP_DATA), a
        djnz tp_n
        jr tp_cn
tp_w:   rlc d
        ld a, h
        jr nc, tp_w1
        ld a, l
tp_w1:  out (VDP_DATA), a
        out (VDP_DATA), a
        djnz tp_w
tp_cn:  pop hl
        jr tp_ch
tp_eol: pop bc
        ld hl, tx_xy + 1
        inc (hl)
        djnz tp_rep
        ld hl, tx_row
        inc (hl)
        ld a, (hl)
        cp 8
        jr nz, tp_row
        ret

; HL -> db x, y, page, colour, scale, text, 0 -> HL after it (paper 0)
txt_at: ld e, (hl)
        inc hl
        ld d, (hl)
        inc hl
        ld a, (hl)
        inc hl
        ld (txt_page), a
        ld a, (hl)
        inc hl
        ld (txt_fg), a
        xor a
        ld (txt_bg), a
        ld a, (hl)
        inc hl
        ld (txt_scale), a
        push hl
        call txt_put
        pop hl
ta_1:   ld a, (hl)
        inc hl
        or a
        jr nz, ta_1
        ret

; HL -> B texts for txt_at
txt_list:
        push bc
        call txt_at
        pop bc
        djnz txt_list
        ret

; ---------------------------------------------------------------- messages
; drawn once, in the hidden rows: page 0 rows 212 and 230, page 1 the same
MSG_ROUND:  equ 1
MSG_FIGHT:  equ 2
MSG_KO:     equ 3
MSG_WIN0:   equ 4                   ; + the winner's slot

msg_prep:
        ld hl, msg_texts
        ld b, 5
        jp txt_list

msg_texts:
        db 0, 212, 0, COL_YELLOW, 2
        db "ROUND 1", 0
        db 128, 212, 0, COL_WHITE, 2
        db "FIGHT!", 0
        db 0, 230, 0, COL_RED, 2
        db "K.O.", 0
        db 0, 212, 1, COL_YELLOW, 2
        db "RAI WINS", 0
        db 0, 230, 1, COL_YELLOW, 2
        db "DAGO WINS", 0

; per message: source x, source y, source page, width
msg_tab:
        db 0, 212, 0, 112
        db 128, 212, 0, 96
        db 0, 230, 0, 64
        db 0, 212, 1, 128
        db 0, 230, 1, 144

; the message on show (gm_msg), over the picture of the hidden page
msg_draw:
        ld a, (gm_msg)
        or a
        ret z
        dec a
        add a, a
        add a, a
        ld e, a
        ld d, 0
        ld hl, msg_tab
        add hl, de
        ld a, (hl)
        inc hl
        ld (cmd_sx), a
        xor a
        ld (cmd_sx + 1), a
        ld a, (hl)
        inc hl
        ld (cmd_sy), a
        ld a, (hl)
        inc hl
        ld (cmd_sy + 1), a
        ld a, (hl)                  ; the width
        ld (cmd_nx), a
        xor a
        ld (cmd_nx + 1), a
        ld (cmd_dx + 1), a
        ld (cmd_ny + 1), a
        ld (cmd_clr), a
        ld (cmd_arg), a
        ld a, (hl)
        srl a
        ld b, a
        ld a, 128
        sub b
        ld (cmd_dx), a              ; centred
        ld a, MSG_Y
        ld (cmd_dy), a
        ld a, (buf)
        ld (cmd_dy + 1), a
        ld a, 16
        ld (cmd_ny), a
        ld a, LMMM + TIMP
        ld (cmd_op), a
        jp cmd_all

; ---------------------------------------------------------------- status bar
; the fixed part, on both pages: black, the names, the bars' frames
hud_init:
        xor a
        call hi_page
        ld a, 1
        call hi_page
        ld hl, hud_texts
        ld b, 6
        call txt_list
        ld a, 2
        ld (hud_dirty), a
        ret
hi_page:
        ld (txt_page), a
        ld hl, hud_boxes
        ld b, 3
hi_1:   push bc
        call box
        pop bc
        djnz hi_1
        jp wait_ce

hud_boxes:                          ; x, y, width, height, colour
        db 0, 0, 0, VIEW_Y0, COL_BLACK
        db BAR0_X - 2, BAR_Y - 2, HP_MAX + 4, BAR_H + 4, COL_FRAME
        db BAR1_X - 2, BAR_Y - 2, HP_MAX + 4, BAR_H + 4, COL_FRAME

hud_texts:                          ; x, y, page, colour, scale, text
        db BAR0_X, 0, 0, COL_WHITE, 1
        db "RAI", 0
        db BAR1_X + HP_MAX - 32, 0, 0, COL_WHITE, 1
        db "DAGO", 0
        db 120, 10, 0, COL_ORANGE, 1
        db "KO", 0
        db BAR0_X, 0, 1, COL_WHITE, 1
        db "RAI", 0
        db BAR1_X + HP_MAX - 32, 0, 1, COL_WHITE, 1
        db "DAGO", 0
        db 120, 10, 1, COL_ORANGE, 1
        db "KO", 0

; the life bars of the hidden page, when they changed: each is a red box
; with what is left in yellow, the two emptying towards the outside
hud_bars:
        ld a, (hud_dirty)
        or a
        ret z
        dec a
        ld (hud_dirty), a
        ld a, (buf)
        ld (cmd_dy + 1), a
        xor a
        ld (cmd_dx + 1), a
        ld (cmd_nx + 1), a
        ld (cmd_ny + 1), a
        ld a, BAR_Y
        ld (cmd_dy), a
        ld a, BAR_H
        ld (cmd_ny), a
        ; fighter 0: the bar is full at the right (the centre of the screen)
        ld a, BAR0_X
        ld c, COL_RED
        call hb_box
        ld a, (ft0 + FT_HP)
        or a
        jr z, hb_1
        ld (cmd_nx), a
        ld b, a
        ld a, BAR0_X + HP_MAX
        sub b
        ld (cmd_dx), a
        ld a, COL_YELLOW
        call fill
hb_1:   ; fighter 1: full at the left
        ld a, BAR1_X
        ld c, COL_RED
        call hb_box
        ld a, (ft1 + FT_HP)
        or a
        ret z
        ld (cmd_nx), a
        ld a, BAR1_X
        ld (cmd_dx), a
        ld a, COL_YELLOW
        jp fill
; A = x, C = colour: the whole bar
hb_box: ld (cmd_dx), a
        ld a, HP_MAX
        ld (cmd_nx), a
        ld a, c
        jp fill

; ---------------------------------------------------------------- the title
; shows page 0 with the title; returns with gm_demo = 0 when the trigger
; was pressed, 1 after about 6 seconds without it
title_screen:
        call flip_sync
        xor a
        ld (txt_page), a
        ld hl, title_box
        call box
        call wait_ce
        ld hl, title_texts
        ld b, 8
        call txt_list
        xor a
        ld (buf), a
        call flip_ask               ; show page 0
        call flip_sync              ; (buf = 1 now)
        ld hl, (vcount)
        ld de, 360
        add hl, de
        ex de, hl                   ; DE = the blank that starts the demo
ts_1:   ld a, (in_cur)
        and 0x90                    ; IN_A, IN_START
        jr nz, ts_play
        ld hl, (vcount)
        or a
        sbc hl, de
        jr c, ts_1
        ld a, 1
        ld (gm_demo), a
        ret
ts_play:
        xor a
        ld (gm_demo), a
        ld a, 0xFF
        ld (in_prev), a             ; the trigger still held does not cut the opening shot
        ld a, SFX_BELL
        jp sfx_play

title_box:
        db 0, 0, 0, 212, COL_BLACK
title_texts:
        db 40, 40, 0, COL_YELLOW, 2
        db "GEO FIGHTER", 0
        db 56, 66, 0, COL_ORANGE, 1
        db "V9968 + GEO3D DEMO", 0
        db 28, 94, 0, COL_WHITE, 1
        db "SPACE OR TRIGGER: 1 PLAYER", 0
        db 28, 114, 0, COL_FRAME, 1
        db "LEFT RIGHT WALK    UP JUMP", 0
        db 28, 126, 0, COL_FRAME, 1
        db "SPACE PUNCH X KICK C GUARD", 0
        db 28, 138, 0, COL_FRAME, 1
        db "DOWN CROUCH: LOW PUNCH KICK", 0
        db 28, 150, 0, COL_FRAME, 1
        db "UP UP, DOWN DOWN: SIDESTEP", 0
        db 72, 182, 0, COL_GREEN, 1
        db "RAI VS DAGO", 0
