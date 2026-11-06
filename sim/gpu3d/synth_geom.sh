#!/usr/bin/env bash
# Yosys (slang frontend) cost estimate of the geometry engine and its parts.
#   sim/gpu3d/synth_geom.sh [yosys] [outdir]
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
yosys=${1:-build/tools/oss-cad-suite/bin/yosys}; out=${2:-$root/build/geom/synth}
mkdir -p "$out"
src="$root/rtl/gpu3d/gpu3d_gxu_pkg.sv $root/rtl/gpu3d/gpu3d_ram.sv $root/rtl/gpu3d/gpu3d_gxrom.sv $root/rtl/gpu3d/gpu3d_gxrom_us.sv $root/rtl/gpu3d/gpu3d_gxrom_ul.sv $root/rtl/gpu3d/gpu3d_gxrom_uv.sv $root/rtl/gpu3d/gpu3d_gxrom_uw.sv $root/rtl/gpu3d/gpu3d_gxrom_uf.sv $root/rtl/gpu3d/gpu3d_gxlight.sv $root/rtl/gpu3d/gpu3d_gxvfin.sv $root/rtl/gpu3d/gpu3d_gxdiv.sv $root/rtl/gpu3d/gpu3d_gxfront.sv $root/rtl/gpu3d/gpu3d_gxeng.sv $root/rtl/gpu3d/gpu3d_gxsort.sv $root/rtl/gpu3d/gpu3d_geom.sv"
for top in ${TOPS:-gpu3d_geom gpu3d_gxfront gpu3d_gxeng gpu3d_gxsort gpu3d_gxdiv}; do
  "$yosys" -q -l "$out/$top.log" -p "plugin -i slang; read_slang -D SYNTHESIS ${SMALL:+-G SMALL=$SMALL} --top $top $src; synth_intel_alm -family cyclonev -top $top; tee -q -o $out/$top.stat stat" >/dev/null 2>&1 || { echo "$top: yosys failed"; continue; }
  awk -v t=$top '/MISTRAL_ALUT[0-9]|MISTRAL_ALUT_ARITH/{l+=$1} /MISTRAL_FF/{f=$1} /MISTRAL_M10K/{m=$1} /MISTRAL_MLAB/{ml=$1} /MISTRAL_MUL/{d=d" "$1"x"$2}
       END{printf "%-14s LUT cells %6d (~%5.0f ALUTs at 0.76)  FF %5d  M10K %3d  MLAB %3d  DSP%s\n", t, l, l*0.76, f, m, ml, d}' "$out/$top.stat"
done
