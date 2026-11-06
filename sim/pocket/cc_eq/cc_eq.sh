#!/usr/bin/env bash
# nds_cart_scpu (SERV + sw/scpu firmware) against nds_cart_cache on random
# client reads (tb_cc_eq.sv).   cc_eq.sh [seeds] [ops] [plusargs...]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
seeds=${1:-8}; ops=${2:-3000}; shift $(( $# < 2 ? $# : 2 ))
out=build/cc_eq; mkdir -p "$out"
make -s build/scpu/cache.bin
python3 -c "import sys; d=open('build/scpu/cache.bin','rb').read(); d+=bytes(-len(d)%4); open('$out/cache.hex','w').write(''.join('%08x\n'%int.from_bytes(d[i:i+4],'little') for i in range(0,len(d),4)))"
verilator --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-lint \
    --top-module tb_cc_eq --Mdir "$out/obj" rtl/serv/*.v rtl/pocket/nds_cart_cache.sv rtl/pocket/nds_cart_scpu.sv \
    sim/pocket/cc_eq/tb_cc_eq.sv > "$out/build.log" 2>&1 || { grep -E "%Error" "$out/build.log" | head; exit 1; }
pass=0
for s in $(seq 1 "$seeds"); do
    "$out/obj/Vtb_cc_eq" +seed=$s +ops=$ops "$@" | grep -E "^(PASS|FAIL)|TIMEOUT|^(read|command|table|owner|ready)" | tail -12 | tee -a "$out/runs.log" | grep -q '^PASS' && pass=$((pass + 1)) || true
done
echo "cc_eq: $pass/$seeds PASS"
[ "$pass" = "$seeds" ]
