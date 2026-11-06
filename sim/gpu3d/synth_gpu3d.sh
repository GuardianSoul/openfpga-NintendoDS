#!/usr/bin/env bash
# Yosys cost estimate for the 3D rasterizer (no Quartus: fits on the shared
# nodes need the maintainer's go-ahead). Two runs:
#   generic.log  - `synth` cell counts (technology independent)
#   cyclonev.log - `synth_intel_alm -family cyclonev`: ALM LUTs, FFs, M10K, DSP
# Usage: synth_gpu3d.sh <yosys> <outdir> [top] [extra .sv files...]
set -euo pipefail
yosys=$1; out=$2; top=${3:-gpu3d_raster}; shift 3 2>/dev/null || shift $#
root=$(cd "$(dirname "$0")/../.." && pwd)
src=("$root"/rtl/gpu3d/gpu3d_pkg.sv $(ls "$root"/rtl/gpu3d/*.sv | grep -v gpu3d_pkg.sv) "$@")
mkdir -p "$out"
"$yosys" -q -l "$out/generic.log" -p "read_verilog -sv -DSYNTHESIS ${src[*]}; synth -top $top -flatten; tee -o $out/generic.stat stat"
"$yosys" -q -l "$out/cyclonev.log" -p "read_verilog -sv -DSYNTHESIS ${src[*]}; synth_intel_alm -family cyclonev -top $top; tee -o $out/cyclonev.stat stat"
echo "== $top, Yosys synth_intel_alm (Cyclone V)"
grep -E "MISTRAL_ALUT|MISTRAL_ALUT_ARITH|MISTRAL_FF|MISTRAL_M10K|MISTRAL_MLAB|MISTRAL_MUL|cells" "$out/cyclonev.stat" | sed 's/^ */  /'
