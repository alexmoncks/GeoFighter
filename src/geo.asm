; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Alex Moncks
; ============================================================================
; geo.asm - what geo3d draws: the ring and the two fighters
;
; The scene is a resident scene (VECTOR RAID, docs/engine.md 6.3). All the
; vertices and all the faces are loaded once (geo_init) and stay in geo3d:
;
;   vertices   fighter 0's parts, fighter 1's parts, the ring (the highest)
;   faces      the ring's first (0..NFACE_FLOOR-1), then the fighters'
;
; A RUN transforms vertices 0..NVERT-1 and keeps the projection of the rest,
; and a face with a vertex behind the near plane is skipped. So a frame is:
;
;   1. the ring: NVERT = all, NFACE = NFACE_FLOOR, the camera's matrix.
;   2. a hide RUN: NFACE = 0 and TZ behind the near plane. Every vertex is
;      now hidden, the ring's too.
;   3. one transform-only RUN (NFACE = 0) for each body part, from the
;      highest vertex range down: its matrix and translation come ready from
;      the pose table, the Z80 adds the fighter's X.
;   4. the last RUN: NVERT = 0, NFACE = all. It sorts the faces of both
;      fighters together, far to near, and paints them; the ring's faces are
;      skipped (hidden in step 2). Its matrix is the identity: the normals
;      are stored in camera space.
;
; No face is uploaded in a frame. The Z80 sends 25 RUNs of 24 bytes.
; Rules (geo3d README): while RUN busy = 1 nothing else may write the VDP
; command registers or geo3d; CE = 0 does not mean the engine is free.
; ============================================================================

geo_init:
        ld a, 1
        ld (BANK2_SEL), a
        ld a, 0x18
        out (GEO_IDX), a
        ld hl, geo_cam
        ld bc, 12 * 256 + GEO_DAT
        otir                        ; F, CX, CY, ZNEAR, W, H
        ld a, 0x40
        out (GEO_IDX), a
        ld hl, geo_r40
        ld bc, 8 * 256 + GEO_DAT
        otir                        ; VADDR, EADDR, NVERT, NEDGE, COLOR, LOP, YPAGE
        ld a, 0x58
        out (GEO_IDX), a
        ld hl, geo_r58
        ld bc, 8 * 256 + GEO_DAT
        otir                        ; FADDR, NFACE, LX, LY, LZ
        ; the vertices (6 bytes each, from VADDR = 0)
        ld a, 0x50
        out (GEO_IDX), a
        ld hl, models
        ld de, VTX_BYTES
        call geo_stream
        ; the faces (11 bytes each, from FADDR = 0)
        ld a, 0x52
        out (GEO_IDX), a
        ld de, FACE_BYTES
        call geo_stream
        ld a, 1
        ld (st_geo), a
        ret

; HL -> DE bytes for the data port
geo_stream:
        ld c, GEO_DAT
gst_1:  outi
        dec de
        ld a, d
        or e
        jr nz, gst_1
        ret

geo_cam:
        dw G3_F, G3_CX, G3_CY, G3_ZNEAR, G3_W, G3_H
geo_r40:
        db 0, 0, 0, 0, 15, 0, 0, 0
geo_r58:
        db 0, 0
        dw LIGHT_X, LIGHT_Y, LIGHT_Z
ident_rec:
        dw 16384, 0, 0, 0, 16384, 0, 0, 0, 16384, 0, 0, 0

; wait for RUN busy = 0 (a stuck geo3d is given up after about 1 s). Keeps
; HL, DE, IX, IY.
geo_wait:
        ld bc, 0
gw_1:   in a, (GEO_IDX)
        rrca
        ret nc
        dec bc
        ld a, b
        or c
        jr nz, gw_1
        xor a
        ld (st_geo), a
        ret

; A = NVERT, HL -> a record (9 matrix words, TX, TY, TZ), DE = added to TX:
; one RUN, waited for. -> HL after the record. Keeps DE, IX, IY.
geo_rec:
        ld b, a
        ld a, 0x42
        out (GEO_IDX), a
        ld a, b
        out (GEO_DAT), a            ; NVERT
        xor a
        out (GEO_IDX), a
        ld bc, 18 * 256 + GEO_DAT
        otir                        ; the matrix
        ld a, (hl)
        inc hl
        add a, e
        out (GEO_DAT), a
        ld a, (hl)
        inc hl
        adc a, d
        out (GEO_DAT), a            ; TX + DE
        ld bc, 4 * 256 + GEO_DAT
        otir                        ; TY, TZ
        ld a, 0x48
        out (GEO_IDX), a
        ld a, 3
        out (GEO_DAT), a            ; RUN, filled faces
        jr geo_wait

; A = NFACE
geo_nface:
        ld b, a
        ld a, 0x59
        out (GEO_IDX), a
        ld a, b
        out (GEO_DAT), a
        ret

; ---------------------------------------------------------------- the frame
; the whole picture of the hidden page (buf); returns while the last RUN
; is still painting (geo_wait before anything else is drawn)
scene_draw:
        call wait_ce
        ld a, 0x46
        out (GEO_IDX), a
        ld a, VIEW_Y0
        out (GEO_DAT), a
        ld a, (buf)
        out (GEO_DAT), a            ; YPAGE = 256 * buf + VIEW_Y0
        ; 1. the ring
        ld a, NFACE_FLOOR
        call geo_nface
        ld hl, (cam_x)
        call neg_hl
        ex de, hl                   ; DE = -cam_x
        ld hl, floor_rec
        ld a, NVERT_ALL
        call geo_rec
        ; 2. hide everything
        xor a
        call geo_nface
        ld a, 0x16
        out (GEO_IDX), a
        xor a
        out (GEO_DAT), a
        ld a, 0xF8
        out (GEO_DAT), a            ; TZ = -2048
        ld a, 0x48
        out (GEO_IDX), a
        ld a, 3
        out (GEO_DAT), a
        call geo_wait
        ; 3. the parts, the highest range first: fighter 1, then fighter 0
        ld ix, ft1
        ld iy, part_end_1 + NPARTS - 1
        call scene_fighter
        ld ix, ft0
        ld iy, part_end_0 + NPARTS - 1
        call scene_fighter
        ld a, 1
        ld (BANK2_SEL), a
        ; 4. sort and paint every face
        ld a, NFACE_ALL
        call geo_nface
        ld de, 0
        ld hl, ident_rec
        xor a                       ; NVERT = 0
        ld b, a
        ld a, 0x42
        out (GEO_IDX), a
        xor a
        out (GEO_DAT), a
        out (GEO_IDX), a
        ld bc, 24 * 256 + GEO_DAT
        otir
        ld a, 0x48
        out (GEO_IDX), a
        ld a, 3
        out (GEO_DAT), a
        ret

; IX -> fighter, IY -> the end of its last part's vertex range
scene_fighter:
        ld a, (ix + FT_CHAR)
        add a, a
        add a, (ix + FT_FACING)
        add a, POSE_BANK0
        ld (BANK2_SEL), a
        ; the pose's last record: 8000h + pose * POSE_BYTES + (NPARTS - 1) * POSE_REC
        ld l, (ix + FT_POSE)
        ld h, 0
        ld e, l
        ld d, h
        add hl, hl
        add hl, hl
        add hl, hl                  ; * 8
        ld d, e
        ld e, 0                     ; * 256
        add hl, de                  ; * 264 = POSE_BYTES
        ld de, 0x8000 + (NPARTS - 1) * POSE_REC
        add hl, de
        push hl
        ; DE = the fighter's x seen from the camera
        ld l, (ix + FT_X)
        ld h, (ix + FT_X + 1)
        ld de, (cam_x)
        or a
        sbc hl, de
        ex de, hl
        pop hl
        ld b, NPARTS
sfi_1:  push bc
        ld a, (iy + 0)
        call geo_rec
        ld bc, -2 * POSE_REC
        add hl, bc
        dec iy
        pop bc
        djnz sfi_1
        ret
