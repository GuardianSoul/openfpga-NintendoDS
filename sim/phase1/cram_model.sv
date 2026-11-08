// SPDX-License-Identifier: MIT
// Pin model of one Pocket CellularRAM chip (AS1C8M16PL: two 4M x 16 dies on
// CE0#/CE1#) for the Phase 1 test, written from the controller's side of the
// datasheet. Simulation only.
//   - Address: {A[21:16], DQ} is latched while ADV# is low (CE# low).
//   - Asynchronous write (chip clock low): WE# low with the address phase,
//     then data on DQ; the word is stored when WE# or CE# rises, with the
//     byte lanes UB#/LB# seen low during the cycle.
//   Address, data and lanes are sampled on the falling edges of sclk (the
//   controller's clock), so the model needs no X or Z (Verilator is 2-state):
//   the value stored is the last one sampled before the write ends. A rising chip-clock edge
//     during an asynchronous write is an error (on the Pocket the chips then
//     start a burst write: openfpga-PlayStation overnight-decisions.md 2026-10-15).
//   - CRE high: the latched address is a configuration register write;
//     A[19:18] = 2'b10 is the BCR (bit 15 = 0: synchronous mode).
//   - Synchronous burst read (BCR bit 15 = 0): a chip-clock rising edge with
//     CE# and ADV# low and WE# high latches the address. WAIT (driven high
//     whenever CE# is low and no data is out) drops when data is out: the
//     word for edge n >= LAT (n counted from the latching edge) goes out
//     T_CK ns after that edge. Crossing a 128-halfword row adds ROW_WAIT
//     edges of WAIT. DQ is driven only while OE# is low.
// Storage is sparse; unwritten halfwords read as a function of the address.
`timescale 1ns/1ps
`default_nettype none
module cram_model #(parameter integer LAT = 4, parameter integer ROW_WAIT = 2,
                    parameter real T_CK = 5.0, parameter NAME = "cram") (
    input wire sclk,
    input wire clk,
    input wire [21:16] a,
    inout wire [15:0] dq,
    output wire wait_o,
    input wire adv_n, cre, ce0_n, ce1_n, oe_n, we_n, ub_n, lb_n
);
    reg [15:0] mem [int];
    reg [15:0] bcr [0:1];
    initial begin bcr[0] = 16'h9D1F; bcr[1] = 16'h9D1F; end
    integer errors = 0, writes = 0, bursts = 0, configs = 0;
    function [15:0] fill(input int i);
        fill = i[15:0] ^ (i[22:7] * 16'h3b) ^ 16'h5a5a;
    endfunction
    function [15:0] peek(input int i);
        peek = mem.exists(i) ? mem[i] : fill(i);
    endfunction

    wire ce = !ce0_n || !ce1_n;
    wire die_now = !ce1_n;
    reg [21:0] addr = 0;
    reg die = 0;
    always @(negedge sclk) if (ce && !adv_n) begin addr <= {a, dq}; die <= die_now; end

    // ---------------- asynchronous writes and configuration ----------------
    wire wr_active = ce && !we_n;
    reg [15:0] wdata = 0;
    reg [1:0] wbe = 0;
    reg wcre = 0;
    always @(negedge sclk)
        if (wr_active) begin
            if (adv_n) wdata <= dq;
            if (!ub_n) wbe[1] <= 1;
            if (!lb_n) wbe[0] <= 1;
            if (cre) wcre <= 1;
        end else begin wbe <= 0; wcre <= cre; end
    always @(negedge wr_active) begin
        if (wcre) begin
            configs++;
            if (addr[19:18] == 2'b10) bcr[die] = addr[15:0];
        end else begin
            int i;
            reg [15:0] h;
            i = {die, addr};
            h = peek(i);
            if (wbe[0]) h[7:0] = wdata[7:0];
            if (wbe[1]) h[15:8] = wdata[15:8];
            mem[i] = h;
            writes++;
        end
    end

    // ---------------- synchronous burst reads ----------------
    reg bursting = 0;
    integer n = 0, k = 0, stall = 0;
    reg [21:0] baddr = 0;
    reg bdie = 0;
    reg [15:0] dout = 0;
    reg dout_v = 0, wait_r = 1;
    always @(posedge clk) begin
        if (wr_active && !wcre) begin
            errors++;
            if (errors < 10) $display("ERROR %0s: chip clock edge during an asynchronous write at %0t", NAME, $time);
        end
        if (!ce) bursting = 0;
        else if (!adv_n && we_n && !bcr[die_now][15]) begin
            bursting = 1; baddr = {a, dq}; bdie = die_now; n = 0; k = 0; stall = 0; bursts++;
            dout_v <= #(T_CK) 0; wait_r <= #(T_CK) 1;
        end else if (bursting) begin
            n++;
            if (n >= LAT) begin
                if (stall > 0) begin
                    stall--;
                    dout_v <= #(T_CK) 0; wait_r <= #(T_CK) 1;
                end else begin
                    // BCR bit 3 = 0 with length 8 (bits 2:0 = 010): the burst wraps within its 8-word block
                    // (nds_psram CWF); otherwise continuous, with the row-boundary wait
                    if (!bcr[bdie][3] && bcr[bdie][2:0] == 3'b010)
                        dout <= #(T_CK) peek({bdie, baddr[21:3], 3'(baddr[2:0] + k[2:0])});
                    else
                        dout <= #(T_CK) peek({bdie, baddr + k[21:0]});
                    dout_v <= #(T_CK) 1; wait_r <= #(T_CK) 0;
                    k++;
                    if ((bcr[bdie][3] || bcr[bdie][2:0] != 3'b010) && ((baddr + k) & 22'h7F) == 0) stall = ROW_WAIT;
                end
            end
        end
    end
    assign dq = (ce && !oe_n && we_n && bursting && dout_v) ? dout : 16'bz;
    assign wait_o = ce ? (bursting ? wait_r : 1'b1) : 1'bz;
endmodule
`default_nettype wire
