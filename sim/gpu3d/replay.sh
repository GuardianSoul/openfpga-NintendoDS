#!/usr/bin/env bash
# Real-game check for the renderer: turns a census GX trace into scenes with
# tools/melonds-census gx2scene (melonDS's geometry engine replays the trace),
# then diffs every scene RTL vs melonDS with --profile, in parallel.
# Usage: sim/gpu3d/replay.sh <gx.bin> <scene-dir> [tb args...]
# Needs tools/melonds-census/build.sh and the testbench (make test-gpu3d).
# Exit 0 when every scene is pixel-exact; results in <scene-dir>/results.txt.
set -euo pipefail
trace=$1; dir=$2; shift 2
root=$(cd "$(dirname "$0")/../.." && pwd)
"$root/build/census-melonds/build/gx2scene" "$trace" "$dir" | tail -1
tb=$root/build/gpu3d/obj/Vgpu3d_raster
rm -rf "$dir/out"; mkdir -p "$dir/out"
# one log per batch: parallel writers to one file would interleave lines
ls "$dir"/*.scn | xargs -n 8 -P "$(nproc)" sh -c \
  'tb=$1; out=$2; shift 2; a=; for f; do a="$a --scene $f"; done; "$tb" --profile --out "$out" '"$*"' $a > "$out/batch.$$.log"' \
  _ "$tb" "$dir/out" || true
cat "$dir"/out/batch.*.log > "$dir/results.txt"
ok=$(grep -c '^ok' "$dir/results.txt" || true); bad=$(grep -c '^FAIL' "$dir/results.txt" || true)
echo "$ok/$((ok + bad)) scenes pixel-exact"
[ "$bad" = 0 ] && [ "$ok" -gt 0 ]
