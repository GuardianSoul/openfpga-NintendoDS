#!/usr/bin/env bash
# nds_bport_share on random traffic (tb_share.sv), and a planted fault it must catch (quad reads counted
# as one word: the port turns to B while A's words are still due).   share.sh [seeds]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
seeds=${1:-8}; out=build/share_tb; rm -rf "$out"; mkdir -p "$out/mut"
sed "s/(own_b ? 5'sd1 : a_quad ? 5'sd4 : 5'sd1)/(own_b ? 5'sd1 : 5'sd1)/" rtl/pocket/nds_bport_share.sv > "$out/mut/nds_bport_share.sv"
grep -q "5'sd1 : 5'sd1)" "$out/mut/nds_bport_share.sv"
for v in dut mut; do
    src=rtl/pocket/nds_bport_share.sv; [ $v = mut ] && src=$out/mut/nds_bport_share.sv
    verilator --binary --timing -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module tb_share --Mdir "$out/obj_$v" \
        "$src" sim/pocket_ds/share/tb_share.sv > "$out/build_$v.log" 2>&1 || { grep -E "%Error" "$out/build_$v.log" | head; exit 1; }
    p=0
    for s in $(seq 1 "$seeds"); do "$out/obj_$v/Vtb_share" +seed=$s | tee -a "$out/$v.log" | grep -q '^PASS' && p=$((p + 1)) || true; done
    echo "$v: $p/$seeds PASS"
    eval "pass_$v=$p"
done
[ "$pass_dut" = "$seeds" ] && [ "$pass_mut" = 0 ]
