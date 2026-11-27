#!/usr/bin/env bash
# nds_arm7_port in clock-exact lockstep with an earlier revision, plus a data scoreboard (sim/arm/tb_p7lock.sv).
#   p7lock_test.sh REF [cycles] [seeds] [GPARAMS] [MUT_SED]
#     GPARAMS: verilator -G settings for the bench, e.g. "-GIL=6 -GDL=5 -GIW=4 -GDW=4 -GLOCK=0" (LOCK=0: no
#              reference, the scoreboard only: for way counts the old port does not have)
#     MUT_SED: a sed expression planted in the new port, which must fail
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
ref=${1:?REF} cycles=${2:-2000000} seeds=${3:-"1 2 3"} gp=${4:-} mut=${5:-}
verilator=${VERILATOR:-$root/tools/verilator-locked}
[ -x "$verilator" ] || verilator=build/tools/oss-cad-suite/bin/verilator
tag=$(echo "$gp $mut" | md5sum | cut -c1-8)
d=$root/build/p7lock/$tag; mkdir -p "$d"; rm -rf "${d:?}"/*
# the reference port with the reference revision's nds_lcache (renamed), so an unpumped change in it is caught too
git -C "$root" show "$ref:rtl/ds/nds_arm7_port.sv" | sed -e "s/^module nds_arm7_port #/module nds_arm7_port_ref #/" -e "s/\bnds_lcache #/nds_lcache_ref #/g" > "$d/p7_ref.sv"
git -C "$root" show "$ref:rtl/ds/nds_lcache.sv" | sed "s/^module nds_lcache\b/module nds_lcache_ref/" > "$d/lcache_ref.sv"
cp "$root/rtl/ds/nds_arm7_port.sv" "$d/p7_new.sv"
cp "$root/rtl/ds/nds_lcache.sv" "$d/lcache.sv"
# MUT_FILE=lcache plants MUT_SED in nds_lcache (both ports use the mutated copy then: the reference must stay unpumped)
mf=$d/p7_new.sv; of=$root/rtl/ds/nds_arm7_port.sv
[ "${MUT_FILE:-port}" = lcache ] && { mf=$d/lcache.sv; of=$root/rtl/ds/nds_lcache.sv; }
[ -z "$mut" ] || { sed -i "$mut" "$mf"; cmp -s "$mf" "$of" && { echo "mutation changed nothing"; exit 2; }; }
files="$d/lcache.sv $d/lcache_ref.sv $root/rtl/gpu2d/gpu2d_ram.sv $root/rtl/ds/nds_ram.sv $root/rtl/gpu3d/gpu3d_ram.sv"
"$verilator" --binary -O3 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -DSYNTHESIS --x-initial 0 --x-assign 0 \
  --top-module tb_p7lock $gp --Mdir "$d" -o Vp7 $files "$d/p7_ref.sv" "$d/p7_new.sv" "$root/sim/arm/tb_p7lock.sv" \
  >"$d/build.log" 2>&1 || { tail -30 "$d/build.log"; exit 3; }
rc=0
for s in $seeds; do "$d/Vp7" +seed=$s +cycles=$cycles | grep -E 'DIFF|ERROR|p7lock|TEST|new |ref ' | cut -c1-240 || true; done | tee "$d/out.txt"
grep -q 'TEST FAILED' "$d/out.txt" && rc=1
exit $rc
