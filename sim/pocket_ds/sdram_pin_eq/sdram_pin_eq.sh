#!/usr/bin/env bash
# nds_sdram_mc's SDRAM pins against its version at REF (default da920750), clock by clock: tb_sdram_mc's
# random traffic (reads of 1/4/8 words, byte-masked writes, write chains) drives both, each with its own
# chip model; every pin (command, address, bank, DQM, DQ value and drive, chip clock) and every client
# output (c_ready, r_*, bw_read) must match on both clock edges. OPEN=1 OUT_REG=1 (the DS build's setting).
#   sdram_pin_eq.sh [REF] [seeds] [RTL file to test instead of rtl/pocket/nds_sdram_mc.sv]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-da920750}; seeds=${2:-4}; dut=${3:-rtl/pocket/nds_sdram_mc.sv}
out=build/sdram_pin_eq; rm -rf "$out"; mkdir -p "$out"
git show "$ref:rtl/pocket/nds_sdram_mc.sv" | sed -E 's/^module nds_sdram_mc /module nds_sdram_mc_ref /' > "$out/ref.sv"
grep -q "module nds_sdram_mc_ref" "$out/ref.sv"
# the testbench: tb_sdram_mc with OPEN/OUT_REG set, a second (reference) controller and the comparison
python3 - "$out/tb.sv" <<'PY'
import sys, re
t = open('sim/pocket_ds/tb_sdram_mc.sv').read()
t = t.replace('nds_sdram_mc #(.POWERUP_CYCLES(400)) dut', 'nds_sdram_mc #(.POWERUP_CYCLES(400), .OPEN(1), .OUT_REG(1)) dut')
anchor = '    // golden copy of the words written so far'
assert t.count(anchor) == 1
t = t.replace(anchor, '''    wire [15:0] dq_r; wire [12:0] a_r; wire [1:0] ba_r, dqm_r; wire nwe_r, nras_r, ncas_r, cke_r, sclk_r;
    wire ready_r, c_ready_r, r_valid_r, r_last_r, bw_read_r; wire [31:0] r_data_r;
    nds_sdram_mc_ref #(.POWERUP_CYCLES(400), .OPEN(1), .OUT_REG(1)) ref_mc (.clk, .init, .ready(ready_r),
        .c_valid, .c_hurry(1'b0), .c_we, .c_addr, .c_rb(c_addr[22:8]), .c_n, .c_wdata, .c_be, .c_ready(c_ready_r),
        .r_valid(r_valid_r), .r_data(r_data_r), .r_last(r_last_r),
        .bw_valid, .bw_addr(bw_head[55:32]), .bw_data(bw_head[31:0]), .bw_read(bw_read_r), .ref_late(),
        .SDRAM_DQ(dq_r), .SDRAM_A(a_r), .SDRAM_BA(ba_r), .SDRAM_DQML(dqm_r[0]), .SDRAM_DQMH(dqm_r[1]),
        .SDRAM_nWE(nwe_r), .SDRAM_nRAS(nras_r), .SDRAM_nCAS(ncas_r), .SDRAM_CKE(cke_r), .SDRAM_CLK(sclk_r));
    wire #2.0 chip_clk_r = sclk_r;
    sdram_chip_model #(.CAS(3), .T_AC(6.0), .T_OH(2.5), .T_RET(2.0)) chip_r (.clk(chip_clk_r), .cke(cke_r), .ncs(1'b0),
        .nras(nras_r), .ncas(ncas_r), .nwe(nwe_r), .a(a_r), .ba(ba_r), .dqm(dqm_r), .dq(dq_r));
    wire [127:0] pins   = {dq,   a,   ba,   dqm,   nwe,   nras,   ncas,   cke,   sclk,   ready,   c_ready,   r_valid,   r_last,   bw_read,   r_data};
    wire [127:0] pins_r = {dq_r, a_r, ba_r, dqm_r, nwe_r, nras_r, ncas_r, cke_r, sclk_r, ready_r, c_ready_r, r_valid_r, r_last_r, bw_read_r, r_data_r};
    integer eq_diff = 0; longint eq_n = 0, eq_cmds = 0;
    task automatic eq_cmp(input string edge_name);
        eq_n++;
        if ({nras, ncas, nwe} != 3'b111) eq_cmds++;
        if (pins !== pins_r) begin
            eq_diff++;
            if (eq_diff <= 5) $display("EQ DIFF at %0t (%s): new %h ref %h", $realtime, edge_name, pins, pins_r);
        end
    endtask
    always @(negedge clk) #1 eq_cmp("neg+1");
    always @(posedge clk) #1 eq_cmp("pos+1");
    final $display("EQ %0s: %0d samples, %0d with a command on the pins, %0d differ", eq_diff == 0 ? "SAME" : "DIFFERENT", eq_n, eq_cmds, eq_diff);

''' + anchor)
open(sys.argv[1], 'w').write(t)
PY
verilator --binary --timing -O2 -j 8 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-MULTIDRIVEN \
    --top-module tb_sdram_mc --Mdir "$out/obj" sim/phase1/sim_prims.sv sim/phase1/sdram_chip_model.sv "$dut" "$out/ref.sv" "$out/tb.sv" \
    > "$out/build.log" 2>&1 || { grep -E "%Error" "$out/build.log" | head; exit 1; }
pass=0
for s in $(seq 1 "$seeds"); do
    r=$("$out/obj/Vtb_sdram_mc" +seed=$s +verilator+seed+$s | grep -E "^(EQ|TEST|reads)|EQ DIFF" | tee -a "$out/runs.log")
    echo "seed $s: $(echo "$r" | grep -E '^EQ (SAME|DIFF)') $(echo "$r" | grep -E '^TEST')"
    echo "$r" | grep -q '^EQ SAME' && echo "$r" | grep -q 'TEST PASSED' && pass=$((pass + 1)) || true
done
rm -rf "$out/obj"
echo "sdram_pin_eq: $pass/$seeds PASS"
[ "$pass" = "$seeds" ]
