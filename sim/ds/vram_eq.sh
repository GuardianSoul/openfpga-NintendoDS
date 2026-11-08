#!/bin/sh
# nds_vram (the working tree, or RTL_ROOT's copy) against the version at REF,
# cycle by cycle, with the core's VR_* settings (sim/ds/tb_vram_eq.sv).
#   vram_eq.sh VERILATOR BUILD_DIR [REF] [RTL_ROOT]
# EQ_SEEDS (default "1 2 3"), EQ_CYCLES (default 2,000,000).
set -e
V=$1; B=$2; REF=${3:-HEAD}; R=${4:-.}
mkdir -p $B
git show $REF:rtl/ds/nds_vram.sv | sed 's/^module nds_vram\b/module nds_vram_old/' > $B/nds_vram_old.sv
$V --binary --timing -O2 -j 4 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINMISSING \
   --top-module tb_vram_eq --Mdir $B/obj rtl/gpu2d/gpu2d_pkg.sv $B/nds_vram_old.sv $R/rtl/ds/nds_vram.sv sim/ds/tb_vram_eq.sv \
   > $B/build.log 2>&1 || { grep -E "%Error" $B/build.log | head; exit 1; }
fail=0
for s in ${EQ_SEEDS:-1 2 3}; do
  out=$($B/obj/Vtb_vram_eq +seed=$s +cycles=${EQ_CYCLES:-2000000} 2>&1 | grep -E "^vram_eq|^PASS|^FAIL|^MISMATCH|nds_vram" | head -4 | tr '\n' ' ')
  echo "seed $s: $out"
  case "$out" in *PASS*) ;; *) fail=1 ;; esac
done
exit $fail
