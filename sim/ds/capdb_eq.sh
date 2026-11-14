#!/bin/sh
# nds_vram CAP_DB=1 against CAP_DB=0: same capture halfword stream, same VRAM contents (sim/ds/tb_capdb_eq.sv).
#   capdb_eq.sh VERILATOR BUILD_DIR    EQ_SEEDS (default "1 2 3"), EQ_N (halfwords, default 200000), EQ_VFLAGS
set -e
V=$1; B=$2
mkdir -p $B
$V --binary --timing -O2 -j 4 ${EQ_VFLAGS:-} -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINMISSING \
   --top-module tb_capdb_eq --Mdir $B/obj rtl/gpu2d/gpu2d_pkg.sv rtl/ds/nds_vram.sv rtl/ds/nds_ram.sv sim/ds/tb_capdb_eq.sv \
   > $B/build.log 2>&1 || { grep -E "%Error" $B/build.log | head; exit 1; }
fail=0
for s in ${EQ_SEEDS:-1 2 3}; do
  out=$($B/obj/Vtb_capdb_eq +seed=$s +n=${EQ_N:-200000} 2>&1 | grep -E "^capdb_eq|^PASS|^FAIL|^MISMATCH" | head -6 | tr '\n' ' ')
  echo "seed $s: $out"
  case "$out" in *PASS*) ;; *) fail=1 ;; esac
done
exit $fail
