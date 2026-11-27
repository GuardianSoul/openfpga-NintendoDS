// +g2dcoh (simulation only): the 2D BG caches' coherence with CPU/DMA writes through the BG views. A BG-space block
// ({SP_BG, engine, offset[18:5]}, the view address the caches tag) that a write through engine e's BG view reached
// after the block's last fill and before the current BG job started must not hit in that job: the job's cache
// restart (gpu2d_bg dirty, nds_top G2D_WSPLIT) should have retired it. (A write during the job may hit until the
// next job, as designed.) Prints "g2dcoh: N stale hits" at the end; each of the first 10 as an ERROR.
`define GC_B dut.ds.u_disp.u_gpu2d.u_bg
    bit     gc_on;
    initial gc_on = $test$plusargs("g2dcoh");
    longint gc_cyc = 0, gc_job = 0, gc_n = 0, gc_bad = 0;
    longint gc_w [bit [17:0]];       // last write, by block
    longint gc_f [bit [17:0]];       // last fill (its last beat), by block
    function automatic void gc_chk(input bit [17:0] b, input string c);
        if (b[17:15] != 3'd0) return;          // BG space only
        gc_n++;
        if (gc_w.exists(b) && gc_w[b] < gc_job && (!gc_f.exists(b) || gc_w[b] > gc_f[b])) begin
            gc_bad++;
            if (gc_bad <= 10) $display("[%0t] ERROR: g2dcoh: %s cache hit on block %05x (engine %0d) written at %0d, filled at %0d, job from %0d",
                $time, c, b, b[14], gc_w[b], gc_f.exists(b) ? gc_f[b] : -1, gc_job);
        end
    endfunction
    always @(posedge dut.clk_sys) if (gc_on) begin
        gc_cyc++;
        if (`GW_T.vc_req && `GW_T.vc_we && `GW_T.vc_ack && !`GW_T.vc_cpu && `GW_T.vc_addr[23:22] == 2'd0)
            gc_w[`GW_T.vc_addr[21] ? {4'b0001, 2'b00, `GW_T.vc_addr[16:5]} : {4'b0000, `GW_T.vc_addr[18:5]}] = gc_cyc;
        if (`GC_B.js == `GC_B.J_IDLE && `GC_B.start) gc_job = gc_cyc;
        if ((|`GC_B.fill_we[2:0]) && `GC_B.fill_last) gc_f[`GC_B.fill_fblk] = gc_cyc;
        if (((`GC_B.s1.v && `GC_B.s1_nm) || (`GC_B.s4.v && `GC_B.s4_nm)) && `GC_B.m_hit) gc_chk(`GC_B.m_cur, "map");
        if (((`GC_B.s2.v && `GC_B.s2_nt) || (`GC_B.s4.v && `GC_B.s4_nt)) && `GC_B.t_hit) gc_chk(`GC_B.t_cur, "texel");
    end
    final if (gc_on) $display("g2dcoh: %0d BG-space hits checked, %0d stale hits", gc_n, gc_bad);
