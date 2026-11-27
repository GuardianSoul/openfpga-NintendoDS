// +mkgx (simulation only, MKDS race-start lag on RC15e, 2026-11-21): per video frame, the clocks the GX front's staged
// entries wait for room (gx_stall: the DS FIFO model at 256, the on-chip queue at 511 without the spill, or the spill
// full), the ARM9's bus request waiting while it stalls, an ARM9 DMA running while it stalls, the ARM9 halted, and the
// deepest GX queue (dg_used: written and not yet run by the engine)
`define MKG_F dut.ds.g_3d.u_gpu3d.u_geom.u_front
    bit mkg_on; initial mkg_on = $test$plusargs("mkgx");
    longint mg_st = 0, mg_a9 = 0, mg_dma = 0, mg_halt = 0, mg_clk = 0; int mg_max = 0, mg_sq = 0, mg_sqg = 0;
    always @(posedge dut.clk_sys) if (mkg_on && !dut.rst_sys) begin
        mg_clk++;
        if (`MKG_F.gx_stall) begin
            mg_st++;
            if (dut.ds.b9_req && !dut.ds.b9_ack) mg_a9++;
            if (dut.ds.dma_busy[0]) mg_dma++;
        end
        if (dut.ds.dg_halt[0]) mg_halt++;
        if (int'(`MKG_F.dg_used) > mg_max) mg_max = int'(`MKG_F.dg_used);
`ifdef MKG_SQ
        if (int'(`MKG_F.g_spill.sq) > mg_sq) mg_sq = int'(`MKG_F.g_spill.sq);
`endif
        if (dut.frame_pulse) begin
            $display("mkgx: %0d clk | GX stall %0d (ARM9 waiting %0d, ARM9 DMA %0d) | ARM9 halted %0d | GX queue max %0d | spilled max %0d",
                     mg_clk, mg_st, mg_a9, mg_dma, mg_halt, mg_max, mg_sq);
            if (mg_sq > mg_sqg) mg_sqg = mg_sq; mg_sq = 0;
            mg_clk = 0; mg_st = 0; mg_a9 = 0; mg_dma = 0; mg_halt = 0; mg_max = 0;
        end
    end
    final if (mkg_on) $display("mkgx total: spilled max %0d", mg_sqg);
`undef MKG_F
