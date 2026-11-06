#!/usr/bin/env bash
# nds_psram_port's 32-byte blocks against a reference image (tb_port_blk.sv), 3 seeds;
# "mutate": each planted bug must fail a seed.
#   port_blk.sh [mutate]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
run() {   # run DIR X2B_FILE
    mkdir -p "$1"
    verilator --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE \
        --top-module tb_port_blk --Mdir "$1/obj" rtl/mem/psx_pq_psram.sv rtl/mem/psx_psram_pair.sv "$2" \
        sim/phase1/cram_model.sv sim/phase1/sim_prims.sv sim/pocket/psram_eq/tb_port_blk.sv > "$1/build.log" 2>&1 \
        || { grep -E "%Error" "$1/build.log" | head; return 1; }
    for s in 1 2 3; do timeout 300 "$1/obj/Vtb_port_blk" +seed=$s +reqs=2000 | grep -E "^(PASS|FAIL)" || echo "FAIL (no result, seed $s)"; done
}
B=build/port_blk
run $B/ref rtl/pocket/nds_x2b.sv | tee $B.log
if grep -q FAIL $B.log; then echo "reference FAILS"; exit 1; fi
[ "${1:-}" = mutate ] || exit 0
mut() {   # mut N OLD NEW
    mkdir -p $B/m$1; cp rtl/pocket/nds_x2b.sv $B/m$1/
    python3 -c "import sys; p=sys.argv[1]; s=open(p).read(); assert s.count(sys.argv[2])==1, 'mutant $1 not applied'; open(p,'w').write(s.replace(sys.argv[2], sys.argv[3]))" $B/m$1/nds_x2b.sv "$2" "$3"
    run $B/m$1 $B/m$1/nds_x2b.sv > $B/m$1.log || true
    if grep -q FAIL $B/m$1.log; then echo "mutant $1 caught"; else echo "mutant $1 MISSED"; fi
}
mut 1 "if (b_adv) begin half <= 1; b_raddr <= b_raddr + 25'd8;" "if (b_adv) begin half <= 1; b_raddr <= b_raddr + 25'd4;"
mut 2 "b_wdata[(3'd4 - coll) * 32 +: 32] <= s_wdata;" "b_wdata[(coll - 3'd1) * 32 +: 32] <= s_wdata;"
mut 3 "if (!half) begin half <= 1; b_raddr <= b_raddr + 25'd8; busy <= 1; req_t <= !req_t; end" "if (!half) begin half <= 1; busy <= 1; req_t <= !req_t; end"
mut 4 "coll <= 3'd4; s_wnext <= 1; b_adv <= 0; end" "coll <= 3'd4; b_adv <= 0; end"
