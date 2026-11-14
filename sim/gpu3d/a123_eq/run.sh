#!/usr/bin/env bash
# Run the a1-a3 lockstep set, one run at a time: sim/gpu3d/a123_eq/run.sh TB OUTDIR
# Each line: the run, tb_geom's result line, the lockstep's totals; PASS needs no %Error, 0 differ against
# melonDS (traces and synth) and 0 differing clocks for a1, a2 and a3.
set -uo pipefail
tb=$1 out=$2; mkdir -p "$out"; C=/home/user/Git/NDS_Pocket/build/census; A=build/a123eq
runs=()
for f in $A/gxmax/*.gx.bin; do runs+=("$(basename $f .gx.bin)|--trace $f --frames 4"); done
for t in kh358 heartgold replay/hg-ow replay/hg-battle replay/mkds replay/nsmb replay/platinum-ow; do runs+=("$(echo $t | tr / -)|--trace $C/$t/gx.bin --frames 31"); done
for s in 1 2 3 4 5 6; do runs+=("synth$s|--synth 30 --seed $s" "wild$s|--synth 30 --seed $s --wild"); done
runs+=("burnout-race|--trace $C/burnout/gx-race/gx.bin --frames 22" "burnout-forest|--trace $C/burnout/gx-forest/gx.bin --frames 17")
runs+=("hooh-title|--trace $A/scenes/hg-title/gx.bin --frames 17" "nsmb-busy|--trace $A/scenes/nsmb-busy/gx.bin --frames 17" "nsmb-11|--trace $A/scenes/nsmb-11/gx.bin --frames 17")
runs+=("hg-ow-title300|--trace $C/replay/hg-ow/gx.bin --frames 300")
for t in mkds-heavy-ss-gx mkds-race-ss-gx gsdd-battle gsdd-continue hg-goldenrod kh-plaza kh-halloween ff4-newgame smoke-gx; do runs+=("$t|--trace $C/$t/gx.bin --frames 17"); done
for s in 1 2 3; do [ -f $A/packgaps$s.rwlog ] || python3 sim/gpu3d/a123_eq/packgaps.py $A/packgaps$s.rwlog $s 20000 >/dev/null; runs+=("packgaps$s|--rwlog $A/packgaps$s.rwlog"); done
for r in "${runs[@]}"; do
  n=${r%%|*}; a=${r#*|}
  timeout 3600 $tb $a > "$out/$n.log" 2>&1; rc=$?
  eq=$(grep "^A123EQ clocks" "$out/$n.log" | tail -1)
  res=$(grep -E "differ|frames|lines" "$out/$n.log" | grep -v "^A123EQ" | tail -1 | cut -c1-110)
  err=$(grep -c "%Error\|A123EQ a[123]" "$out/$n.log")
  ok=PASS; { [ $rc -ne 0 ] || [ $err -ne 0 ] || ! echo "$eq" | grep -q "a1 0, a2 0, a3 0 " || echo "$res" | grep -qE "[1-9][0-9]* differ"; } && ok=FAIL
  echo "$ok $n rc$rc | $res | ${eq#A123EQ }"
done | tee "$out/summary.txt"
