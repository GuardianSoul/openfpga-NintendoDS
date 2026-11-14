#!/usr/bin/env bash
# The rtcprobe's date/time rows on nds_rtc's RTL against the DS's run (rtl_ds.cpp). rtl_ds.sh [nds_rtc.sv] [defines]
# e.g. rtl_ds.sh rtl/ds/nds_rtc.sv +define+RTC_SAN_MUT1 (a mutant: row 10 differs)
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
rtl=${1:-rtl/ds/nds_rtc.sv}; shift || true
out=build/rtcprobe-rtl/$(basename "$rtl" .sv)$(echo "$*" | tr -dc 'A-Z0-9_'); mkdir -p "$out"
clang -DRTC_PROBE_HOST -std=c11 -O2 -c sw/tests/rtcprobe/probe.c -o "$out/probe.o"
verilator --cc --exe --build -j 4 -O2 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-fatal --top-module nds_rtc -GSEC_TICKS=32728 "$@" \
    --Mdir "$out/obj" "$rtl" "$PWD/sw/tests/rtcprobe/rtl_ds.cpp" -LDFLAGS "$PWD/$out/probe.o" -CFLAGS "-I$PWD/sw/tests/rtcprobe" \
    > "$out/build.log" 2>&1 || { tail -20 "$out/build.log"; exit 1; }
"$out/obj/Vnds_rtc"
