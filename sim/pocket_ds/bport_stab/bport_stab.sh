#!/usr/bin/env bash
# tb_bport_stab: bp_cache's request-stability check behind nds_bport_share.
#  fixed rtl:               PASS, no check message (B's read with A's write be on the port is within the contract)
#  rtl before the fix:      PASS but the check reports (the cold-boot message reproduced; not a data fault)
#  fixed rtl, +mut:         the check reports (B moves its address while its read is pending: a real fault)
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
out=build/bport_stab; rm -rf "$out"; mkdir -p "$out/old"
git show "${OLD:-887187e64}":rtl/pocket/nds_sdram_bus.sv > "$out/old/nds_sdram_bus.sv"
for v in new old; do
    bus=rtl/pocket/nds_sdram_bus.sv; [ $v = old ] && bus=$out/old/nds_sdram_bus.sv
    verilator --binary --timing -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-MULTIDRIVEN --top-module tb_bport_stab \
        --Mdir "$out/obj_$v" "$bus" rtl/pocket/nds_bport_share.sv sim/pocket_ds/bport_stab/tb_bport_stab.sv > "$out/build_$v.log" 2>&1 \
        || { grep -E "%Error" "$out/build_$v.log" | head; exit 1; }
done
"$out/obj_new/Vtb_bport_stab" > "$out/new.log"; "$out/obj_old/Vtb_bport_stab" > "$out/old.log"; "$out/obj_new/Vtb_bport_stab" +mut > "$out/mut.log"
c() { grep -c "changed before c_ready" "$1" || true; }
echo "fixed: $(grep -E '^(PASS|FAIL)' $out/new.log), check $(c $out/new.log)"
echo "old:   $(grep -E '^(PASS|FAIL)' $out/old.log), check $(c $out/old.log)"
echo "mut:   check $(c $out/mut.log)"
grep -q '^PASS' "$out/new.log" && [ "$(c $out/new.log)" = 0 ] && grep -q '^PASS' "$out/old.log" && [ "$(c $out/old.log)" != 0 ] && [ "$(c $out/mut.log)" != 0 ]
