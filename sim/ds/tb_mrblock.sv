// nds_fabric's ARM9 32-byte main-RAM blocks (MR_BLOCK) through nds_mr_arb,
// against a reference image (sim/ds/mrblock_test.sh). Random ARM9 single
// words and blocks (reads and writes) and ARM7 single words, over a 1 KiB
// window of main RAM so lines are shared; the main-RAM model answers after
// a random latency, 16-byte reads and word writes as tb_ds does, 32-byte
// blocks with 8 read words or 8 mr_wnext write cycles. Every read is checked,
// and every write's mon_* report against the image. Block reads outside main
// RAM (the fabric serves them word by word): OAM (the fabric's own copy,
// written here by word) and the empty GBA slot (open bus from the address).
//   +seed=N +ops=N
`default_nettype none
module tb_mrblock;
    logic clk = 0, rst = 1;
    always #5 clk = !clk;
    // ARM9 and ARM7 ports
    logic        a9_req = 0, a9_we = 0, a9_n8 = 0;
    logic [31:0] a9_addr = 0, a9_wdata = 0;
    logic [3:0]  a9_be = 0;
    logic        a9_ack, a9_rvalid, a9_wnext;
    logic [31:0] a9_rdata;
    logic        a7_req = 0, a7_we = 0;
    logic [31:0] a7_addr = 0, a7_wdata = 0;
    logic [3:0]  a7_be = 0;
    logic        a7_ack;
    logic [31:0] a7_rdata;
    // main RAM
    logic        fm_req, fm_we, fm_ack, fm_rvalid, fm_n8, fm_wnext;
    logic [21:2] fm_addr;
    logic [3:0]  fm_be;
    logic [31:0] fm_wdata;
    logic        mr_req, mr_we, mr_n8;
    logic [22:2] mr_addr;
    logic [3:0]  mr_be;
    logic [31:0] mr_wdata, mr_rdata;
    logic        mr_ack = 0, mr_rvalid = 0, mr_wnext = 0;
    logic        mon_we;
    logic [31:0] mon_addr, mon_wdata;
    logic [3:0]  mon_be;
`ifndef A7F
`define A7F 1
`endif
    nds_fabric #(.MR_BLOCK(1), .A7_FIRST(`A7F)) u_fab (.clk, .rst, .dm_unit(1'b0), .dm_more(1'b0), .dm_dst(32'd0), .dx_valid(), .dx_ready(1'b1), .dx_idle(1'b1), .wramcnt(2'd3), .pb_busy(1'b0),
        .dm_req(1'b0), .dm_we(1'b0), .dm_cpu(1'b0), .dm_size32(1'b1), .dm_addr(32'd0), .dm_wdata(32'd0), .dm_ack(), .dm_rdata(),
        .a9_req, .a9_we, .a9_addr, .a9_be, .a9_wdata, .a9_ack, .a9_rdata, .a9_n8, .a9_rvalid, .a9_wnext,
        .a7_req, .a7_we, .a7_addr, .a7_be, .a7_wdata, .a7_ack, .a7_rdata,
        .sn_req(1'b0), .sn_we(1'b0), .sn_addr(32'd0), .sn_wdata(32'd0), .sn_ack(), .sn_rdata(),
        .mr_req(fm_req), .mr_we(fm_we), .mr_addr(fm_addr), .mr_be(fm_be), .mr_wdata(fm_wdata),
        .mr_ack(fm_ack), .mr_rvalid(fm_rvalid), .mr_rdata, .mr_n8(fm_n8), .mr_wnext(fm_wnext),
        .fx_req(), .fx_we(), .fx_addr(), .fx_be(), .fx_wdata(), .fx_done(1'b0), .fx_rdata(32'd0),
        .boot_addr(), .boot_q(32'd0), .ram_wdata(),
        .io_req(), .io_cpu(), .io_we(), .io_be(), .io_addr(), .io_wdata(), .io_ack(1'b0), .io_rdata(32'd0),
        .vr_req(), .vr_cpu(), .vr_we(), .vr_addr(), .vr_be(), .vr_wdata(), .vr_ack(1'b0), .vr_rdata(32'd0),
        .pal_cq(32'd0), .pal_we(), .oam_we(), .po_waddr(), .po_wdata(), .po_be(),
        .mon_we, .mon_master(), .mon_cpu(), .mon_addr, .mon_be, .mon_wdata);
    nds_mr_arb u_arb (.clk, .rst,
        .a_req(fm_req), .a_we(fm_we), .a_addr(fm_addr), .a_be(fm_be), .a_wdata(fm_wdata), .a_ack(fm_ack), .a_rvalid(fm_rvalid),
        .a_n8(fm_n8), .a_wnext(fm_wnext),
        .b_req(1'b0), .b_we(1'b0), .b_addr(21'd0), .b_wdata(32'd0), .b_ack(), .b_rvalid(),
        .mr_req, .mr_we, .mr_addr, .mr_be, .mr_wdata, .mr_ack, .mr_rvalid, .mr_n8, .mr_wnext);

    // the main-RAM model (256 words: the test's window)
    logic [31:0] mem [0:255];
    logic [31:0] img [0:255];             // what the CPUs wrote, in order
    int st = 0, cnt = 0, k = 0, n = 0;
    logic [9:2] ma;
    logic mwe;
    always @(posedge clk) begin
        mr_ack <= 0; mr_rvalid <= 0; mr_wnext <= 0;
        case (st)
            0: if (mr_req && !mr_ack) begin st <= 1; cnt <= 2 + $urandom % 20; ma <= mr_addr[9:2]; mwe <= mr_we; n <= mr_n8 ? 8 : 4; end
            1: if (cnt > 1) cnt <= cnt - 1;
               else if (n == 8 && mwe) begin st <= 3; k <= 0; end
               else begin
                   mr_ack <= 1;
                   if (mwe) begin
                       for (int b = 0; b < 4; b++) if (mr_be[b]) mem[ma][b*8 +: 8] <= mr_wdata[b*8 +: 8];
                       st <= 4;
                   end else begin st <= 2; k <= 0; end
               end
            2: begin
                   mr_rvalid <= 1;
                   mr_rdata <= mem[(n == 8 ? {ma[9:5], 3'd0} : {ma[9:4], 2'd0}) + k];
                   k <= k + 1;
                   if (k == n - 1) st <= 4;
               end
            3: begin
                   // a block write: mr_wdata is the word for this mr_wnext
                   mr_wnext <= 1;
                   st <= 5;
               end
            5: begin
                   mem[{ma[9:5], 3'd0} + k] <= mr_wdata;
                   k <= k + 1;
                   if (k == 7) begin mr_ack <= 1; st <= 4; end
                   else mr_wnext <= 1;
               end
            default: st <= 0;
        endcase
    end

    int bad = 0, n_rd = 0, n_brd = 0, n_bwr = 0, n_wr = 0, n_mon = 0;
    always @(posedge clk) if (mon_we) n_mon++;

    // the ARM9's block write feed: a9_wdata is word bk_i until a9_wnext
    logic [31:0] bw [0:7];
    int bk_i = 0;
    always @(posedge clk) if (a9_req && a9_n8 && a9_we && a9_wnext) begin
        bk_i <= bk_i + 1;
        a9_wdata <= bw[bk_i + 1 < 8 ? bk_i + 1 : 7];
    end

    task automatic a9_word(input bit we, input [9:2] a);
        logic [31:0] d, exp;
        logic [3:0] be;
        d = $urandom; be = we ? 4'hF : 4'hF;
        @(posedge clk);
        a9_req <= 1; a9_we <= we; a9_n8 <= 0; a9_addr <= {22'h008000, a, 2'b00}; a9_be <= be; a9_wdata <= d;
        @(posedge clk); while (!a9_ack) @(posedge clk);
        if (we) begin img[a] = d; n_wr++; end
        else begin
            n_rd++;
            if (a9_rdata !== img[a]) begin bad++; if (bad < 8) $display("%0t ARM9 read %h: %h, expected %h", $time, a, a9_rdata, img[a]); end
        end
        a9_req <= 0;
    endtask

    task automatic a9_block(input bit we, input [9:5] l);
        int got;
        @(posedge clk);
        for (int i = 0; i < 8; i++) bw[i] = $urandom;
        bk_i = 0;
        a9_req <= 1; a9_we <= we; a9_n8 <= 1; a9_addr <= {22'h008000, l, 5'd0}; a9_be <= 4'hF; a9_wdata <= bw[0];
        got = 0;
        @(posedge clk);
        while (1) begin
            if (!we && a9_rvalid) begin
                if (a9_rdata !== img[{l, 3'd0} + got]) begin bad++; if (bad < 8) $display("%0t ARM9 block read %h word %0d: %h, expected %h", $time, l, got, a9_rdata, img[{l, 3'd0} + got]); end
                got++;
            end
            if (a9_ack) break;
            @(posedge clk);
        end
        if (we) begin for (int i = 0; i < 8; i++) img[{l, 3'd0} + i] = bw[i]; n_bwr++; end
        else begin n_brd++; if (got != 8) begin bad++; $display("block read gave %0d words", got); end end
        a9_req <= 0; a9_n8 <= 0;
    endtask

    task automatic a7_word(input bit we, input [9:2] a);
        logic [31:0] d;
        d = $urandom;
        @(posedge clk);
        a7_req <= 1; a7_we <= we; a7_addr <= {22'h008000, a, 2'b00}; a7_be <= 4'hF; a7_wdata <= d;
        @(posedge clk); while (!a7_ack) @(posedge clk);
        if (we) begin img[a] = d; n_wr++; end
        else begin
            n_rd++;
            if (a7_rdata !== img[a]) begin bad++; if (bad < 8) $display("%0t ARM7 read %h: %h, expected %h", $time, a, a7_rdata, img[a]); end
        end
        a7_req <= 0;
    endtask

    // OAM (0x07000000, the first 1 KiB) and the GBA slot (0x08000000)
    logic [31:0] oimg [0:255];
    int n_obw = 0, n_obr = 0;
    task automatic a9_oword(input [9:2] a);
        logic [31:0] d;
        d = $urandom;
        @(posedge clk);
        a9_req <= 1; a9_we <= 1; a9_n8 <= 0; a9_addr <= {22'h01C000, a, 2'b00}; a9_be <= 4'hF; a9_wdata <= d;
        @(posedge clk); while (!a9_ack) @(posedge clk);
        oimg[a] = d; n_obw++;
        a9_req <= 0;
    endtask
    task automatic a9_oblock(input bit gba, input [9:5] l, input [4:2] w0);
        int got;
        logic [31:0] e;
        @(posedge clk);
        // (the request's word bits are not the line's start: the fabric aligns)
        a9_req <= 1; a9_we <= 0; a9_n8 <= 1; a9_be <= 4'hF;
        a9_addr <= gba ? {22'h020000, l, w0, 2'b00} : {22'h01C000, l, w0, 2'b00};
        got = 0;
        @(posedge clk);
        while (1) begin
            if (a9_rvalid) begin
                logic [31:0] ad;
                ad = {gba ? 22'h020000 : 22'h01C000, l, got[2:0], 2'b00};
                e = gba ? {ad[16:2], 1'b1, ad[16:2], 1'b0} : oimg[{l, got[2:0]}];
                if (got > 7 || a9_rdata !== e) begin bad++; if (bad < 8) $display("%0t ARM9 %s block read %h word %0d: %h, expected %h", $time, gba ? "GBA" : "OAM", l, got, a9_rdata, e); end
                got++;
            end
            if (a9_ack) break;
            @(posedge clk);
        end
        n_obr++;
        if (got != 8) begin bad++; $display("%s block read gave %0d words", gba ? "GBA" : "OAM", got); end
        a9_req <= 0; a9_n8 <= 0;
    endtask

    // +lockout: an ARM7 issuing main-RAM word reads back to back (a new
    // request on the clock of each ack) for 3,000 clocks, against ARM9 block
    // reads: how many ARM9 blocks get through during the burst, and their
    // longest wait (run 30: on the DS the ARM7's loop keeps them out)
    task automatic lockout();
        int t_end, nb = 0, wmax = 0, w0;
        bit a7_on = 1;
        fork
            begin
                @(posedge clk); a7_req <= 1; a7_we <= 0; a7_be <= 4'hF; a7_addr <= {22'h008000, 8'h40, 2'b00};
                t_end = $time + 30000;
                while ($time < t_end) begin
                    @(posedge clk);
                    if (a7_ack) a7_addr <= {22'h008000, 8'(a7_addr[9:2] + 1), 2'b00};
                end
                while (!a7_ack) @(posedge clk);
                a7_req <= 0; a7_on = 0;
            end
            begin
                repeat (20) @(posedge clk);
                while (a7_on) begin
                    @(posedge clk); w0 = $time;
                    a9_req <= 1; a9_we <= 0; a9_n8 <= 1; a9_addr <= {22'h008000, 5'd4, 5'd0}; a9_be <= 4'hF;
                    @(posedge clk); while (!a9_ack) @(posedge clk);
                    a9_req <= 0; a9_n8 <= 0;
                    if (a7_on) nb++;
                    if (($time - w0) / 10 > wmax) wmax = ($time - w0) / 10;
                end
            end
        join
        $display("lockout: %0d ARM9 blocks during a 3000-clock ARM7 burst, longest wait %0d clocks (A7_FIRST %0d)", nb, wmax, `A7F);
        // A7_FIRST: none get through (the DS); without it they take turns
        $display("%s: lockout (seed %0d)", (`A7F != 0) == (nb == 0) ? "PASS" : "FAIL", seed);
    endtask

    int seed = 1, ops = 4000;
    initial begin
        void'($value$plusargs("seed=%d", seed)); void'($value$plusargs("ops=%d", ops));
        void'($urandom(seed));
        for (int i = 0; i < 256; i++) begin mem[i] = 0; img[i] = 0; oimg[i] = 0; end
        repeat (4) @(posedge clk); rst <= 0; repeat (4) @(posedge clk);
        if ($test$plusargs("lockout")) begin lockout(); $finish; end
        for (int o = 0; o < ops; o++) begin
            int r;
            logic [9:2] wa;
            logic [9:5] la;
            r = $urandom % 9;
            // half the operations in the first 256 bytes, so lines (and their
            // 16-byte halves in the line buffers) are shared often
            wa = $urandom; la = $urandom;
            if ($urandom % 2) begin wa[9:8] = 2'd0; la[9:8] = 2'd0; end
            case (r)
                0: a9_word(0, wa);
                1: a9_word(1, wa);
                2: a9_block(0, la);
                3: a9_block(1, la);
                4: a7_word(0, wa);
                5: a7_word(1, wa);
                6: a9_oword(wa);
                7: a9_oblock(0, la, $urandom);
                default: a9_oblock(1, la, $urandom);
            endcase
        end
        repeat (4) @(posedge clk);            // the last write's mon_we
        if (n_mon != n_wr + 8 * n_bwr + n_obw) begin bad++; $display("mon_we %0d, expected %0d", n_mon, n_wr + 8 * n_bwr + n_obw); end
        $display("%s: %0d word reads, %0d word writes, %0d block reads, %0d block writes, %0d OAM writes, %0d OAM/GBA block reads, %0d errors (seed %0d)",
                 bad ? "FAIL" : "PASS", n_rd, n_wr, n_brd, n_bwr, n_obw, n_obr, bad, seed);
        $finish;
    end
endmodule
`default_nettype wire
