#!/usr/bin/env bash
# nds_psram_port (rtl/pocket/nds_x2b.sv) against its version at REF (default
# origin/main), cycle by cycle behind psx_psram_pair (tb_port_eq.sv).
#   port_eq.sh [REF] [seeds] [reqs] [RTL file to test instead of rtl/pocket/nds_x2b.sv]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-origin/main}; seeds=${2:-10}; reqs=${3:-3000}; dut=${4:-rtl/pocket/nds_x2b.sv}
out=build/port_eq; rm -rf "$out"; mkdir -p "$out"
git show "$ref:rtl/pocket/nds_x2b.sv" | sed -n '/^module nds_psram_port /,/^endmodule/p' \
    | sed 's/^module nds_psram_port /module nds_psram_port_ref /' > "$out/port_ref.sv"
grep -q "module nds_psram_port_ref" "$out/port_ref.sv"
verilator --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-MULTIDRIVEN \
    --top-module tb_port_eq --Mdir "$out/obj" rtl/mem/psx_pq_psram.sv rtl/mem/psx_psram_pair.sv "$dut" "$out/port_ref.sv" \
    sim/phase1/cram_model.sv sim/phase1/sim_prims.sv sim/pocket/psram_eq/tb_port_eq.sv > "$out/build.log" 2>&1 \
    || { grep -E "%Error" "$out/build.log" | head; exit 1; }
pass=0
for s in $(seq 1 "$seeds"); do
    "$out/obj/Vtb_port_eq" +seed=$s +reqs=$reqs | grep -E "^(PASS|FAIL)|ERROR" | tail -2 | tee -a "$out/runs.log" | grep -q '^PASS' && pass=$((pass + 1)) || true
done
echo "port_eq: $pass/$seeds PASS"
[ "$pass" = "$seeds" ]
