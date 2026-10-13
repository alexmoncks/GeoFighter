; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Alex Moncks
; ============================================================================
; isr.asm - the interrupt handler (H.KEYI hook), sound effects, input (the
; scheme of MSX WOLF and VECTOR RAID)
;
; H.KEYI is called at every interrupt, before the BIOS looks at the VDP; the
; BIOS has saved all the registers. The handler reads the V9968's S#0 (R#15
; is 0 whenever interrupts are on). At a vertical blank (bit 7) it counts
; it, shows the page the main loop finished if it asked (R#2), steps the
; sound effects and reads the keyboard and joystick 1.
; On 98h this read takes the blank from the BIOS (its handler then sees
; F = 0 and skips its keyboard scan), so the game reads the keys itself.
; On 88h the internal VDP's interrupt is turned off at init and the V9968
; drives /INT (R#1 IE0).
; Nothing here may read page 2: the main loop switches its bank.
; ============================================================================

isr:
        if PORT_BASE == 0x88
        in a, (0x99)                ; the internal VDP's own F flag
        endif
        in a, (VDP_CTRL)
        rlca
        ret nc
        ld hl, (vcount)
        inc hl
        ld (vcount), hl
        ld a, (flip_req)
        or a
        jr z, is_1
        ld a, (flip_r2)
        out (VDP_CTRL), a
        ld a, 0x82
        out (VDP_CTRL), a
        xor a
        ld (flip_req), a
        ld (flip_vc), hl
is_1:   call sfx_tick
        ; fall through

; ---------------------------------------------------------------- input
; in_cur: IN_LEFT, IN_RIGHT (walk), IN_UP, IN_DOWN, IN_A (SPACE, Z, trigger
; A), IN_B (X, trigger B), IN_G (C), IN_START (RETURN). dbg_in (tests) is
; OR-ed in.
input_read:
        ld b, 0
        ld a, 8
        call key_row                ; row 8: 0 SPACE 4 left 5 up 6 down 7 right
        ld c, a
        bit 5, c
        jr z, ir_1
        set IN_UP, b
ir_1:   bit 6, c
        jr z, ir_2
        set IN_DOWN, b
ir_2:   bit 4, c
        jr z, ir_3
        set IN_LEFT, b
ir_3:   bit 7, c
        jr z, ir_4
        set IN_RIGHT, b
ir_4:   bit 0, c
        jr z, ir_5
        set IN_A, b
ir_5:   ld a, 5
        call key_row                ; row 5: 5 X 7 Z
        ld c, a
        bit 7, c
        jr z, ir_6
        set IN_A, b
ir_6:   bit 5, c
        jr z, ir_7
        set IN_B, b
ir_7:   ld a, 3
        call key_row                ; row 3: 0 C
        bit 0, a
        jr z, ir_7b
        set IN_G, b
ir_7b:  ld a, 7
        call key_row                ; row 7: 7 RETURN
        bit 7, a
        jr z, ir_8
        set IN_START, b
ir_8:   ; joystick 1: PSG R#14 (R#15 bit 6 = 0 selects it), active low
        ld a, 15
        out (PSG_A), a
        in a, (PSG_R)
        and 0xBF
        out (PSG_W), a
        ld a, 14
        out (PSG_A), a
        in a, (PSG_R)
        cpl
        and 0x3F                    ; 0 up 1 down 2 left 3 right 4 A 5 B: the IN_ bits
        or b
        ld b, a
        ld a, (dbg_in)
        or b
        ld (in_cur), a
        ret

; A = keyboard row -> A = its keys, 1 = pressed
key_row:
        ld e, a
        in a, (PPI_C)
        and 0xF0
        or e
        out (PPI_C), a
        in a, (PPI_B)
        cpl
        ret

; ---------------------------------------------------------------- sound
; Two voices on PSG channels A and B. A sound is a list of ticks (1/60 s):
; flags | volume, tone period lo, hi, noise period; FFh ends it. Flags: 80h
; noise on, 40h tone off. Data in bank 0 (below).
psg_init:
        ld b, 14
        xor a
pi_1:   out (PSG_A), a
        ld c, a
        xor a
        out (PSG_W), a
        ld a, c
        inc a
        djnz pi_1
        ld a, 0x3F
        ld (psg_mix), a
        ld a, 7
        out (PSG_A), a
        ld a, 0xBF                  ; all off; port B output, port A input
        out (PSG_W), a
        ret

; A = sound (SFX_*)
sfx_play:
        push hl
        push de
        ld l, a
        ld h, 0
        ld e, l
        ld d, h
        add hl, hl
        add hl, de
        ld de, sfx_tab
        add hl, de
        ld e, (hl)
        inc hl
        ld d, (hl)
        inc hl
        ld a, (hl)
        ld hl, sv_ptr
        or a
        jr z, spl_1
        ld hl, sv_ptr + 2
spl_1:  di
        ld (hl), e
        inc hl
        ld (hl), d
        call eiop
        pop de
        pop hl
        ret

sfx_tick:
        ld ix, sv_ptr
        ld c, 0
        call sv_tick
        ld ix, sv_ptr + 2
        ld c, 1
        call sv_tick
        ld a, 7
        out (PSG_A), a
        ld a, (psg_mix)
        or 0x80
        out (PSG_W), a
        ret

; IX -> the voice's pointer, C = voice (0, 1)
sv_tick:
        ld l, (ix + 0)
        ld h, (ix + 1)
        ld a, h
        or l
        ret z
        ld de, 0x0801               ; D = the voice's noise bit, E = its tone bit
        ld a, c
        or a
        jr z, sv_0
        ld de, 0x1002
sv_0:   ld a, (hl)
        cp 0xFF
        jr z, sv_stop
        ld b, a
        inc hl
        ld a, c
        add a, a
        out (PSG_A), a
        ld a, (hl)
        out (PSG_W), a
        inc hl
        ld a, c
        add a, a
        inc a
        out (PSG_A), a
        ld a, (hl)
        out (PSG_W), a
        inc hl
        bit 7, b
        jr z, sv_1
        ld a, 6
        out (PSG_A), a
        ld a, (hl)
        out (PSG_W), a
sv_1:   inc hl
        ld (ix + 0), l
        ld (ix + 1), h
        ld a, c
        add a, 8
        out (PSG_A), a
        ld a, b
        and 15
        out (PSG_W), a
        ld a, (psg_mix)
        or e
        or d
        bit 6, b
        jr nz, sv_2
        xor e                       ; tone on
sv_2:   bit 7, b
        jr z, sv_3
        xor d                       ; noise on
sv_3:   ld (psg_mix), a
        ret
sv_stop:
        xor a
        ld (ix + 0), a
        ld (ix + 1), a
        ld a, c
        add a, 8
        out (PSG_A), a
        xor a
        out (PSG_W), a
        ld a, (psg_mix)
        or e
        or d
        ld (psg_mix), a
        ret

; the sounds: address, voice
SFX_SWING:  equ 0
SFX_HIT:    equ 1
SFX_BLOCK:  equ 2
SFX_KO:     equ 3
SFX_BELL:   equ 4
sfx_tab:
        dw sfx_swing
        db 0
        dw sfx_hit
        db 1
        dw sfx_block
        db 1
        dw sfx_ko
        db 1
        dw sfx_bell
        db 0

; flags | volume, tone lo, tone hi, noise period
sfx_swing:                          ; a short swish
        db 0xC9, 0, 0, 6
        db 0xCB, 0, 0, 4
        db 0xCA, 0, 0, 3
        db 0xC7, 0, 0, 2
        db 0xC4, 0, 0, 2
        db 0xFF
sfx_hit:                            ; a thud
        db 0x8F, 0x40, 0x03, 14
        db 0x8E, 0x80, 0x03, 18
        db 0x8D, 0xC0, 0x03, 22
        db 0x8B, 0x20, 0x04, 26
        db 0x88, 0x80, 0x04, 30
        db 0x85, 0xE0, 0x04, 31
        db 0xFF
sfx_block:                          ; a dry knock
        db 0x8C, 0xA0, 0x00, 8
        db 0x0A, 0xD0, 0x00, 0
        db 0x06, 0x00, 0x01, 0
        db 0xFF
sfx_ko:                             ; a long fall
        db 0x8F, 0x00, 0x02, 20
        db 0x8F, 0x40, 0x02, 22
        db 0x8E, 0x80, 0x02, 24
        db 0x8E, 0xC0, 0x02, 26
        db 0x8D, 0x00, 0x03, 28
        db 0x8C, 0x60, 0x03, 30
        db 0x8B, 0xC0, 0x03, 31
        db 0x8A, 0x40, 0x04, 31
        db 0x88, 0xC0, 0x04, 31
        db 0x86, 0x80, 0x05, 31
        db 0x84, 0x40, 0x06, 31
        db 0x82, 0x00, 0x07, 31
        db 0xFF
sfx_bell:                           ; the round starts
        db 0x0F, 0x70, 0x00, 0
        db 0x0E, 0x70, 0x00, 0
        db 0x0D, 0x70, 0x00, 0
        db 0x0C, 0x70, 0x00, 0
        db 0x0B, 0x70, 0x00, 0
        db 0x0A, 0x70, 0x00, 0
        db 0x09, 0x70, 0x00, 0
        db 0x08, 0x70, 0x00, 0
        db 0x07, 0x70, 0x00, 0
        db 0x06, 0x70, 0x00, 0
        db 0x05, 0x70, 0x00, 0
        db 0x04, 0x70, 0x00, 0
        db 0x03, 0x70, 0x00, 0
        db 0x02, 0x70, 0x00, 0
        db 0xFF
