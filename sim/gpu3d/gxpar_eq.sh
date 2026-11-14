#!/usr/bin/env bash
# GX_PAR equivalence against the current engine (docs/geometry-engine-par.md "Build plan"): the reference tb_geom
# (GX_PAR 0) and the new one run the same inputs; both must be exact against melonDS (0 differ) and their polygon
# record streams (--podump: every header and beat with its words, every sort output, in order, no cycles) must be
# byte-identical.
#   sim/gpu3d/gxpar_eq.sh REF_TB NEW_TB [SEEDS=3] [FRAMES=30] [TRACE...]   (each seed plain and --wild)
# JOBS (default 2) runs at once. Prints one line a run; exit 0 when every run matches.
set -uo pipefail
ref=$1 new=$2 seeds=${3:-3} frames=${4:-30}; shift 4 2>/dev/null || shift $#
out=${GXEQ_OUT:-$(mktemp -d)}; mkdir -p "$out"
jobs=()
for t in "$@"; do jobs+=("trace $t"); done
for s in $(seq 1 "$seeds"); do jobs+=("synth $s" "wild $s"); done
printf '%s\n' "${jobs[@]}" | xargs -P "${JOBS:-2}" -I{} bash -c '
  set -- {}; kind=$1; arg=$2; n=$(echo "$arg" | sed "s|.*/census/||; s|/gx.bin$||; s|.*/||; s|.gx.bin$||; s|/|-|g")
  if [ "$kind" = trace ]; then a=(--trace "$arg" --frames '"$((frames + 1))"'); elif [ "$kind" = wild ]; then a=(--synth '"$frames"' --seed "$arg" --wild); n=wild$arg; else a=(--synth '"$frames"' --seed "$arg"); n=synth$arg; fi
  "'"$ref"'" "${a[@]}" --podump "'"$out"'/$n.ref" > "'"$out"'/$n.ref.log" 2>&1; r1=$?
  "'"$new"'" "${a[@]}" --podump "'"$out"'/$n.new" > "'"$out"'/$n.new.log" 2>&1; r2=$?
  d1=$(grep -o "[0-9]* differ" "'"$out"'/$n.ref.log" | head -1); d2=$(grep -o "[0-9]* differ" "'"$out"'/$n.new.log" | head -1)
  if cmp -s "'"$out"'/$n.ref" "'"$out"'/$n.new"; then eq=same; else eq="STREAMS DIFFER at line $(cmp "'"$out"'/$n.ref" "'"$out"'/$n.new" 2>/dev/null | awk "{print \$NF}")"; fi
  echo "$n: ref rc$r1 ($d1), new rc$r2 ($d2), records $(wc -l < "'"$out"'/$n.ref"): $eq"
  [ "$eq" = same ] && rm -f "'"$out"'/$n.ref" "'"$out"'/$n.new"' | sort | tee "$out/summary.txt"
! grep -qv "rc0 (0 differ), new rc0 (0 differ), records [0-9]*: same" "$out/summary.txt"
