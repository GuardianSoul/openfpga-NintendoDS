// VRAM bandwidth on the Pocket's memory path (docs/phase2-integration.md,
// "VRAM bandwidth"): nds_vram's external port as core_top_ds wires it
// (nds_vm_split -> nds_x2b -> nds_sdram client 3 -> the SDRAM pin model),
// fed with back-to-back 32-byte block reads at spread addresses, alone or
// with other clients busy. Prints clk_sys cycles per block.
//   +blocks=N (default 2000)  +load=0|1 (1: client 2 posts a write every 64
//   clk_bus, as APF data would, and client 4 reads a quad every 40 clk_bus)
`timescale 1ps/1ps
module tb_vram_bw;
    // clocks as sim_prims_ds: clk_mem 100.54 MHz, clk_bus = /3, clk_sys = 2 x clk_bus
    reg clk_mem = 0, clk_bus = 0, clk_sys = 0;
    always #4973 clk_mem = !clk_mem;
    always #14919 clk_bus = !clk_bus;
    initial begin #14919; forever begin clk_sys = 1; #7460; clk_sys = 0; #7459; end end
    reg rst_bus = 1, rst_sys = 1;
    wire take;
    nds_bus_phase phase (.clk_bus, .clk_sys, .take);

    // ---- the VRAM port (clk_sys)
    reg vm_req = 0, vm_blk = 1;
    reg [20:2] vm_addr = 0;
    wire vm_ack, vm_rvalid;
    wire [31:0] vm_rdata;
    wire vs_req, vs_we, vs_quad, vs_ack, vs_rvalid;
    wire [23:0] vs_addr;
    wire [31:0] vs_wdata, vs_rdata;
    wire [3:0] vs_be;
    localparam integer NC = 6;
    wire [NC-1:0] c_valid, c_write, c_quad, c_ready, r_valid;
    wire [NC*24-1:0] c_addr;
    wire [NC*32-1:0] c_wdata;
    wire [NC*4-1:0] c_be;
    wire [31:0] r_data;
    parameter bit OCT = 0;
    nds_vm_split #(.BASE_W(24'h0), .OCT(OCT)) x_vsplit (.clk(clk_sys), .reset(rst_sys),
        .vm_req, .vm_we(1'b0), .vm_blk, .vm_addr, .vm_be(4'hF), .vm_wdata(32'd0),
        .vm_ack, .vm_rvalid, .vm_rdata,
        .s_req(vs_req), .s_we(vs_we), .s_quad(vs_quad), .s_addr(vs_addr), .s_wdata(vs_wdata), .s_be(vs_be),
        .s_ack(vs_ack), .s_rvalid(vs_rvalid), .s_rdata(vs_rdata));
    nds_x2b #(.AW(24)) x_vram (.clk_sys, .clk_bus, .reset(rst_bus), .take,
        .s_req(vs_req), .s_we(vs_we), .s_quad(vs_quad), .s_addr(vs_addr), .s_wdata(vs_wdata), .s_be(vs_be),
        .s_ack(vs_ack), .s_rvalid(vs_rvalid), .s_rdata(vs_rdata),
        .c_valid(c_valid[3]), .c_write(c_write[3]), .c_quad(c_quad[3]), .c_addr(c_addr[95:72]),
        .c_wdata(c_wdata[127:96]), .c_be(c_be[15:12]), .c_ready(c_ready[3]), .r_valid(r_valid[3]), .r_data(r_data));

    // ---- other clients (clk_bus): 2 posted writes, 4 quad reads, the rest idle
    integer load = 0;
    reg w2 = 0, q4 = 0;
    integer cnt2 = 0, cnt4 = 0;
    // initial pattern: word a of the 64 test blocks holds pat(a), written through client 2
    function automatic [31:0] pat(input [23:0] a); pat = {a[15:0], ~a[15:0]} ^ 32'h5A3C_9617; endfunction
    function automatic [23:0] blk_w(input integer n); blk_w = (n % 64) * 37 * 8; endfunction
    integer init_n = 0;
    reg initing = 1;
    reg [23:0] w2_addr = 0;
    reg [31:0] w2_data = 0;
    always @(posedge clk_bus) begin
        if (c_ready[2]) w2 <= 0;
        if (initing && !rst_bus && sdram_ready && !w2 && !c_ready[2]) begin
            if (init_n == 64 * 8) initing <= 0;
            else begin
                w2 <= 1; w2_addr <= blk_w(init_n / 8) + init_n % 8; w2_data <= pat(blk_w(init_n / 8) + init_n % 8);
                init_n <= init_n + 1;
            end
        end else if (!initing) begin w2_addr <= 24'h20_0000 + cnt2; w2_data <= 32'h1234_5678; end
        if (c_ready[4]) q4 <= 0;
        if (load != 0 && !rst_bus && !initing) begin
            cnt2 <= cnt2 == 63 ? 0 : cnt2 + 1; if (cnt2 == 0) w2 <= 1;
            cnt4 <= cnt4 == 39 ? 0 : cnt4 + 1; if (cnt4 == 0) q4 <= 1;
        end
    end
    assign c_valid[0] = 0, c_valid[1] = 0, c_valid[5] = 0, c_valid[2] = w2, c_valid[4] = q4;
    assign c_write = 6'b000100, c_quad = 6'b010000 | {2'b0, c_quad[3], 3'b0};
    assign c_addr[23:0] = 0, c_addr[47:24] = 0, c_addr[71:48] = w2_addr, c_addr[119:96] = 24'h40_0000 + {cnt4, 2'b00};
    assign c_addr[143:120] = 0;
    assign c_wdata[63:0] = 0, c_wdata[95:64] = w2_data, c_wdata[191:128] = 0;
    assign c_be[7:0] = 0, c_be[11:8] = 4'hF, c_be[23:16] = 0;

    wire sdram_ready;
    wire [15:0] dram_dq;
    wire [12:0] dram_a;
    wire [1:0] dram_ba, dram_dqm;
    wire dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;
    parameter integer OPEN_ROW = 0;
    nds_sdram #(.N(NC), .OPEN_ROW(OPEN_ROW), .OCT(OCT ? 6'b001000 : 6'b0)) sdram (.clk_bus, .clk_mem, .reset(rst_bus), .ready(sdram_ready),
        .c_valid, .c_write, .c_quad, .c_addr, .c_wdata, .c_be, .c_ready, .r_valid, .r_data,
        .bw_valid(1'b0), .bw_addr(24'd0), .bw_data(32'd0), .bw_read(),
        .dram_dq, .dram_a, .dram_ba, .dram_dqm, .dram_clk, .dram_cke, .dram_ras_n, .dram_cas_n, .dram_we_n);
    wire #2.0 chip_clk = dram_clk;
    sdram_chip_model #(.CAS(3), .T_AC(6.0), .T_OH(2.5), .T_RET(2.0), .NAME("sdram")) sdram_chip (
        .clk(chip_clk), .cke(dram_cke), .ncs(1'b0), .nras(dram_ras_n), .ncas(dram_cas_n), .nwe(dram_we_n),
        .a(dram_a), .ba(dram_ba), .dqm(dram_dqm), .dq(dram_dq));

    // ---- the block stream: next block asked for as soon as the last word is in
    integer blocks = 2000, done = 0, words = 0, errors = 0;
    reg [31:0] sum = 0;                     // a checksum of every word read, in order
    longint t0 = 0, c0 = 0, cyc = 0;
    always @(posedge clk_sys) cyc++;
    integer pipe = 0;                        // +pipe=1: the next block is asked for once this one is accepted
    integer asked = 1;
    always @(posedge clk_sys) begin
        if (vm_ack) begin
            vm_req <= 0;
            if (pipe != 0 && asked < blocks) begin vm_req <= 1; vm_addr <= blk_w(asked); asked <= asked + 1; end
        end
        if (vm_rvalid) begin
            words <= words + 1;
            sum <= {sum[30:0], sum[31]} ^ vm_rdata ^ words;
            if (vm_rdata !== pat(blk_w(done) + words % 8)) begin
                errors++;
                if (errors < 5) $display("ERROR block %0d word %0d: %08x, expected %08x", done, words % 8, vm_rdata, pat(blk_w(done) + words % 8));
            end
            if (words % 8 == 7) begin
                done <= done + 1;
                if (pipe == 0 && done + 1 < blocks) begin
                    vm_req <= 1;
                    vm_addr <= blk_w(done + 1);                  // 64 blocks spread over rows and banks
                end
            end
        end
    end
    initial begin
        void'($value$plusargs("blocks=%d", blocks));
        void'($value$plusargs("load=%d", load));
        void'($value$plusargs("pipe=%d", pipe));
        repeat (20) @(posedge clk_bus);
        rst_bus = 0; rst_sys = 0;
        wait (sdram_ready);
        wait (!initing);
        repeat (10) @(posedge clk_sys);
        c0 = cyc;
        @(posedge clk_sys) begin vm_req <= 1; vm_addr <= 0; end
        wait (done == blocks);
        $display("model: %0d reads %0d writes %0d errors, init words %0d", sdram_chip.reads, sdram_chip.writes, sdram_chip.errors, init_n);
        $display("VRAM blocks %0d, load %0d: %.1f clk_sys cycles per block, data checksum %08x, %0d wrong words", blocks, load, real'(cyc - c0) / blocks, sum, errors);
        $finish;
    end
endmodule
