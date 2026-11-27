// S2c (simulation only, +define+G2D_WHY, +g2dwhy=FILE): pace and late 2D line jobs.
//   SWAP,<clk_sys cycle>,<n>          each 3D swap (nds_gpu3d so_done; NODEBUG hides tb's g3swaps)
//   DSF,<cycle>                       each DS frame start (vcount 0)
//   G2DJ,<cycle at end>,line,late,start,dur,overrun,stall,cap,cpu,dma,cap_bus,tex,own_a,video,wchain,ringw,ringr,rom,own_d
// One G2DJ per line job (nds_disp Q_RUN until both engines are idle) that a late HBlank found
// running (stat_late while it ran), and per job its BG/OBJ stall clocks (gpu2d stat_*_stall) by
// what held the 2D engine's block:
//   not yet accepted (d_req && !d_ack): nds_vram's state: CPU / DMA access (cpu, dma), capture
//     (cap_bus), a 3D texel/palette block in service or in flight ahead (tex), the 2D's own earlier
//     blocks in flight (own_a);
//   accepted, waiting for its words: the SDRAM controller's granted port: 0 video (video), 1 the
//     write chain (ringw while the ring writes, else wchain), 2 a texel block ahead of it (tex) or
//     its own (own_d), 3-5 ROM cache/BIOS/save (rom), 6 ring reads (ringr); nothing granted: own_d.
// overrun = the job's end minus the HBlank that found it busy (clocks the job lacked);
// cap = the line's capture write clocks (cap_we) during the job.
`define GW_D dut.ds.u_disp
`define GW_V dut.ds.u_vram
`define GW_3 dut.ds.g_3d
    integer gw_fd = 0;
    longint gw_cyc = 0, gw_sw = 0;
    initial begin
        string fn;
        if ($value$plusargs("g2dwhy=%s", fn)) gw_fd = $fopen(fn, "w");
    end
    bit     gw_on = 0, gw_late = 0, gw_so = 0;
    bit     gw_all; initial gw_all = $test$plusargs("g2dall");   // +g2dall: every line job (late 0 too) and HB,<cycle>,<vcount> at each line start
    longint gw_st = 0, gw_lt = 0;
    integer gw_line = 0;
    longint gw_b [16];
    bit gw_of = 0, gw_ocl = 0;
    always @(posedge dut.clk_sys) if (gw_fd != 0) begin
        gw_cyc++;
        if (`GW_3.u_gpu3d.so_done && !gw_so) begin gw_sw++; $fdisplay(gw_fd, "SWAP,%0d,%0d", gw_cyc, gw_sw); end
        gw_so = `GW_3.u_gpu3d.so_done;
        if (dut.ds.line_start && dut.ds.vcount == 9'd0) $fdisplay(gw_fd, "DSF,%0d", gw_cyc);
        if (gw_all && dut.ds.line_start) $fdisplay(gw_fd, "HB,%0d,%0d", gw_cyc, dut.ds.vcount);
        // a job starts as the sequencer enters Q_RUN
        if (`GW_D.q == 3'd4 && !gw_on) begin
            gw_on = 1; gw_late = 0; gw_st = gw_cyc; gw_line = int'(`GW_D.q_line);
            foreach (gw_b[i]) gw_b[i] = 0;
            gw_ocl = 0;
        end
        if (gw_on) begin
            if (`GW_D.stat_late && !gw_late) begin gw_late = 1; gw_lt = gw_cyc; end
            if (`GW_D.cap_we) gw_b[1]++;
            if (`GW_D.u_gpu2d.u_obj.fill_req[0] && !gw_of) gw_b[15]++;   // OBJ texel fill episodes
            gw_of = `GW_D.u_gpu2d.u_obj.fill_req[0];
            if (`GW_D.u_gpu2d.u_obj.cclear) gw_ocl = 1;
            if (`GW_D.obj_busy && !`GW_D.bg_busy) gw_b[13]++;   // OBJ side still busy after BG's part
            if (`GW_D.bg_busy && !`GW_D.obj_busy) gw_b[14]++;   // BG side still busy after OBJ's part
            if (`GW_D.g_bg_stall || `GW_D.g_obj_stall) begin
                int k;
                gw_b[0]++;
                if (`GW_3.u_arb.a_req && !`GW_3.u_arb.a_ack) begin
                    case (`GW_V.st)
                        4'd4, 4'd5, 4'd7, 4'd9, 4'd10, 4'd8, 4'd11:
                            k = `GW_V.rd_dma ? 3 : 2;
                        4'd12: k = 3;
                        4'd3: k = 4;
                        4'd1, 4'd6, 4'd2: k = `GW_V.g_tex ? 5 : 6;
                        default: k = (`GW_3.u_arb.rp != `GW_3.u_arb.wp && `GW_3.u_arb.head) ? 5 : 6;
                    endcase
                end else if (dut.sdram.g_v) begin
                    case (int'(dut.sdram.g))
                        0: k = 7;
                        1: k = `GW_3.u_gpu3d.rg_wreq ? 9 : 8;
                        2: k = (`GW_3.u_arb.rp != `GW_3.u_arb.wp && `GW_3.u_arb.head) ? 5 : 12;
                        6: k = 10;
                        default: k = 11;
                    endcase
                end else k = 12;
                gw_b[k]++;
            end
            if (`GW_D.q != 3'd4 && !`GW_D.bg_busy && !`GW_D.obj_busy && !`GW_D.bg_start && !`GW_D.obj_start) begin
                gw_on = 0;
                if (gw_late || gw_all)
                    $fdisplay(gw_fd, "G2DJ,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                        gw_cyc, gw_line, gw_late, gw_st, gw_cyc - gw_st, gw_cyc - gw_lt, gw_b[0], gw_b[1],
                        gw_b[2], gw_b[3], gw_b[4], gw_b[5], gw_b[6], gw_b[7], gw_b[8], gw_b[9], gw_b[10], gw_b[11], gw_b[12], gw_b[13], gw_b[14], gw_b[15], gw_ocl);
            end
        end
    end
// +g2dwhy: the CPU/DMA VRAM writes by view (the 2D caches start over at the next job after any: vram_wr)
`define GW_T dut.ds
    longint gw_vw [8];
    always @(posedge dut.clk_sys) if (gw_fd != 0 && `GW_T.vc_req && `GW_T.vc_we && `GW_T.vc_ack)
        gw_vw[`GW_T.vc_cpu ? 3'd7 : `GW_T.vc_addr[23] ? 3'd6 : {1'b0, `GW_T.vc_addr[22:21]}]++;
    final if (gw_fd != 0) $display("g2dwhy VRAM writes: A BG %0d, B BG %0d, A OBJ %0d, B OBJ %0d, LCDC %0d, ARM7 %0d",
        gw_vw[0], gw_vw[1], gw_vw[2], gw_vw[3], gw_vw[6], gw_vw[7]);
// +g2dwhy: the OBJ side's cache restarts (cclear), written ranges too big to sweep (w_big), sweep clocks (w_on)
    longint gw_occ = 0, gw_obig = 0, gw_osw = 0, gw_bcc = 0, gw_bsw = 0;
    always @(posedge dut.clk_sys) if (gw_fd != 0) begin
        if (`GW_D.u_gpu2d.u_obj.cclear) gw_occ++;
        if (`GW_D.u_gpu2d.u_obj.w_big) gw_obig++;
        if (`GW_D.u_gpu2d.u_obj.w_on) gw_osw++;
        if (`GW_D.u_gpu2d.u_bg.cclear) gw_bcc++;
        if (`GW_D.u_gpu2d.u_bg.w_on) gw_bsw++;
    end
    final if (gw_fd != 0) $display("g2dwhy cache restarts: OBJ %0d (written range too big %0d, sweep clocks %0d), BG %0d (sweep clocks %0d)",
        gw_occ, gw_obig, gw_osw, gw_bcc, gw_bsw);
// +g2dwhy: each OBJ job (gpu2d_obj start -> idle): G2DO,end,line,eng,clocks,OBJs drawn,affine,sum of bound widths,
// draw clocks (p0_v),texel fill episodes,stall clocks,work limit on,work left at the end
`define GW_O dut.ds.u_disp.u_gpu2d.u_obj
    bit gw_oon = 0, gw_ofp = 0; longint gw_o0, gw_on_, gw_oa, gw_obw, gw_opx, gw_ofl, gw_ost; int gw_oln, gw_oen;
    always @(posedge dut.clk_sys) if (gw_fd != 0) begin
        if (!gw_oon && `GW_O.os != 0) begin
            gw_oon = 1; gw_o0 = gw_cyc; gw_on_ = 0; gw_oa = 0; gw_obw = 0; gw_opx = 0; gw_ofl = 0; gw_ost = 0;
            gw_oln = int'(`GW_O.line); gw_oen = int'(`GW_O.j_eng);
        end
        if (gw_oon) begin
            if (`GW_O.os == 8 && `GW_O.e_on && !`GW_O.e_skip && !(`GW_O.work_limit && `GW_O.work_left == 0)) begin
                gw_on_++; if (`GW_O.e_type[0]) gw_oa++; gw_obw += `GW_O.e_bw;
            end
            if (`GW_O.p0_v && !`GW_O.stall) gw_opx++;
            if (`GW_O.stall) gw_ost++;
            if (`GW_O.fill_req[0] && !gw_ofp) gw_ofl++;
            gw_ofp = `GW_O.fill_req[0];
            if (`GW_O.os == 0) begin
                gw_oon = 0;
                $fdisplay(gw_fd, "G2DO,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d", gw_cyc, gw_oln, gw_oen, gw_cyc - gw_o0,
                    gw_on_, gw_oa, gw_obw, gw_opx, gw_ofl, gw_ost, `GW_O.work_limit, `GW_O.work_left);
            end
        end
    end
// +g2dwr=FIRST: from DS frame FIRST for 3 frames, W,<frame>,<vcount>,<view>,<blk> per CPU/DMA write through a
// BG/OBJ view (vc_addr[22:5], view = vc_addr[22:21]) and F,<frame>,<vcount>,<eng>,<cache>,<blk> per BG block fill
    integer gw_wr0 = -1, gw_dsf = 0;
    initial if (!$value$plusargs("g2dwr=%d", gw_wr0)) gw_wr0 = -1;
    always @(posedge dut.clk_sys) if (gw_fd != 0 && gw_wr0 >= 0) begin
        if (dut.ds.line_start && dut.ds.vcount == 9'd0) gw_dsf++;
        if (gw_dsf >= gw_wr0 && gw_dsf < gw_wr0 + 3) begin
            if (`GW_T.vc_req && `GW_T.vc_we && `GW_T.vc_ack && !`GW_T.vc_cpu && !`GW_T.vc_addr[23])
                $fdisplay(gw_fd, "W,%0d,%0d,%0d,%0d", gw_dsf, dut.ds.vcount, `GW_T.vc_addr[22:21], `GW_T.vc_addr[22:5]);
            if ((|`GW_D.u_gpu2d.u_bg.fill_we[2:0]) && `GW_D.u_gpu2d.u_bg.fill_first)
                $fdisplay(gw_fd, "F,%0d,%0d,%0d,%0d,%0d", gw_dsf, dut.ds.vcount, `GW_D.u_gpu2d.ld_eng,
                    `GW_D.u_gpu2d.u_bg.fill_we[0] ? 0 : `GW_D.u_gpu2d.u_bg.fill_we[1] ? 1 : 2, `GW_D.u_gpu2d.u_bg.fill_fblk);
        end
    end
