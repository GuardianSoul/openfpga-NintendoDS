// nds_g3d_store's line stream against a reference model (sim/ds/store_stream_test.sh, docs/geometry-engine.md
// "Store pool: one line's polygons"). One frame of polygons goes in through the geometry side (header, then
// its vertices; render order from the sort), a frame is drawn line by line, and every beat must be the
// expected one: for each line, the polygons that cover it in render order, each as its header and its
// vertices, then the end-of-line beat. A line that takes more than LINE_CLK clocks fails (a stall).
//   +scene=0  random polygons, at most 3/4 of the pool's slots and chunks on any line (STREAM 0 and 1 pass)
//   +scene=1  the Burnout horizon in small: a line with 3x the pool's slots in one-line polygons beside
//             multi-line ones (STREAM 0 stalls, STREAM 1 passes)
//   +scene=2  a 2-line band (item 16): line 120-121 holds 2 << SL polygons spanning both lines (3 vertices each),
//             more than the pool holds: STREAM alone stalls; with DROP the frame goes on, the polygons the
//             pool can't take are dropped (whole: on none of their lines), the rest come out in order
//   +seed=N   the random scene's seed
module tb_g3d_store_stream #(parameter bit STREAM = 1'b1, parameter bit DROP = 1'b0, parameter int SL = 5, parameter int CL = 7);
    logic clk = 0;
    always #5 clk = !clk;
    logic rst = 1;
    localparam int LINE_CLK = 200000;

    // geometry side
    logic         po_valid = 0, po_type = 0, po_wv = 0;
    logic [127:0] po_data = '0;
    logic [10:0]  po_index = '0;
    logic [1:0]   po_wk = '0;
    logic [31:0]  po_wd = '0;
    logic         po_ready;
    logic         so_we = 0, so_done = 0;
    logic [10:0]  so_pos = '0, so_idx = '0;
    logic [11:0]  so_count = '0;
    // raster side
    logic         drawing, lists_bld, frame_go = 0, abort = 0;
    logic [3:0]   diag_ld;
    logic         ps_line_req = 0, ps_valid, ps_ready = 1;
    logic [7:0]   ps_line_y = '0;
    logic [8:0]   y_lim = 9'd255;
    logic [1:0]   ps_type;
    logic [127:0] ps_data;
    // PSRAM
    logic         p_req, p_we, p_ack = 0, p_rvalid = 0;
    logic [22:2]  p_addr;
    logic [31:0]  p_wdata, p_rdata = '0;

    nds_g3d_store #(.SL(SL), .CL(CL), .STREAM(STREAM), .DROP(DROP)) dut (.clk, .rst, .po_valid, .po_ready, .po_type, .po_data,
        .po_index, .po_wv, .po_wk, .po_wd, .so_we, .so_pos, .so_idx, .so_done, .so_count, .drawing, .lists_bld,
        .frame_go, .abort, .diag_ld, .ps_line_req, .ps_line_y, .y_lim, .ps_valid, .ps_ready, .ps_type, .ps_data,
        .p_req, .p_we, .p_addr, .p_wdata, .p_ack, .p_rvalid, .p_rdata, .p_wdrained(1'b1));

    // PSRAM model: a request is taken after 2-5 clocks; a read then returns its 4 words a clock apart
    logic [31:0] mem [logic [22:2]];
    int          p_wait = 0, rd_left = 0;
    logic [22:2] rd_a;
    always @(posedge clk) begin
        p_ack <= 0; p_rvalid <= 0;
        if (rd_left > 0) begin
            p_rvalid <= 1; p_rdata <= mem.exists(rd_a) ? mem[rd_a] : 32'hDEAD0000; rd_a <= rd_a + 1; rd_left <= rd_left - 1;
        end else if (p_req && !p_ack) begin
            if (p_wait == 0) p_wait <= 2 + $urandom_range(0, 3);
            else if (p_wait == 1) begin
                p_wait <= 0; p_ack <= 1;
                if (p_we) mem[p_addr] = p_wdata;
                else begin rd_a <= p_addr; rd_left <= 4; end
            end else p_wait <= p_wait - 1;
        end
    end

    // the frame
    localparam int NP_MAX = 2048;
    int          np;
    int          ytop [NP_MAX], ybot [NP_MAX], nv [NP_MAX];
    int          order [NP_MAX];                 // render position -> polygon index
    logic [31:0] vw [NP_MAX][10][4];             // vertex words (word 3: 20 bits kept)
    logic [31:0] hw [NP_MAX][4];                 // header words as geom writes them

    // lines a polygon goes out on (nds_g3d_store: ytop to ybot - 1, at least ytop)
    function automatic bit covers(int i, int y);
        return y >= ytop[i] && (y == ytop[i] || y < ybot[i]) && ytop[i] < 192;
    endfunction

    function automatic void make_header(int i);
        logic [127:0] h;
        h = '0;
        h[31:0] = 32'h1000 + i;                  // payload, so each header differs
        h[63:32] = $urandom;
        h[76:64] = 13'($urandom);
        h[80:77] = 4'(nv[i]);
        h[88:81] = 8'($urandom);
        h[96:89] = 8'(ytop[i]);
        h[104:97] = 8'(ybot[i]);
        h[106:105] = 2'($urandom);
        h[107] = 1'b0;
        for (int k = 0; k < 4; k++) hw[i][k] = h[k*32 +: 32];
        for (int v = 0; v < nv[i]; v++) begin
            vw[i][v][0] = $urandom; vw[i][v][1] = $urandom; vw[i][v][2] = $urandom;
            vw[i][v][3] = {12'd0, 20'($urandom)};
        end
    endfunction

    // scene 0: random, the pool never more than 3/4 full on a line (counted over everything that covers it)
    function automatic void scene_random();
        int lp [192], lv [192];
        foreach (lp[y]) begin lp[y] = 0; lv[y] = 0; end
        np = 0;
        for (int t = 0; t < 4000 && np < 600; t++) begin
            int a, h, n, ok, b;
            a = $urandom_range(0, 191);
            h = $urandom_range(0, 3) == 0 ? $urandom_range(0, 60) : $urandom_range(0, 6);
            n = $urandom_range(3, 10);
            ok = 1;
            b = a + h > 191 ? 191 : a + h;
            ytop[np] = a; ybot[np] = b; nv[np] = n;
            for (int y = 0; y < 192; y++) if (covers(np, y) && (lp[y] + 1 > (3 << SL) / 4 || lv[y] + n > (3 << CL) / 4)) ok = 0;
            if (ok) begin
                for (int y = 0; y < 192; y++) if (covers(np, y)) begin lp[y]++; lv[y] += n; end
                np++;
            end
        end
    endfunction

    // scene 1: line 100 holds 3 << SL one-line polygons (3 vertices each) between multi-line ones that
    // take half the slots; every other line is light
    function automatic void scene_horizon();
        int half = (1 << SL) / 2;
        np = 0;
        for (int i = 0; i < half; i++) begin ytop[np] = 90 + i % 8; ybot[np] = 110 + i % 7; nv[np] = 3; np++; end
        for (int i = 0; i < (3 << SL); i++) begin ytop[np] = 100; ybot[np] = 100 + (i % 2); nv[np] = 3; np++; end
        for (int i = 0; i < 20; i++) begin ytop[np] = $urandom_range(0, 180); ybot[np] = ytop[np] + 4; nv[np] = 4; np++; end
    endfunction

    // scene 2: the 2-line band
    function automatic void scene_band();
        np = 0;
        for (int i = 0; i < (2 << SL); i++) begin ytop[np] = 120; ybot[np] = 122; nv[np] = 3; np++; end
        for (int i = 0; i < 20; i++) begin ytop[np] = $urandom_range(0, 100); ybot[np] = ytop[np] + 4; nv[np] = 4; np++; end
    endfunction

    // DROP's check (scene 2): per line the polygons covering it in render order; a header names its polygon (payload
    // 0x1000 + index); polygons skipped before it, or left at the line's end, are dropped and may not come out on any line
    int dl_ptr = 0, dl_i = -1, dl_vk = 0, dl_vleft = 0, n_drop = 0;
    bit dropped [NP_MAX], seen [NP_MAX];
    function automatic int line_poly(int y, int k);   // the k-th polygon covering line y in render order, -1 past the end
        int c = 0;
        for (int p = 0; p < np; p++) if (covers(order[p], y)) begin if (c == k) return order[p]; c++; end
        return -1;
    endfunction
    function automatic void drop_beat(int y, logic [1:0] t, logic [127:0] d);
        if (t == 0) begin
            int i, q;
            i = int'(d[15:0]) - 32'h1000;
            if (i < 0 || i >= np || dropped[i]) begin errors++; $display("FAIL: line %0d: header of polygon %0d (dropped or unknown)", y, i); return; end
            while ((q = line_poly(y, dl_ptr)) != i && q >= 0) begin
                if (seen[q]) begin errors++; $display("FAIL: line %0d: polygon %0d missing after it came out", y, q); end
                if (!dropped[q]) n_drop++;
                dropped[q] = 1; dl_ptr++;
            end
            if (q < 0) begin errors++; $display("FAIL: line %0d: polygon %0d out of order or not on this line", y, i); return; end
            if (d[106:0] !== {hw[i][3][10:0], hw[i][2], hw[i][1], hw[i][0]}) begin errors++; $display("FAIL: line %0d: polygon %0d header", y, i); end
            seen[i] = 1; dl_i = i; dl_vk = 0; dl_vleft = nv[i]; dl_ptr++;
        end else if (t == 1) begin
            if (dl_vleft == 0 || d !== {12'd0, vw[dl_i][dl_vk][3][19:0], vw[dl_i][dl_vk][2], vw[dl_i][dl_vk][1], vw[dl_i][dl_vk][0]}) begin
                errors++; if (errors < 10) $display("FAIL: line %0d: vertex %0d of polygon %0d", y, dl_vk, dl_i);
            end
            dl_vk++; if (dl_vleft > 0) dl_vleft--;
        end else begin
            int q;
            if (dl_vleft != 0) begin errors++; $display("FAIL: line %0d ends inside polygon %0d", y, dl_i); end
            while ((q = line_poly(y, dl_ptr)) >= 0) begin
                if (seen[q]) begin errors++; $display("FAIL: line %0d: polygon %0d missing after it came out", y, q); end
                if (!dropped[q]) n_drop++;
                dropped[q] = 1; dl_ptr++;
            end
            dl_ptr = 0; dl_vleft = 0;
        end
    endfunction

    // the expected beats in a queue: {type, data}
    typedef struct { logic [1:0] t; logic [127:0] d; } beat_t;
    beat_t       exp_q [$];
    function automatic void expect_frame();
        for (int y = 0; y < 192; y++) begin
            for (int p = 0; p < np; p++) begin
                int i;
                beat_t b;
                i = order[p];
                if (!covers(i, y)) continue;
                b.t = 0; b.d = '0; b.d[106:0] = {hw[i][3][10:0], hw[i][2], hw[i][1], hw[i][0]};
                exp_q.push_back(b);
                for (int v = 0; v < nv[i]; v++) begin
                    b.t = 1; b.d = {12'd0, vw[i][v][3][19:0], vw[i][v][2], vw[i][v][1], vw[i][v][0]};
                    exp_q.push_back(b);
                end
            end
            begin beat_t b; b.t = 3; b.d = 'x; exp_q.push_back(b); end
        end
    endfunction

    task automatic write_record(input bit typ, input int idx, input logic [31:0] w [4]);
        for (int k = 0; k < 4; k++) begin
            @(negedge clk); po_wv = 1; po_wk = 2'(k); po_wd = w[k];
        end
        @(negedge clk); po_wv = 0; po_valid = 1; po_type = typ; po_index = 11'(idx);
        po_data = {w[3], w[2], w[1], w[0]};
        @(posedge clk); while (!po_ready) @(posedge clk);
        @(negedge clk); po_valid = 0;
    endtask

    int scene = 0, seed = 1, beats = 0, errors = 0;
    int line = 0, line_clk = 0;
    bit running = 0;
    always @(posedge clk) begin
        if (running) begin
            line_clk++;
            if (line_clk > LINE_CLK) begin
                $display("STALL: line %0d took more than %0d clocks (%0d beats so far)", line, LINE_CLK, beats);
                $display("  loader state %0d line %0d | fetcher state %0d line %0d | free slots %0d chunks %0d",
                         dut.lst, dut.ly, dut.fst, dut.fy, dut.fs_n, dut.fc_n);
                begin int cp, cv; cp = 0; cv = 0; for (int i = 0; i < np; i++) if (covers(i, line)) begin cp++; cv += nv[i]; end
                $display("  line %0d: %0d polygons, %0d vertices cover it", line, cp, cv); end
                $finish;
            end
        end
        if (ps_valid && ps_ready && scene == 2 && DROP) begin
            drop_beat(line, ps_type, ps_data);
            beats++;
            if (ps_type == 2'd3) begin line++; line_clk = 0; end
        end else if (ps_valid && ps_ready) begin
            beat_t e;
            if (exp_q.size() == 0) begin $display("FAIL: beat after the frame's last"); errors++; end
            else begin
                e = exp_q.pop_front();
                if (ps_type != e.t || (e.t != 3 && ps_data !== e.d)) begin
                    if (errors < 10) $display("FAIL: line %0d beat %0d: type %0d data %h, expected type %0d data %h",
                                              line, beats, ps_type, ps_data, e.t, e.d);
                    if (errors < 10 && ps_type == 0 && e.t == 0)
                        for (int p = 0; p < np; p++) if (order[p] == int'(ps_data[15:0]) - 4096 || order[p] == int'(e.d[15:0]) - 4096)
                            $display("  position %0d: polygon %0d ytop %0d ybot %0d", p, order[p], ytop[order[p]], ybot[order[p]]);
                    errors++;
                end
            end
            beats++;
            if (ps_type == 2'd3) begin line++; line_clk = 0; end
        end
    end
    // a random ready, so the fetcher's held beats are covered
    always @(negedge clk) ps_ready = $urandom_range(0, 3) != 0;

    initial begin
        void'($value$plusargs("scene=%d", scene));
        void'($value$plusargs("seed=%d", seed));
        void'($urandom(seed));
        if (scene == 0) scene_random(); else if (scene == 1) scene_horizon(); else scene_band();
        for (int i = 0; i < np; i++) make_header(i);
        // render order: a random permutation
        for (int i = 0; i < np; i++) order[i] = i;
        for (int i = np - 1; i > 0; i--) begin int j, t; j = $urandom_range(0, i); t = order[i]; order[i] = order[j]; order[j] = t; end
        expect_frame();
        $display("scene %0d: %0d polygons, %0d beats expected; first ytop %0d ybot %0d nv %0d", scene, np, exp_q.size(), ytop[0], ybot[0], nv[0]);
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (5) @(posedge clk);
        // records: each header, then its vertices
        for (int i = 0; i < np; i++) begin
            write_record(0, i, hw[i]);
            for (int v = 0; v < nv[i]; v++) write_record(1, i, vw[i][v]);
        end
        for (int p = 0; p < np; p++) begin
            @(negedge clk); so_we = 1; so_pos = 11'(p); so_idx = 11'(order[p]);
        end
        @(negedge clk); so_we = 0; so_done = 1; so_count = 12'(np);
        @(negedge clk); so_done = 0;
        while (lists_bld || !dut.ready) @(posedge clk);
        repeat (10) @(posedge clk);
        @(negedge clk); frame_go = 1;
        @(negedge clk); frame_go = 0;
        running = 1;
        for (int y = 0; y < 192; y++) begin
            @(negedge clk); ps_line_req = 1; ps_line_y = 8'(y);
            @(negedge clk); ps_line_req = 0;
            while (line == y) @(posedge clk);
        end
        running = 0;
        repeat (20) @(posedge clk);
        if (scene == 2 && DROP) begin
            if (line != 192) begin $display("FAIL: %0d lines", line); errors++; end
            if (n_drop == 0) begin $display("FAIL: nothing dropped (the band exceeds the pool)"); errors++; end
            $display("DROP: %0d of %0d polygons dropped", n_drop, np);
        end else if (exp_q.size() != 0) begin $display("FAIL: %0d beats never came", exp_q.size()); errors++; end
        $display("%s: STREAM %0d DROP %0d SL %0d CL %0d scene %0d seed %0d: %0d polygons, %0d beats, %0d errors",
                 errors == 0 ? "PASS" : "FAIL", STREAM, DROP, SL, CL, scene, seed, np, beats, errors);
        $finish;
    end
endmodule
