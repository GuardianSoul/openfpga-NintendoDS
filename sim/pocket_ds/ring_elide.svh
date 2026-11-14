// +ringelide: plan-next R1 part e's ceiling. Ring lines the final pass staged (each written to SDRAM as 32 blocks),
// and of those the ones the display got without the SDRAM round trip: direct (dir held from the line's first
// pixel to its last: its pixels went into the read buffer as drawn) or copied whole from staging (E_COPY done, not
// voided). Printed at the end. Only a line also not read back from SDRAM later could skip its write.
`define RE_R dut.ds.g_3d.u_gpu3d.g_ring.u_ringx
    bit re_on; initial re_on = $test$plusargs("ringelide");
    longint re_lines = 0, re_dir = 0, re_copy = 0, re_rd = 0;
    bit re_d0 = 0, re_cp = 0;
    always @(posedge dut.clk_sys) if (re_on && !dut.rst_sys) begin
        if (`RE_R.px_valid && `RE_R.px_x == 8'd0) begin re_lines++; re_d0 = `RE_R.dir_now; end
        if (`RE_R.px_valid && `RE_R.px_x == 8'd255 && re_d0 && `RE_R.dir_now) re_dir++;
        if (`RE_R.est == 3'd5 && !re_cp) re_cp = 1;
        if (re_cp && `RE_R.est != 3'd5) begin re_cp = 0; if (!`RE_R.cp_ab) re_copy++; end
        if (`RE_R.est == 3'd3 && `RE_R.rg_rack) re_rd++;
    end
    final if (re_on) $display("ringelide: %0d lines staged, %0d direct, %0d copied from staging (%.1f %% without the SDRAM trip); %0d SDRAM read blocks",
        re_lines, re_dir, re_copy, 100.0 * real'(re_dir + re_copy) / (re_lines ? re_lines : 1), re_rd);
