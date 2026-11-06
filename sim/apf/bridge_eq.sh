#!/usr/bin/env bash
# rtl/apf/io_bridge_peripheral.v against Analogue's (at afc78fe6): bridge_eq.sh [new.v] [seeds]
set -euo pipefail
cd "$(dirname "$0")/../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
src=${1:-rtl/apf/io_bridge_peripheral.v}; seeds=${2:-2}
out=build/bridge_eq/$(basename "$src" .v); mkdir -p "$out"
git show afc78fe6:rtl/apf/io_bridge_peripheral.v | sed 's/^module io_bridge_peripheral\b/module io_bridge_peripheral_ref/' > "$out/ref.v"
# (iverilog: declarations before use, no inout reg: the spiclk block's declarations moved up, the pins renamed)
fix() { python3 -c "
import sys,re
s=open(sys.argv[1]).read()
for n in ('spimosi','spimiso','spiclk'):
    s=s.replace('inout   reg             phy_%s,'%n,'inout   wire            phy_%s_w,'%n)
k=s.index('// clock domain: clk (74.25mhz) rising edge')
decl='''reg phy_spimosi, phy_spimiso, phy_spiclk; assign phy_spimosi_w = phy_spimosi, phy_spimiso_w = phy_spimiso, phy_spiclk_w = phy_spiclk;
reg [1:0] rx_latch_idx; reg [7:0] rx_dat; reg [7:0] rx_byte; reg rx_byte_done;
reg [31:0] pmp_rd_data_e; reg [31:0] pmp_wr_data_latch;
'''
s=re.sub(r'\s*reg \[1:0\]\s+rx_latch_idx;.*?reg\s+rx_byte_done;\n','\n',s,flags=re.S)
s=re.sub(r'\s*reg \[31:0\]\s+pmp_wr_data_latch;\n\s*reg \[31:0\]\s+pmp_rd_data_e;[^\n]*\n','\n',s)
s=s[:k]+decl+s[k:]
s=s.replace('(phy_spimosi','(phy_spimosi_w').replace('{phy_spimosi, phy_spimiso}','{phy_spimosi_w, phy_spimiso_w}').replace('rx_dat[7:2], phy_spimosi, phy_spimiso','rx_dat[7:2], phy_spimosi_w, phy_spimiso_w').replace('posedge phy_spiclk','posedge phy_spiclk_w')
open(sys.argv[2],'w').write(s)" "$1" "$2"; }
fix "$out/ref.v" "$out/ref2.v"; fix "$src" "$out/new2.v"
pass=0
for s in $(seq 1 "$seeds"); do
    iverilog -g2012 -Ptb_bridge_eq.SEED="$s" -s tb_bridge_eq -o "$out/sim$s" "$out/new2.v" "$out/ref2.v" rtl/apf/common.v sim/apf/tb_bridge_eq.sv 2>&1 | grep -v 'warning\|sorry' | head -8 || true
    vvp "$out/sim$s" | grep -E '^(PASS|FAIL|cycle)' | tail -6 | tee "$out/run$s.log" | tail -1 | grep -q '^PASS' && pass=$((pass + 1)) || cat "$out/run$s.log"
    rm -f "$out/sim$s"
done
echo "bridge_eq: $pass/$seeds PASS"
[ "$pass" = "$seeds" ]
