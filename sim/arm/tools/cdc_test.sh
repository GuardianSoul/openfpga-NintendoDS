#!/bin/sh
# Two-clock test of rtl/arm/cdc_req.sv and cdc_fifo.sv (sim/arm/tb_cdc.sv) at
# several clock ratios, the CPU_FAST ones (89.37 vs 67.03 MHz) among them.
#   cdc_test.sh VERILATOR BUILD_DIR [RTL_DIR]
set -e
V=$1; B=$2; R=${3:-rtl/arm}
mkdir -p $B
$V --binary -j 8 -O2 --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module tb_cdc \
   -Mdir $B $R/cdc_req.sv $R/cdc_fifo.sv sim/arm/tb_cdc.sv > $B/verilator.log 2>&1 || { tail -20 $B/verilator.log; exit 1; }
fail=0
for a in "+pm=11190 +ps=14920" "+pm=14920 +ps=11190" "+pm=10000 +ps=10000" "+pm=7000 +ps=23000 +seed=3" \
         "+pm=23000 +ps=7000 +seed=4" "+pm=11190 +ps=11191 +seed=5" "+pm=5000 +ps=14920 +seed=6"; do
  out=$($B/Vtb_cdc $a | grep -E "PASS|FAIL" | head -1)
  echo "$out ($a)"
  case "$out" in *PASSED*) ;; *) fail=1 ;; esac
done
exit $fail
