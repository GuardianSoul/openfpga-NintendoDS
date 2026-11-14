// nds_g3d_cache2 in lockstep against its version at a base commit (sim/ds/tc2_lock.sh): both instances take the
// same requests, flushes and block-port signals (the port answers the new one's b_req), and every output is
// compared at every clock. Stimulus as tb_g3dcache_eq's (a hot window, aliasing sets, flushes).
`timescale 1ns/1ps
module tb_tc2_lock;
    parameter int AW = 19;
    parameter int LW = 9;
    parameter int QL = 4;
    parameter int NF = 2;
    parameter bit PUMP = 1;
    parameter int WAYS = 4;
    parameter bit SCAN = 1;
    logic clk = 0, clk2 = 1;
    always #5 clk = !clk;
    always #2.5 clk2 = !clk2;           // 2 x clk, rising with clk
    logic rst = 1;
    logic          req = 0, flush = 0;
    logic [AW-1:0] addr = 0;
    logic          b_ack = 0, b_rvalid = 0;
    logic [63:0]   b_rdata = 0;
    logic          valid [2], b_req [2];
    logic [15:0]   data [2];
    logic [13:0]   b_blk [2];
    nds_g3d_cache2_ref #(.AW(AW), .LW(LW), .QL(QL), .NF(NF), .PUMP(PUMP), .WAYS(WAYS), .SCAN(SCAN)) u_ref (.clk, .clk2, .rst, .flush,
        .req, .addr, .valid(valid[0]), .data(data[0]), .b_req(b_req[0]), .b_blk(b_blk[0]), .b_ack, .b_rvalid, .b_rdata,
        .pf_v(1'b0), .pf_a('0));
    nds_g3d_cache2 #(.AW(AW), .LW(LW), .QL(QL), .NF(NF), .PUMP(PUMP), .WAYS(WAYS), .SCAN(SCAN)) u_new (.clk, .clk2, .rst, .flush,
        .req, .addr, .valid(valid[1]), .data(data[1]), .b_req(b_req[1]), .b_blk(b_blk[1]), .b_ack, .b_rvalid, .b_rdata,
        .pf_v(1'b0), .pf_a('0));
    // the block port (NF blocks acknowledged at most, random latency and beat gaps), answering the new one
    logic [13:0] pq_blk [$];
    longint      pq_at [$];
    longint      cyc = 0, pbeat = 0, nblk = 0, nans = 0, diff = 0, nreq = 0, inflight = 0;
    always @(posedge clk) begin
        b_ack <= 1'b0; b_rvalid <= 1'b0;
        if (!rst && b_req[1] && !b_ack && pq_blk.size() < NF && $urandom % 3 != 0) begin
            b_ack <= 1'b1; nblk <= nblk + 1;
            pq_blk.push_back(b_blk[1]);
            pq_at.push_back(cyc + 2 + $urandom % 12 + (pq_at.size() != 0 ? 4 : 0));
        end
        if (pq_blk.size() != 0 && pq_at[0] <= cyc && $urandom % 4 != 0) begin
            b_rvalid <= 1'b1; b_rdata <= {$urandom, $urandom};
            if (pbeat == 3) begin pbeat <= 0; void'(pq_blk.pop_front()); void'(pq_at.pop_front()); end
            else pbeat <= pbeat + 1;
        end
    end
    always @(posedge clk) if (!rst) begin
        if (valid[1]) nans <= nans + 1;
        if ({valid[0], data[0], b_req[0], b_blk[0]} != {valid[1], data[1], b_req[1], b_blk[1]}) begin
            diff <= diff + 1;
            if (diff < 10) $display("TC2LOCK differs at clock %0d: base %b %h %b %h, new %b %h %b %h", cyc,
                                    valid[0], data[0], b_req[0], b_blk[0], valid[1], data[1], b_req[1], b_blk[1]);
        end
    end
    int unsigned seed = 1;
    longint cycles = 500000;
    int     flush_1in = 60;
    bit     alias_on;
    logic [AW-1:0] hot;
    initial begin
        void'($value$plusargs("cycles=%d", cycles));
        void'($value$plusargs("seed=%d", seed));
        void'($value$plusargs("flush=%d", flush_1in));
        alias_on = $test$plusargs("alias");
        void'($urandom(seed));
        hot = AW'($urandom);
        repeat (4) @(posedge clk);
        rst = 0;
        while (cyc < cycles) begin
            @(negedge clk);
            req = 0; flush = 0;
            if ($urandom % 1024 == 0) hot = AW'($urandom);
            if ($urandom % 3 == 0 && inflight < (1 << QL) - 4) begin
                req = 1; nreq++;
                addr = ($urandom % 4 != 0) ? AW'(hot + AW'($urandom % 2048)) : AW'($urandom);
                // the same set, other tags: the ways of one set fill and are replaced
                if (alias_on && $urandom % 2 == 0) addr = AW'(hot + AW'(($urandom % 8) << (LW + 3)) + AW'($urandom % 64));
            end
            if ($urandom % flush_1in == 0) flush = 1;
            @(posedge clk);
            inflight = inflight + (req ? 1 : 0) - (valid[1] ? 1 : 0);
            cyc++;
        end
        $display("TC2LOCK AW %0d LW %0d WAYS %0d: %0d cycles, %0d requests, %0d answers, %0d blocks: %0d differing clocks",
                 AW, LW, WAYS, cyc, nreq, nans, nblk, diff);
        if (diff != 0 || nans < nreq / 2) $display("FAIL"); else $display("PASS");
        $finish;
    end
endmodule
