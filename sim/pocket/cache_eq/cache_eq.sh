#!/usr/bin/env bash
# nds_cart_cache equivalence: the working tree's cache against REF (default
# HEAD), seeds 1..N. cache_eq.sh [REF] [seeds] [cycles] [new.sv]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-HEAD}; seeds=${2:-20}; cycles=${3:-2000000}; src=${4:-rtl/pocket/nds_cart_cache.sv}
out=build/cache_eq/$(basename "$src" .sv); mkdir -p "$out"
git show "$ref:rtl/pocket/nds_cart_cache.sv" | sed 's/^module nds_cart_cache\b/module nds_cart_cache_ref/' > "$out/ref.sv"
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
    --top-module tb_cache_eq --Mdir "$out/obj" "$src" "$out/ref.sv" sim/pocket/cache_eq/tb_cache_eq.sv \
    "$PWD/sim/pocket/cache_eq/cache_eq.cpp" > "$out/build.log" 2>&1 || { grep -E "%Error" "$out/build.log" | head; exit 1; }
pass=0
for s in $(seq 1 "$seeds"); do
    "$out/obj/Vtb_cache_eq" --seed "$s" --cycles "$cycles" | tail -1 | tee -a "$out/runs.log" | grep -q '^PASS' && pass=$((pass + 1)) || true
done
echo "cache_eq: $pass/$seeds PASS"
[ "$pass" = "$seeds" ]
