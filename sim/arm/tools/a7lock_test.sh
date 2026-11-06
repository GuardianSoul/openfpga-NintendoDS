#!/usr/bin/env bash
# arm7_ds in clock-exact lockstep with an earlier revision on hashed code (sim/arm/tb_a7lock.sv).
#   a7lock_test.sh REF [cycles] [seeds] [MUT_SED]   MUT_SED: a sed expression planted in the new side, which must fail
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
ref=${1:?REF} cycles=${2:-2000000} seeds=${3:-"1 2 3"} mut=${4:-}
verilator=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
d=$root/build/a7lock/${mut:+mut}obj; mkdir -p "$d"; rm -rf "$d"/*
git -C "$root" show "$ref:rtl/arm/arm7_ds.sv" | sed "s/^module arm7_ds /module arm7_ref /; /for (int i = 0; i < 5; i++) spsr\[i\] <= 13'h0;/d" > "$d/arm7_ref.sv"
cp "$root/rtl/arm/arm7_ds.sv" "$d/arm7_new.sv"
[ -z "$mut" ] || { sed -i "$mut" "$d/arm7_new.sv"; cmp -s "$d/arm7_new.sv" "$root/rtl/arm/arm7_ds.sv" && { echo "mutation changed nothing"; exit 2; }; }
"$verilator" --binary --timing -O3 -j 8 -Wno-fatal -DSYNTHESIS --x-initial 0 --x-assign 0 --top-module tb_a7lock --Mdir "$d" \
  -o Vlock "$root/rtl/arm/arm_pkg.sv" "$root/rtl/arm/arm_thumb.sv" "$d/arm7_ref.sv" "$d/arm7_new.sv" "$root/sim/arm/tb_a7lock.sv" >"$d/build.log" 2>&1 || { tail -20 "$d/build.log"; exit 3; }
rc=0
for s in $seeds; do "$d/Vlock" +seed=$s +cycles=$cycles | grep -E 'DIFF|ref |new |states|cycles|TEST' | cut -c1-200 || true; done | tee "$d/out.txt"
grep -q 'TEST FAILED' "$d/out.txt" && rc=1
exit $rc
