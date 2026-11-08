// nds_vram lockstep (sim/ds/vram_eq.sh): nds_vram_old (the version at REF,
// renamed) and nds_vram (the working tree) with the core's VR_* settings get
// the same inputs every clock, and every output is compared every clock.
// The inputs that answer outputs (vm_ack, the read words, cw_ack, c_ack's
// end of request) are computed from the old model's outputs, so they stay
// identical as long as the outputs do. Stimulus: CPU/DMA reads and writes
// in a small window (read-line hits, writes into the line, posted words),
// 2D blocks, capture halfwords, save accesses, FIFO acks and drains.
//   +seed=S +cycles=N
`timescale 1ns/1ps
module tb_vram_eq;
    import gpu2d_pkg::*;
    reg clk = 0; always #1 clk = !clk;
    reg rst = 1;
    integer seed = 1, cycles = 2000000;
    initial begin void'($value$plusargs("seed=%d", seed)); void'($value$plusargs("cycles=%d", cycles)); end

    wire [71:0] vramcnt = 72'h80;           // bank A, LCDC
    reg  c_req = 0, c_cpu = 0, c_dma = 0, c_we = 0;
    reg  [23:2] c_addr = 0;
    reg  [3:0]  c_be = 0;
    reg  [31:0] c_wdata = 0;
    reg  g_req = 0;
    reg  [17:0] g_blk = 0;
    reg  cap_we = 0;
    reg  [17:0] cap_addr = 0;
    reg  [15:0] cap_data = 0;
    reg  cw_ack = 0, cw_drained = 1;
    reg  [6:0] cw_fill = 0, cw_pcnt = 0;
    reg  sv_req = 0, sv_we = 0;
    reg  [20:2] sv_addr = 0;
    reg  [3:0] sv_be = 0;
    reg  [31:0] sv_wdata = 0;
    reg  vm_ack = 0, vm_rvalid = 0;
    reg  [31:0] vm_rdata = 0;

`define VRAM_PORTS(p) \
        .clk, .rst, .vramcnt, .c_req, .c_cpu, .c_we, .c_addr, .c_be, .c_wdata, .c_ack(p``c_ack), .c_rdata(p``c_rdata), \
        .g_req, .g_blk, .g_ack(p``g_ack), .g_rvalid(p``g_rvalid), .g_rdata(p``g_rdata), \
        .cap_we, .cap_addr, .cap_data, .cap_ready(p``cap_ready), \
        .cw_valid(p``cw_valid), .cw_addr(p``cw_addr), .cw_data(p``cw_data), .cw_ack, .cw_drained, .cw_fill, .cw_pcnt, \
        .sv_req, .sv_we, .sv_addr, .sv_be, .sv_wdata, .sv_ack(p``sv_ack), .sv_rdata(p``sv_rdata), \
        .vm_req(p``vm_req), .vm_we(p``vm_we), .vm_blk(p``vm_blk), .vm_addr(p``vm_addr), .vm_be(p``vm_be), \
        .vm_wdata(p``vm_wdata), .vm_ack, .vm_rvalid, .vm_rdata, .vramstat(p``vramstat)
`define VRAM_OUTS(p) \
    wire p``c_ack, p``g_ack, p``g_rvalid, p``cap_ready, p``cw_valid, p``sv_ack, p``vm_req, p``vm_we, p``vm_blk; \
    wire [31:0] p``c_rdata, p``cw_data, p``sv_rdata, p``vm_wdata; \
    wire [63:0] p``g_rdata; \
    wire [23:0] p``cw_addr; \
    wire [20:2] p``vm_addr; \
    wire [3:0]  p``vm_be; \
    wire [1:0]  p``vramstat;
    `VRAM_OUTS(o_)
    `VRAM_OUTS(n_)
    localparam P = 1;
    nds_vram_old #(.CAP_CHAIN(P), .VR_POST(P), .VR_RDB(P), .VR_PASS(P), .VR_WB(P), .VR_CWF(P), .VR_HIT(0), .VR_YIELD(P), .VR_PDRAIN(P))
        u_old (`VRAM_PORTS(o_));
    nds_vram #(.CAP_CHAIN(P), .VR_POST(P), .VR_RDB(P), .VR_PASS(P), .VR_WB(P), .VR_CWF(P), .VR_HIT(0), .VR_YIELD(P), .VR_PDRAIN(P), .VR_PF(0))
        u_new (`VRAM_PORTS(n_), .c_dma);

    wire [255:0] o_all = {o_c_ack, o_c_rdata, o_g_ack, o_g_rvalid, o_g_rdata, o_cap_ready, o_cw_valid, o_cw_addr, o_cw_data,
                          o_sv_ack, o_sv_rdata, o_vm_req, o_vm_we, o_vm_blk, o_vm_addr, o_vm_be, o_vm_wdata, o_vramstat};
    wire [255:0] n_all = {n_c_ack, n_c_rdata, n_g_ack, n_g_rvalid, n_g_rdata, n_cap_ready, n_cw_valid, n_cw_addr, n_cw_data,
                          n_sv_ack, n_sv_rdata, n_vm_req, n_vm_we, n_vm_blk, n_vm_addr, n_vm_be, n_vm_wdata, n_vramstat};

    // external memory, answered from the old model's requests
    integer q_n [$];
    integer cur_left = 0, ack_wait = 0, word_wait = 0;
    integer mism = 0, n_c = 0, n_g = 0, n_cyc = 0;
    integer c_base = 0;
    reg cap_odd = 0;          // the last capture halfword was even: its partner may follow
    always @(posedge clk) begin
        n_cyc++;
        if (!rst && o_all !== n_all) begin
            mism++;
            if (mism < 6) $display("MISMATCH at %0d: old %h new %h", n_cyc, o_all, n_all);
        end
        vm_ack <= 0; vm_rvalid <= 0; cw_ack <= 0;
        if (o_vm_req && !vm_ack) begin
            if (ack_wait == 0) begin
                vm_ack <= 1;
                if (!o_vm_we) q_n.push_back(o_vm_blk ? 8 : 1);
                ack_wait = $urandom % 5;
            end else ack_wait--;
        end
        if (cur_left == 0 && q_n.size() > 0) begin cur_left = q_n.pop_front(); word_wait = 1 + $urandom % 6; end
        if (cur_left != 0) begin
            if (word_wait == 0) begin vm_rvalid <= 1; vm_rdata <= $urandom; cur_left--; word_wait = $urandom % 3; end
            else word_wait--;
        end
        if (o_cw_valid && !cw_ack && $urandom % 3 == 0) cw_ack <= 1;
        cw_drained <= $urandom % 4 != 0;
        cw_fill <= $urandom % 70; cw_pcnt <= cw_pcnt + ($urandom % 3 == 0);
        if (!rst) begin
            // CPU / DMA: held until c_ack; a window of 64 words that moves now and then
            if (o_c_ack) begin c_req <= 0; n_c++; end
            else if (!c_req && $urandom % 4 == 0) begin
                if ($urandom % 500 == 0) c_base = $urandom % 32000;
                c_req <= 1; c_cpu <= $urandom % 10 == 0; c_dma <= $urandom % 2;
                c_we <= $urandom % 4 == 0; c_be <= ($urandom % 3 == 0) ? 4'h3 : 4'hF;
                c_addr <= 22'h20_0000 | 22'(c_base + $urandom % 64); c_wdata <= $urandom;
            end
            if (o_g_ack) begin g_req <= 0; n_g++; end
            else if (!g_req && $urandom % 20 == 0) begin
                g_req <= 1; g_blk <= {SP_LCDC, 1'b0, ($urandom % 6 == 0) ? 14'(4096 + $urandom % 4096) : 14'($urandom % 4096)};
            end
            cap_we <= 0;
            // capture: mostly an even halfword and its odd partner a few clocks later (a pair), else singles
            if (o_cap_ready && (cap_odd ? $urandom % 3 == 0 : $urandom % 30 == 0)) begin
                cap_we <= 1; cap_data <= $urandom;
                if (cap_odd && $urandom % 6 != 0) begin cap_addr <= cap_addr | 18'd1; cap_odd <= 0; end
                else begin cap_addr <= $urandom; cap_odd <= 0; if (cap_addr[0] == 0) ; end
            end
            if (cap_we && !cap_addr[0]) cap_odd <= 1;
            if (o_sv_ack) sv_req <= 0;
            else if (!sv_req && $urandom % 300 == 0) begin
                sv_req <= 1; sv_we <= $urandom % 2; sv_addr <= 19'h40000 | 19'($urandom % 1024); sv_be <= 4'hF; sv_wdata <= $urandom;
            end
        end
    end
    initial begin
        void'($urandom(seed));
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (cycles) @(posedge clk);
        $display("vram_eq: %0d cycles, %0d CPU/DMA accesses, %0d blocks, %0d mismatches", n_cyc, n_c, n_g, mism);
        if (mism == 0 && n_c > 0 && n_g > 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
