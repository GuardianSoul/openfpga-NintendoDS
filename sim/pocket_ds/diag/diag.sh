#!/usr/bin/env bash
# nds_diag (rtl/pocket/nds_diag.sv) on random events (tb_diag.sv), and nds_diag_lat's bins (tb_diag_lat.sv).
#   diag.sh [seeds] [frames] [RTL file to test instead of rtl/pocket/nds_diag.sv]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
seeds=${1:-6}; frames=${2:-60}; dut=${3:-rtl/pocket/nds_diag.sv}
out=build/diag_tb; rm -rf "$out"; mkdir -p "$out"
# with the line histograms (NL = 2) and without (NL = 0, the NDSDiag build since #608)
pass=0
for nl in 2 0; do
    verilator --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -DTB_NL=$nl \
        --top-module tb_diag --Mdir "$out/obj$nl" "$dut" rtl/gpu3d/gpu3d_ram.sv sim/pocket_ds/diag/tb_diag.sv > "$out/build$nl.log" 2>&1 \
        || { grep -E "%Error" "$out/build$nl.log" | head; exit 1; }
    for s in $(seq 1 "$seeds"); do
        "$out/obj$nl/Vtb_diag" +seed=$s +frames=$frames | grep -E "^(PASS|FAIL|diag:)|ERROR" | tail -6 | tee -a "$out/runs.log" | grep -q '^PASS' && pass=$((pass + 1)) || true
    done
done
seeds2=$((2 * seeds))
echo "diag: $pass/$seeds2 PASS (NL 2 and 0)"
# nds_diag_lat: the four bin modes against a model
verilator --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module tb_diag_lat --Mdir "$out/obj_lat" \
    rtl/pocket/nds_diag_lat.sv sim/pocket_ds/diag/tb_diag_lat.sv > "$out/build_lat.log" 2>&1 || { grep -E "%Error" "$out/build_lat.log" | head; exit 1; }
lp=0
for s in $(seq 1 "$seeds"); do "$out/obj_lat/Vtb_diag_lat" +seed=$s | grep -q '^PASS' && lp=$((lp + 1)) || true; done
echo "diag_lat: $lp/$seeds PASS"
# nds_diag_xmem: clk_mem events crossed to clk_sys, none lost
verilator --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module tb_diag_xmem --Mdir "$out/obj_xm" \
    ${XMEM:-rtl/pocket/nds_diag_xmem.sv} sim/pocket_ds/diag/tb_diag_xmem.sv > "$out/build_xm.log" 2>&1 || { grep -E "%Error" "$out/build_xm.log" | head; exit 1; }
xp=0
for s in $(seq 1 "$seeds"); do "$out/obj_xm/Vtb_diag_xmem" +seed=$s | grep -q '^PASS' && xp=$((xp + 1)) || true; done
echo "diag_xmem: $xp/$seeds PASS"
[ "$pass" = "$seeds2" ] && [ "$lp" = "$seeds" ] && [ "$xp" = "$seeds" ]
