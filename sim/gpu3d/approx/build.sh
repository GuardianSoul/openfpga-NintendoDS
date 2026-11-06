#!/usr/bin/env bash
# Build the budget-3D comparison tool (docs/budget-3d.md): melonDS's renderer
# exact and with architecture 3's approximations, side by side.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
m=${MELONDS:-$root/references/melonDS}
b=$root/build/approx; mkdir -p "$b"
python3 "$root/sim/gpu3d/approx/patch.py" "$m/src" "$b"
cp "$root/sim/gpu3d/approx/approx.h" "$b/"
g++ -std=c++20 -O2 -I"$b" -I"$root/sim/gpu3d" -I"$root/sim/gpu3d/melonds_shim" \
  "$root/sim/gpu3d/approx/approx_cmp.cpp" "$root/sim/gpu3d/scenes.cpp" "$b/GPU3D_SoftE.cpp" "$b/GPU3D_SoftA.cpp" \
  -o "$b/approx_cmp"
echo "$b/approx_cmp"
