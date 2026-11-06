#!/usr/bin/env bash
# nds_sdram_xport/nds_sdram_bport (rtl/pocket/nds_sdram_bus.sv) against their versions at REF (default
# origin/main), clock by clock (tb_xp_eq.sv), with clk_mem's start shifted over a sweep of phases.
#   xp_eq.sh [REF] [seeds] [ops] [RTL file to test instead of rtl/pocket/nds_sdram_bus.sv]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-origin/main}; seeds=${2:-8}; ops=${3:-2000}; dut=${4:-rtl/pocket/nds_sdram_bus.sv}
out=build/xp_eq; rm -rf "$out"; mkdir -p "$out"
git show "$ref:rtl/pocket/nds_sdram_bus.sv" | awk '/^module nds_sdram_(xport|bport) /{p=1} p; /^endmodule/{p=0}' \
    | sed -E 's/^module (nds_sdram_xport|nds_sdram_bport) /module \1_ref /' > "$out/ref.sv"
grep -q "module nds_sdram_xport_ref" "$out/ref.sv"; grep -q "module nds_sdram_bport_ref" "$out/ref.sv"
verilator --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-MULTIDRIVEN \
    --top-module tb_xp_eq --Mdir "$out/obj" rtl/pocket/nds_cdc.sv "$dut" "$out/ref.sv" sim/pocket_ds/xp_eq/tb_xp_eq.sv > "$out/build.log" 2>&1 \
    || { grep -E "%Error" "$out/build.log" | head; exit 1; }
pass=0; total=0
for phase in 0 1 2486 4972 4973 7000 9945; do
    for s in $(seq 1 "$seeds"); do
        total=$((total + 1))
        "$out/obj/Vtb_xp_eq" +seed=$s +ops=$ops +phase=$phase | grep -E "^(PASS|FAIL)|ERROR" | tail -4 | tee -a "$out/runs.log" | grep -q '^PASS' && pass=$((pass + 1)) || true
    done
done
echo "xp_eq: $pass/$total PASS"
[ "$pass" = "$total" ]
