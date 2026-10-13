; SPDX-License-Identifier: MIT
; Copyright (c) 2026 Alex Moncks
; ============================================================================
; ram.asm - the RAM map (C000h up; the init clears C000h-E7FFh)
; ============================================================================
        org 0xC000
ram_start:
eiop:       ds 2            ; EI, RET (NOP, RET during init)
vcount:     ds 2            ; vertical blanks (interrupt handler)
flip_req:   ds 1            ; 1: show flip_r2 at the next blank
flip_r2:    ds 1
flip_pend:  ds 1            ; 1: a page was asked for and buf not swapped yet
flip_vc:    ds 2            ; vcount at the last flip
in_cur:     ds 1            ; IN_* bits
in_prev:    ds 1            ; the frame before (new presses)
dbg_in:     ds 1            ; tests: keys held from outside
dbg_freeze: ds 1            ; tests: 1 = the logic stops (the picture is still drawn)
buf:        ds 1            ; the hidden page, being drawn (0, 1)
st_geo:     ds 1            ; 0: geo3d did not answer in time
st_frames:  ds 2            ; frames shown (tests)
rnd:        ds 2
sv_ptr:     ds 4            ; the two sound voices
psg_mix:    ds 1
txt_font:   ds 2
txt_page:   ds 1
txt_fg:     ds 1            ; ink (txt_bg must follow: one 16-bit load)
txt_bg:     ds 1
txt_scale:  ds 1
tx_str:     ds 2
tx_xy:      ds 2            ; x, y
tx_row:     ds 1

; ---- VDP command buffer: R#32..R#46
cmdbuf:
cmd_sx:     ds 2
cmd_sy:     ds 2
cmd_dx:     ds 2
cmd_dy:     ds 2
cmd_nx:     ds 2
cmd_ny:     ds 2
cmd_clr:    ds 1
cmd_arg:    ds 1
cmd_op:     ds 1

; ---- the match
cam_x:      ds 2            ; the camera's x: between the two fighters
dv_ring:    ds 6            ; where the ring is, seen by the camera: -cam_x * KVEC
dv_ft0:     ds 6            ; ... and each fighter: (x - cam_x) * KVEC
dv_ft1:     ds 6
kv_d:       ds 2            ; kvec's work
kv_p:       ds 2
orb_i:      ds 1            ; frame of the opening shot
gm_axis:    ds 1            ; the fight's axis: how far the ring is turned (0..AXIS_N-1)
tap_u:      ds 1            ; ticks left for a second tap of up (tap_d must follow)
tap_d:      ds 1            ; ... and of down
gm_state:   ds 1            ; GS_*
gm_timer:   ds 1
gm_demo:    ds 1            ; 1: the machine plays both
gm_msg:     ds 1            ; message on show (0: none)
gm_winner:  ds 1            ; slot of the winner
hud_dirty:  ds 1            ; pages whose life bars are out of date (2: both)
ft0:        ds FT_SIZE      ; the fighter on the left (looks right)
ft1:        ds FT_SIZE      ; the fighter on the right
ram_end:
