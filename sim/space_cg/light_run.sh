#!/bin/bash
# sim/space_cg/light_run.sh [NEW.sv] [TAG]: gpu3d_gxlight NEW.sv (default rtl/gpu3d/gpu3d_gxlight.sv) against
# REF.s (default 669c40c9), cycle for cycle (tb_light.sv), 3M clocks; the build is deleted afterwards (docs/space-cg.md item 5)
cd "$(dirname "$0")/../.."
new=${1:-rtl/gpu3d/gpu3d_gxlight.sv}; tag=${2:-new}
d=build/space_cg/light; o=$d/obj-$tag; mkdir -p $d
git show ${REF:-669c40c9}:rtl/gpu3d/gpu3d_gxlight.sv | sed 's/^module gpu3d_gxlight #(/module gpu3d_gxlight_old #(/' > $d/old.sv
tools/verilator-locked --binary --timing -j 4 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
  --top-module tb_light -Mdir $o rtl/gpu3d/gpu3d_ram.sv $d/old.sv $new sim/space_cg/tb_light.sv \
  > $d/build-$tag.log 2>&1 || { tail $d/build-$tag.log; exit 1; }
$o/Vtb_light +cycles=3000000 > $d/$tag.log 2>&1
echo "$tag: $(grep -c 'two VB' $d/$tag.log) exclusivity errors; $(grep -v '^- ' $d/$tag.log | grep 'cycles,') $(grep -o 'LIGHT [A-Z]*' $d/$tag.log)"
rm -rf $o
