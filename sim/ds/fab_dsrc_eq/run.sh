#!/bin/sh
# nds_fabric (the dm_src hit test) against nds_fabric at REF (default 6c8a1bd89), every output every cycle, random inputs
#   sim/ds/fab_dsrc_eq/run.sh VERILATOR BUILD_DIR [REF] [EXTRA_DEFINES]
set -e
V=$1; B=$2; REF=${3:-6c8a1bd89}; X=$4
mkdir -p $B
git show $REF:rtl/ds/nds_fabric.sv | sed 's/^module nds_fabric /module nds_fabric_ref /' > $B/nds_fabric_ref.sv
grep -q "module nds_fabric_ref" $B/nds_fabric_ref.sv
fail=0
for cfg in "1 1" "2 0"; do set -- $cfg
  d=$B/ra$1b8$2; mkdir -p $d
  $V --binary -j 4 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-MULTIDRIVEN $X --top-module tb_fab_dsrc_eq -GRA=$1 -GB8=$2 \
     -Mdir $d rtl/gpu2d/gpu2d_pkg.sv rtl/gpu2d/gpu2d_ram.sv rtl/ds/nds_ram.sv rtl/ds/nds_fabric.sv $B/nds_fabric_ref.sv sim/ds/fab_dsrc_eq/tb.sv > $d/verilator.log 2>&1 || { grep -E "%Error" $d/verilator.log | head -20; exit 1; }
  for s in 1 2 3; do
    out=$($d/Vtb_fab_dsrc_eq +cycles=${EQ_CYCLES:-300000} +seed=$s 2>&1 | grep -E "^fab_dsrc_eq|^PASS|^FAIL|ERROR" | head -4 | tr '\n' ' ')
    echo "RA $1 B8 $2 seed $s: $out"
    case "$out" in *PASS*) ;; *) fail=1 ;; esac
  done
done
exit $fail
