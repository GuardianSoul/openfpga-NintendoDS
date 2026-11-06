#!/usr/bin/env bash
# nds_psram with B8 = 1 against REF's (tb_b8_eq.sv), clock by clock at the DS
# port and the chip pins, on cram_model chips.
#   b8_eq.sh [REF=HEAD] [seeds] [reqs]   MUTATE_EXPR='<sed>' mutates the new side
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-HEAD}; seeds=${2:-8}; reqs=${3:-3000}
out=build/b8_eq; rm -rf "$out"; mkdir -p "$out"
git show "$ref:rtl/pocket/nds_psram.sv" | sed -E 's/^module nds_psram\b/module old_nds_psram/' > "$out/old.sv"
cp rtl/pocket/nds_psram.sv "$out/new.sv"
[ -z "${MUTATE_EXPR:-}" ] || sed -i -e "$MUTATE_EXPR" "$out/new.sv"
verilator --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-MULTIDRIVEN \
    --top-module tb_b8_eq --Mdir "$out/obj" rtl/mem/psx_pq_psram.sv "$out/old.sv" "$out/new.sv" \
    sim/phase1/cram_model.sv sim/phase1/sim_prims.sv sim/pocket/psram_eq/tb_b8_eq.sv > "$out/build.log" 2>&1 \
    || { grep -E "%Error" "$out/build.log" | head >&2; exit 2; }
pass=0
for s in $(seq 1 "$seeds"); do
    "$out/obj/Vtb_b8_eq" +seed=$s +reqs=$reqs | grep -E "^(PASS|FAIL)" | tail -1 | tee -a "$out/runs.log" | grep -q '^PASS' && pass=$((pass + 1)) || true
done
echo "b8_eq against $(git rev-parse --short "$ref")${MUTATE_EXPR:+ (mutated)}: $pass/$seeds PASS"
[ "$pass" = "$seeds" ]
