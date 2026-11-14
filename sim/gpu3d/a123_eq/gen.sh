#!/usr/bin/env bash
# a1-a3 lockstep references (docs/gx-area-map.md): the step-before modules, renamed, from git.
#   sim/gpu3d/a123_eq/gen.sh OUTDIR   -> gpu3d_gxeng_r0.sv (base e553da725), gpu3d_gxeng_r1.sv (a1), gpu3d_gxfront_r0.sv (base)
set -euo pipefail
out=$1; mkdir -p "$out"
BASE=${A123_BASE:-e553da725}; A1=${A123_A1:-314601da3}
git show "$BASE:rtl/gpu3d/gpu3d_gxeng.sv"  | sed 's/^module gpu3d_gxeng #/module gpu3d_gxeng_r0 #/' > "$out/gpu3d_gxeng_r0.sv"
git show "$A1:rtl/gpu3d/gpu3d_gxeng.sv"    | sed 's/^module gpu3d_gxeng #/module gpu3d_gxeng_r1 #/' > "$out/gpu3d_gxeng_r1.sv"
git show "$BASE:rtl/gpu3d/gpu3d_gxfront.sv" | sed 's/^module gpu3d_gxfront #/module gpu3d_gxfront_r0 #/; s/^module gpu3d_gxpre (/module gpu3d_gxpre_r0 (/' > "$out/gpu3d_gxfront_r0.sv"
grep -c '^module gpu3d_gx[a-z]*_r[01]' "$out"/*.sv
