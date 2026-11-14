// +dmapath: one DMA unit's time along its path (clk_sys clocks; DS system cycles = /2), per unit class
// (VRAM read: source in 0x06xxxxxx; VRAM write: destination there; other), summed and printed every 64 frames
// and at the end:
//   gap   the previous unit's ack to this unit's m_req (the DMA engine's own issue time; 0 for a run's first unit,
//         taken as one more than 64 clocks after the last ack)
//   in    m_req to nds_vram's c_req (fabric and the clock crossing in; 0 if the unit never reached VRAM)
//   vram  nds_vram c_req to c_ack (its state machine and the SDRAM port, for the unit's VRAM access)
//   ps    clocks the PSRAM had a request waiting for its ack during the unit (main RAM side)
//   rest  the unit's other clocks (from m_req to m_ack minus in, vram)
    bit dp_on; initial dp_on = $test$plusargs("dmapath");
    longint dp_cyc = 0, dp_last_ack = 0, dp_t0 = 0, dp_vin = 0, dp_vout = 0, dp_ps = 0;
    bit dp_run = 0, dp_vseen = 0, dp_vdone = 0;
    integer dp_cls = 2;
    longint dp_n [3], dp_gap [3], dp_in [3], dp_vr [3], dp_psum [3], dp_rest [3];
    initial for (int i = 0; i < 3; i++) begin dp_n[i] = 0; dp_gap[i] = 0; dp_in[i] = 0; dp_vr[i] = 0; dp_psum[i] = 0; dp_rest[i] = 0; end
    // VRAM-write units, nds_vram phase (c_req seen, no c_ack yet), clocks by cause:
    //  0 wb full, S_IDLE with a 2D request   1 wb full, S_IDLE other   2 wb full, S_WRES (bt_hit)   3 wb full, S_POST no cw_ack
    //  4 wb full, S_GRES/S_GBLK/S_GZERO   5 wb full, other state   6 wb empty (the take clock)   7 other
    longint dw_c [8]; initial foreach (dw_c[i]) dw_c[i] = 0;
    longint dw_cwrej = 0, dw_cwring = 0, dw_cwfull = 0;
    task automatic dp_print(input string tag);
        for (int i = 0; i < 3; i++) if (dp_n[i] != 0)
            $display("dmapath %s %s: %0d units, DS cycles a unit: gap %.2f in %.2f vram %.2f ps %.2f rest %.2f total (ack to ack) %.2f",
                tag, i == 0 ? "VRAM-read" : i == 1 ? "VRAM-write" : "other", dp_n[i],
                real'(dp_gap[i]) / dp_n[i] / 2, real'(dp_in[i]) / dp_n[i] / 2, real'(dp_vr[i]) / dp_n[i] / 2,
                real'(dp_psum[i]) / dp_n[i] / 2, real'(dp_rest[i]) / dp_n[i] / 2,
                real'(dp_gap[i] + dp_in[i] + dp_vr[i] + dp_rest[i]) / dp_n[i] / 2);
        if (dp_n[1] != 0)
            $display("dmapath %s VRAM-write vram split, DS cycles a unit: idle+2D %.2f idle-other %.2f wres %.2f post-noack %.2f 2D-states %.2f other-wbfull %.2f take %.2f other %.2f; post refusals: ring %0d fifo-full %0d other %0d",
                tag, real'(dw_c[0]) / dp_n[1] / 2, real'(dw_c[1]) / dp_n[1] / 2, real'(dw_c[2]) / dp_n[1] / 2, real'(dw_c[3]) / dp_n[1] / 2,
                real'(dw_c[4]) / dp_n[1] / 2, real'(dw_c[5]) / dp_n[1] / 2, real'(dw_c[6]) / dp_n[1] / 2, real'(dw_c[7]) / dp_n[1] / 2,
                dw_cwring, dw_cwfull, dw_cwrej);
    endtask
    always @(posedge dut.clk_sys) if (dp_on && !dut.rst_sys) begin
        dp_cyc++;
        if (dut.ds.u_sys.u_dma.m_req && !dp_run) begin
            dp_run = 1; dp_t0 = dp_cyc; dp_vseen = 0; dp_vdone = 0; dp_ps = 0;
            // (a write request's m_addr is its destination: a 16-bit or I/O-source unit is a read, then a write)
            dp_cls = dut.ds.u_sys.u_dma.m_addr[27:24] == 4'h6 && !dut.ds.u_sys.u_dma.m_we ? 0
                   : (dut.ds.u_sys.u_dma.m_unit ? dut.ds.u_sys.u_dma.m_dst[27:24] : dut.ds.u_sys.u_dma.m_addr[27:24]) == 4'h6
                     && (dut.ds.u_sys.u_dma.m_unit || dut.ds.u_sys.u_dma.m_we) ? 1 : 2;
        end
        if (dp_run) begin
            if (dut.ds.u_vram.c_req && !dp_vseen) begin dp_vseen = 1; dp_vin = dp_cyc; end
            if (dp_vseen && !dp_vdone && dut.ds.u_vram.c_ack) begin dp_vdone = 1; dp_vout = dp_cyc; end
            if (dut.psram.s_req && !dut.psram.s_ack) dp_ps++;
            if (dp_cls == 1 && dp_vseen && !dp_vdone && !dut.ds.u_vram.c_ack) begin
                automatic int st = dut.ds.u_vram.st;
                if (!dut.ds.u_vram.wb_v) dw_c[dut.ds.u_vram.c_req ? 6 : 7]++;
                else if (st == 0) dw_c[dut.ds.u_vram.g_req ? 0 : 1]++;
                else if (st == 11) dw_c[2]++;
                else if (st == 8) begin
                    if (!dut.ds.u_vram.cw_ack) begin
                        dw_c[3]++;
                        if (dut.bw_full) dw_cwfull++; else if (dut.rg_k != 0 || dut.ds_rg_wreq) dw_cwring++; else dw_cwrej++;
                    end else dw_c[5]++;
                end
                else if (st == 1 || st == 2 || st == 6) dw_c[4]++;
                else dw_c[5]++;
            end
            if (dut.ds.u_sys.u_dma.m_ack) begin
                longint tot, inn, vr;
                dp_run = 0;
                tot = dp_cyc - dp_t0 + 1;
                inn = dp_vseen ? dp_vin - dp_t0 : 0;
                vr = dp_vdone ? dp_vout - dp_vin + 1 : 0;
                dp_n[dp_cls]++; dp_gap[dp_cls] += dp_last_ack != 0 && dp_t0 - dp_last_ack < 64 ? dp_t0 - dp_last_ack - 1 : 0;
                dp_in[dp_cls] += inn; dp_vr[dp_cls] += vr; dp_psum[dp_cls] += dp_ps; dp_rest[dp_cls] += tot - inn - vr;
                dp_last_ack = dp_cyc;
            end
        end
    end
    final if (dp_on) dp_print("end");
