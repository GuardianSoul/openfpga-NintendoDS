// nds_g3d_cache against its version before M3 (nds_g3d_cache_ref, from git:
// sim/ds/g3dcache_eq.sh): the same requests and flushes go to both, each with
// its own block port. VRAM words carry a version that each flush moves on.
// Checked for each: every answer is the word asked for, and not older than
// the last flush before its lookup. Checked between them: the same answers in
// the same order (the new one may answer later while a flush waits for its
// scrubber; those cycles are counted).
//   +cycles=N  +seed=S  +flush=N (one flush in N cycles)
//   +alias: half the requests to a region whose lines alias the hot one's (another tag)
module tb_g3dcache_eq;
    parameter int AW = 19;
    parameter int LW = 6;
    // the new one's options (the reference is the plain direct-mapped cache):
    // answers are the same words in the same order whatever they are
    parameter bit FAST = 0;
    parameter bit MIF2 = 0;
    parameter int WAYS = 1;
    parameter int QL = 4;              // the new one's queue (log2); requests in flight up to 2^QL - 4
    parameter bit V2 = 0;              // the new one is nds_g3d_cache2
    parameter bit SCAN = 1;            // ... its scanner
    parameter int PMIF = 1;            // the new one's block port: blocks in flight (1, 2; random latency, beat gaps)

    logic clk = 0;
    always #5 clk = !clk;
    logic rst = 1;
    logic          req = 0, flush = 0;
    logic [AW-1:0] addr = 0;
    logic [7:0]    ver = 0;             // VRAM content version
    longint        nflush = 0;

    logic          valid [2], b_req [2], b_ack [2], b_rvalid [2];
    logic [15:0]   data [2];
    logic [13:0]   b_blk [2];
    logic [63:0]   b_rdata [2];
    nds_g3d_cache_ref #(.AW(AW), .LW(LW)) u_ref (.clk, .rst, .flush, .req, .addr, .valid(valid[0]), .data(data[0]),
        .b_req(b_req[0]), .b_blk(b_blk[0]), .b_ack(b_ack[0]), .b_rvalid(b_rvalid[0]), .b_rdata(b_rdata[0]));
    logic new_idle_look, new_busy;
    generate if (V2) begin : g_v2
        nds_g3d_cache2 #(.AW(AW), .LW(LW), .QL(QL), .SCAN(SCAN)) u_new (.clk, .clk2(1'b0), .rst, .flush, .req, .addr, .valid(valid[1]), .data(data[1]),
            .b_req(b_req[1]), .b_blk(b_blk[1]), .b_ack(b_ack[1]), .b_rvalid(b_rvalid[1]), .b_rdata(b_rdata[1]));
        assign new_idle_look = u_new.st == u_new.C_IDLE && u_new.n != 0 && !u_new.tc_busy;
        assign new_busy = u_new.tc_busy;
    end else begin : g_v1
        nds_g3d_cache #(.AW(AW), .LW(LW), .FAST(FAST), .MIF2(MIF2), .WAYS(WAYS), .QL(QL)) u_new (.clk, .rst, .flush, .req, .addr, .valid(valid[1]), .data(data[1]),
            .b_req(b_req[1]), .b_blk(b_blk[1]), .b_ack(b_ack[1]), .b_rvalid(b_rvalid[1]), .b_rdata(b_rdata[1]));
        assign new_idle_look = u_new.st == u_new.C_IDLE && u_new.n != 0 && !u_new.tc_busy;
        assign new_busy = u_new.tc_busy;
    end endgenerate
    // V2: the flush count at each lookup (l_en), passed on to the answer it gives (C_LOOK hit)
    longint lf1 = 0, lf2 = 0;
    if (V2) begin : g_lf
        always @(posedge clk) begin
            if (g_v2.u_new.l_en) lf1 <= nflush + (flush ? 1 : 0);
            if (g_v2.u_new.st == g_v2.u_new.C_LOOK && g_v2.u_new.hit) lf2 <= lf1;
        end
    end

    function automatic logic [7:0] h8(input logic [AW-2:0] a);
        logic [31:0] x = 32'(a) * 32'h9E37_79B1;
        return x[31:24];
    endfunction

    // ---- per instance: block port, the requests in flight, the checks
    logic [AW-1:1] rq_a [2][$];         // request word addresses, in order
    longint        rq_f [2][$];         // flushes before each request
    longint        ans [2][$];          // answered: {word address, data}
    longint        errs = 0, n_ans [2], n_blk [2], lat_cnt [2], beat_n [2];
    logic          bp_on [2];
    logic [13:0]   bp_blk [2];          // the block acknowledged (the port latches it; b_blk may move on)
    initial for (int k = 0; k < 2; k++) begin n_ans[k] = 0; n_blk[k] = 0; bp_on[k] = 0; beat_n[k] = 0; lat_cnt[k] = 0; end
    // the version as of each instance's last lookup start (C_IDLE -> C_LOOK)
    longint        look_f [2];

    // PMIF 2 (the new one): blocks acknowledged and their first-beat times, in order
    logic [13:0] pq_blk [$];
    longint      pq_at [$];
    longint      pcyc = 0, pbeat = 0;
    always @(posedge clk) pcyc <= pcyc + 1;
    for (genvar k = 0; k < 2; k++) begin : g_k
        if (k == 1 && PMIF > 1) begin : g_p2
        always @(posedge clk) begin
            b_ack[k] <= 1'b0; b_rvalid[k] <= 1'b0;
            if (b_req[k] && !b_ack[k] && pq_blk.size() < PMIF && $urandom % 3 != 0) begin
                b_ack[k] <= 1'b1; n_blk[k] <= n_blk[k] + 1;
                pq_blk.push_back(b_blk[k]);
                pq_at.push_back(pcyc + 2 + $urandom % 12 + (pq_at.size() != 0 ? 4 : 0));
            end
            if (pq_blk.size() != 0 && pq_at[0] <= pcyc && $urandom % 4 != 0) begin
                logic [63:0] d;
                for (int w = 0; w < 4; w++) begin
                    logic [AW-2:0] wa;
                    wa = {pq_blk[0], 2'(pbeat), 2'(w)};
                    d[w*16 +: 16] = {ver, h8(wa)};
                end
                b_rvalid[k] <= 1'b1; b_rdata[k] <= d;
                if (pbeat == 3) begin pbeat <= 0; void'(pq_blk.pop_front()); void'(pq_at.pop_front()); end
                else pbeat <= pbeat + 1;
            end
            if (rst) begin pq_blk.delete(); pq_at.delete(); pbeat <= 0; end
        end
        end else begin : g_p1
        always @(posedge clk) begin
            b_ack[k] <= 1'b0; b_rvalid[k] <= 1'b0;
            if (b_req[k] && !bp_on[k] && !b_ack[k] && beat_n[k] == 0) begin
                bp_on[k] <= 1'b1; lat_cnt[k] <= 1 + (n_blk[k] * 7 + 3) % 6;   // the same latencies for both
            end else if (bp_on[k]) begin
                if (lat_cnt[k] > 1) lat_cnt[k] <= lat_cnt[k] - 1;
                else begin b_ack[k] <= 1'b1; bp_on[k] <= 1'b0; beat_n[k] <= 4; n_blk[k] <= n_blk[k] + 1; bp_blk[k] <= b_blk[k]; end
            end else if (beat_n[k] > 0) begin
                logic [63:0] d;
                for (int w = 0; w < 4; w++) begin
                    logic [AW-2:0] wa;
                    wa = {bp_blk[k], 2'(4 - beat_n[k]), 2'(w)};
                    d[w*16 +: 16] = {ver, h8(wa)};
                end
                b_rvalid[k] <= 1'b1; b_rdata[k] <= d; beat_n[k] <= beat_n[k] - 1;
            end
            if (rst) begin bp_on[k] <= 1'b0; beat_n[k] <= 0; end
        end
        end
        // lookups: the flush count when the lookup reads the tags
        always @(posedge clk) if (k == 0 ? u_ref.st == u_ref.C_IDLE && u_ref.n != 0 : new_idle_look)
            look_f[k] <= nflush + (flush ? 1 : 0);
        always @(posedge clk) if (!rst && valid[k]) begin
            logic [AW-1:1] a;
            logic [7:0]    age;
            a = rq_a[k].pop_front(); void'(rq_f[k].pop_front());
            n_ans[k]++;
            ans[k].push_back({32'(a), 16'd0, data[k]});
            if (data[k][7:0] != h8(a)) begin
                errs++; if (errs < 8) $display("cache %0d: answer %0d for word %h: data %h is another word's", k, n_ans[k], a, data[k]);
            end
            age = 8'(k == 1 && V2 ? lf2 : look_f[k]) - data[k][15:8];
            if (age != 0 && age < 8'd128) begin
                errs++; if (errs < 8) $display("cache %0d: answer %0d for word %h: data from %0d flushes before its lookup", k, n_ans[k], a, age);
            end
        end
    end

    int unsigned seed = 1;
    longint cycles = 500000, cyc = 0, n_req = 0, n_cmp = 0, n_late = 0, busy_cyc = 0;
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
            // at most 12 requests in flight in the reference, 2^QL - 4 in the new one
            if ($urandom % 3 == 0 && rq_a[0].size() < 12 && rq_a[1].size() < (1 << QL) - 4) begin
                req = 1;
                addr = ($urandom % 4 != 0) ? AW'(hot + AW'($urandom % 2048)) : AW'($urandom);
                if (alias_on && $urandom % 2 == 0) addr = AW'(hot + AW'(1 << (LW + 5)) + AW'($urandom % 512));
                for (int k = 0; k < 2; k++) begin rq_a[k].push_back(addr[AW-1:1]); rq_f[k].push_back(nflush); end
                n_req++;
            end
            if ($urandom % flush_1in == 0) flush = 1;
            @(posedge clk);
            if (flush) begin ver <= ver + 1; nflush <= nflush + 1; end
            if (new_busy) busy_cyc++;
            // compare the answers both have given
            while (ans[0].size() > 0 && ans[1].size() > 0) begin
                longint x0, x1;
                x0 = ans[0].pop_front(); x1 = ans[1].pop_front(); n_cmp++;
                if (x0[63:32] != x1[63:32]) begin
                    errs++; if (errs < 8) $display("answer %0d: reference word %h, new %h", n_cmp, x0[63:32], x1[63:32]);
                end
                if (x0[15:0] != x1[15:0]) n_late++;   // same word, another version (timing)
            end
            cyc++;
        end
        $display("g3dcache_eq AW %0d LW %0d: %0d cycles, %0d requests, %0d answers compared (%0d / %0d block reads), %0d of another version, %0d busy cycles: %0d errors",
                 AW, LW, cyc, n_req, n_cmp, n_blk[0], n_blk[1], n_late, busy_cyc, errs);
        if (errs || n_cmp < n_req / 2) begin $display("FAIL"); $fatal(1); end
        $display("PASS");
        $finish;
    end
endmodule
