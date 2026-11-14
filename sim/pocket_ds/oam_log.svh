// +oamlog: engine B's OAM writes (po_waddr 256..511) per video frame: count, the VCOUNT of the first and last,
// how many came while the display was in lines 0..191, and how many while a DMA channel ran; +oamlog=2 also
// prints each write (frame, VCOUNT, word, data, dma)
    int oam_lv = 0;
    initial if ($test$plusargs("oamlog")) begin oam_lv = 1; void'($value$plusargs("oamlog=%d", oam_lv)); end
    int ol_n = 0, ol_vis = 0, ol_dma = 0, ol_first = -1, ol_last = -1, ol_frame = -1, ol_na = 0;
    int ol_en_v [8]; logic [7:0] ol_en_q = 0; bit ol_dshown = 0;
    logic [31:0] ol_pc9 = 0;                   // the ARM9's last retired PC
    always @(posedge dut.clk_sys) if (dut.dbg_retire && !dut.dbg_tid) ol_pc9 <= dut.dbg_pc;
    // engine B BG VRAM writes (0x0620xxxx: the CPU port's c_addr[23:21] == 1), acked, per frame
    int bw_n = 0, bw_vis = 0, bw_dma = 0, bw_first = -1, bw_last = -1;
    initial foreach (ol_en_v[i]) ol_en_v[i] = -1;
    always @(posedge dut.clk_sys) if (oam_lv != 0) begin
        for (int i = 0; i < 8; i++) if (dut.ds.u_sys.u_dma.en[i] && !ol_en_q[i]) begin
            ol_en_v[i] = dut.ds.vcount;
            if (oam_lv > 1 && i < 4) $display("dmaen f%0d v%0d: channel %0d mode %0d, ARM9 pc %h", v_frames, dut.ds.vcount, i, dut.ds.u_sys.u_dma.mode[i], ol_pc9);
        end
        if (dut.ds.vc_req && dut.ds.vc_we && dut.ds.vc_ack && !dut.ds.vc_cpu && dut.ds.vc_addr[23:21] == 3'd1) begin
            bw_n++; if (bw_first < 0) bw_first = dut.ds.vcount; bw_last = dut.ds.vcount;
            if (dut.ds.vcount < 192) bw_vis++;
            if (dut.ds.vc_dma) bw_dma++;
        end
        ol_en_q = dut.ds.u_sys.u_dma.en;
        if (dut.ds.oam_we && dut.ds.po_waddr[8] && dut.ds.u_sys.u_dma.m_req && !ol_dshown) begin
            ol_dshown = 1;
            $display("oamdma f%0d v%0d: channel %0d mode %0d (enabled at VCOUNT %0d), source %h", v_frames, dut.ds.vcount,
                     dut.ds.u_sys.u_dma.ek, dut.ds.u_sys.u_dma.mode[dut.ds.u_sys.u_dma.ek], ol_en_v[dut.ds.u_sys.u_dma.ek], dut.ds.u_sys.u_dma.e_src);
        end
        if (v_frames != ol_frame) begin
            if (ol_frame >= 0)
                $display("oamlog frame %0d: B %0d writes (VCOUNT %0d..%0d, %0d in lines 0-191, %0d by DMA); A %0d writes",
                         ol_frame, ol_n, ol_first, ol_last, ol_vis, ol_dma, ol_na);
            if (ol_frame >= 0)
                $display("bgblog frame %0d: B BG VRAM writes %0d (VCOUNT %0d..%0d, %0d in lines 0-191, %0d by DMA)", ol_frame, bw_n, bw_first, bw_last, bw_vis, bw_dma);
            bw_n = 0; bw_vis = 0; bw_dma = 0; bw_first = -1; bw_last = -1;
            ol_frame = v_frames; ol_dshown = 0; ol_n = 0; ol_vis = 0; ol_dma = 0; ol_first = -1; ol_last = -1; ol_na = 0;
        end
        if (dut.ds.oam_we) begin
            if (dut.ds.po_waddr[8]) begin
                ol_n++;
                if (ol_first < 0) ol_first = dut.ds.vcount;
                ol_last = dut.ds.vcount;
                if (dut.ds.vcount < 192) ol_vis++;
                if (dut.ds.u_sys.u_dma.m_req) ol_dma++;
                if (oam_lv > 1) $display("oamw f%0d v%0d w%03x %08x be%b %s", v_frames, dut.ds.vcount, dut.ds.po_waddr[7:0], dut.ds.po_wdata, dut.ds.po_be, dut.ds.u_sys.u_dma.m_req ? "dma" : "cpu");
            end else ol_na++;
        end
    end
