#!/usr/bin/env bash
# nds_psram (rtl/pocket/nds_psram.sv) against nds_psram_port + psx_psram_pair,
# clock by clock at the DS port and the chip pins (tb_h1_eq.sv, docs/psram-ds.md).
#   h1_eq.sh [seeds] [reqs]        h1_eq.sh mutate [seeds] [reqs]   (planted faults must fail)
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
mode=check; [ "${1:-}" = mutate ] && { mode=mutate; shift; }
seeds=${1:-8}; reqs=${2:-3000}
out=build/h1_eq; rm -rf "$out"; mkdir -p "$out"
run() {   # run DIR DUT: build, run the seeds, print the pass count
    verilator --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-MULTIDRIVEN \
        --top-module tb_h1_eq --Mdir "$1/obj" rtl/mem/psx_pq_psram.sv rtl/mem/psx_psram_pair.sv rtl/pocket/nds_x2b.sv "$2" \
        sim/phase1/cram_model.sv sim/phase1/sim_prims.sv sim/pocket/psram_eq/tb_h1_eq.sv > "$1/build.log" 2>&1 \
        || { grep -E "%Error" "$1/build.log" | head >&2; echo 0; return; }
    local pass=0
    for s in $(seq 1 "$seeds"); do
        "$1/obj/Vtb_h1_eq" +seed=$s +reqs=$reqs | grep -E "^(PASS|FAIL)|ERROR" | tail -2 | tee -a "$1/runs.log" | grep -q '^PASS' && pass=$((pass + 1)) || true
    done
    echo $pass
}
if [ $mode = check ]; then
    p=$(run "$out" rtl/pocket/nds_psram.sv); tail -3 "$out/runs.log"
    echo "h1_eq: $p/$seeds PASS"; [ "$p" = "$seeds" ]; exit
fi
mut() {   # mut N OLD NEW: the fault must make some seed fail
    mkdir -p "$out/m$1"; python3 -c "import sys; p=sys.argv[1]; s=open(p).read(); assert s.count(sys.argv[2])==1, 'mutant $1 not applied'; open(sys.argv[4],'w').write(s.replace(sys.argv[2], sys.argv[3]))" \
        rtl/pocket/nds_psram.sv "$2" "$3" "$out/m$1/dut.sv"
    p=$(run "$out/m$1" "$out/m$1/dut.sv")
    if [ "$p" = "$seeds" ]; then echo "mutant $1 MISSED"; else echo "mutant $1 caught ($((seeds - p))/$seeds seeds fail)"; fi
}
mut 1 "wire [3:0] words = req_write ? 4'd1 : req_n8 ? 4'd8 : 4'd4;" "wire [3:0] words = req_write ? 4'd1 : req_n8 ? 4'd8 : 4'd3;"
mut 2 "wdata1 <= b_wdata[31:16]; be1 <= b_be[3:2]; we1 <= b_be[3:2] != 0;" "wdata1 <= b_wdata[31:16]; be1 <= {b_be[2], b_be[3]}; we1 <= b_be[3:2] != 0;"
mut 3 "                bank <= 1'b0;" "                bank <= 1'b0; chip_addr <= {1'b0, b_word};"
mut 4 "b_word <= b_word + 21'd4;" "b_word <= b_word + 21'd8;"
mut 5 "WR_WAIT: if (!write_en && cbusy == 2'b00) state <= RSP;" "WR_WAIT: begin wdata0 <= 16'h0; if (!write_en && cbusy == 2'b00) state <= RSP; end"
mut 6 "if (filled < have) filled <= filled + 1'b1;" "if (filled + 4'd1 < have) filled <= filled + 1'b1;"
