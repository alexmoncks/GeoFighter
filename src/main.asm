; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Alex Moncks
; ============================================================================
; GEO FIGHTER - a 3D fighting game for the MSX with the V9968 + geo3d
;
; This is the test demo: two fighters walk into the ring and fight (player 1
; on the keyboard or joystick 1 against the machine, or the machine against
; itself).
;
; MSX MegaROM, ASCII16 mapper, 128 KB:
;   bank 0   page 1 (4000h-7FFFh), fixed: all the code, the animation table,
;            the sounds
;   bank 1   page 2 (8000h-BFFFh) at boot: the palette, the vertices and the
;            faces of the scene
;   bank 2+  the poses: one bank per character and facing, POSE_BYTES per pose
; Ports come from out/ports.asm (build.sh): PORT_BASE 98h (openMSX: the
; V9968 is the machine's VDP) or 88h (the V9968 cartridge next to the
; internal VDP). geo3d sits at PORT_BASE + 5 (index/status) and + 7 (data).
;
; The picture: SCREEN 8 (256 x 212, 1 byte a pixel) with the V9968's
; extended palette (256 entries of 15 bits), two pages flipped in the
; vertical blank, 30 frames a second. Rows 0..19 are the status bar; the 3D
; view is rows 20..211. Every frame the hidden page gets
;   1. the sky and the ground: four HMMV fills
;   2. the ring: one geo3d RUN
;   3. the two fighters: a resident scene (geo.asm), one transform-only RUN
;      for each body part and a last RUN that sorts and paints every face
;   4. a message, when there is one: LMMM + TIMP
; The poses are worked out on the PC (tools/gen_fighter.py): the Z80 does no
; 3D arithmetic, it adds each fighter's X to 22 translations.
; ============================================================================

        include "out/ports.asm"         ; PORT_BASE (build.sh)
        include "out/inc/const.asm"     ; tools/gen_fighter.py

VDP_DATA:   equ PORT_BASE
VDP_CTRL:   equ PORT_BASE + 1
VDP_PAL:    equ PORT_BASE + 2
VDP_IND:    equ PORT_BASE + 3
VDP_P4:     equ PORT_BASE + 4
GEO_IDX:    equ PORT_BASE + 5
GEO_DAT:    equ PORT_BASE + 7

PPI_B:      equ 0xA9
PPI_C:      equ 0xAA
PSG_A:      equ 0xA0
PSG_W:      equ 0xA1
PSG_R:      equ 0xA2

ENASLT:     equ 0x0024
RSLREG:     equ 0x0138
CGTABL:     equ 0x0004
EXPTBL:     equ 0xFCC1
RG1SAV:     equ 0xF3E0
HKEYI:      equ 0xFD9A
BANK1_SEL:  equ 0x6000          ; ASCII16: bank of 4000h-7FFFh
BANK2_SEL:  equ 0x7000          ; ASCII16: bank of 8000h-BFFFh

HMMV:       equ 0xC0
HMMM:       equ 0xD0
LMMM:       equ 0x90
TIMP:       equ 0x08

; in_cur bits
IN_UP:      equ 0
IN_DOWN:    equ 1
IN_LEFT:    equ 2
IN_RIGHT:   equ 3
IN_A:       equ 4               ; SPACE, Z, trigger A: punch
IN_B:       equ 5               ; X, trigger B: kick
IN_G:       equ 6               ; C: guard (also DOWN)
IN_START:   equ 7               ; RETURN

; ============================================================================
; bank 0
; ============================================================================
        org 0x4000
        db "AB"
        dw init
        dw 0, 0, 0
        ds 6, 0
        db "ROM_AS16"                   ; 4010h: ROM type signature (MSXgl): ASCII16
        include "src/mapper_tag_ascii16.asm"    ; never run: for mapper guessers

init:
        di
        ld sp, 0xF300
        ; page 2 -> this cartridge's slot (the slot of page 1)
        call RSLREG
        rrca
        rrca
        and 3
        ld c, a
        ld b, 0
        ld hl, EXPTBL
        add hl, bc
        ld a, (hl)
        and 0x80
        or c
        ld c, a
        inc hl
        inc hl
        inc hl
        inc hl
        ld a, (hl)
        and 0x0C
        or c
        ld h, 0x80
        call ENASLT
        di
        xor a
        ld (BANK1_SEL), a
        ld a, 1
        ld (BANK2_SEL), a
        ; clear RAM C000h-E7FFh
        ld hl, 0xC000
        ld de, 0xC001
        ld bc, 0x27FF
        ld (hl), 0
        ldir
        ld hl, 0xC900               ; NOP, RET: interrupts stay off during init
        ld (eiop), hl
        ld hl, (CGTABL)
        ld (txt_font), hl
        ld hl, 0x1D2B
        ld (rnd), hl
        call psg_init
        if PORT_BASE == 0x88
        ; the internal VDP: no interrupts (its BIOS keyboard scan is not needed)
        ld a, (RG1SAV)
        and 0xDF
        out (0x99), a
        ld a, 0x81
        out (0x99), a
        in a, (0x99)
        endif
        call vdp_init
        call pal_load
        in a, (GEO_IDX)
        cp 0xFF
        jp z, no_geo
        call geo_init
        call msg_prep
        ; the interrupt handler (H.KEYI: every interrupt, before the BIOS)
        ld a, 0xC3
        ld (HKEYI), a
        ld hl, isr
        ld (HKEYI + 1), hl
        ld hl, 0xC9FB               ; EI, RET
        ld (eiop), hl
        ld a, 0x60                  ; display on, IE0
        ld b, 1
        call wreg                   ; (interrupts on from here: eiop)

main_loop:
        call title_screen
        call game_run
        jr main_loop

; no geo3d at PORT_BASE + 5: say so and stop
no_geo:
        ld a, 0x40                  ; display on, no interrupt
        ld b, 1
        call wreg
        xor a
        ld (txt_page), a
        ld (txt_bg), a
        ld a, COL_YELLOW
        ld (txt_fg), a
        ld a, 1
        ld (txt_scale), a
        ld hl, s_nogeo
        ld de, 96 * 256 + 48
        call txt_put
ng_1:   jr ng_1
s_nogeo:
        db "GEO3D NAO ENCONTRADO", 0

        include "src/vdp.asm"
        include "src/math.asm"
        include "src/isr.asm"
        include "src/geo.asm"
        include "src/hud.asm"
        include "src/fighter.asm"
        include "src/game.asm"
        include "out/inc/tables.asm"

bank0_end:
        ds 0x8000 - $, 0xFF

; ============================================================================
; bank 1: the palette and the scene's vertices and faces
; ============================================================================
        org 0x8000
palette:
        incbin "out/palette.bin"
models:
        incbin "out/models.bin"
bank1_end:
        ds 0xC000 - $, 0xFF

; ============================================================================
; banks 2..5: the poses of character 0 looking right, looking left, then
; character 1's
; ============================================================================
        org 0x8000
        incbin "out/pose_0_0.bin"
        ds 0xC000 - $, 0xFF
        org 0x8000
        incbin "out/pose_0_1.bin"
        ds 0xC000 - $, 0xFF
        org 0x8000
        incbin "out/pose_1_0.bin"
        ds 0xC000 - $, 0xFF
        org 0x8000
        incbin "out/pose_1_1.bin"
        ds 0xC000 - $, 0xFF
; banks 6 and 7: free (the ROM is 128 KB)
        org 0x8000
        ds 0x4000, 0xFF
        org 0x8000
        ds 0x4000, 0xFF

; ============================================================================
; RAM (addresses only: build.sh cuts the image at the ROM size)
; ============================================================================
        include "src/ram.asm"
