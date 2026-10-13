#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alex Moncks
# run_tests.sh - runs the cartridge in openMSX (the V9968 + geo3d fork) and checks it
#
#   run_tests.sh [scenario ...]     default: boot demo play
#     boot     the title, then the demo starts by itself: the fighters walk in
#     demo     the machine against itself for a while: someone loses life,
#              a round ends and the next one starts
#     play     player 1: walks, punches, kicks, guards
#     prof     frames per second in the demo
#     shots    SHOT=1: pictures of a demo round (no checks)
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

script_of() {
  case $1 in
    boot)
      echo "wait 1;log title;expect gm_demo == 0;wait 7;log demo;expect gm_demo == 1;expect st_geo == 1;expect16 st_frames > 2;wait 3;log walked in;expect16 st_frames > 60" ;;
    demo)     # the title (6 s), the walk in and two rounds at most
      echo "wait 12;log fight;expect gm_state == 3;wait 25;log later;expect16 st_frames > 600;wait 40;log end;expect st_geo == 1" ;;
    play)     # the trigger at the title: player 1 against the machine
      # (ft1+14 = 0: the other fighter stands still)
      echo "wait 3;tap 16;wait 0.5;expect gm_demo == 0;poke ft1+14 0;wait 5;log fight;expect gm_state == 3;poke ft1+14 0;poke ft1+8 0;keys 8;wait 1.2;keys 0;log walked;expect16 ft0 > 65400;tap 16;wait 0.5;log punched;expect ft1+2 == 91;tap 32;wait 0.8;log kicked;expect ft1+2 == 77;keys 64;wait 0.4;expect ft0+4 == 5;keys 0;wait 0.3;keys 4;wait 0.5;keys 0;log back;expect16 ft0 < 65500" ;;
    prof)
      echo "wait 12;prof 10;log prof" ;;
    title)    # the title's text is in VRAM and on show
      echo "wait 2.5;shot title;vram 40 44 24;vram 0 0 4;log title" ;;
    shots)
      echo "wait 3;shot title;wait 5;shot walk_in;wait 2;shot round;wait 1.5;shot fight0;wait 1;shot fight1;wait 1;shot fight2;wait 1;shot fight3;wait 2;shot fight4;wait 3;shot fight5;wait 4;shot fight6;poke ft1+2 1;wait 2.5;shot ko;wait 2.5;shot win" ;;
    *) echo "unknown scenario $1" >&2; exit 2 ;;
  esac
}

rc=0
for scen in ${@:-boot demo play}; do
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
