// Test top for the ARM7 SPI bus and RTC (sim/ds_dev/tb_ds_dev.cpp): both
// devices side by side, the RTC's second shortened to SEC_TICKS DS clocks.
module tb_ds_dev #(
    parameter int SEC_TICKS = 1000
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        tick,
    input  logic        spi_req,
    input  logic        rtc_req,
    input  logic        io_we,
    input  logic [3:0]  io_be,
    input  logic [31:0] io_wdata,
    output logic [31:0] spi_rdata,
    output logic [31:0] rtc_rdata,
    output logic        spi_irq,
    output logic        pwr_off,
    output logic        fw_req,
    output logic [17:2] fw_addr,
    input  logic        fw_ack,
    input  logic [31:0] fw_rdata,
    input  logic        pen,
    input  logic [7:0]  tx,
    input  logic [7:0]  ty,
    output logic        pen_down
);
    nds_spi u_spi (
        .clk, .rst, .tick, .io_req(spi_req), .io_we, .io_be, .io_wdata, .io_rdata(spi_rdata),
        .irq(spi_irq), .pwr_off, .fw_req, .fw_addr, .fw_ack, .fw_rdata,
        .pen, .tx, .ty, .pen_down);
    nds_rtc #(.SEC_TICKS(SEC_TICKS)) u_rtc (
        .clk, .rst, .tick, .io_req(rtc_req), .io_we, .io_be, .io_wdata, .io_rdata(rtc_rdata));
endmodule
