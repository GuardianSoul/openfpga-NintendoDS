#!/bin/sh
# nds_lcache PUMP = 1 against PUMP = 0 (sim/ds/tb_lcache_pump.sv): nds_g3d_cache2's texture
# (LB 8, TW 8) and palette (LB 6, TW 3: few tags, many hits) tag stores, three seeds each; then
# the mutants: the phase inverted (ph), and the check read at the middle edge with the write
# at E (the order swapped). Each mutant must fail.
#   lcache_pump.sh VERILATOR BUILD_DIR
set -u
V=$1; B=$2
mkdir -p $B
build() {   # DIR LB TW LCACHE
    $V --binary --timing -j 8 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL --top-module tb_lcache_pump \
       -GLB=$2 -GTW=$3 -Mdir $B/$1 $4 rtl/gpu3d/gpu3d_ram.sv sim/ds/tb_lcache_pump.sv > $B/$1.log 2>&1 || { tail -20 $B/$1.log; exit 1; }
}
sed 's/ph <= tg == tq;/ph <= tg != tq;/' rtl/ds/nds_lcache.sv > $B/mut_ph.sv
sed 's/\.b_addr(ph ? bwa : c_idx), \.b_we(ph \&\& bw)/.b_addr(!ph ? bwa : c_idx), .b_we(!ph \&\& bw)/' rtl/ds/nds_lcache.sv > $B/mut_ord.sv
cmp -s $B/mut_ph.sv rtl/ds/nds_lcache.sv && { echo "mutant ph not applied"; exit 1; }
cmp -s $B/mut_ord.sv rtl/ds/nds_lcache.sv && { echo "mutant ord not applied"; exit 1; }
build t 8 8 rtl/ds/nds_lcache.sv & build p 6 3 rtl/ds/nds_lcache.sv & build mph 8 8 $B/mut_ph.sv & wait
build mord 8 8 $B/mut_ord.sv
fail=0
for d in t p; do for s in 1 2 3; do
    o=$($B/$d/Vtb_lcache_pump +cycles=200000 +seed=$s 2>&1 | grep -E "^lcache pump|%Error|nds_lcache:" | head -3)
    echo "$o"; case "$o" in *"-> PASS"*) ;; *) fail=1 ;; esac
    case "$o" in *Error*|*nds_lcache:*) fail=1 ;; esac
done; done
for d in mph mord; do
    o=$($B/$d/Vtb_lcache_pump +cycles=200000 +seed=1 2>&1 | grep -E "^lcache pump|^MISMATCH|%Error" | head -2 | tr '\n' ' ')
    echo "mutant $d: $o"; case "$o" in *"-> PASS"*) fail=1 ;; esac
done
exit $fail
