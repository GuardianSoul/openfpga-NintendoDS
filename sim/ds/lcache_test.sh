#!/bin/sh
# rtl/ds/nds_lcache.sv against a register valid array (sim/ds/tb_lcache.sv):
# the ARM7 port's use (MODE 0, one-byte tag; in M10K and MLAB), nds_g3d_cache's (MODE 1, G=3,
# two-byte tag) and a harsh one (G=2, a flush every ~10 cycles: generations
# wrap while stale entries are still being scrubbed), three seeds each.
#   lcache_test.sh VERILATOR BUILD_DIR [RTL_DIR]
set -e
V=$1; B=$2; R=${3:-rtl/ds}
fail=0
for cfg in "0 3 3 a" "0 3 3 m MLAB" "1 10 3 b" "1 3 2 c +flush=10"; do
  set -- $cfg
  d=$B/$4
  mkdir -p $d
  $V --binary -j 8 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL --top-module tb_lcache \
     -GMODE=$1 -GTW=$2 -GGB=$3 $( [ "$5" = MLAB ] && echo "-GSTYLE=\"MLAB\"" ) -Mdir $d $R/nds_lcache.sv sim/ds/tb_lcache.sv > $d/verilator.log 2>&1 \
     || { tail -20 $d/verilator.log; exit 1; }
  for s in 1 2 3; do
    out=$($d/Vtb_lcache +cycles=300000 +seed=$s $( [ "$5" != MLAB ] && echo $5 ) 2>&1 | grep -E "^lcache|^PASS|^FAIL|nds_lcache:" | tr '\n' ' ')
    echo "G=$3 $5 $out"
    case "$out" in *PASS*) ;; *) fail=1 ;; esac
    case "$out" in *nds_lcache:*) fail=1 ;; esac
  done
done
exit $fail
