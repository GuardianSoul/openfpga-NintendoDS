#!/usr/bin/env bash
# nds_psram B8 + BW (block writes) against a shadow memory (tb_bw.sv).
#   bw_test.sh [seeds] [reqs]        bw_test.sh mutate [seeds] [reqs]   (planted faults must fail)
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
mode=check; [ "${1:-}" = mutate ] && { mode=mutate; shift; }
seeds=${1:-8}; reqs=${2:-3000}
out=build/bw_test; rm -rf "$out"; mkdir -p "$out"
run() {   # run DIR DUT
    verilator --binary --timing -O2 -j 3 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-MULTIDRIVEN \
        --top-module tb_bw -GSTREAM=${STREAM:-0} --Mdir "$1/obj" rtl/mem/psx_pq_psram.sv "$2" sim/phase1/cram_model.sv sim/phase1/sim_prims.sv \
        sim/pocket/psram_eq/tb_h1_eq.sv sim/pocket/psram_eq/tb_bw.sv > "$1/build.log" 2>&1 \
        || { grep -E "%Error" "$1/build.log" | head >&2; echo 0; return; }
    local pass=0
    for s in $(seq 1 "$seeds"); do
        timeout 600 "$1/obj/Vtb_bw" +seed=$s +reqs=$reqs | grep -E "^(PASS|FAIL)|^  " | tail -3 | tee -a "$1/runs.log" | grep -q '^PASS' && pass=$((pass + 1)) || true
    done
    echo $pass
}
if [ $mode = check ]; then
    p=$(run "$out" rtl/pocket/nds_psram.sv); tail -2 "$out/runs.log"
    echo "bw_test: $p/$seeds PASS"; [ "$p" = "$seeds" ]; exit
fi
mut() {
    mkdir -p "$out/m$1"; python3 -c "import sys; p=sys.argv[1]; s=open(p).read(); assert s.count(sys.argv[2])==1, 'mutant $1 not applied'; open(sys.argv[4],'w').write(s.replace(sys.argv[2], sys.argv[3]))" \
        rtl/pocket/nds_psram.sv "$2" "$3" "$out/m$1/dut.sv"
    p=$(run "$out/m$1" "$out/m$1/dut.sv")
    if [ "$p" = "$seeds" ]; then echo "mutant $1 MISSED"; else echo "mutant $1 caught ($((seeds - p))/$seeds seeds fail)"; fi
}
mut 1 "if (req_n8w && wi != 3'd7) begin wi <= wi + 3'd1; state <= WR; end" "if (req_n8w && wi != 3'd6) begin wi <= wi + 3'd1; state <= WR; end"
mut 2 "bwd[bw_k] <= s_wdata; bw_k <= bw_k + 1'b1;" "bwd[bw_k] <= s_wdata; bw_k <= bw_k + 3'd2;"
mut 3 "            if (strm && tot != wc_b) begin" "            if (strm) begin"
