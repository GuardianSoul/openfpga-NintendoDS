#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0
root=$(cd "$(dirname "$0")/../../.." && pwd)
out=${1:-$root/build/sound/pipeline76-restore}
mkdir -p "$out"
out=$(cd "$out" && pwd)
python3 "$root/sim/sound/pipeline76/prepare.py" "$out"
old_pipe=()
if [[ -f "$out/old/old_sound_pipe_group.sv" ]]; then
    old_pipe=(-DOLD_PIPE_REFERENCE "$out/old/old_sound_job_pipe.sv" "$out/old/old_sound_pipe_group.sv")
fi
v=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
"$v" --binary --timing --assert --threads 1 -j 1 -O2 -Wno-fatal -Wno-PINMISSING -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -I"$out" -I"$out/old" -I"$out/frozen/rtl/sound" -I"$out/frozen/sim/pocket_ds" -I"$out/frozen/sim/sound" \
    --top-module tb_pipe_restore --Mdir "$out/obj" \
    "$root/rtl/ds/nds_dsp_add.sv" "${old_pipe[@]}" \
    "$out/old/old_sound_ram.sv" "$out/old/old_sound_event_timers.sv" "$out/old/old_sound.sv" \
    "$out/frozen/rtl/sound/sound_ram.sv" "$out/frozen/rtl/sound/sound_event_timers.sv" "$out/frozen/rtl/sound/sound.sv" \
    "$out/frozen/rtl/sound/sound_job_pipe.sv" "$out/frozen/rtl/sound/sound_pipe_group.sv" \
    "$out/frozen/sim/sound/pipeline76/tb_pipe_restore.sv" >"$out/build.log" 2>&1
"$out/obj/Vtb_pipe_restore" >"$out/run.log" 2>&1
cat "$out/run.log"
