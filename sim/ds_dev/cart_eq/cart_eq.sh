#!/usr/bin/env bash
# nds_cart equivalence: the working tree's rtl/ds/nds_cart.sv (or a mutant)
# against REF (default HEAD). cart_eq.sh [REF] [seeds] [ops] [new.sv]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-HEAD}; seeds=${2:-20}; ops=${3:-20000}; src=${4:-rtl/ds/nds_cart.sv}
out=build/cart_eq/$(basename "$src" .sv); mkdir -p "$out"; rm -f "$out/runs.log"
git show "$ref:rtl/ds/nds_cart.sv" | sed 's/^module nds_cart\b/module nds_cart_ref/' > "$out/ref.sv"
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
    --top-module tb_cart_eq --Mdir "$out/obj" "$src" "$out/ref.sv" rtl/ds/nds_dsp_add.sv sim/ds_dev/cart_eq/tb_cart_eq.sv \
    "$PWD/sim/ds_dev/cart_eq/cart_eq.cpp" > "$out/build.log" 2>&1 || { grep -E "%Error" "$out/build.log" | head; exit 1; }
pass=0
for s in $(seq 1 "$seeds"); do
    "$out/obj/Vtb_cart_eq" --seed "$s" --ops "$ops" | tail -1 | tee -a "$out/runs.log" | grep -q '^PASS' && pass=$((pass + 1)) || true
done
echo "cart_eq: $pass/$seeds PASS"
[ "$pass" = "$seeds" ]
