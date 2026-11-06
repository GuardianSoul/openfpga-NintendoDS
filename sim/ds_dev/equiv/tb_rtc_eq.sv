// Equivalence top: rtl/ds/nds_rtc.sv against a reference copy (module
// nds_rtc_ref), same inputs; sim/ds_dev/equiv/rtc_eq.cpp compares io_rdata. Since the bridge load went
// (2026-10-28: the boot program sets the time) the reference's load inputs are tied off and the test sets
// dates through the register, as the boot program does.
module tb_rtc_eq #(parameter int SEC_TICKS = 37) (
    input  logic        clk, rst, tick, io_req, io_we, init_valid,
    input  logic [3:0]  io_be,
    input  logic [31:0] io_wdata, init_date_bcd, init_time_bcd,
    output logic [31:0] q_new, q_ref
);
    nds_rtc #(.SEC_TICKS(SEC_TICKS)) u_new (.clk, .rst, .tick, .io_req, .io_we, .io_be, .io_wdata,
        .io_rdata(q_new));
    nds_rtc_ref #(.SEC_TICKS(SEC_TICKS)) u_ref (.clk, .rst, .tick, .io_req, .io_we, .io_be, .io_wdata,
        .io_rdata(q_ref), .init_valid(1'b0), .init_date_bcd(32'd0), .init_time_bcd(32'd0));
endmodule
