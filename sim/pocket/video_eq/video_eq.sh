#!/usr/bin/env bash
# nds_video against REF, clock by clock (tb_video_eq.sv). video_eq.sh [REF] [seeds] [new.sv]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-afc78fe6}; seeds=${2:-3}; src=${3:-rtl/pocket/nds_video.sv}
out=build/video_eq/$(basename "$src" .sv); mkdir -p "$out"
git show "$ref:rtl/pocket/nds_video.sv" | sed -E 's/^module nds_video\b/module old_nds_video/' > "$out/old.sv"
pass=0
for s in $(seq 1 "$seeds"); do
    verilator --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -GSEED="$s" --top-module tb_video_eq \
        --Mdir "$out/obj$s" "$src" "$out/old.sv" sim/pocket/video_eq/tb_video_eq.sv > "$out/build.log" 2>&1 || { grep -E '%Error' "$out/build.log" | head -5; exit 1; }
    "$out/obj$s/Vtb_video_eq" | grep -E '^(PASS|FAIL|clk)' | tail -4 | tee "$out/run$s.log" | tail -1 | grep -q '^PASS' && pass=$((pass + 1)) || cat "$out/run$s.log"
    rm -rf "$out/obj$s"
done
echo "video_eq: $pass/$seeds PASS"
[ "$pass" = "$seeds" ]
