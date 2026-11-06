#!/usr/bin/env bash
# nds_io's sound stub: ARM7 0x4000520-0x40007FF read 0 with the sound engine (tb_io_stub.sv).
#   io_stub.sh [nds_io.sv]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
src=${1:-rtl/ds/nds_io.sv}; out=build/io_stub/$(basename "$src" .sv); mkdir -p "$out"
verilator --binary --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
    --top-module tb_io_stub --Mdir "$out/obj" rtl/ds/nds_ram.sv "$src" sim/ds_dev/io_stub/tb_io_stub.sv > "$out/build.log" 2>&1 \
    || { grep -E "%Error" "$out/build.log" | head; exit 1; }
"$out/obj/Vtb_io_stub" | grep -E "^(PASS|FAIL)|SOUND" | tee /dev/stderr | grep -q "^PASS"
