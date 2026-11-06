#!/usr/bin/env bash
# nds_sdram_mc equivalence against REF: mc_eq.sh [REF=HEAD] [seeds=3] [cycles=1000000]; MUTATE_EXPR mutates this tree's copy.
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-HEAD}; seeds=${2:-3}; cycles=${3:-1000000}; out=build/mc_eq; rm -rf "$out"; mkdir -p "$out"
git show "$ref:rtl/pocket/nds_sdram_mc.sv" | sed 's/^module nds_sdram_mc\b/module nds_sdram_mc_ref/' > "$out/ref.sv"
cp rtl/pocket/nds_sdram_mc.sv "$out/new.sv"
if [ -n "${MUTATE_EXPR:-}" ]; then sed -i -e "$MUTATE_EXPR" "$out/new.sv"; cmp -s rtl/pocket/nds_sdram_mc.sv "$out/new.sv" && { echo "mutation did not change it"; exit 2; }; fi
verilator --binary --timing -j 8 -Wno-fatal -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-PINMISSING -Wno-CASEINCOMPLETE '-DCOMMA=,' --top-module tb_mc_eq --Mdir "$out/obj" \
    "$out/new.sv" "$out/ref.sv" sim/phase1/sim_prims.sv sim/pocket/mc_eq/tb_mc_eq.sv > "$out/build.log" 2>&1 || { grep -E "%Error" "$out/build.log" | head -5 | cut -c1-200; exit 1; }
rc=0
for s in $(seq 1 "$seeds"); do "$out/obj/Vtb_mc_eq" +seed=$s +cycles=$cycles > "$out/run$s.log" 2>&1 || true; grep -E 'EQUIVALENT|DIFFER|differ' "$out/run$s.log" | tail -2 | cut -c1-150; grep -q '^EQUIVALENT' "$out/run$s.log" || grep -q 'EQUIVALENT' "$out/run$s.log" || rc=1; done
exit $rc
