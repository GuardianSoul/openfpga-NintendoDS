// nds_sdram_xport and nds_sdram_bport (rtl/pocket/nds_sdram_bus.sv) against
// their versions at a git ref (*_ref, xp_eq.sh), side by side on the same
// inputs, compared on every edge of each clock: random requests on clk_sys
// (xport) and clk_bus (bport), an arbiter model taking each m_valid after a
// random delay, and read words returned on clk_mem. The clocks are
// sim_prims_ds.sv's (clk_sys and clk_bus rise together, clk_mem 3:2 and 3:1
// with coincident edges), with clk_mem started +phase ps late.
`timescale 1ps/1ps
`default_nettype none
module tb_xp_eq;
    reg clk_mem = 0, clk_bus = 0, clk_sys = 0;
    integer phase = 0, seed = 1, seed0 = 1, ops = 2000;
    initial begin
        void'($value$plusargs("phase=%d", phase));
        #(phase); forever #4973 clk_mem = !clk_mem;
    end
    always #14919 clk_bus = !clk_bus;
    initial begin #14919; forever begin clk_sys = 1; #7460; clk_sys = 0; #7459; end end
    reg reset = 1, breset = 1;

    // ---- xport (clk_sys side), SHARED = 0 and 1
    reg s_req = 0, s_we = 0, s_quad = 0;
    reg [23:0] s_addr = 0; reg [31:0] s_wdata = 0; reg [3:0] s_be = 0;
    reg c_valid = 0, c_write = 0, c_quad = 0;
    reg [23:0] c_addr = 0; reg [31:0] c_wdata = 0; reg [3:0] c_be = 0;
    reg [2:0] m_take = 0;       // 0: xport, 1: xport SHARED, 2: bport
    reg [2:0] w_valid = 0; reg [31:0] w_data = 0;
    wire [2:0] a_ack, a_rv, b_ack, b_rv, a_mv, b_mv, a_we, b_we;
    wire [31:0] a_rd [0:2]; wire [31:0] b_rd [0:2];
    wire [23:0] a_ad [0:2]; wire [23:0] b_ad [0:2];
    wire [3:0] a_n [0:2]; wire [3:0] b_n [0:2]; wire [3:0] a_be [0:2]; wire [3:0] b_be [0:2];
    wire [31:0] a_wd [0:2]; wire [31:0] b_wd [0:2];
`define XP(M, S, K, P) M #(.QW(4), .SHARED(S)) P (.clk_sys, .clk_mem, .reset, .s_req, .s_we, .s_quad, .s_addr, .s_wdata, .s_be, \
        .s_ack(K``_ack[S]), .s_rvalid(K``_rv[S]), .s_rdata(K``_rd[S]), .m_valid(K``_mv[S]), .m_we(K``_we[S]), .m_addr(K``_ad[S]), \
        .m_n(K``_n[S]), .m_wdata(K``_wd[S]), .m_be(K``_be[S]), .m_take(m_take[S]), .w_valid(w_valid[S]), .w_data);
    `XP(nds_sdram_xport, 0, a, xa0)
    `XP(nds_sdram_xport_ref, 0, b, xb0)
    `XP(nds_sdram_xport, 1, a, xa1)
    `XP(nds_sdram_xport_ref, 1, b, xb1)
    nds_sdram_bport #(.SHARED(0)) pa (.clk_bus, .clk_mem, .reset(breset), .c_valid, .c_write, .c_quad, .c_addr, .c_wdata, .c_be,
        .c_ready(a_ack[2]), .r_valid(a_rv[2]), .r_data(a_rd[2]), .m_valid(a_mv[2]), .m_we(a_we[2]), .m_addr(a_ad[2]),
        .m_n(a_n[2]), .m_wdata(a_wd[2]), .m_be(a_be[2]), .m_take(m_take[2]), .w_valid(w_valid[2]), .w_data);
    nds_sdram_bport_ref #(.SHARED(0)) pb (.clk_bus, .clk_mem, .reset(breset), .c_valid, .c_write, .c_quad, .c_addr, .c_wdata, .c_be,
        .c_ready(b_ack[2]), .r_valid(b_rv[2]), .r_data(b_rd[2]), .m_valid(b_mv[2]), .m_we(b_we[2]), .m_addr(b_ad[2]),
        .m_n(b_n[2]), .m_wdata(b_wd[2]), .m_be(b_be[2]), .m_take(m_take[2]), .w_valid(w_valid[2]), .w_data);

    integer errs = 0, checks = 0, done_x = 0, done_b = 0;
    task automatic cmp(input string what, input [63:0] a, input [63:0] b);
        checks++;
        if (a !== b) begin errs++; if (errs <= 10) $display("ERROR %s: new %h ref %h at %0t", what, a, b, $time); end
    endtask
    // compare just before each edge (the values every receiver samples)
    always @(negedge clk_sys) for (int i = 0; i < 2; i++) begin
        cmp($sformatf("xport%0d s_ack", i), a_ack[i], b_ack[i]); cmp($sformatf("xport%0d s_rvalid", i), a_rv[i], b_rv[i]);
        if (a_rv[i]) cmp($sformatf("xport%0d s_rdata", i), a_rd[i], b_rd[i]);
    end
    always @(negedge clk_bus) begin
        cmp("bport c_ready", a_ack[2], b_ack[2]); cmp("bport r_valid", a_rv[2], b_rv[2]);
        if (a_rv[2]) cmp("bport r_data", a_rd[2], b_rd[2]);
    end
    always @(negedge clk_mem) for (int i = 0; i < 3; i++) begin
        cmp($sformatf("port%0d m_valid", i), a_mv[i], b_mv[i]);
        if (a_mv[i]) cmp($sformatf("port%0d m_*", i), {a_we[i], a_ad[i], a_n[i], a_be[i]}, {b_we[i], b_ad[i], b_n[i], b_be[i]});
        if (a_mv[i] && a_we[i]) cmp($sformatf("port%0d m_wdata", i), a_wd[i], b_wd[i]);
    end

    // the arbiter model (clk_mem): take a waiting port after 0-5 edges, one
    // at a time; a read's words follow after 1-8 edges, 0-2 apart
    integer wait_n [0:2]; integer words_left = 0, word_gap = 0, word_port = 0;
    reg busy_take = 0;
    always @(posedge clk_mem) begin
        m_take <= 0; w_valid <= 0;
        if (words_left > 0) begin
            if (word_gap > 0) word_gap <= word_gap - 1;
            else begin w_valid[word_port] <= 1; w_data <= $random(seed); words_left <= words_left - 1; word_gap <= $urandom_range(2, 0); end
        end else if (!busy_take) begin
            for (int i = 0; i < 3; i++)
                if (a_mv[i] && !m_take[i] && !busy_take) begin
                    if (wait_n[i] > 0) wait_n[i] <= wait_n[i] - 1;
                    else begin
                        m_take[i] <= 1; busy_take = 1; wait_n[i] <= $urandom_range(5, 0);
                        if (!a_we[i]) begin words_left <= a_n[i]; word_port <= i; word_gap <= $urandom_range(8, 1); end
                    end
                end
            busy_take = 0;
        end
    end

    // clk_sys requester (nds_x2b's contract: s_req until s_ack, drops the cycle after)
    always @(posedge clk_sys) begin
        if (!reset) begin
            if (s_req && a_ack[0]) begin s_req <= 0; done_x <= done_x + 1; end
            else if (!s_req && !a_ack[0] && $urandom_range(3, 0) == 0 && done_x < ops) begin
                s_req <= 1; s_we <= $urandom_range(2, 0) == 0; s_quad <= $urandom_range(1, 0);
                s_addr <= $random(seed); s_wdata <= $random(seed); s_be <= $random(seed);
            end
        end
    end
    // clk_bus client (nds_sdram's contract: c_valid until c_ready)
    always @(posedge clk_bus) begin
        if (!breset) begin
            if (c_valid && a_ack[2]) begin c_valid <= 0; done_b <= done_b + 1; end
            else if (!c_valid && $urandom_range(2, 0) == 0 && done_b < ops) begin
                c_valid <= 1; c_write <= $urandom_range(2, 0) == 0; c_quad <= $urandom_range(1, 0);
                c_addr <= $random(seed); c_wdata <= $random(seed); c_be <= $random(seed);
            end
        end
    end

    initial begin
        void'($value$plusargs("seed=%d", seed)); void'($value$plusargs("ops=%d", ops)); seed0 = seed;
        for (int i = 0; i < 3; i++) wait_n[i] = 0;
        repeat (4) @(posedge clk_sys); reset <= 0;
        @(posedge clk_bus); breset <= 0;
        wait (done_x >= ops && done_b >= ops);
        repeat (40) @(posedge clk_sys);
        if (errs == 0 && checks > 1000) $display("PASS: %0d checks, %0d+%0d requests (seed %0d, phase %0d)", checks, done_x, done_b, seed0, phase);
        else $display("FAIL: %0d of %0d checks (seed %0d, phase %0d)", errs, checks, seed0, phase);
        $finish;
    end
    initial begin #(64'd4000000000); $display("FAIL: timeout (%0d+%0d requests)", done_x, done_b); $finish; end
endmodule
