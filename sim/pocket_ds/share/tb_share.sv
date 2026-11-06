// nds_bport_share (rtl/pocket/nds_bport_share.sv) against a model of nds_sdram_bport: client A (quad and
// single reads, writes; each request held until its c_ready, the next one possibly right after) and client
// B (single reads); the port takes one request at a time, answers c_ready after a random delay and each
// read's words with a random lag, before or after c_ready. Every word carries its request's address, so a
// word reaching the wrong client or out of order is caught; while B is idle the port must see A's signals
// exactly (same clock). +seed=N
`timescale 1ns/1ps
module tb_share;
    logic clk = 0, reset = 1;
    always #5 clk = !clk;
    logic a_valid = 0, a_write = 0, a_quad = 0, b_valid = 0;
    logic [23:0] a_addr = 0, b_addr = 0;
    logic [31:0] a_wdata = 0;
    logic [3:0] a_be = 0;
    wire a_ready, a_rvalid, b_ready, b_rvalid, c_valid, c_write, c_quad;
    wire [23:0] c_addr;
    wire [31:0] c_wdata;
    wire [3:0] c_be;
    logic c_ready = 0, r_valid = 0;
    logic [31:0] r_data = 0;
    nds_bport_share dut (.clk, .reset, .a_valid, .a_write, .a_quad, .a_addr, .a_wdata, .a_be, .a_ready, .a_rvalid,
        .b_valid, .b_addr, .b_ready, .b_rvalid, .c_valid, .c_write, .c_quad, .c_addr, .c_wdata, .c_be, .c_ready, .r_valid);
    integer errors = 0, a_reqs = 0, b_reqs = 0, a_words = 0, b_words = 0, shared = 0;
    task automatic err(input string m); errors++; if (errors < 10) $display("ERROR %0t %s", $time, m); endtask
    // the port model: latch a request when idle (as nds_sdram_bport), c_ready after 2-8 clocks; read words
    // (address tagged: {addr, k}) queued with lags from c_ready - 2 to c_ready + 6
    logic busy = 0;
    integer rdy_at = 0, now = 0;
    logic l_write, l_quad;
    logic [23:0] l_addr;
    int unsigned wq_t [$];
    logic [31:0] wq_d [$];
    always @(posedge clk) begin
        now <= now + 1;
        c_ready <= 0; r_valid <= 0;
        if (busy && now == rdy_at) begin c_ready <= 1; busy <= 0; end
        else if (!busy && c_valid && !c_ready) begin
            busy <= 1; l_write = c_write; l_quad = c_quad; l_addr = c_addr;
            rdy_at <= now + 2 + $urandom % 7;
            if (!c_write) for (int k = 0; k < (c_quad ? 4 : 1); k++) begin
                wq_t.push_back(now + 1 + $urandom % 9 + k); wq_d.push_back({c_addr[21:0], 2'(k), 8'h5A});
                // the request's client (the one whose request this is, by its address on the port)
                if (b_valid && c_addr == b_addr && !a_valid_is(c_addr)) eb.push_back({c_addr[21:0], 2'(k), 8'h5A});
                else ea.push_back({c_addr[21:0], 2'(k), 8'h5A});
            end
        end
        if (wq_t.size() && wq_t[0] <= now) begin r_valid <= 1; r_data <= wq_d[0]; void'(wq_t.pop_front()); void'(wq_d.pop_front()); end
    end
    // client A: random requests, each held until a_ready; expected words in order
    logic [31:0] ea [$];
    logic [31:0] eb [$];
    // the port shows A's request when it carries A's address with A asking (A and B never share an address:
    // A's addresses have bit 23 clear, B's set)
    function automatic logic a_valid_is(input logic [23:0] ad); return a_valid && ad == a_addr; endfunction
    always @(posedge clk) if (!reset) begin
        if (a_rvalid) begin a_words++; if (!ea.size() || r_data !== ea[0]) err($sformatf("A word %h", r_data)); else void'(ea.pop_front()); end
        if (b_rvalid) begin b_words++; if (!eb.size() || r_data !== eb[0]) err($sformatf("B word %h", r_data)); else void'(eb.pop_front()); end
        if (a_valid && a_ready) a_reqs++;
        if (b_valid && b_ready) b_reqs++;
        // while B neither requests nor owns the port, the port is A's, the same clock
        if (!b_valid && !dut.own_b && (c_valid !== a_valid || c_addr !== a_addr || c_write !== a_write || c_quad !== a_quad
            || a_ready !== c_ready || a_rvalid !== r_valid)) err("the port is not A's while B is idle");
        if (b_valid && a_valid) shared++;
    end
    initial begin
        int seed;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        void'($urandom(seed));
        repeat (4) @(posedge clk); reset = 0;
        fork
            repeat (3000) begin   // client A
                @(posedge clk);
                if (!a_valid && $urandom % 3 == 0) begin
                    a_valid <= 1; a_write <= $urandom % 4 == 0; a_quad <= $urandom % 2; a_addr <= $urandom & 24'h7FFFFF; a_wdata <= $urandom; a_be <= 4'hF;
                end else if (a_valid && a_ready) a_valid <= 0;
            end
            repeat (3000) begin   // client B: bursts of single reads, each after the last word came back
                @(posedge clk);
                if (!b_valid && eb.size() == 0 && $urandom % 5 == 0) begin b_valid <= 1; b_addr <= $urandom | 24'h800000; end
                else if (b_valid && b_ready) b_valid <= 0;
            end
        join
        // let the requests still up finish (a request is never withdrawn)
        for (int t = 0; t < 2000 && (a_valid || b_valid); t++) begin
            @(posedge clk);
            if (a_valid && a_ready) a_valid <= 0;
            if (b_valid && b_ready) b_valid <= 0;
        end
        if (a_valid || b_valid) err("a request was never served");
        repeat (100) @(posedge clk);
        if (ea.size() || eb.size()) err($sformatf("words never came: A %0d, B %0d", ea.size(), eb.size()));
        $display("share: A %0d requests %0d words, B %0d requests %0d words, %0d clocks both waiting, %0d errors",
                 a_reqs, a_words, b_reqs, b_words, shared, errors);
        if (errors == 0 && b_reqs > 0 && a_reqs > 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
