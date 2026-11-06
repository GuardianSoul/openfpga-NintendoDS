`timescale 1ns/100ps
// nds_lcache PUMP = 1 (the tag store's two copies as one block double-pumped on clk2) against
// PUMP = 0, every clk cycle: random lookups, checks, fills, tag-checked invalidations and
// flushes (inv_all) drive both; l_v, l_vn, l_tag, c_v, c_tag and busy are compared just before
// each clk edge. Inputs are junk from just after the edge until just after the middle clk2 edge
// (logic that settles late), so a design that sampled them at the middle edge fails. G = 3 and LB = 8 / TW = 8 as nds_g3d_cache2's
// texture tags (-GLB=6 -GTW=3: its palette tags).   +cycles=N +seed=S
module tb_lcache_pump;
    parameter int LB = 8;
    parameter int TW = 8;
    localparam int N = 1 << LB;
    logic clk = 1'b0, clk2 = 1'b0;       // both rise at 10, 20, ...; clk2 also at 15, 25, ...
    initial begin #10; forever begin clk = 1; #5; clk = 0; #5; end end
    initial begin #10; forever begin clk2 = 1; #2.5; clk2 = 0; #2.5; end end
    logic          rst = 1'b1;
    logic          l_en = 0, f_busy = 0, f_end = 0, f_ok = 0, inv = 0, inv_all = 0;
    logic [LB-1:0] l_idx = '0, c_idx = '0, f_idx = '0, inv_idx = '0;
    logic [TW-1:0] f_tag = '0;
    logic          lv [2], lvn [2], cv [2], bz [2];
    logic [TW-1:0] lt [2], ct [2];
    nds_lcache #(.LB(LB), .TW(TW), .G(3), .CHECK(1), .PUMP(1'b0)) u_p (.clk, .clk2, .rst, .l_en, .l_idx,
        .l_v(lv[0]), .l_vn(lvn[0]), .l_tag(lt[0]), .c_idx, .c_v(cv[0]), .c_tag(ct[0]), .f_busy, .f_idx, .f_end,
        .f_ok, .f_tag, .inv, .inv_idx, .inv_all, .busy(bz[0]));
    nds_lcache #(.LB(LB), .TW(TW), .G(3), .CHECK(1), .PUMP(1'b1)) u_q (.clk, .clk2, .rst, .l_en, .l_idx,
        .l_v(lv[1]), .l_vn(lvn[1]), .l_tag(lt[1]), .c_idx, .c_v(cv[1]), .c_tag(ct[1]), .f_busy, .f_idx, .f_end,
        .f_ok, .f_tag, .inv, .inv_idx, .inv_all, .busy(bz[1]));

    longint cycles = 200000, n = 0, bad = 0, n_hit = 0, n_chit = 0, n_inv = 0, n_fl = 0, n_fe = 0;
    int unsigned seed = 1;
    int fl_left = 0;
    logic [LB-1:0] fi_q = '0;
    logic [TW-1:0] ft_q = '0;
    logic fok_q = 0;
    logic [LB-1:0] hot = '0, ca_q = '0;
    function automatic logic [LB-1:0] pick();
        return ($urandom % 4 != 0) ? LB'(hot + LB'($urandom % 4)) : LB'($urandom);
    endfunction
    initial begin
        void'($value$plusargs("cycles=%d", cycles));
        void'($value$plusargs("seed=%d", seed));
        void'($urandom(seed));
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        while (n < cycles) begin
            @(posedge clk);
            #1;
            ca_q = c_idx;                // the line the check read at this edge
            // junk until after the middle clk2 edge (late-settling logic), this cycle's values after it
            {l_en, f_end, f_ok, inv, inv_all} = 5'($urandom);
            l_idx = LB'($urandom); c_idx = LB'($urandom); f_idx = LB'($urandom); inv_idx = LB'($urandom); f_tag = TW'($urandom);
            #5;
            if ($urandom % 512 == 0) hot = LB'($urandom);
            l_idx = pick(); c_idx = pick();
            l_en = $urandom % 3 != 0;
            f_end = 1'b0; inv = 1'b0; inv_all = 1'b0; f_idx = fi_q; f_tag = ft_q; f_ok = fok_q;
            if (fl_left > 0) begin
                fl_left--;
                if (fl_left == 0) begin f_end = 1'b1; f_ok = $urandom % 8 != 0; fok_q = f_ok; f_busy = 1'b0; n_fe++; end
            end else if ($urandom % 3 == 0) begin
                f_idx = pick(); f_tag = TW'($urandom % 6); fi_q = f_idx; ft_q = f_tag; fl_left = 2 + $urandom % 5; f_busy = $urandom % 2;
            end
            // a tag-checked invalidation of the line the last edge's check read (often with a fill end:
            // the queue), a flush now and then
            if (!bz[0] && $urandom % 6 == 0) begin inv = 1'b1; inv_idx = ca_q; n_inv++; end
            if ($urandom % 300 == 0) begin inv_all = 1'b1; n_fl++; end
        end
        $display("lcache pump LB %0d TW %0d: %0d cycles, %0d lookup hits, %0d check hits, %0d fill ends, %0d invalidations, %0d flushes: %0d mismatches -> %s",
                 LB, TW, n, n_hit, n_chit, n_fe, n_inv, n_fl, bad, (bad == 0 && n_hit > 0 && n_chit > 0) ? "PASS" : "FAIL");
        $finish;
    end
    // the outputs just before the next edge
    always @(posedge clk) if (!rst) begin
        #9.9;
        n++;
        if (lv[0] && lvn[0]) n_hit++;
        if (cv[0]) n_chit++;
        if (lv[0] !== lv[1] || lvn[0] !== lvn[1] || lt[0] !== lt[1] || cv[0] !== cv[1] || ct[0] !== ct[1] || bz[0] !== bz[1]) begin
            bad++;
            if (bad < 5) $display("MISMATCH cycle %0d: l_v %b/%b l_vn %b/%b l_tag %h/%h c_v %b/%b c_tag %h/%h busy %b/%b", n,
                                  lv[0], lv[1], lvn[0], lvn[1], lt[0], lt[1], cv[0], cv[1], ct[0], ct[1], bz[0], bz[1]);
        end
    end
endmodule
