#!/usr/bin/env bash
# Mutation check for the renderer harness: copy rtl/gpu3d, apply one sed
# expression to one file, rebuild the testbench and expect the diff to fail.
# Usage: sim/gpu3d/mutate.sh <file-in-rtl/gpu3d> '<sed expr>' [tb args...]
# MUT_VFLAGS: extra Verilator flags (e.g. -GFEAT_AA=0 with tb args --feat-off aa)
# Exit 0 when the mutation is caught (some scene differs), 1 when it is not.
set -euo pipefail
file=$1; expr=$2; shift 2
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$root/build/gpu3d/mutant
rm -rf "$work"; mkdir -p "$work/rtl"
cp "$root"/rtl/gpu3d/*.sv "$work/rtl/"
before=$(md5sum "$work/rtl/$file")
sed -i -e "$expr" "$work/rtl/$file"
[ "$before" != "$(md5sum "$work/rtl/$file")" ] || { echo "mutation did not change $file" >&2; exit 2; }
make -s -C "$root" build/gpu3d/obj/Vgpu3d_raster >/dev/null   # golden copies, objects
verilator=${VERILATOR:-$(command -v verilator || echo "build/tools/oss-cad-suite/bin/verilator")}
g=$root/build/gpu3d/golden
"$verilator" --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL ${MUT_VFLAGS:-} --Mdir "$work/obj" --top-module gpu3d_raster \
  -CFLAGS "-std=c++20 -O2 -DDS_RULE_TOON -DDS_RULE_HILITE -DDS_RULE_LIN17 -DDS_RULE_LINZ -DDS_RULE_YPERSP -DDS_RULE_XPERSP16 -DDS_RULE_AACOV -DDS_RULE_AAYCOV -DDS_RULE_TEXRND -DDS_RULE_ZFACE -DDS_RULE_TEX4X4 -I$root/sim/gpu3d -I$root/sim/gpu3d/melonds_shim -I$g" \
  "$work"/rtl/gpu3d_pkg.sv "$work"/rtl/gpu3d_div4.sv "$work"/rtl/gpu3d_ram.sv "$work"/rtl/gpu3d_edge.sv "$work"/rtl/gpu3d_front.sv "$work"/rtl/gpu3d_fpass.sv "$work"/rtl/gpu3d_raster.sv \
  "$root"/sim/gpu3d/tb_gpu3d.cpp "$root"/sim/gpu3d/golden.cpp "$root"/sim/gpu3d/scenes.cpp "$g/GPU3D_Soft.cpp" \
  >"$work/verilator.log" 2>&1 || { tail -20 "$work/verilator.log"; exit 2; }
if "$work/obj/Vgpu3d_raster" --out "$work" "$@" > "$work/run.log"; then
  echo "NOT CAUGHT: $file: $expr"; exit 1
else
  echo "caught: $file: $expr -> $(grep -c '^FAIL' "$work/run.log") scenes differ ($(grep -m1 '^FAIL' "$work/run.log" | awk '{print $2}') first)"
fi
