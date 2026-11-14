#!/bin/sh
# rtl/ds/nds_disp_refs.sv against the registers it replaces
# (sim/ds/tb_disp_refs.sv): CPU writes every 2 and every 3 clocks, two seeds.
#   disp_refs_test.sh VERILATOR BUILD_DIR [RTL_DIR]
# FE=1 in the environment: the DUT with FE=1 (tb_disp_refs TB_FE); FES=0 with it: FE_S 0 (TB_FES0, the card's)
set -e
V=$1; B=$2; R=${3:-rtl/ds}
mkdir -p $B
$V --binary -j 8 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL --top-module tb_disp_refs $( [ "${FE:-0}" = 1 ] && echo +define+TB_FE ) $( [ "${FES:-1}" = 0 ] && echo +define+TB_FES0 ) \
   -Mdir $B $R/nds_disp_refs.sv sim/ds/tb_disp_refs.sv > $B/verilator.log 2>&1 || { tail -20 $B/verilator.log; exit 1; }
fail=0
for a in "+gap=2 +seed=1" "+gap=2 +seed=2" "+gap=3 +seed=3"; do
  out=$($B/Vtb_disp_refs +cycles=1000000 $a 2>&1 | grep -E "^disp_refs|^PASS|^FAIL|^cycle|nds_disp_refs:" | head -4 | tr '\n' ' ')
  echo "$out"
  case "$out" in *PASS*) ;; *) fail=1 ;; esac
  case "$out" in *nds_disp_refs:*) fail=1 ;; esac
done
exit $fail
