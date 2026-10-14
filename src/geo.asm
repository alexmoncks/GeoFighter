; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Alex Moncks
; ============================================================================
; geo.asm - what geo3d draws: the ring and the two fighters
;
; geo3d v2.0 is needed (geo_init checks it): the scene has more than 255
; vertices and faces, and every RUN works on its own range of them
; (VFIRST/NVERT for the vertices, FFIRST/NFACE for the faces). It is a
; resident scene (VECTOR RAID, docs/engine.md 6.3): all the faces are loaded
; once (geo_init) and stay in geo3d, and so do the vertices:
;
;   vertices   fighter 0's parts, fighter 1's parts, then the ring's
;   faces      the ring's first (0..NFACE_RING-1), then the fighters'
;
; A RUN transforms its range of vertices and keeps the projection of all
; the others; a face with a vertex behind the near plane is skipped.
;
; A frame of the fight (scene_draw):
;   1. the ring: its own vertices and faces, the camera's matrix with the
;      ring turned as the fight's axis is (gm_axis: a sidestep turns it; one
;      matrix and its light for each of the AXIS_N notches)
;   2. one transform-only RUN (NFACE = 0) for each body part, its own
;      vertices only: its matrix and translation come ready from the pose
;      table; the Z80 adds the fighter's place along the ring (a vector
;      worked out once a frame)
;   3. the last RUN: NVERT = 0 and the fighters' faces. It sorts the faces
;      of both fighters together, far to near, and paints them. Its matrix
;      is the identity.
;
; A frame of the opening shot (scene_orbit): the camera circles the ring and
; nothing else moves, so the vertices loaded are the ones of the stance
; already in the world (geo_vtx) and the whole frame is one camera record
; from the table: one RUN for the ring, one for both fighters.
;
; No face is uploaded in a frame. The normals are stored in the fight
; camera's space, and each RUN gets the light that goes with its matrix
; (tools/gen_fighter.py light()), so a face keeps its tone in every RUN.
; Rules (geo3d README): while RUN busy = 1 nothing else may write the VDP
; command registers or geo3d; CE = 0 does not mean the engine is free.
; ============================================================================

; -> Z: geo3d v2.0 with room for the scene, the scene's faces loaded.
; NZ: an older geo3d (v1.0.0 reads FFh at index 49h) or a smaller build.
geo_init:
        ld a, 0x49
        out (GEO_IDX), a
        in a, (GEO_DAT)
        cp 0xFF
        jr z, gi_old                ; v1.0.0
        cp 0x20
        jr c, gi_old                ; (v1.1-dev: 11h)
        ; the high bits of the pointers and counts, and XCTRL: the extended
        ; mode (10-bit pointers, 12-byte faces)
        ld a, 0x68
        out (GEO_IDX), a
        ld hl, geo_r68
        ld bc, 8 * 256 + GEO_DAT
        otir
        ; XCTRL bits 7-4: the address bits of geo3d's RAMs
        ld a, 0x6F
        out (GEO_IDX), a
        in a, (GEO_DAT)
        and 0xF0
        cp GEO3D_AW * 16
        jr c, gi_old
        ld a, 0x54
        out (GEO_IDX), a
        xor a
        out (GEO_DAT), a            ; VFIRST = 0
        out (GEO_DAT), a
        out (GEO_DAT), a            ; FFIRST = 0
        out (GEO_DAT), a
        ld a, 0x66
        out (GEO_IDX), a
        xor a
        out (GEO_DAT), a            ; EFIRST = 0
        out (GEO_DAT), a
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
        ; the faces (12 bytes each, from FADDR = 0): they follow the fight's vertices
        ld a, MODEL_BANK
        ld (BANK2_SEL), a
        ld a, 0x52
        out (GEO_IDX), a
        ld hl, 0x8000 + VTX_BYTES
        ld de, FACE_BYTES
        call geo_stream
        ld a, 1
        ld (BANK2_SEL), a
        ld (st_geo), a
        xor a                       ; Z
        ret
gi_old: or 1                        ; NZ
        ret

; A = 0: the fight's vertices (each part in its own frame); 1: the opening
; shot's (the stance, in the world). 6 bytes each, from VADDR = 0.
geo_vtx:
        push af
        call geo_wait
        ld a, 0x68
        out (GEO_IDX), a
        xor a
        out (GEO_DAT), a            ; VADDR's high bits
        ld a, 0x40
        out (GEO_IDX), a
        xor a
        out (GEO_DAT), a            ; VADDR = 0
        ld a, 0x50
        out (GEO_IDX), a
        pop af
        or a
        ld a, MODEL_BANK
        ld hl, 0x8000
        jr z, gv_1
        ld a, 1
        ld hl, vtx_intro
gv_1:   ld (BANK2_SEL), a
        ld de, VTX_BYTES
        call geo_stream
        ld a, 1
        ld (BANK2_SEL), a
        ret

; HL -> DE bytes for the data port, 256 at a time
geo_stream:
        ld c, GEO_DAT
gst_1:  ld a, d
        or a
        jr z, gst_2
        ld b, 0
        otir                        ; 256 bytes
        dec d
        jr gst_1
gst_2:  ld a, e
        or a
        ret z
        ld b, e
        otir
        ret

geo_cam:
        dw G3_F, G3_CX, G3_CY, G3_ZNEAR, G3_W, G3_H
geo_r40:
        db 0, 0, 0, 0, 15, 0, 0, 0
geo_r68:                            ; the high bits: all 0; XCTRL = 1
        db 0, 0, 0, 0, 0, 0, 0, 1
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

; HL = the first vertex, DE = how many: the range a RUN transforms
geo_vrange:
        ld a, 0x54
        out (GEO_IDX), a
        ld a, l
        out (GEO_DAT), a            ; VFIRST
        ld a, h
        out (GEO_DAT), a
        ld a, 0x42
        out (GEO_IDX), a
        ld a, e
        out (GEO_DAT), a            ; NVERT
        ld a, 0x6A
        out (GEO_IDX), a
        ld a, d
        out (GEO_DAT), a
        ret

; HL = the first face, DE = how many: the faces a RUN paints
geo_frange:
        ld a, 0x56
        out (GEO_IDX), a
        ld a, l
        out (GEO_DAT), a            ; FFIRST
        ld a, h
        out (GEO_DAT), a
        ld a, 0x59
        out (GEO_IDX), a
        ld a, e
        out (GEO_DAT), a            ; NFACE
        ld a, 0x6D
        out (GEO_IDX), a
        ld a, d
        out (GEO_DAT), a
        ret

; HL -> a record (9 matrix words, TX, TY, TZ), DE -> 3 words added to the
; translation: one RUN of the range already set, waited for. -> HL after
; the record, DE after the vector. Keeps IX, IY.
geo_rec:
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

; HL -> a record: one RUN of the range already set, waited for. -> HL after
; the record.
geo_run:
        call geo_set
geo_go: ld a, 0x48
        out (GEO_IDX), a
        ld a, 3
        out (GEO_DAT), a            ; RUN, filled faces
        jr geo_wait

; HL -> a record: the matrix and the translation
geo_set:
        xor a
        out (GEO_IDX), a
        ld bc, 24 * 256 + GEO_DAT
        otir
        ret

; HL -> LX, LY, LZ
geo_light:
        ld a, 0x5A
        out (GEO_IDX), a
        ld bc, 6 * 256 + GEO_DAT
        otir
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
        ld a, (gm_state)
        or a
        jp z, scene_orbit           ; GS_ORBIT
        ; 1. the ring, turned as the fight's axis is: its matrix and light
        ; from the table, its translation worked out with the camera's
        ld hl, NVERT_FIGHT
        ld de, NVERT_RING
        call geo_vrange
        ld hl, 0
        ld de, NFACE_RING
        call geo_frange
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
        pop hl
        xor a
        out (GEO_IDX), a
        ld bc, 18 * 256 + GEO_DAT
        otir                        ; the matrix
        ld hl, ring_t0
        ld de, dv_ring
        call geo_tr
        ; 2. the parts: fighter 1, then fighter 0 (transform only)
        ld de, 0
        call geo_frange             ; (HL: any face)
        ld ix, ft1
        ld iy, part_v_1 + (NPARTS - 1) * 3
        ld de, dv_ft1
        call scene_fighter
        ld ix, ft0
        ld iy, part_v_0 + (NPARTS - 1) * 3
        ld de, dv_ft0
        call scene_fighter
        ld a, 1
        ld (BANK2_SEL), a
        ; 3. sort and paint the fighters' faces
        ld hl, 0
        ld de, 0
        call geo_vrange             ; NVERT = 0
        ld hl, NFACE_RING
        ld de, NFACE_FIGHT
        call geo_frange
        ld hl, light_id
        call geo_light
        ld hl, ident_rec
        jr so_last

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
        ; the ring
        ld hl, NVERT_FIGHT
        ld de, NVERT_RING
        call geo_vrange
        ld hl, 0
        ld de, NFACE_RING
        call geo_frange
        pop hl
        push hl
        call geo_run
        ; the fighters, with the same camera
        ld hl, 0
        ld de, NVERT_FIGHT
        call geo_vrange
        ld hl, NFACE_RING
        ld de, NFACE_FIGHT
        call geo_frange
        pop hl
so_last:
        call geo_set
        ld a, 0x48
        out (GEO_IDX), a
        ld a, 3
        out (GEO_DAT), a
        ret

; IX -> fighter, IY -> its last part's entry in part_v_<slot> (the first
; vertex, a word, and how many, a byte), DE -> its place along the ring as a
; vector (dv_ft0, dv_ft1)
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
        push hl
        ld l, (iy + 0)
        ld h, (iy + 1)
        ld e, (iy + 2)
        ld d, 0
        call geo_vrange             ; this part's vertices
        pop hl
        pop de
        push de
        call geo_rec
        pop de
        ld bc, -2 * POSE_REC
        add hl, bc
        ld bc, -3
        add iy, bc
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
