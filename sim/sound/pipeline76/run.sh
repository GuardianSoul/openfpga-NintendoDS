#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
out=${1:-$root/build/sound/pipeline76}
mkdir -p "$out"
cp "$root/rtl/sound/sound_job_pipe.sv" "$out/job.sv"
if [[ ${MUTATE_CONTEXT:-0} == 1 ]]; then
    sed -i 's/decode_tag<=dt1;/decode_tag<=dt1 ^ 24\x27h400000;/' "$out/job.sv"
    cmp -s "$root/rtl/sound/sound_job_pipe.sv" "$out/job.sv" && exit 2
fi
v=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
"$v" --binary --timing --assert -j 1 -O2 -Wno-fatal -Wno-PINMISSING -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -I"$root/rtl/sound" --top-module tb_job_pipe --Mdir "$out/obj" \
    "$root/rtl/ds/nds_dsp_add.sv" "$root/rtl/sound/sound_ram.sv" \
    "$root/rtl/sound/sound_event_timers.sv" "$root/rtl/sound/sound.sv" \
    "$out/job.sv" "$root/sim/sound/pipeline76/tb_job_pipe.sv" >"$out/build.log" 2>&1
"$out/obj/Vtb_job_pipe" >"$out/run.log" 2>&1
cat "$out/run.log"
