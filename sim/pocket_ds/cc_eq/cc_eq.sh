#!/usr/bin/env bash
# nds_cart_cache (rtl/pocket/nds_cart_cache.sv) against its version at REF (default origin/main), clock by
# clock (tb_cc_eq.sv), with 64 slots (constant evictions) and the Pocket's 12,288.
#   cc_eq.sh [REF] [seeds] [ops] [RTL file to test instead of rtl/pocket/nds_cart_cache.sv]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-origin/main}; seeds=${2:-10}; ops=${3:-3000}; dut=${4:-rtl/pocket/nds_cart_cache.sv}
out=build/cc_eq; rm -rf "$out"; mkdir -p "$out"
git show "$ref:rtl/pocket/nds_cart_cache.sv" | sed 's/^module nds_cart_cache /module nds_cart_cache_ref /' > "$out/cc_ref.sv"
grep -q "module nds_cart_cache_ref" "$out/cc_ref.sv"
pass=0; total=0
for slots in 64 12288; do
    verilator --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -GSLOTS=$slots \
        --top-module tb_cc_eq --Mdir "$out/obj$slots" "$dut" "$out/cc_ref.sv" sim/pocket_ds/cc_eq/tb_cc_eq.sv > "$out/build$slots.log" 2>&1 \
        || { grep -E "%Error" "$out/build$slots.log" | head; exit 1; }
    for s in $(seq 1 "$seeds"); do
        total=$((total + 1))
        "$out/obj$slots/Vtb_cc_eq" +seed=$s +ops=$ops | grep -E "^(PASS|FAIL|cc_eq:)|ERROR" | tail -4 | sed "s/^/[$slots slots] /" | tee -a "$out/runs.log" | grep -q 'PASS' && pass=$((pass + 1)) || true
    done
done
echo "cc_eq: $pass/$total PASS"
[ "$pass" = "$total" ]
