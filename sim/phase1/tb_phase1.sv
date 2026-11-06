// SPDX-License-Identifier: MIT
// Phase 1 test core, whole chip (docs/phase1-foundation.md, "Tests"):
// core_top with the pinned APF command handler, a model of the Pocket's APF
// firmware on the bridge, and pin models of the SDRAM, both CellularRAMs and
// the SRAM. sim/phase1/run.py builds the files and checks the results.
//
// The firmware model writes the data table (ROM ID 1, BIOS9 2, BIOS7 3,
// firmware 4, log 9), loads BIOS9/BIOS7/firmware through the 0x0082
// request-write handshake into their bridge addresses, sends all-complete,
// then serves every 0x0180 target read from the ROM image: busy, a latency,
// the words (bytes past the end of the file as 0xEE), ok. Bridge words are
// what io_bridge_peripheral delivers with bridge_endian_little = 1: file data
// little-endian, command-register values byte-swapped.
//
// Plusargs: +rom=HEX +romsize=N +bios9=HEX +bios7=HEX +fw=HEX (+...size=N)
//           +lat=N +jitter=N +gap=N  host timing in clk_74a clocks
//           +wspace=N clocks per data word (default 16)
//           +errat=K  target command K (0-based, any kind) fails with APF error 3
//           +trace=FILE  every target command: kind offset length
//           +log=FILE    the 64-word log read back through the bridge
//           +timeout_ms=N
`timescale 1ns/1ps
module tb_phase1;
    parameter integer SLOTS = 24;
    parameter bit PREFETCH = 0;             // the cache's sequential prefetch (run.py's prefetch runs)
    reg clk_74a = 0, clk_74b = 0;
    always #6.734 clk_74a = !clk_74a;
    always #6.734 clk_74b = !clk_74b;

    reg [31:0] bridge_addr = 0, bridge_wr_data = 0;
    reg bridge_rd = 0, bridge_wr = 0;
    wire [31:0] bridge_rd_data;
    reg [31:0] cont1_key = 0;
    wire [12:0] dram_a; wire [1:0] dram_ba, dram_dqm; wire [15:0] dram_dq;
    wire dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;
    wire [21:16] cram0_a, cram1_a; wire [15:0] cram0_dq, cram1_dq;
    wire cram0_wait, cram1_wait, cram0_clk, cram1_clk;
    wire cram0_adv_n, cram0_cre, cram0_ce0_n, cram0_ce1_n, cram0_oe_n, cram0_we_n, cram0_ub_n, cram0_lb_n;
    wire cram1_adv_n, cram1_cre, cram1_ce0_n, cram1_ce1_n, cram1_oe_n, cram1_we_n, cram1_ub_n, cram1_lb_n;
    wire [16:0] sram_a; wire [15:0] sram_dq; wire sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n;
    wire [23:0] video_rgb; wire video_de, video_hs, video_vs, video_skip, video_clk, video_clk90;
    wire bridge_endian_little;

    core_top #(.CACHE_SLOTS(SLOTS), .CACHE_PREFETCH(PREFETCH), .SDRAM_TEST_WORDS(24'd4096), .PSRAM_TEST_WORDS(22'd2048),
               .SRAM_LAST(17'd255), .DIRECT_CHUNK(32'h8000), .MS_CLOCKS(32'd7425), .MS_BUS_CLOCKS(32'd3351)) dut (
        .clk_74a(clk_74a), .clk_74b(clk_74b),
        .cart_tran_bank2(), .cart_tran_bank2_dir(), .cart_tran_bank3(), .cart_tran_bank3_dir(),
        .cart_tran_bank1(), .cart_tran_bank1_dir(), .cart_tran_bank0(), .cart_tran_bank0_dir(),
        .cart_tran_pin30(), .cart_tran_pin30_dir(), .cart_pin30_pwroff_reset(), .cart_tran_pin31(), .cart_tran_pin31_dir(),
        .port_ir_rx(1'b0), .port_ir_tx(), .port_ir_rx_disable(),
        .port_tran_si(), .port_tran_si_dir(), .port_tran_so(), .port_tran_so_dir(),
        .port_tran_sck(), .port_tran_sck_dir(), .port_tran_sd(), .port_tran_sd_dir(),
        .cram0_a(cram0_a), .cram0_dq(cram0_dq), .cram0_wait(cram0_wait), .cram0_clk(cram0_clk), .cram0_adv_n(cram0_adv_n),
        .cram0_cre(cram0_cre), .cram0_ce0_n(cram0_ce0_n), .cram0_ce1_n(cram0_ce1_n), .cram0_oe_n(cram0_oe_n),
        .cram0_we_n(cram0_we_n), .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n),
        .cram1_a(cram1_a), .cram1_dq(cram1_dq), .cram1_wait(cram1_wait), .cram1_clk(cram1_clk), .cram1_adv_n(cram1_adv_n),
        .cram1_cre(cram1_cre), .cram1_ce0_n(cram1_ce0_n), .cram1_ce1_n(cram1_ce1_n), .cram1_oe_n(cram1_oe_n),
        .cram1_we_n(cram1_we_n), .cram1_ub_n(cram1_ub_n), .cram1_lb_n(cram1_lb_n),
        .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq), .dram_dqm(dram_dqm), .dram_clk(dram_clk),
        .dram_cke(dram_cke), .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n),
        .sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n), .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n),
        .vblank(1'b0), .dbg_tx(), .dbg_rx(1'b0), .user1(), .user2(1'b0), .aux_sda(), .aux_scl(), .vpll_feed(),
        .video_rgb(video_rgb), .video_rgb_clock(video_clk), .video_rgb_clock_90(video_clk90), .video_de(video_de),
        .video_skip(video_skip), .video_vs(video_vs), .video_hs(video_hs),
        .audio_mclk(), .audio_adc(1'b0), .audio_dac(), .audio_lrck(),
        .bridge_endian_little(bridge_endian_little), .bridge_addr(bridge_addr), .bridge_rd(bridge_rd),
        .bridge_rd_data(bridge_rd_data), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
        .cont1_key(cont1_key), .cont2_key(32'b0), .cont3_key(32'b0), .cont4_key(32'b0),
        .cont1_joy(32'b0), .cont2_joy(32'b0), .cont3_joy(32'b0), .cont4_joy(32'b0),
        .cont1_trig(16'b0), .cont2_trig(16'b0), .cont3_trig(16'b0), .cont4_trig(16'b0));

    // ---------------- memory models ----------------
    wire #2.0 chip_clk = dram_clk;
    sdram_chip_model #(.CAS(3), .T_AC(6.0), .T_OH(2.5), .T_RET(2.0), .NAME("sdram")) sdram_chip (
        .clk(chip_clk), .cke(dram_cke), .ncs(1'b0), .nras(dram_ras_n), .ncas(dram_cas_n), .nwe(dram_we_n),
        .a(dram_a), .ba(dram_ba), .dqm(dram_dqm), .dq(dram_dq));
    cram_model #(.NAME("cram0")) cram0 (.sclk(dut.clk_mem), .clk(cram0_clk), .a(cram0_a), .dq(cram0_dq), .wait_o(cram0_wait),
        .adv_n(cram0_adv_n), .cre(cram0_cre), .ce0_n(cram0_ce0_n), .ce1_n(cram0_ce1_n), .oe_n(cram0_oe_n),
        .we_n(cram0_we_n), .ub_n(cram0_ub_n), .lb_n(cram0_lb_n));
    cram_model #(.NAME("cram1")) cram1 (.sclk(dut.clk_mem), .clk(cram1_clk), .a(cram1_a), .dq(cram1_dq), .wait_o(cram1_wait),
        .adv_n(cram1_adv_n), .cre(cram1_cre), .ce0_n(cram1_ce0_n), .ce1_n(cram1_ce1_n), .oe_n(cram1_oe_n),
        .we_n(cram1_we_n), .ub_n(cram1_ub_n), .lb_n(cram1_lb_n));
    sram_model sram (.clk(dut.clk_mem), .a(sram_a), .dq(sram_dq), .oe_n(sram_oe_n), .we_n(sram_we_n),
        .ub_n(sram_ub_n), .lb_n(sram_lb_n));

    // ---------------- stale SDRAM (+stale_sdram) ----------------
    // An earlier session's ROM tables for a ROM of this size, with every block
    // marked cached in slot 0, already in SDRAM before power-up: the core must
    // clear the magic first and not take them (nds_apf_host, nds_cart_cache).
    function automatic int sdram_hw(input [25:0] at);       // halfword index in sdram_chip_model
        sdram_hw = {7'b0, at[24:23], at[22:10], at[25], at[9:1]};
    endfunction
    task automatic sdram_word(input [23:0] w, input [31:0] v);
        sdram_chip.mem[sdram_hw({w, 2'b00})] = v[15:0];
        sdram_chip.mem[sdram_hw({w, 2'b10})] = v[31:16];
    endtask
    initial if ($test$plusargs("stale_sdram")) begin
        integer sz;
        #1;
        void'($value$plusargs("romsize=%d", sz));
        sdram_word(24'h2F_FC00, 32'h3154_444E);     // "NDT1"
        sdram_word(24'h2F_FC01, 32'd1);             // version 1: valid tables but for the power-up clear
        sdram_word(24'h2F_FC03, sz);
        for (integer b = 0; b < (sz + 4095) / 4096; b++) sdram_word(24'h30_0000 + b, 32'h0001_0000);
    end

    // ---------------- files ----------------
    reg [31:0] rom [0:(1<<20)-1];
    reg [31:0] b9 [0:1023], b7 [0:4095], fw [0:65535], ndt [0:65535], sv [0:262143];
    integer romsize = 0, s9 = 4096, s7 = 16384, sfw = 16384, sndt = 0, ssv = 0;
    reg [8*256-1:0] fname;

    // ---------------- APF firmware model ----------------
    function automatic [31:0] swap(input [31:0] v);
        swap = {v[7:0], v[15:8], v[23:16], v[31:24]};
    endfunction
    integer wspace = 16;    // clocks per data word: 215 ns, ~10x the Pocket's measured 1.7-1.9 MB/s
    task automatic write_bus(input [31:0] addr, input [31:0] data);
        @(negedge clk_74a); bridge_addr = addr; bridge_wr_data = data;
        @(negedge clk_74a); bridge_wr = 1;
        @(negedge clk_74a); bridge_wr = 0;
    endtask
    task automatic write_data(input [31:0] addr, input [31:0] data);
        write_bus(addr, data);
        repeat (wspace - 3) @(negedge clk_74a);
    endtask
    task automatic read_bus(input [31:0] addr, output [31:0] data);
        @(negedge clk_74a); bridge_addr = addr; bridge_rd = 1;
        repeat (4) @(negedge clk_74a);
        data = bridge_rd_data; bridge_rd = 0;
    endtask
    task automatic write_reg(input [31:0] addr, input [31:0] v); write_bus(addr, swap(v)); endtask
    task automatic read_reg(input [31:0] addr, output [31:0] v);
        reg [31:0] r; read_bus(addr, r); v = swap(r);
    endtask
    task automatic host_command(input [15:0] command);
        reg [31:0] result;
        write_reg(32'hF800_0000, {16'h434D, command});
        result = 0;
        for (integer n = 0; n < 100000 && result[31:16] !== 16'h4F4B; n++) read_reg(32'hF800_0000, result);
        if (result[31:16] != 16'h4F4B) $fatal(1, "APF host command %h result %h", command, result);
    endtask
    task automatic load_slot(input [15:0] id, input [31:0] base, input integer size, input integer which);
        write_reg(32'hF800_0020, {16'b0, id});
        write_reg(32'hF800_0024, size);
        host_command(16'h0082);
        for (integer n = 0; n < size / 4; n++)
            write_data(base + n*4, which == 0 ? b9[n] : which == 1 ? b7[n] : which == 2 ? fw[n] : which == 3 ? ndt[n] : sv[n]);
    endtask

    integer lat = 60, jitter = 0, gap = 0, errat = -1, served = 0, seed = 7, fd_trace = 0;
    function automatic [31:0] rom_word(input integer off);
        reg [31:0] w;
        w = rom[off / 4];
        // bytes past the end of the file
        for (integer b = 0; b < 4; b++) if (off + b >= romsize) w[b*8 +: 8] = 8'hEE;
        rom_word = w;
    endfunction
    task automatic serve_target();
        reg [31:0] status, id, offset, addr, length;
        integer d;
        read_reg(32'hF800_1000, status);
        if (status[31:16] !== 16'h636D) return;
        if (status[15:0] == 16'h0140) begin write_reg(32'hF800_1000, 32'h6F6B_0000); return; end
        if (status[15:0] != 16'h0180) $fatal(1, "APF target opcode %h", status[15:0]);
        read_reg(32'hF800_1020, id); read_reg(32'hF800_1024, offset);
        read_reg(32'hF800_1028, addr); read_reg(32'hF800_102C, length);
        if (id != 1) $fatal(1, "target read of slot %0d", id);
        if (length == 0 || offset + length > romsize) $fatal(1, "target read outside the file: offset %h length %0d", offset, length);
        if (addr != 32'h2000_0000 && addr != 32'h5000_0000) $fatal(1, "target read to bridge %h", addr);
        if (fd_trace) $fdisplay(fd_trace, "%s %0d %0d", addr == 32'h2000_0000 ? "fetch" : "direct", offset, length);
        write_reg(32'hF800_1000, 32'h6275_0000);
        d = lat + (jitter > 0 ? $urandom(seed) % jitter : 0); seed++;
        repeat (d) @(negedge clk_74a);
        if (served == errat) begin
            served++;
            if (fd_trace) $fdisplay(fd_trace, "error");
            // some of the data arrives before the error, wrong in places
            for (integer n = 0; n < (length + 3) / 8; n++) write_data(addr + n*4, rom_word(offset + n*4) ^ (n % 3 == 0 ? 32'h1 : 32'h0));
            write_reg(32'hF800_1000, 32'h6F6B_0003);
            return;
        end
        served++;
        for (integer n = 0; n < (length + 3) / 4; n++) begin
            write_data(addr + n*4, rom_word(offset + n*4));
            if (gap > 0) repeat ($urandom(seed + n) % gap) @(negedge clk_74a);
        end
        write_reg(32'hF800_1000, 32'h6F6B_0000);
    endtask

    reg done_loading = 0, stop_serving = 0, serving = 0;
    initial begin
        if (!$value$plusargs("rom=%s", fname)) $fatal(1, "+rom= missing");
        $readmemh(fname, rom);
        if (!$value$plusargs("romsize=%d", romsize)) $fatal(1, "+romsize= missing");
        if ($value$plusargs("bios9=%s", fname)) $readmemh(fname, b9); else s9 = 0;
        if ($value$plusargs("bios7=%s", fname)) $readmemh(fname, b7); else s7 = 0;
        if ($value$plusargs("fw=%s", fname)) $readmemh(fname, fw); else sfw = 0;
        void'($value$plusargs("fwsize=%d", sfw));
        if ($value$plusargs("ndt=%s", fname)) begin $readmemh(fname, ndt); void'($value$plusargs("ndtsize=%d", sndt)); end
        if ($value$plusargs("save=%s", fname)) begin $readmemh(fname, sv); void'($value$plusargs("savesize=%d", ssv)); end
        void'($value$plusargs("lat=%d", lat));
        void'($value$plusargs("jitter=%d", jitter));
        void'($value$plusargs("gap=%d", gap));
        void'($value$plusargs("wspace=%d", wspace));
        void'($value$plusargs("errat=%d", errat));
        if ($value$plusargs("trace=%s", fname)) fd_trace = $fopen(fname, "w");
        repeat (400) @(negedge clk_74a);
        // data.json order: ROM, BIOS9, BIOS7, firmware, log, ROM tables, game file
        write_reg(32'hF800_2000, 32'd1); write_reg(32'hF800_2004, romsize);
        write_reg(32'hF800_2008, 32'd2); write_reg(32'hF800_200C, s9);
        write_reg(32'hF800_2010, 32'd3); write_reg(32'hF800_2014, s7);
        write_reg(32'hF800_2018, 32'd4); write_reg(32'hF800_201C, sfw);
        write_reg(32'hF800_2020, 32'd9); write_reg(32'hF800_2024, 32'd0);
        write_reg(32'hF800_2028, 32'd5); write_reg(32'hF800_202C, sndt);
        write_reg(32'hF800_2030, 32'd0); write_reg(32'hF800_2034, 32'd0);
        write_reg(32'hF800_2038, 32'd10); write_reg(32'hF800_203C, ssv);   // the save (docs/saves.md)
        if (s9) load_slot(16'd2, 32'h1000_0000, s9, 0);
        if (s7) load_slot(16'd3, 32'h1010_0000, s7, 1);
        if (sfw) load_slot(16'd4, 32'h1020_0000, sfw, 2);
        if (sndt) load_slot(16'd5, 32'h3000_0000, sndt, 3);   // the ROM tables (docs/pocket-plugin.md)
        if (ssv) load_slot(16'd10, 32'h6000_0000, ssv, 4);
        host_command(16'h008F);
        host_command(16'h0011);
        done_loading = 1;
        while (!stop_serving) begin serving = 1; serve_target(); serving = 0; end
        serving = 0;
    end

    // ---------------- video ----------------
    // Reference pictures: every pixel the pattern generator draws, by screen,
    // line and column (the generator stands in for the 2D engines).
    reg [14:0] top_ref [0:191][0:255];
    reg [14:0] bot_ref [0:191][0:255];
    always @(posedge dut.clk_bus) if (dut.screens.gen) begin
        if (dut.screens.scr) bot_ref[dut.screens.n][dut.screens.x] <= dut.screens.pix;
        else top_ref[dut.screens.n][dut.screens.x] <= dut.screens.pix;
    end
    function automatic [23:0] expand(input [14:0] c);
        expand = {c[14:10], c[14:12], c[9:5], c[9:7], c[4:0], c[4:2]};
    endfunction
    integer v_clocks = 0, v_de = 0, v_lines = 0, v_frames = 0, v_errors = 0, v_pix_bad = 0, v_skipped = 0;
    // A stacked frame's buffered half is compared only if no line of it was
    // written late (the core logs those; a late line may show stale data).
    // Only the first stacked frame may have one: the SDRAM is still starting.
    integer late_at_vs = 0;
    reg skip_half = 0;
    integer v_frames_by[0:2];
    initial begin v_frames_by[0] = 0; v_frames_by[1] = 0; v_frames_by[2] = 0; end
    reg de_d = 0, hs_d = 0, vs_d = 0, in_frame = 0;
    reg [1:0] f_layout = 0;
    task automatic verr(input [8*80-1:0] what);
        v_errors++;
        if (v_errors < 8) $display("ERROR video: %0s (frame %0d line %0d clock %0d)", what, v_frames, v_lines, v_clocks);
    endtask
    always @(posedge video_clk) begin
        reg [23:0] want;
        de_d <= video_de; hs_d <= video_hs; vs_d <= video_vs;
        if (!video_de) begin
            if (de_d) begin
                want = {10'd0, f_layout != 0, 13'b0};
                if (video_rgb != want) verr("wrong scaler slot word after DE");
            end else if (video_rgb != 0) verr("RGB outside DE");
        end
        if (video_hs && hs_d) verr("HS longer than one clock");
        if (video_vs && vs_d) verr("VS longer than one clock");
        if (video_vs && !video_hs) verr("VS without HS");
        if (video_de && video_hs) verr("HS inside DE");
        if (video_hs) begin
            if (in_frame && v_de != 0 && v_de != 256) verr("DE line not 256 pixels");
            if (v_de != 0) v_lines++;
            v_clocks = 0; v_de = 0;
        end
        if (video_vs) begin
            if (in_frame) begin
                if (v_lines != (f_layout == 0 ? 384 : 192)) verr("wrong number of DE lines in a frame");
                v_frames++; v_frames_by[f_layout]++;
            end
            in_frame = 1; v_lines = 0; f_layout = dut.screens.layout; late_at_vs = dut.late; skip_half = 0;
        end
        if (video_de && in_frame && f_layout == 0 && v_lines == 192 && v_de == 0 && dut.late != late_at_vs) begin
            skip_half = 1; v_skipped++;
            if (v_frames_by[0] != 0) verr("a buffered line written late after the first stacked frame");
        end
        if (video_de && in_frame && !(skip_half && v_lines >= 192)) begin
            // the picture: stacked = top then bottom; single = that screen
            if (f_layout == 2 || (f_layout == 0 && v_lines >= 192)) want = expand(bot_ref[v_lines % 192][v_de]);
            else want = expand(top_ref[v_lines][v_de]);
            if (video_rgb != want) begin
                v_pix_bad++;
                if (v_pix_bad < 5) $display("ERROR video: layout %0d line %0d x %0d: %h, drawn %h", f_layout, v_lines, v_de, video_rgb, want);
            end
        end
        v_clocks++;
        if (video_de) v_de++;
    end

    // ---------------- controls: SELECT combos, layouts, touch cursor ----------------
    localparam K_UP = 0, K_RIGHT = 3, K_A = 4, K_R = 9, K_L = 8, K_SEL = 14;
    integer ctl_errors = 0;
    reg ctl_done = 0;
    task automatic press(input integer key, input integer ms_hold);
        cont1_key[key] = 1; #(ms_hold * 1ms); cont1_key[key] = 0;
    endtask
    task automatic combo(input integer key);
        cont1_key[K_SEL] = 1; #2ms; press(key, 3); #2ms; cont1_key[K_SEL] = 0; #2ms;
    endtask
    task automatic cerr(input [8*80-1:0] what);
        ctl_errors++; $display("ERROR controls: %0s", what);
    endtask
    task automatic wait_frames(input integer layout, input integer count);
        integer start;
        start = v_frames_by[layout];
        wait (v_frames_by[layout] >= start + count);
    endtask
    initial begin
        integer x0;
        if ($test$plusargs("controls")) begin
            wait_frames(0, 2);
            combo(K_R);
            if (dut.layout_sel != 1) cerr("SELECT+R did not select top only");
            if (dut.ds_keys[K_R] || dut.ds_keys[K_SEL]) cerr("a combo reached the game");
            wait_frames(1, 2);
            combo(K_R);
            if (dut.layout_sel != 2) cerr("SELECT+R did not select bottom only");
            // touch mode: the cursor follows the D-pad, A is the pen, neither reaches the game
            combo(K_L);
            if (!dut.touch) cerr("SELECT+L did not enter touch mode");
            x0 = dut.cur_x;
            // normal speed is 1 px per frame since fe16e3c: 80 ms is ~4.8 frames
            cont1_key[K_RIGHT] = 1; cont1_key[K_A] = 1; #80ms;
            if (dut.cur_x < x0 + 4) cerr("the cursor did not move right");
            if (!dut.pen) cerr("A did not put the pen down");
            if (dut.ds_keys[K_RIGHT] || dut.ds_keys[K_A]) cerr("touch-mode keys reached the game");
            cont1_key[K_RIGHT] = 0; cont1_key[K_A] = 0;
            wait_frames(2, 2);
            combo(K_L);
            if (dut.touch) cerr("SELECT+L did not leave touch mode");
            // a SELECT tap reaches the game as a pulse after release
            cont1_key[K_SEL] = 1; #20ms;
            if (dut.ds_keys[K_SEL]) cerr("a held SELECT reached the game at once");
            #30ms; cont1_key[K_SEL] = 0; #20ms;
            if (!dut.ds_keys[K_SEL]) cerr("a SELECT tap did not reach the game");
            #200ms;
            combo(K_R);
            if (dut.layout_sel != 0) cerr("SELECT+R did not return to stacked");
            wait_frames(0, 1);
        end
        ctl_done = 1;
    end

    // ---------------- every pass B word against the file ----------------
    integer b_bad = 0;
    always @(posedge dut.clk_bus) if (dut.passb.state == 1 && dut.cl_rvalid && !dut.passb.hot && dut.passb.wpos < romsize) begin
        reg [31:0] want;
        want = rom_word(dut.passb.wpos);
        for (integer b = 0; b < 4; b++) if (dut.passb.wpos + b >= romsize) want[b*8 +: 8] = 0;
        if ((dut.cl_rdata & dut.passb.wmask) != want) begin
            b_bad++;
            if (b_bad <= 5) $display("ERROR pass B word at %h: %h, file %h (slot %0d)", dut.passb.wpos, dut.cl_rdata, want, dut.cache.slot);
        end
    end

    // ---------------- progress ----------------
    initial if ($test$plusargs("progress")) forever begin
        #1ms;
        $display("[%0t] loaded %0d sdram_ready %0d allc %0d a_state %0d a_words %0d cache_ready %0d b_state %0d b_bytes %0d cart %0d bflags %h mflags %h served %0d ovf %0d cst %0d mem_busy %0d ps %0d/%0d ph %0d pair %0d chip %0d/%0d n %0d/%0d model %0d/%0d k %0d",
                 $time, done_loading, dut.sdram_ready, dut.dataslot_allcomplete, dut.a_state, dut.a_words,
                 dut.cache_ready, dut.b_state, dut.b_bytes, dut.cart_state, dut.v_bflags, dut.v_mflags, served,
                 dut.f_overflow, dut.cache.st, dut.cache.mem_busy, dut.pstest.state, dut.pstest.passes, dut.pstest.phase,
                 dut.psram.state, dut.psram.chip0.state, dut.psram.chip1.state, dut.psram.n0, dut.psram.n1,
                 cram0.bursting, cram0.n, cram0.k);
    end

    // ---------------- save write-back (+savetest, docs/saves.md) ----------------
    // The game's writes stand in as SDRAM writes; then the Pocket's quit: the
    // size word, 0x0080 for slot 10, and reads, each taking the answer to the
    // read before (sampled just before the next read starts), >= 88 clk_74a
    // apart, in 1 KiB pieces each ending with a dummy read of the next word.
    task automatic save_quit();
        reg [31:0] size, prev, want;
        integer bytes, words, bad, chunk;
        bytes = 0; bad = 0; chunk = 256;
        void'($value$plusargs("savebytes=%d", bytes));
        read_reg(32'hF800_203C, size);
        if (size != bytes) $fatal(1, "save size word %0d, expected %0d", size, bytes);
        words = bytes / 4;
        for (integer k = 0; k < 4; k++) begin
            integer at;
            at = k == 0 ? 0 : k == 1 ? 1 : k == 2 ? words / 3 : words - 1;
            sv[at] = 32'hA5C3_0000 + k * 32'h0101_0101 + at;
            sdram_word(dut.SAVE_BASE_W + at, sv[at]);
        end
        write_reg(32'hF800_0020, 32'd10);
        host_command(16'h0080);
        // in pieces of `chunk` words (1 KiB, as the Pocket does, #265), each
        // followed by a dummy read of the next word, which the next piece then
        // reads again; +savechunk=0 reads all in one piece
        void'($value$plusargs("savechunk=%d", chunk));
        for (integer p0 = 0; p0 < words; p0 += (chunk ? chunk : words)) begin
            integer len;
            len = chunk && words - p0 > chunk ? chunk : words - p0;
            for (integer j = 0; j <= len; j++) begin
                @(negedge clk_74a); prev = bridge_rd_data;
                bridge_addr = 32'h6000_0000 + (p0 + j) * 4; bridge_rd = 1;
                repeat (4) @(negedge clk_74a);
                bridge_rd = 0;
                repeat (84) @(negedge clk_74a);
                if (j > 0) begin
                    integer i;
                    i = p0 + j - 1;
                    // past the loaded file only the written words are known
                    want = sv[i];
                    if ((i < ssv / 4 || i == 0 || i == 1 || i == words / 3 || i == words - 1) && prev != want) begin
                        bad++;
                        if (bad <= 5) $display("ERROR save word %0d: %h, expected %h", i, prev, want);
                    end
                end
            end
        end
        $display("save: %0d bytes exported, %0d wrong, %0d reader errors, %0d runs",
                 bytes, bad, dut.save_read.errors, dut.save_read.runs);
        if (bad || dut.save_read.errors || dut.save_read.runs != 1) $fatal(1, "save write-back errors");
    endtask

    // ---------------- finish ----------------
    integer timeout_ms = 400;
    reg [31:0] logw;
    integer fd;
    initial begin
        void'($value$plusargs("timeout_ms=%d", timeout_ms));
        fork
            begin
                // the cartridge verdict, and at least one full pass of each memory test
                wait (dut.cart_state[1] && dut.v_mflags[1:0] >= 2 && dut.v_bflags[1:0] >= 2
                      && dut.v_mflags[31:16] >= 1 && dut.v_bflags[7:2] != 6'b010101 && ctl_done && v_frames >= 2);
                // let the streams carry the final values into the log
                repeat (20000) @(negedge clk_74a);
            end
            begin
                #(timeout_ms * 1ms);
                $display("TIMEOUT: cart %0d a %0d flags %h mflags %h", dut.cart_state, dut.a_state, dut.v_bflags, dut.v_mflags);
                $fatal(1, "timeout");
            end
        join_any
        disable fork;
        stop_serving = 1;
        wait (!serving);
        if ($value$plusargs("log=%s", fname)) begin
            fd = $fopen(fname, "wb");
            for (integer i = 0; i < 128; i++) begin
                read_bus(32'h4000_0000 + i * 4, logw);
                $fwrite(fd, "%c%c%c%c", logw[7:0], logw[15:8], logw[23:16], logw[31:24]);
            end
            $fclose(fd);
        end
        if (fd_trace) $fclose(fd_trace);
        if ($test$plusargs("savetest")) save_quit();
        if ($test$plusargs("dumplog")) for (integer i = 0; i < 8; i++) $display("log ram %0d %h li %0d", i, dut.log.ram_b[i], dut.log.li);
        $display("video: %0d frames (stacked %0d, top %0d, bottom %0d), %0d timing errors, %0d wrong pixels, %0d stacked halves skipped for a late line; controls errors %0d; buffered lines late %0d, underruns %0d; pass B words wrong: %0d",
                 v_frames, v_frames_by[0], v_frames_by[1], v_frames_by[2], v_errors, v_pix_bad, v_skipped, ctl_errors,
                 dut.late, dut.underruns, b_bad);
        $display("models: sdram errors %0d, cram errors %0d/%0d, cram writes %0d/%0d bursts %0d/%0d",
                 sdram_chip.errors, cram0.errors, cram1.errors, cram0.writes, cram1.writes, cram0.bursts, cram1.bursts);
        if (v_errors || v_pix_bad || v_skipped > 1 || ctl_errors || dut.underruns || b_bad || sdram_chip.errors || cram0.errors || cram1.errors || v_frames < 2) $fatal(1, "model or video errors");
        $display("DONE cart %0d at %0t", dut.cart_state, $time);
        $finish;
    end
endmodule
