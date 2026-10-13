; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Alex Moncks
; ============================================================================
; math.asm - small helpers. The 3D arithmetic is done on the PC
; (tools/gen_fighter.py); the only products left are the three positions
; along the ring times a constant vector, 9 a frame (geo.asm kvec).
; ============================================================================

; HL = (DE * BC) >> 14, signed: the product of the magnitudes, the sign put
; back after (so it rounds toward zero). Keeps IX, IY. (MSX WOLF's)
mulq14:
        ld a, d
        xor b
        push af                     ; bit 7: the result is negative
        bit 7, d
        jr z, mq_1
        xor a
        sub e
        ld e, a
        sbc a, a
        sub d
        ld d, a
mq_1:   bit 7, b
        jr z, mq_2
        xor a
        sub c
        ld c, a
        sbc a, a
        sub b
        ld b, a
mq_2:   ; the product >> 8 = D * BC + (E * BC >> 8): two multiplies of 8 by
        ; 16 bits, and only one when D = 0 (a small factor goes in DE)
        ld a, e
        call mul8
        ld l, h
        ld h, a                     ; HL = E * BC >> 8
        ld a, d
        or a
        jr z, mq_3
        push hl
        call mul8
        pop de
        add hl, de
        adc a, 0
mq_3:   add hl, hl
        rla
        add hl, hl
        rla
        ld l, h
        ld h, a                     ; product >> 14
        pop af
        ret p
        jp neg_hl

; A:HL = A * BC, unsigned (keeps BC, DE). A gives its bits from the top and
; takes what overflows HL at the bottom.
mul8:   ld hl, 0
        add hl, hl
        rla
        jr nc, m8_1
        add hl, bc
        adc a, 0
m8_1:   add hl, hl
        rla
        jr nc, m8_2
        add hl, bc
        adc a, 0
m8_2:   add hl, hl
        rla
        jr nc, m8_3
        add hl, bc
        adc a, 0
m8_3:   add hl, hl
        rla
        jr nc, m8_4
        add hl, bc
        adc a, 0
m8_4:   add hl, hl
        rla
        jr nc, m8_5
        add hl, bc
        adc a, 0
m8_5:   add hl, hl
        rla
        jr nc, m8_6
        add hl, bc
        adc a, 0
m8_6:   add hl, hl
        rla
        jr nc, m8_7
        add hl, bc
        adc a, 0
m8_7:   add hl, hl
        rla
        ret nc
        add hl, bc
        adc a, 0
        ret

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
