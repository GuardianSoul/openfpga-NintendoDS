#!/usr/bin/env bash
# Build tb_geom at the card's geometry parameters (FF, LUNIT, VFIN 2, USORT, GX_PAR 2, PRE, SPILL with the
# behavioural SDRAM, GATH16, SP_AW 12 (the behavioural SDRAM holds 4,096 entries; the card has 16), DIV_P2X 0) with the a1-a3 lockstep references (lock.svh).
#   sim/gpu3d/a123_eq/build.sh [EXTRA_VERILATOR_ARGS...]   (e.g. -DGXENG_A1_MUT; GEOM_BUILD=... for a separate build)
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd); cd "$root"
ref=${GEOM_BUILD:-build/geom}/a123ref; sim/gpu3d/a123_eq/gen.sh "$ref" >/dev/null
make ${GEOM_BUILD:+GEOM_BUILD=$GEOM_BUILD} GEOM_MELON=${GEOM_MELON:-/home/user/Git/NDS_Pocket/build/census-melonds} \
  GEOM_FF=1 GEOM_LUNIT=1 GEOM_VFIN=2 GEOM_USORT=1 GEOM_PAR=2 GEOM_SPILL=1 \
  GEOM_G="-GGATH16=1 -GSP_AW=12 -GDIV_P2X=0 -DGX_A123_EQ -I$root/sim/gpu3d/a123_eq $root/$ref/gpu3d_gxeng_r0.sv $root/$ref/gpu3d_gxeng_r1.sv $root/$ref/gpu3d_gxfront_r0.sv $*" \
  "${GEOM_BUILD:-build/geom}/obj-lu-vf2-ff-sp-par2/Vgpu3d_geom"
