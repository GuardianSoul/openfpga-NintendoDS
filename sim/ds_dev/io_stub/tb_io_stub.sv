// nds_io's sound stub with and without the engine: ARM7 writes to
// 0x4000500-0x40007FC then reads them back. With snd_real (SOUND=1) the
// addresses past the sound registers (0x520-0x7FF) must read 0, as on a DS;
// without it the stub keeps what was written (builds without rtl/sound).
// io_stub.sh builds and runs it.
`timescale 1ns/1ps
module tb_io_stub;
    logic clk = 0; always #5 clk = !clk;
    logic rst = 1, io_req = 0, io_we = 0;
    logic [3:0] io_be = 4'hF;
    logic [23:2] io_addr = 0;
    logic [31:0] io_wdata = 0;
    wire io_ack_s, io_ack_n; wire [31:0] rd_s, rd_n;
    `define IO(NM, SR, ACK, RD) nds_io NM (.clk, .rst, .io_req, .io_cpu(1'b1), .io_we, .io_be, .io_addr, .io_wdata, \
        .io_ack(ACK), .io_rdata(RD), .sys_req(), .sys_rdata(32'd0), .disp_req(), .disp_rdata(32'd0), .cart_req(), .cart_reg(), \
        .cart_rdata(32'd0), .spi_req(), .spi_rdata(32'd0), .rtc_req(), .rtc_rdata(32'd0), .snd_req(), .snd_ack(1'b1), \
        .snd_rdata(32'hDEAD0000), .snd_real(SR), .gx_req(), .gx_ack(1'b0), .gx_rdata(32'd0), .gx_real(1'b0), .gx_ovf(1'b0), \
        .disp3dcnt_o(), .keys(12'd0), .pen_down(1'b0), .lid_closed(1'b0), .rom_size(32'd0), .mem_dirty(1'b0), .save_info(8'd0), \
        .vramstat(2'd0), .powcnt1(), .powcnt2(), .exmem_o(), .wramcnt(), .vramcnt(), .bootctl(), \
        .halt7(), .irq_key9(), .irq_key7(), .gx_irq())
    `IO(u_snd1, 1'b1, io_ack_s, rd_s);
    `IO(u_snd0, 1'b0, io_ack_n, rd_n);
    integer bad = 0, nz_s = 0, kept_n = 0;
    task automatic acc(input logic we, input logic [23:2] a, input logic [31:0] d);
        @(negedge clk); io_req = 1; io_we = we; io_addr = a; io_wdata = d;
        @(negedge clk); io_req = 0; io_we = 0;
        repeat (2) @(negedge clk);
    endtask
    initial begin
        repeat (3) @(negedge clk); rst = 0;
        for (int w = 'h148; w < 'h200; w++) acc(1, 22'(w), 32'hA5000000 | w);
        for (int w = 'h148; w < 'h200; w++) begin
            @(negedge clk); io_req = 1; io_we = 0; io_addr = 22'(w);
            @(negedge clk); io_req = 0;
            wait (io_ack_s && io_ack_n); #1;
            if (rd_s != 32'd0) begin nz_s++; if (bad++ < 3) $display("  SOUND=1: 0x%h reads %h", 32'h04000000 | (w << 2), rd_s); end
            if (rd_n != 32'd0) kept_n++;
            repeat (2) @(negedge clk);
        end
        // SOUND=0 must keep the stub's contents (aliased onto 128 words)
        if (kept_n == 0) begin bad++; $display("  SOUND=0: stub kept nothing"); end
        $display("%s: SOUND=1 nonzero reads %0d of %0d, SOUND=0 kept %0d", bad ? "FAIL" : "PASS", nz_s, 'h200 - 'h148, kept_n);
        $finish;
    end
endmodule
