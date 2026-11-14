// Passive source binding for core_top's shared SYS-to-MEM write FIFO.
// Pops are the existing retirement ticket edge, on the low SDRAM halfword.
    integer fs_fd = 0;
    string fs_path;
    bit fs_enable = 0;
    initial if ($value$plusargs("fifo_service=%s", fs_path)) begin
        fs_enable = 1;
        fs_fd = $fopen(fs_path, "w");
        if (!fs_fd) $fatal(1, "FIFO_SERVICE_OPEN");
        if (!dut.G3D_RDEADLINE || !dut.VR_PH || !dut.CAP_CHAIN || !dut.SOUND)
            $fatal(1, "FIFO_SERVICE_PROFILE");
        $fwrite(fs_fd, "frame,line,sys,fill_peak,native_peak,full_sys,d_wait,d_full,d_inflight,d_ack,d_done,d_late,ring_wait,ring_full,ring_read_ack,ring_read_words,cap_wait,cap_pair_full,cap_pair_other,cap_lone_native,cap_lone_admit,cap_other,cap_halves,quanta,words_peak,post_video,post_ring,post_capture,post_cpu,pop_video,pop_ring,pop_capture,pop_cpu,tail_video,tail_ring,tail_capture,tail_cpu");
        $fdisplay(fs_fd, ",reserve_offer,reserve_ring_start,reserve_urgent_2d,reserve_full_pair,full_mix_video,full_mix_ring,full_mix_capture,full_mix_cpu");
    end

    int fs_sys = 0, fs_write = 0, fs_pop = 0;
    logic [57:0] fs_word [128];
    int fs_owner [128];
    // Producer order: video, ring, capture pair, CPU write.
    int fs_accepted [4], fs_retired [4], fs_last_a [4], fs_last_r [4];
    int fs_2d_accepted = 0, fs_2d_complete = 0, fs_2d_beat = 0;
    int fs_fill_peak = 0, fs_native_peak = 0, fs_full = 0;
    int fs_d_wait = 0, fs_d_full = 0, fs_d_active = 0, fs_d_ack = 0, fs_d_done = 0, fs_d_late = 0;
    int fs_ring_wait = 0, fs_ring_full = 0, fs_ring_read = 0, fs_ring_words = 0;
    int fs_cap_wait = 0, fs_cap_full = 0, fs_cap_pair = 0, fs_cap_native = 0, fs_cap_admit = 0;
    int fs_cap_other = 0, fs_cap_halves = 0;
    int fs_quanta = 0, fs_quanta_at = 0, fs_quantum_start = 0, fs_peak_words = 0;
    int fs_frame = 0, fs_line = 0;
    bit fs_first_line = 1;
    int fs_reserve_offer = 0, fs_reserve_start = 0, fs_reserve_urgent = 0;
    int fs_reserve_full_pair = 0;
    bit fs_reserve_pending = 0;
    int fs_full_mix [4];
    wire fs_ring_group = dut.g_post_deadline.post_arb.active &&
                         dut.g_post_deadline.post_arb.owner == 1;

    always @(posedge dut.clk_mem) if (fs_enable && !dut.rst_mem) begin
        if (dut.sdram.mc.bw_start) fs_quantum_start = fs_pop;
        if (dut.bw_read) begin
            if (!dut.bw_valid || fs_pop >= fs_write ||
                {dut.bw_he, dut.bw_q[55:0]} !== fs_word[fs_pop % 128])
                $fatal(1, "FIFO_SERVICE_POP_OWNER_OR_DATA id=%0d", fs_pop);
            fs_retired[fs_owner[fs_pop % 128]]++;
            fs_pop++;
        end
        if (dut.sdram.mc.bw_done) begin
            if (fs_pop <= fs_quantum_start || fs_pop - fs_quantum_start > 8)
                $fatal(1, "FIFO_SERVICE_QUANTUM start=%0d stop=%0d", fs_quantum_start, fs_pop);
            if (fs_pop - fs_quantum_start > fs_peak_words) fs_peak_words = fs_pop - fs_quantum_start;
            fs_quanta++;
        end
    end

    always @(posedge dut.clk_sys) if (fs_enable) begin
        fs_sys++;
        if (!dut.rst_sys) begin
            int observed_tail;
            observed_tail = fs_write - fs_pop;
            if (observed_tail < 0 || observed_tail > 65 ||
                dut.bw_fill !== 7'(fs_write - int'(dut.bw_pcnt)))
                $fatal(1, "FIFO_SERVICE_OCCUPANCY tail=%0d fill=%0d", observed_tail, dut.bw_fill);
            if (dut.vw_ack || dut.rg_wack || dut.cw_ack) begin
                logic [57:0] descriptor;
                int owner;
                if (dut.bw_full || $countones({dut.vw_ack, dut.rg_wack, dut.cw_ack}) != 1)
                    $fatal(1, "FIFO_SERVICE_POST_OWNER");
                if (dut.vw_ack) begin
                    owner = 0;
                    descriptor = {2'b11, dut.vw_addr, dut.vw_data};
                end else if (dut.rg_wack) begin
                    owner = 1;
                    descriptor = {2'b11, dut.rg_waddr, dut.rg_wdata};
                end else begin
                    owner = dut.ds.u_vram.cw_pair ? 2 : 3;
                    descriptor = {dut.cw_he, dut.cw_addr, dut.cw_data};
                end
                fs_word[fs_write % 128] = descriptor;
                fs_owner[fs_write % 128] = owner;
                fs_accepted[owner]++;
                fs_write++;
            end
            if (dut.ds.d_rvalid) begin
                if (fs_2d_complete >= fs_2d_accepted)
                    $fatal(1, "FIFO_SERVICE_UNOWNED_2D");
                fs_2d_beat++;
                if (fs_2d_beat == 4) begin
                    fs_2d_beat = 0;
                    fs_2d_complete++;
                    fs_d_done++;
                end
            end
            if (dut.ds.d_ack) begin
                fs_2d_accepted++;
                fs_d_ack++;
            end
            if (dut.ds.u_disp.line_start && ro_started) begin
                if (!fs_first_line) begin
                    $fwrite(fs_fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                        fs_frame, fs_line, fs_sys, fs_fill_peak, fs_native_peak, fs_full,
                        fs_d_wait, fs_d_full, fs_d_active, fs_d_ack, fs_d_done, fs_d_late,
                        fs_ring_wait, fs_ring_full, fs_ring_read, fs_ring_words);
                    $fwrite(fs_fd, ",%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                        fs_cap_wait, fs_cap_full, fs_cap_pair, fs_cap_native, fs_cap_admit, fs_cap_other,
                        fs_cap_halves, fs_quanta - fs_quanta_at, fs_peak_words);
                    foreach (fs_last_a[i]) $fwrite(fs_fd, ",%0d", fs_accepted[i] - fs_last_a[i]);
                    foreach (fs_last_r[i]) $fwrite(fs_fd, ",%0d", fs_retired[i] - fs_last_r[i]);
                    foreach (fs_last_a[i]) $fwrite(fs_fd, ",%0d", fs_accepted[i] - fs_retired[i]);
                    $fwrite(fs_fd, ",%0d,%0d,%0d,%0d", fs_reserve_offer, fs_reserve_start,
                            fs_reserve_urgent, fs_reserve_full_pair);
                    foreach (fs_full_mix[i]) $fwrite(fs_fd, ",%0d", fs_full_mix[i]);
                    $fwrite(fs_fd, "\n");
                end
                fs_first_line = 0;
                fs_frame = v_frames;
                fs_line = int'(dut.vcount);
                fs_fill_peak = 0; fs_native_peak = 0; fs_full = 0;
                fs_d_wait = 0; fs_d_full = 0; fs_d_active = 0; fs_d_ack = 0; fs_d_done = 0; fs_d_late = 0;
                fs_ring_wait = 0; fs_ring_full = 0; fs_ring_read = 0; fs_ring_words = 0;
                fs_cap_wait = 0; fs_cap_full = 0; fs_cap_pair = 0; fs_cap_native = 0; fs_cap_admit = 0;
                fs_cap_other = 0; fs_cap_halves = 0;
                fs_quanta_at = fs_quanta;
                fs_peak_words = 0;
                fs_reserve_offer = 0; fs_reserve_start = 0; fs_reserve_urgent = 0;
                fs_reserve_full_pair = 0;
                foreach (fs_full_mix[i]) fs_full_mix[i] = 0;
                foreach (fs_last_a[i]) fs_last_a[i] = fs_accepted[i];
                foreach (fs_last_r[i]) fs_last_r[i] = fs_retired[i];
            end
            if (int'(dut.bw_fill) > fs_fill_peak) fs_fill_peak = int'(dut.bw_fill);
            if (observed_tail > fs_native_peak) fs_native_peak = observed_tail;
            if (dut.bw_full) fs_full++;
            if (dut.ds.d_req && !dut.ds.d_ack) begin
                fs_d_wait++;
                if (dut.bw_full) fs_d_full++;
            end
            if (fs_2d_accepted != fs_2d_complete) fs_d_active++;
            if (dut.ds.u_disp.stat_late) fs_d_late++;
            if (dut.rg_wreq && !dut.rg_wack) begin
                fs_ring_wait++;
                if (dut.bw_full) fs_ring_full++;
            end
            if (dut.rg_rreq && dut.rg_rack) fs_ring_read++;
            if (dut.rg_rvalid) fs_ring_words++;
            // Count actual ring starts that could have used a slot reserved
            // for a capture half already assembled. Sample pre-edge gates.
            if (fs_reserve_pending && !dut.ds.u_vram.cap_p) begin
                fs_reserve_pending = 0;
                if (dut.ds.u_vram.cw_pair && dut.bw_full) fs_reserve_full_pair++;
            end
            if (dut.ds.u_vram.cap_p && dut.bw_fill[6] && !dut.bw_full &&
                dut.rg_wreq && !fs_ring_group) begin
                fs_reserve_offer++;
                if (dut.rg_wack) begin
                    fs_reserve_start++;
                    fs_reserve_pending = 1;
                    if (dut.ds.hurry2d) fs_reserve_urgent++;
                end
            end
            if (dut.ds.cap_we && dut.ds.cap_ready) fs_cap_halves++;
            if (dut.ds.cap_we && !dut.ds.cap_ready) begin
                fs_cap_wait++;
                if (dut.ds.u_vram.cap_v && dut.ds.u_vram.cap_w) begin
                    if (dut.bw_full) begin
                        fs_cap_full++;
                        foreach (fs_full_mix[i]) fs_full_mix[i] += fs_accepted[i] - fs_retired[i];
                    end
                    else fs_cap_pair++;
                end else if (dut.ds.u_vram.cap_v) begin
                    if (dut.ds.u_vram.st == dut.ds.u_vram.S_CAP) fs_cap_native++;
                    else fs_cap_admit++;
                end else fs_cap_other++;
            end
        end
    end
    final if (fs_enable) begin
        $display("FIFO_SERVICE_SUMMARY posts=%0d pops=%0d d_ack=%0d d_done=%0d d_tail_beats=%0d quanta=%0d",
                 fs_write, fs_pop, fs_2d_accepted, fs_2d_complete, fs_2d_beat, fs_quanta);
        $fclose(fs_fd);
    end
