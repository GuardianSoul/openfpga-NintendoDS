#!/bin/sh
# nds_g3d_cache (rtl/ds/nds_gpu3d.sv) against its version at REF, on random
# requests and flushes (sim/ds/tb_g3dcache_eq.sv): the texture and palette
# cache sizes, two seeds each, plus a run with a flush every ~8 cycles.
#   g3dcache_eq.sh VERILATOR BUILD_DIR REF [RTL_DIR]
set -e
V=$1; B=$2; REF=$3; R=${4:-rtl/ds}
mkdir -p $B
git show $REF:rtl/ds/nds_gpu3d.sv | sed -n '/^module nds_g3d_cache #(/,/^endmodule/p' \
  | sed 's/^module nds_g3d_cache /module nds_g3d_cache_ref /' > $B/ref.sv
sed -n '/^module nds_g3d_cache/,/^endmodule/p' $R/nds_gpu3d.sv > $B/new.sv
grep -q "module nds_g3d_cache_ref" $B/ref.sv && grep -q "module nds_g3d_cache " $B/new.sv
fail=0
# the new one as built today and with its options (EQ_OPTS: a list of -G sets)
for sz in "19 6" "17 4"; do
 for opt in ${EQ_OPTS:-"-GWAYS=1"}; do
  set -- $sz
  o=$(echo "$opt" | tr ',' ' ')
  d=$B/aw$1$(echo "$opt" | tr -dc 'A-Za-z0-9')
  mkdir -p $d
  $V --binary -j 8 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-MULTIDRIVEN \
     --top-module tb_g3dcache_eq -GAW=$1 -GLW=$2 $o -Mdir $d rtl/gpu3d/gpu3d_ram.sv $R/nds_lcache.sv $B/ref.sv $B/new.sv \
     sim/ds/tb_g3dcache_eq.sv > $d/verilator.log 2>&1 || { grep -E "%Error" $d/verilator.log | head -20; exit 1; }
  for a in "+seed=1" "+seed=2" "+seed=3 +flush=8" "+seed=4 +alias"; do
    out=$($d/Vtb_g3dcache_eq +cycles=${EQ_CYCLES:-500000} $a 2>&1 | grep -E "^g3dcache_eq|^PASS|^FAIL|^cache|^answer|nds_lcache:" | head -6 | tr '\n' ' ')
    echo "$opt $out"
    case "$out" in *PASS*) ;; *) fail=1 ;; esac
    case "$out" in *nds_lcache:*) fail=1 ;; esac
  done
 done
done
exit $fail
