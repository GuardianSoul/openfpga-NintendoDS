#!/usr/bin/env bash
# Mutation check for the system-block test bench: copy rtl/sys, apply one
# sed expression to one file, rebuild and expect tb_sys to fail.
#   sim/sys/mutate.sh                         the standard set below
#   sim/sys/mutate.sh <file> '<sed expr>' [tb args...]
# Exit 0 when every mutation is caught, 1 when one is not.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
verilator=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
one() {
    local file=$1 expr=$2; shift 2
    local work=$root/build/sys/mutant
    rm -rf "$work"; mkdir -p "$work/rtl"
    cp "$root"/rtl/sys/*.sv "$work/rtl/"
    local before; before=$(md5sum "$work/rtl/$file")
    sed -i -e "$expr" "$work/rtl/$file"
    [ "$before" != "$(md5sum "$work/rtl/$file")" ] || { echo "mutation did not change $file: $expr" >&2; exit 2; }
    local r=$work/rtl
    "$verilator" --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
      -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL --Mdir "$work/obj" --top-module nds_sys \
      -CFLAGS "-std=c++20 -O2 -I$root/sim/sys" \
      "$root/rtl/ds/nds_dsp_add.sv" $r/sys_ram.sv $r/sys_irq.sv $r/sys_timers.sv $r/sys_ipc.sv $r/sys_math.sv $r/sys_dma.sv $r/nds_sys.sv \
      "$root/sim/sys/tb_sys.cpp" >"$work/verilator.log" 2>&1 || { tail -20 "$work/verilator.log"; exit 2; }
    if timeout 600 "$work/obj/Vnds_sys" "$@" > "$work/run.log" 2>&1; then
        echo "NOT CAUGHT: $file: $expr"; return 1
    fi
    echo "caught: $file: $expr -> $(tail -1 "$work/run.log" | sed 's/ (seed.*//'); first: $(grep -m1 '^FAIL \[' "$work/run.log" | cut -c1-110)"
}
if [ $# -ge 2 ]; then one "$@"; exit; fi
rc=0
one sys_math.sv   "s/6'd18 : 6'd34) - 6'(tick)/6'd17 : 6'd34) - 6'(tick)/" --only div   || rc=1
one sys_math.sv   "s/r2 = sq_step(r1, q1, nib\[1:0\]);/r2 = sq_step(r1, q1, {nib[0], nib[1]});/" --only sqrt || rc=1
one sys_timers.sv "s/? s_gt + togo : 4'hF;/? s_gt + togo + 4'd1 : 4'hF;/" --only timers   || rc=1
one sys_timers.sv "s/? s_gt + togo : 4'hF;/? s_gt + togo : 4'hE;/" --only timers           || rc=1
one sys_timers.sv "s/dn \&\& ch\[k\];/1'b0;/" --only timers                                  || rc=1
one sys_timers.sv "s/\&dv\[5:4\]}/dv[5]}/" --only timers                                      || rc=1
one sys_timers.sv "s/near = \&s_nc\[15:4\]/near = \&s_nc[15:5]/" --only timers                   || rc=1
one sys_ipc.sv    "s/n\[o\] == 5'd1 \&\& sirq\[o\]/n[o] == 5'd2 \&\& sirq[o]/" --only ipc   || rc=1
one sys_ipc.sv    "s/fl\[c\] <= n\[c\] == 5'd15/fl[c] <= n[c] == 5'd14/" --only ipc          || rc=1
one sys_irq.sv    "s/assign irq    = ime \&\& /assign irq    = /" --only irq               || rc=1
one sys_dma.sv    "s/(r > 21'd112 || r == 21'd0)) ? 7'd112/(r > 21'd111 || r == 21'd0)) ? 7'd111/" --only dma || rc=1
one sys_dma.sv    "s/e_cnt\[22:21\] == 2'd3) e_dst/e_cnt[22:21] == 2'd2) e_dst/" --only dma || rc=1
one sys_dma.sv    "s/if (run\[i\] \&\& 3'(i) < ek) higher/if (1'b0) higher/" --only dma      || rc=1
exit $rc
