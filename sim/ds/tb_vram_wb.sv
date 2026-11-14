// nds_vram's posted CPU/DMA writes (VR_POST, VR_PASS, VR_WB, VR_WBQ, VR_PH, VR_PDRAIN, VR_RDB/CWF, VR_YIELD: the
// card's settings) with randomized traffic: 2D block reads of bank A in bursts, CPU word and halfword writes in
// DMA-like runs and random reads, against a model of core_top_ds's shared write FIFO (cw_*: random refusals as the
// 3D ring's and the bottom screen's words take it, random drain into memory, its fill and pop counts) and an
// external port with random latencies. Checks:
//   - the posted words leave in the order the writes were acked, each with its address, data and halves;
//   - a CPU read returns the last value written there (reads wait for every earlier write);
//   - every write acked has been posted by the end (none lost, none twice).
// Prints the clocks a write unit took from request to ack and the run's length (sim/ds/vram_wb_test.py).
`timescale 1ns/1ps
module tb_vram_wb;
    import gpu2d_pkg::*;
    reg clk = 0; always #1 clk = !clk;
    reg rst = 1;
    integer seed = 1, n_units = 20000;
    initial begin void'($value$plusargs("seed=%d", seed)); void'($value$plusargs("units=%d", n_units)); end
`ifndef TB_WBQ
`define TB_WBQ 0
`endif
    wire [71:0] vramcnt = 72'h80;           // bank A, LCDC
    reg  c_req = 0, c_we = 0, c_dma = 0;
    reg  [23:2] c_addr = 0;
    reg  [3:0]  c_be = 0;
    reg  [31:0] c_wdata = 0;
    wire        c_ack;
    wire [31:0] c_rdata;
    reg  g_req = 0;
    reg  [17:0] g_blk = 0;
    wire g_ack, g_rvalid;
    wire [63:0] g_rdata;
    wire vm_req, vm_we, vm_blk, vm_ack, vm_rvalid;
    wire [20:2] vm_addr;
    wire [3:0] vm_be;
    wire [31:0] vm_wdata, vm_rdata;
    wire cw_valid;
    wire [23:0] cw_addr;
    wire [31:0] cw_data;
    wire [1:0]  cw_he;
    reg  cw_ack_r = 0;
    wire cw_ack = cw_ack_r;
    reg  [6:0] cw_fill = 0, cw_pcnt = 0;
    wire cw_drained;
    nds_vram #(.CAP_CHAIN(1), .VR_POST(1), .VR_RDB(1), .VR_PASS(1), .VR_WB(1), .VR_CWF(1), .VR_YIELD(1), .VR_PDRAIN(1),
               .VR_PH(1)
`ifndef TB_OLD
               , .VR_WBQ(`TB_WBQ)
`endif
`ifdef TB_HPAIR
               , .VR_HPAIR(1)
`endif
`ifdef TB_PF
               , .VR_PF(1)
`endif
               ) dut (.clk, .rst, .vramcnt,
        .c_req, .c_cpu(1'b0), .c_dma, .c_we, .c_addr, .c_be, .c_wdata, .c_ack, .c_rdata,
        .g_req, .g_blk, .g_ack, .g_rvalid, .g_rdata,
        .cap_we(1'b0), .cap_addr(18'd0), .cap_data(16'd0), .cap_ready(),
        .cw_valid, .cw_addr, .cw_data, .cw_he, .cw_ack, .cw_drained, .cw_fill, .cw_pcnt,
        .sv_req(1'b0), .sv_we(1'b0), .sv_addr(19'd5), .sv_be(4'hF), .sv_wdata(32'd0), .sv_ack(), .sv_rdata(),
        .vm_req, .vm_we, .vm_blk, .vm_tex(), .vm_addr, .vm_be, .vm_wdata, .vm_ack, .vm_rvalid, .vm_rdata,
        .vramstat());

`ifdef TB_EQ
    // +define+TB_EQ: an earlier nds_vram (renamed nds_vram_old) beside the DUT on the same inputs, with the DUT's
    // settings at VR_WBQ 0; every output is compared every clock (the change's equivalence check, AGENTS.md)
    wire o_c_ack, o_g_ack, o_g_rvalid, o_vm_req, o_vm_we, o_vm_blk, o_cw_valid, o_cw_drained_unused;
    wire [31:0] o_c_rdata, o_vm_wdata, o_cw_data;
    wire [63:0] o_g_rdata;
    wire [20:2] o_vm_addr;
    wire [3:0] o_vm_be;
    wire [23:0] o_cw_addr;
    wire [1:0] o_cw_he;
    // +define+TB_SAME: the earlier copy with the DUT's VR_WBQ (and VR_PF with TB_PF), for a change that keeps every
    // setting (the RC11 tie-off audit's gated states)
    nds_vram_old #(.CAP_CHAIN(1), .VR_POST(1), .VR_RDB(1), .VR_PASS(1), .VR_WB(1), .VR_CWF(1), .VR_YIELD(1), .VR_PDRAIN(1),
               .VR_PH(1)
`ifdef TB_OLDQ
               , .VR_WBQ(`TB_WBQ)
`endif
`ifdef TB_SAME
               , .VR_WBQ(`TB_WBQ)
`endif
`ifdef TB_PF
               , .VR_PF(1)
`endif
               ) old (.clk, .rst, .vramcnt,
        .c_req, .c_cpu(1'b0), .c_dma, .c_we, .c_addr, .c_be, .c_wdata, .c_ack(o_c_ack), .c_rdata(o_c_rdata),
        .g_req, .g_blk, .g_ack(o_g_ack), .g_rvalid(o_g_rvalid), .g_rdata(o_g_rdata),
        .cap_we(1'b0), .cap_addr(18'd0), .cap_data(16'd0), .cap_ready(),
        .cw_valid(o_cw_valid), .cw_addr(o_cw_addr), .cw_data(o_cw_data), .cw_he(o_cw_he), .cw_ack, .cw_drained, .cw_fill, .cw_pcnt,
        .sv_req(1'b0), .sv_we(1'b0), .sv_addr(19'd5), .sv_be(4'hF), .sv_wdata(32'd0), .sv_ack(), .sv_rdata(),
        .vm_req(o_vm_req), .vm_we(o_vm_we), .vm_blk(o_vm_blk), .vm_tex(), .vm_addr(o_vm_addr), .vm_be(o_vm_be), .vm_wdata(o_vm_wdata),
        .vm_ack, .vm_rvalid, .vm_rdata, .vramstat());
    int eq_bad = 0;
    always @(negedge clk) if (!rst) begin
        if ({c_ack, g_ack, g_rvalid, vm_req, cw_valid} !== {o_c_ack, o_g_ack, o_g_rvalid, o_vm_req, o_cw_valid}
            || (c_ack && c_rdata !== o_c_rdata) || (g_rvalid && g_rdata !== o_g_rdata)
            || (vm_req && {vm_we, vm_blk, vm_addr} !== {o_vm_we, o_vm_blk, o_vm_addr}) || (vm_req && vm_we && {vm_be, vm_wdata} !== {o_vm_be, o_vm_wdata})
            || (cw_valid && {cw_addr, cw_data, cw_he} !== {o_cw_addr, o_cw_data, o_cw_he})) begin
            eq_bad++;
            if (eq_bad <= 5) $display("ERROR equivalence at %0t: new c_ack %b g_ack %b vm_req %b cw_valid %b / old %b %b %b %b",
                                      $time, c_ack, g_ack, vm_req, cw_valid, o_c_ack, o_g_ack, o_vm_req, o_cw_valid);
        end
    end
`endif
    reg [31:0] mem [0:32767];
    reg [31:0] ref_ [0:32767];             // bank A as the CPU must read it (every acked write applied)
    function automatic [31:0] merge(input [31:0] old, input [31:0] d, input [3:0] be);
        for (int b = 0; b < 4; b++) if (be[b]) old[b*8 +: 8] = d[b*8 +: 8];
        return old;
    endfunction

    // ---- the shared write FIFO: takes cw words when it has room and no other client's word goes in this clock
    // (random), writes them to memory in order with random gaps; fill and pop counts as core_top_ds gives them
    integer f_a [$], f_d [$], f_be [$];
    integer f_gap = 0;
    assign cw_drained = f_a.size() == 0;
    always @(posedge clk) begin
        cw_ack_r <= cw_valid && !cw_ack_r && f_a.size() < 60 && $urandom % 4 != 0;
        if (cw_valid && cw_ack) begin
            f_a.push_back(cw_addr[14:0]); f_d.push_back(cw_data); f_be.push_back({{2{cw_he[1]}}, {2{cw_he[0]}}});
        end
        if (f_a.size() != 0) begin
            if (f_gap == 0) begin
                int a; a = f_a.pop_front();
                mem[a] = merge(mem[a], f_d.pop_front(), f_be.pop_front());
                cw_pcnt <= cw_pcnt + 7'd1;
                f_gap = ($urandom % 5 == 0) ? 4 + $urandom % 12 : $urandom % 3;   // the ring's 8-word blocks now and then
            end else f_gap--;
        end
        cw_fill <= 7'(f_a.size());
    end

    // ---- external port (reads only from this port's posted traffic: no S_CPU writes are expected for full words)
    integer q_addr [$], q_n [$];
    integer ack_wait = 0, word_wait = 0, cur_a = -1, cur_left = 0;
    reg ack_r = 0, rv_r = 0;
    reg [31:0] rd_r = 0;
    assign vm_ack = ack_r, vm_rvalid = rv_r, vm_rdata = rd_r;
    always @(posedge clk) begin
        ack_r <= 0; rv_r <= 0;
        if (vm_req && !ack_r) begin
            if (ack_wait == 0) begin
                ack_r <= 1;
                if (vm_we) mem[vm_addr[16:2]] = merge(mem[vm_addr[16:2]], vm_wdata, vm_be);
                else begin q_addr.push_back(vm_blk ? {vm_addr[20:5], 3'b000} : vm_addr); q_n.push_back(vm_blk ? 8 : 1); end
                ack_wait = $urandom % 6;
            end else ack_wait--;
        end
        if (cur_left == 0 && q_addr.size() > 0) begin cur_a = q_addr.pop_front(); cur_left = q_n.pop_front(); word_wait = 1 + $urandom % 8; end
        if (cur_left != 0) begin
            if (word_wait == 0) begin rv_r <= 1; rd_r <= mem[cur_a[14:0]]; cur_a++; cur_left--; word_wait = $urandom % 3; end
            else word_wait--;
        end
    end

    // ---- 2D: random bank A blocks in bursts (traffic only: a block may read a word still in the buffer, the
    // known difference this design keeps, so its data are not checked here)
    reg g_burst = 0;
    always @(posedge clk) if (!rst) begin
        if ($urandom % 120 == 0) g_burst <= !g_burst;
        if (g_ack) g_req <= 0;
        if ((!g_req || g_ack) && g_burst && $urandom % 3 == 0) begin
            g_req <= 1; g_blk <= {SP_LCDC, 1'b0, 14'($urandom % 4096)};
        end
    end

    // ---- CPU / DMA: runs of writes (words, now and then halfwords) to consecutive words, single reads anywhere
    integer n_pair = 0;
    integer errors = 0, c_done = 0, n_w = 0, w_clk = 0, n_post = 0, t_req = 0, t_end = 0;
    integer e_a [$], e_d [$], e_be [$];     // acked writes not yet seen posted
    integer c_w, run_left = 0, run_next = 0;
    integer run_h = 0, run_sub = 0;     // a 16-bit run (a DMA16 / STRH loop): 1 low half first, 2 high half first
    reg c_isw = 0;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;
    always @(posedge clk) if (!rst) begin
        if (c_ack) begin
            c_req <= 0; c_done++;
            if (c_isw) begin n_w++; w_clk += cyc - t_req; ref_[c_w] = merge(ref_[c_w], c_wdata, c_be);
                             e_a.push_back(c_w); e_d.push_back(c_wdata); e_be.push_back(c_be); end
            else if (c_rdata !== ref_[c_w]) begin
                errors++; if (errors < 10) $display("ERROR CPU read %0d: %h, expected %h", c_w, c_rdata, ref_[c_w]);
            end
        end
        if ((!c_req || c_ack) && c_done < n_units && (run_left != 0 ? $urandom % 3 == 0 : $urandom % 10 == 0)) begin
            if (run_left == 0 && $urandom % 4 == 0) begin
                run_left = 8 + $urandom % 120; run_next = $urandom % 32768; run_sub = 0;
                run_h = $urandom % 3 == 0 ? 1 + $urandom % 2 : 0;
            end
            if (run_left != 0 && run_h != 0) begin   // both halves of each word, in order (a word's halves now and then alone)
                c_isw = 1; c_w = run_next; c_dma <= 1;
                c_be <= (run_sub == 0) == (run_h == 1) ? 4'b0011 : 4'b1100;
                if (run_sub == 1 || $urandom % 16 == 0) begin run_sub = 0; run_next = (run_next + 1) % 32768; run_left--; end
                else run_sub = 1;
            end else if (run_left != 0) begin
                c_isw = 1; c_w = run_next; run_next = (run_next + 1) % 32768; run_left--; c_dma <= 1;
                c_be <= $urandom % 8 == 0 ? ($urandom % 2 ? 4'b0011 : 4'b1100) : 4'hF;
            end else begin
                c_isw = $urandom % 3 == 0; c_w = $urandom % 32768; c_dma <= 0;
                c_be <= c_isw && $urandom % 6 == 0 ? 4'b1100 : 4'hF;
                if (!c_isw && $urandom % 2 && e_a.size() != 0) c_w = e_a[e_a.size() - 1];   // read back a fresh write
            end
            c_req <= 1; c_we <= c_isw; c_addr <= 22'h20_0000 | c_w; c_wdata <= $urandom; t_req = cyc + 1;
        end
    end
    // posted words: in the order acked, each one's address, data and halves
    always @(posedge clk) if (cw_valid && cw_ack) begin
        n_post++;
        if (e_a.size() == 0) begin errors++; if (errors < 10) $display("ERROR posted word %h with no write pending", cw_addr); end
        else begin
            int a, d, be; a = e_a.pop_front(); d = e_d.pop_front(); be = e_be.pop_front();
            // a merged pair (VR_HPAIR): this half and the next write, the other half of the same word
            if (cw_he == 2'b11 && be != 4'hF && e_a.size() != 0 && e_a[0] == a && e_be[0] == (~be & 4'hF)) begin
                int d2, be2; void'(e_a.pop_front()); d2 = e_d.pop_front(); be2 = e_be.pop_front();
                d = be[3] ? {d[31:16], d2[15:0]} : {d2[31:16], d[15:0]}; be = 4'hF; n_pair++;
            end
            // (only the posted halves' data counts: the SDRAM masks the other)
            if (cw_addr[14:0] != a[14:0] || ((cw_data ^ d) & {{16{be[2]}}, {16{be[0]}}}) != 0 || cw_he != {be[2], be[0]}) begin
                errors++;
                if (errors < 10) $display("ERROR post %0d: word %h %h he %b, expected %h %h he %b", n_post, cw_addr[14:0], cw_data, cw_he, a[14:0], d, {be[2], be[0]});
            end
        end
    end

    longint sig = 0;
    always @(posedge clk) sig = sig * 1000003 + {c_ack, g_ack, g_rvalid, vm_req, vm_we, vm_blk, cw_valid, cw_ack} + vm_addr * 7 + cw_addr * 13 + cw_data + c_rdata;
    initial begin
        void'($urandom(seed));
        for (int i = 0; i < 32768; i++) begin mem[i] = $urandom; ref_[i] = mem[i]; end
        repeat (4) @(posedge clk);
        rst = 0;
        wait (c_done >= n_units || $time > 64'd400_000_000);
        repeat (4000) @(posedge clk);   // (the queue drains behind 2D bursts and FIFO refusals)
`ifdef TB_EQ
        errors += eq_bad;
        $display("equivalence: %0d clocks differ", eq_bad);
`endif
        if (e_a.size() != 0) begin errors++; $display("ERROR %0d acked writes never posted", e_a.size()); end
        $display("signature %h", sig);
        $display("pairs merged %0d", n_pair);
        $display("units %0d (writes %0d, %.2f clk request to ack), posts %0d, clocks %0d, errors %0d",
                 c_done, n_w, real'(w_clk) / (n_w ? n_w : 1), n_post, cyc, errors);
        if (errors == 0 && c_done >= n_units) $display("TEST PASSED"); else $display("TEST FAILED");
        $finish;
    end
endmodule
