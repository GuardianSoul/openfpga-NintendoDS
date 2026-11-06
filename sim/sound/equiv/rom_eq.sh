#!/usr/bin/env bash
# ADPCM ROM equivalence (docs/sound.md, "M10K"): the FIFO RAM's step table and
# sound_adpcm_step against the 1024-word ROM at 89d3622, every address.
# rom_eq.sh [sound_ram.sv]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
src=${1:-rtl/sound/sound_ram.sv}; out=build/rom_eq/$(basename "$src" .sv); mkdir -p "$out"
git show 89d3622:rtl/sound/sound_ram.sv | sed -E 's/^module (sound_[a-z_]+)\b/module \1_ref/' > "$out/ref.sv"
verilator --binary --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module tb_rom_eq \
    --Mdir "$out/obj" "$src" "$out/ref.sv" sim/sound/equiv/tb_rom_eq.sv > "$out/build.log" 2>&1 \
    || { tail -20 "$out/build.log"; exit 1; }
"$out/obj/Vtb_rom_eq" | grep -E "^(PASS|FAIL)" | tee /dev/stderr | grep -q "^PASS"
