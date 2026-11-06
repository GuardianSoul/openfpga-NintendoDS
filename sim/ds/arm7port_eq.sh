#!/bin/sh
# nds_arm7_port against its version at REF (default HEAD), cycle by cycle
# (sim/ds/tb_arm7port_eq.sv), at the cache sizes in use (IL/DL 7/6), the
# small ones (5/4), and those with the tag stores in MLAB, two seeds each.
#   arm7port_eq.sh VERILATOR BUILD_DIR [REF] [RTL_DIR]
set -e
V=$1; B=$2; REF=${3:-HEAD}; R=${4:-rtl/ds}
mkdir -p $B
git show $REF:rtl/ds/nds_arm7_port.sv | sed 's/^module nds_arm7_port /module nds_arm7_port_ref /' > $B/nds_arm7_port_ref.sv
grep -q "module nds_arm7_port_ref" $B/nds_arm7_port_ref.sv
LIB="rtl/gpu2d/gpu2d_ram.sv rtl/gpu3d/gpu3d_ram.sv rtl/ds/nds_ram.sv"
[ -f $R/nds_lcache.sv ] && LIB="$LIB $R/nds_lcache.sv"
git show $REF:rtl/ds/nds_lcache.sv > $B/nds_lcache_ref.sv 2>/dev/null || true
fail=0
for sz in "7 6" "5 4" "5 4 MLAB"; do
  set -- $sz
  d=$B/il$1$3
  mkdir -p $d
  $V --binary -j 8 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-MULTIDRIVEN \
     --top-module tb_arm7port_eq -GIL=$1 -GDL=$2 $( [ -n "$3" ] && echo "-GTAG_STYLE=\"$3\"" ) -Mdir $d $LIB $R/nds_arm7_port.sv $B/nds_arm7_port_ref.sv \
     sim/ds/tb_arm7port_eq.sv > $d/verilator.log 2>&1 || { grep -E "%Error" $d/verilator.log | head -20; exit 1; }
  for s in 1 2; do
    out=$($d/Vtb_arm7port_eq +cycles=${EQ_CYCLES:-1000000} +seed=$s 2>&1 | grep -E "^arm7port_eq|^PASS|^FAIL|^cycle|nds_lcache:" | head -6 | tr '\n' ' ')
    echo "$out"
    case "$out" in *PASS*) ;; *) fail=1 ;; esac
    case "$out" in *nds_lcache:*) fail=1 ;; esac
  done
done
exit $fail
