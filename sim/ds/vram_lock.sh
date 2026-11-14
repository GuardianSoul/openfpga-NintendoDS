#!/bin/sh
# nds_vram (rtl/ds/nds_vram.sv, WQ_FE 1) in lockstep against its version at REF (sim/ds/tb_vram_lock.sv): the card's
# parameters, random requests on every port, every output every clock; seeds 1-5.
#   vram_lock.sh BUILD_DIR REF [EXTRA_VERILATOR_ARGS]     (e.g. +define+VRAM_WQFE_MUT: the mutant, must FAIL)
set -e
B=$1; REF=$2; X=${3:-}
V=${VERILATOR:-$(dirname "$0")/../../tools/verilator-locked}
mkdir -p $B
git show $REF:rtl/ds/nds_vram.sv | sed 's/^module nds_vram$/module nds_vram_ref/' > $B/ref.sv
grep -q "^module nds_vram_ref" $B/ref.sv
$V --binary -j 8 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-MULTIDRIVEN $X \
   --top-module tb_vram_lock -Mdir $B/obj rtl/gpu2d/gpu2d_pkg.sv $B/ref.sv rtl/ds/nds_vram.sv sim/ds/tb_vram_lock.sv \
   > $B/verilator.log 2>&1 || { grep -E "%Error" $B/verilator.log | head -20; exit 1; }
fail=0
for s in 1 2 3 4 5; do
  out=$($B/obj/Vtb_vram_lock +seed=$s +cycles=${EQ_CYCLES:-400000} 2>&1 | grep -E "^VRAMLOCK|^PASS|^FAIL|^DIFF|%Error" | head -4 | tr '\n' ' ')
  echo "$out"
  case "$out" in *PASS*) ;; *) fail=1 ;; esac
done
exit $fail
