// Opt-in testbench instrumentation only. Include inside tb_ds_pocket after
// ram_word(), compile gxd_mailbox_dpi.cpp, and define GXD_MAILBOX. Not wired
// into the canonical CLEAN bench by this source-preparation change.
`ifdef GXD_MAILBOX
    import "DPI-C" function int gxd_open(input string helper, input string cases_path,
                                        input string output_path);
    import "DPI-C" function int gxd_submit(input string packet);
    import "DPI-C" function int gxd_close();
    bit gxd_enabled = 0;
    integer gxd_last_sequence = 0;
    initial if ($test$plusargs("gxd_ack")) begin
        string helper, cases_path, output_path;
        if (!$value$plusargs("gxd_helper=%s", helper) ||
            !$value$plusargs("gxd_cases=%s", cases_path) ||
            !$value$plusargs("gxd_output=%s", output_path))
            $fatal(1, "GXD missing collector paths");
        if (gxd_open(helper, cases_path, output_path) != 1)
            $fatal(1, "GXD collector start failed");
        gxd_enabled = 1;
        $display("GXD_MAILBOX_READY packet023f0100 ACK023f0180 physicalRAM shared-validator");
    end
    always @(negedge dut.clk_mem) begin
        // Both physical RAM chips are inactive: the asynchronous writes
        // have completed, including the last commit word. No port ACK is
        // substituted for physical visibility. The producer is in its
        // export/ACK path, outside the retained timed sampler.
        if (gxd_enabled && !cram0.ce && !cram1.ce &&
            ram_word(32'hfc061) == 32'h47584431) begin
            reg [31:0] packet_sequence;
            packet_sequence = ram_word(32'hfc04f);
            if (packet_sequence != 0 && packet_sequence != gxd_last_sequence) begin
                reg [31:0] words[16];
                string packet;
                integer accepted;
                packet = "[";
                for (int i = 0; i < 16; ++i) begin
                    words[i] = ram_word(32'hfc040 + i);
                    packet = {packet, (i == 0 ? "" : ","), $sformatf("%0d", words[i])};
                end
                packet = {packet, "]"};
                accepted = gxd_submit(packet);
                if (packet_sequence != gxd_last_sequence + 1 || accepted != packet_sequence)
                    $fatal(1, "GXD rejected packet %0d, ACK remains unchanged", packet_sequence);
                // The only testbench write: ACK0 at DS address023f0180,
                // split over the existing low/high physical RAM models.
                cram0.mem[32'hfc060] = packet_sequence[15:0];
                cram1.mem[32'hfc060] = packet_sequence[31:16];
                gxd_last_sequence = packet_sequence;
                if (words[2] == 2 && words[3] == 53) begin
                    if (gxd_close() != 0) $fatal(1, "GXD collector completion failed");
                    gxd_enabled = 0;
                    $display("GXD_COMPLETE windows54 packets%0d", packet_sequence);
                end
            end
        end
    end
    final begin
        if (gxd_enabled) begin
            integer ignored;
            ignored = gxd_close();
        end
    end
`endif
