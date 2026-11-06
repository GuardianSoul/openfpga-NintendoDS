`timescale 1ns/1ps
// SD probe test (docs/sd-probe.md): the pinned APF command handler
// (core_bridge_cmd, rtl/apf) plus a firmware model with configurable
// latency, driving rtl/probe/sd_probe.sv. An independent monitor times each
// command from the bus and every log record must match it. Data words come
// from a pattern ROM; tools/sd-probe/decode.py re-checks the sums from a file
// with the same pattern (sim/probe/run.py).
//
// Before all-complete the model loads the whole file to bridge 0 (the slot is
// not deferred), as the Pocket does at start-up; the monitor checks the
// probe's load counters.
//
// Plusargs: +lat=N    clocks from the host's "busy" to the first data word
//           +jitter=N extra random clocks (0..N-1) on top of lat
//           +poll=N   idle clocks between the host's status polls
//           +gap=N    random idle clocks (0..N-1) between data words
//           +errat=K  command K (0-based) fails with APF error 3, no data
//           +lgap=N   random idle clocks (0..N-1) between start-up load words
//           +lgapevery=K  only after every K-th load word (default 1)
//           +lstall=N one stall of N clocks in the start-up load, at word 1000
//           +log=FILE the log as the Pocket saves it (one word late)
module tb_sd_probe;
    localparam integer N = 4;
    localparam [31:0] ROM_SIZE = 32'h0010_0600;   // 1 MiB + 3 sectors: rejection sampling, sequential wrap
    localparam [31:0] TIMEOUT = 32'd60000;
    localparam [31:0] WINDOW = 32'h3000_0000;
    localparam [31:0] GAP_LONG = 32'd1000;
    localparam integer NREC = 7*N;
    localparam integer HDR = 32;
    localparam integer LOG_WORDS = HDR + 8*NREC;

    reg clk = 0;
    always #6.734 clk = !clk;
    reg reset = 1;

    reg [31:0] bridge_addr = 0, bridge_data = 0;
    reg bridge_rd = 0, bridge_wr = 0;
    wire [31:0] command_data;
    wire reset_n, allcomplete;
    wire tgt_read, tgt_ack, tgt_done;
    wire [2:0] tgt_err;
    wire [15:0] tgt_id;
    wire [31:0] tgt_offset, tgt_bridge, tgt_length;
    wire [9:0] dt_addr;
    wire dt_wren;
    wire [31:0] dt_data, dt_q;
    core_bridge_cmd commands (
        .clk(clk), .reset_n(reset_n),
        .bridge_endian_little(1'b0), .bridge_addr(bridge_addr), .bridge_rd(bridge_rd),
        .bridge_rd_data(command_data), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_data),
        .status_boot_done(!reset), .status_setup_done(!reset), .status_running(reset_n),
        .dataslot_requestread(), .dataslot_requestread_id(), .dataslot_requestread_ack(1'b1), .dataslot_requestread_ok(1'b1),
        .dataslot_requestwrite(), .dataslot_requestwrite_id(), .dataslot_requestwrite_size(),
        .dataslot_requestwrite_ack(1'b1), .dataslot_requestwrite_ok(1'b1),
        .dataslot_update(), .dataslot_update_id(), .dataslot_update_size(),
        .dataslot_allcomplete(allcomplete),
        .rtc_epoch_seconds(), .rtc_date_bcd(), .rtc_time_bcd(), .rtc_valid(),
        .savestate_supported(1'b0), .savestate_addr(32'b0), .savestate_size(32'b0), .savestate_maxloadsize(32'b0),
        .osnotify_inmenu(),
        .savestate_start(), .savestate_start_ack(1'b0), .savestate_start_busy(1'b0), .savestate_start_ok(1'b0), .savestate_start_err(1'b0),
        .savestate_load(), .savestate_load_ack(1'b0), .savestate_load_busy(1'b0), .savestate_load_ok(1'b0), .savestate_load_err(1'b0),
        .target_dataslot_read(tgt_read), .target_dataslot_write(1'b0),
        .target_dataslot_getfile(1'b0), .target_dataslot_openfile(1'b0),
        .target_dataslot_ack(tgt_ack), .target_dataslot_done(tgt_done), .target_dataslot_err(tgt_err),
        .target_dataslot_id(tgt_id), .target_dataslot_slotoffset(tgt_offset),
        .target_dataslot_bridgeaddr(tgt_bridge), .target_dataslot_length(tgt_length),
        .target_buffer_param_struct(32'b0), .target_buffer_resp_struct(32'b0),
        .datatable_addr(dt_addr), .datatable_wren(dt_wren), .datatable_data(dt_data), .datatable_q(dt_q));

    reg [14:0] read_index = 0;
    wire [31:0] read_data;
    wire [1:0] state;
    wire [13:0] case_state;
    wire stuck;
    wire [1:0] load_state;
    wire [15:0] records;
    sd_probe #(.N(N), .START_DELAY(32'd200), .TIMEOUT(TIMEOUT), .GAP_LONG(GAP_LONG)) dut (
        .clk(clk), .reset(reset), .start(allcomplete && reset_n),
        .slots_done(allcomplete), .load_state(load_state),
        .dt_addr(dt_addr), .dt_wren(dt_wren), .dt_data(dt_data), .dt_q(dt_q),
        .tgt_read(tgt_read), .tgt_id(tgt_id), .tgt_offset(tgt_offset), .tgt_bridge(tgt_bridge),
        .tgt_length(tgt_length), .tgt_ack(tgt_ack), .tgt_done(tgt_done), .tgt_err(tgt_err),
        .bridge_wr(bridge_wr), .bridge_addr(bridge_addr), .bridge_wr_data(bridge_data),
        .read_index(read_index), .read_data(read_data),
        .state_out(state), .case_state(case_state), .stuck(stuck), .records(records));

    function automatic [31:0] rom_word(input [31:0] byte_offset);
        rom_word = (byte_offset >> 2) * 32'd2654435761 + 32'd12345;
    endfunction

    // ---------------- APF firmware model ----------------
    task automatic write_bus(input [31:0] addr, input [31:0] data);
        @(negedge clk); bridge_addr = addr; bridge_data = data;
        @(negedge clk); bridge_wr = 1;
        @(negedge clk); bridge_wr = 0;
    endtask
    task automatic read_bus(input [31:0] addr, output [31:0] data);
        @(negedge clk); bridge_addr = addr; bridge_rd = 1;
        repeat (4) @(negedge clk);
        data = command_data; bridge_rd = 0;
    endtask
    task automatic host_command(input [15:0] command);
        reg [31:0] result;
        write_bus(32'hF800_0000, {16'h434D, command});
        result = 0;
        for (integer n = 0; n < 1000 && result[31:16] !== 16'h4F4B; n++) read_bus(32'hF800_0000, result);
        if (result[31:16] != 16'h4F4B) $fatal(1, "APF host command %h result %h", command, result);
    endtask

    integer lat = 40, jitter = 0, poll = 0, gap = 0, errat = -1, seed = 1, served = 0, lgap = 0, lstall = 0, lgapevery = 1;
    task automatic serve_target();
        reg [31:0] status, id, offset, addr, length;
        integer d;
        read_bus(32'hF800_1000, status);
        repeat (poll) @(negedge clk);
        if (status[31:16] !== 16'h636D) return;
        // Ready to Run (status_setup_done) is answered at once
        if (status[15:0] == 16'h0140) begin write_bus(32'hF800_1000, 32'h6F6B_0000); return; end
        if (status[15:0] != 16'h0180) $fatal(1, "APF target opcode %h", status[15:0]);
        read_bus(32'hF800_1020, id); read_bus(32'hF800_1024, offset);
        read_bus(32'hF800_1028, addr); read_bus(32'hF800_102C, length);
        if (id != 1 || addr != WINDOW) $fatal(1, "APF read shape id=%0d addr=%h", id, addr);
        if (length == 0 || offset + length > ROM_SIZE) $fatal(1, "APF read outside the file offset=%h length=%0d", offset, length);
        write_bus(32'hF800_1000, 32'h6275_0000);
        d = lat + (jitter > 0 ? $urandom(seed) % jitter : 0); seed++;
        repeat (d) @(negedge clk);
        if (served == errat) begin
            served++;
            write_bus(32'hF800_1000, 32'h6F6B_0003);
            return;
        end
        // writes that are not this read's data and must not be counted
        write_bus(WINDOW + 32'h0004_0000, 32'h5A5A_5A5A);
        write_bus(32'h4000_0000, 32'hA5A5_A5A5);
        for (integer n = 0; n < (length + 3) / 4; n++) begin
            write_bus(addr + n*4, rom_word(offset + n*4));
            if (gap > 0) repeat ($urandom(seed + n) % gap) @(negedge clk);
        end
        served++;
        write_bus(32'hF800_1000, 32'h6F6B_0000);
    endtask

    initial begin
        void'($value$plusargs("lat=%d", lat));
        void'($value$plusargs("jitter=%d", jitter));
        void'($value$plusargs("poll=%d", poll));
        void'($value$plusargs("gap=%d", gap));
        void'($value$plusargs("errat=%d", errat));
        void'($value$plusargs("lgap=%d", lgap));
        void'($value$plusargs("lstall=%d", lstall));
        void'($value$plusargs("lgapevery=%d", lgapevery));
        repeat (300) @(negedge clk); reset = 0;
        repeat (20) @(negedge clk);
        // data.json order: ROM (ID 1) then the log (ID 2, no file yet)
        write_bus(32'hF800_2000, 32'd1); write_bus(32'hF800_2004, ROM_SIZE);
        write_bus(32'hF800_2008, 32'd2); write_bus(32'hF800_200C, 32'd0);
        // start-up load: an old log into its slot (not counted), then the ROM
        write_bus(32'h4000_0000, 32'h1234_5678);
        for (integer n = 0; n < ROM_SIZE / 4; n++) begin
            write_bus(n*4, rom_word(n*4));
            if (lgap > 0 && n % lgapevery == 0) repeat ($urandom(seed + n) % lgap) @(negedge clk);
            if (n == 1000) repeat (lstall) @(negedge clk);
        end
        repeat (50) @(negedge clk);
        host_command(16'h008F);
        host_command(16'h0011);
        forever serve_target();
    end

    // ---------------- independent monitor ----------------
    reg [31:0] e_off[0:NREC-1], e_len[0:NREC-1], e_ack[0:NREC-1], e_first[0:NREC-1], e_last[0:NREC-1];
    reg [31:0] e_done[0:NREC-1], e_words[0:NREC-1], e_sum[0:NREC-1];
    reg [2:0] e_err[0:NREC-1];
    reg e_acked[0:NREC-1];
    integer cyc = 0, c0 = 0, ncmd = 0;
    reg active = 0, prev_read = 0, prev_ack = 0, low = 0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        prev_read <= tgt_read; prev_ack <= tgt_ack;
        if (tgt_read && !prev_read) begin
            if (active) $fatal(1, "new command before done");
            if (ncmd >= NREC) $fatal(1, "more commands than records");
            active = 1; low = 0; c0 = cyc;
            e_off[ncmd] = tgt_offset; e_len[ncmd] = tgt_length; e_acked[ncmd] = 0; e_ack[ncmd] = 0;
            e_first[ncmd] = 0; e_last[ncmd] = 0; e_words[ncmd] = 0; e_sum[ncmd] = 0;
        end
        if (active) begin
            if (tgt_ack && !prev_ack && !e_acked[ncmd]) begin e_acked[ncmd] = 1; e_ack[ncmd] = cyc - c0; end
            if (bridge_wr && bridge_addr >= WINDOW && bridge_addr < WINDOW + 32'h0004_0000) begin
                if (e_words[ncmd] == 0) e_first[ncmd] = cyc - c0;
                e_last[ncmd] = cyc - c0;
                e_words[ncmd] = e_words[ncmd] + 1;
                e_sum[ncmd] = e_sum[ncmd] + bridge_data;
            end
            if (!tgt_done) low = 1;
            else if (low) begin
                e_done[ncmd] = cyc - c0; e_err[ncmd] = tgt_err;
                active = 0; ncmd = ncmd + 1;
            end
        end
    end

    // start-up load, timed like the probe (clocks between write strobes)
    reg [31:0] m_words = 0, m_sum = 0, m_gap = 0, m_gap_at = 0, m_long = 0, m_jumps = 0, m_addr = 0;
    reg [63:0] m_long_clocks = 0;
    integer m_first = -1, m_last = 0, m_done = -1;
    always @(posedge clk) begin
        if (allcomplete && m_done < 0) m_done = cyc;
        if (bridge_wr && bridge_addr < 32'h2000_0000 && m_done < 0) begin
            if (m_first < 0) m_first = cyc;
            else begin
                if (cyc - m_last > m_gap) begin m_gap = cyc - m_last; m_gap_at = m_words; end
                if (cyc - m_last >= GAP_LONG) begin m_long++; m_long_clocks = m_long_clocks + (cyc - m_last); end
                if (bridge_addr != m_addr + 4) m_jumps++;
            end
            m_last = cyc; m_addr = bridge_addr;
            m_words++; m_sum = m_sum + bridge_data;
        end
    end

    // ---------------- checks ----------------
    integer fails = 0;
    task automatic check(input cond, input [8*64-1:0] what, input integer r);
        if (!cond) begin
            fails++;
            if (fails < 20) $display("FAIL record %0d: %0s", r, what);
        end
    endtask
    reg [31:0] logw[0:LOG_WORDS-1];
    integer fd;
    reg [8*256-1:0] logname;
    initial begin
        reg [31:0] w0, expect_sum, len, align, prev_end;
        reg [2:0] c;
        integer seq_wrapped;
        wait (state == 2'd2 || state == 2'd3);
        if (state != 2'd2) $fatal(1, "probe failed, state %0d", state);
        repeat (10) @(negedge clk);
        for (integer i = 0; i < LOG_WORDS; i++) begin
            @(negedge clk) read_index = i;
            @(negedge clk) logw[i] = read_data;
        end
        if (logw[0] != 32'h5344_5042) $fatal(1, "magic %h", logw[0]);
        check(logw[2] == NREC && records == NREC && ncmd == NREC, "record count", -1);
        check(logw[3] == ROM_SIZE, "ROM size", -1);
        check(logw[6] == N, "records per case", -1);
        check(logw[15] == 32'h001F_FFFF, "offset mask", -1);
        check(logw[5][31] == 1, "done flag", -1);
        check(logw[1] == {8'd2, 8'd8, 16'd7}, "format word", -1);
        // start-up load
        expect_sum = 0;
        for (integer n = 0; n < ROM_SIZE / 4; n++) expect_sum = expect_sum + rom_word(n*4);
        check(logw[16] == ROM_SIZE / 4 && m_words == ROM_SIZE / 4, "load words", -1);
        check(logw[17] == expect_sum && m_sum == expect_sum, "load sum", -1);
        check(logw[20] - logw[18] == m_last - m_first && logw[19] == 0 && logw[21] == 0, "load span", -1);
        check(logw[26] - logw[18] == m_done - m_first, "slots complete time", -1);
        check(logw[22] == m_gap && logw[23] == m_gap_at, "largest load gap", -1);
        check(lstall < 1000 || (m_gap >= lstall && m_gap_at == 1001), "stall is the largest gap", -1);
        check(logw[24] == m_long && logw[25] == m_long_clocks[39:8], "gaps over GAP_LONG", -1);
        check(logw[28] == m_jumps && m_jumps == 0, "load address jumps", -1);
        check(logw[29] == ROM_SIZE - 4 && logw[30] == 0 && logw[31] == GAP_LONG, "last load address, window, GAP_LONG", -1);
        check(load_state == 2'd2, "load state", -1);
        for (integer r = 0; r < NREC; r++) begin
            w0 = logw[HDR + 8*r];
            c = r / N;
            len = c == 0 ? 4 : c <= 2 ? 512 : c <= 4 ? 32768 : 262144;
            align = len < 512 ? 512 : len;
            check(w0[31:28] == 4'hA && w0[27:24] == c && w0[15:0] == r % N, "record tag", r);
            check(e_len[r] == len, "command length", r);
            check(logw[HDR + 8*r + 1] == e_off[r], "offset", r);
            check(e_off[r] % align == 0 && e_off[r] + len <= ROM_SIZE, "offset alignment/range", r);
            // sequential cases continue from the record before, wrapping to 0
            if ((c == 2 || c == 4 || c == 6) && r % N != 0)
                check(e_off[r] == e_off[r-1] + len || (e_off[r] == 0 && e_off[r-1] + 2*len > ROM_SIZE), "sequential order", r);
            check(w0[23:21] == e_err[r] && w0[20] == e_acked[r], "error/ack flags", r);
            check(logw[HDR + 8*r + 2] == e_ack[r], "t_ack", r);
            check(logw[HDR + 8*r + 3] == e_first[r], "t_first", r);
            check(logw[HDR + 8*r + 4] == e_last[r], "t_last", r);
            check(logw[HDR + 8*r + 5] == e_done[r], "t_done", r);
            check(w0[19] == (e_done[r] >= TIMEOUT), "timeout flag", r);
            check(logw[HDR + 8*r + 6] == e_words[r] && logw[HDR + 8*r + 7] == e_sum[r], "words/sum vs bus", r);
            expect_sum = 0;
            for (integer n = 0; n < (len + 3) / 4; n++) expect_sum = expect_sum + rom_word(e_off[r] + n*4);
            if (e_err[r] == 0)
                check(e_words[r] == (len + 3) / 4 && e_sum[r] == expect_sum, "data vs ROM", r);
            else check(e_words[r] == 0, "error read has no data", r);
            check(e_ack[r] > 0 && e_ack[r] < e_done[r] && (e_err[r] != 0 || (e_ack[r] < e_first[r] && e_last[r] < e_done[r])), "event order", r);
        end
        for (integer k = 0; k < 7; k++)
            check(case_state[2*k +: 2] == ((errat >= 0 && errat / N == k) ? 2'd3 : 2'd2), "case state", k);
        check(stuck == 1, "stuck flag (256 KiB reads exceed the test timeout)", -1);
        if ($value$plusargs("log=%s", logname)) begin
            fd = $fopen(logname, "wb");
            // +pocketsave: as the test Pocket saved it (2026-10-23): big-endian,
            // and the one-word lag drops the magic. Otherwise little-endian
            // with a leading junk word, as first modelled.
            for (integer i = 0; i < LOG_WORDS + 4; i++) begin
                if ($test$plusargs("pocketsave")) begin
                    w0 = i + 1 < LOG_WORDS ? logw[i+1] : 32'h0;
                    $fwrite(fd, "%c%c%c%c", w0[31:24], w0[23:16], w0[15:8], w0[7:0]);
                end else begin
                    w0 = i == 0 ? 32'hDEAD_BEEF : i <= LOG_WORDS ? logw[i-1] : 32'h0;
                    $fwrite(fd, "%c%c%c%c", w0[7:0], w0[15:8], w0[23:16], w0[31:24]);
                end
            end
            $fclose(fd);
        end
        if (fails) $fatal(1, "%0d checks failed", fails);
        $display("PASS: %0d records, lat=%0d jitter=%0d poll=%0d gap=%0d errat=%0d, %0d clocks", NREC, lat, jitter, poll, gap, errat, cyc);
        $finish;
    end
    initial begin
        #400ms $fatal(1, "timeout");
    end
endmodule
