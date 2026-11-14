// +g2dreuse (simulation only): each 2D cache fill pushed to VRAM (gpu2d out_* -> vr_ack), by target cache
// (0 BG map, 1 BG texel, 2 BG ext palette, 3 OBJ texel, 4 OBJ ext palette) and demand/prefetch, classed by its
// reuse distance: distinct blocks of that cache filled since this block's previous fill (an LRU stack, fully
// associative). "cold" = first fill since the cache was last started over (cclear) or ever. A distance < 64 in a
// 64-block cache is a conflict (hash) or a write invalidation; 64..127 would hit in a 128-block cache.
`define GR_G dut.ds.u_disp.u_gpu2d
    bit gr_on = 0;
    initial gr_on = $test$plusargs("g2dreuse");
    typedef logic [17:0] gr_blk_t;
    gr_blk_t gr_lru[5][$];
    longint gr_h[5][2][9];   // [target][prefetch][cold, 0, 1, 2-7, 8-31, 32-63, 64-127, 128-511, >=512]
    longint gr_clr[2];
    always @(posedge dut.clk_sys) if (gr_on) begin
        if (`GR_G.u_bg.cclear)  begin gr_clr[0]++; for (int t = 0; t < 3; t++) gr_lru[t].delete(); end
        if (`GR_G.u_obj.cclear) begin gr_clr[1]++; for (int t = 3; t < 5; t++) gr_lru[t].delete(); end
        if (`GR_G.vr_req && `GR_G.vr_ack) begin
            int t, p, d, b;
            t = int'(`GR_G.out_t); p = `GR_G.out_r >= 3'd5 ? 1 : 0; d = -1;
            foreach (gr_lru[t][i]) if (gr_lru[t][i] == `GR_G.out_blk) begin d = i; break; end
            if (d >= 0) gr_lru[t].delete(d);
            gr_lru[t].push_front(`GR_G.out_blk);
            b = d < 0 ? 0 : d == 0 ? 1 : d == 1 ? 2 : d < 8 ? 3 : d < 32 ? 4 : d < 64 ? 5 : d < 128 ? 6 : d < 512 ? 7 : 8;
            if (t < 5) gr_h[t][p][b]++;
        end
    end
    final if (gr_on) begin
        $display("g2dreuse clears bg %0d obj %0d (cold,0,1,2-7,8-31,32-63,64-127,128-511,>=512)", gr_clr[0], gr_clr[1]);
        for (int t = 0; t < 5; t++) for (int p = 0; p < 2; p++)
            $display("g2dreuse t%0d %s %0d %0d %0d %0d %0d %0d %0d %0d %0d", t, p ? "pf" : "dm",
                     gr_h[t][p][0], gr_h[t][p][1], gr_h[t][p][2], gr_h[t][p][3], gr_h[t][p][4], gr_h[t][p][5], gr_h[t][p][6], gr_h[t][p][7], gr_h[t][p][8]);
    end
// +g2dreuse: shadow BG texel caches on the lookup stream (u_tc: a new block latched while not held and not idle,
// plus the BG prefetch fills pushed), each started over at the BG cclear: the RTL's 64-block direct-mapped HASH 1
// cache, 2-way x 32 sets and 4-way x 16 sets (same hash on the set bits, LRU), direct-mapped 128 blocks
`define GR_TC dut.ds.u_disp.u_gpu2d.u_bg.u_tc
    function automatic int gr_idx(input logic [17:0] w, input int n);
        logic [17:0] c0, c1, c2, r1; int m;
        m = (1 << n) - 1;
        c0 = w & m; c1 = (w >> n) & m; c2 = (w >> (2 * n)) & m; r1 = 0;
        for (int i = 0; i < n; i++) r1[i] = c1[n-1-i];
        return int'((c0 ^ r1 ^ c2) & m);
    endfunction
    // shadow k: ways W[k], set bits S[k]; tags gs_t[k][set*ways+way], age gs_a (bigger = older)
    localparam int GS_N = 4;
    int gs_w[GS_N] = '{1, 2, 4, 1};
    int gs_s[GS_N] = '{6, 5, 4, 7};
    logic [18:0] gs_t[GS_N][128];   // {valid, blk}
    int          gs_a[GS_N][128];
    longint      gs_acc, gs_miss[GS_N];
    logic [17:0] gs_last; bit gs_lv = 0;
    function automatic bit gs_look(input int k, input logic [17:0] b, input bit count);
        int s, w, base, v; bit h;
        s = gr_idx(b, gs_s[k]); w = gs_w[k]; base = s * w; v = -1; h = 0;
        for (int i = 0; i < w; i++) if (gs_t[k][base + i] == {1'b1, b}) v = i;
        if (v < 0) begin   // miss: fill the oldest way
            int o = 0;
            for (int i = 1; i < w; i++) if (gs_a[k][base + i] > gs_a[k][base + o]) o = i;
            gs_t[k][base + o] = {1'b1, b}; v = o;
            if (count) gs_miss[k]++;
        end else h = 1;
        for (int i = 0; i < w; i++) gs_a[k][base + i]++;
        gs_a[k][base + v] = 0;
        return h;
    endfunction
    always @(posedge dut.clk_sys) if (gr_on) begin
        if (`GR_G.u_bg.cclear) begin for (int k = 0; k < GS_N; k++) for (int i = 0; i < 128; i++) gs_t[k][i] = '0; gs_lv = 0; end
        if (!`GR_TC.hold && !`GR_TC.idle && !(gs_lv && `GR_TC.a_blk == gs_last)) begin
            gs_acc++; gs_last = `GR_TC.a_blk; gs_lv = 1;
            for (int k = 0; k < GS_N; k++) void'(gs_look(k, `GR_TC.a_blk, 1));
        end
        if (`GR_G.vr_req && `GR_G.vr_ack && `GR_G.out_r == 3'd5)
            for (int k = 0; k < GS_N; k++) void'(gs_look(k, `GR_G.out_blk, 0));
    end
    final if (gr_on) $display("g2dreuse shadow BG texel: %0d block lookups; misses DM64 %0d, 2wx32 %0d, 4wx16 %0d, DM128 %0d",
                              gs_acc, gs_miss[0], gs_miss[1], gs_miss[2], gs_miss[3]);
// +g2dreuse: in the DM64 shadow, each miss of a block that an eviction removed: the XOR of it and the block that
// evicted it (the colliding pair's address difference), top 12; plus DM64 misses under alternative index functions
    logic [17:0] gc_by[logic [17:0]];      // victim -> the block that evicted it
    longint      gc_x[logic [17:0]];
    logic [18:0] gc_t[4][64];
    longint      gc_m[4];
    logic [17:0] gc_last; bit gc_lv = 0;
    function automatic int gc_idx(input int h, input logic [17:0] w);
        logic [5:0] c0, c1, c2, r1;
        c0 = w[5:0]; c1 = w[11:6]; c2 = w[17:12];
        for (int i = 0; i < 6; i++) r1[i] = c1[5-i];
        case (h)
            0: return int'(c0 ^ r1 ^ c2);                       // HASH 1 (the RTL)
            1: return int'(c0 ^ c1);                            // HASH 0
            2: return int'(c0 ^ {c1[3:0], c1[5:4]} ^ {c2[2:0], c2[5:3]});
            default: return int'(c0 ^ r1 ^ {c2[0], c2[1], c2[2], c2[3], c2[4], c2[5]});
        endcase
    endfunction
    always @(posedge dut.clk_sys) if (gr_on) begin
        bit lk, pf;
        if (`GR_G.u_bg.cclear) begin for (int h = 0; h < 4; h++) for (int i = 0; i < 64; i++) gc_t[h][i] = '0; gc_lv = 0; end
        lk = !`GR_TC.hold && !`GR_TC.idle && !(gc_lv && `GR_TC.a_blk == gc_last);
        pf = `GR_G.vr_req && `GR_G.vr_ack && `GR_G.out_r == 3'd5;
        if (lk) begin gc_last = `GR_TC.a_blk; gc_lv = 1; end
        for (int n = 0; n < 2; n++) if (n == 0 ? lk : pf) begin
            logic [17:0] b; int i;
            b = n == 1 ? `GR_G.out_blk : `GR_TC.a_blk;
            for (int h = 0; h < 4; h++) begin
                i = gc_idx(h, b);
                if (gc_t[h][i] != {1'b1, b}) begin
                    gc_m[h]++;
                    if (h == 0) begin
                        if (gc_by.exists(b)) begin logic [17:0] x = b ^ gc_by[b]; if (gc_x.exists(x)) gc_x[x]++; else gc_x[x] = 1; end
                        if (gc_t[0][i][18]) gc_by[gc_t[0][i][17:0]] = b;
                    end
                    gc_t[h][i] = {1'b1, b};
                end
            end
        end
    end
    final if (gr_on) begin
        longint best[12]; logic [17:0] bx[12];
        foreach (best[k]) best[k] = 0;
        foreach (gc_x[x]) for (int k = 0; k < 12; k++) if (gc_x[x] > best[k]) begin
            for (int j = 11; j > k; j--) begin best[j] = best[j-1]; bx[j] = bx[j-1]; end
            best[k] = gc_x[x]; bx[k] = x; break;
        end
        $display("g2dreuse DM64 index variants misses: HASH1 %0d, HASH0 %0d, rot %0d, rev2 %0d", gc_m[0], gc_m[1], gc_m[2], gc_m[3]);
        for (int k = 0; k < 12; k++) if (best[k] != 0) $display("g2dreuse conflict xor %05h: %0d", bx[k], best[k]);
    end
