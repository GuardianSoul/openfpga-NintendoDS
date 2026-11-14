#!/usr/bin/env bash
# Run the engine lockstep set (sim/gpu3d/eng_eq/build.sh's tb_geom), one run at a time: run.sh TB OUTDIR [PART/PARTS]
# PASS: no %Error, 0 differ against melonDS, 0 differing clocks against the base engine. The set is a123_eq's
# with the streams on this machine: synth/wild 1-6, the census traces, Burnout race and forest, hg-ow to 300 frames.
set -uo pipefail
tb=$1 out=$2 part=${3:-1/1}; mkdir -p "$out"; C=/home/user/Git/NDS_Pocket/build/census
runs=()
for f in $C/gxmax/*.gx.bin; do runs+=("$(basename $f .gx.bin)|--trace $f --frames 4"); done
for s in 1 2 3 4 5 6; do runs+=("synth$s|--synth 30 --seed $s" "wild$s|--synth 30 --seed $s --wild"); done
for t in kh358 heartgold replay/hg-ow replay/hg-battle replay/mkds replay/nsmb replay/platinum-ow; do
  [ -f $C/$t/gx.bin ] && runs+=("$(echo $t | tr / -)|--trace $C/$t/gx.bin --frames 31"); done
runs+=("burnout-race|--trace $C/burnout/gx-race/gx.bin --frames 22" "burnout-forest|--trace $C/burnout/gx-forest/gx.bin --frames 17")
for t in mkds-heavy-ss-gx mkds-race-ss-gx gsdd-battle gsdd-continue hg-goldenrod kh-plaza kh-halloween ff4-newgame smoke-gx; do
  [ -f $C/$t/gx.bin ] && runs+=("$t|--trace $C/$t/gx.bin --frames 17"); done
runs+=("hg-ow-title300|--trace $C/replay/hg-ow/gx.bin --frames 300")
k=${part%/*} n=${part#*/}; i=0
for r in "${runs[@]}"; do
  i=$((i + 1)); [ $(( (i - 1) % n + 1 )) -eq $k ] || continue
  nm=${r%%|*}; a=${r#*|}
  timeout 3600 $tb $a > "$out/$nm.log" 2>&1; rc=$?
  eq=$(grep "^ENGEQ clocks" "$out/$nm.log" | tail -1)
  res=$(grep -E "differ|frames|lines" "$out/$nm.log" | grep -v "^ENGEQ" | tail -1 | cut -c1-110)
  err=$(grep -c "%Error\|ENGEQ differs" "$out/$nm.log")
  ok=PASS; { [ $rc -ne 0 ] || [ $err -ne 0 ] || ! echo "$eq" | grep -q ": 0 differing" || echo "$res" | grep -qE "[1-9][0-9]* differ"; } && ok=FAIL
  echo "$ok $nm rc$rc | $res | ${eq#ENGEQ }"
done | tee "$out/summary$k.txt"
