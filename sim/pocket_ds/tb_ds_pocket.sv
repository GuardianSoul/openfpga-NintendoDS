// SPDX-License-Identifier: MIT
// The DS core, whole chip (docs/phase2-integration.md, "Tests"): core_top
// (rtl/pocket/core_top_ds.sv) with the pinned APF command handler, Phase 1's
// model of the Pocket's APF firmware on the bridge, and its pin models of the
// SDRAM and both CellularRAMs. sim/pocket_ds/run.py builds and runs it.
//
// The firmware model writes the data table, loads BIOS9/BIOS7/firmware
// through the 0x0082 request-write handshake, sends all-complete, then serves
// every 0x0180 target read (the ROM cache's fetches) from the ROM image.
// Frames on the video pins go to PPM files; at the end the DS test ROMs'
// result block (main RAM 0x023F0000) is read from the PSRAM models.
//
// Plusargs: +rom=HEX +romsize=N +bios9=HEX +bios7=HEX +fw=HEX +fwsize=N +boot=HEX (nds_boot.bin, 12 KiB)
//           +lat=N +wspace=N +twspace=N  host timing in clk_74a clocks (lat/twspace:
//           the ROM cache's target reads: 60 / wspace; +realbridge: the Pocket's measured bridge)
//           +frames=N  stop after N video frames (default 30)
//           +shots=DIR  every frame as DIR/fNNN.ppm (256 x 384 or 256 x 192)
//           +timeout_ms=N
//           +preload  the ROM's first blocks straight into the ROM cache (below)
//           (IMPORT builds) +imp_*=...  a melonDS state (run.py --import, docs/state-import.md)
// SLOTS is the Pocket's ROM cache (12,288 4 KiB slots, core_top_ds's default). NODEBUG
// (run.py --nodebug) builds core_top without its debug log (NDS_DEBUG=0), as the fit:
// the log's frame, instruction and PC counts then read 0.
`ifdef IMPORT
  `define TB_MEM_DIRTY 0
`else
  `define TB_MEM_DIRTY 1
`endif
`ifdef NODEBUG
  `define G_LOG(f) 32'd0
  `define TB_NDS_DEBUG 0
`else
  `define G_LOG(f) dut.g_log.f
  `define TB_NDS_DEBUG 1
`endif
`timescale 1ns/1ps
// the ROM cache instance (core_top_ds SHELL_CPU: nds_cart_scpu; +define+NO_SCPU for nds_cart_cache)
`ifdef NO_SCPU
`define TB_CACHE dut.g_cache.cache
`else
`define TB_CACHE dut.g_scpu.cache
`endif
module tb_ds_pocket;
    parameter integer SLOTS = 12288;
    parameter integer ROM_AW = 24;      // the ROM image's word-address bits (run.py: 64 MiB, or the ROM's size)
    parameter bit PREFETCH = 1;
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

    // run.py --core-param NAME=V: more core_top parameters (", .NAME(V)" each)
`ifndef TB_CORE_PARAMS
`define TB_CORE_PARAMS
`endif
    core_top #(.CACHE_SLOTS(SLOTS), .CACHE_PREFETCH(PREFETCH), .NDS_DEBUG(`TB_NDS_DEBUG), .MEM_DIRTY(`TB_MEM_DIRTY), .MS_CLOCKS(32'd7425) `TB_CORE_PARAMS) dut (
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

    // async SRAM (128K x 16) with the access times Phase 1 measured on the
    // Pocket (phase1-foundation.md): reads sampled 29.9 ns after the address
    // failed and 39.8 ns passed, and WE# needs 39.8 ns too. The model updates
    // its output on falling clk_sys edges, so its age is half a clock (7.45
    // ns) short of the sample's: T_AA 30 stands for 37.45 ns. A shorter
    // access reads garbled data, a shorter WE# pulse stores it inverted.
    sram_model #(.T_AA(30.0), .T_WP(38.0)) u_sram (.clk(dut.clk_sys), .a(sram_a), .dq(sram_dq),
        .oe_n(sram_oe_n), .we_n(sram_we_n), .ub_n(sram_ub_n), .lb_n(sram_lb_n));

    // ---------------- files ----------------
    reg [31:0] rom [0:(1<<ROM_AW)-1];      // 64 MiB unless the ROM is larger (ROM_AW)
    reg [31:0] b9 [0:1023], b7 [0:4095], fw [0:131071], sv [0:262143], bt [0:3071];
    integer romsize = 0, s9 = 4096, s7 = 16384, sfw = 262144, ssv = 0;
    reg [8*256-1:0] fname;

    // ---------------- APF firmware model (Phase 1's) ----------------
    function automatic [31:0] swap(input [31:0] v);
        swap = {v[7:0], v[15:8], v[23:16], v[31:24]};
    endfunction
    // clocks per data word: 40 (540 ns) is still ~4x the Pocket bridge's
    // measured rate (1.75 MB/s). At 16 the FIFO overflowed while the DS drew
    // (NSMB) and dropped ROM-cache data, which hardware never does (its log
    // shows no overflow); an overflow now fails the run.
    integer wspace = 40;
    task automatic write_bus(input [31:0] addr, input [31:0] data);
        @(negedge clk_74a); bridge_addr = addr; bridge_wr_data = data;
        @(negedge clk_74a); bridge_wr = 1;
        @(negedge clk_74a); bridge_wr = 0;
    endtask
    task automatic write_data(input [31:0] addr, input [31:0] data);
        write_bus(addr, data);
        repeat (wspace > 3 ? wspace - 3 : 0) @(negedge clk_74a);
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
            write_data(base + n*4, which == 0 ? b9[n] : which == 1 ? b7[n] : which == 2 ? fw[n] : which == 4 ? bt[n] : sv[n]);
    endtask
    // the ROM cache's target reads (0x0180): by default the fast host (60
    // clocks, then wspace a word), so scene imports release in time.
    // +realbridge: the Pocket's measured bridge, about 0.9 ms per command
    // (docs/sd-probe.md "First hardware result") and about 1 MB/s under load
    // (phase1's pass B: 8 KiB in 7.7 ms): lat 66,825 clk_74a, twspace 297.
    // The fast host is about 1,000x / 7x faster, so ROM-cache misses cost
    // far less than on the Pocket: use +realbridge for boot/load timing.
    integer lat = 60, twspace = -1, served = 0;
    reg [31:0] rtc_d = 0, rtc_t = 0;
    reg [63:0] rtc_v = 0;
    reg rtc2 = 0;
    integer rtc_fr = 0;                    // video frames, for +rtc2
    always @(posedge dut.clk_sys) if (dut.frame_pulse) rtc_fr++;
    function automatic [31:0] rom_word(input integer off);
        reg [31:0] w;
        w = rom[off / 4];
        for (integer b = 0; b < 4; b++) if (off + b >= romsize) w[b*8 +: 8] = 8'hEE;
        rom_word = w;
    endfunction
    task automatic serve_target();
        reg [31:0] status, id, offset, addr, length;
        read_reg(32'hF800_1000, status);
        if (status[31:16] !== 16'h636D) return;
        if (status[15:0] == 16'h0140) begin write_reg(32'hF800_1000, 32'h6F6B_0000); return; end
        if (status[15:0] != 16'h0180) $fatal(1, "APF target opcode %h", status[15:0]);
        read_reg(32'hF800_1020, id); read_reg(32'hF800_1024, offset);
        read_reg(32'hF800_1028, addr); read_reg(32'hF800_102C, length);
        if (id != 1) $fatal(1, "target read of slot %0d", id);
        if (length == 0 || offset + length > romsize) $fatal(1, "target read outside the file: offset %h length %0d", offset, length);
        if (addr != 32'h2000_0000) $fatal(1, "target read to bridge %h", addr);
        write_reg(32'hF800_1000, 32'h6275_0000);
        repeat (lat) @(negedge clk_74a);
        served++;
        for (integer n = 0; n < (length + 3) / 4; n++) begin
            write_bus(addr + n*4, rom_word(offset + n*4));
            repeat (twspace > 3 ? twspace - 3 : 0) @(negedge clk_74a);
        end
        write_reg(32'hF800_1000, 32'h6F6B_0000);
    endtask

    reg done_loading = 0, stop_serving = 0, serving = 0;
    initial begin
        if (!$value$plusargs("rom=%s", fname)) $fatal(1, "+rom= missing");
        $readmemh(fname, rom);
        if (!$value$plusargs("romsize=%d", romsize)) $fatal(1, "+romsize= missing");
        if ($value$plusargs("bios9=%s", fname)) $readmemh(fname, b9); else $fatal(1, "+bios9= missing");
        if ($value$plusargs("bios7=%s", fname)) $readmemh(fname, b7); else $fatal(1, "+bios7= missing");
        if ($value$plusargs("fw=%s", fname)) $readmemh(fname, fw); else $fatal(1, "+fw= missing");
        if ($value$plusargs("boot=%s", fname)) $readmemh(fname, bt); else $fatal(1, "+boot= missing");   // nds_boot.bin (ID 12)
        void'($value$plusargs("fwsize=%d", sfw));
        if ($test$plusargs("realbridge")) begin lat = 66825; twspace = 297; end
        void'($value$plusargs("lat=%d", lat));
        void'($value$plusargs("twspace=%d", twspace));
        void'($value$plusargs("wspace=%d", wspace));
        if (twspace < 0) twspace = wspace;
        if ($value$plusargs("sav=%s", fname)) begin $readmemh(fname, sv); void'($value$plusargs("savsize=%d", ssv)); end
        repeat (400) @(negedge clk_74a);
        write_reg(32'hF800_2000, 32'd1); write_reg(32'hF800_2004, romsize);
        write_reg(32'hF800_2008, 32'd2); write_reg(32'hF800_200C, s9);
        write_reg(32'hF800_2010, 32'd3); write_reg(32'hF800_2014, s7);
        write_reg(32'hF800_2018, 32'd4); write_reg(32'hF800_201C, sfw);
        write_reg(32'hF800_2020, 32'd9); write_reg(32'hF800_2024, 32'd0);
        write_reg(32'hF800_2028, 32'd5); write_reg(32'hF800_202C, 32'd0);
        write_reg(32'hF800_2030, 32'd10); write_reg(32'hF800_2034, ssv);   // the save (docs/saves.md)
        write_reg(32'hF800_2038, 32'd12); write_reg(32'hF800_203C, 32'd12288);   // the boot ROM (package.py: last)
        if (ssv) load_slot(16'd10, 32'h6000_0000, ssv, 3);
        load_slot(16'd2, 32'h1000_0000, s9, 0);
        load_slot(16'd3, 32'h1010_0000, s7, 1);
        load_slot(16'd4, 32'h1020_0000, sfw, 2);
        load_slot(16'd12, 32'h1030_0000, 12288, 4);
`ifdef IMPORT
        // a table as the plugin gives one (all read-ahead 0), so the firmware doesn't clear it word by word and
        // the release stays where the scenes expect it
        for (integer b = 0; b < (romsize + 4095) / 4096; b++) sd_poke32(PL_TABLE_W + b, 32'd0);
        write_bus(32'h3000_0000, 32'h3154_444E); write_bus(32'h3000_0004, 32'd1); write_bus(32'h3000_000C, romsize);
`endif
        host_command(16'h008F);
        // +rotation=N: the Core Setting "Rotation" written as the Pocket's menu does (docs/screen-orientation.md)
        begin
            integer rot;
            if ($value$plusargs("rotation=%d", rot)) write_reg(32'h5000_0010, rot);
            // +gest_a/b/x/y=N: the Core Settings "A/B/X/Y in Touch Mode" (tools/ds/settings.py)
            if ($value$plusargs("gest_a=%d", rot)) write_reg(32'h5000_001C, rot);
            if ($value$plusargs("gest_b=%d", rot)) write_reg(32'h5000_0020, rot);
            if ($value$plusargs("gest_x=%d", rot)) write_reg(32'h5000_0024, rot);
            if ($value$plusargs("gest_y=%d", rot)) write_reg(32'h5000_0028, rot);
        end
        // +rtc=DDDDDDDDTTTTTTTT (hex: BCD date 0xYYYYMMDD, time 0x00HHMMSS): the APF RTC command; +rtc2=... a
        // second one after the DS has started (the core keeps the first: core_bridge_cmd_lean). Without +rtc
        // the Pocket's command comes anyway, as on hardware (2026-10-23 12:00:00, as tb_ds), so the boot program
        // sets the RTC without waiting for it; +nortc: no RTC command (the boot program's 0.1 s wait, then none)
        if (!$value$plusargs("rtc=%h", rtc_v)) rtc_v = 64'h2026_1023_0012_0000;
        if (!$test$plusargs("nortc")) begin
            rtc_d = rtc_v[63:32]; rtc_t = rtc_v[31:0];
            write_reg(32'hF800_0020, 32'd0); write_reg(32'hF800_0024, rtc_d); write_reg(32'hF800_0028, rtc_t);
            host_command(16'h0090);
        end
        host_command(16'h0011);
        done_loading = 1;
        rtc2 = $value$plusargs("rtc2=%h", rtc_v);
        rtc_d = rtc_v[63:32]; rtc_t = rtc_v[31:0];
        $display("[%0t] slots loaded", $time);
        while (!stop_serving) begin
            serving = 1; serve_target(); serving = 0;
            if (rtc2 && rtc_fr >= 3) begin
                rtc2 = 0;
                write_reg(32'hF800_0020, 32'd0); write_reg(32'hF800_0024, rtc_d); write_reg(32'hF800_0028, rtc_t);
                host_command(16'h0090);
                $display("[%0t] rtc2 sent", $time);
            end
        end
        serving = 0;
    end

    // ---------------- video: frames to PPM ----------------
    reg [23:0] frame [0:384*256-1];
    integer v_x = 0, v_y = 0, v_frames = 0, v_errors = 0, nshot = 0;
    // DS lines the display missed (core_top's stat_late: nds_disp skipped a line's BG job, a pulse per line)
    integer late2d = 0, late2d_seen = 0;
    always @(posedge dut.clk_sys) if (dut.stat_late) late2d++;
    // 3D frames the game finished (the geometry engine's swap: nds_gpu3d diag_g_ev[4]), for scenes.py's pace check
    integer g3swaps = 0;
    always @(posedge dut.clk_sys) if (dut.diag_g_ev[4]) g3swaps++;
`ifdef DIAG_MON
    // NDSDiag check (DIAG=1, docs/diag.md): the recorder's taps counted here by name, each at its documented
    // index, cumulative, printed at every frame_pulse ("diagmon F c0 .. c48 | v0 .. v5"); the clk_mem ones on
    // clk_mem. sim/pocket_ds/diag_check.py compares them with the log read back at quit (+diagout)
    longint dm_c [0:48];
    initial for (int i = 0; i < 49; i++) dm_c[i] = 0;
    integer dm_f = 0, dm_l2d = 0;
    reg dm_cmd_d = 0;
    always @(posedge dut.clk_sys) begin
        for (int i = 0; i < 11; i++) if (dut.diag_r_ev[i]) dm_c[i]++;
        for (int i = 0; i < 8; i++)  if (dut.diag_g_ev[i]) dm_c[11 + i]++;
        for (int i = 0; i < 10; i++) if (dut.diag_c_ev[i]) dm_c[19 + i]++;
        for (int i = 0; i < 5; i++)  if (dut.diag_d_ev[i]) dm_c[29 + i]++;
        if (dut.vm_req && dut.vm_blk && !dut.vm_we && dut.vm_ack) dm_c[34]++;
        if (dut.mr_req && dut.mr_ack) dm_c[35]++;
        if (dut.mr_req && !dut.mr_ack) dm_c[36]++;
        if (dut.rg_wreq && !dut.rg_wack) dm_c[37]++;
        if (dut.rg_rreq && !dut.rg_rack) dm_c[38]++;
        if (!dut.bw_empty) dm_c[39]++;
        if (`TB_CACHE.dg_wait) dm_c[40]++;                     // (by the cache's own clk_bus signals)
        if (`TB_CACHE.dg_cmd && !dm_cmd_d) dm_c[41]++;
        dm_cmd_d <= `TB_CACHE.dg_cmd;
        if (dut.diag_l2d_v) dm_l2d++;
        if (dut.frame_pulse) begin
            string l;
            dm_f++;
            l = $sformatf("diagmon %0d", dm_f);
            for (int i = 0; i < 49; i++) l = {l, $sformatf(" %0d", dm_c[i])};
            $display("%s | %0d %0d %0d %0d late2d %0d", l, dut.g_diag.dsf, dut.diag_g_val, dut.underruns, dut.diag_g_used, dm_l2d);
        end
    end
    always @(posedge dut.clk_mem) begin
        for (int p = 0; p < 5; p++) if (dut.p_valid[p] && !dut.p_take[p]) dm_c[42 + p]++;
        if (dut.p_valid[6] && !dut.p_take[6]) dm_c[47]++;
        if (dut.sd_ref_late) dm_c[48]++;
    end
`endif
    // nds_video's output phase (scripts/build_ds.sh's o_rgb window): its outputs may change only on the
    // clk_sys edge midway between clk_vid edges, so o_* (clk_vid) take each value two clk_sys clocks after
    // it changed, never on the edge it changes
    realtime vph_ch = -1000;               // (no change before time 0)
    reg [26:0] vph_q = 0;
    integer vph_bad = 0;
    always @(posedge dut.clk_sys) #1 if ({dut.s_rgb, dut.s_de, dut.s_hs, dut.s_vs} != vph_q) begin
        vph_q = {dut.s_rgb, dut.s_de, dut.s_hs, dut.s_vs}; vph_ch = $realtime - 1;
    end
    always @(posedge dut.clk_vid) #2 if ($realtime - 2 - vph_ch < 29.0) begin
        v_errors++; vph_bad++;
        if (vph_bad < 5) $display("ERROR video: nds_video output changed %0.3f ns before a clk_vid edge", $realtime - 2 - vph_ch);
    end
    reg de_d = 0;
    reg [8*256-1:0] shots;
    reg have_shots = 0;
    initial have_shots = $value$plusargs("shots=%s", shots);
    task automatic write_ppm(input integer lines);
        integer fd;
        reg [8*300-1:0] name;
        $sformat(name, "%0s/f%03d.ppm", shots, nshot);
        fd = $fopen(name, "wb");
        $fwrite(fd, "P6\n256 %0d\n255\n", lines);
        for (integer i = 0; i < 256 * lines; i++) $fwrite(fd, "%c%c%c", frame[i][23:16], frame[i][15:8], frame[i][7:0]);
        $fclose(fd);
        nshot++;
    endtask
    // The APF scaler as openfpga-PlayStation measured it: the first DE line after VS is
    // dropped, and an HS less than 3 clocks after VS is an error
    reg drop1 = 0;
    integer since_vs = 99;
    // the APF scaler slot word: the pixel clock after DE falls carries the slot in RGB[23:13] (the last one seen)
    integer v_slot = -1;
    always @(posedge video_clk) if (de_d && !video_de) v_slot <= video_rgb[23:13];
    always @(posedge video_clk) begin
        de_d <= video_de;
        since_vs = video_vs ? 0 : since_vs + 1;
        if (video_hs && since_vs < 3) begin v_errors++; if (v_errors < 5) $display("ERROR video: HS %0d clocks after VS", since_vs); end
        if (video_de && video_hs) begin v_errors++; if (v_errors < 5) $display("ERROR video: HS inside DE"); end
        if (video_vs) begin
            if (v_y != 0) begin
                // an even number of DE lines (the dropped one included), else
                // the scaler leaves part of a top row unwritten (openfpga-PlayStation
                // EVEN_LINES); the picture is 384 or 192 lines and a pad line
                if (v_y != 385 && v_y != 193) begin v_errors++; if (v_errors < 5) $display("ERROR video: %0d DE lines in a frame", v_y + 1); end
                if (have_shots && !stop_serving) write_ppm(v_y - 1);   // (none during the quit read-backs)
                v_frames++;
                $display("[%0t] video frame %0d: %0d lines; DS frames %0d, retired 9:%0d 7:%0d, pc 9:%h 7:%h, cache fetches %0d",
                         $time, v_frames, v_y, `G_LOG(frames), `G_LOG(ret9), `G_LOG(ret7), `G_LOG(pc9), `G_LOG(pc7), served);
                if (late2d != late2d_seen) $display("g2d LATE: %0d 2D lines late in the last frame, %0d so far", late2d - late2d_seen, late2d);
                late2d_seen = late2d;
                $display("g3d swaps: %0d at video frame %0d", g3swaps, v_frames);
            end
            v_y = 0;
            drop1 = 1;
        end
        if (video_de) begin
            if (v_y < 384) frame[v_y * 256 + v_x] = video_rgb;
            v_x = v_x + 1;
        end else if (de_d) begin
            if (v_x != 256) begin v_errors++; if (v_errors < 5) $display("ERROR video: %0d pixels in a line", v_x); end
            v_x = 0;
            if (drop1) drop1 = 0; else v_y = v_y + 1;
        end
    end

    // ---------------- stalls and waveforms ----------------
    // A CPU that retires nothing for 2 ms is reported once (time of its last
    // retirement). +fst=FILE +fst_from_us=N [+fst_us=N]: an FST window
    // (run.py --fst builds with --trace-fst).
    realtime last_ret [0:1];
    bit stall_rep [0:1];
    initial begin last_ret[0] = 0; last_ret[1] = 0; stall_rep[0] = 0; stall_rep[1] = 0; end

`ifdef IMPORT
    // ---------------- state import (docs/state-import.md, run.py --import) ----------------
    // As tb_ds --import-state, with the Pocket's memories: when the core starts (go), main RAM
    // (with the restore stub overlaid) goes into the two CellularRAM models (die 0, word w at
    // chip address w: chip 0 the low halfword), VRAM into the SDRAM model (VRAM-port word w is
    // SDRAM word w, nds_vm_split BASE_W 0), both WRAMs into the SRAM model (word w at halfwords
    // 2w, 2w+1). core_top is built with MEM_DIRTY 0, so the boot ROM's import check runs. When
    // both stubs' ready words are 1, 4,000 clk_sys later and at the start of the state's line,
    // main RAM's own words go back over the overlay and the block, and the DS keys are held
    // all down (KEYINPUT 0, forced past nds_controls' shell combos) for 400 clk_sys.
    reg [31:0] imp_main [0:(1<<20)-1];
    reg [31:0] imp_real [0:(1<<20)-1];
    reg [31:0] imp_vram [0:32'h29000-1];
    reg [31:0] imp_sram [0:32'h6000-1];
    integer imp_ready9, imp_ready7, imp_vc, imp_ov, imp_ovn, imp_blk, imp_blkn, imp_stubn = 0, imp_frame = -1, imp_hold;
    bit imp_stub_pend = 0;
    reg [8*256-1:0] imp_f, imp_f2;
    initial if ($value$plusargs("imp_main=%s", imp_f)) begin
        reg [8*256-1:0] f2;
        $readmemh(imp_f, imp_main);
        void'($value$plusargs("imp_real=%s", f2)); $readmemh(f2, imp_real);
        void'($value$plusargs("imp_vram=%s", f2)); $readmemh(f2, imp_vram);
        void'($value$plusargs("imp_sram=%s", f2)); $readmemh(f2, imp_sram);
        void'($value$plusargs("imp_ready9=%h", imp_ready9)); void'($value$plusargs("imp_ready7=%h", imp_ready7));
        void'($value$plusargs("imp_vcount=%d", imp_vc));
        void'($value$plusargs("imp_ov=%h", imp_ov)); void'($value$plusargs("imp_ovn=%h", imp_ovn));
        void'($value$plusargs("imp_blk=%h", imp_blk)); void'($value$plusargs("imp_blkn=%h", imp_blkn));
        void'($value$plusargs("imp_stubn=%h", imp_stubn));   // the stub's words: back once the ARM9 has left them (its return path)
        @(posedge dut.go);
        for (integer w = 0; w < (1 << 20); w++) begin
            cram0.mem[w] = imp_main[w][15:0]; cram1.mem[w] = imp_main[w][31:16];
        end
        for (integer w = 0; w < 32'h29000; w++) sd_poke32(w, imp_vram[w]);
        for (integer w = 0; w < 32'h6000; w++) begin u_sram.mem[2 * w] = imp_sram[w][15:0]; u_sram.mem[2 * w + 1] = imp_sram[w][31:16]; end
        $display("import: memories loaded at %0t; release at line %0d", $time, imp_vc);
        while (!({cram1.peek(imp_ready9), cram0.peek(imp_ready9)} == 1 && {cram1.peek(imp_ready7), cram0.peek(imp_ready7)} == 1))
            @(posedge dut.clk_sys);
        $display("import: stubs done at %0t (line %0d)", $time, dut.vcount);
        repeat (4000) @(posedge dut.clk_sys);
        while (!(dut.line_start && dut.vcount == imp_vc)) @(posedge dut.clk_sys);
        for (integer w = imp_ov + imp_stubn; w < imp_ov + imp_ovn; w++) begin cram0.mem[w] = imp_real[w][15:0]; cram1.mem[w] = imp_real[w][31:16]; end
        for (integer w = imp_blk; w < imp_blk + imp_blkn; w++) begin cram0.mem[w] = imp_real[w][15:0]; cram1.mem[w] = imp_real[w][31:16]; end
        force dut.keys = 12'h3FF;
        imp_stub_pend = imp_stubn != 0;
        repeat (400) @(posedge dut.clk_sys);
        release dut.keys;
        // +hold=HEX: the scene's held keys (scenes.py hold=: core_top's keys, DS order, pressed = 1) from the release on
        if ($value$plusargs("hold=%h", imp_hold)) force dut.keys = imp_hold[11:0];
        imp_frame = v_frames;
        $display("import: released at %0t, video frame %0d", $time, v_frames);
    end
`endif

    // ---------------- +preload: the ROM in the ROM cache before the first fetch ----------------
    // Once nds_cart_cache has cleared its table and owners (cache_ready), the ROM's first
    // min(blocks, SLOTS) 4 KiB blocks go straight into the SDRAM model: block b in slot b, its
    // table entry cached (read-ahead bits kept), slot b's owner entry used. The cache then
    // fetches only blocks beyond those; its CLOCK hand starts at slot 0 and evicts as usual.
    // (nds_cart_cache's default layout, word addresses; the SDRAM model's byte map is
    // nds_sdram_mc's: column [9:1] + A9 [25], row [22:10], bank [24:23].)
    localparam [23:0] PL_TABLE_W = 24'h30_0000, PL_OWNER_W = 24'h34_0000, PL_CACHE_W = 24'h40_0000;
    function automatic int sd_index(input [25:0] byte_a);
        sd_index = sdram_chip.index(byte_a[24:23], byte_a[22:10], {byte_a[25], byte_a[9:1]});
    endfunction
    task automatic sd_poke32(input [23:0] w, input [31:0] d);
        sdram_chip.mem[sd_index({w, 2'b00})] = d[15:0];
        sdram_chip.mem[sd_index({w, 2'b10})] = d[31:16];
    endtask
    function automatic [31:0] sd_peek32(input [23:0] w);
        sd_peek32 = {sdram_chip.peek(sd_index({w, 2'b10})), sdram_chip.peek(sd_index({w, 2'b00}))};
    endfunction
    integer pl_blocks = 0;
    initial if ($test$plusargs("preload")) begin
        @(posedge dut.cache_ready);
        pl_blocks = (romsize + 4095) / 4096;
        if (pl_blocks > SLOTS) pl_blocks = SLOTS;
        for (integer b = 0; b < pl_blocks; b++) begin
            sd_poke32(PL_TABLE_W + b, (sd_peek32(PL_TABLE_W + b) & 32'hE000_0000) | 32'h0001_0000 | b);
            sd_poke32(PL_OWNER_W + b, 32'h8000_0000 | b);
            for (integer i = 0; i < 1024; i++) sd_poke32(PL_CACHE_W + 1024 * b + i, rom_word(b * 4096 + i * 4));
        end
        $display("preload: %0d blocks of %0d (%0d bytes) in the ROM cache at %0t", pl_blocks, (romsize + 4095) / 4096, romsize, $time);
    end
    // The card ROM's read words (nds_cart_cache r_data, clk_bus) reach
    // nds_cart (clk_sys) through x_cart, whose s_rvalid needs take: only on
    // the clk_sys edges between clk_bus edges. build_ds.sh relaxes the hold
    // check at the coincident edge on that, so a word there is an error.
    // Sampled mid-cycle (falling clk_sys, never a clk_bus edge): clk_bus low
    // there means this clk_sys cycle began on a clk_bus fall, so it ends on
    // a clk_bus rise, where nds_cart would take the word.
    integer cart_words = 0, cart_errors = 0;
    always @(negedge dut.clk_sys) if (dut.x_cart.s_rvalid) begin
        cart_words++;
        if (!dut.clk_bus) begin
            cart_errors++; if (cart_errors < 5) $display("[%0t] ERROR: cart: a read word taken on a clk_bus edge", $time);
        end
    end
    always @(posedge dut.clk_sys) if (dut.dbg_retire) begin last_ret[dut.dbg_tid] = $realtime; stall_rep[dut.dbg_tid] = 0; end
`ifdef IMPORT
    // the import: the stub's own words (the ARM9's return path) once the ARM9 retires outside them
    always @(posedge dut.clk_sys) if (imp_stub_pend && dut.dbg_retire && !dut.dbg_tid &&
                                      (dut.dbg_pc[21:2] < imp_ov || dut.dbg_pc[21:2] >= imp_ov + imp_stubn || dut.dbg_pc[31:24] != 8'h02)) begin
        for (integer w = imp_ov; w < imp_ov + imp_stubn; w++) begin cram0.mem[w] = imp_real[w][15:0]; cram1.mem[w] = imp_real[w][31:16]; end
        imp_stub_pend = 0;
    end
`endif
    initial forever begin
        #100us;
        for (int c = 0; c < 2; c++)
            if (!stall_rep[c] && $realtime - last_ret[c] > 2ms && last_ret[c] > 0) begin
                stall_rep[c] = 1;
                $display("[%0t] STALL ARM%0d: nothing retired since %0t (pc %h)", $time, c ? 7 : 9,
                         last_ret[c], c ? `G_LOG(pc7) : `G_LOG(pc9));
            end
    end
    // +pctrace=FILE +pctrace_from=N +pctrace_n=M: the ARM9's retired PCs
    // (32-bit little-endian words) from its Nth retirement on, for comparing
    // with tb_ds --trace-dir (sim/pocket_ds/pccmp.py)
    // +dump_pc=HEX +dump_file=F: main RAM (4 MiB, from the PSRAM models)
    // when the ARM9 first retires that PC
    string dump_file;
    reg [31:0] dump_pc = 0;
    // +vmcheck: every word read on the DS core's VRAM port (vm_*: nds_vram to
    // the SDRAM path) against a shadow of every word written there; a
    // mismatch is the SDRAM path's (nds_vm_split, nds_sdram_xport/bus/mc).
    bit vmc_on = 0;
    initial vmc_on = $test$plusargs("vmcheck");
    logic [31:0] vmc_sh [int];
    longint vmc_q [$];                      // word address of each read word still to come
    int vmc_bad = 0, vmc_n = 0;
    always @(posedge dut.clk_sys) if (vmc_on) begin
        if (dut.vm_rvalid && vmc_q.size() != 0) begin
            longint a; logic [31:0] e;
            a = vmc_q.pop_front(); e = vmc_sh.exists(a) ? vmc_sh[a] : 32'd0; vmc_n++;
            if (dut.vm_rdata !== e && vmc_sh.exists(a)) begin
                vmc_bad++;
                if (vmc_bad <= 10) $display("[%0t] ERROR: vmcheck: VRAM word %06x read %08x, written %08x", $time, a << 2, dut.vm_rdata, e);
            end
        end
        if (dut.vm_req && dut.vm_ack) begin
            if (dut.vm_we) begin
                logic [31:0] w;
                w = vmc_sh.exists(dut.vm_addr) ? vmc_sh[dut.vm_addr] : 32'd0;
                for (int b = 0; b < 4; b++) if (dut.vm_be[b]) w[b*8 +: 8] = dut.vm_wdata[b*8 +: 8];
                vmc_sh[dut.vm_addr] = w;
            end else if (dut.vm_blk) for (int k = 0; k < 8; k++) vmc_q.push_back({dut.vm_addr[20:5], 3'(k)});
            else vmc_q.push_back(dut.vm_addr);
        end
    end
    final if (vmc_on) $display("vmcheck: %0d words read, %0d mismatches", vmc_n, vmc_bad);

    // +vmlat=F: from video frame F on, the VRAM block port's latency as the
    // DS core sees it (clk_sys): request -> ack, ack -> 8th word, request ->
    // 8th word, per block read; histograms at the end, for tb_ds's --vlat /
    // --jitter / --stall (docs/phase2-integration.md "Pocket VRAM latency")
    integer vml_from = -1;
    initial void'($value$plusargs("vmlat=%d", vml_from));
    longint vml_cyc = 0;
    longint vml_q [$];                       // per block in flight: request cycle, then ack cycle
    longint vml_rq, vml_ak [$];
    integer vml_w = 0, vml_n = 0;
    integer vml_h_ack [0:255], vml_h_tail [0:255], vml_h_tot [0:255];
    logic   vml_pend = 0;
    initial for (int i = 0; i < 256; i++) begin vml_h_ack[i] = 0; vml_h_tail[i] = 0; vml_h_tot[i] = 0; end
    always @(posedge dut.clk_sys) begin
        vml_cyc++;
        if (vml_from >= 0 && v_frames >= vml_from) begin
            if (dut.vm_req && dut.vm_blk && !dut.vm_we && !vml_pend) begin vml_pend = 1; vml_rq = vml_cyc; end
            if (dut.vm_ack && vml_pend && dut.vm_blk && !dut.vm_we) begin
                vml_pend = 0;
                vml_q.push_back(vml_rq); vml_ak.push_back(vml_cyc);
                vml_h_ack[(vml_cyc - vml_rq) > 255 ? 255 : (vml_cyc - vml_rq)]++;
            end
            if (dut.vm_rvalid && vml_q.size() != 0) begin
                vml_w++;
                if (vml_w == 8) begin
                    longint r, a;
                    r = vml_q.pop_front(); a = vml_ak.pop_front(); vml_w = 0; vml_n++;
                    vml_h_tail[(vml_cyc - a) > 255 ? 255 : (vml_cyc - a)]++;
                    vml_h_tot[(vml_cyc - r) > 255 ? 255 : (vml_cyc - r)]++;
                end
            end
        end
    end
    task automatic vml_print();
        if (vml_from < 0) return;
        $display("vmlat: %0d block reads from video frame %0d (clk_sys; value: count)", vml_n, vml_from);
        for (int h = 0; h < 3; h++) begin
            string l;
            l = h == 0 ? "req->ack " : h == 1 ? "ack->8th " : "req->8th ";
            for (int i = 0; i < 256; i++) begin
                integer c;
                c = h == 0 ? vml_h_ack[i] : h == 1 ? vml_h_tail[i] : vml_h_tot[i];
                if (c != 0) l = {l, $sformatf(" %0d:%0d", i, c)};
            end
            $display("vmlat %s", l);
        end
    endtask

    // +dump_frame=D +dump_file=F: main RAM the same way at video frame D after an import's release (melonDS's
    // frame D past the export: sim/pocket_ds/w2load.sh); main RAM only, not lines still dirty in the ARM9's cache
    integer dump_frame = -1;
`ifndef IMPORT
    integer imp_frame = -1;   // (a cold boot has no import release: +dump_frame never fires)
`endif
    initial if ($value$plusargs("dump_pc=%h", dump_pc) | $value$plusargs("dump_frame=%d", dump_frame))
        void'($value$plusargs("dump_file=%s", dump_file));
    always @(posedge dut.clk_sys) if (dump_pc != 0 && dut.dbg_retire && !dut.dbg_tid && dut.dbg_pc == dump_pc
                                      || dump_frame >= 0 && imp_frame >= 0 && v_frames == imp_frame + dump_frame) begin
        integer fd;
        reg [31:0] w;
        dump_pc = 0;
        dump_frame = -1;
        fd = $fopen(dump_file, "wb");
        for (int i = 0; i < (1 << 20); i++) begin
            w = ram_word(i);
            $fwrite(fd, "%c%c%c%c", w[7:0], w[15:8], w[23:16], w[31:24]);
        end
        $fclose(fd);
        $display("[%0t] main RAM dumped", $time);
    end
    // +touchtest=F: from DS frame F, SELECT+A (touch mode), then RIGHT held 8
    // frames and DOWN held 8: touch mode must be on, the cursor must have
    // moved at least 12 px each way (2 px per frame), and the touchscreen
    // controller's coordinates must be the cursor's. Prints TOUCH PASS/FAIL.
    // +onescreen: SELECT+R at the first DS frame (stacked -> top only), for the one-screen scaler slots (1, or
    // 4/5 rotated)
    initial if ($test$plusargs("onescreen")) begin
        wait (ds_frame == 1);
        cont1_key[14] = 1'b1; #20us; cont1_key[9] = 1'b1; #200us; cont1_key[9] = 1'b0; #20us; cont1_key[14] = 1'b0;
    end
    integer tt_from = 0, ds_frame = 0;
    initial void'($value$plusargs("touchtest=%d", tt_from));
    always @(posedge dut.clk_sys) if (dut.frame_pulse) ds_frame <= ds_frame + 1;
    initial if (tt_from > 0) begin
        reg [7:0] x0, y0;
        wait (ds_frame == tt_from);
        cont1_key[14] = 1'b1; #20us; cont1_key[4] = 1'b1; #200us; cont1_key[4] = 1'b0; #20us; cont1_key[14] = 1'b0;
        wait (ds_frame == tt_from + 2);
        x0 = dut.cur_x; y0 = dut.cur_y;
        cont1_key[3] = 1'b1; wait (ds_frame == tt_from + 10); cont1_key[3] = 1'b0;
        cont1_key[1] = 1'b1; wait (ds_frame == tt_from + 18); cont1_key[1] = 1'b0;
        #10us;
        $display("TOUCH touch %0d cursor %0d,%0d -> %0d,%0d, touchscreen %0d,%0d", dut.touch, x0, y0,
                 dut.cur_x, dut.cur_y, dut.ds.u_spi.tx, dut.ds.u_spi.ty);
        $display("TOUCH %s", dut.touch && dut.cur_x >= x0 + 8'd12 && dut.cur_y >= y0 + 8'd12
                 && dut.ds.u_spi.tx == dut.cur_x && dut.ds.u_spi.ty == dut.cur_y ? "PASS" : "FAIL");
    end
    // +gesturetest=F: from video frame F, SELECT+A (touch mode), then B pressed for 2 frames and, from F+20,
    // X held for 16 (with +gest_b/+gest_x set, two gestures; docs/touch-gestures.md). Prints the pen and the
    // touchscreen controller's coordinates at each frame from F+2 to F+40 (GEST lines). Touch mode and the
    // pen need no running DS, so a cold boot can run it from its first frames.
    integer gt_from = 0;
    initial void'($value$plusargs("gesturetest=%d", gt_from));
    initial if (gt_from > 0) begin
        wait (ds_frame == gt_from);
        cont1_key[14] = 1'b1; #20us; cont1_key[4] = 1'b1; #200us; cont1_key[4] = 1'b0; #20us; cont1_key[14] = 1'b0;
        wait (ds_frame == gt_from + 3); cont1_key[5] = 1'b1;
        wait (ds_frame == gt_from + 5); cont1_key[5] = 1'b0;
        wait (ds_frame == gt_from + 20); cont1_key[6] = 1'b1;
        wait (ds_frame == gt_from + 36); cont1_key[6] = 1'b0;
    end
    always @(posedge dut.clk_sys) if (gt_from > 0 && dut.frame_pulse && ds_frame >= gt_from + 2 && ds_frame <= gt_from + 40)
        $display("GEST %0d touch %0d pen %0d cursor %0d,%0d touchscreen %0d,%0d", ds_frame - gt_from, dut.touch, dut.pen,
                 dut.cur_x, dut.cur_y, dut.ds.u_spi.tx, dut.ds.u_spi.ty);
    // +wwatch=HEX: main-RAM writes to the 64-byte window at that byte
    // address, as the fabric issues them, as the PSRAM port takes them (both
    // clk_sys) and as nds_psram writes them (clk_mem)
    reg [31:0] wwatch = 0;
    initial void'($value$plusargs("wwatch=%h", wwatch));
    always @(posedge dut.clk_sys) if (wwatch != 0 && dut.ds.u_fab.mr_req && dut.ds.u_fab.mr_we && dut.ds.u_fab.mr_ack
                                      && dut.ds.u_fab.mr_addr[21:6] == wwatch[21:6])
        $display("[%0t] WW fabric  %06x <= %08x be %x", $time, {dut.ds.u_fab.mr_addr, 2'b00}, dut.ds.u_fab.mr_wdata, dut.ds.u_fab.mr_be);
    always @(posedge dut.clk_sys) if (wwatch != 0 && dut.mr_req && dut.mr_we && dut.mr_ack && dut.mr_addr[21:6] == wwatch[21:6])
        $display("[%0t] WW port    %06x <= %08x be %x", $time, {dut.mr_addr, 2'b00}, dut.mr_wdata, dut.mr_be);
    always @(posedge dut.clk_mem) if (wwatch != 0 && dut.psram.state == 4'd4 && dut.psram.b_word[19:4] == wwatch[21:6])
        $display("[%0t] WW psram  word %06x <= %08x be %x", $time, dut.psram.b_word, dut.psram.b_wdata, dut.psram.b_be);
    // +cwatch=HEX: ROM reads of the 64-byte window at that ROM offset: the
    // cache's client answers (clk_bus) and the words the cart takes (clk_sys)
    reg [31:0] cwatch = 0;
    initial void'($value$plusargs("cwatch=%h", cwatch));
    always @(posedge dut.clk_bus) if (cwatch != 0 && dut.cl_rvalid && `TB_CACHE.qaddr[31:6] == cwatch[31:6])
        $display("[%0t] CW cache   quad %06x word %08x (slot %0d, st %0d)", $time, `TB_CACHE.qaddr, dut.cl_rdata, `TB_CACHE.last_slot, `TB_CACHE.st);
    always @(posedge dut.clk_sys) if (cwatch != 0 && dut.ds.u_cart.cr_rvalid && dut.ds.u_cart.raddr[31:6] == cwatch[31:6])
        $display("[%0t] CW cart    raddr %06x fw %0d word %08x", $time, dut.ds.u_cart.raddr, dut.ds.u_cart.fw, dut.ds.u_cart.cr_rdata);
    always @(posedge dut.clk_sys) if (cwatch != 0 && dut.ds.u_cart.cr_req && dut.ds.u_cart.cr_ack && dut.ds.u_cart.cr_addr[31:6] == cwatch[31:6])
        $display("[%0t] CW cart    request quad %06x", $time, {dut.ds.u_cart.cr_addr, 4'd0});
    // +swatch=HEX: SDRAM word address window (8 words): bridge data into the
    // write FIFO (clk_74a), the drain's SDRAM writes (clk_bus); FIFO overflow
    reg [23:0] swatch = 0;
    initial void'($value$plusargs("swatch=%h", swatch));
    always @(posedge dut.clk_74a) if (swatch != 0 && dut.f_wr && dut.f_wdata[55:35] == swatch[23:3])
        $display("[%0t] SW fifo in  %06x <= %08x (full %0d)", $time, dut.f_wdata[55:32], dut.f_wdata[31:0], dut.f_full);
    always @(posedge dut.clk_bus) if (swatch != 0 && dut.d_valid && dut.c_ready[2] && dut.d_addr[23:3] == swatch[23:3])
        $display("[%0t] SW sdram    %06x <= %08x", $time, dut.d_addr, dut.d_wdata);
    // The write chain's ordering contract (nds_sdram_mc serves a waiting port
    // before the chain, docs/phase2-integration.md "ports first"): no port
    // may read or write an SDRAM word while a write to it still waits in the
    // chain FIFO (x_vwr), or it would see or overwrite older data. The
    // clients keep it by distance (the bottom screen and the 3D line ring
    // read their lines at least a line after writing them); checked here,
    // word by word, at the controller's take.
    // ---------------- +mrprof: main-RAM request profile, per video frame ----------------
    // ARM9 main-RAM requests through the fabric (clk_sys cycles): the wait
    // for the grant, each waiting cycle charged to what held the fabric
    // (DMA, ARM7, sound, the sound side path, or a grant to another master),
    // then grant -> a9_ack (service; ack comes with a read's last word),
    // including waits behind the 3D store in nds_mr_arb. nds_psram, every
    // request: s_ack -> the mem side's req_valid (crossing in), -> WR/RD
    // (queue), -> RSP (chip), -> the sys side's done (crossing back), ->
    // the last word handed out (reads).
    bit mrprof = 0;
    initial mrprof = $test$plusargs("mrprof");
    longint pc = 0;
    always @(posedge dut.clk_sys) pc <= pc + 1;
    longint p9_n = 0, p9_wait = 0, p9_dm = 0, p9_a7 = 0, p9_sn = 0, p9_sd = 0, p9_oth = 0, p9_svc = 0, p9_mrb = 0, p9_dmrun = 0, p9_dmmax = 0;
    bit a9_on = 0, a9_g = 0; longint a9_t0 = 0, a9_tg = 0;
    longint pm_b = 0, pm_dm = 0;
    // DMA through the fabric: transactions (grants), main-RAM reads and
    // writes, I/O writes (the GX FIFO among them), and their clocks
    longint dm_n = 0, dm_mr = 0, dm_mw = 0, dm_io = 0, dm_oth = 0, dm_cyc_mr = 0, dm_cyc_mw = 0, dm_cyc_io = 0, dm_t0 = 0;
    bit dm_on = 0; int dm_k = 0;
    longint dm_io_st = 0, dm_io_full = 0;      // DMA I/O-write clocks with the GX FIFO stalling (gx_stall) / full (dg_full)
    always @(posedge dut.clk_sys) if (mrprof) begin
        if (dm_on && dut.ds.u_fab.st == 3'd0) begin
            dm_on = 0;
            case (dm_k) 0: begin dm_mr++; dm_cyc_mr += pc - dm_t0; end 1: begin dm_mw++; dm_cyc_mw += pc - dm_t0; end
                        2: begin dm_io++; dm_cyc_io += pc - dm_t0; end default: dm_oth++; endcase
        end
        if (dm_on && dm_k == 2) begin
            if (dut.ds.g_3d.u_gpu3d.u_geom.u_front.gx_stall) dm_io_st++;
            if (dut.ds.g_3d.u_gpu3d.u_geom.u_front.dg_full) dm_io_full++;
        end
        if (dut.ds.u_fab.st == 3'd0 && dut.ds.u_fab.grant[0]) begin
            dm_on = 1; dm_t0 = pc; dm_n++;
            dm_k = dut.ds.u_fab.dm_addr[31:24] == 8'h02 ? (dut.ds.u_fab.dm_we ? 1 : 0) : dut.ds.u_fab.dm_addr[31:24] == 8'h04 ? 2 : 3;
        end
    end
    always @(posedge dut.clk_sys) if (mrprof) begin
        if (dut.ds.u_mrarb.own == 2'd2) pm_b++;                                   // the 3D store on the port
        if (dut.ds.u_fab.st != 3'd0 && dut.ds.u_fab.mst == 2'd0) pm_dm++;          // the fabric serving DMA
        if (!a9_on && dut.ds.u_fab.a9_req && dut.ds.u_fab.a9_addr[31:24] == 8'h02) begin a9_on = 1; a9_g = 0; a9_t0 = pc; p9_dmrun = 0; end
        if (a9_on && !a9_g) begin
            if (dut.ds.u_fab.st == 3'd0 && dut.ds.u_fab.grant[1]) begin a9_g = 1; a9_tg = pc; p9_wait += pc - a9_t0; end
            else begin
                if (dut.ds.u_fab.sd_busy) p9_sd++;
                else if (dut.ds.u_fab.st != 3'd0) case (dut.ds.u_fab.mst)
                    2'd0: p9_dm++; 2'd2: p9_a7++; 2'd3: p9_sn++; default: p9_oth++; endcase
                else if (dut.ds.u_fab.grant[0]) p9_dm++;
                else if (dut.ds.u_fab.grant[2]) p9_a7++;
                else if (dut.ds.u_fab.grant[3]) p9_sn++;
                else p9_oth++;
                if (dut.ds.u_fab.st != 3'd0 && dut.ds.u_fab.mst == 2'd0 || dut.ds.u_fab.grant[0]) begin
                    p9_dmrun++; if (p9_dmrun > p9_dmmax) p9_dmmax = p9_dmrun; end
                else p9_dmrun = 0;
            end
        end else if (a9_on && a9_g) begin
            if (dut.ds.u_mrarb.a_req && dut.ds.u_mrarb.own == 2'd2) p9_mrb++;
            if (dut.ds.u_fab.a9_ack) begin p9_svc += pc - a9_tg; p9_n++; a9_on = 0; end
        end
    end
    // nds_psram: timestamps of the request in flight (one at a time), in ps
    realtime q_ack = 0, q_rv = 0, q_st = 0, q_rsp = 0, q_done = 0;
    bit q_wr = 0, q_rd_on = 0, q_rvp = 0, q_tp = 0;
    real qr_in = 0, qr_q = 0, qr_chip = 0, qr_back = 0, qr_out = 0, qw_in = 0, qw_q = 0, qw_chip = 0, qw_back = 0;
    longint qr_n = 0, qw_n = 0;
    always @(posedge dut.clk_sys) if (mrprof) begin
        if (dut.psram.req_t != q_tp) q_ack = $realtime;          // a request (or a block's second half) leaves
        q_tp = dut.psram.req_t;
        if (dut.psram.busy && dut.psram.done_t != dut.psram.done_seen) begin
            q_done = $realtime;
            if (q_wr) begin qw_in += q_rv - q_ack; qw_q += q_st - q_rv; qw_chip += q_rsp - q_st; qw_back += q_done - q_rsp; qw_n++; end
            else q_rd_on = 1;
        end
        if (q_rd_on && dut.psram.out_n == 3'd1) begin
            qr_in += q_rv - q_ack; qr_q += q_st - q_rv; qr_chip += q_rsp - q_st; qr_back += q_done - q_rsp; qr_out += $realtime - q_done; qr_n++;
            q_rd_on = 0;
        end
    end
    always @(posedge dut.clk_mem) if (mrprof) begin
        if (dut.psram.req_valid && !q_rvp) begin q_rv = $realtime; q_wr = dut.psram.req_write; end
        q_rvp = dut.psram.req_valid;
        if (dut.psram.state == 4'd3 && dut.psram.req_valid) q_st = $realtime;      // IDLE takes it: WR/RD next edge
        if (dut.psram.state == 4'd8) q_rsp = $realtime;
    end
    real tsys = 14.919;                         // clk_sys period in the tb's time unit (ns)
    integer pf_last = -1;
    always @(posedge dut.clk_sys) if (mrprof && v_frames != pf_last) begin
        if (pf_last >= 0)
            $display("mrprof frame %0d: a9 main %0d reqs, wait %0d (dma %0d, a7 %0d, snd %0d, sndpath %0d, other %0d; longest dma %0d), service %0d (behind 3D store %0d); port: 3D store %0d, dma %0d; psram reads %0d: in %.1f queue %.1f chip %.1f back %.1f out %.1f; writes %0d: in %.1f queue %.1f chip %.1f back %.1f (clk_sys)",
                     pf_last, p9_n, p9_wait, p9_dm, p9_a7, p9_sn, p9_sd, p9_oth, p9_dmmax, p9_svc, p9_mrb, pm_b, pm_dm,
                     qr_n, qr_n ? qr_in / qr_n / tsys : 0, qr_n ? qr_q / qr_n / tsys : 0, qr_n ? qr_chip / qr_n / tsys : 0, qr_n ? qr_back / qr_n / tsys : 0, qr_n ? qr_out / qr_n / tsys : 0,
                     qw_n, qw_n ? qw_in / qw_n / tsys : 0, qw_n ? qw_q / qw_n / tsys : 0, qw_n ? qw_chip / qw_n / tsys : 0, qw_n ? qw_back / qw_n / tsys : 0);
        if (pf_last >= 0)
            $display("mrprof frame %0d dma: %0d transfers: main reads %0d (%.1f clk each), main writes %0d (%.1f), I/O writes %0d (%.1f; GX stall %0d, FIFO full %0d of %0d clocks), other %0d",
                     pf_last, dm_n, dm_mr, dm_mr ? real'(dm_cyc_mr) / dm_mr : 0, dm_mw, dm_mw ? real'(dm_cyc_mw) / dm_mw : 0,
                     dm_io, dm_io ? real'(dm_cyc_io) / dm_io : 0, dm_io_st, dm_io_full, dm_cyc_io, dm_oth);
        dm_io_st = 0; dm_io_full = 0; dm_n = 0; dm_mr = 0; dm_mw = 0; dm_io = 0; dm_oth = 0; dm_cyc_mr = 0; dm_cyc_mw = 0; dm_cyc_io = 0;
        pf_last = v_frames;
        p9_n = 0; p9_wait = 0; p9_dm = 0; p9_a7 = 0; p9_sn = 0; p9_sd = 0; p9_oth = 0; p9_svc = 0; p9_mrb = 0; p9_dmmax = 0;
        pm_b = 0; pm_dm = 0; qr_n = 0; qw_n = 0; qr_in = 0; qr_q = 0; qr_chip = 0; qr_back = 0; qr_out = 0; qw_in = 0; qw_q = 0; qw_chip = 0; qw_back = 0;
    end
    // +vwatch=HEX: writes to that physical VRAM byte address per video frame:
    // for HBlank DMA rewriting one row every line (gsdd-title: 0x9C000), the
    // number of lines whose DMA landed (sim/ds tb_ds --vwatch's measure)
    reg [31:0] vwatch = 0;
    integer vw_n = 0, vw_f = -1;
    initial void'($value$plusargs("vwatch=%h", vwatch));
    always @(posedge dut.clk_sys) if (vwatch != 0) begin
        if (dut.ds.u_vram.vm_req && dut.ds.u_vram.vm_ack && dut.ds.u_vram.vm_we && !dut.ds.u_vram.vm_blk
            && dut.ds.u_vram.vm_addr == vwatch[20:2]) vw_n++;
        else if (dut.cw_ack && dut.cw_addr[18:0] == vwatch[20:2]) vw_n++;
        if (v_frames != vw_f) begin
            if (vw_f >= 0) $display("vwatch f%0d: %0d writes to %h", vw_f, vw_n, vwatch);
            vw_f = v_frames; vw_n = 0;
        end
    end
    int chain_pend [int];
    int chain_viol = 0;
    always @(posedge dut.clk_sys) if (dut.x_vwr.wr && !dut.x_vwr.full)
        chain_pend[int'(dut.x_vwr.wdata[55:32])] = chain_pend.exists(int'(dut.x_vwr.wdata[55:32])) ? chain_pend[int'(dut.x_vwr.wdata[55:32])] + 1 : 1;
    always @(posedge dut.clk_mem) begin
        if (dut.sdram.c_ready) begin
            int a, n;
            a = int'(dut.sdram.m_addr[dut.sdram.g*24 +: 24]); n = int'(dut.sdram.m_n[dut.sdram.g*4 +: 4]);
            for (int k = 0; k < n; k++)
                if (chain_pend.exists(a + k) && chain_pend[a + k] > 0) begin
                    chain_viol++;
                    if (chain_viol <= 5)
                        $display("[%0t] ERROR: SDRAM port %0d %s word %06x with a chain write pending (ordering contract)",
                                 $time, dut.sdram.g, dut.sdram.m_we[dut.sdram.g] ? "writes" : "reads", a + k);
                end
        end
        if (dut.bw_read) begin
            int a;
            a = int'(dut.bw_q[55:32]);
            if (chain_pend.exists(a)) begin
                if (chain_pend[a] <= 1) chain_pend.delete(a); else chain_pend[a] = chain_pend[a] - 1;
            end
        end
    end
    reg ovf_seen = 0;
    // the SDRAM read-word FIFOs (nds_sdram_words, no back-pressure): a
    // dropped word would shift every later word of its client (an odd count
    // swaps nds_vram's word pairs)
    always @(posedge dut.clk_sys) if ((dut.words_sys.words.overflow || dut.words_bus.words.overflow) && !ovf_seen) begin
        ovf_seen = 1;
        $display("[%0t] ERROR: SDRAM read-word FIFO overflow (words_sys %0d, words_bus %0d)", $time,
                 dut.words_sys.words.overflow, dut.words_bus.words.overflow);
    end
    always @(posedge dut.clk_74a) if (dut.f_overflow && !ovf_seen) begin
        ovf_seen = 1;
        $display("[%0t] ERROR: bridge write FIFO overflow (host model faster than the SDRAM drain)", $time);
    end
    // +line_stats=FRAME: per DS line, the VRAM blocks the core asked for and
    // the clk_sys cycles its VRAM port was busy, and late lines (as tb_ds)
    integer ls_frame = -1, ls_blk = 0, ls_busy = 0, ls_vc = 999;
    bit ls_late = 0, ls_open = 0;
    initial void'($value$plusargs("line_stats=%d", ls_frame));
    always @(posedge dut.clk_sys) if (ls_frame >= 0 && `G_LOG(frames) == ls_frame) begin
        if (dut.vcount != ls_vc) begin
            if (ls_vc < 263 && (ls_blk != 0 || ls_late))
                $display("line %3d: %3d blocks, VRAM busy %5d cycles%s", ls_vc, ls_blk, ls_busy, ls_late ? "  LATE" : "");
            ls_blk = 0; ls_busy = 0; ls_late = 0; ls_vc = dut.vcount;
        end
        if (dut.vm_req && dut.vm_blk && dut.vm_ack) ls_blk++;
        if (dut.ds.u_vram.st != 0) ls_busy++;
        if (dut.ds.stat_late) ls_late = 1;
    end
    string pc_file;
    integer pc_fd = 0;
    longint pc_n = 0, pc_from = 0, pc_cnt = 2000000;
    initial if ($value$plusargs("pctrace=%s", pc_file)) begin
        pc_fd = $fopen(pc_file, "wb");
        void'($value$plusargs("pctrace_from=%d", pc_from));
        void'($value$plusargs("pctrace_n=%d", pc_cnt));
    end
    always @(posedge dut.clk_sys) if (dut.dbg_retire && !dut.dbg_tid) begin
        if (pc_fd != 0 && pc_n >= pc_from && pc_n < pc_from + pc_cnt)
            $fwrite(pc_fd, "%c%c%c%c", dut.dbg_pc[7:0], dut.dbg_pc[15:8], dut.dbg_pc[23:16], dut.dbg_pc[31:24]);
        pc_n++;
    end
    string fst_file;
    longint fst_from_us = 0, fst_us = 200;
    initial if ($value$plusargs("fst=%s", fst_file)) begin
        void'($value$plusargs("fst_from_us=%d", fst_from_us));
        void'($value$plusargs("fst_us=%d", fst_us));
        #(fst_from_us * 1us);
        $dumpfile(fst_file);
        $dumpvars(0, tb_ds_pocket);
        #(fst_us * 1us);
        $dumpoff;
        $display("[%0t] FST window done", $time);
    end

    // ---------------- progress (+progress) ----------------
    initial if ($test$plusargs("progress")) forever begin
        #1ms;
        $display("[%0t] cart rs %0d cr_req %0d raddr %h left %0d | cl_valid %0d cache st %0d ready %0d | go %0d running %0d | pc 9:%h 7:%h fetches %0d",
                 $time, dut.ds.u_cart.rs, dut.cr_req, dut.ds.u_cart.raddr, dut.ds.u_cart.left, dut.cl_valid,
                 `TB_CACHE.st, dut.cache_ready, dut.go, dut.running, `G_LOG(pc9), `G_LOG(pc7), served);
    end

    // ---------------- the save on quit (+savout=FILE, docs/saves.md) ----------------
    // As the Pocket: the size word, 0x0080 for slot 10, reads each taking the
    // answer to the read before, >= 88 clk_74a apart, in 1 KiB pieces each
    // ending with a dummy read of the next word (which the next piece reads
    // again; #265). The file gets exactly the size word's bytes.
    // slot 11 (+diagout=FILE, DIAG=1: the NDSDiag log, docs/diag.md) the same way, at 0x70000000:
    // +diagwords=N reads only its first N words (default all 512 KiB)
    task automatic save_quit(input string path, input integer slot = 10);
        reg [31:0] size, prev, win;
        integer fd;
        if (slot == 10) begin
            read_reg(32'hF800_2034, size);
            $display("save: size word %0d, %0d bytes loaded", size, ssv);
            win = 32'h6000_0000;
        end else begin
            integer w;
            w = 32'h2_0000;
            void'($value$plusargs("diagwords=%d", w));
            size = w * 4;
            win = 32'h7000_0000;
        end
        write_reg(32'hF800_0020, slot);
        host_command(16'h0080);
        fd = $fopen(path, "wb");
        // 1 KiB pieces, each ending with a dummy read of the next word (#265)
        for (integer p0 = 0; p0 < size / 4; p0 += 256) begin
            integer len;
            len = size / 4 - p0 > 256 ? 256 : size / 4 - p0;
            for (integer j = 0; j <= len; j++) begin
                @(negedge clk_74a); prev = bridge_rd_data;
                bridge_addr = win + (p0 + j) * 4; bridge_rd = 1;
                repeat (4) @(negedge clk_74a);
                bridge_rd = 0;
                repeat (84) @(negedge clk_74a);
                if (j > 0) $fwrite(fd, "%c%c%c%c", prev[7:0], prev[15:8], prev[23:16], prev[31:24]);
            end
        end
        $fclose(fd);
        $display("%0s: exported %0d bytes, reader errors %0d, runs %0d", slot == 10 ? "save" : "diag", size, dut.save_read.errors, dut.save_read.runs);
    endtask

    // ---------------- finish ----------------
    integer timeout_ms = 2000, frames = 30;
    function automatic [31:0] ram_word(input integer w);
        ram_word = {cram1.peek({1'b0, w[21:0]}), cram0.peek({1'b0, w[21:0]})};
    endfunction
    initial begin
        reg [31:0] magic, n, mask, done;
        void'($value$plusargs("timeout_ms=%d", timeout_ms));
        void'($value$plusargs("frames=%d", frames));
        fork
            wait (v_frames >= frames);
            begin #(timeout_ms * 1ms); $display("TIMEOUT"); end
        join_any
        disable fork;
        magic = ram_word(32'hFC000); n = ram_word(32'hFC001); mask = ram_word(32'hFC002); done = ram_word(32'hFC003);
        $display("result: magic %h checks %0d mask %h done %0d", magic, n, mask, done);
        $display("video: %0d frames, %0d errors; DS frames %0d, retired 9:%0d 7:%0d; underruns %0d",
                 v_frames, v_errors, `G_LOG(frames), `G_LOG(ret9), `G_LOG(ret7), dut.underruns);
        $display("models: sdram errors %0d, cram errors %0d/%0d; cart words %0d, %0d on clk_bus edges", sdram_chip.errors, cram0.errors, cram1.errors,
                 cart_words, cart_errors);
        vml_print();
        $display("video slot %0d (the scaler slot word of the last line)", v_slot);
        // the RTC chip's state at the end (BCD; set by the boot program from +rtc since 2026-10-28)
        $display("rtc: 20%h-%h-%h dow %0d %h:%h:%h pm %0d poc %0d s1 %h", dut.ds.u_rtc.yr, dut.ds.u_rtc.mo,
                 dut.ds.u_rtc.rm[2], dut.ds.u_rtc.rm[3], dut.ds.u_rtc.hr, dut.ds.u_rtc.rm[1], dut.ds.u_rtc.rm[0],
                 dut.ds.u_rtc.pm, dut.ds.u_rtc.poc, dut.ds.u_rtc.s1);
        if (sdram_chip.errors || cram0.errors || cram1.errors || v_errors || ovf_seen || cart_errors) $fatal(1, "model, video or FIFO errors");
        if ($value$plusargs("savout=%s", fname)) begin
            string path;
            path = $sformatf("%0s", fname);
            stop_serving = 1;
            wait (!serving);
            save_quit(path);
        end
        if ($value$plusargs("diagout=%s", fname)) begin
            string path;
            path = $sformatf("%0s", fname);
            stop_serving = 1;
            wait (!serving);
            save_quit(path, 11);
        end
`ifdef IMPORT
        // an import that never released (stubs not done: the state did not reach them as laid out)
        if (imp_frame < 0) begin $display("import: never released"); $display("FAIL"); $finish; end
`endif
        // (a game has no result block: no verdict)
        if (magic != 32'h52545344) $display("no result block (not a test ROM)");
        else if (done == 1 && n > 0 && mask == (n >= 32 ? 32'hFFFFFFFF : (32'd1 << n) - 1))
            $display("PASS");
        else $display("FAIL");
        $finish;
    end
endmodule
