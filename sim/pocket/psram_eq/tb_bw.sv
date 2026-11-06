// nds_psram B8 + BW against a shadow memory (bw_test.sh, docs/psram-ds.md
// "BW"): random word writes with byte enables, 32-byte block writes (8 words
// on s_wnext), 16-byte reads and 32-byte block reads on two cram_model chips
// (h1_chips from tb_h1_eq.sv); every read word of a written address must be
// the last value written.
`timescale 1ps/1ps
`default_nettype none
module tb_bw #(parameter integer STREAM = 0);
    reg clk_mem = 0, clk_sys = 0, clk_cram = 0;
    always #4973 clk_mem = !clk_mem;
    initial begin #14919; forever begin clk_sys = 1; #7460; clk_sys = 0; #7459; end end
    always @(clk_mem) clk_cram <= #6838 clk_mem;
    reg rst_sys = 1, rst_mem = 1;
    reg s_req = 0, s_we = 0, s_n8 = 0; reg [23:0] s_addr = 0; reg [31:0] s_wdata = 0; reg [3:0] s_be = 0;
    wire ack, rv, init, cke, wnext; wire [31:0] rd;
    wire [21:16] n0a, n1a; wire [15:0] n0dq, n1dq; wire n0w, n1w;
    wire n0adv, n1adv, n0cre, n1cre, n0ce0, n0ce1, n1ce0, n1ce1, n0oe, n1oe, n0we, n1we, n0ub, n0lb, n1ub, n1lb;
    nds_psram #(.T_INIT(200), .B8(1), .BW(1), .STREAM(STREAM)) dut (.clk_sys, .clk_mem, .reset_sys(rst_sys), .reset_mem(rst_mem), .initialized(init),
        .s_req, .s_we, .s_addr, .s_wdata, .s_be, .s_ack(ack), .s_rvalid(rv), .s_rdata(rd), .s_n8, .s_wnext(wnext),
        .chip_clk_en(cke), .cram0_a(n0a), .cram1_a(n1a), .cram0_dq(n0dq), .cram1_dq(n1dq), .cram0_wait(n0w), .cram1_wait(n1w),
        .cram0_adv_n(n0adv), .cram1_adv_n(n1adv), .cram0_cre(n0cre), .cram1_cre(n1cre),
        .cram0_ce0_n(n0ce0), .cram0_ce1_n(n0ce1), .cram1_ce0_n(n1ce0), .cram1_ce1_n(n1ce1),
        .cram0_oe_n(n0oe), .cram1_oe_n(n1oe), .cram0_we_n(n0we), .cram1_we_n(n1we),
        .cram0_ub_n(n0ub), .cram0_lb_n(n0lb), .cram1_ub_n(n1ub), .cram1_lb_n(n1lb));
    h1_chips #(.NAME("b")) nc (.clk_mem, .clk_cram, .clk_en(cke), .c0a(n0a), .c1a(n1a), .c0dq(n0dq), .c1dq(n1dq),
        .c0w(n0w), .c1w(n1w), .c0adv(n0adv), .c1adv(n1adv), .c0cre(n0cre), .c1cre(n1cre), .c0ce0(n0ce0), .c0ce1(n0ce1),
        .c1ce0(n1ce0), .c1ce1(n1ce1), .c0oe(n0oe), .c1oe(n1oe), .c0we(n0we), .c1we(n1we), .c0ub(n0ub), .c0lb(n0lb),
        .c1ub(n1ub), .c1lb(n1lb));

    reg [31:0] mem [int];                // the shadow: word address -> value
    reg [31:0] blkd [8];
    integer seed = 1, reqs = 3000, bad = 0, nw = 0, nbw = 0, nr = 0, nbr = 0, nchk = 0, gap, k, base, exp_n, got;
    // block-read latency in clk_sys from s_req: to the first word and to the last
    longint cyc = 0, t_req, lat_f = 0, lat_l = 0;
    always @(posedge clk_sys) cyc <= cyc + 1;
    always @(posedge clk_sys) if (rv && exp_n == 8) begin
        if (got == 0) lat_f = lat_f + (cyc - t_req);
        if (got == 7) lat_l = lat_l + (cyc - t_req);
    end
    // read answers: words base.. in order
    always @(posedge clk_sys) if (rv) begin
        if (mem.exists(base + got) && rd !== mem[base + got]) begin
            if (bad < 5) $display("  %0t: word %h read %h, written %h", $time, base + got, rd, mem[base + got]);
            bad = bad + 1;
        end else if (mem.exists(base + got)) nchk = nchk + 1;
        got = got + 1;
    end
    initial begin
        void'($value$plusargs("seed=%d", seed)); void'($value$plusargs("reqs=%d", reqs));
        void'($urandom(seed));
        #100000; rst_mem = 0; @(posedge clk_sys); rst_sys = 0;
        wait (init);
        repeat (reqs) begin
            int op, a;
            @(posedge clk_sys);
            op = $urandom % 4;                      // 0 word write, 1 block write, 2 read, 3 block read
            a = ($urandom % 4 == 0) ? (21'($urandom)) : ($urandom % 512);
            s_req <= 1; s_we <= op < 2; s_n8 <= op == 1 || op == 3; t_req = cyc;
            s_addr <= 24'(a); s_be <= op == 0 ? 4'($urandom % 16) : 4'hF;
            if (op == 1) begin
                for (int i = 0; i < 8; i++) blkd[i] = $urandom;
                s_wdata <= blkd[0]; k = 0;
            end else s_wdata <= $urandom;
            base = op == 3 ? (a & ~7) : (a & ~3); got = 0; exp_n = op == 3 ? 8 : op == 2 ? 4 : 0;
            @(posedge clk_sys);
            while (!ack) begin
                if (op == 1 && wnext) begin k = k + 1; if (k < 8) s_wdata <= blkd[k]; end
                @(posedge clk_sys);
            end
            if (op == 1 && wnext) k = k + 1;
            s_req <= 0;
            if (op == 0) begin
                reg [31:0] v; v = mem.exists(a) ? mem[a] : 32'd0;
                for (int b = 0; b < 4; b++) if (s_be[b]) v[b*8 +: 8] = s_wdata[b*8 +: 8];
                if (mem.exists(a) || s_be == 4'hF) mem[a] = v;
                nw = nw + 1;
            end else if (op == 1) begin
                if (k != 8) begin $display("  block write took %0d words", k); bad = bad + 1; end
                for (int i = 0; i < 8; i++) mem[(a & ~7) + i] = blkd[i];
                nbw = nbw + 1;
            end else begin
                while (got < exp_n) @(posedge clk_sys);
                if (op == 3) nbr = nbr + 1; else nr = nr + 1;
            end
            gap = $urandom % 3 == 0 ? 0 : $urandom % 12; repeat (gap) @(posedge clk_sys);
        end
        repeat (400) @(posedge clk_sys);
        $display("%s: %0d writes, %0d block writes, %0d reads, %0d block reads, %0d words checked, %0d bad (seed %0d); block read from s_req: first word %.1f, last %.1f clk_sys",
                 bad ? "FAIL" : "PASS", nw, nbw, nr, nbr, nchk, bad, seed, real'(lat_f) / nbr, real'(lat_l) / nbr);
        $finish;
    end
endmodule
`default_nettype wire
