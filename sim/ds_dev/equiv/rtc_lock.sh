#!/usr/bin/env bash
# nds_rtc in lockstep against its version at a base commit on valid 24-hour traffic (rtc_lock.cpp: date/time
# writes with valid BCD, every register read, status 1 in 24-hour mode, the second count through its carries);
# io_rdata compared every clock. rtc_lock.sh [BASE=e1d56be09] [nds_rtc.sv] [seeds=5]
# (rtc_eq.sh's b4eb578 bench predates the boot-load port change and no longer builds.)
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
base=${1:-e1d56be09}; rtl=${2:-rtl/ds/nds_rtc.sv}; seeds=${3:-5}
out=build/rtc_lock/$(basename "$rtl" .sv); mkdir -p "$out"
git show "$base":rtl/ds/nds_rtc.sv | sed 's/^module nds_rtc\b/module nds_rtc_old/' > "$out/nds_rtc_old.sv"
verilator --cc --exe --build -j 4 -O2 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-fatal --top-module tb_rtc_lock \
    --Mdir "$out/obj" "$out/nds_rtc_old.sv" "$rtl" sim/ds_dev/equiv/tb_rtc_lock.sv "$PWD/sim/ds_dev/equiv/rtc_lock.cpp" \
    > "$out/build.log" 2>&1 || { tail -20 "$out/build.log"; exit 1; }
fail=0
for s in $(seq 1 "$seeds"); do "$out/obj/Vtb_rtc_lock" "$s" 3000 | tail -2 | head -1; "$out/obj/Vtb_rtc_lock" "$s" 3000 > /dev/null || fail=1; done
exit $fail
