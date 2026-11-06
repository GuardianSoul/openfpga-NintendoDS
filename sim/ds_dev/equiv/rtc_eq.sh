#!/usr/bin/env bash
# RTC equivalence: rtl/ds/nds_rtc.sv (RAM version) against the all-flop RTC
# at b4eb578, 40 seeds x gaps 3/4/16, plain and with bridge loads inside
# transfers (RTC_MIDINIT), fields compared whenever the new one is idle. A mutant file can stand in for the RTL: rtc_eq.sh [nds_rtc.sv] [seeds]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
rtl=${1:-rtl/ds/nds_rtc.sv}; seeds=${2:-40}
out=build/rtc_eq/$(basename "$rtl" .sv); mkdir -p "$out"
git show b4eb578:rtl/ds/nds_rtc.sv | sed 's/^module nds_rtc\b/module nds_rtc_ref/' > "$out/nds_rtc_ref.sv"
verilator --cc --exe --build -j 8 -O2 --public-flat-rw -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -Wno-UNUSEDSIGNAL --top-module tb_rtc_eq --Mdir "$out/obj" "$rtl" "$out/nds_rtc_ref.sv" \
    sim/ds_dev/equiv/tb_rtc_eq.sv "$PWD/sim/ds_dev/equiv/rtc_eq.cpp" > "$out/build.log" 2>&1 \
    || { tail -20 "$out/build.log"; exit 1; }
pass=0; n=0
for m in "" 1; do for s in $(seq 1 "$seeds"); do for g in 3 4 16; do
    n=$((n + 1))
    RTC_MIDINIT=$m RTC_FIELDS=1 "$out/obj/Vtb_rtc_eq" --seed "$s" --ops 5000 --gap "$g" | tail -1 | grep -q '^PASS' \
        && pass=$((pass + 1)) || echo "FAIL seed $s gap $g${m:+ mid-transfer loads}"
done; done; done
echo "rtc_eq: $pass/$n PASS"
[ "$pass" = "$n" ]
