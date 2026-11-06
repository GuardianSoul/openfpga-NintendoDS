// SPDX-License-Identifier: MIT
// Pocket top of the NDS_Pocket Phase 1 test core, NDSPhase1
// (docs/phase1-foundation.md). The APF shell (rtl/apf/) is the Analogue
// template from MIRLO64, as in tools/sd-probe.
//
// What it does:
//   - loads BIOS9, BIOS7 and the firmware from data slots into SDRAM and
//     checks them back (CRC-32 while loading against CRC-32 read back)
//   - pass A: reads the whole .nds through APF target reads (CRC-32, signature)
//   - builds the SDRAM ROM cache's read-ahead table from the ROM's header and
//     FAT, then pass B: reads the whole ROM again through the cache in a
//     scrambled order; the cartridge test passes when both signatures match
//   - SDRAM, PSRAM and SRAM pattern tests run in a loop throughout
//   - video at DS timing: stacked (default), top only, bottom only (SELECT+R);
//     SELECT+L touch cursor (nds_controls, nds_screens)
//   - a 1 kHz tone while A is held outside touch mode (audio path check)
//   - every result in a 64-word log saved to Saves/nds/common/phase1-log.bin
//
// Data slots (data.json order; slot k's size is data-table word 2k+1):
//   0  ROM (ID 1), deferred: read only by target commands
//   1  bios9.bin (ID 2) at bridge 0x10000000     \ not deferred: the Pocket
//   2  bios7.bin (ID 3) at bridge 0x10100000      | writes them before the
//   3  firmware.bin (ID 4) at bridge 0x10200000  / core runs
//   4  the log (ID 9), nonvolatile, at bridge 0x40000000
//   5  ROM tables (ID 5, <game>.ndt) at bridge 0x30000000, optional
//   6  game file (ID 0), optional: the plugin's instance JSON
// Bridge windows: 0x20000000 cache fetches, 0x50000000 pass A.
`default_nettype none
module core_top #(
    parameter integer CACHE_SLOTS = 12288,          // 48 MiB of 4 KiB slots
    parameter bit CACHE_PREFETCH = 0,               // nds_cart_cache sequential prefetch
    parameter [23:0] SDRAM_TEST_WORDS = 24'h20_0000,  // 8 MiB at SDRAM 0
    parameter [23:0] SAVE_BASE_W = 24'h3C_0000,       // the save slot's 1 MiB
    parameter [21:0] PSRAM_TEST_WORDS = 22'h20_0000,  // 8 MiB per die
    parameter [16:0] SRAM_LAST = 17'h1_FFFF,
    parameter [31:0] DIRECT_CHUNK = 32'h0004_0000,
    parameter [31:0] MS_CLOCKS = 32'd74250,
    parameter [31:0] MS_BUS_CLOCKS = 32'd33514
) (
    input wire clk_74a,
    input wire clk_74b,
    inout  wire [7:0] cart_tran_bank2,
    output wire       cart_tran_bank2_dir,
    inout  wire [7:0] cart_tran_bank3,
    output wire       cart_tran_bank3_dir,
    inout  wire [7:0] cart_tran_bank1,
    output wire       cart_tran_bank1_dir,
    inout  wire [7:4] cart_tran_bank0,
    output wire       cart_tran_bank0_dir,
    inout  wire cart_tran_pin30,
    output wire cart_tran_pin30_dir,
    output wire cart_pin30_pwroff_reset,
    inout  wire cart_tran_pin31,
    output wire cart_tran_pin31_dir,
    input  wire port_ir_rx,
    output wire port_ir_tx,
    output wire port_ir_rx_disable,
    inout  wire port_tran_si,
    output wire port_tran_si_dir,
    inout  wire port_tran_so,
    output wire port_tran_so_dir,
    inout  wire port_tran_sck,
    output wire port_tran_sck_dir,
    inout  wire port_tran_sd,
    output wire port_tran_sd_dir,
    output wire [21:16] cram0_a,
    inout  wire [ 15:0] cram0_dq,
    input  wire         cram0_wait,
    output wire         cram0_clk,
    output wire         cram0_adv_n,
    output wire         cram0_cre,
    output wire         cram0_ce0_n,
    output wire         cram0_ce1_n,
    output wire         cram0_oe_n,
    output wire         cram0_we_n,
    output wire         cram0_ub_n,
    output wire         cram0_lb_n,
    output wire [21:16] cram1_a,
    inout  wire [ 15:0] cram1_dq,
    input  wire         cram1_wait,
    output wire         cram1_clk,
    output wire         cram1_adv_n,
    output wire         cram1_cre,
    output wire         cram1_ce0_n,
    output wire         cram1_ce1_n,
    output wire         cram1_oe_n,
    output wire         cram1_we_n,
    output wire         cram1_ub_n,
    output wire         cram1_lb_n,
    output wire [12:0] dram_a,
    output wire [ 1:0] dram_ba,
    inout  wire [15:0] dram_dq,
    output wire [ 1:0] dram_dqm,
    output wire        dram_clk,
    output wire        dram_cke,
    output wire        dram_ras_n,
    output wire        dram_cas_n,
    output wire        dram_we_n,
    output wire [16:0] sram_a,
    inout  wire [15:0] sram_dq,
    output wire        sram_oe_n,
    output wire        sram_we_n,
    output wire        sram_ub_n,
    output wire        sram_lb_n,
    input wire vblank,
    output wire dbg_tx,
    input  wire dbg_rx,
    output wire user1,
    input  wire user2,
    inout  wire aux_sda,
    output wire aux_scl,
    output wire vpll_feed,
    output wire [23:0] video_rgb,
    output wire        video_rgb_clock,
    output wire        video_rgb_clock_90,
    output wire        video_de,
    output wire        video_skip,
    output wire        video_vs,
    output wire        video_hs,
    output wire audio_mclk,
    input  wire audio_adc,
    output wire audio_dac,
    output wire audio_lrck,
    output wire        bridge_endian_little,
    input  wire [31:0] bridge_addr,
    input  wire        bridge_rd,
    output reg  [31:0] bridge_rd_data,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,
    input wire [31:0] cont1_key,
    input wire [31:0] cont2_key,
    input wire [31:0] cont3_key,
    input wire [31:0] cont4_key,
    input wire [31:0] cont1_joy,
    input wire [31:0] cont2_joy,
    input wire [31:0] cont3_joy,
    input wire [31:0] cont4_joy,
    input wire [15:0] cont1_trig,
    input wire [15:0] cont2_trig,
    input wire [15:0] cont3_trig,
    input wire [15:0] cont4_trig
);
    assign port_ir_tx = 0, port_ir_rx_disable = 1;
    assign cart_tran_bank1 = 8'bz, cart_tran_bank2 = 8'bz, cart_tran_bank3 = 8'bz;
    assign cart_tran_bank1_dir = 0, cart_tran_bank2_dir = 0, cart_tran_bank3_dir = 0;
    assign cart_tran_bank0 = 4'hf, cart_tran_bank0_dir = 1;
    assign cart_tran_pin30 = 1'bz, cart_tran_pin30_dir = 0, cart_pin30_pwroff_reset = 0;
    assign cart_tran_pin31 = 1'bz, cart_tran_pin31_dir = 0;
    assign port_tran_si = 1'bz, port_tran_so = 1'bz, port_tran_sck = 1'bz, port_tran_sd = 1'bz;
    assign port_tran_si_dir = 0, port_tran_so_dir = 0, port_tran_sck_dir = 0, port_tran_sd_dir = 0;
    assign dbg_tx = 1'bz, user1 = 1'bz, aux_sda = 1'bz, aux_scl = 1'bz, vpll_feed = 1'bz;
    // bridge words carry file bytes little-endian (byte 0 in bits 7:0)
    assign bridge_endian_little = 1;

    localparam [31:0] LOG_BYTES = 32'd528;      // 128 words + 4 spare (the save's one-word read lag)

    // ---------------- clocks and resets ----------------
    reg [7:0] power_count = 0;
    reg power_reset_n = 0;
    always @(posedge clk_74a) begin
        if (!power_reset_n) power_count <= power_count + 1'b1;
        if (&power_count) power_reset_n <= 1;
    end
    wire clk_bus, clk_mem, clk_cram, clk_vid, clk_vid90, pll_locked;
    nds_pll core_pll (.refclk(clk_74a), .rst(!power_reset_n), .clk_bus(clk_bus), .clk_mem(clk_mem),
        .clk_cram(clk_cram), .clk_vid(clk_vid), .clk_vid90(clk_vid90), .locked(pll_locked));
    (* async_reg = "true" *) reg [2:0] rst_bus_s = 3'b111, rst_mem_s = 3'b111, rst_vid_s = 3'b111;
    always @(posedge clk_bus or negedge pll_locked)
        if (!pll_locked) rst_bus_s <= 3'b111; else rst_bus_s <= {rst_bus_s[1:0], 1'b0};
    always @(posedge clk_mem or negedge pll_locked)
        if (!pll_locked) rst_mem_s <= 3'b111; else rst_mem_s <= {rst_mem_s[1:0], 1'b0};
    always @(posedge clk_vid or negedge pll_locked)
        if (!pll_locked) rst_vid_s <= 3'b111; else rst_vid_s <= {rst_vid_s[1:0], 1'b0};
    wire rst_bus = rst_bus_s[2], rst_mem = rst_mem_s[2], rst_vid = rst_vid_s[2];
    wire rst_74 = !power_reset_n;

    // ---------------- APF commands ----------------
    wire reset_n, dataslot_allcomplete;
    wire [31:0] cmd_bridge_rd_data;
    wire rq, rq_ack;
    wire [15:0] rq_id;
    wire tgt_read, tgt_ack, tgt_done;
    wire [2:0] tgt_err;
    wire [31:0] tgt_offset, tgt_bridge, tgt_length;
    wire [9:0] dt_addr;
    wire dt_wren;
    wire [31:0] dt_data, dt_q;
    wire sdram_ready, mem_ready74;
    nds_sync s_memready (.clk(clk_74a), .d(sdram_ready), .q(mem_ready74));
    core_bridge_cmd_lean commands (    // the APF template minus copies of held inputs (tools/apf/bridge_cmd_lean.py)
        .clk(clk_74a), .reset_n(reset_n),
        .bridge_endian_little(bridge_endian_little), .bridge_addr(bridge_addr), .bridge_rd(bridge_rd),
        .bridge_rd_data(cmd_bridge_rd_data), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
        .status_boot_done(power_reset_n), .status_setup_done(power_reset_n), .status_running(reset_n),
        .dataslot_requestread(rq), .dataslot_requestread_id(rq_id), .dataslot_requestread_ack(rq_ack), .dataslot_requestread_ok(1'b1),
        .dataslot_requestwrite(), .dataslot_requestwrite_id(), .dataslot_requestwrite_size(),
        .dataslot_requestwrite_ack(mem_ready74), .dataslot_requestwrite_ok(1'b1),
        .dataslot_update(), .dataslot_update_id(), .dataslot_update_size(),
        .dataslot_allcomplete(dataslot_allcomplete),
        .rtc_epoch_seconds(), .rtc_date_bcd(), .rtc_time_bcd(), .rtc_valid(),
        .savestate_supported(1'b0), .savestate_addr(32'b0), .savestate_size(32'b0), .savestate_maxloadsize(32'b0),
        .osnotify_inmenu(),
        .savestate_start(), .savestate_start_ack(1'b0), .savestate_start_busy(1'b0), .savestate_start_ok(1'b0), .savestate_start_err(1'b0),
        .savestate_load(), .savestate_load_ack(1'b0), .savestate_load_busy(1'b0), .savestate_load_ok(1'b0), .savestate_load_err(1'b0),
        .target_dataslot_read(tgt_read), .target_dataslot_write(1'b0),
        .target_dataslot_getfile(1'b0), .target_dataslot_openfile(1'b0),
        .target_dataslot_ack(tgt_ack), .target_dataslot_done(tgt_done), .target_dataslot_err(tgt_err),
        .target_dataslot_id(16'd1), .target_dataslot_slotoffset(tgt_offset),
        .target_dataslot_bridgeaddr(tgt_bridge), .target_dataslot_length(tgt_length),
        .target_buffer_param_struct(32'b0), .target_buffer_resp_struct(32'b0),
        .datatable_addr(dt_addr), .datatable_wren(dt_wren), .datatable_data(dt_data), .datatable_q(dt_q));

    // ---------------- APF side (clk_74a) ----------------
    wire f_wr;
    wire [56:0] f_wdata;
    wire fc_recv;
    wire [119:0] fc_data74;
    wire sizes_valid;
    wire [31:0] rom_size, size9, size7, sizefw, crc9, crc7, crcfw, load_words, a_crc, a_words, a_ms, ms;
    wire [15:0] load_jumps, a_cmds, a_errors, a_jumps, f_cmds, f_errors;
    wire [1:0] a_state;
    wire [63:0] a_sig;
    // the save slot (docs/saves.md) at SDRAM 15 MiB, clear of the SDRAM test; with
    // no DS to choose, the type is the tables' if valid, else the file size's,
    // else EEPROM 8 KiB (the boot program's order without savetab)
    wire [7:0] save_info;
    wire [20:0] save_loaded, save_bytes;
    wire [2:0] save_type = save_info[7] ? save_info[6:4] : save_info[3] ? save_info[2:0] : 3'd2;
    nds_apf_host #(.DIRECT_CHUNK(DIRECT_CHUNK), .LOG_POS(4), .LOG_BYTES(LOG_BYTES), .MS_CLOCKS(MS_CLOCKS),
                   .SAVE_POS(7), .SAVE_BASE_W(SAVE_BASE_W)) host (
        .clk(clk_74a), .reset(rst_74), .allcomplete(dataslot_allcomplete),
        .bridge_wr(bridge_wr), .bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
        .save_type(save_type), .save_loaded(save_loaded), .save_info(save_info), .save_bytes(save_bytes),
        .dt_addr(dt_addr), .dt_wren(dt_wren), .dt_data(dt_data), .dt_q(dt_q),
        .tgt_read(tgt_read), .tgt_offset(tgt_offset), .tgt_bridge(tgt_bridge), .tgt_length(tgt_length),
        .tgt_ack(tgt_ack), .tgt_done(tgt_done), .tgt_err(tgt_err),
        .f_wr(f_wr), .f_data(f_wdata), .fc_recv(fc_recv), .fc_data(fc_data74),
        .sizes_valid(sizes_valid), .rom_size(rom_size), .bios9_size(size9), .bios7_size(size7), .fw_size(sizefw),
        .crc9(crc9), .crc7(crc7), .crcfw(crcfw), .load_jumps(load_jumps), .load_words(load_words),
        .a_state(a_state), .a_crc(a_crc), .a_sig(a_sig), .a_words(a_words), .a_ms(a_ms),
        .a_cmds(a_cmds), .a_errors(a_errors), .a_jumps(a_jumps), .f_cmds(f_cmds), .f_errors(f_errors), .ms(ms));

    // ---------------- crossings ----------------
    wire f_valid, f_rd, f_full, f_overflow;
    wire [56:0] f_rdata;
    nds_dcfifo #(.W(57), .A(6)) wfifo (.wclk(clk_74a), .wreset(rst_74), .wr(f_wr), .wdata(f_wdata), .full(f_full), .overflow(f_overflow),
        .rclk(clk_bus), .rd(f_rd), .valid(f_valid), .rdata(f_rdata));
    wire fc_send, fc_busy;
    wire [119:0] fc_data;
    // the cache holds fc_data from send until the command's marker returns,
    // after the host is done with it: only the toggles cross
    nds_bundle_cdc #(.W(120), .SOURCE_HOLDS(1)) x_fetch (.a_clk(clk_bus), .a_send(fc_send), .a_data(fc_data), .a_busy(fc_busy),
        .b_clk(clk_74a), .b_recv(fc_recv), .b_data(fc_data74));
    // sizes and load CRCs, once, when the data table has been read
    reg info_sent = 0;
    always @(posedge clk_74a) if (rst_74) info_sent <= 0; else if (sizes_valid) info_sent <= 1;
    wire info_recv;
    wire [223:0] info;
    nds_bundle_cdc #(.W(224)) x_info (.a_clk(clk_74a), .a_send(sizes_valid && !info_sent),
        .a_data({crcfw, crc7, crc9, sizefw, size7, size9, rom_size}), .a_busy(),
        .b_clk(clk_bus), .b_recv(info_recv), .b_data(info));
    reg info_ok = 0;
    always @(posedge clk_bus) if (rst_bus) info_ok <= 0; else if (info_recv) info_ok <= 1;
    wire [31:0] rom_size_b = info[31:0];
    // one pulse per millisecond on clk_bus
    reg [31:0] bus_tick = 0;
    reg tick_ms = 0;
    always @(posedge clk_bus) begin
        tick_ms <= bus_tick == MS_BUS_CLOCKS - 1;
        bus_tick <= bus_tick == MS_BUS_CLOCKS - 1 ? 32'd0 : bus_tick + 1'b1;
    end

    // ---------------- SDRAM and its clients (clk_bus) ----------------
    localparam integer NC = 7;
    wire [NC-1:0] c_valid, c_write, c_quad, c_ready, r_valid;
    wire [NC*24-1:0] c_addr;
    wire [NC*32-1:0] c_wdata;
    wire [NC*4-1:0] c_be;
    wire [31:0] r_data;
    nds_sdram #(.N(NC)) sdram (.clk_bus(clk_bus), .clk_mem(clk_mem), .reset(rst_bus), .ready(sdram_ready),
        .c_valid(c_valid), .c_write(c_write), .c_quad(c_quad), .c_addr(c_addr), .c_wdata(c_wdata), .c_be(c_be),
        .c_ready(c_ready), .r_valid(r_valid), .r_data(r_data),
        .bw_valid(1'b0), .bw_addr(24'd0), .bw_data(32'd0), .bw_read(),
        .dram_dq(dram_dq), .dram_a(dram_a), .dram_ba(dram_ba), .dram_dqm(dram_dqm), .dram_clk(dram_clk),
        .dram_cke(dram_cke), .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n));

    // client 2: the bridge-write FIFO (after the display's deadlines)
    wire mk_valid;
    wire [2:0] mk_err;
    wire d_valid;
    wire [23:0] d_addr;
    wire [31:0] d_wdata;
    nds_fifo_drain drain (.clk(clk_bus), .f_valid(f_valid), .f_data(f_rdata), .f_rd(f_rd),
        .mk_valid(mk_valid), .mk_err(mk_err), .m_valid(d_valid), .m_addr(d_addr), .m_wdata(d_wdata), .m_ready(c_ready[2]));
    assign c_valid[2] = d_valid, c_write[2] = 1'b1, c_quad[2] = 1'b0;
    assign c_addr[71:48] = d_addr, c_wdata[95:64] = d_wdata, c_be[11:8] = 4'hF;

    // clients 0 and 1: the stacked layout's bottom screen from and to SDRAM
    // (first: the display has deadlines, at most a quarter of the SDRAM's time)
    wire [1:0] layout_sel, layout;
    wire touch, pen;
    wire [7:0] cur_x, cur_y;
    wire [15:0] ds_keys, underruns, late;
    wire vr_valid, vw_valid, frame_pulse;
    wire [23:0] vr_addr, vw_addr;
    wire [31:0] vw_data;
    assign c_valid[0] = vr_valid, c_write[0] = 1'b0, c_quad[0] = 1'b1;
    assign c_addr[23:0] = vr_addr, c_wdata[31:0] = 32'b0, c_be[3:0] = 4'b0;
    assign c_valid[1] = vw_valid, c_write[1] = 1'b1, c_quad[1] = 1'b0;
    assign c_addr[47:24] = vw_addr, c_wdata[63:32] = vw_data, c_be[7:4] = 4'hF;

    // client 3: the ROM cache, serving pass B
    wire cache_ready, cache_fail, cache_capped;
    wire cl_valid, cl_ready, cl_rvalid, stat_clear;
    wire [31:0] cl_addr, cl_rdata;
    wire k_valid, k_write, k_quad;
    wire [23:0] k_addr;
    wire [31:0] k_wdata;
    wire [3:0] k_be;
    wire [31:0] st_lookups, st_fast, st_cmds, st_blocks, st_evict, st_wait, st_spans, st_marks;
    wire [15:0] st_errors;
    nds_cart_cache #(.SLOTS(CACHE_SLOTS), .PREFETCH(CACHE_PREFETCH)) cache (.clk(clk_bus), .reset(rst_bus),
        .start(info_ok && rom_size_b != 0), .rom_size(rom_size_b),
        .ready(cache_ready), .fail(cache_fail), .init_capped(cache_capped),
        .c_valid(cl_valid), .c_addr(cl_addr), .c_ready(cl_ready), .r_valid(cl_rvalid), .r_data(cl_rdata),
        .fc_send(fc_send), .fc_data(fc_data), .fc_busy(fc_busy), .mk_valid(mk_valid), .mk_err(mk_err),
        .m_valid(k_valid), .m_write(k_write), .m_quad(k_quad), .m_addr(k_addr), .m_wdata(k_wdata), .m_be(k_be),
        .m_ready(c_ready[3]), .m_rvalid(r_valid[3]), .m_rdata(r_data),
        .stat_clear(stat_clear), .tick_ms(tick_ms), .st_lookups(st_lookups), .st_fast(st_fast), .st_cmds(st_cmds), .st_blocks(st_blocks),
        .st_evict(st_evict), .st_wait(st_wait), .st_errors(st_errors), .st_spans(st_spans), .st_marks(st_marks));
    assign c_valid[3] = k_valid, c_write[3] = k_write, c_quad[3] = k_quad;
    assign c_addr[95:72] = k_addr, c_wdata[127:96] = k_wdata, c_be[15:12] = k_be;
    wire [1:0] b_state;
    wire [63:0] b_sig;
    wire [31:0] b_words, b_quads, b_ms, b_bytes;
    nds_cart_test passb (.clk(clk_bus), .reset(rst_bus), .start(cache_ready), .rom_size(rom_size_b), .tick_ms(tick_ms),
        .state(b_state), .sig(b_sig), .words(b_words), .quads(b_quads), .ms(b_ms), .bytes_done(b_bytes),
        .stat_clear(stat_clear), .c_valid(cl_valid), .c_addr(cl_addr), .c_ready(cl_ready),
        .r_valid(cl_rvalid), .r_data(cl_rdata));

    // client 4: BIOS and firmware read back
    wire [5:0] load_state;
    wire [31:0] rb9, rb7, rbfw;
    wire lc_valid;
    wire [23:0] lc_addr;
    nds_load_check check (.clk(clk_bus), .reset(rst_bus), .start(info_ok),
        .size9(info[63:32]), .size7(info[95:64]), .sizefw(info[127:96]),
        .crc9(info[159:128]), .crc7(info[191:160]), .crcfw(info[223:192]),
        .state(load_state), .rb9(rb9), .rb7(rb7), .rbfw(rbfw),
        .m_valid(lc_valid), .m_addr(lc_addr), .m_ready(c_ready[4]), .m_rvalid(r_valid[4]), .m_rdata(r_data));
    assign c_valid[4] = lc_valid, c_write[4] = 1'b0, c_quad[4] = 1'b1;
    assign c_addr[119:96] = lc_addr, c_wdata[159:128] = 32'b0, c_be[19:16] = 4'b0;

    // client 5: the save's write-back on quit (nds_save_read)
    wire save_sel, s_valid;
    wire [31:0] save_rd;
    wire [23:0] s_addr;
    wire [15:0] save_runs, save_errors;
    nds_save_read #(.BASE_W(SAVE_BASE_W)) save_read (.clk(clk_74a), .reset(rst_74),
        .rq(rq), .rq_id(rq_id), .rq_ack(rq_ack), .words(save_bytes[20:2]),
        .bridge_rd(bridge_rd), .bridge_addr(bridge_addr), .selected(save_sel), .bridge_data(save_rd),
        .runs(save_runs), .errors(save_errors),
        .clk_bus(clk_bus), .reset_bus(rst_bus), .m_valid(s_valid), .m_addr(s_addr),
        .m_ready(c_ready[5]), .m_rvalid(r_valid[5]), .m_rdata(r_data));
    assign c_valid[5] = s_valid, c_write[5] = 1'b0, c_quad[5] = 1'b0;
    assign c_addr[143:120] = s_addr, c_wdata[191:160] = 32'b0, c_be[23:20] = 4'b0;

    // client 6: SDRAM pattern test (lowest priority)
    wire [1:0] sd_state;
    wire [31:0] sd_passes, sd_errors, sd_faddr, sd_fexp, sd_fact, sd_wr, sd_rd;
    wire t_valid, t_write, t_quad;
    wire [23:0] t_addr;
    wire [31:0] t_wdata;
    wire [3:0] t_be;
    nds_sdram_test #(.BASE(24'h0), .WORDS(SDRAM_TEST_WORDS)) sdtest (.clk(clk_bus), .reset(rst_bus), .start(sdram_ready),
        .state(sd_state), .passes(sd_passes), .errors(sd_errors), .fail_addr(sd_faddr), .fail_exp(sd_fexp),
        .fail_act(sd_fact), .wr_cycles(sd_wr), .rd_cycles(sd_rd),
        .m_valid(t_valid), .m_write(t_write), .m_quad(t_quad), .m_addr(t_addr), .m_wdata(t_wdata), .m_be(t_be),
        .m_ready(c_ready[6]), .m_rvalid(r_valid[6]), .m_rdata(r_data));
    assign c_valid[6] = t_valid, c_write[6] = t_write, c_quad[6] = t_quad;
    assign c_addr[167:144] = t_addr, c_wdata[223:192] = t_wdata, c_be[27:24] = t_be;

    // bus words for the log (indices 24..51)
    wire [12:0] bus_flags = {cache_capped, cache_fail, cache_ready, b_state, load_state, sd_state};
    wire [28*32-1:0] bus_words = {
        {layout, touch, pen, cur_x, cur_y, 12'b0}, {underruns, late}, b_bytes,  // 51..49
        sd_rd, sd_wr, sd_fact, sd_fexp, sd_faddr, sd_errors, sd_passes,  // 48..42
        rbfw, rb7, rb9, {19'b0, bus_flags}, {16'b0, st_errors},          // 41..37
        st_marks, st_spans, st_wait, st_evict, st_blocks, st_cmds, st_fast, st_lookups,  // 36..29
        b_quads, b_ms, b_words, b_sig[63:32], b_sig[31:0]};              // 28..24
    wire bs_send, bs_busy, bs_recv;
    wire [38:0] bs_data, bs_data74;
    nds_status_stream #(.N(28), .BASE(7'd24)) bus_stream (.clk(clk_bus), .words(bus_words), .busy(bs_busy),
        .send(bs_send), .data(bs_data));
    nds_bundle_cdc #(.W(39)) x_bus (.a_clk(clk_bus), .a_send(bs_send), .a_data(bs_data), .a_busy(bs_busy),
        .b_clk(clk_74a), .b_recv(bs_recv), .b_data(bs_data74));

    // ---------------- PSRAM and SRAM (clk_mem) ----------------
    wire ps_init, ps_valid, ps_write, ps_ready, ps_rsp, ps_error, ps_clk_en;
    wire [24:0] ps_addr;
    wire [3:0] ps_half;
    wire [127:0] ps_wdata, ps_rdata;
    wire [15:0] ps_be;
    psx_psram_pair #(.CLOCK_MHZ(100.541946), .PAIRED(1)) psram (.clk(clk_mem), .reset(rst_mem), .initialized(ps_init),
        .req_valid(ps_valid), .req_write(ps_write), .req_ready(ps_ready), .req_addr(ps_addr), .req_halfwords(ps_half),
        .req_wdata(ps_wdata), .req_byte_en(ps_be), .rsp_valid(ps_rsp), .rsp_ready(1'b1), .rsp_rdata(ps_rdata),
        .rsp_error(ps_error), .fill_valid(), .fill_word(), .fill_data(), .idle(), .chip_clk_en(ps_clk_en), .dbg_state(),
        .cram0_a(cram0_a), .cram1_a(cram1_a), .cram0_dq(cram0_dq), .cram1_dq(cram1_dq),
        .cram0_wait(cram0_wait), .cram1_wait(cram1_wait),
        .cram0_adv_n(cram0_adv_n), .cram1_adv_n(cram1_adv_n), .cram0_cre(cram0_cre), .cram1_cre(cram1_cre),
        .cram0_ce0_n(cram0_ce0_n), .cram0_ce1_n(cram0_ce1_n), .cram1_ce0_n(cram1_ce0_n), .cram1_ce1_n(cram1_ce1_n),
        .cram0_oe_n(cram0_oe_n), .cram1_oe_n(cram1_oe_n), .cram0_we_n(cram0_we_n), .cram1_we_n(cram1_we_n),
        .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n), .cram1_ub_n(cram1_ub_n), .cram1_lb_n(cram1_lb_n));
    // Chip clock only while a burst read runs, LOW otherwise: with a free-running
    // clock the chips turned asynchronous writes into burst writes (openfpga-PlayStation
    // overnight-decisions.md, 2026-10-15 02:55).
    altddio_out #(.width(2), .intended_device_family("Cyclone V"), .lpm_type("altddio_out"), .power_up_high("OFF"),
        .extend_oe_disable("OFF"), .invert_output("OFF"), .oe_reg("UNREGISTERED")) cram_clock (
        .datain_h({2{ps_clk_en}}), .datain_l(2'b0), .outclock(clk_cram), .dataout({cram1_clk, cram0_clk}),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0));
    wire [1:0] ps_state;
    wire [31:0] ps_passes, ps_errors, ps_faddr, ps_fexp, ps_fact, ps_wr, ps_rd;
    wire [15:0] ps_max, ps_min;
    nds_psram_test #(.WORDS(PSRAM_TEST_WORDS)) pstest (.clk(clk_mem), .reset(rst_mem), .start(ps_init),
        .state(ps_state), .passes(ps_passes), .errors(ps_errors), .fail_addr(ps_faddr), .fail_exp(ps_fexp),
        .fail_act(ps_fact), .wr_cycles(ps_wr), .rd_cycles(ps_rd), .rd_max(ps_max), .rd_min(ps_min),
        .req_valid(ps_valid), .req_write(ps_write), .req_ready(ps_ready), .req_addr(ps_addr), .req_halfwords(ps_half),
        .req_wdata(ps_wdata), .req_byte_en(ps_be), .rsp_valid(ps_rsp), .rsp_rdata(ps_rdata), .rsp_error(ps_error));

    wire [15:0] sr_ok, sr_bad, sr_rounds, sr_out;
    wire [31:0] sr_errors, sr_ffff, sr_finfo, sr_fdata;
    wire [255:0] sr_err_l;
    wire sr_oe;
    nds_sram_test #(.LAST(SRAM_LAST)) srtest (.clk(clk_mem), .reset(rst_mem), .start(1'b1),
        .ok(sr_ok), .bad(sr_bad), .rounds(sr_rounds), .errors(sr_errors), .ffff_reads(sr_ffff), .err_l(sr_err_l),
        .fail_info(sr_finfo), .fail_data(sr_fdata),
        .sram_a(sram_a), .dq_out(sr_out), .dq_oe(sr_oe), .dq_pin(sram_dq), .oe_n(sram_oe_n), .we_n(sram_we_n),
        .ub_n(sram_ub_n), .lb_n(sram_lb_n));
    assign sram_dq = sr_oe ? sr_out : 16'bz;

    // mem words for the log (indices 52..72): 64..71 the SRAM errors per access
    // length ({L 2k+1, L 2k}), 72 the bad reads that were 0xFFFF
    wire [21*32-1:0] mem_words = {
        sr_ffff, sr_err_l,                                                      // 72, 71..64
        sr_fdata, sr_finfo, {sr_rounds, 14'b0, ps_state}, {sr_ok, sr_bad},   // 63..60
        {ps_max, ps_min}, ps_rd, ps_wr, ps_fact, ps_fexp, ps_faddr, ps_errors, ps_passes};  // 59..52
    wire ms_send, ms_busy, ms_recv;
    wire [38:0] ms_data, ms_data74;
    nds_status_stream #(.N(21), .BASE(7'd52)) mem_stream (.clk(clk_mem), .words(mem_words), .busy(ms_busy),
        .send(ms_send), .data(ms_data));
    nds_bundle_cdc #(.W(39)) x_mem (.a_clk(clk_mem), .a_send(ms_send), .a_data(ms_data), .a_busy(ms_busy),
        .b_clk(clk_74a), .b_recv(ms_recv), .b_data(ms_data74));

    // ---------------- verdicts and the log (clk_74a) ----------------
    // copies of the streamed words the verdicts need
    reg [31:0] v_bflags = 0, v_bsig_lo = 0, v_bsig_hi = 0, v_bbytes = 0, v_mflags = 0, v_sram = 0;
    reg b_done_seen = 0, fresh_lo = 0, fresh_hi = 0;
    always @(posedge clk_74a) begin
        if (bs_recv) case (bs_data74[38:32])
            7'd38: begin
                v_bflags <= bs_data74[31:0];
                if (bs_data74[9:8] == 2'd2 && !b_done_seen) begin b_done_seen <= 1; fresh_lo <= 0; fresh_hi <= 0; end
            end
            7'd24: begin v_bsig_lo <= bs_data74[31:0]; if (b_done_seen) fresh_lo <= 1; end
            7'd25: begin v_bsig_hi <= bs_data74[31:0]; if (b_done_seen) fresh_hi <= 1; end
            7'd49: v_bbytes <= bs_data74[31:0];
            default: ;
        endcase
        if (ms_recv) case (ms_data74[38:32])
            7'd61: v_mflags <= ms_data74[31:0];
            7'd60: v_sram <= ms_data74[31:0];
            default: ;
        endcase
        if (rst_74) begin b_done_seen <= 0; fresh_lo <= 0; fresh_hi <= 0; v_bflags <= 0; end
    end
    // SRAM: green once some access length passed every round so far, red if a
    // full round left no such length, yellow before the first round ends
    wire [15:0] sram_clean = v_sram[31:16] & ~v_sram[15:0] & 16'hFFFE;
    wire [1:0] sram_state = v_mflags[31:16] == 0 ? 2'd1 : sram_clean != 0 ? 2'd2 : 2'd3;
    wire b_final = b_done_seen && fresh_lo && fresh_hi;
    wire sig_match = {v_bsig_hi, v_bsig_lo} == a_sig;
    wire [1:0] cart_state =
        a_state == 2'd3 || v_bflags[11] || f_overflow ? 2'd3 :
        b_final ? (a_state == 2'd2 && sig_match ? 2'd2 : 2'd3) :
        a_state == 2'd2 ? 2'd1 : 2'd0;
    wire [15:0] boxes = {cart_state, a_state, v_bflags[7:2], sram_state, v_mflags[1:0], v_bflags[1:0]};
    wire [31:0] flags = {9'b0, sig_match, b_final, sizes_valid, load_jumps != 0, v_bflags[11], v_bflags[12], f_overflow, boxes};
    // progress bars: bytes >> shift, where (rom_size >> shift) <= 512
    reg [4:0] pshift = 0;
    always @(posedge clk_74a) if (!sizes_valid) pshift <= 0; else if ((rom_size >> pshift) > 32'd512) pshift <= pshift + 1'b1;
    wire [31:0] pa_full = {a_words[29:0], 2'b0} >> pshift, pb_full = v_bbytes >> pshift;
    wire [9:0] prog_a = pa_full > 512 ? 10'd512 : pa_full[9:0];
    wire [9:0] prog_b = pb_full > 512 ? 10'd512 : pb_full[9:0];

    wire [24*32-1:0] local_words = {
        32'h0, 32'h0, {f_overflow, 31'b0}, {16'b0, f_cmds},                             // 23..20
        {a_jumps, 16'b0}, {a_cmds, a_errors}, a_ms, a_words, a_sig[63:32], a_sig[31:0], ~a_crc,  // 19..13
        {load_jumps, f_errors}, load_words, ~crcfw, ~crc7, ~crc9,                        // 12..8
        sizefw, size7, size9, rom_size, ms, flags, 32'h0140_0000, 32'h4E44_5031};        // 7..0
    wire [31:0] log_rd;
    wire [5:0] v_log_addr;
    wire [31:0] v_log_data;
    nds_log #(.NLOCAL(24)) log (.clk(clk_74a), .local_words(local_words),
        .b_recv(bs_recv), .b_data(bs_data74), .m_recv(ms_recv), .m_data(ms_data74),
        .rd_addr(bridge_addr[8:2]), .rd_data(log_rd), .vclk(clk_bus), .v_addr({1'b0, v_log_addr}), .v_data(v_log_data));
    reg log_window = 0;
    always @(posedge clk_74a) log_window <= bridge_addr[31:24] == 8'h40 && bridge_addr[23:9] == 0;
    always @* begin
        bridge_rd_data = 0;
        if (bridge_addr[31:24] == 8'hF8) bridge_rd_data = cmd_bridge_rd_data;
        else if (log_window) bridge_rd_data = log_rd;
        else if (save_sel) bridge_rd_data = save_rd;
    end

    // ---------------- controls and video (clk_bus) ----------------
    nds_controls controls (.clk(clk_bus), .reset(rst_bus), .apf_keys(cont1_key[15:0]), .apf_type(4'd0),
        .apf_joy(32'h8080_8080), .cursor(), .frame(frame_pulse),
        .combo_sel(2'd0), .gest(12'h001), .speed(2'd1), .layout_set(2'd0), .set_new(1'b0),
        .layout(layout_sel), .touch(touch), .pen(pen), .cur_x(cur_x), .cur_y(cur_y), .pen_x(), .pen_y(), .ds_keys(ds_keys));
    // display-only status from clk_74a
    wire [35:0] disp;
    nds_sync #(.W(36)) s_disp (.clk(clk_bus), .d({prog_b, prog_a, boxes}), .q(disp));
    wire [23:0] s_rgb;
    wire s_de, s_hs, s_vs;
    // log rows on screen: flags, ROM CRC-32, pass A and B signatures (low
    // words), pass A ms, pass B clocks, SRAM ok/bad lengths, APF fetches
    nds_screens screens (.clk(clk_bus), .reset(rst_bus), .layout_in(layout_sel),
        .boxes(disp[15:0]), .prog_a(disp[25:16]), .prog_b(disp[35:26]), .touch(touch), .pen(pen),
        .cur_x(cur_x), .cur_y(cur_y), .keys(ds_keys), .log_addr(v_log_addr), .log_data(v_log_data),
        .log_rows({6'd31, 6'd60, 6'd27, 6'd17, 6'd24, 6'd14, 6'd13, 6'd2}), .frame_pulse(frame_pulse),
        .w_valid(vw_valid), .w_addr(vw_addr), .w_data(vw_data), .w_ready(c_ready[1]),
        .r_valid(vr_valid), .r_addr(vr_addr), .r_ready(c_ready[0]), .r_rvalid(r_valid[0]), .r_rdata(r_data),
        .underruns(underruns), .late(late), .layout(layout), .rgb(s_rgb), .de(s_de), .hs(s_hs), .vs(s_vs));
    // one pixel per clk_vid (clk_bus / 2, edges aligned): the screen outputs hold for two bus clocks
    reg [23:0] o_rgb = 0;
    reg o_de = 0, o_hs = 0, o_vs = 0;
    always @(posedge clk_vid) begin o_rgb <= s_rgb; o_de <= s_de; o_hs <= s_hs; o_vs <= s_vs; end
    assign video_rgb = o_rgb, video_de = o_de, video_hs = o_hs, video_vs = o_vs, video_skip = 1'b0;
    assign video_rgb_clock = clk_vid, video_rgb_clock_90 = clk_vid90;

    // ---------------- audio: 1 kHz square while A is held ----------------
    wire audio_sclk;
    mf_audio_pll audio_pll (.refclk(clk_74b), .rst(!power_reset_n), .outclk_0(audio_mclk), .outclk_1(audio_sclk), .locked());
    wire key_a;
    nds_sync s_key (.clk(audio_sclk), .d(ds_keys[4]), .q(key_a));   // A as the game sees it (not the pen)
    reg [10:0] tone_count = 0;
    reg tone = 0;
    always @(posedge audio_sclk) begin
        if (tone_count == 11'd1535) begin tone_count <= 0; tone <= !tone; end
        else tone_count <= tone_count + 1'b1;
    end
    wire [15:0] sample = !key_a ? 16'd0 : tone ? 16'h0800 : 16'hF800;
    sound_i2s #(.SIGNED_INPUT(1)) sound (.audio_sclk(audio_sclk), .audio_l(sample), .audio_r(sample),
        .audio_lrck(audio_lrck), .audio_dac(audio_dac));
endmodule
`default_nettype wire
