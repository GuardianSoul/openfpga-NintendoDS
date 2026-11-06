#!/usr/bin/env bash
# sys_ram64p against sys_ram64be and sys_ram (sim/sys/tb_ram64p.sv).
# MUTATE_EXPR='<sed expr>' mutates sys_ram.sv first (the check must then fail).
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
verilator=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cp "$root/rtl/sys/sys_ram.sv" "$work/"
if [ -n "${MUTATE_EXPR:-}" ]; then
    before=$(md5sum "$work/sys_ram.sv"); sed -i -e "$MUTATE_EXPR" "$work/sys_ram.sv"
    [ "$before" != "$(md5sum "$work/sys_ram.sv")" ] || { echo "mutation did not change sys_ram.sv" >&2; exit 2; }
fi
"$verilator" --binary --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module tb_ram64p --Mdir "$work/obj" \
    "$work/sys_ram.sv" "$root/sim/sys/tb_ram64p.sv" > "$work/v.log" 2>&1 || { tail -20 "$work/v.log"; exit 2; }
"$work/obj/Vtb_ram64p" | tail -6
