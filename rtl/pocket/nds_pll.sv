// SPDX-License-Identifier: MIT
// Core PLL of the Phase 1 shell (docs/phase1-foundation.md, "Clocks"): every
// core clock is a multiple or fraction of the DS bus clock, from one PLL so
// the SDRAM controller's 3:1 clock pair is edge aligned.
//   clk_bus   33.513982 MHz  DS bus clock; SDRAM clients (the controller's clk1x)
//   clk_mem  100.541946 MHz  3 x bus; SDRAM controller (clk3x), PSRAM controller
//   clk_cram 100.541946 MHz  PSRAM chip clock, 6,838 ps after clk_mem: 0.6875 of
//                            the period, the fraction openfpga-PlayStation's hardware-
//                            tested 6,600 ps is at 104.17 MHz (6,600 itself is
//                            no legal step; the fitted VCO is 603.5 MHz, steps
//                            of 207.1 ps; 6,631 failed output setup by 0.13 ns)
//   clk_vid   16.756991 MHz  bus / 2: the video pixel clock (3 pixels per DS dot)
//   clk_vid90 the same, 90 degrees (14,919 ps) later (APF video_rgb_clock_90)
`default_nettype none
module nds_pll (
    input wire refclk,                      // clk_74a
    input wire rst,
    output wire clk_bus, clk_mem, clk_cram, clk_vid, clk_vid90,
    output wire locked
);
    altera_pll #(.fractional_vco_multiplier("true"), .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"), .number_of_clocks(5), .pll_type("General"), .pll_subtype("General"),
        .output_clock_frequency0("33.513982 MHz"), .phase_shift0("0 ps"), .duty_cycle0(50),
        .output_clock_frequency1("100.541946 MHz"), .phase_shift1("0 ps"), .duty_cycle1(50),
        .output_clock_frequency2("100.541946 MHz"), .phase_shift2("6838 ps"), .duty_cycle2(50),
        .output_clock_frequency3("16.756991 MHz"), .phase_shift3("0 ps"), .duty_cycle3(50),
        .output_clock_frequency4("16.756991 MHz"), .phase_shift4("14919 ps"), .duty_cycle4(50)) pll (
        .refclk(refclk), .rst(rst), .fbclk(1'b0), .fboutclk(), .locked(locked),
        .outclk({clk_vid90, clk_vid, clk_cram, clk_mem, clk_bus}));
endmodule
`default_nettype wire
