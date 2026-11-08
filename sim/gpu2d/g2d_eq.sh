#!/bin/bash
# The 2D engine against its version at REF on tb_gpu2d's runs (built-in
# scenes and the census dumps, with and without VRAM jitter): every run's
# report line, including its output hash (every pixel and capture write with
# its clock) and fill/stall counts, must be the same.
#   g2d_eq.sh VERILATOR BUILD_DIR [REF]
# G2D_DUMPS: the dumps (default build/census/gpu2d/*.g2d of the main checkout)
set -e
V=$1; B=$2; REF=${3:-669c40c9}
FILES="rtl/gpu2d/gpu2d_pkg.sv rtl/ds/nds_ram.sv rtl/gpu2d/gpu2d_ram.sv rtl/gpu2d/gpu2d_cache.sv rtl/gpu2d/gpu2d_bg.sv rtl/gpu2d/gpu2d_obj.sv rtl/gpu2d/gpu2d.sv"
mkdir -p $B/oldsrc
OLD=""
for f in $FILES; do git show $REF:$f > $B/oldsrc/$(basename $f); OLD="$OLD $B/oldsrc/$(basename $f)"; done
VF="--cc --exe --build -j 6 -O3 --x-assign fast --x-initial fast -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL --top-module gpu2d"
make -s VERILATOR=$V MELONDS=${MELONDS:-/home/user/Git/NDS_Pocket/references/melonDS} G2D_BUILD=$B/old G2D_RTL="$OLD" G2D_VFLAGS="$VF" $B/old/obj/Vgpu2d
make -s VERILATOR=$V MELONDS=${MELONDS:-/home/user/Git/NDS_Pocket/references/melonDS} G2D_BUILD=$B/new G2D_VFLAGS="$VF" $B/new/obj/Vgpu2d
DUMPS=${G2D_DUMPS:-$(ls /home/user/Git/NDS_Pocket/build/census/gpu2d/*.g2d)}
fail=0
for args in "--scenes" "--scenes --jitter 20" $(for d in $DUMPS; do echo "--dump:$d" "--dump:$d:--jitter:20"; done); do
  a=$(echo "$args" | tr ':' ' ')
  o=$($B/old/obj/Vgpu2d $a 2>/dev/null | grep -E "^(PASS|FAIL) ")
  n=$($B/new/obj/Vgpu2d $a 2>/dev/null | grep -E "^(PASS|FAIL) ")
  if [ "$o" = "$n" ]; then echo "same  $a: $(echo "$n" | wc -l) runs, $(echo "$n" | grep -c '^PASS') PASS, hashes $(echo "$n" | sed 's/.*out \([0-9a-f]*\).*/\1/' | md5sum | cut -c1-12)"
  else echo "DIFF  $a"; diff <(echo "$o") <(echo "$n") | head -6; fail=1; fi
done
exit $fail
