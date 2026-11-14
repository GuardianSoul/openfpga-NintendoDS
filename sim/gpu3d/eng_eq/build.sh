#!/usr/bin/env bash
# Build tb_geom at the card's geometry parameters (as sim/gpu3d/a123_eq/build.sh) with u_eng in lockstep against
# ENG_BASE's gpu3d_gxeng (lock.svh here).
#   ENG_BASE=<commit> GEOM_BUILD=build/geom-x sim/gpu3d/eng_eq/build.sh [EXTRA_VERILATOR_ARGS...]
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd); cd "$root"
b=${GEOM_BUILD:-build/geom-engeq}; mkdir -p "$b/engref"
git show "${ENG_BASE:?ENG_BASE}:rtl/gpu3d/gpu3d_gxeng.sv" | sed 's/^module gpu3d_gxeng #/module gpu3d_gxeng_r0 #/' > "$b/engref/gpu3d_gxeng_r0.sv"
make GEOM_BUILD=$b GEOM_MELON=${GEOM_MELON:-/home/user/Git/NDS_Pocket/build/census-melonds} \
  GEOM_FF=1 GEOM_LUNIT=1 GEOM_VFIN=2 GEOM_USORT=1 GEOM_PAR=2 GEOM_SPILL=1 \
  GEOM_G="-GGATH16=1 -GSP_AW=12 -GDIV_P2X=0 -DGX_A123_EQ -I$root/sim/gpu3d/eng_eq $root/$b/engref/gpu3d_gxeng_r0.sv $*" \
  "$b/obj-lu-vf2-ff-sp-par2/Vgpu3d_geom"
