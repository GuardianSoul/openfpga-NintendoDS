#!/usr/bin/env bash
# nds_dcfifo's wempty and order (tb_dcfifo.sv), 3 seeds; "mutate": the planted
# bug (wempty from the load pointer, ahead of the pop) must fail a seed.
set -euo pipefail
cd "$(dirname "$0")/../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
B=build/dcfifo
run() {   # run DIR CDC_FILE
    mkdir -p "$1"
    verilator --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module tb_dcfifo --Mdir "$1/obj" \
        "$2" sim/pocket/tb_dcfifo.sv > "$1/build.log" 2>&1 || { grep -E "%Error" "$1/build.log" | head; return 1; }
    for s in 1 2 3; do timeout 120 "$1/obj/Vtb_dcfifo" +seed=$s | grep -E "^(PASS|FAIL)" || echo "FAIL (no result, seed $s)"; done
}
mkdir -p $B
run $B/ref rtl/pocket/nds_cdc.sv | tee $B.log
if grep -q FAIL $B.log; then echo "reference FAILS"; exit 1; fi
[ "${1:-}" = mutate ] || exit 0
mkdir -p $B/m1; cp rtl/pocket/nds_cdc.sv $B/m1/
python3 -c "import sys; p=sys.argv[1]; s=open(p).read(); o='    assign wempty = wgray == pgray_w;'; assert s.count(o)==1; open(p,'w').write(s.replace(o,'    assign wempty = wgray == rgray_w;'))" $B/m1/nds_cdc.sv
run $B/m1 $B/m1/nds_cdc.sv > $B/m1.log || true
if grep -q FAIL $B/m1.log; then echo "mutant 1 caught"; else echo "mutant 1 MISSED"; fi
