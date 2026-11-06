#!/usr/bin/env bash
# arm7_ds instruction by instruction against an earlier revision on hashed code (sim/arm/tb_a7arch.sv).
# Three things in the reference are put right first: a Thumb BL's target kept LR's bit 0 (an odd PC, and so odd links); a
# Thumb STMIA with an empty list stored PC + 12, not PC + 6; a shift by register or multiply with a BL's second half in D
# read r14 for its Rs (hashed code only: BL's first half comes between them in a program).
#   a7arch_test.sh REF [episodes] [seeds] [MUT_SED]   MUT_SED: a sed expression planted in the new side, which must fail
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
ref=${1:?REF} episodes=${2:-200} seeds=${3:-"1 2 3"} mut=${4:-}
verilator=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
d=$root/build/a7arch/${mut:+mut}obj; mkdir -p "$d"; rm -rf "${d:?}"/*
git -C "$root" show "$ref:rtl/arm/arm7_ds.sv" | sed -e "s/^module arm7_ds /module arm7_ref /" \
  -e "s/{alu\[31:2\], 2'b00}) : sum;/{alu[31:2], 2'b00}) : {sum[31:1], 1'b0};/" \
  -e "s/st == S_BLKR2 ? 32'd12 :/st == S_BLKR2 ? (tbit ? 32'd6 : 32'd12) :/" \
  -e "s/^\( *\)d_bl2 ? 4'd14 :$/\1(d_bl2 \&\& !(e_sr \&\& esub == 2'd0) \&\& !(e_mul \&\& esub == 2'd0)) ? 4'd14 :/" > "$d/arm7_ref.sv"
cp "$root/rtl/arm/arm7_ds.sv" "$d/arm7_new.sv"
[ -z "$mut" ] || { sed -i "$mut" "$d/arm7_new.sv"; cmp -s "$d/arm7_new.sv" "$root/rtl/arm/arm7_ds.sv" && { echo "mutation changed nothing"; exit 2; }; }
"$verilator" --binary --timing -O2 -j 8 -Wno-fatal -DSYNTHESIS --x-initial 0 --x-assign 0 --top-module tb_a7arch --Mdir "$d" \
  -o Varch "$root/rtl/arm/arm_pkg.sv" "$root/rtl/arm/arm_thumb.sv" "$d/arm7_ref.sv" "$d/arm7_new.sv" "$root/sim/arm/tb_a7arch.sv" > "$d/build.log" 2>&1 || { grep -m8 %Error "$d/build.log"; exit 1; }
rc=0
for s in $seeds; do "$d/Varch" +seed=$s +episodes=$episodes | grep -E 'DIFF|episodes,|TEST' | cut -c1-210 || true; done | tee "$d/out.txt"
grep -q 'TEST FAILED' "$d/out.txt" && rc=1
exit $rc
