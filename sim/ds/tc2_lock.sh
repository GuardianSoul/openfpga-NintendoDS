#!/bin/sh
# nds_g3d_cache2 (rtl/ds/nds_gpu3d.sv) in lockstep against its version at REF (sim/ds/tb_tc2_lock.sv), at the card's
# texture cache (AW 19, LW 9, 4 ways, PUMP, QL 4, NF 2) and palette cache (AW 17, LW 7, 1 way) sizes; seeds, flushes,
# aliasing sets.   tc2_lock.sh VERILATOR BUILD_DIR REF [EXTRA_VERILATOR_ARGS]
set -e
V=$1; B=$2; REF=$3; X=${4:-}
mkdir -p $B
git show $REF:rtl/ds/nds_gpu3d.sv | sed -n '/^module nds_g3d_cache2 #(/,/^endmodule/p' | sed 's/^module nds_g3d_cache2 /module nds_g3d_cache2_ref /' > $B/ref.sv
sed -n '/^module nds_g3d_cache2 #(/,/^endmodule/p' rtl/ds/nds_gpu3d.sv > $B/new.sv
fail=0
for sz in "19 9 4" "17 7 1"; do
  set -- $sz
  d=$B/aw$1w$3; mkdir -p $d
  $V --binary -j 8 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-MULTIDRIVEN $X \
     --top-module tb_tc2_lock -GAW=$1 -GLW=$2 -GWAYS=$3 -Mdir $d rtl/gpu3d/gpu3d_ram.sv rtl/ds/nds_lcache.sv $B/ref.sv $B/new.sv \
     sim/ds/tb_tc2_lock.sv > $d/verilator.log 2>&1 || { grep -E "%Error" $d/verilator.log | head -20; exit 1; }
  for a in "+seed=1" "+seed=2" "+seed=3 +flush=8" "+seed=4 +alias" "+seed=5 +alias +flush=400"; do
    out=$($d/Vtb_tc2_lock +cycles=${EQ_CYCLES:-500000} $a 2>&1 | grep -E "^TC2LOCK|^PASS|^FAIL|%Error" | head -6 | tr '\n' ' ')
    echo "$1/$3 $a: $out"
    case "$out" in *PASS*) ;; *) fail=1 ;; esac
  done
done
exit $fail
