// SPDX-License-Identifier: MIT
// Simulation stand-ins for the Intel primitives of the Phase 1 core: the core
// PLL (ideal clocks with the configured ratios and phases, lock after 2 us),
// the audio PLL, and altddio_out (both halves registered on the rising edge,
// high half out while the clock is high).
`timescale 1ps/1ps
`default_nettype none
module nds_pll (
    input wire refclk, rst,
    output reg clk_bus = 0, clk_mem = 0, clk_vid = 0,
    output reg clk_cram = 0, clk_vid90 = 0,
    output reg locked = 0
);
    // 100.541946 MHz: 9,946 ps; bus = 3 x, video = 6 x that period
    always #4973 clk_mem = !clk_mem;
    always #14919 clk_bus = !clk_bus;
    initial begin #14919; forever begin clk_vid = !clk_vid; #29838; end end   // rises with clk_bus
    // transport delays (an inertial 6.6 ns delay would swallow a 5 ns half period)
    always @(clk_mem) clk_cram <= #6838 clk_mem;
    always @(clk_vid) clk_vid90 <= #14919 clk_vid;
    always @(posedge rst or negedge rst) if (rst) locked <= 0; else locked <= #2000000 1;
endmodule

module mf_audio_pll (
    input wire refclk, rst,
    output reg outclk_0 = 0, outclk_1 = 0,
    output wire locked
);
    always #40690 outclk_0 = !outclk_0;     // 12.288 MHz
    always #162760 outclk_1 = !outclk_1;    // 3.072 MHz
    assign locked = 1;
endmodule

module altddio_out #(parameter integer width = 1, parameter extend_oe_disable = "OFF",
    parameter intended_device_family = "Cyclone V", parameter invert_output = "OFF",
    parameter lpm_hint = "UNUSED", parameter lpm_type = "altddio_out", parameter oe_reg = "UNREGISTERED",
    parameter power_up_high = "OFF") (
    input wire [width-1:0] datain_h, datain_l,
    input wire outclock, aclr, aset, oe, outclocken, sclr, sset,
    output wire [width-1:0] dataout
);
    reg [width-1:0] h = 0, l = 0;
    always @(posedge outclock) begin h <= datain_h; l <= datain_l; end
    assign dataout = outclock ? h : l;
endmodule
`default_nettype wire
