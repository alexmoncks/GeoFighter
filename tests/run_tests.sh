#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alex Moncks
# run_tests.sh - runs the cartridge in openMSX (the V9968 + geo3d fork) and checks it
#
#   run_tests.sh [scenario ...]     default: boot demo play moves
#     boot     the title, then the demo starts by itself: the fighters walk in
#     demo     the machine against itself for a while: someone loses life,
#              a round ends and the next one starts
#     play     player 1: walks, punches, kicks, guards
#     moves    player 1: crouch, low punch, sweep, jump, flying kick, punch
#              from above, sidesteps; what each guard stops
#     skip     the trigger cuts the opening shot short
#     prof     frames per second in the demo
#     shots    SHOT=1: pictures of a demo round (no checks)
#     shotsmoves   SHOT=1: pictures of the special moves
#   PROFILE=88 runs the 88h ROM on a machine with the V9968 cartridge
#   (-ext HRA_V9968 -ext geo3d88); MACHINE=... picks another machine.
#   SHOT=1 opens a window and saves the `shot` pictures.
# OPENMSX=... picks the emulator: a Windows build (its arguments become
# Windows paths) or a Linux build. Writes out/test/<scenario>/ (log.txt,
# PNGs). Exit 1 on a failure.
cd "$(dirname "$0")/.."
OPENMSX=${OPENMSX:-/mnt/c/Projects/mmsoft/openmsx-geo3d/openmsx.exe}
PROFILE=${PROFILE:-98}
[ -f out/GEOFIGHTER_$PROFILE.ROM ] || { echo "build first (build.sh)"; exit 2; }
if [ "$PROFILE" = 88 ]; then
  args="-machine ${MACHINE:-C-BIOS_MSX2+} -ext HRA_V9968 -ext geo3d88"
else
  args="-machine ${MACHINE:-C-BIOS_V9968_JP} -ext geo3d"
fi
export SHOT=${SHOT:-0}
case "$OPENMSX" in
  *.exe) w() { wslpath -m "$(realpath "$1")"; } ;;
  *)     w() { realpath "$1"; }
         export SDL_AUDIODRIVER=dummy
         [ "$SHOT" = 1 ] || export SDL_VIDEODRIVER=${SDL_VIDEODRIVER:-dummy} ;;
esac

# walk up to the other fighter (it gives way no further than MIN_SEP)
W="keys 8;wait 0.4;keys 0;wait 0.1"
# down held, then with it the kick (34) or the punch (18): the low moves
low() { echo "keys 2;wait 0.3;keys $1;wait 0.1;keys 2;wait 0.8;keys 0;wait 0.2"; }
# the picture of a moment: the logic stops while it is taken
snap() { echo "poke dbg_freeze 1;shot $1;poke dbg_freeze 0"; }

script_of() {
  case $1 in
    boot)     # the title, then the demo starts by itself with the opening shot
      echo "wait 1;log title;expect gm_demo == 0;wait 7;log demo;expect gm_demo == 1;expect st_geo == 1;expect gm_state == 0;wait 1;expect16 st_frames > 20;wait 6;log fight;expect gm_state == 3" ;;
    demo)     # the title (6 s), the opening shot (4 s) and two rounds at most
      echo "wait 15;log fight;expect gm_state == 3;wait 25;log later;expect16 st_frames > 600;wait 40;log end;expect st_geo == 1" ;;
    play)     # the trigger at the title: player 1 against the machine
      # (ft1+14 = 0: the other fighter stands still)
      echo "wait 3;tap 16;wait 0.5;expect gm_demo == 0;expect gm_state == 0;poke ft1+14 0;wait 7;log fight;expect gm_state == 3;keys 8;wait 1.2;keys 0;log walked;expect16 ft0 > 65400;tap 16;wait 0.5;log punched;expect ft1+2 == 91;tap 32;wait 0.8;log kicked;expect ft1+2 == 77;keys 64;wait 0.4;expect ft0+4 == 5;keys 0;wait 0.3;keys 4;wait 0.5;keys 0;log back;expect16 ft0 < 65500" ;;
    moves)    # player 1 against a fighter that stands still: the crouch and
      # its low moves, the jump and the attacks from it, the sidesteps
      # (the ring turns: gm_axis), then what each guard stops (ft1+8 is
      # the other one's intent: 4 the standing guard, 8 the crouch)
      echo "wait 3;tap 16;wait 0.5;poke ft1+14 0;tap 16;wait 3.5;log fight;expect gm_state == 3;\
$W;keys 2;wait 0.3;expect ft0+4 == 10;keys 0;wait 0.2;\
$(low 34);log sweep;expect ft1+2 == 88;\
$W;$(low 18);log lowpunch;expect ft1+2 == 82;\
tap 1;expect ft0+3 == 6;wait 0.9;log jump;expect ft0+3 == 0;expect ft1+2 == 82;\
$W;keys 33;wait 0.1;keys 0;wait 0.2;expect ft0+4 == 15;wait 0.7;log flyingkick;expect ft1+2 == 66;\
$W;tap 1;tap 16;wait 0.9;log punchabove;expect ft1+2 == 54;\
tap 1;wait 0.05;tap 1;wait 0.1;expect ft0+3 == 7;wait 0.6;log stepup;expect gm_axis == 120;expect ft0+3 == 0;\
tap 2;wait 0.05;tap 2;wait 0.7;log stepdown;expect gm_axis == 0;\
poke ft1+8 4;wait 0.3;expect ft1+4 == 5;\
$W;$(low 34);log sweep_guard;expect ft1+2 == 42;\
$W;tap 16;wait 0.6;log punch_guard;expect ft1+2 == 42;\
poke ft1+8 8;wait 0.4;expect ft1+4 == 10;\
$W;tap 16;wait 0.6;log punch_crouch;expect ft1+2 == 42;\
tap 32;wait 0.9;log kick_crouch;expect ft1+2 == 42;\
$W;$(low 34);log sweep_crouch;expect ft1+2 == 42;\
$W;keys 33;wait 0.1;keys 0;wait 0.9;log flyingkick_crouch;expect ft1+2 == 26" ;;
    skip)     # a new press of the trigger cuts the opening shot short
      echo "wait 3;tap 16;wait 1;expect gm_state == 0;tap 16;wait 0.3;log cut;expect gm_state >= 1" ;;
    prof)     # the fight, then (proforbit) the opening shot
      echo "wait 15;prof 8;log prof" ;;
    proforbit)
      echo "wait 6.6;prof 3.3;log orbit" ;;
    title)    # the title's text is in VRAM and on show
      echo "wait 2.5;shot title;vram 40 44 24;vram 0 0 4;log title" ;;
    shots)
      echo "wait 3;shot title;wait 3.3;shot orbit0;wait 0.25;shot orbit1;wait 0.25;shot orbit2;wait 0.25;shot orbit3;wait 0.25;shot orbit4;wait 0.25;shot orbit5;wait 0.25;shot orbit6;wait 0.6;shot round;wait 2;shot fight0;wait 1.5;shot fight1;wait 2;shot fight2;wait 3;shot fight3;poke ft1+2 1;wait 1.6;shot ko;wait 1.6;shot win" ;;
    shotsmoves)   # SHOT=1: pictures of the special moves
      echo "wait 3;tap 16;wait 0.5;poke ft1+14 0;tap 16;wait 3.5;$W;\
keys 2;wait 0.3;$(snap crouch);keys 34;wait 0.1;keys 2;wait 0.13;$(snap sweep);wait 0.7;\
keys 18;wait 0.1;keys 2;wait 0.07;$(snap lowpunch);wait 0.6;keys 0;wait 0.2;\
tap 1;wait 0.2;$(snap jump);wait 0.6;\
$W;keys 33;wait 0.1;keys 0;wait 0.27;$(snap flyingkick);wait 0.6;\
$W;keys 17;wait 0.1;keys 0;wait 0.27;$(snap punchabove);wait 0.6;\
tap 1;wait 0.05;tap 1;wait 0.02;$(snap step1);wait 0.6;$(snap turned1);\
tap 1;wait 0.05;tap 1;wait 0.7;tap 1;wait 0.05;tap 1;wait 0.7;$(snap turned3);\
tap 2;wait 0.05;tap 2;wait 0.02;$(snap stepdown)" ;;
    *) echo "unknown scenario $1" >&2; exit 2 ;;
  esac
}

rc=0
for scen in ${@:-boot demo play moves}; do
  dir=out/test/${scen}${TAG:+_$TAG}
  rm -rf "$dir"
  mkdir -p "$dir"
  awk -F'[:\t$ ]+' '/^[A-Za-z_0-9]+:\tequ \$/ { printf "set ::A(%s) 0x%s\n", $1, $NF }' \
    out/labels_$PROFILE.txt > "$dir/labels.tcl"
  export LABELS="$(w "$dir/labels.tcl")" OUTDIR="$(w "$dir")"
  export SCRIPT="$(script_of $scen)"
  export WSLENV=LABELS:OUTDIR:SCRIPT:SHOT
  rom="$(w out/GEOFIGHTER_$PROFILE.ROM)"
  script="$(w tests/run.tcl)"
  (cd "$(dirname "$OPENMSX")" && timeout 900 "./$(basename "$OPENMSX")" $args \
     -cart "$rom" -romtype ASCII16 -script "$script" > "$OLDPWD/$dir/openmsx.txt" 2>&1)
  echo "== $scen ($PROFILE h)"
  if ! grep -q " END" "$dir/log.txt" 2>/dev/null; then echo "FAIL: the run did not end"; tail -3 "$dir/openmsx.txt"; rc=1; continue; fi
  grep -E " E | L | PROF" "$dir/log.txt"
  grep -q " E FAIL" "$dir/log.txt" && rc=1
done
[ $rc = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $rc
