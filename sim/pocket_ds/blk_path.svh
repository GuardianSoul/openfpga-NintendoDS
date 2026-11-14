// +blkpath: a 2D or 3D texel block's time along its path through nds_vram (clk_sys clocks), means printed at the end:
//   q    g_req to g_ack (waiting in nds_vram: blocks in flight, a CPU access, a posted word)
//   i    g_ack to vm_ack (S_GRES/S_GBLK and the crossing port taking the request)
//   r    vm_ack to the block's first word back (the crossing in, the SDRAM bus, the crossing out)
//   s    first to last of its 8 words
//   o    last word to the client's last pair (g_rvalid)
//   f    2D: last pair to gpu2d's fill_last (its cache's last beat)
`define BP_V dut.ds.u_vram
    bit bk_on; initial bk_on = $test$plusargs("blkpath");
    longint bk_cyc = 0, bk_treq = 0;
    bit bk_rq = 0;
    typedef struct { longint req, ack, iss, first, last, out; bit tex; integer words, pairs; } bk_t;
    bk_t bk_q [$];
    integer bk_wi = 0, bk_oi = 0, bk_ii = 0;
    longint bk_sum [2][6], bk_n [2];
    initial begin foreach (bk_sum[i, j]) bk_sum[i][j] = 0; bk_n[0] = 0; bk_n[1] = 0; end
    longint bk_fl [$];
    always @(posedge dut.clk_sys) if (bk_on && !dut.rst_sys) begin
        bk_cyc++;
        if (`BP_V.g_req && !bk_rq) begin bk_rq = 1; bk_treq = bk_cyc; end
        if (`BP_V.g_ack) begin
            bk_t b; b.req = bk_treq; b.ack = bk_cyc; b.iss = 0; b.first = 0; b.last = 0; b.out = 0; b.words = 0; b.pairs = 0;
            b.tex = `BP_V.g_blk[17:15] == 3'd5 || `BP_V.g_blk[17:15] == 3'd6;
            bk_q.push_back(b); bk_rq = 0;
        end
        // the block request goes to the port in S_GBLK
        if (`BP_V.st == 4'd1 && `BP_V.vm_ack) begin
            for (int k = 0; k < bk_q.size(); k++) if (bk_q[k].iss == 0) begin bk_q[k].iss = bk_cyc; break; end
        end
        if (`BP_V.vm_rvalid && `BP_V.bw_left != 0 && `BP_V.pf_left == 0) begin
            for (int k = 0; k < bk_q.size(); k++) if (bk_q[k].words < 8) begin
                if (bk_q[k].words == 0) bk_q[k].first = bk_cyc;
                bk_q[k].words++; if (bk_q[k].words == 8) bk_q[k].last = bk_cyc;
                break;
            end
        end
        if (`BP_V.g_rvalid) begin
            for (int k = 0; k < bk_q.size(); k++) if (bk_q[k].pairs < 4) begin
                bk_q[k].pairs++;
                if (bk_q[k].pairs == 4) begin
                    bk_t b; integer t;
                    b = bk_q[k]; b.out = bk_cyc; t = b.tex ? 1 : 0;
                    if (b.iss != 0 && b.first != 0) begin
                        bk_n[t]++;
                        bk_sum[t][0] += b.ack - b.req; bk_sum[t][1] += b.iss - b.ack; bk_sum[t][2] += b.first - b.iss;
                        bk_sum[t][3] += b.last - b.first; bk_sum[t][4] += b.out - b.last;
                        if (!b.tex) bk_fl.push_back(b.out);
                    end
                    bk_q.delete(k);
                end
                break;
            end
        end
        if (dut.ds.u_disp.u_gpu2d.flast && bk_fl.size() != 0) begin bk_sum[0][5] += bk_cyc - bk_fl[0]; void'(bk_fl.pop_front()); end
    end
    final if (bk_on) for (int t = 0; t < 2; t++) if (bk_n[t] != 0)
        $display("blkpath %s: %0d blocks, clk_sys: q %.1f i %.1f r %.1f s %.1f o %.1f%s; request to last pair %.1f",
            t ? "3D texel" : "2D", bk_n[t], real'(bk_sum[t][0]) / bk_n[t], real'(bk_sum[t][1]) / bk_n[t],
            real'(bk_sum[t][2]) / bk_n[t], real'(bk_sum[t][3]) / bk_n[t], real'(bk_sum[t][4]) / bk_n[t],
            t ? "" : $sformatf(" f %.1f", real'(bk_sum[0][5]) / bk_n[0]),
            real'(bk_sum[t][0] + bk_sum[t][1] + bk_sum[t][2] + bk_sum[t][3] + bk_sum[t][4]) / bk_n[t]);
// +blkpath, the BG texel miss at the 2D engine (clk_sys): an episode is u_bg's fill_req[1] high (the pipeline
// stalled on that block); split: until gpu2d asks nds_vram for the block (vr_req for the same block, or 0 if it
// was asked for already: a prefetch or an earlier miss of it in flight), from then until the miss clears
`define BK_G dut.ds.u_disp.u_gpu2d
    bit bk_mv = 0; longint bk_m0 = 0, bk_mreq = 0; logic [17:0] bk_mb;
    longint bk_mn = 0, bk_mlen = 0, bk_mpre = 0, bk_mown = 0, bk_mown_n = 0;
    always @(posedge dut.clk_sys) if (bk_on && !dut.rst_sys) begin
        if (`BK_G.u_bg.fill_req[1] && !bk_mv) begin bk_mv = 1; bk_m0 = bk_cyc; bk_mb = `BK_G.u_bg.fill_blk[1]; bk_mreq = 0; end
        if (bk_mv && bk_mreq == 0 && `BK_G.vr_req && `BK_G.vr_blk == bk_mb) bk_mreq = bk_cyc;
        if (bk_mv && !`BK_G.u_bg.fill_req[1]) begin
            bk_mv = 0; bk_mn++; bk_mlen += bk_cyc - bk_m0;
            if (bk_mreq != 0) begin bk_mown_n++; bk_mpre += bk_mreq - bk_m0; bk_mown += bk_cyc - bk_mreq; end
        end
    end
    final if (bk_on && bk_mn != 0)
        $display("blkpath BG texel miss: %0d episodes, %.1f clk_sys each; %0d asked for in the episode: %.1f until gpu2d asks nds_vram, %.1f from then",
            bk_mn, real'(bk_mlen) / bk_mn, bk_mown_n, bk_mown_n ? real'(bk_mpre) / bk_mown_n : 0.0, bk_mown_n ? real'(bk_mown) / bk_mown_n : 0.0);
// +blkpath: the BG side's stall clocks split: a fill outstanding (fill_req[2:0]), the prefetch queue full (pf_bp),
// capture not ready (S6's capture write waiting for cap_ready), all
    longint bk_s_fill = 0, bk_s_pf = 0, bk_s_cap = 0, bk_s_all = 0;
    always @(posedge dut.clk_sys) if (bk_on && !dut.rst_sys && `BK_G.u_bg.stall) begin
        bk_s_all++;
        if (|`BK_G.u_bg.fill_req[2:0]) bk_s_fill++;
        else if (`BK_G.u_bg.pf_bp) bk_s_pf++;
        else bk_s_cap++;
    end
    final if (bk_on && bk_s_all != 0)
        $display("blkpath BG stall clocks: %0d, fill %0d (%.1f %%), prefetch queue full %0d, capture not ready %0d (%.1f %%)",
            bk_s_all, bk_s_fill, 100.0 * bk_s_fill / bk_s_all, bk_s_pf, bk_s_cap, 100.0 * bk_s_cap / bk_s_all);
// +blkpath: the capture-not-ready clocks split by what holds nds_vram's capture word (cap_v): the word leaves
// this clock (cw_ack: the one-word buffer's bubble), the write FIFO full, a ring block writing (rg_k), a ring
// block waiting to start (rg_wreq), the bottom screen's write (vw_req); or an even halfword waiting (cap_p)
`define BK_V dut.ds.u_vram
    longint bk_c_ack = 0, bk_c_full = 0, bk_c_rgk = 0, bk_c_rgw = 0, bk_c_vw = 0, bk_c_p = 0, bk_c_o = 0;
    always @(posedge dut.clk_sys) if (bk_on && !dut.rst_sys && `BK_G.u_bg.stall && !(|`BK_G.u_bg.fill_req[2:0]) && !`BK_G.u_bg.pf_bp) begin
        if (`BK_V.cap_v) begin
            if (dut.cw_ack) bk_c_ack++;
            else if (dut.bw_full) bk_c_full++;
            else if (dut.rg_k != 0) bk_c_rgk++;
            else if (dut.rg_wreq) bk_c_rgw++;
            else if (dut.vw_req) bk_c_vw++;
            else bk_c_o++;
        end else bk_c_p++;
    end
    final if (bk_on && bk_s_cap != 0)
        $display("blkpath capture wait: word leaving %0d, FIFO full %0d, ring block writing %0d, ring block waiting %0d, bottom screen %0d, other %0d, even half held %0d",
            bk_c_ack, bk_c_full, bk_c_rgk, bk_c_rgw, bk_c_vw, bk_c_o, bk_c_p);
