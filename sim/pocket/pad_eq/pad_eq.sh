#!/usr/bin/env bash
# psx_pocket_pad on DS frames against REF's clock counters: pad_eq.sh [REF=HEAD]; MUTATE_EXPR mutates this tree's copy.
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-HEAD}; out=build/pad_eq; rm -rf "$out"; mkdir -p "$out"
git show "$ref:rtl/pocket/psx_pocket_pad_combo.sv" | sed 's/^module psx_pocket_pad\b/module psx_pocket_pad_ref/' > "$out/ref.sv"
cp rtl/pocket/psx_pocket_pad_combo.sv "$out/new.sv"
if [ -n "${MUTATE_EXPR:-}" ]; then sed -i -e "$MUTATE_EXPR" "$out/new.sv"; cmp -s rtl/pocket/psx_pocket_pad_combo.sv "$out/new.sv" && { echo "mutation did not change it"; exit 2; }; fi
verilator --binary --timing -j 8 -Wno-fatal -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-PINMISSING --top-module tb_pad_eq --Mdir "$out/obj" "$out/new.sv" "$out/ref.sv" sim/pocket/pad_eq/tb_pad_eq.sv > "$out/build.log" 2>&1 || { grep -E "%Error" "$out/build.log" | head -5 | cut -c1-200; exit 1; }
"$out/obj/Vtb_pad_eq" | grep -E 'EQUIVALENT|DIFFER|tick ' | tail -3 | cut -c1-130
