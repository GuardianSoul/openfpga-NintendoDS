#!/usr/bin/env bash
# core_bridge_cmd_lean equivalence against REF (tb_cmd_eq.sv).
#   cmd_eq.sh [REF=HEAD] [seeds=3]; MUTATE_EXPR='<sed expr>' mutates this tree's copy.
set -euo pipefail
cd "$(dirname "$0")/../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-HEAD}; seeds=${2:-3}; out=build/cmd_eq; rm -rf "$out"; mkdir -p "$out"
git show "$ref:rtl/apf/core_bridge_cmd_lean.v" | sed 's/^module core_bridge_cmd_lean\b/module core_bridge_cmd_lean_ref/' > "$out/ref.v"
cp rtl/apf/core_bridge_cmd_lean.v "$out/new.v"
if [ -n "${MUTATE_EXPR:-}" ]; then sed -i -e "$MUTATE_EXPR" "$out/new.v"; cmp -s rtl/apf/core_bridge_cmd_lean.v "$out/new.v" && { echo "mutation did not change it"; exit 2; }; fi
verilator --binary --timing -j 8 -Wno-fatal -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-PINMISSING -Wno-CASEX -Wno-BLKANDNBLK --top-module tb_cmd_eq --Mdir "$out/obj" \
    "$out/new.v" "$out/ref.v" rtl/apf/common.v sim/probe/mf_datatable_model.sv sim/apf/tb_cmd_eq.sv > "$out/build.log" 2>&1 || { grep -E "%Error" "$out/build.log" | head; exit 1; }
rc=0
for s in $(seq 1 "$seeds"); do "$out/obj/Vtb_cmd_eq" +seed=$s > "$out/run$s.log" 2>&1 || true; grep -E 'PASS|FAIL|differ' "$out/run$s.log" | tail -3 | cut -c1-150; grep -q '^PASS' "$out/run$s.log" || rc=1; done
exit $rc
