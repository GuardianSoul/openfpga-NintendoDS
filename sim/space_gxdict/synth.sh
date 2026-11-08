#!/usr/bin/env bash
# sim/space_gxdict/synth.sh ENG.sv ROM.sv TAG: Yosys (slang) synth_intel_alm of gpu3d_gxeng at the release
# parameters (FF, LUNIT, VFIN 2, USORT, SMALL) with the given engine and control-store files; LUT/FF/M10K
# counts (docs/space-gxdict.md). Yosys's counts are a rough guide; the fit decides.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
Y=${YOSYS:-build/tools/oss-cad-suite/bin/yosys}
eng=$1; rom=$2; tag=$3; out=$root/build/space_gxdict; mkdir -p "$out"
g=$root/rtl/gpu3d
src="$g/gpu3d_gxu_pkg.sv $g/gpu3d_ram.sv $g/gpu3d_gxrom.sv $g/gpu3d_gxrom_us.sv $g/gpu3d_gxrom_ul.sv $g/gpu3d_gxrom_uv.sv $g/gpu3d_gxrom_uw.sv $rom $g/gpu3d_gxlight.sv $g/gpu3d_gxvfin.sv $g/gpu3d_gxdiv.sv $eng"
"$Y" -q -l "$out/$tag.log" -p "plugin -i slang; read_slang --allow-use-before-declare -D SYNTHESIS -G FF=1 -G LUNIT=1 -G VFIN=2 -G USORT=1 -G SMALL=1 --top gpu3d_gxeng $src; synth_intel_alm -family cyclonev -top gpu3d_gxeng; tee -q -o $out/$tag.stat stat" >/dev/null 2>&1
awk -v t=$tag '/MISTRAL_ALUT[0-9]|MISTRAL_ALUT_ARITH/{l+=$1} /MISTRAL_FF/{f=$1} /MISTRAL_M10K/{m=$1} /MISTRAL_MLAB/{ml=$1}
     END{printf "%-6s LUT cells %6d  FF %5d  M10K %3d  MLAB %3d\n", t, l, f, m, ml}' "$out/$tag.stat"
