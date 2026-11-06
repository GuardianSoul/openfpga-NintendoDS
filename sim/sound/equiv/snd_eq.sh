#!/usr/bin/env bash
# Sound engine equivalence (tb_snd_eq.sv): the working tree's rtl/sound
# against REF, side by side. snd_eq.sh [REF=HEAD] [cycles] [seed] [half]
# MUTATE_FILE=<file in rtl/sound> MUTATE_EXPR='<sed expr>' mutates the new side.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
ref=${1:-HEAD} cycles=${2:-2000000} seed=${3:-1} half=${4:-0}
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
work=$root/build/sound/snd_eq; rm -rf "$work"; mkdir -p "$work/old" "$work/new"
for f in sound_ram sound; do
    git -C "$root" show "$ref:rtl/sound/$f.sv" |
        sed -E -e 's/\b(sound_(ram|mlab|cpu_ram|run_ram|capbuf|adpcm_rom|adpcm_step))\b/old_\1/g' -e 's/^module sound\b/module old_sound/' > "$work/old/$f.sv"
    cp "$root/rtl/sound/$f.sv" "$work/new/$f.sv"
done
if [ -n "${MUTATE_FILE:-}" ]; then
    before=$(md5sum "$work/new/$MUTATE_FILE")
    sed -i -e "$MUTATE_EXPR" "$work/new/$MUTATE_FILE"
    [ "$before" != "$(md5sum "$work/new/$MUTATE_FILE")" ] || { echo "mutation did not change $MUTATE_FILE" >&2; exit 2; }
fi
verilator --binary -j 8 -O3 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    --top-module tb_snd_eq --Mdir "$work/obj" "$work"/old/*.sv "$work"/new/*.sv "$root/rtl/ds/nds_dsp_add.sv" "$root/sim/sound/equiv/tb_snd_eq.sv" \
    > "$work/build.log" 2>&1 || { tail -20 "$work/build.log"; exit 2; }
echo "rtl/sound against $(git -C "$root" rev-parse --short "$ref")${MUTATE_FILE:+ (new side mutated: $MUTATE_FILE: $MUTATE_EXPR)}"
"$work/obj/Vtb_snd_eq" +cycles=$cycles +seed=$seed +half=$half | grep -E "^(EQUIVALENT|DIFFER|cycle)"
