// nds_rtc against its version at a base commit (nds_rtc_old, sim/ds_dev/equiv/rtc_lock.sh), the same inputs
module tb_rtc_lock (input logic clk, rst, tick, io_req, io_we, input logic [3:0] io_be, input logic [31:0] io_wdata,
                    output logic [31:0] a_rdata, b_rdata);
    parameter int SEC = 3000;
    nds_rtc_old #(.SEC_TICKS(SEC)) u_a (.clk, .rst, .tick, .io_req, .io_we, .io_be, .io_wdata, .io_rdata(a_rdata));
    nds_rtc     #(.SEC_TICKS(SEC)) u_b (.clk, .rst, .tick, .io_req, .io_we, .io_be, .io_wdata, .io_rdata(b_rdata));
endmodule
