// nds_lcache against a register valid array (the clients' code before M3),
// cycle by cycle, random traffic. MODE 0: the ARM7 port's use (G = 0, check
// copy, registered lookups, tag-checked invalidations, fill start clears).
// MODE 1: nds_g3d_cache's (G = 3, lookups read valid now, inv_all on any
// VRAM write, the fill in flight then stale).
//   +cycles=N  +seed=S
module tb_lcache;
    parameter int MODE = 0;
    localparam int LB = MODE == 0 ? 5 : 4;
    parameter int TW = 3;               // few tags: many hits (10: two tag bytes)
    localparam int N  = 1 << LB;
    parameter int GB = 3;
    parameter STYLE = "M10K";         // MODE 0: "MLAB" too               // MODE 1: generation bits
    localparam int G  = MODE == 0 ? 0 : GB;

    logic clk = 0;
    logic clk2 = 0;                     // nds_lcache PUMP only (tb_lcache_pump.sv)
    always #5 clk = !clk;
    logic rst = 1;

    logic          l_en, f_busy, f_end, f_ok, inv, inv_all;
    logic [LB-1:0] l_idx, c_idx, f_idx, inv_idx;
    logic [TW-1:0] f_tag;
    logic          l_v, l_vn, c_v, busy;
    logic [TW-1:0] l_tag, c_tag;
    nds_lcache #(.LB(LB), .TW(TW), .G(G), .CHECK(MODE == 0 ? 1 : 0), .STYLE(STYLE)) dut (.*, .f_busy(MODE == 0 && f_busy));

    // ---- the reference
    logic          rv [N];
    logic [TW-1:0] rt [N];
    logic          r_lv;                // lookup: valid before the edge
    logic [TW-1:0] r_lt, r_ct;
    logic [LB-1:0] r_la, r_ca;
    logic          l_q;                 // a lookup was issued last cycle
    initial for (int i = 0; i < N; i++) begin rv[i] = 0; rt[i] = 0; end

    // ---- stimulus state
    int unsigned seed = 1;
    longint cycles = 200000, cyc = 0, errs = 0;
    int     flush_1in = 40, look_1in = 3;   // MODE 1: one flush / lookup in N cycles
    int     fl_left = 0, n_inv = 0, n_hit = 0, n_lk = 0, n_busy = 0, n_qmax = 0, n_flush = 0, n_wrap = 0;
    logic   stale = 0, fstart = 0;
    int     quiet = 0;
    logic [2:0] cur_q;
    logic [LB-1:0] hot;                 // a few lines most traffic goes to

    function automatic logic [LB-1:0] pick();
        return ($urandom % 4 != 0) ? LB'(hot + LB'($urandom % 4)) : LB'($urandom);
    endfunction

    initial begin
        void'($value$plusargs("cycles=%d", cycles));
        void'($value$plusargs("seed=%d", seed));
        void'($value$plusargs("flush=%d", flush_1in));
        void'($value$plusargs("look=%d", look_1in));
        void'($urandom(seed));
        hot = '0;
        {l_en, f_busy, f_end, f_ok, inv, inv_all} = '0;
        l_idx = '0; c_idx = '0; f_idx = '0; inv_idx = '0; f_tag = '0;
        repeat (3) @(posedge clk);
        rst <= 0;
        repeat (N + 4) @(posedge clk);
        while (cyc < cycles) begin
            @(negedge clk);
            // a fill ends at the edge of its f_end cycle
            if (f_end) f_busy = 1'b0;
            if (fstart) f_busy = 1'b1;        // fl_v rises at the start edge
            #1;
            // ---- compare last cycle's reads
            if (l_q) begin
                n_lk++;
                if (MODE == 0) begin
                    if (l_v !== r_lv || (r_lv && l_tag !== r_lt)) begin
                        errs++; if (errs < 4) $display("cycle %0d: lookup %0d: v %b tag %0d, expected %b %0d | mem %h fb %b %0d q %b lw %b %0d %0d rq %h lm %b", cyc, r_la, l_v, l_tag, r_lv, r_lt, dut.mem[r_la], f_busy, f_idx, dut.qv, dut.lw_v, dut.lw_a, dut.lw_d, dut.rq, dut.lm_q);
                    end
                    if (r_lv) n_hit++;
                end else begin
                    if (l_vn !== rv[r_la] || (rv[r_la] && l_tag !== r_lt)) begin
                        errs++; if (errs < 4) $display("cycle %0d: lookup %0d: v %b tag %0d, expected %b %0d | mem %h cur %0d pend %b lw %b %0d %0d la %0d rq %h", cyc, r_la, l_vn, l_tag, rv[r_la], rt[r_la], dut.mem[r_la], dut.cur, dut.pend, dut.lw_v, dut.lw_a, dut.lw_d, dut.la_q, dut.rq);
                    end
                    if (rv[r_la]) n_hit++;
                end
            end
            if (MODE == 0 && !rst && (c_v !== rv[r_ca] || c_tag !== r_ct)) begin
                errs++; if (errs < 4) $display("cycle %0d: check %0d: v %b tag %0d, expected %b %0d | mem2 %h fb %b %0d q %b lw %b %0d %0d rq2 %h sw %b", cyc, r_ca, c_v, c_tag, rv[r_ca], r_ct, dut.mem2[r_ca], f_busy, f_idx, dut.qv, dut.lw_v, dut.lw_a, dut.lw_d, dut.rq2, dut.sw_on);
            end
            // the tag stores hold the tags the old tag RAM held (only a fill
            // end writes one; everything else writes the tag back)
            // (MLAB: a write waits a cycle in the buffer)
            for (int i = 0; i < N; i++) begin
                logic [TW-1:0] t1, t2;
                t1 = dut.mem[i][TW-1:0]; t2 = dut.mem2[i][TW-1:0];
                if (STYLE == "MLAB" && dut.ww && dut.wwa == i) begin t1 = dut.wwd[TW-1:0]; t2 = t1; end
                if (t1 !== rt[i] || (MODE == 0 && t2 !== rt[i])) begin
                    errs++; if (errs < 4) $display("cycle %0d: entry %0d holds tag %0d / %0d, the tag RAM %0d", cyc, i, t1, t2, rt[i]);
                end
            end
            // ---- this cycle's requests
            if ($urandom % 512 == 0) hot = LB'($urandom);
            l_idx = pick(); c_idx = pick();
            l_en = MODE == 0 ? 1'b1 : (!busy && $urandom % look_1in == 0);
            f_end = 1'b0; inv = 1'b0; inv_all = 1'b0; fstart = 1'b0;
            if (fl_left > 0) begin
                fl_left--;
                if (fl_left == 0) begin f_end = 1'b1; f_ok = MODE == 0 ? ($urandom % 8 != 0) : !stale; end
            end else if (MODE == 0 && !f_busy && quiet == 0 && $urandom % 20000 == 0) begin
                // a reset: the port's caches empty, and it waits for the sweep
                inv_all = 1'b1; quiet = N + 2; n_flush++;
            end else if (quiet > 0) quiet--;
            else if ($urandom % 3 == 0 && !(MODE == 1 && busy)) begin
                f_idx = pick(); f_tag = TW'($urandom); fl_left = 4 + $urandom % 4; stale = 0; fstart = 1'b1;
            end
            if (MODE == 0) begin
                // a tag-checked invalidation of last cycle's check (often)
                // (as the port: the tag read for the check against the
                // write's tag, here mostly that same tag; also right after
                // a fill ended on that line, whose new tag was not read)
                if (!inv_all && rv[r_ca] && r_ct == (($urandom % 4 != 0) ? r_ct : TW'($urandom)) && $urandom % 4 != 0) begin
                    inv = 1'b1; inv_idx = r_ca; n_inv++;
                end
            end else if ($urandom % flush_1in == 0) begin
                inv_all = 1'b1; n_flush++;
                if (fl_left > 0) stale = 1;
            end
            // ---- reference: the old code, as at the next edge
            @(posedge clk);
            cyc++;
            if (busy) n_busy++;
            if ($countones(dut.qv) > n_qmax) n_qmax = $countones(dut.qv);
            if (MODE == 1 && dut.cur != cur_q && dut.cur == 1) n_wrap++;
            cur_q = dut.cur;
            r_lv <= rv[l_idx]; r_lt <= rt[l_idx]; r_la <= l_idx; l_q <= l_en;
            r_ct <= rt[c_idx]; r_ca <= c_idx;
            // fill start (MODE 0 clears the line's valid bit then)
            if (MODE == 0 && fstart) rv[f_idx] <= 1'b0;
            if (f_end) begin rv[f_idx] <= f_ok; rt[f_idx] <= f_tag; end
            if (inv) rv[inv_idx] <= 1'b0;
            if (inv_all) for (int i = 0; i < N; i++) rv[i] <= 1'b0;
        end
        $display("lcache MODE %0d: %0d cycles, %0d lookups (%0d hits), %0d invalidations, queue max %0d, %0d flushes, %0d generation wraps, %0d busy cycles: %0d errors",
                 MODE, cyc, n_lk, n_hit, n_inv, n_qmax, n_flush, n_wrap, n_busy, errs);
        if (errs || n_hit == 0 || n_flush == 0 || (MODE == 0 && n_qmax == 0) || (MODE == 1 && n_wrap == 0)) begin
            $display("FAIL"); $fatal(1);
        end
        $display("PASS");
        $finish;
    end

endmodule
