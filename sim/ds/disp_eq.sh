#!/bin/sh
# nds_disp with its 2D engine (rtl/ds/nds_disp*.sv, rtl/gpu2d) against the
# version at REF, cycle by cycle (sim/ds/tb_disp_eq.cpp): the release's
# parameters (no mosaic, ext-palette tags in the data words, CPU OAM reads
# through the 2D engine, HURRY_AT), the defaults, and AR_RAM = 0, two
# seeds each.
#   disp_eq.sh VERILATOR BUILD_DIR [REF] [RTL_ROOT]
# EQ_CYCLES (default 3,000,000: about three frames), EQ_CFGS (which configs),
# EQ_SEEDS (default "1 2"), NEWREF (a commit to test in place of the tree),
# EQ_ARGS (more tb_disp_eq arguments). Mutations: sim/ds/disp_eq_mutate.py.
set -e
V=$1; B=$2; REF=${3:-669c40c9}; R=${4:-.}
FILES="rtl/gpu2d/gpu2d_pkg.sv rtl/ds/nds_ram.sv rtl/gpu2d/gpu2d_ram.sv rtl/gpu2d/gpu2d_cache.sv rtl/gpu2d/gpu2d_bg.sv
       rtl/gpu2d/gpu2d_obj.sv rtl/gpu2d/gpu2d.sv rtl/ds/nds_disp_refs.sv rtl/ds/nds_disp.sv"
mkdir -p $B/old
OLD=""; NEW=""
[ -n "$NEWREF" ] && mkdir -p $B/newsrc
for f in $FILES; do
  git show $REF:$f > $B/old/$(basename $f)
  OLD="$OLD $B/old/$(basename $f)"
  if [ -n "$NEWREF" ]; then git show $NEWREF:$f > $B/newsrc/$(basename $f); NEW="$NEW $B/newsrc/$(basename $f)"
  else NEW="$NEW $R/$f"; fi
done
VF="--cc -O3 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE --top-module tb_disp_eq_top"
fail=0
for cfg in ${EQ_CFGS:-rel def noar}; do
  case $cfg in
    rel)  G="-GMOSAIC=0 -GTAG_MLAB=1 -GOAM_CPU=1 -GTEX_IDXW=6 -GHURRY_AT=2800" ;;
    def)  G="-GMOSAIC=1 -GTAG_MLAB=0 -GOAM_CPU=0 -GTEX_IDXW=7" ;;
    noar) G="-GAR_RAM=0 -GWST_RF=0 -GMOSAIC=1 -GTEX_IDXW=6" ;;
  esac
  d=$B/$cfg
  mkdir -p $d
  $V $VF $G --prefix Vold --build -j 6 -Mdir $d/old $OLD sim/ds/tb_disp_eq_top.sv > $d/old.log 2>&1 || { grep -E "%Error" $d/old.log | head; exit 1; }
  $V $VF $G --prefix Vnew --exe --build -j 6 -Mdir $d/new -CFLAGS "-O2 -I$(realpath $d/old)" \
     $NEW sim/ds/tb_disp_eq_top.sv $(realpath sim/ds/tb_disp_eq.cpp) $(realpath $d/old/Vold__ALL.a) \
     -o tb_disp_eq > $d/new.log 2>&1 || { grep -E "%Error|error" $d/new.log | head; exit 1; }
  for s in ${EQ_SEEDS:-1 2}; do
    out=$($d/new/tb_disp_eq --cycles ${EQ_CYCLES:-3000000} --seed $s $EQ_ARGS 2>&1 | grep -E "^disp_eq|^PASS|^FAIL|^cycle|nds_disp" | head -8 | tr '\n' ' ')
    echo "$cfg seed $s: $out"
    case "$out" in *PASS*) ;; *) fail=1 ;; esac
    case "$out" in *nds_disp*) fail=1 ;; esac
  done
done
exit $fail
