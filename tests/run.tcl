# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alex Moncks
#
# run.tcl - openMSX driver for the GEO FIGHTER tests (started by tests/run_tests.sh)
#
# Env: LABELS (Tcl file: set ::A(name) addr, from the assembler's label list),
#      OUTDIR, SHOT (1: a window and screenshots),
#      SCRIPT: steps separated by ";"
#   keys MASK         hold keys through dbg_in: 1 up 2 down 4 left 8 right
#                     16 punch 32 kick 64 guard 128 RETURN (up: the jump,
#                     down: the crouch)
#   tap MASK          the same for 0.1 s, then released
#   frames N          wait until the game has shown N more frames
#   wait SECONDS      emulated seconds
#   shot NAME         screenshot NAME.png (with SHOT=1)
#   poke LABEL VALUE  a byte of RAM; poke16 for a word (LABEL or LABEL+OFFSET)
#   expect LABEL OP VALUE   log "E PASS|FAIL ..." (a byte; expect16 for a word)
#   prof SECONDS      frames shown and frame time over that long
#   log TEXT
# Log (log.txt): "<time> <event>" lines; "END" last.
set throttle off
set mute on
set ::shots [expr {[info exists ::env(SHOT)] && $::env(SHOT) eq "1"}]
if {!$::shots} { set renderer none }
catch { set save_settings_on_exit off }

source $::env(LABELS)
set ::dir $::env(OUTDIR)
set ::log [open "$::dir/log.txt" w]
fconfigure $::log -buffering line

proc t {} { format %.3f [machine_info time] }
proc adr {name} {
  if {[regexp {^(\w+)\+(\d+)$} $name -> n o]} { return [expr {$::A($n) + $o}] }
  return $::A($name)
}
proc rd {name {o 0}} { debug read memory [expr {[adr $name] + $o}] }
proc rd16 {name {o 0}} { expr {[rd $name $o] | ([rd $name [expr {$o + 1}]] << 8)} }
proc rds16 {name {o 0}} { set v [rd16 $name $o]; expr {$v >= 32768 ? $v - 65536 : $v} }
proc wr {name v {o 0}} { debug write memory [expr {[adr $name] + $o}] [expr {$v & 255}] }
proc wr16 {name v} { wr $name $v; wr $name [expr {$v >> 8}] 1 }
proc say {s} { puts $::log "[t] $s" }
proc finish {} { say END; close $::log; exit }

proc status {} {
  set s "frames=[rd16 st_frames] state=[rd gm_state] demo=[rd gm_demo] msg=[rd gm_msg] cam=[rds16 cam_x] axis=[rd gm_axis] geo=[rd st_geo]"
  foreach f {ft0 ft1} {
    append s " $f: x=[rds16 $f] hp=[rd $f 2] st=[rd $f 3] an=[rd $f 4] pose=[rd $f 7]"
  }
  return $s
}

proc af_poll {} {
  set d [expr {([rd16 st_frames] - $::af_target) & 0xFFFF}]
  if {$d < 0x8000} { step_next } else { after time 0.02 af_poll }
}

proc step_next {} {
  if {$::step_i >= [llength $::steps]} { finish; return }
  set st [string trim [lindex $::steps $::step_i]]
  incr ::step_i
  set a [lassign $st cmd]
  switch -- $cmd {
    keys    { wr dbg_in [lindex $a 0]; step_next }
    tap     { wr dbg_in [lindex $a 0]; after time 0.1 { wr dbg_in 0; after time 0.05 step_next } }
    frames  {
      set ::af_target [expr {([rd16 st_frames] + [lindex $a 0]) & 0xFFFF}]
      af_poll
    }
    wait    { after time [lindex $a 0] step_next }
    shot    {
      # (without the throttle the emulator skips frames: a still picture
      # would be saved as the last one it happened to draw)
      if {$::shots} {
        set ::throttle on
        after realtime 0.3 [list apply {{name} {
          catch {screenshot -raw "$::dir/$name.png"}
          set ::throttle off
          step_next
        }} [lindex $a 0]]
      } else { step_next }
    }
    poke    { wr [lindex $a 0] [lindex $a 1]; step_next }
    poke16  { wr16 [lindex $a 0] [lindex $a 1]; step_next }
    expect  -
    expect16 {
      lassign $a name op val
      set got [expr {$cmd eq "expect" ? [rd $name] : [rd16 $name]}]
      say "E [expr {[expr "$got $op $val"] ? "PASS" : "FAIL"}] $name = $got (want $op $val)"
      step_next
    }
    prof    {
      # frames a second, and the work of a frame: from fb_work (the page is
      # free) to frame_end (the picture is done), split at the marks between
      set ::pf_f [rd16 st_frames]
      set ::pf_t [machine_info time]
      set ::pf_marks {fb_work logic hud_bars scene_draw geo_wait msg_draw frame_end}
      set ::pf_bp {}
      set ::pf_last -1
      set ::pf_name ""
      array unset ::pf_sum
      array unset ::pf_max
      set ::pf_t0 -1
      set ::pf_n 0
      set ::pf_w 0
      set ::pf_wmax 0
      foreach m $::pf_marks { lappend ::pf_bp [debug set_bp $::A($m) {} "pf_hit $m"] }
      after time [lindex $a 0] {
        foreach b $::pf_bp { debug remove_bp $b }
        set f [expr {([rd16 st_frames] - $::pf_f) & 0xFFFF}]
        set d [expr {[machine_info time] - $::pf_t}]
        say [format "PROF frames=%d in %.2f s: %.1f fps; work avg=%.1f ms max=%.1f ms" $f $d [expr {$f / $d}] \
          [expr {1000.0 * $::pf_w / ($::pf_n ? $::pf_n : 1)}] [expr {1000.0 * $::pf_wmax}]]
        foreach m $::pf_marks {
          if {[info exists ::pf_sum($m)]} {
            say [format "PROF   %-11s avg=%5.2f ms max=%5.2f ms" $m [expr {1000.0 * $::pf_sum($m) / $::pf_n}] [expr {1000.0 * $::pf_max($m)}]]
          }
        }
        step_next
      }
    }
    vram    {
      lassign $a x y n
      set s ""
      for {set i 0} {$i < $n} {incr i} { append s [format " %02x" [debug read VRAM [expr {$y * 256 + $x + $i}]]] }
      say "V $x,$y:$s R1=[format %02x [debug read {VDP regs} 1]] R2=[format %02x [debug read {VDP regs} 2]] R8=[format %02x [debug read {VDP regs} 8]]"
      step_next
    }
    log     { say "L $a [status]"; step_next }
    ""      { step_next }
    default { say "E FAIL unknown step: $st"; step_next }
  }
}

proc pf_hit {m} {
  set now [machine_info time]
  if {$m eq "fb_work"} {
    set ::pf_t0 $now
  } elseif {$::pf_t0 >= 0 && $::pf_last >= 0} {
    set d [expr {$now - $::pf_last}]
    set k $::pf_name
    if {![info exists ::pf_sum($k)]} { set ::pf_sum($k) 0; set ::pf_max($k) 0 }
    set ::pf_sum($k) [expr {$::pf_sum($k) + $d}]
    if {$d > $::pf_max($k)} { set ::pf_max($k) $d }
    if {$m eq "frame_end"} {
      set w [expr {$now - $::pf_t0}]
      set ::pf_w [expr {$::pf_w + $w}]
      if {$w > $::pf_wmax} { set ::pf_wmax $w }
      incr ::pf_n
    }
  }
  set ::pf_last $now
  set ::pf_name $m
}

set ::steps [split $::env(SCRIPT) ";"]
set ::step_i 0
# the BIOS logo and the boot take about 4 emulated seconds
after time 4 step_next
