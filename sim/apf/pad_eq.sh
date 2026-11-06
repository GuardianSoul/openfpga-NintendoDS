#!/usr/bin/env bash
# rtl/apf/io_pad_controller.v against Analogue's (at afc78fe6): pad_eq.sh [new.v] [seeds]
set -euo pipefail
cd "$(dirname "$0")/../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
src=${1:-rtl/apf/io_pad_controller.v}; seeds=${2:-2}
out=build/pad_eq/$(basename "$src" .v); mkdir -p "$out"
git show afc78fe6:rtl/apf/io_pad_controller.v | sed 's/^module io_pad_controller\b/module io_pad_controller_ref/' > "$out/ref.v"
# (iverilog: declarations before use; the transmit engine's block moved up, in both copies)
hoist() { python3 -c "
import sys
s=open(sys.argv[1]).read()
a=s.index('// word receive/transmit engine'); b=s.index('always @(posedge clk)', a)
blk=s[a:b]; s=s[:a]+s[b:]
s=s.replace('inout   reg             pad_1wire,','inout   wire            pad_1wire_w,').replace('synch_3 s01(pad_1wire,','reg pad_1wire; assign pad_1wire_w = pad_1wire;\\nsynch_3 s01(pad_1wire_w,')
k=s.index('// protocol fsm')
open(sys.argv[2],'w').write(s[:k]+blk+s[k:])" "$1" "$2"; }
hoist "$out/ref.v" "$out/ref2.v"; hoist "$src" "$out/new2.v"
pass=0
for s in $(seq 1 "$seeds"); do
    iverilog -g2012 -Ptb_pad_eq.SEED="$s" -s tb_pad_eq -o "$out/sim$s" "$out/new2.v" "$out/ref2.v" rtl/apf/common.v sim/apf/tb_pad_eq.sv 2>&1 | grep -v 'warning\|sorry' | head -8 || true
    vvp "$out/sim$s" | grep -E '^(PASS|FAIL|cycle)' | tail -6 | tee "$out/run$s.log" | tail -1 | grep -q '^PASS' && pass=$((pass + 1)) || cat "$out/run$s.log"
    rm -f "$out/sim$s"
done
echo "pad_eq: $pass/$seeds PASS"
[ "$pass" = "$seeds" ]
