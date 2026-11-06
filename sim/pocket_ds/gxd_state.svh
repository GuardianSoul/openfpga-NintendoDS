// Frozen5e GX_FAST/PU hierarchy only. Passive observation of existing bus
// responses and accepted geometry record beats. Never creates a bus request,
// waits for an engine result, or changes a core signal.
`ifdef GXD_MAILBOX
`define GXD_GEOM dut.ds.g_3d.u_gpu3d.u_geom
`define GXD_ENG `GXD_GEOM.u_eng
    integer gxd_state_fd = 0;
    integer gxd_state_window = -1;
    longint unsigned gxd_state_cycle = 0;
    bit gxd_state_pending = 0;
    integer gxd_state_reads = 0;
    bit gxd_io_pending = 0, gxd_io_write = 0, gxd_io_cpu = 0;
    reg [23:0] gxd_io_address;
    reg [31:0] gxd_io_value;
    reg [3:0] gxd_io_be;
    initial if ($test$plusargs("gxd_ack")) begin
        string path;
        if (!$value$plusargs("gxd_state=%s", path))
            $fatal(1, "GXD requires a first-idle state witness path");
        gxd_state_fd = $fopen(path, "w");
        if (!gxd_state_fd) $fatal(1, "GXD state witness cannot open output");
        $display("GXD_STATE_READY frozen5e first-idle bus response; passive records and RF");
    end

    task automatic gxd_state_idle(input [31:0] status);
        $fwrite(gxd_state_fd,
            "{\"event\":\"idle\",\"window\":%0d,\"cycle\":%0d,\"read_ordinal\":%0d,\"gxstat\":%0d,\"rtl\":{\"rf\":[",
            gxd_state_window, gxd_state_cycle, gxd_state_reads, status);
        // Include the material/normal working words as raw diagnostics too.
        for (int i = 0; i < 384; ++i)
            $fwrite(gxd_state_fd, "%s%0d", i == 0 ? "" : ",", `GXD_ENG.u_rfa.mem[i]);
        $fwrite(gxd_state_fd,
            "],\"current_vertex\":[%0d,%0d,%0d],\"normal_packed\":%0d,\"color\":[%0d,%0d,%0d],\"engine_counts\":[%0d,%0d],\"model_counts\":[%0d,%0d]},",
            `GXD_ENG.at_v[0], `GXD_ENG.at_v[1], `GXD_ENG.at_v[2], `GXD_ENG.lu_nr,
            `GXD_ENG.g_ff.at_c[0], `GXD_ENG.g_ff.at_c[1], `GXD_ENG.g_ff.at_c[2],
            `GXD_GEOM.npoly, `GXD_GEOM.nvert, `GXD_GEOM.model_npoly, `GXD_GEOM.model_nvert);
        $fwrite(gxd_state_fd,
            "\"pending\":{\"engine_idle\":%0d,\"upc\":%0d,\"model_seq\":%0d,\"engine_seq\":%0d,\"entries_more\":%0d,\"entries_available\":%0d,\"lighting_busy\":%0d,\"vertex_finish_busy\":%0d}}\n",
            `GXD_GEOM.dbg_idle, `GXD_ENG.upc, `GXD_GEOM.mrd_model_seq, `GXD_GEOM.mrd_engine_seq,
            `GXD_GEOM.e_more, `GXD_GEOM.e_avail, `GXD_ENG.lu_busy, `GXD_ENG.vf_busy);
        $fflush(gxd_state_fd);
    endtask

    always @(posedge dut.clk_sys) begin
        gxd_state_cycle = gxd_state_cycle + 1;
        // Observe the values consumed on this edge, before RTL NBA updates.
        if (gxd_state_fd && gxd_enabled && !dut.rst_sys) begin
            if (gxd_state_pending && `GXD_GEOM.po_valid && `GXD_GEOM.po_ready)
                $fwrite(gxd_state_fd,
                    "{\"event\":\"po\",\"window\":%0d,\"cycle\":%0d,\"kind\":%0d,\"index\":%0d,\"words\":[%0d,%0d,%0d,%0d]}\n",
                    gxd_state_window, gxd_state_cycle, `GXD_GEOM.po_type, `GXD_GEOM.po_index,
                    `GXD_GEOM.po_data[31:0], `GXD_GEOM.po_data[63:32],
                    `GXD_GEOM.po_data[95:64], `GXD_GEOM.po_data[127:96]);
            if (dut.ds.io_ack && gxd_io_pending) begin
                gxd_io_pending = 0;
                if (!gxd_io_cpu && ram_word(32'hfc061) == 32'h47584431) begin
                    if (gxd_io_write && gxd_io_address == 24'h000540) begin
                        if (gxd_state_pending) $fatal(1, "GXD SWAP before first-idle witness");
                        gxd_state_window = gxd_state_window + 1;
                        if (gxd_state_window >= 54) $fatal(1, "GXD unexpected extra SWAP");
                        gxd_state_pending = 1;
                        gxd_state_reads = 0;
                        $fwrite(gxd_state_fd,
                            "{\"event\":\"swap\",\"window\":%0d,\"cycle\":%0d,\"value\":%0d}\n",
                            gxd_state_window, gxd_state_cycle, gxd_io_value);
                    end else if (gxd_state_pending && gxd_io_write &&
                                 gxd_io_address >= 24'h000440 && gxd_io_address < 24'h0005cc) begin
                        if (gxd_io_be != 4'hf) $fatal(1, "GXD non-word command write");
                        $fwrite(gxd_state_fd,
                            "{\"event\":\"write\",\"window\":%0d,\"cycle\":%0d,\"command\":%0d,\"value\":%0d}\n",
                            gxd_state_window, gxd_state_cycle,
                            (gxd_io_address & 24'h0001fc) >> 2, gxd_io_value);
                    end else if (gxd_state_pending && !gxd_io_write && gxd_io_address == 24'h000600) begin
                        $fwrite(gxd_state_fd,
                            "{\"event\":\"read\",\"window\":%0d,\"cycle\":%0d,\"ordinal\":%0d,\"gxstat\":%0d}\n",
                            gxd_state_window, gxd_state_cycle, gxd_state_reads, dut.ds.io_rdata);
                        if (!dut.ds.io_rdata[27]) begin
                            // Freeze on the first CPU-visible idle response.
                            // Do NOT gate this on dbg_idle/e_more.
                            gxd_state_idle(dut.ds.io_rdata);
                            gxd_state_pending = 0;
                        end
                        gxd_state_reads = gxd_state_reads + 1;
                    end
                end
            end
            if (dut.ds.io_req) begin
                if (gxd_io_pending) $fatal(1, "GXD overlapping observed IO request");
                gxd_io_pending = 1;
                gxd_io_address = {dut.ds.io_addr, 2'b00};
                gxd_io_value = dut.ds.io_wdata;
                gxd_io_be = dut.ds.io_be;
                gxd_io_write = dut.ds.io_we;
                gxd_io_cpu = dut.ds.io_cpu;
            end
        end
    end
    final if (gxd_state_fd) $fclose(gxd_state_fd);
`undef GXD_ENG
`undef GXD_GEOM
`endif
