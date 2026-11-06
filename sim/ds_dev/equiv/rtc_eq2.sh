#!/usr/bin/env bash
# nds_rtc against an earlier revision on the traffic games make (valid BCD dates and times, 24-hour mode, no raw
# date fields): rtc_eq2.sh [REF] [new.sv] [seeds]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-afc78fe6}; rtl=${2:-rtl/ds/nds_rtc.sv}; seeds=${3:-30}
out=build/rtc_eq2/$(basename "$rtl" .sv); mkdir -p "$out"
git show "$ref:rtl/ds/nds_rtc.sv" | sed 's/^module nds_rtc\b/module nds_rtc_ref/' > "$out/nds_rtc_ref.sv"
sed 's/, \.init_valid(1.b0), \.init_date_bcd(32.d0), \.init_time_bcd(32.d0)//; s/\.io_rdata(q_ref), *$/.io_rdata(q_ref)/; /\.init_valid(1.b0)/d' sim/ds_dev/equiv/tb_rtc_eq.sv > "$out/tb_rtc_eq.sv"
sed -i 's/\.io_rdata(q_ref)$/.io_rdata(q_ref));/' "$out/tb_rtc_eq.sv"
verilator --cc --exe --build -j 8 -O2 --public-flat-rw -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -CFLAGS -DRTC_VALID \
    -Wno-UNUSEDSIGNAL --top-module tb_rtc_eq --Mdir "$out/obj" "$rtl" "$out/nds_rtc_ref.sv" \
    "$out/tb_rtc_eq.sv" "$PWD/sim/ds_dev/equiv/rtc_eq.cpp" > "$out/build.log" 2>&1 \
    || { grep -E '%Error|error:' "$out/build.log" | head -8; exit 1; }
pass=0; n=0
for s in $(seq 1 "$seeds"); do for g in 3 4 16; do
    n=$((n + 1))
    "$out/obj/Vtb_rtc_eq" --seed "$s" --ops 3000 --gap "$g" | tail -1 | grep -q '^PASS' \
        && pass=$((pass + 1)) || echo "FAIL seed $s gap $g"
done; done
echo "rtc_eq2: $pass/$n PASS"
[ "$pass" = "$n" ]
