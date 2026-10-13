; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Alex Moncks
; ============================================================================
; geo.asm - what geo3d draws: the ring and the two fighters
;
; The scene is a resident scene (VECTOR RAID, docs/engine.md 6.3). All the
; faces are loaded once (geo_init) and stay in geo3d, and so do the vertices:
;
;   vertices   fighter 0's parts, fighter 1's parts, the ring (the highest)
;   faces      the ring's first (0..NFACE_RING-1), then the fighters'
;
; A RUN transforms vertices 0..NVERT-1 and keeps the projection of the rest,
; and a face with a vertex behind the near plane is skipped.
;
; A frame of the fight (scene_draw):
;   1. the ring: NVERT = all, NFACE = NFACE_RING, the camera's matrix with
;      the ring turned as the fight's axis is (gm_axis: a sidestep turns
;      it; one matrix and its light for each of the AXIS_N notches).
;   2. a hide RUN: NFACE = 0 and TZ behind the near plane. Every vertex is
;      now hidden, the ring's too.
;   3. one transform-only RUN (NFACE = 0) for each body part: its matrix and
;      translation come ready from the pose table; the Z80 adds the
;      fighter's place along the ring (a vector worked out once a frame).
;   4. the last RUN: NVERT = 0, NFACE = all. It sorts the faces of both
;      fighters together, far to near, and paints them; the ring's faces are
;      skipped (hidden in step 2). Its matrix is the identity.
;
; A frame of the opening shot (scene_orbit): the camera circles the ring and
; nothing else moves, so the vertices loaded are the ones of the stance
; already in the world (geo_vtx) and the whole frame is one camera record
; from the table: the ring's RUN, the hide RUN, and one RUN that transforms
; the fighters' vertices and paints all their faces.
;
; No face is uploaded in a frame. The normals are stored in the fight
; camera's space, and each RUN gets the light that goes with its matrix
; (tools/gen_fighter.py light()), so a face keeps its tone in every RUN.
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
        xor a
        out (GEO_DAT), a            ; FADDR = 0
        out (GEO_DAT), a            ; NFACE = 0
        ; the faces (11 bytes each, from FADDR = 0): they follow the fight's vertices
        ld a, 0x52
        out (GEO_IDX), a
        ld hl, models + VTX_BYTES
        ld de, FACE_BYTES
        call geo_stream
        ld a, 1
        ld (st_geo), a
        ret

; A = 0: the fight's vertices (each part in its own frame); 1: the opening
; shot's (the stance, in the world). 6 bytes each, from VADDR = 0.
geo_vtx:
        push af
        call geo_wait
        ld a, 1
        ld (BANK2_SEL), a
        ld a, 0x40
        out (GEO_IDX), a
        xor a
        out (GEO_DAT), a            ; VADDR = 0
        ld a, 0x50
        out (GEO_IDX), a
        pop af
        or a
        ld hl, models
        jr z, gv_1
        ld hl, vtx_intro
gv_1:   ld de, VTX_BYTES
        ; fall through
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
ident_rec:
        dw 16384, 0, 0, 0, 16384, 0, 0, 0, 16384, 0, 0, 0
light_id:                           ; for a RUN with the identity
        dw LIGHT_X, LIGHT_Y, LIGHT_Z

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

; A = NVERT, HL -> a record (9 matrix words, TX, TY, TZ), DE -> 3 words
; added to the translation: one RUN, waited for. -> HL after the record,
; DE after the vector. Keeps IX, IY.
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
; HL -> TX, TY, TZ, DE -> 3 words added to them: the translation, and RUN
geo_tr: ld b, 3
gre_1:  ld a, (de)
        inc de
        add a, (hl)
        inc hl
        out (GEO_DAT), a
        ld a, (de)
        inc de
        adc a, (hl)
        inc hl
        out (GEO_DAT), a
        djnz gre_1
        jr geo_go

; A = NVERT, HL -> a record: one RUN, waited for. -> HL after the record.
geo_run:
        call geo_set
geo_go: ld a, 0x48
        out (GEO_IDX), a
        ld a, 3
        out (GEO_DAT), a            ; RUN, filled faces
        jr geo_wait

; A = NVERT, HL -> a record: everything but the RUN
geo_set:
        ld b, a
        ld a, 0x42
        out (GEO_IDX), a
        ld a, b
        out (GEO_DAT), a
        xor a
        out (GEO_IDX), a
        ld bc, 24 * 256 + GEO_DAT
        otir
        ret

; A = NFACE
geo_nface:
        ld b, a
        ld a, 0x59
        out (GEO_IDX), a
        ld a, b
        out (GEO_DAT), a
        ret

; HL -> LX, LY, LZ
geo_light:
        ld a, 0x5A
        out (GEO_IDX), a
        ld bc, 6 * 256 + GEO_DAT
        otir
        ret

; every vertex behind the near plane: only TZ is written
scene_hide:
        xor a
        call geo_nface
        ld a, 0x16
        out (GEO_IDX), a
        xor a
        out (GEO_DAT), a
        ld a, 0xF8
        out (GEO_DAT), a            ; TZ = -2048
        jr geo_go

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
        ld a, (gm_state)
        or a
        jp z, scene_orbit           ; GS_ORBIT
        ; 1. the ring, turned as the fight's axis is: its matrix and light
        ; from the table, its translation worked out with the camera's
        ld a, 1
        ld (BANK2_SEL), a
        ld a, (gm_axis)
        ld l, a
        ld h, 0
        add hl, hl
        add hl, hl
        add hl, hl                  ; * 8
        ld e, l
        ld d, h
        add hl, hl                  ; * 16
        add hl, de                  ; * 24
        ld de, ring_tab
        add hl, de
        push hl
        ld de, 18
        add hl, de
        call geo_light
        ld a, NFACE_RING
        call geo_nface
        ld a, 0x42
        out (GEO_IDX), a
        ld a, NVERT_ALL
        out (GEO_DAT), a
        xor a
        out (GEO_IDX), a
        pop hl
        ld bc, 18 * 256 + GEO_DAT
        otir                        ; the matrix
        ld hl, ring_t0
        ld de, dv_ring
        call geo_tr
        ; 2. hide everything
        call scene_hide
        ; 3. the parts: fighter 1, then fighter 0
        ld ix, ft1
        ld iy, part_end_1 + NPARTS - 1
        ld de, dv_ft1
        call scene_fighter
        ld ix, ft0
        ld iy, part_end_0 + NPARTS - 1
        ld de, dv_ft0
        call scene_fighter
        ld a, 1
        ld (BANK2_SEL), a
        ; 4. sort and paint every face
        ld hl, light_id
        call geo_light
        ld a, NFACE_ALL
        call geo_nface
        ld hl, ident_rec
        xor a                       ; NVERT = 0
        jp so_last

; the opening shot: the frame's camera record and light, for everything
scene_orbit:
        ld a, 1
        ld (BANK2_SEL), a
        ld a, (orb_i)
        ld l, a
        ld h, 0
        add hl, hl                  ; * 2
        ld e, l
        ld d, h
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl                  ; * 32
        or a
        sbc hl, de                  ; * 30 = ORBIT_REC
        ld de, orbit_tab
        add hl, de
        push hl
        ld de, 24
        add hl, de
        call geo_light
        ld a, NFACE_RING
        call geo_nface
        pop hl
        push hl
        ld a, NVERT_ALL
        call geo_run                ; the ring
        call scene_hide
        ld a, NFACE_ALL
        call geo_nface
        pop hl
        ld a, NVERT_FIGHT           ; the ring's vertices stay hidden
so_last:
        call geo_set
        ld a, 0x48
        out (GEO_IDX), a
        ld a, 3
        out (GEO_DAT), a
        ret

; IX -> fighter, IY -> the end of its last part's vertex range, DE -> its
; place along the ring as a vector (dv_ft0, dv_ft1)
scene_fighter:
        ; the bank: two per character and facing, POSES_BANK poses in each
        ld a, (ix + FT_CHAR)
        add a, a
        add a, (ix + FT_FACING)
        add a, a
        add a, POSE_BANK0
        ld c, a
        ld a, (ix + FT_POSE)
        cp POSES_BANK
        jr c, sfi_0
        sub POSES_BANK
        inc c
sfi_0:  ld l, a
        ld a, c
        ld (BANK2_SEL), a
        push de
        ; the pose's last record: 8000h + pose * POSE_BYTES + (NPARTS - 1) * POSE_REC
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
        pop de
        ld b, NPARTS
sfi_1:  push bc
        push de
        ld a, (iy + 0)
        call geo_rec
        pop de
        ld bc, -2 * POSE_REC
        add hl, bc
        dec iy
        pop bc
        djnz sfi_1
        ret

; DE = a distance along the ring (the world's x), HL -> where its 3 words
; go: the same distance seen by the fight camera
kvec:   ld (kv_d), de
        ld (kv_p), hl
        ld bc, KVEC_X
        call kv_one
        ld bc, KVEC_Y
        call kv_one
        ld bc, KVEC_Z
kv_one: ld de, (kv_d)
        call mulq14
        ex de, hl
        ld hl, (kv_p)
        ld (hl), e
        inc hl
        ld (hl), d
        inc hl
        ld (kv_p), hl
        ret
