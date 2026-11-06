#!/usr/bin/env bash
# nds_io equivalence against REF (sim/ds/io_eq/tb_io_eq.sv): io_eq.sh [REF=HEAD] [cycles]
# MUTATE_EXPR='<sed expr>' mutates the new side's nds_io.sv first.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
ref=${1:-HEAD}; cycles=${2:-2000000}
verilator=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
work=$root/build/io_eq; rm -rf "$work"; mkdir -p "$work"
git -C "$root" show "$ref:rtl/ds/nds_io.sv" | sed -E 's/^module nds_io\b/module old_nds_io/; s/\bnds_sdp_ram\b/nds_sdp_ram/' > "$work/old.sv"
cp "$root/rtl/ds/nds_io.sv" "$work/new.sv"
if [ -n "${MUTATE_EXPR:-}" ]; then
    before=$(md5sum < "$work/new.sv"); sed -i -e "$MUTATE_EXPR" "$work/new.sv"
    [ "$before" != "$(md5sum < "$work/new.sv")" ] || { echo "mutation did not change nds_io.sv" >&2; exit 2; }
fi
"$verilator" --binary --timing -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module tb_io_eq --Mdir "$work/obj" \
    "$root/rtl/ds/nds_ram.sv" "$work/old.sv" "$work/new.sv" "$root/sim/ds/io_eq/tb_io_eq.sv" > "$work/v.log" 2>&1 || { tail -20 "$work/v.log"; exit 2; }
echo "nds_io against $(git -C "$root" rev-parse --short "$ref")${MUTATE_EXPR:+ (mutated: $MUTATE_EXPR)}"
"$work/obj/Vtb_io_eq" +cycles=$cycles | grep -E "^ *(EQUIVALENT|DIFFER|cycle)"
