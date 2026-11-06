#!/usr/bin/env bash
# Geometry engine regression (docs/geometry-engine.md): the census GX traces
# and synthetic seeds, RTL vs melonDS, in parallel.
#   sim/gpu3d/geom_regress.sh [SEEDS=40] [FRAMES=30] [traces...]
# Logs and a summary in build/geom/runs/. Exit 0 when nothing differs.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
seeds=${1:-40}; frames=${2:-30}; shift 2 2>/dev/null || shift $#
tb=${GEOM_TB:-$root/build/geom/obj/Vgpu3d_geom}
out=${GEOM_OUT:-$root/build/geom/runs}
mkdir -p "$out"; rm -f "$out"/*.log
traces=("$@")
[ ${#traces[@]} -eq 0 ] && traces=($(ls "$root"/build/census/{kh358,heartgold}/gx.bin "$root"/build/census/replay/*/gx.bin 2>/dev/null))
jobs=()
for t in "${traces[@]}"; do jobs+=("trace $t"); done
for s in $(seq 1 "$seeds"); do jobs+=("synth $s"); done
printf '%s\n' "${jobs[@]}" | xargs -P "${JOBS:-$(nproc)}" -I{} sh -c '
  set -- {}; kind=$1; arg=$2
  if [ "$kind" = trace ]; then name=$(echo "$arg" | sed "s|.*/census/||; s|/gx.bin||; s|/|-|g"); "'"$tb"'" --trace "$arg" > "'"$out"'/trace-$name.log" 2>&1
  else "'"$tb"'" --synth '"$frames"' --seed "$arg" > "'"$out"'/synth-$arg.log" 2>&1; fi
  echo "exit $?" >> "'"$out"'/$( [ "$kind" = trace ] && echo trace-$name || echo synth-$arg ).log"'
bad=0
for f in "$out"/*.log; do
  if ! grep -q "^exit 0" "$f"; then bad=$((bad + 1)); echo "FAIL $(basename "$f"): $(grep -v '^exit' "$f" | tail -1)"; fi
done
grep -h "frames, " "$out"/trace-*.log
echo "$(ls "$out"/*.log | wc -l) runs, $bad failed"
[ $bad -eq 0 ]
