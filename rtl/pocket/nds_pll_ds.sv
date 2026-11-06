// SPDX-License-Identifier: MIT
// Core PLL of the DS core (docs/phase2-integration.md, "Clocks"): Phase 1's
// nds_pll clocks plus clk_sys, the DS core's own clock, from the same VCO so
// every core clock is edge aligned with the DS bus clock.
//   clk_bus   33.513982 MHz  DS bus clock; SDRAM clients (the controller's clk1x)
//   clk_mem  100.541946 MHz  3 x bus; SDRAM controller (clk3x), PSRAM controller
//   clk_cram 100.541946 MHz  PSRAM chip clock, 6,838 ps after clk_mem (Phase 1)
//   clk_vid   16.756991 MHz  bus / 2: the video pixel clock
//   clk_vid90 the same, 90 degrees (14,919 ps) later (APF video_rgb_clock_90)
//   clk_sys   67.027964 MHz  2 x bus: the DS core (system blocks, 2D; the CPUs without CPU_FAST)
//   clk_cpu   89.370619 MHz  8/3 x bus: the CPUs with CPU_FAST (rtl/arm/cpu_domain.sv), crossed
//                            to clk_sys through cdc_* and timed as an unrelated clock
//   clk_2x   134.055928 MHz  2 x clk_sys, phase 0 (VCO / 6): RAMs double-pumped against
//                            clk_sys logic, timed in clk_sys's group (no crossing)
`default_nettype none
module nds_pll_ds (
    input wire refclk,                      // clk_74a
    input wire rst,
    output wire clk_bus, clk_mem, clk_cram, clk_vid, clk_vid90, clk_sys, clk_cpu, clk_2x,
    output wire locked
);
    altera_pll #(.fractional_vco_multiplier("true"), .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"), .number_of_clocks(8), .pll_type("General"), .pll_subtype("General"),
        .output_clock_frequency0("33.513982 MHz"), .phase_shift0("0 ps"), .duty_cycle0(50),
        .output_clock_frequency1("100.541946 MHz"), .phase_shift1("0 ps"), .duty_cycle1(50),
        .output_clock_frequency2("100.541946 MHz"), .phase_shift2("6838 ps"), .duty_cycle2(50),
        .output_clock_frequency3("16.756991 MHz"), .phase_shift3("0 ps"), .duty_cycle3(50),
        .output_clock_frequency4("16.756991 MHz"), .phase_shift4("14919 ps"), .duty_cycle4(50),
        .output_clock_frequency5("67.027964 MHz"), .phase_shift5("0 ps"), .duty_cycle5(50),
        .output_clock_frequency6("89.370619 MHz"), .phase_shift6("0 ps"), .duty_cycle6(50),
        .output_clock_frequency7("134.055928 MHz"), .phase_shift7("0 ps"), .duty_cycle7(50)) pll (
        .refclk(refclk), .rst(rst), .fbclk(1'b0), .fboutclk(), .locked(locked),
        .outclk({clk_2x, clk_cpu, clk_sys, clk_vid90, clk_vid, clk_cram, clk_mem, clk_bus}));
endmodule
`default_nettype wire
