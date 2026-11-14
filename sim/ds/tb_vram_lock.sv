// nds_vram in lockstep against its version at a base commit (nds_vram_ref, sim/ds/vram_lock.sh): the card's parameters
// (core_top_ds), random requests on every port (each held until its ack, as the fabric does), random SDRAM-side acks
// and read data, VRAMCNT changes and resets. Every output compared every clock, just before the rising edge.
// Coverage: the write queue's (VR_WBQ) fill, its pops, and pops of a word written the clock before (the falling-edge
// read's case: the head written at this clock's rising edge).
`timescale 1ns/1ps
module tb_vram_lock;
    import gpu2d_pkg::*;
    localparam int WBQ = 16;
    logic clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    logic [71:0] vramcnt;
    logic        c_req, c_cpu, c_dma, c_we;
    logic [23:2] c_addr;
    logic [3:0]  c_be;
    logic [31:0] c_wdata;
    logic        g_req;
    logic [17:0] g_blk;
    logic [1:0]  g_word;
    logic        cap_we;
    logic [17:0] cap_addr;
    logic [15:0] cap_data;
    logic        cw_ack, cw_drained;
    logic [6:0]  cw_fill, cw_pcnt;
    logic        sv_req, sv_we;
    logic [20:2] sv_addr;
    logic [3:0]  sv_be;
    logic [31:0] sv_wdata;
    logic        vm_ack, vm_rvalid;
    logic [31:0] vm_rdata;

    // outputs: a = reference, b = new
    logic        a_c_ack, b_c_ack, a_g_ack, b_g_ack, a_g_rvalid, b_g_rvalid, a_cap_ready, b_cap_ready;
    logic [31:0] a_c_rdata, b_c_rdata, a_cw_data, b_cw_data, a_sv_rdata, b_sv_rdata, a_vm_wdata, b_vm_wdata;
    logic [63:0] a_g_rdata, b_g_rdata;
    logic        a_cw_valid, b_cw_valid, a_sv_ack, b_sv_ack;
    logic [23:0] a_cw_addr, b_cw_addr;
    logic [1:0]  a_cw_he, b_cw_he, a_vramstat, b_vramstat;
    logic        a_vm_req, b_vm_req, a_vm_we, b_vm_we, a_vm_blk, b_vm_blk, a_vm_tex, b_vm_tex;
    logic [20:2] a_vm_addr, b_vm_addr;
    logic [3:0]  a_vm_be, b_vm_be;

`define VRAM_PARAMS .CAP_CHAIN(1'b1), .VR_POST(1'b1), .VR_RDB(1'b1), .VR_PASS(1'b1), .VR_WB(1'b1), .VR_WBQ(WBQ), \
        .VR_HITB(1'b1), .VR_HPAIR(1'b1), .VR_CWF(1'b1), .VR_HIT(1'b0), .VR_YIELD(1'b1), .VR_PDRAIN(1'b0), .VR_PF(1'b1), \
        .VR_PFS(1'b1), .VR_PH(1'b1), .RB_M10K(1'b1), .CAP_DB(1'b1), .G2D_CWF(1'b0)
`define VRAM_INS .clk, .rst, .vramcnt, .c_req, .c_cpu, .c_dma, .c_we, .c_addr, .c_be, .c_wdata, .g_req, .g_blk, .g_word, \
        .cap_we, .cap_addr, .cap_data, .cw_ack, .cw_drained, .cw_fill, .cw_pcnt, .sv_req, .sv_we, .sv_addr, .sv_be, \
        .sv_wdata, .vm_ack, .vm_rvalid, .vm_rdata
`define VRAM_OUTS(p) .c_ack(p``_c_ack), .c_rdata(p``_c_rdata), .g_ack(p``_g_ack), .g_rvalid(p``_g_rvalid), \
        .g_rdata(p``_g_rdata), .cap_ready(p``_cap_ready), .cw_valid(p``_cw_valid), .cw_addr(p``_cw_addr), \
        .cw_data(p``_cw_data), .cw_he(p``_cw_he), .sv_ack(p``_sv_ack), .sv_rdata(p``_sv_rdata), .vm_req(p``_vm_req), \
        .vm_we(p``_vm_we), .vm_blk(p``_vm_blk), .vm_tex(p``_vm_tex), .vm_addr(p``_vm_addr), .vm_be(p``_vm_be), \
        .vm_wdata(p``_vm_wdata), .vramstat(p``_vramstat)

    nds_vram_ref #(`VRAM_PARAMS) u_ref (`VRAM_INS, `VRAM_OUTS(a));
    nds_vram #(`VRAM_PARAMS, .WQ_FE(1'b1)) u_new (`VRAM_INS, `VRAM_OUTS(b));

    wire [255:0] oa = {a_c_ack, a_c_rdata, a_g_ack, a_g_rvalid, a_g_rdata, a_cap_ready, a_cw_valid, a_cw_addr, a_cw_data,
                       a_cw_he, a_sv_ack, a_sv_rdata, a_vm_req, a_vm_we, a_vm_blk, a_vm_tex, a_vm_addr, a_vm_be, a_vm_wdata,
                       a_vramstat};
    wire [255:0] ob = {b_c_ack, b_c_rdata, b_g_ack, b_g_rvalid, b_g_rdata, b_cap_ready, b_cw_valid, b_cw_addr, b_cw_data,
                       b_cw_he, b_sv_ack, b_sv_rdata, b_vm_req, b_vm_we, b_vm_blk, b_vm_tex, b_vm_addr, b_vm_be, b_vm_wdata,
                       b_vramstat};

    int unsigned seed, cycles, ackp, wrp, phase;
    longint unsigned n, diffs, pops, pops_fresh, wq_max, qwrites;
    longint unsigned wtime [WBQ];

    function automatic bit pr(input int unsigned pct);    // true with pct % probability
        return ($urandom % 100) < pct;
    endfunction

    task automatic new_vramcnt();
        for (int k = 0; k < 9; k++) vramcnt[8*k +: 8] = {pr(85), 4'd0, 3'($urandom)};
    endtask

    task automatic new_c();
        c_cpu = pr(70); c_dma = !c_cpu && pr(60); c_we = pr(wrp);
        case ($urandom % 8)
            0, 1, 2, 3, 4: c_be = 4'hF;
            5: c_be = 4'b0011;
            6: c_be = 4'b1100;
            default: c_be = 4'($urandom);
        endcase
        // mostly LCDC (0x068xxxxx), the rest any view; a small address window so lines and halves repeat
        c_addr = pr(60) ? {4'h8, 4'($urandom % 2), 14'($urandom % 512)} : 22'($urandom);
        c_wdata = $urandom;
    endtask

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("cycles=%d", cycles)) cycles = 400000;
        void'($urandom(seed));
        n = 0; diffs = 0; pops = 0; pops_fresh = 0; wq_max = 0; qwrites = 0;
        for (int k = 0; k < WBQ; k++) wtime[k] = '1;
        new_vramcnt();
        c_req = 0; g_req = 0; sv_req = 0; cap_we = 0; cw_ack = 0; cw_drained = 1; cw_fill = 0; cw_pcnt = 0;
        vm_ack = 0; vm_rvalid = 0; vm_rdata = 0; new_c();
        g_blk = 0; g_word = 0; cap_addr = 0; cap_data = 0; sv_we = 0; sv_addr = 0; sv_be = 0; sv_wdata = 0;
        ackp = 50; wrp = 80; phase = 0;
        repeat (cycles) begin
            @(posedge clk);
            // the clock's sampled acks retire the held requests (as the fabric drops c_req after c_ack)
            #1;
            n++;
            if (n == 12) rst = 1'b0;
            if (n % 30011 == 0) rst = 1'b1;
            if (rst && n % 30011 == 8) rst = 1'b0;
            if (n % 20000 == 0) new_vramcnt();
            if (n % 300 == 0) begin                          // phases: the write FIFO slow, fast or stalled
                phase = $urandom % 4;
                ackp = phase == 0 ? 3 : phase == 1 ? 30 : phase == 2 ? 70 : 97;
                wrp = pr(50) ? 95 : 60;
            end
            if (!c_req || a_c_ack) begin c_req = pr(phase == 0 ? 90 : 55); new_c(); end
            if (!g_req || a_g_ack) begin g_req = pr(15); g_blk = 18'($urandom); g_word = 2'($urandom); end
            if (!sv_req || a_sv_ack) begin
                sv_req = pr(8); sv_we = pr(50); sv_addr = 19'($urandom); sv_be = pr(70) ? 4'hF : 4'($urandom);
                sv_wdata = $urandom;
            end
            cap_we = a_cap_ready && pr(20); cap_addr = 18'($urandom % 4096); cap_data = 16'($urandom);
            cw_ack = pr(ackp); cw_drained = pr(ackp); cw_fill = 7'($urandom % 80); cw_pcnt = 7'($urandom % 80);
            vm_ack = pr(ackp); vm_rvalid = pr(40); vm_rdata = $urandom;
        end
        $display("VRAMLOCK seed %0d: %0d clocks, %0d differ; queue: %0d writes, %0d pops, %0d of a word written the clock before, deepest %0d",
                 seed, n, diffs, qwrites, pops, pops_fresh, wq_max);
        if (diffs == 0 && pops_fresh > 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

    // compare just before the rising edge (inputs settled, the falling-edge read done)
    always @(negedge clk) begin
        #4;
        if (oa !== ob) begin
            diffs++;
            if (diffs <= 5) $display("DIFF at clock %0d: ref %h new %h", n, oa, ob);
        end
    end

    // the queue's coverage, from the reference
    always @(posedge clk) if (!rst) begin
        if (64'(u_ref.wq_n) > wq_max) wq_max = 64'(u_ref.wq_n);
        if (u_ref.wb_push && u_ref.wb_v && !(u_ref.wb_pop && u_ref.wq_n == '0)) begin
            qwrites++; wtime[u_ref.wq_wr] = n;
        end
        if (u_ref.wb_pop && u_ref.wq_n != '0) begin
            pops++;
            if (wtime[u_ref.wq_rd] + 1 == n) pops_fresh++;
        end
    end
endmodule
