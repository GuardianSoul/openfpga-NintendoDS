#!/bin/bash
# G2D_CFL in tb_gpu2d (PERSIST=1, as nds_disp builds it):
#  1. CFL 0 against REF (default claude/rc8p4): every run's report line the same (pixels, capture writes, clocks)
#  2. CFL 1 + AMF (--cfl 2) against the golden renderer: the same runs pixel-exact as REF's
#  3. mutants of 2 (MUT="file:sed ..."): caught when a run's PASS/FAIL changes
#   cfl_check.sh BUILD_DIR [REF]
set -e
B=$1; REF=${2:-claude/objwork-rc9}
V=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
M=/home/user/Git/NDS_Pocket/references/melonDS
FILES="rtl/gpu2d/gpu2d_pkg.sv rtl/ds/nds_ram.sv rtl/gpu2d/gpu2d_ram.sv rtl/gpu2d/gpu2d_cache.sv rtl/gpu2d/gpu2d_bg.sv rtl/gpu2d/gpu2d_obj.sv rtl/gpu2d/gpu2d.sv"
VF="--cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL --top-module gpu2d"
bld() {  # name params srcdir
  make -s VERILATOR=$V MELONDS=$M G2D_BUILD=$B/$1 G2D_RTL="$(for f in $FILES; do echo -n "$3/$(basename $f) "; done)" G2D_VFLAGS="$VF $2" $B/$1/obj/Vgpu2d >/dev/null
}
mkdir -p $B/old $B/new
for f in $FILES; do git show $REF:$f > $B/old/$(basename $f); cp $f $B/new/$(basename $f); done
bld o0 "-GPERSIST=1" $B/old
bld n0 "-GPERSIST=1" $B/new
bld n2 "-GPERSIST=1 -GCBD=1" $B/new
DUMPS=$(ls /home/user/Git/NDS_Pocket/build/census/gpu2d/*.g2d)
RUNS="--scenes|--scenes:--jitter:20"; for d in $DUMPS; do RUNS="$RUNS|--dump:$d|--dump:$d:--jitter:20"; done
pf() { grep -E "^(PASS|FAIL) " | awk '{print $1, $2}'; }
fail=0
IFS='|'; for args in $RUNS; do IFS=' '
  a=$(echo "$args" | tr ':' ' ')
  o=$($B/o0/obj/Vgpu2d $a 2>/dev/null | grep -E "^(PASS|FAIL) ")
  n=$($B/n0/obj/Vgpu2d $a 2>/dev/null | grep -E "^(PASS|FAIL) ")
  c=$($B/n2/obj/Vgpu2d $a 2>/dev/null | grep -E "^(PASS|FAIL) ")
  [ "$o" = "$n" ] && e0=same || { e0=DIFF; fail=1; }
  [ "$(echo "$o" | pf)" = "$(echo "$c" | pf)" ] && e2=same || { e2=DIFF; fail=1; }
  echo "$e0 cbd0 / $e2 cbd1  $(echo "$a"): $(echo "$o" | grep -c '^PASS')/$(echo "$o" | wc -l) PASS ref, $(echo "$c" | grep -c '^PASS') PASS cbd1"
  IFS='|'
done
exit $fail
