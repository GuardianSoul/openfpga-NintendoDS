#!/bin/sh
# nds_fabric MR_BLOCK + nds_mr_arb against a reference image (sim/ds/tb_mrblock.sv),
# 3 seeds; with "mutate", each planted bug must fail at least one seed.
#   mrblock_test.sh [mutate]
set -e
cd "$(dirname "$0")/../.."
V=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
run() {   # run DIR FABRIC ARB
  mkdir -p $1
  $V --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE \
     --top-module tb_mrblock --Mdir $1/obj rtl/gpu2d/gpu2d_pkg.sv rtl/gpu2d/gpu2d_ram.sv rtl/ds/nds_ram.sv $2 $3 sim/ds/tb_mrblock.sv > $1/build.log 2>&1
  for s in 1 2 3; do timeout 60 $1/obj/Vtb_mrblock +seed=$s +ops=4000 | grep -E "^(PASS|FAIL)" || echo "FAIL (no result: hang or crash, seed $s)"; done
  timeout 60 $1/obj/Vtb_mrblock +lockout | grep -E "^(PASS|FAIL)" || echo "FAIL (no lockout result)"
}
B=build/mrblock
run $B/ref rtl/ds/nds_fabric.sv rtl/ds/nds_mr_arb.sv | tee $B.log
grep -q FAIL $B.log && exit 1
[ "${1:-}" = mutate ] || exit 0
mut() {   # mut N FILE OLD NEW
  mkdir -p $B/m$1; cp rtl/ds/nds_fabric.sv rtl/ds/nds_mr_arb.sv $B/m$1/
  python3 -c "import sys; p=sys.argv[1]; s=open(p).read(); assert s.count(sys.argv[2])==1, 'mutant $1 not applied'; open(p,'w').write(s.replace(sys.argv[2], sys.argv[3]))" $B/m$1/$2 "$3" "$4"
  run $B/m$1 $B/m$1/nds_fabric.sv $B/m$1/nds_mr_arb.sv > $B/m$1.log || true
  if grep -q FAIL $B/m$1.log; then echo "mutant $1 caught"; else echo "mutant $1 MISSED"; fi
}
mut 1 nds_fabric.sv "if (lb_tag[c][21:5] == addr[21:5]) lb_v[c] <= 1'b0;" "if (lb_tag[c] == addr[21:4]) lb_v[c] <= 1'b0;"
mut 2 nds_mr_arb.sv "(sel_n8 ? 3'd7 : 3'd3)" "(sel_n8 ? 3'd3 : 3'd3)"
mut 3 nds_fabric.sv "wire   bk_mon     = a9_wnext;" "wire   bk_mon     = 1'b0;"
mut 4 nds_fabric.sv "assign a9_rvalid = rv9 || (done && bl_word);" "assign a9_rvalid = rv9;"
mut 5 nds_fabric.sv "        else if (a7_first) grant[2] = 1'b1;" "        else if (1'b0) grant[2] = 1'b1;"
