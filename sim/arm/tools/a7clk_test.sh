#!/usr/bin/env bash
# arm7_ds clock by clock against an earlier revision on tb_a7arch's hashed code (sim/arm/tb_a7clk.sv): for RTL changes
# that keep the ARM7's timing (every output equal at every clock, the same answers to both).
#   a7clk_test.sh REF [episodes] [seeds] [MUT_SED]   MUT_SED: a sed expression planted in the new side, which must fail
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
ref=${1:?REF} episodes=${2:-200} seeds=${3:-"1 2 3"} mut=${4:-}
verilator=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
d=$root/build/a7clk/${mut:+mut}obj; mkdir -p "$d"; rm -rf "${d:?}"/*
git -C "$root" show "$ref:rtl/arm/arm7_ds.sv" | sed -e "s/^module arm7_ds /module arm7_ref /" > "$d/arm7_ref.sv"
cp "$root/rtl/arm/arm7_ds.sv" "$d/arm7_new.sv"
[ -z "$mut" ] || { sed -i "$mut" "$d/arm7_new.sv"; cmp -s "$d/arm7_new.sv" "$root/rtl/arm/arm7_ds.sv" && { echo "mutation changed nothing"; exit 2; }; }
def=; grep -q "g_rfm" "$d/arm7_new.sv" && def=-DNEW_RFM
"$verilator" --binary --timing -O2 -j 8 -Wno-fatal -DSYNTHESIS $def --x-initial 0 --x-assign 0 --top-module tb_a7clk --Mdir "$d" \
  -o Vclk "$root/rtl/arm/arm_pkg.sv" "$root/rtl/arm/arm_thumb.sv" "$d/arm7_ref.sv" "$d/arm7_new.sv" "$root/sim/arm/tb_a7clk.sv" > "$d/build.log" 2>&1 || { grep -m8 %Error "$d/build.log"; exit 1; }
rc=0
for s in $seeds; do "$d/Vclk" +seed=$s +episodes=$episodes 2>&1 | grep -E 'DIFF|episodes,|TEST|arm7_ds' | head -20 | cut -c1-230 || true; done | tee "$d/out.txt"
grep -qE 'TEST FAILED|arm7_ds (RFRA|RFQ|RABR)' "$d/out.txt" && rc=1
exit $rc
