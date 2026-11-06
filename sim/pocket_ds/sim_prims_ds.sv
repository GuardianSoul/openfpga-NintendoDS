// SPDX-License-Identifier: MIT
// Simulation stand-in for the DS core's PLL (rtl/pocket/nds_pll_ds.sv):
// ideal clocks with the configured ratios and phases, lock after 2 us. The
// audio PLL and altddio_out come from sim/phase1/sim_prims.sv.
`timescale 1ps/1ps
`default_nettype none
module nds_pll_ds (
    input wire refclk, rst,
    output reg clk_bus = 0, clk_mem = 0, clk_vid = 0,
    output reg clk_cram = 0, clk_vid90 = 0, clk_sys = 0, clk_cpu = 0, clk_2x = 0,
    output reg locked = 0
);
    // 100.541946 MHz: 9,946 ps; bus = 3 x that period, sys = 1.5 x, video = 6 x
    always #4973 clk_mem = !clk_mem;
    always #14919 clk_bus = !clk_bus;
    initial begin #14919; forever begin clk_sys = 1; #7460; clk_sys = 0; #7459; end end  // rises with clk_bus
    // clk_2x: two periods per clk_sys period (14,919 ps), rising with clk_sys
    initial begin #14919; forever begin clk_2x = 1; #3730; clk_2x = 0; #3730; clk_2x = 1; #3730; clk_2x = 0; #3729; end end
    initial begin #14919; forever begin clk_vid = !clk_vid; #29838; end end
    always @(clk_mem) clk_cram <= #6838 clk_mem;
    always @(clk_vid) clk_vid90 <= #14919 clk_vid;
    // clk_cpu 89.370619 MHz = 8/9 of clk_mem (11,189 ps), as the PLL's counter 6
    initial begin #3000; forever begin clk_cpu = 1; #5595; clk_cpu = 0; #5594; end end
    always @(posedge rst or negedge rst) if (rst) locked <= 0; else locked <= #2000000 1;
endmodule
`default_nettype wire
