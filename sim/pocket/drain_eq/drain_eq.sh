#!/usr/bin/env bash
# nds_fifo_drain against REF: drain_eq.sh [REF=HEAD]; MUTATE_EXPR mutates this tree's copy of nds_bus_tests.sv.
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-HEAD}; out=build/drain_eq; rm -rf "$out"; mkdir -p "$out"
ex() { python3 -c "
import re,sys
s=sys.stdin.read(); i=s.index('module nds_fifo_drain'); j=s.index('endmodule',i)+9; print(s[i:j])"; }
git show "$ref:rtl/pocket/nds_bus_tests.sv" | ex | sed 's/^module nds_fifo_drain\b/module nds_fifo_drain_ref/' > "$out/ref.sv"
ex < rtl/pocket/nds_bus_tests.sv > "$out/new.sv"
if [ -n "${MUTATE_EXPR:-}" ]; then cp "$out/new.sv" "$out/b.sv"; sed -i -e "$MUTATE_EXPR" "$out/new.sv"; cmp -s "$out/b.sv" "$out/new.sv" && { echo "mutation did not change it"; exit 2; }; rm "$out/b.sv"; fi
verilator --binary --timing -j 8 -Wno-fatal -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-PINMISSING --top-module tb_drain_eq --Mdir "$out/obj" rtl/pocket/nds_cdc.sv "$out/new.sv" "$out/ref.sv" sim/pocket/drain_eq/tb_drain_eq.sv > "$out/build.log" 2>&1 || { grep -E "%Error" "$out/build.log" | head -5 | cut -c1-200; exit 1; }
"$out/obj/Vtb_drain_eq" | grep -E 'EQUIVALENT|DIFFER|entry ' | tail -3 | cut -c1-130
