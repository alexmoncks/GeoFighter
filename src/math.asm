; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Alex Moncks
; ============================================================================
; math.asm - small helpers. The 3D arithmetic is done on the PC
; (tools/gen_fighter.py): nothing here multiplies.
; ============================================================================

; HL = -HL
neg_hl: xor a
        sub l
        ld l, a
        sbc a, a
        sub h
        ld h, a
        ret

; DE = -DE
neg_de: xor a
        sub e
        ld e, a
        sbc a, a
        sub d
        ld d, a
        ret

; carry set when HL < DE, signed (keeps HL, DE)
lt_s:   push hl
        push de
        ld a, h
        xor 0x80
        ld h, a
        ld a, d
        xor 0x80
        ld d, a
        or a
        sbc hl, de
        pop de
        pop hl
        ret

; HL signed, clamped to -DE..DE (DE > 0)
clamp_s:
        call lt_s
        jr c, cs_1
        ex de, hl                   ; HL >= DE: the limit
        ret
cs_1:   push hl
        call neg_de
        pop hl
        call lt_s
        ret nc
        ex de, hl
        ret

; A = an 8-bit pseudo random number
rand:   push hl
        ld hl, (rnd)
        ld a, h
        rrca
        rrca
        rrca
        xor l
        ld h, l
        ld l, a
        ld a, r
        add a, l
        ld l, a
        ld (rnd), hl
        pop hl
        ret
