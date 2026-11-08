// Equivalence of nds_controls FW = 1 (the per-frame work in SERV's firmware, sw/scpu/cache.c ctl_step, through
// nds_cart_scpu) against an earlier hardware version (nds_controls_old), with random keys, gesture settings,
// speeds, sticks and controller types. Run by sim/pocket_ds/controls_eq.py --fw (docs/space-ctl.md).
//
// The firmware's results follow the frame pulse by L clocks (the window: from the pulse to the frame's last
// register write). Every output is compared on every clock outside the windows, so on every frame after its
// update. The keys change on any clock (the snapshot at the pulse keeps them exact); the sticks, controller
// type, gesture settings and speed, which the firmware reads when it runs, only outside the windows (a known
// difference, docs/space-ctl.md). The ROM cache serves a client with random reads at the same time (a small
// cache, a slow APF host), so misses meet the controls' steps; the bench measures the window (L) and each miss's
// latencies, for docs/space-ctl.md's added-latency figure (+frames=0: the same run without controls frames).
//   +fw=HEX (SERV's image, words)  +frames=0|1  +nframes=N  +client=0 (no cart reads: the window alone)
//   +verilator+seed+N
`timescale 1ns/1ps
module tb_controls_fw;
    reg clk = 0, reset = 1;
    always #5 clk = !clk;
    reg [15:0] keys = 0;
    reg [3:0] ctype = 1;
    reg [31:0] joy = 32'h8080_8080;
    reg frame = 0;
    reg [1:0] csel = 0, speed = 1;
    reg [11:0] gest = 12'h001;
    wire [1:0] lo, ln;
    wire to, tn, co, cn, po, pn;
    wire [7:0] xo, yo, xn, yn, pxo, pyo, pxn, pyn;
    wire [15:0] ko, kn;
    nds_controls_old ref_ (.clk, .reset, .apf_keys(keys), .apf_type(ctype), .apf_joy(joy), .frame,
        .combo_sel(csel), .gest, .speed, .layout_set(2'd0), .set_new(1'b0),
        .layout(lo), .touch(to), .cursor(co), .pen(po), .cur_x(xo), .cur_y(yo), .pen_x(pxo), .pen_y(pyo), .ds_keys(ko));
    wire c_we0, c_we1, c_take, c_pend;
    wire [31:0] c_r0, m_wdata;
    wire [2:0] c_st;
    wire [13:0] c_set;
    nds_controls #(.FW(1)) dut (.clk, .reset, .apf_keys(keys), .apf_type(ctype), .apf_joy(joy), .frame,
        .combo_sel(csel), .gest, .speed, .layout_set(2'd0), .set_new(1'b0),
        .layout(ln), .touch(tn), .cursor(cn), .pen(pn), .cur_x(xn), .cur_y(yn), .pen_x(pxn), .pen_y(pyn), .ds_keys(kn),
        .io_we0(c_we0), .io_we1(c_we1), .io_take(c_take), .io_wd(m_wdata), .io_pend(c_pend), .io_r0(c_r0),
        .io_st(c_st), .io_set(c_set));

    // ---- the ROM cache with SERV, its SDRAM, APF host and client
    localparam [31:0] ROM = 32'h1_0000;     // 16 blocks over 8 slots: misses all along
    localparam [23:0] FW_W = 24'h2C_0800, NDT_W = 24'h30_0000 - 24'h400;
    wire ready, fail, c_ready, r_valid, fc_send, m_valid, m_write, m_quad, dg_wait;
    wire [31:0] r_data;
    wire [119:0] fc_data;
    wire [13:0] fc_slot;
    wire [23:0] m_addr;
    wire [3:0] m_be;
    reg start = 0, c_valid = 0, fc_busy = 0, mk_valid = 0, m_ready = 0, m_rvalid = 0;
    reg [31:0] c_addr = 0, m_rdata = 0;
    nds_cart_scpu #(.SLOTS(8)) cache (.clk, .reset, .start, .rom_size(ROM), .ready, .fail,
        .c_valid, .c_addr, .c_ready, .r_valid, .r_data, .fc_send, .fc_data, .fc_sel(3'd0), .fc_slot, .fc_busy,
        .mk_valid, .mk_err(3'd0), .m_valid, .m_write, .m_quad, .m_addr, .m_wdata, .m_be, .m_ready, .m_rvalid,
        .m_rdata, .stat_clear(1'b0), .tick_ms(1'b0), .st_lookups(), .st_cmds(), .st_blocks(), .st_wait(),
        .dg_wait, .dg_cmd(), .ctl_we0(c_we0), .ctl_we1(c_we1), .ctl_take(c_take), .ctl_pend(c_pend),
        .ctl_r0(c_r0), .ctl_st(c_st), .ctl_set(c_set));
    bit [31:0] mem [bit [23:0]];
    function automatic [31:0] rd(input [23:0] a); rd = mem.exists(a) ? mem[a] : 32'd0; endfunction
    int left = 0, lat = 0, mwait = -1, mn = 0;
    reg [23:0] ma = 0;
    always @(posedge clk) begin
        m_ready <= 0; m_rvalid <= 0;
        if (reset) begin left = 0; mwait = -1; end
        else begin
            if (left > 0) begin
                if (lat > 0) lat--;
                else begin m_rvalid <= 1; m_rdata <= rd(ma + mn); mn++; left--; end
            end
            if (m_valid && left == 0 && !m_ready) begin
                if (mwait < 0) mwait = $urandom % 4;
                if (mwait-- == 0) begin
                    m_ready <= 1; mwait = -1;
                    if (m_write) begin
                        automatic reg [31:0] o = rd(m_addr);
                        for (int b = 0; b < 4; b++) if (m_be[b]) o[8 * b +: 8] = m_wdata[8 * b +: 8];
                        mem[m_addr] = o;
                    end else begin ma = m_addr; mn = 0; left = m_quad ? 4 : 1; lat = 1 + $urandom % 4; end
                end
            end
        end
    end
    // the APF host: busy a few clocks, the marker after 0.2-30% of a frame (the Pocket: ~3 ms a block)
    int mk_at = -1, busy_n = 0;
    always @(posedge clk) begin
        mk_valid <= 0;
        if (busy_n > 0) busy_n--;
        fc_busy <= busy_n > 0;
        if (mk_at > 0) mk_at--; else if (mk_at == 0) begin mk_valid <= 1; mk_at = -1; end
        if (fc_send) begin busy_n = 3 + $urandom % 6; mk_at = 100 + $urandom % 15000; end
        if (reset) begin mk_at = -1; busy_n = 0; end
    end
    // the client: quad reads, mostly near the last, with idle gaps
    int words = -1, idle_c = 0;
    reg [31:0] cur = 0;
    always @(posedge clk) begin
        if (reset) begin c_valid <= 0; words = -1; end
        else if (c_valid && c_ready) begin c_valid <= 0; words = 0; end
        else if (words >= 0) begin if (r_valid && ++words == 4) begin words = -1; idle_c = $urandom % 16000; end end
        else if (!c_valid && ready && client) begin
            if (idle_c > 0) idle_c--;
            else begin
                cur = $urandom % 4 ? (cur + 16 * ($urandom % 64)) % ROM : $urandom % ROM;
                c_addr <= cur & ~32'hF; c_valid <= 1;
            end
        end
    end

    // ---- the windows, the miss latencies
    longint n = 0, cmp = 0, errors = 0, pens = 0, touches = 0, moved = 0, clamped = 0, frames = 0, gest_frames = 0;
    longint w_max = 0, w_sum = 0, misses = 0, miss_win = 0, iss_max = 0, iss_sum = 0, fin_max = 0, fin_sum = 0;
    reg win = 0, took = 0, w0 = 0, w1 = 0, dgq = 0, mkseen = 0, sent = 0, mwin = 0;
    longint w_start = 0, m_start = 0, mk_t = 0;
    always @(posedge clk) begin
        if (frame) begin win <= 1; took <= 0; w0 <= 0; w1 <= 0; w_start = n; end
        else if (win) begin
            if (c_take) took <= 1;
            if (took && c_we0) w0 <= 1;
            if (took && c_we1) w1 <= 1;
            if (took && w0 && w1) begin
                win <= 0; frames++;
                if (n - w_start > w_max) w_max = n - w_start;
                w_sum += n - w_start;
            end
        end
        // a miss: from the client's wait to its command (issue), and from the command's marker to the end (finish)
        dgq <= dg_wait;
        if (dg_wait && !dgq) begin m_start = n; sent <= 0; mkseen <= 0; mwin <= win; end
        if (dg_wait) begin
            if (win) mwin <= 1;
            if (fc_send && !sent) begin sent <= 1; if (n - m_start > iss_max) iss_max = n - m_start; iss_sum += n - m_start; end
            if (mk_valid && sent && !mkseen) begin mkseen <= 1; mk_t = n; end
        end
        if (!dg_wait && dgq) begin
            misses++; miss_win += mwin;
            if (mkseen) begin if (n - mk_t > fin_max) fin_max = n - mk_t; fin_sum += n - mk_t; end
        end
        if (reset) begin win <= 0; dgq <= 0; end
    end

    // ---- stimulus and comparison
    int seed_frames = 1, nframes = 300, gap = 0, burst = 0, hold_joy = 0, client = 1, rst_frames = -1, resets = 0;
    reg [1023:0] fw;
    initial begin
        if (!$value$plusargs("fw=%s", fw)) $fatal(1, "+fw= missing");
        if (!$value$plusargs("frames=%d", seed_frames)) seed_frames = 1;
        if (!$value$plusargs("nframes=%d", nframes)) nframes = 300;
        if (!$value$plusargs("client=%d", client)) client = 1;
        begin
            reg [31:0] img [0:1023];
            for (int i = 0; i < 1024; i++) img[i] = 0;
            $readmemh(fw, img);
            for (int i = 0; i < 1024; i++) mem[FW_W + i] = img[i];
        end
        mem[NDT_W] = 32'h3154444E; mem[NDT_W + 1] = 1; mem[NDT_W + 3] = ROM;   // the plugin's table: no start-up scan
        repeat (4) @(posedge clk);
        reset = 0; start = 1;
        hold_joy = 2;
        wait (ready);
        gap = 2000;
        while (frames < nframes) begin
            @(negedge clk);
            // the keys: a few changes a frame, and bursts (combos, touch mode toggles, presses inside the windows)
            if (burst > 0) burst--; else if ($urandom % 1500000 == 0) burst = 3000 + $urandom % 30000;
            if ($urandom % (burst > 0 ? 40 : 40000) == 0) begin
                automatic int k = $urandom % 20;     // mostly the D-pad and A/B/X/Y, SELECT now and then
                keys[k < 2 ? 14 : k < 16 ? $urandom % 8 : $urandom % 16] ^= 1;
            end
            if ($urandom % 4000000 == 0) keys = 0;
            if ($urandom % 2000000 == 0) csel = $urandom % 2 ? 2'd0 : $urandom;
            // what the firmware reads when it runs: outside the windows, the type also not near a pulse
            if (!win && !frame && hold_joy == 0) begin
                if ($urandom % 500000 == 0) joy = $urandom % 4 ? {$urandom % 2 ? 8'h80 : 8'($urandom), 8'($urandom), 8'($urandom), 8'($urandom)} : 32'h8080_8080;
                if ($urandom % 400000 == 0 && gap > 50) ctype = $urandom % 2 ? 4'h3 : 4'h1;
                if ($urandom % 300000 == 0) speed = $urandom % 3;
                if ($urandom % 1000000 == 0) gest = $urandom;
            end
            // a reset now and then: both start over. g_hw's stick sample survives a reset and the firmware's
            // starts centred (a known difference), so the sticks are centred first and the reset waits until a
            // frame has sampled them; no frame before the cache is ready
            if (rst_frames < 0 && $urandom % 30000000 == 0) begin joy = 32'h8080_8080; hold_joy = 3; rst_frames = frames + 2; end
            if (rst_frames >= 0 && frames >= rst_frames && !win) begin
                rst_frames = -1; resets++; mem[NDT_W] = 32'h3154444E;
                reset = 1; @(negedge clk); @(negedge clk); reset = 0;
                wait (ready); @(negedge clk);
            end
            // frame: one clk_bus pulse per DS frame, 100k-160k clocks apart (the Pocket: 560k)
            if (seed_frames != 0) begin
                frame = gap == 0;
                if (gap == 0) begin gap = 100000 + $urandom % 60000; if (hold_joy > 0) hold_joy--; end else gap--;
            end else begin
                frame = 0;
                if (gap == 0) begin gap = 100000 + $urandom % 60000; frames++; end else gap--;
            end
            @(posedge clk); #1;
            n++;
            if (!win && !reset) begin
                cmp++;
                pens += pn; touches += tn;
                moved += pn && pxn != xn;
                clamped += pn && (pxn == 0 || pxn == 255 || pyn == 0 || pyn == 191);
                if ({lo, to, co, po, xo, yo, ko, pxo, pyo} !== {ln, tn, cn, pn, xn, yn, kn, pxn, pyn}) begin
                    errors++;
                    if (errors < 5) $display("DIFF at %0d (frame %0d): layout %0d/%0d touch %b/%b cursor %b/%b pen %b/%b x %0d/%0d y %0d/%0d keys %h/%h pen_x %0d/%0d pen_y %0d/%0d",
                        n, frames, lo, ln, to, tn, co, cn, po, pn, xo, xn, yo, yn, ko, kn, pxo, pxn, pyo, pyn);
                end
            end
        end
        $display("%0d cycles, %0d frames, %0d compared, %0d with touch mode, %0d with the pen down, %0d with a gesture point off the cursor, %0d pen-down at an edge",
            n, frames, cmp, touches, pens, moved, clamped);
        $display("window (frame pulse to the last write): max %0d, mean %0d clocks; %0d resets", w_max, frames ? w_sum / frames : 0, resets);
        $display("misses %0d (%0d meeting a window): issue max %0d mean %0d, finish max %0d mean %0d clocks",
            misses, miss_win, iss_max, misses ? iss_sum / misses : 0, fin_max, misses ? fin_sum / misses : 0);
        if (seed_frames == 0) $display("NO FRAMES (control run)");
        else if (errors == 0 && touches > 0 && pens > 0 && moved > 0 && clamped > 0) $display("EQUIVALENT");
        else $display("NOT EQUIVALENT (%0d)", errors);
        $finish;
    end
endmodule
