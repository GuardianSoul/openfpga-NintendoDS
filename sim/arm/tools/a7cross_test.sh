#!/bin/sh
# The ARM7 port's CPU_FAST crossings (rtl/arm/cdc_a7.sv) with nds_fr_arb and
# a fabric model (sim/arm/tb_a7cross.sv): both ports, several clock ratios.
#   a7cross_test.sh VERILATOR BUILD_DIR [CDC_A7_DIR]
set -e
V=$1; B=$2; R=${3:-rtl/arm}
fail=0
for p in 0 1; do
  mkdir -p $B/p$p
  $V --binary -j 8 -O2 --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-MULTIDRIVEN \
     --top-module tb_a7cross -GPORT=$p -Mdir $B/p$p rtl/arm/cdc_req.sv $R/cdc_a7.sv rtl/ds/nds_fr_arb.sv \
     rtl/gpu2d/gpu2d_ram.sv rtl/gpu3d/gpu3d_ram.sv rtl/ds/nds_ram.sv rtl/ds/nds_lcache.sv rtl/ds/nds_arm7_port.sv \
     rtl/ds/nds_arm7_port_min.sv sim/arm/tb_a7cross.sv > $B/p$p/verilator.log 2>&1 || { tail -20 $B/p$p/verilator.log; exit 1; }
  for a in "+pc=11190 +ps=14920" "+pc=14920 +ps=11190 +seed=2" "+pc=7000 +ps=23000 +seed=3" "+pc=11190 +ps=11191 +seed=4"; do
    out=$($B/p$p/Vtb_a7cross +cycles=200000 $a 2>&1 | grep -E "^a7cross|^PASS|^FAIL|^deadlock|^order" | head -3 | tr '\n' ' ')
    echo "$out"
    case "$out" in *PASS*) ;; *) fail=1 ;; esac
  done
done
exit $fail
