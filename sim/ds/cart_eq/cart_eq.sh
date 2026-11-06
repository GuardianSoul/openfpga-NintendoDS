#!/usr/bin/env bash
# nds_cart (rtl/ds/nds_cart.sv) against its version at REF (default origin/main),
# clock by clock on random register traffic (tb_cart_eq.sv).
#   cart_eq.sh [REF] [seeds] [ops] [RTL file to test instead of rtl/ds/nds_cart.sv]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-origin/main}; seeds=${2:-10}; ops=${3:-2000}; dut=${4:-rtl/ds/nds_cart.sv}
out=build/cart_eq; rm -rf "$out"; mkdir -p "$out"
git show "$ref:rtl/ds/nds_cart.sv" | sed 's/^module nds_cart /module nds_cart_ref /' > "$out/cart_ref.sv"
grep -q "module nds_cart_ref" "$out/cart_ref.sv"
verilator --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
    --top-module tb_cart_eq --Mdir "$out/obj" "$dut" "$out/cart_ref.sv" sim/ds/cart_eq/tb_cart_eq.sv > "$out/build.log" 2>&1 \
    || { grep -E "%Error" "$out/build.log" | head; exit 1; }
pass=0
for s in $(seq 1 "$seeds"); do
    "$out/obj/Vtb_cart_eq" +seed=$s +ops=$ops | grep -E "^(PASS|FAIL)|ERROR" | tail -3 | tee -a "$out/runs.log" | grep -q '^PASS' && pass=$((pass + 1)) || true
done
echo "cart_eq: $pass/$seeds PASS"
[ "$pass" = "$seeds" ]
