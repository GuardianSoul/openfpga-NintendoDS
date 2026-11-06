#!/usr/bin/env bash
# Mutation check for the 2D harness: copy rtl/gpu2d, apply one sed
# expression to one file, rebuild the testbench and expect the diff to fail.
# Usage: sim/gpu2d/mutate.sh <file-in-rtl/gpu2d> '<sed expr>' [tb args...]
# G2D_PARAMS="-GPERSIST=1 ..." builds a parameter variant.
# Exit 0 when the mutation is caught (some run differs), 1 when it is not.
set -euo pipefail
file=$1; expr=$2; shift 2
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$root/build/gpu2d/mutant
rm -rf "$work"; mkdir -p "$work/rtl"
cp "$root"/rtl/gpu2d/*.sv "$work/rtl/"
before=$(md5sum "$work/rtl/$file")
sed -i -e "$expr" "$work/rtl/$file"
[ "$before" != "$(md5sum "$work/rtl/$file")" ] || { echo "mutation did not change $file" >&2; exit 2; }
make -s -C "$root" build/gpu2d/obj/Vgpu2d >/dev/null   # golden copies
verilator=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
g=$root/build/gpu2d/golden
s=$root/sim/gpu2d
"$verilator" --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL --Mdir "$work/obj" --top-module gpu2d ${G2D_PARAMS:-} \
  -CFLAGS "-std=c++20 -O2 -I$s -I$s/melonds_shim -I$g" \
  "$work"/rtl/gpu2d_pkg.sv "$root"/rtl/ds/nds_ram.sv "$work"/rtl/gpu2d_ram.sv "$work"/rtl/gpu2d_cache.sv "$work"/rtl/gpu2d_bg.sv \
  "$work"/rtl/gpu2d_obj.sv "$work"/rtl/gpu2d.sv \
  "$s/tb_gpu2d.cpp" "$s/golden2d.cpp" "$s/scenes2d.cpp" "$s/dump2d.cpp" "$g/GPU2D.cpp" "$g/GPU2D_Soft.cpp" \
  >"$work/verilator.log" 2>&1 || { tail -20 "$work/verilator.log"; exit 2; }
if timeout 1800 "$work/obj/Vgpu2d" "$@" > "$work/run.log" 2>/dev/null; then
  echo "NOT CAUGHT: $file: $expr"; exit 1
else
  echo "caught: $file: $expr -> $(grep -c '^FAIL ' "$work/run.log") runs differ ($(grep -m1 '^FAIL ' "$work/run.log" | awk '{print $2}') first)"
fi
