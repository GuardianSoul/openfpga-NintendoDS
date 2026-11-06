#!/usr/bin/env bash
# psx_pq_psram (rtl/mem/psx_pq_psram.sv) against its version at REF (default
# origin/main), clock by clock (tb_pq_eq.sv).
#   pq_eq.sh [REF] [seeds] [clocks]     pq_eq.sh mutate   (planted faults must fail)
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
mode=check; [ "${1:-}" = mutate ] && { mode=mutate; shift; }
ref=${1:-origin/main}; seeds=${2:-8}; cycles=${3:-200000}
out=build/pq_eq; rm -rf "$out"; mkdir -p "$out"
git show "$ref:rtl/mem/psx_pq_psram.sv" | sed -n '/^module psx_pq_psram /,/^endmodule/p' \
    | sed 's/^module psx_pq_psram /module psx_pq_psram_ref /' > "$out/pq_ref.sv"
grep -q "module psx_pq_psram_ref" "$out/pq_ref.sv"
run() {   # run DIR DUT: build and run all seeds, print the pass count
    verilator --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-MULTIDRIVEN \
        --top-module tb_pq_eq --Mdir "$1/obj" "$2" "$out/pq_ref.sv" sim/pocket/psram_eq/tb_pq_eq.sv > "$1/build.log" 2>&1 \
        || { grep -E "%Error" "$1/build.log" | head; return 1; }
    local pass=0
    for s in $(seq 1 "$seeds"); do
        "$1/obj/Vtb_pq_eq" +seed=$s +cycles=$cycles | grep -E "^(PASS|FAIL)" | tee -a "$1/runs.log" | grep -q '^PASS' && pass=$((pass + 1)) || true
    done
    echo $pass
}
if [ $mode = check ]; then
    p=$(run "$out" rtl/mem/psx_pq_psram.sv); tail -2 "$out/runs.log"
    echo "pq_eq: $p/$seeds PASS"; [ "$p" = "$seeds" ]; exit
fi
mut() {   # mut N OLD NEW: the fault must make some seed fail
    mkdir -p "$out/m$1"; python3 -c "import sys; p=sys.argv[1]; s=open(p).read(); assert s.count(sys.argv[2])==1, 'mutant $1 not applied'; open(sys.argv[4],'w').write(s.replace(sys.argv[2], sys.argv[3]))" \
        rtl/mem/psx_pq_psram.sv "$2" "$3" "$out/m$1/pq.sv"
    p=$(run "$out/m$1" "$out/m$1/pq.sv")
    if [ "$p" = "$seeds" ]; then echo "mutant $1 MISSED"; else echo "mutant $1 caught ($((seeds - p))/$seeds seeds fail)"; fi
}
mut 1 "st_none  <= sn == STATE_NONE;" "st_none  <= state == STATE_NONE;"
mut 2 "st_wdata <= sn == STATE_WRITE_DATA_START;" "st_wdata <= sn == STATE_WRITE_DATA_START + 1;"
mut 3 "st_cfg   <= sn == STATE_CONFIG_CRE_SETUP;" "st_cfg   <= sn == STATE_CONFIG_START;"
