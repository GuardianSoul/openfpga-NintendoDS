#!/usr/bin/env bash
# run.sh <outdir> <flags> <prec> <scene-dir>...: approx_cmp over every scene, in parallel,
# one result file per scene dir
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd); t=$root/build/approx/approx_cmp
o=$1 fl=$2 pr=$3; shift 3; mkdir -p "$o"
for d in "$@"; do
  n=$(basename "$d")
  ls "$d"/*.scn | xargs -n 8 -P "$(nproc)" "$t" --flags "$fl" --prec "$pr" > "$o/$n.txt"
done
