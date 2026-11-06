#!/usr/bin/env bash
# psx_psram_pair LIVE_REQ=1 against LIVE_REQ=0 behind nds_psram_port (tb_psram_eq.sv).
#   psram_eq.sh [seeds] [reqs] [extra plusargs, e.g. +mutant]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
seeds=${1:-10}; reqs=${2:-3000}; extra=${3:-}
out=build/psram_eq; mkdir -p "$out"
verilator --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
    --top-module tb_psram_eq --Mdir "$out/obj" rtl/mem/psx_pq_psram.sv rtl/mem/psx_psram_pair.sv rtl/pocket/nds_x2b.sv \
    sim/phase1/cram_model.sv sim/phase1/sim_prims.sv sim/pocket/psram_eq/tb_psram_eq.sv > "$out/build.log" 2>&1 \
    || { grep -E "%Error" "$out/build.log" | head; exit 1; }
pass=0
for s in $(seq 1 "$seeds"); do
    "$out/obj/Vtb_psram_eq" +seed=$s +reqs=$reqs $extra | grep -E "^(PASS|FAIL)|ERROR" | tail -2 | tee -a "$out/runs.log" | grep -q '^PASS' && pass=$((pass + 1)) || true
done
echo "psram_eq: $pass/$seeds PASS"
[ "$pass" = "$seeds" ]
