// SPDX-License-Identifier: MIT
// Pocket top of the DS core, NDS (docs/phase2-integration.md, "Pocket
// shell"): rtl/ds's nds_top on Phase 1's platform. The APF shell (rtl/apf)
// is the Analogue template from MIRLO64, as in Phase 1.
//
// Data slots (data.json order; slot k's size is data-table word 2k+1):
//   0  ROM (ID 1), deferred: read only by target commands (the ROM cache)
//   1  bios9.bin (ID 2) at bridge 0x10000000     \ not deferred: the Pocket
//   2  bios7.bin (ID 3) at bridge 0x10100000      | writes them into SDRAM
//   3  firmware.bin (ID 4) at bridge 0x10200000  / before the core runs
//   4  the log (ID 9), nonvolatile, at bridge 0x40000000
//   last: nds_boot.bin (ID 12, BOOT_SRAM) at bridge 0x10300000, after the save (and the diagnostics log)
//
// Memories (docs/phase2-integration.md, "Placement"):
//   SDRAM  VRAM (656 KiB at 0), the save (512 KiB at 0x100000), BIOS/firmware (0x0800000), ROM cache table
//          and slots (Phase 1 layout), the stacked layout's bottom screen
//   PSRAM  die 0: DS main RAM (4 MiB)
// Clocks: the DS core on clk_sys (67.03 MHz); memory clients on clk_bus,
// crossed synchronously (nds_x2b); PSRAM and SDRAM controllers on clk_mem.
`default_nettype none
module core_top #(
    parameter integer CACHE_SLOTS = 12288,          // 48 MiB of 4 KiB slots
    parameter bit CACHE_PREFETCH = 1,               // nds_cart_cache sequential prefetch
    parameter bit SND_CAPTURE = 1'b1,               // TEMPORARY for the test build (docs/ds-rules.md): no sound capture units
    parameter integer SOUND = 1,                    // the DS sound engine (rtl/sound) to the Pocket's audio
    parameter integer GPU3D = 1,                    // the DS 3D engine (rtl/gpu3d, nds_gpu3d)
    parameter integer NDS_DEBUG = 0,                // 1: the debug log (nds_log, status streams)
    parameter integer ARM7_CACHE = 1,               // 1: ARM7 port caches (speed); 0: none (area, ARM7 ~1/4 speed)
    parameter integer DIAG = 0,                     // 1: the diagnostics recorder's SDRAM write port (bus port 7, diag_w_*; docs/diag.md)
    parameter integer SYS_PUMP = 0,                 // nds_top SYS_PUMP: sys_math's results RAM written on clk_2x (-1 M10K) and its sqrt on clk_2x
    parameter integer WIFI = 3,                     // the DS WiFi block (nds_top WIFI; 0: absent, games see no WiFi; 3: a game's WiFi start reads back, no radio)
    parameter integer G2D_MOSAIC = 0,               // the 2D engine's mosaic (nds_top G2D_MOSAIC)
    parameter integer G2D_TEX_IDXW = GPU3D != 0 ? 6 : 9,   // the 2D BG texel cache: log2 blocks (64 blocks = 2 + 1 M10K; 128 = 4 + 1: docs/2d-engine.md "M10K")
    parameter integer DIAG_SEC = 60,                // DIAG: a per-second record every DIAG_SEC frames (fewer: the Pocket-model check)
    parameter integer A7_IO = 1,                    // 1: ARM7 requests before ARM9 DMA units (nds_fabric A7_IO; the DS's ARM7 bus)
    parameter integer DMA_UNIT = 1,                 // 1: an ARM9 DMA unit from main RAM as one fabric request (sys_dma FAST)
    parameter integer DMA_RA = 1,                   // 1: DMA units read the next source quad ahead (nds_fabric)
    parameter integer DMA_B8 = 1,                   // 1: DMA lines of 32 bytes, one PSRAM burst (nds_fabric DMA_B8)
    parameter integer DMA_PACE = 0,
    parameter integer DMA_PACE_GX = 34,             // nds_top DMA_PACE_GX: GX FIFO DMA words at 2.08 system cycles (0-1 FIFO entries, ds-rules row 52)               // nonzero: DMA units at the DS.s measured rate per route (nds_fabric table; 0 off)
    parameter integer DMA_GX = 3,                   // 1: DMA units post GX FIFO words to the geometry engine (nds_fabric); 3: the ARM9's GX FIFO/command-port writes too
    parameter integer GX_GATH16 = 1,    // nds_top GX_GATH16: the GX spill's gather 16 entries deep
    parameter integer GX_SPAW = 16,     // nds_top GX_SPAW: the GX spill ring, 16,384 entries (128 KiB at SDRAM 0x300000; free to 0x7FFFFF)
    parameter integer DX_SKID = 0,      // nds_top DX_SKID (off: with GATH16 on 72a91f97, mkds-race stops at frame ~21 on nds_g3d_store:557; either alone runs clean): a skid word for posted DMA_GX words
    parameter integer SHELL_CPU = 1,                // 1: the ROM cache's policy in firmware on SERV (nds_cart_scpu; its code in nds_boot.bin past 8 KiB); 0: nds_cart_cache
    parameter integer BOOT_SRAM = 1,                // 1: the boot ROM from the data slot ID 12 into the external SRAM (nds_top BOOT_SRAM; frees 7 M10K)
    parameter integer OAM_SHARE = 1,                // 1: CPU OAM reads through the 2D engine's OAM, no fabric copy (nds_top OAM_SHARE; frees 2 M10K)
    parameter integer PSRAM_B8 = 1,                 // 1: an ARM9 32-byte block fill as one 8-word PSRAM burst (nds_psram B8)
    parameter integer VR_POST = 1,                  // 1: CPU and DMA word writes to VRAM through the same FIFO (nds_vram VR_POST)
    parameter integer VR_RDB = 1,                   // 1: VRAM reads from the CPUs and DMA through an 8-word line (nds_vram VR_RDB)
    parameter integer CAP_CHAIN = 1,                // 1: the display capture's word pairs go through the SDRAM write FIFO (nds_vram CAP_CHAIN)
    parameter integer G3D_STORE_SD = 0,             // 1: the 3D polygon store in SDRAM (mkds-pack: PSRAM -60K clk, but the SDRAM write chain starves the GX spill and the ring: stale rows)
    parameter integer RING = 1,                     // 1: the 3D line ring's SDRAM ports (rg_*: block reads on bus port 6, writes into the write chain)
    parameter integer A9_EVB = 1,                   // 1: the ARM9's eviction buffer (nds_top A9_EVB)
    parameter integer A9_XD = 2,                    // ARM9 D cache: 2^XD times the sets (4 KB x 2^XD; the DS: 4 KB 4-way)
    parameter integer A9_XI = 1,                    // ARM9 I cache: 2^XI times the sets (8 KB x 2^XI)
    parameter integer A9_SOLO = 5,                  // nds_top A9_SOLO (bit 0 solo while the ARM7 is halted; bit 1 sim-only split of the CPUs)
    parameter integer A9_OPT = 67101667,                 // ARM9 speed options (arm_core / arm9_mem bitmask): 4187107 + early restart (arm9_mem ERI bit 22, ERD bit 23, ERL 3 in bits 26:24)
    parameter integer A9_EARLYD = 1,                // 1: the early fetch release of a refused D access (arm9_mem EARLYD)
    parameter integer A9_EVBW = 0,                  // 1: the eviction buffer drains as a block write (needs PSRAM_BW)
    parameter integer PSRAM_BW = 0,                 // 1: a 32-byte block write (an ARM9 line eviction) as one PSRAM request (nds_psram BW)
    parameter integer PSRAM_STREAM = 1,             // 1: a block read's words to the fabric as they arrive, not after the whole burst (nds_psram STREAM)
    parameter integer SDRAM_OPEN = 1,               // 1: SDRAM reads leave their rows open (nds_sdram_mc OPEN; the 3D texture blocks' latency)
    // DL_PRI: display deadlines on the SDRAM bus (nds_sdram_bus HURRY): the 2D engine's VRAM blocks
    // (port 2) once its BG job has run G2D_HURRY clocks of the line's 4,260, and the 3D ring's
    // needed-line read (port 6) G3D_RH_AT clocks into the line, go before ports 1-5 and end a write
    // chain early (mkds-intro-cut: 216 2D lines late at sdlat 0, capture writes and texel blocks ahead)
    parameter integer DL_PRI = 1,
    parameter integer G2D_HURRY = 2800,
    parameter integer G3D_RH_AT = 2800,
    parameter integer SDRAM_OREG = 1,               // 1: a register stage between nds_sdram_mc's engine and the pins (OUT_REG; #1029/#1032/#1033 command decode)
    parameter integer CPU_FAST = GPU3D != 0 ? 0 : 1, // 1: the CPUs on clk_cpu, 89.37 MHz (rtl/arm/cpu_domain.sv); on with 3D off (KH's movie), off with 3D (area)
    // ARM7 caches: 2^A7_IL fetch lines and 2^A7_DL data lines of 16 bytes. With
    // 3D the small ones (512 B / 256 B, -33 LABs, nds-fit #198; fit plan step 4)
    parameter integer A7_IL = GPU3D != 0 ? 5 : 7,
    parameter integer A7_DL = GPU3D != 0 ? 4 : 6,
    // switchable 3D features (nds_top G3D_*; 1 = as the DS, 0 = the DS's
    // behaviour with the feature off; docs/budget-3d.md options table)
    parameter integer G3D_AA = 0,
    parameter integer G3D_TOON = 0,                 // restore order item 6 (budget-3d), room: nds_g3d_store WQ_M10K
    parameter integer G3D_FOG = 0,
    parameter integer G3D_ATEST = 1,                // restore order item 1 (budget-3d): ~0 ALMs (Yosys −11 LUT)
    parameter integer G3D_EDGE = 0,
    parameter integer G3D_SHADOW = 0,               // restore order: shadow polygons (budget-3d), room: gpu3d_raster lanes as sums of two products
    parameter integer G3D_LOWER = 0,
    parameter integer G3D_TCFAST = 0,               // 3D texture caches: one lookup per clock (budget-3d "HeartGold in the core")
    parameter integer G3D_TCMIF2 = 0,               // ... two blocks in flight
    parameter integer G3D_TCV2 = 1,                 // ... nds_g3d_cache2 (prefetch scanner; replaces FAST/MIF2)
    parameter integer G3D_NXB = 0,                  // 3D raster: no next-span register
    parameter integer G3D_VREG = 1,                 // 3D edge unit: vertex RAM output registered (timing)
    parameter integer G3D_DSHARE = 0,               // 3D front: one divider for the edge unit and the AA coverage start
    parameter integer G3D_LB2 = 0,                  // 3D raster: line buffers as two RAMs per layer (2:1 read muxes)
    parameter integer G3D_LOV = 1,                  // 3D raster: the next line starts while this one's pixels drain
    parameter integer G3D_EDIV4 = 0,                // 3D edge unit: perspective divider four bits a clock
    parameter integer G3D_EDGE2 = 0,                // 3D: a second edge unit (a polygon's two edges at once)
    parameter integer G3D_EP2 = 1,                  // 3D: the edge unit as two stages (two edges at once)
    parameter integer G3D_PUMP = 1,                 // 3D: the texture/palette caches' tag stores double-pumped on clk_2x (2 -> 1 M10K each)
    parameter integer G3D_SWHOLD = 1,               // 3D: a late swap (the engine behind the DS model) still drawn the next frame (nds_gpu3d SWHOLD)
    parameter integer G3D_SWPC = 1,                 // 3D: a late sort runs once the started frame is drawn, not at the next VBlank (nds_gpu3d SWPC)
    parameter integer G3D_SWL = 15,                 // 3D: the late-swap window stays open this many lines past line 215 (nds_gpu3d SWHOLD; MKDS startline: sorts ending up to 118.6K clk, line 220)
    parameter integer G3D_LEAD = 192,               // 3D: the lines the raster may run ahead of the display (the DS's buffer: 46; 192: the whole frame, MKDS race intro corner)
    parameter integer G3D_SL = 9,                   // 3D: log2 polygon-store pool slots (MKDS race intro: up to 260 polygons on one line)
    parameter integer G3D_TCWAYS = 1,               // ... texture cache ways (2: budget-3d "cache sizing model")
    parameter integer G3D_TXD = 5,                  // 3D raster: texel request-to-use stages added (budget-3d)
    parameter integer G3D_PXD = 5,                  // 3D raster: palette request-to-use stages added (budget-3d)
    parameter integer G3D_FPSKIP = 1,               // 3D final pass: skips the fog steps a frame does not use
    parameter integer G3D_TRU = 1,                  // 3D raster: texture reads of the last two halfwords reused
    parameter integer G3D_TRUL = 1,                 // 3D raster: TRU with one entry per read slot
    parameter integer G3D_FPCLR = 1,                // 3D final pass: its clear waits for a free write clock from F_3 on
    parameter integer G3D_YLIM2 = 1,                // 3D ring: the store two lines further past the ring's writes
    parameter integer G3D_NX2 = 0,                  // 3D ring: line dline+2 fetched too (the display skips a late 2D line)
    parameter integer G3D_RPRI = 1,                 // 3D ring: the needed line's read before a staged line's write
    parameter integer G3D_LLR = 0,                  // 3D ring: late lines show the polygons drawn so far (DS rule)
    parameter integer G3D_TL = 9,                  // 3D texture cache: log2 sets
    parameter integer G3D_PL = 8,                   // 3D palette cache: log2 lines (MKDS pre-race pan: late lines -26% on TL 9 at 7; 8: MKDS race intro corner)
    // 1 (the Pocket): main RAM and VRAM power up random, so the boot program clears them.
    // 0 only in sim/pocket_ds's state import (docs/state-import.md): memories as loaded,
    // and the boot ROM's import check enabled
    parameter integer MEM_DIRTY = 1,
    parameter [31:0] MS_CLOCKS = 32'd74250
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
    assign bridge_endian_little = 1;        // bridge words carry file bytes little-endian

    localparam [31:0] LOG_BYTES = 32'd516;  // 128 words + 4 spare (the save's one-word read lag); tools/ds/package.py LOG_BYTES

    // ---------------- clocks and resets ----------------
    reg [7:0] power_count = 0;
    reg power_reset_n = 0;
    always @(posedge clk_74a) begin
        if (!power_reset_n) power_count <= power_count + 1'b1;
        if (&power_count) power_reset_n <= 1;
    end
    wire clk_bus, clk_mem, clk_cram, clk_vid, clk_vid90, clk_sys, clk_cpu, clk_2x, pll_locked;
    nds_pll_ds core_pll (.refclk(clk_74a), .rst(!power_reset_n), .clk_bus(clk_bus), .clk_mem(clk_mem),
        .clk_cram(clk_cram), .clk_vid(clk_vid), .clk_vid90(clk_vid90), .clk_sys(clk_sys), .clk_cpu(clk_cpu), .clk_2x(clk_2x), .locked(pll_locked));
    (* async_reg = "true" *) reg [2:0] rst_bus_s = 3'b111, rst_mem_s = 3'b111, rst_sys_s = 3'b111;
    always @(posedge clk_bus or negedge pll_locked)
        if (!pll_locked) rst_bus_s <= 3'b111; else rst_bus_s <= {rst_bus_s[1:0], 1'b0};
    always @(posedge clk_mem or negedge pll_locked)
        if (!pll_locked) rst_mem_s <= 3'b111; else rst_mem_s <= {rst_mem_s[1:0], 1'b0};
    always @(posedge clk_sys or negedge pll_locked)
        if (!pll_locked) rst_sys_s <= 3'b111; else rst_sys_s <= {rst_sys_s[1:0], 1'b0};
    wire rst_bus = rst_bus_s[2], rst_mem = rst_mem_s[2], rst_sys = rst_sys_s[2];
    wire rst_74 = !power_reset_n;
    wire take;
    nds_bus_phase phase (.clk_bus(clk_bus), .clk_sys(clk_sys), .take(take));

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
    wire [31:0] rtc_date74, rtc_time74;
    wire rtc_valid74;
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
        .rtc_epoch_seconds(), .rtc_date_bcd(rtc_date74), .rtc_time_bcd(rtc_time74), .rtc_valid(rtc_valid74),
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

    // ---------------- APF side (clk_74a): loads and ROM-cache fetches ----------------
    wire f_wr;
    wire [56:0] f_wdata;
    wire fc_recv;
    wire [119:0] fc_data74;
    wire [13:0] fc_slot74;                  // (SHELL_CPU: from the cache's MLAB, read at the bridge's address)
    wire sizes_valid;
    wire [31:0] rom_size, size9, size7, sizefw, ms;
    // the save (docs/saves.md): slot 10 at data.json position 6, its memory at
    // SDRAM byte 0x100000 (nds_vram's save port); the type is the boot
    // program's (BOOTCTL[6:4], static once the DS runs)
    wire [7:0] save_info;
    wire [20:0] save_loaded, save_bytes;
    wire [2:0] save_type_sys;
    // BOOTCTL[6:4] is written once by the boot program and static from then
    // on (the size word is read at quit), so two flops are enough for 3 bits
    (* async_reg = "true" *) reg [2:0] save_type_s1 = 0, save_type74 = 0;
    always @(posedge clk_74a) begin save_type_s1 <= save_type_sys; save_type74 <= save_type_s1; end
    nds_apf_host #(.FC_RAM(SHELL_CPU), .LOG_POS(4), .LOG_BYTES(LOG_BYTES), .MS_CLOCKS(MS_CLOCKS), .PASS_A(0),
                   .SAVE_POS(6), .SAVE_BASE_W(24'h04_0000), .DIAG_POS(DIAG != 0 ? 7 : -1)) host (
        .clk(clk_74a), .reset(rst_74), .allcomplete(dataslot_allcomplete),
        .bridge_wr(bridge_wr), .bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
        .save_type(save_type74), .save_loaded(save_loaded), .save_info(save_info), .save_bytes(save_bytes),
        .dt_addr(dt_addr), .dt_wren(dt_wren), .dt_data(dt_data), .dt_q(dt_q),
        .tgt_read(tgt_read), .tgt_offset(tgt_offset), .tgt_bridge(tgt_bridge), .tgt_length(tgt_length),
        .tgt_ack(tgt_ack), .tgt_done(tgt_done), .tgt_err(tgt_err),
        .f_wr(f_wr), .f_data(f_wdata), .fc_recv(fc_recv), .fc_data(fc_data74), .fc_slot(fc_slot74),
        .sizes_valid(sizes_valid), .rom_size(rom_size), .bios9_size(size9), .bios7_size(size7), .fw_size(sizefw),
        .crc9(), .crc7(), .crcfw(), .load_jumps(), .load_words(),
        .a_state(), .a_crc(), .a_sig(), .a_words(), .a_ms(),
        .a_cmds(), .a_errors(), .a_jumps(), .f_cmds(), .f_errors(), .ms(ms));

    // ---------------- crossings from clk_74a ----------------
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
    reg info_sent = 0;
    always @(posedge clk_74a) if (rst_74) info_sent <= 0; else if (sizes_valid) info_sent <= 1;
    wire info_recv;
    wire [31:0] rom_size_b;
    // rom_size is written once, by the host's data-table scan before
    // sizes_valid, and never again: only the toggles cross
    nds_bundle_cdc #(.W(32), .SOURCE_HOLDS(1)) x_info (.a_clk(clk_74a), .a_send(sizes_valid && !info_sent), .a_data(rom_size),
        .a_busy(), .b_clk(clk_bus), .b_recv(info_recv), .b_data(rom_size_b));
    reg info_ok = 0;
    always @(posedge clk_bus) if (rst_bus) info_ok <= 0; else if (info_recv) info_ok <= 1;
    // the APF's date and time, once, for the RTC
    // the RTC: core_bridge_cmd_lean keeps the first RTC command's date and time (rtc_valid74 a level from
    // it on, the registers never written again), so clk_sys reads them directly: rtc_valid74 through two
    // flops, then 8 clocks for the static values to settle on any route (clk_74a is asynchronous, the
    // paths unconstrained), then rtc_ok (nds_rtc loads them and keeps reading them). No 64-bit copy.
    (* async_reg = "true" *) reg rtc_v1 = 0, rtc_v2 = 0;
    reg [3:0] rtc_wait = 0;
    reg rtc_ok = 0;
    always @(posedge clk_sys) begin
        rtc_v1 <= rtc_valid74; rtc_v2 <= rtc_v1;
        if (rst_sys || !rtc_v2) begin rtc_wait <= 0; rtc_ok <= 0; end
        else if (!rtc_ok) begin rtc_wait <= rtc_wait + 1'b1; if (rtc_wait == 4'd7) rtc_ok <= 1; end
    end
    wire [63:0] rtc_sys = {rtc_date74, rtc_time74};
    reg tick_ms = 0;
    reg [15:0] bus_tick = 0;
    always @(posedge clk_bus) begin
        tick_ms <= bus_tick == 16'd33513;
        bus_tick <= bus_tick == 16'd33513 ? 16'd0 : bus_tick + 1'b1;
    end

    // ---------------- SDRAM and its clients (clk_bus) ----------------
    // 0 bottom-screen reads, 1 unused (the bottom-screen writes go through
    // the controller's write FIFO, bw_*), 2 bridge-write FIFO, 3 VRAM, 4 ROM
    // cache, 5 BIOS/firmware words, 6 the save's write-back (quit only)
    localparam integer NC = 7;
    wire bw_valid, bw_read, sd_ref_late;
    wire [55:0] bw_q;
    wire [NC-1:0] c_valid, c_write, c_quad, c_ready, r_valid;
    wire [NC*24-1:0] c_addr;
    wire [NC*32-1:0] c_wdata;
    wire [NC*4-1:0] c_be;
    wire [31:0] r_data;
    // The SDRAM bus (M1, nds_sdram_bus): nds_sdram_mc on clk_mem behind one
    // arbiter, one crossing per client. Ports, first served first: 0
    // bottom-screen reads, 1 bridge-write FIFO, 2 VRAM (32-byte blocks), 3 ROM
    // cache, 4 BIOS/firmware words, 5 the save's write-back. The clk_bus
    // clients keep nds_sdram's c_* contract (indices 2, 4, 6 below), the
    // clk_sys ones nds_x2b's.
`ifdef RING_GEN
    localparam integer RING_I = 1;          // (simulation: nds_ring_gen drives the ring's ports)
`else
    localparam integer RING_I = RING;
`endif
    localparam integer NP = DIAG != 0 ? 8 : RING_I != 0 ? 7 : 6;   // (DIAG: port 6 is there, idle without RING)
    wire [NP-1:0] p_valid, p_we, p_take, p_w;
    wire [NP*24-1:0] p_addr;
    wire [NP*4-1:0] p_n, p_be;
    wire [NP*32-1:0] p_wdata;
    wire [31:0] p_wd, r_data4, r_data6;
    // DL_PRI: the deadline flags (levels from clk_sys registers) into clk_mem
    wire ds_hurry2d, ds_rg_hurry;          // nds_disp / nds_g3d_ring deadline flags (clk_sys)
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [1:0] hz2_s = 0, hzr_s = 0;
    always @(posedge clk_mem) begin hz2_s <= {hz2_s[0], ds_hurry2d}; hzr_s <= {hzr_s[0], ds_rg_hurry}; end
    wire [NP-1:0] p_hurry = DL_PRI != 0 ? NP'({hzr_s[1], 3'b000, hz2_s[1], 2'b00}) : {NP{1'b0}};
    nds_sdram_bus #(.N(NP), .OPEN(SDRAM_OPEN), .OUT_REG(SDRAM_OREG), .HURRY(DL_PRI)) sdram (.m_hurry(p_hurry), .clk(clk_mem), .init(rst_mem), .ready(sdram_ready),
        .m_valid(p_valid), .m_we(p_we), .m_addr(p_addr), .m_n(p_n), .m_wdata(p_wdata), .m_be(p_be), .m_take(p_take),
        .w_valid(p_w), .w_data(p_wd),
        .bw_valid(bw_valid), .bw_addr(bw_q[55:32]), .bw_data(bw_q[31:0]), .bw_read(bw_read), .ref_late(sd_ref_late),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_BA(dram_ba), .SDRAM_DQML(dram_dqm[0]), .SDRAM_DQMH(dram_dqm[1]),
        .SDRAM_nWE(dram_we_n), .SDRAM_nRAS(dram_ras_n), .SDRAM_nCAS(dram_cas_n), .SDRAM_CKE(dram_cke), .SDRAM_CLK(dram_clk));
    // read words: one FIFO for the clk_bus clients (1, 3; port 5 is idle: the save shares port 3), one for the
    // clk_sys ones (0, 2, 4)
    wire [NP-1:0] wb_v, ws_v;
    wire [31:0] wb_d, ws_d;
    nds_sdram_words #(.N(NP), .SEL(NP'(8'b00001010)), .A(3)) words_bus (.clk_mem(clk_mem), .w_valid(p_w), .w_data(p_wd),
        .rclk(clk_bus), .o_valid(wb_v), .o_data(wb_d));
    nds_sdram_words #(.N(NP), .SEL(NP'(8'b01010101)), .A(4)) words_sys (.clk_mem(clk_mem), .w_valid(p_w), .w_data(p_wd),
        .rclk(clk_sys), .o_valid(ws_v), .o_data(ws_d));
    nds_sdram_bport #(.SHARED(1), .SYNC_TAKE(1)) bp_bridge (.clk_bus(clk_bus), .clk_mem(clk_mem), .reset(rst_bus),
        .c_valid(c_valid[2]), .c_write(c_write[2]), .c_quad(c_quad[2]), .c_addr(c_addr[71:48]), .c_wdata(c_wdata[95:64]),
        .c_be(c_be[11:8]), .c_ready(c_ready[2]), .r_valid(r_valid[2]), .r_data(),
        .m_valid(p_valid[1]), .m_we(p_we[1]), .m_addr(p_addr[47:24]), .m_n(p_n[7:4]), .m_wdata(p_wdata[63:32]),
        .m_be(p_be[7:4]), .m_take(p_take[1]), .w_valid(wb_v[1]), .w_data(wb_d));
    // the ROM cache (client 4) and the save's write-back at quit (client 6) share one port (nds_bport_share:
    // the cache's requests pass straight through; the save's single reads get the port while the cache is
    // idle), so bus port 5 is idle (budget-3d.md H2)
    wire sh_valid, sh_write, sh_quad, sh_ready, sh_rvalid;
    wire [23:0] sh_addr;
    wire [31:0] sh_wdata;
    wire [3:0] sh_be;
    nds_bport_share x_share (.clk(clk_bus), .reset(rst_bus),
        .a_valid(c_valid[4]), .a_write(c_write[4]), .a_quad(c_quad[4]), .a_addr(c_addr[119:96]), .a_wdata(c_wdata[159:128]),
        .a_be(c_be[19:16]), .a_ready(c_ready[4]), .a_rvalid(r_valid[4]),
        .b_valid(c_valid[6]), .b_addr(c_addr[167:144]), .b_ready(c_ready[6]), .b_rvalid(r_valid[6]),
        .c_valid(sh_valid), .c_write(sh_write), .c_quad(sh_quad), .c_addr(sh_addr), .c_wdata(sh_wdata), .c_be(sh_be),
        .c_ready(sh_ready), .r_valid(sh_rvalid));
    nds_sdram_bport #(.SHARED(1)) bp_cache (.clk_bus(clk_bus), .clk_mem(clk_mem), .reset(rst_bus),
        .c_valid(sh_valid), .c_write(sh_write), .c_quad(sh_quad), .c_addr(sh_addr), .c_wdata(sh_wdata),
        .c_be(sh_be), .c_ready(sh_ready), .r_valid(sh_rvalid), .r_data(r_data4),
        .m_valid(p_valid[3]), .m_we(p_we[3]), .m_addr(p_addr[95:72]), .m_n(p_n[15:12]), .m_wdata(p_wdata[127:96]),
        .m_be(p_be[15:12]), .m_take(p_take[3]), .w_valid(wb_v[3]), .w_data(wb_d));
    assign r_data6 = r_data4;
    assign p_valid[5] = 1'b0, p_we[5] = 1'b0, p_addr[143:120] = 24'd0, p_n[23:20] = 4'd0, p_wdata[191:160] = 32'd0,
           p_be[23:20] = 4'd0;

    // client 2: the bridge-write FIFO
    wire mk_valid;
    wire [2:0] mk_err;
    wire d_valid;
    wire [23:0] d_addr;
    wire [31:0] d_wdata;
    nds_fifo_drain drain (.clk(clk_bus), .f_valid(f_valid), .f_data(f_rdata), .f_rd(f_rd),
        .mk_valid(mk_valid), .mk_err(mk_err), .m_valid(d_valid), .m_addr(d_addr), .m_wdata(d_wdata), .m_ready(c_ready[2]));
    assign c_valid[2] = d_valid, c_write[2] = 1'b1, c_quad[2] = 1'b0;
    assign c_addr[71:48] = d_addr, c_wdata[95:64] = d_wdata, c_be[11:8] = 4'hF;

    // client 4: the ROM cache; its client is the DS card (cr_*)
    wire cache_ready, cache_fail;
    wire cl_valid, cl_ready, cl_rvalid;
    wire [31:0] cl_addr, cl_rdata;
    wire k_valid, k_write, k_quad;
    wire [23:0] k_addr;
    wire [31:0] k_wdata;
    wire [3:0] k_be;
    wire [31:0] st_lookups, st_cmds, st_blocks, st_wait;
    wire diag_k_wait, diag_k_cmd;           // NDSDiag: the ROM cache waits for an APF fetch; a fetch command (clk_bus)
    generate if (SHELL_CPU != 0) begin : g_scpu
    nds_cart_scpu #(.SLOTS(CACHE_SLOTS)) cache (.clk(clk_bus), .reset(rst_bus), .fc_sel(bridge_addr[14:12]), .fc_slot(fc_slot74),
        .start(info_ok && rom_size_b != 0), .rom_size(rom_size_b),
        .ready(cache_ready), .fail(cache_fail),
        .c_valid(cl_valid), .c_addr(cl_addr), .c_ready(cl_ready), .r_valid(cl_rvalid), .r_data(cl_rdata),
        .fc_send(fc_send), .fc_data(fc_data), .fc_busy(fc_busy), .mk_valid(mk_valid), .mk_err(mk_err),
        .m_valid(k_valid), .m_write(k_write), .m_quad(k_quad), .m_addr(k_addr), .m_wdata(k_wdata), .m_be(k_be),
        .m_ready(c_ready[4]), .m_rvalid(r_valid[4]), .m_rdata(r_data4),
        .stat_clear(1'b0), .tick_ms(tick_ms), .st_lookups(st_lookups), .st_cmds(st_cmds), .st_blocks(st_blocks),
        .st_wait(st_wait), .dg_wait(diag_k_wait), .dg_cmd(diag_k_cmd));
    end else begin : g_cache
    assign fc_slot74 = 14'd0;
    nds_cart_cache #(.SLOTS(CACHE_SLOTS), .PREFETCH(CACHE_PREFETCH)) cache (.clk(clk_bus), .reset(rst_bus),
            .start(info_ok && rom_size_b != 0), .rom_size(rom_size_b),
            .ready(cache_ready), .fail(cache_fail), .init_capped(),
            .c_valid(cl_valid), .c_addr(cl_addr), .c_ready(cl_ready), .r_valid(cl_rvalid), .r_data(cl_rdata),
            .fc_send(fc_send), .fc_data(fc_data), .fc_busy(fc_busy), .mk_valid(mk_valid), .mk_err(mk_err),
            .m_valid(k_valid), .m_write(k_write), .m_quad(k_quad), .m_addr(k_addr), .m_wdata(k_wdata), .m_be(k_be),
            .m_ready(c_ready[4]), .m_rvalid(r_valid[4]), .m_rdata(r_data4),
            .stat_clear(1'b0), .tick_ms(tick_ms), .st_lookups(st_lookups), .st_fast(), .st_cmds(st_cmds), .st_blocks(st_blocks),
            .st_evict(), .st_wait(st_wait), .st_errors(), .st_spans(), .st_marks(), .dg_wait(diag_k_wait), .dg_cmd(diag_k_cmd));
    end endgenerate
    assign c_valid[4] = k_valid, c_write[4] = k_write, c_quad[4] = k_quad;
    assign c_addr[119:96] = k_addr, c_wdata[159:128] = k_wdata, c_be[19:16] = k_be;

    // ---------------- PSRAM: DS main RAM (die 0) ----------------
    // nds_psram (docs/psram-ds.md): the DS core's main-RAM port (clk_sys)
    // straight onto the two chips (clk_mem), PocketQuake's chip timing
    wire ps_clk_en;
    wire mr_req, mr_we, mr_ack, mr_rvalid, mr_n8, mr_wnext;
    wire [22:2] mr_addr;
    wire [3:0] mr_be;
    wire [31:0] mr_wdata, mr_rdata;
    nds_psram #(.CLOCK_MHZ(100.541946), .B8(PSRAM_B8), .BW(PSRAM_BW), .STREAM(PSRAM_STREAM)) psram (.clk_sys(clk_sys), .clk_mem(clk_mem), .reset_sys(rst_sys), .reset_mem(rst_mem),
        .initialized(),
        .s_req(mr_req), .s_we(mr_we), .s_addr({3'd0, mr_addr}), .s_wdata(mr_wdata), .s_be(mr_be),
        .s_ack(mr_ack), .s_rvalid(mr_rvalid), .s_rdata(mr_rdata), .s_n8(mr_n8), .s_wnext(mr_wnext),
        .chip_clk_en(ps_clk_en),
        .cram0_a(cram0_a), .cram1_a(cram1_a), .cram0_dq(cram0_dq), .cram1_dq(cram1_dq),
        .cram0_wait(cram0_wait), .cram1_wait(cram1_wait),
        .cram0_adv_n(cram0_adv_n), .cram1_adv_n(cram1_adv_n), .cram0_cre(cram0_cre), .cram1_cre(cram1_cre),
        .cram0_ce0_n(cram0_ce0_n), .cram0_ce1_n(cram0_ce1_n), .cram1_ce0_n(cram1_ce0_n), .cram1_ce1_n(cram1_ce1_n),
        .cram0_oe_n(cram0_oe_n), .cram1_oe_n(cram1_oe_n), .cram0_we_n(cram0_we_n), .cram1_we_n(cram1_we_n),
        .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n), .cram1_ub_n(cram1_ub_n), .cram1_lb_n(cram1_lb_n));
    // chip clock only while a burst read runs, LOW otherwise (Phase 1, openfpga-PlayStation)
    altddio_out #(.width(2), .intended_device_family("Cyclone V"), .lpm_type("altddio_out"), .power_up_high("OFF"),
        .extend_oe_disable("OFF"), .invert_output("OFF"), .oe_reg("UNREGISTERED")) cram_clock (
        .datain_h({2{ps_clk_en}}), .datain_l(2'b0), .outclock(clk_cram), .dataout({cram1_clk, cram0_clk}),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0));

    // ---------------- controls (clk_bus) ----------------
    wire [1:0] layout_sel;
    wire touch, cursor, pen;
    wire [7:0] cur_x, cur_y, pen_x, pen_y;
    wire [15:0] ds_keys;
    wire frame_pulse;
    reg frame_b = 0;
    // Core Settings (tools/ds/settings.py -> nds_settings.svh): bridge writes
    // to 0x500000xx on clk_74a, through two flops to clk_bus (they only change from the menu, a clock's mix of old
    // and new bits does nothing)
    `include "nds_settings.svh"
    reg [SET_BITS-1:0] set_a = SET_DEFAULT;
    // a setting's value (a small option number) from either end of the bridge
    // word: with bridge_endian_little the APF delivers it byte-swapped, in
    // bits 31:24 (#253: the settings never changed on hardware); the other
    // byte is zero either way
    function automatic [3:0] set_v(input integer w);
        set_v = (bridge_wr_data[3:0] | bridge_wr_data[27:24]) & ((4'd1 << w) - 4'd1);
    endfunction
    always @(posedge clk_74a)
        if (bridge_wr && bridge_addr[31:8] == 24'h500000)
            case (bridge_addr[7:2])
                SET_SELECT_LR_IDX:     set_a[SET_SELECT_LR_BIT +: SET_SELECT_LR_W] <= set_v(SET_SELECT_LR_W);
                SET_SELECT_ABXY_IDX:   set_a[SET_SELECT_ABXY_BIT +: SET_SELECT_ABXY_W] <= set_v(SET_SELECT_ABXY_W);
                SET_CURSOR_SPEED_IDX:  set_a[SET_CURSOR_SPEED_BIT +: SET_CURSOR_SPEED_W] <= set_v(SET_CURSOR_SPEED_W);
                SET_SCREEN_ROTATION_IDX: set_a[SET_SCREEN_ROTATION_BIT +: SET_SCREEN_ROTATION_W] <= set_v(SET_SCREEN_ROTATION_W);
                SET_A_IN_TOUCH_MODE_IDX: set_a[SET_A_IN_TOUCH_MODE_BIT +: SET_A_IN_TOUCH_MODE_W] <= set_v(SET_A_IN_TOUCH_MODE_W);
                SET_B_IN_TOUCH_MODE_IDX: set_a[SET_B_IN_TOUCH_MODE_BIT +: SET_B_IN_TOUCH_MODE_W] <= set_v(SET_B_IN_TOUCH_MODE_W);
                SET_X_IN_TOUCH_MODE_IDX: set_a[SET_X_IN_TOUCH_MODE_BIT +: SET_X_IN_TOUCH_MODE_W] <= set_v(SET_X_IN_TOUCH_MODE_W);
                SET_Y_IN_TOUCH_MODE_IDX: set_a[SET_Y_IN_TOUCH_MODE_BIT +: SET_Y_IN_TOUCH_MODE_W] <= set_v(SET_Y_IN_TOUCH_MODE_W);
                default: ;
            endcase
    wire [SET_BITS-1:0] set_b;
    nds_sync #(.W(SET_BITS)) set_sync (.clk(clk_bus), .d(set_a), .q(set_b));
    nds_controls controls (.clk(clk_bus), .reset(rst_bus), .apf_keys(cont1_key[15:0]), .apf_type(cont1_key[31:28]),
        .apf_joy(cont1_joy), .frame(frame_b),
        .combo_sel({set_b[SET_SELECT_ABXY_BIT], set_b[SET_SELECT_LR_BIT]}), .gest({set_b[SET_Y_IN_TOUCH_MODE_BIT +: 3], set_b[SET_X_IN_TOUCH_MODE_BIT +: 3],
               set_b[SET_B_IN_TOUCH_MODE_BIT +: 3], set_b[SET_A_IN_TOUCH_MODE_BIT +: 3]}),
        .speed(set_b[SET_CURSOR_SPEED_BIT +: 2]), .layout_set(2'd0), .set_new(1'b0),
        .layout(layout_sel), .touch(touch), .cursor(cursor), .pen(pen), .cur_x(cur_x), .cur_y(cur_y), .pen_x(pen_x), .pen_y(pen_y), .ds_keys(ds_keys));
    // APF order -> DS order (A B Sel Start Right Left Up Down R L X Y)
    wire [11:0] keys = {ds_keys[7], ds_keys[6], ds_keys[8], ds_keys[9], ds_keys[1], ds_keys[0],
                        ds_keys[2], ds_keys[3], ds_keys[15], ds_keys[14], ds_keys[5], ds_keys[4]};
    // the frame pulse for the controls, as one clk_bus pulse
    // (a toggle: a clk_sys flag cleared on `take` was cleared before clk_bus
    // saw it whenever the pulse fell just before a bus edge, and the DS
    // frame's length in clk_sys cycles keeps that phase, so the cursor never
    // moved on hardware)
    reg frame_t = 0, frame_tq = 0;
    always @(posedge clk_sys) if (frame_pulse) frame_t <= !frame_t;
    always @(posedge clk_bus) begin frame_tq <= frame_t; frame_b <= frame_t != frame_tq; end

    // ---------------- the DS (clk_sys) ----------------
    reg go = 0;
    always @(posedge clk_bus) go <= !rst_bus && cache_ready;
    wire vm_req, vm_we, vm_blk, vm_ack, vm_rvalid;
    wire [20:2] vm_addr;
    wire [3:0] vm_be;
    wire [31:0] vm_wdata, vm_rdata;
    wire sr_req, sr_ack;
    wire [1:0] sr_sel;
    wire [19:2] sr_addr;
    wire [31:0] sr_rdata;
    wire cr_req, cr_ack, cr_rvalid;
    wire [31:4] cr_addr;
    wire [31:0] cr_rdata;
    wire px_valid, px_eng, line_start, running;
    wire [7:0] px_line, px_x;
    wire [17:0] px_rgb;
    wire [8:0] vcount;
    wire [15:0] powcnt1;
    wire dbg_retire, dbg_tid;
    wire stat_late;                         // the DS display missed a line (pulse)
    wire [31:0] dbg_pc;
    wire aud_pre;
    wire [15:0] aud_l, aud_r;
    wire [31:0] snd_late;
    wire [15:0] snd_wait_max;
    wire        fr_req, fr_we, fr_done;
    wire [17:2] fr_addr;
    wire [3:0]  fr_be;
    wire [31:0] fr_wdata, fr_rdata;
    // the 3D line ring's SDRAM ports (RING): nds_top's (ds_rg_*), or RING_GEN's
    wire        rg_wreq, rg_rreq, rg_rack, rg_rvalid;
    wire [23:0] rg_waddr, rg_raddr;
    wire [31:0] rg_wdata, rg_rdata;
    wire        bw_full, bw_empty;
    wire        cw_valid, cw_ack;                // nds_vram's capture word pairs for the write FIFO
    wire [23:0] cw_addr;
    wire [31:0] cw_data;
    wire [6:0]  bw_fill;      // the write-chain FIFO (bottom screen + ring): full, all written words popped
    wire        ds_rg_wreq, ds_rg_rreq, ds_rg_wlast;
    wire [23:0] ds_rg_waddr, ds_rg_raddr;
    wire [31:0] ds_rg_wdata;
    // NDSDiag taps from the DS (docs/diag.md); unconnected below without DIAG, so pruned
    wire [4:0]  diag_d_ev;
    wire [15:0] diag_d_bgmax;
    wire        diag_v_start, diag_v_stop, diag_l2d_v;
    wire [8:0]  diag_l2d_line;
    wire [7:0]  diag_g_ev;
    wire [31:0] diag_g_val;
    wire [15:0] diag_g_used;
    wire [9:0]  diag_c_ev;
    wire [10:0] diag_r_ev;
    wire [31:0] diag_r_val;
    wire        diag_t_start, diag_t_stop, diag_l3d_v;
    wire [8:0]  diag_l3d_line;
    nds_top #(.BOOTROM("bootrom.mif"), .A9_SOLO(A9_SOLO), .SOUND(SOUND), .SND_CAPTURE(SND_CAPTURE), .GPU3D(GPU3D), .G3D_AA(G3D_AA), .G3D_TOON(G3D_TOON), .G3D_FOG(G3D_FOG), .G3D_ATEST(G3D_ATEST), .G3D_EDGE(G3D_EDGE), .G3D_SHADOW(G3D_SHADOW), .G3D_LOWER(G3D_LOWER), .G3D_TCFAST(G3D_TCFAST), .G3D_TCMIF2(G3D_TCMIF2), .G3D_TCWAYS(G3D_TCWAYS), .G3D_TXD(G3D_TXD), .G3D_PXD(G3D_PXD), .G3D_FPSKIP(G3D_FPSKIP), .G3D_TRU(G3D_TRU), .G3D_TRUL(G3D_TRUL), .G3D_FPCLR(G3D_FPCLR), .G3D_YLIM2(G3D_YLIM2), .G3D_LLR(G3D_LLR), .G3D_RPRI(G3D_RPRI), .G3D_NX2(G3D_NX2), .G3D_TL(G3D_TL), .G3D_PL(G3D_PL), .G3D_TCV2(G3D_TCV2), .G3D_NXB(G3D_NXB), .G3D_VREG(G3D_VREG), .G3D_DSHARE(G3D_DSHARE), .G3D_LB2(G3D_LB2), .G3D_LOV(G3D_LOV), .G3D_EDIV4(G3D_EDIV4), .G3D_EDGE2(G3D_EDGE2), .G3D_EP2(G3D_EP2), .G3D_PUMP(G3D_PUMP), .G3D_SWHOLD(G3D_SWHOLD), .G3D_SWPC(G3D_SWPC), .G3D_SWL(G3D_SWL), .G3D_LEAD(G3D_LEAD), .G3D_SL(G3D_SL), .CAP_CHAIN(CAP_CHAIN), .VR_POST(VR_POST), .VR_RDB(VR_RDB), .G3D_RING(RING), .G3D_STORE_SD(G3D_STORE_SD), .A9_EVB(A9_EVB), .A9_EVBW(A9_EVBW), .A9_EARLYD(A9_EARLYD), .BOOT_SRAM(BOOT_SRAM), .A9_OPT(A9_OPT), .A9_XD(A9_XD), .A9_XI(A9_XI), .A7_IO(A7_IO), .DMA_UNIT(DMA_UNIT), .DMA_RA(DMA_RA), .DMA_B8(DMA_B8), .DMA_PACE(DMA_PACE), .DMA_PACE_GX(DMA_PACE_GX), .DMA_GX(DMA_GX), .GX_GATH16(GX_GATH16), .GX_SPAW(GX_SPAW), .DX_SKID(DX_SKID), .ARM7_CACHE(ARM7_CACHE), .A7_IL(A7_IL), .A7_DL(A7_DL), .CPU_FAST(CPU_FAST), .WIFI(WIFI), .SYS_PUMP(SYS_PUMP), .G2D_MOSAIC(G2D_MOSAIC), .OAM_SHARE(OAM_SHARE), .G2D_TEX_IDXW(G2D_TEX_IDXW), .G2D_HURRY(DL_PRI != 0 ? G2D_HURRY : 0), .G3D_RH_AT(DL_PRI != 0 && RING != 0 ? G3D_RH_AT : 0)) ds (.hurry2d(ds_hurry2d), .rg_hurry(ds_rg_hurry), .clk(clk_sys), .clk_cpu(clk_cpu), .clk_2x(clk_2x), .rst(rst_sys), .go(go),
        .cw_valid(cw_valid), .cw_addr(cw_addr), .cw_data(cw_data), .cw_ack(cw_ack), .rg_wlast(ds_rg_wlast), .rg_wreq(ds_rg_wreq), .rg_waddr(ds_rg_waddr), .rg_wdata(ds_rg_wdata), .rg_wack(rg_wack),
        .rg_rreq(ds_rg_rreq), .rg_raddr(ds_rg_raddr), .rg_rack(rg_rack), .rg_rvalid(rg_rvalid), .rg_rdata(rg_rdata), .rg_wdrained(bw_empty), .rom_size(rom_size_b), .mem_dirty(MEM_DIRTY != 0),
        .wx_req(), .wx_we(), .wx_be(), .wx_addr(), .wx_wdata(), .wx_ack(1'b0), .wx_rdata(32'd0), .wx_irq(1'b0), .wx_power(), .wx_rtl_ack(), .wx_rtl_rdata(), .wx_rtl_irq(),
        .save_info(save_info), .sv_loaded(save_loaded), .save_type(save_type_sys),
        .aud_valid(), .aud_pre(aud_pre), .aud_l(aud_l), .aud_r(aud_r), .snd_late(snd_late), .snd_wait_max(snd_wait_max),
        .keys(keys), .pen(pen), .pen_x(pen_x), .pen_y(pen_y),
        .rtc_valid(rtc_ok), .rtc_date(rtc_sys[63:32]), .rtc_time(rtc_sys[31:0]),
        .mr_req(mr_req), .mr_we(mr_we), .mr_addr(mr_addr), .mr_be(mr_be), .mr_wdata(mr_wdata),
        .mr_ack(mr_ack), .mr_rvalid(mr_rvalid), .mr_rdata(mr_rdata), .mr_n8(mr_n8), .mr_wnext(mr_wnext),
        .vm_req(vm_req), .vm_we(vm_we), .vm_blk(vm_blk), .vm_addr(vm_addr), .vm_be(vm_be), .vm_wdata(vm_wdata),
        .vm_ack(vm_ack), .vm_rvalid(vm_rvalid), .vm_rdata(vm_rdata),
        .fr_req(fr_req), .fr_we(fr_we), .fr_addr(fr_addr), .fr_be(fr_be), .fr_wdata(fr_wdata),
        .fr_done(fr_done), .fr_rdata(fr_rdata),
        .sr_req(sr_req), .sr_sel(sr_sel), .sr_addr(sr_addr), .sr_ack(sr_ack), .sr_rdata(sr_rdata),
        .cr_req(cr_req), .cr_addr(cr_addr), .cr_ack(cr_ack), .cr_rvalid(cr_rvalid), .cr_rdata(cr_rdata),
        .px_valid(px_valid), .px_eng(px_eng), .px_line(px_line), .px_x(px_x), .px_rgb(px_rgb),
        .line_start(line_start), .vcount(vcount), .powcnt1(powcnt1), .running(running),
        .dbg_retire(dbg_retire), .dbg_tid(dbg_tid), .dbg_pc(dbg_pc), .dbg_cpsr(),
        .dbg_wen(), .dbg_wa(), .dbg_wd(),
        .mon_we(), .mon_master(), .mon_cpu(), .mon_addr(), .mon_be(), .mon_wdata(), .stat_late(stat_late),
        .diag_d_ev(diag_d_ev), .diag_d_bgmax(diag_d_bgmax), .diag_v_start(diag_v_start), .diag_v_stop(diag_v_stop),
        .diag_l2d_v(diag_l2d_v), .diag_l2d_line(diag_l2d_line),
        .diag_g_ev(diag_g_ev), .diag_g_val(diag_g_val), .diag_g_used(diag_g_used), .diag_c_ev(diag_c_ev), .diag_f_start(), .diag_f_stop(),
        .diag_r_ev(diag_r_ev), .diag_r_val(diag_r_val), .diag_t_start(diag_t_start), .diag_t_stop(diag_t_stop),
        .diag_l3d_v(diag_l3d_v), .diag_l3d_line(diag_l3d_line));

    // ARM7 WRAM, shared WRAM, BIOS7: the async SRAM on clk_sys
    nds_sram sram (.clk(clk_sys), .rst(rst_sys), .req(fr_req), .we(fr_we), .addr(fr_addr), .be(fr_be),
        .wdata(fr_wdata), .done(fr_done), .rdata(fr_rdata),
        .sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
        .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n));

    // VRAM: SDRAM client 3 (at SDRAM 0)
    wire vs_req, vs_we, vs_quad, vs_ack, vs_rvalid;
    wire [23:0] vs_addr;
    wire [31:0] vs_wdata, vs_rdata;
    wire [3:0] vs_be;
    nds_vm_split #(.BASE_W(24'h0), .OCT(1)) x_vsplit (.clk(clk_sys), .reset(rst_sys),
        .vm_req(vm_req), .vm_we(vm_we), .vm_blk(vm_blk), .vm_addr(vm_addr), .vm_be(vm_be), .vm_wdata(vm_wdata),
        .vm_ack(vm_ack), .vm_rvalid(vm_rvalid), .vm_rdata(vm_rdata),
        .s_req(vs_req), .s_we(vs_we), .s_quad(vs_quad), .s_addr(vs_addr), .s_wdata(vs_wdata), .s_be(vs_be),
        .s_ack(vs_ack), .s_rvalid(vs_rvalid), .s_rdata(vs_rdata));
    nds_sdram_xport #(.QW(8), .SHARED(1)) x_vram (.clk_sys(clk_sys), .clk_mem(clk_mem), .reset(rst_sys),
        .s_req(vs_req), .s_we(vs_we), .s_quad(vs_quad), .s_addr(vs_addr), .s_wdata(vs_wdata), .s_be(vs_be),
        .s_ack(vs_ack), .s_rvalid(vs_rvalid), .s_rdata(vs_rdata),
        .m_valid(p_valid[2]), .m_we(p_we[2]), .m_addr(p_addr[71:48]), .m_n(p_n[11:8]), .m_wdata(p_wdata[95:64]),
        .m_be(p_be[11:8]), .m_take(p_take[2]), .w_valid(ws_v[2]), .w_data(ws_d));

    // BIOS/firmware words: SDRAM client 5
    wire ss_req, ss_ack, ss_rvalid;
    wire [23:0] ss_addr;
    wire [31:0] ss_rdata;
    nds_sr_port x_srport (.clk(clk_sys), .reset(rst_sys), .sr_req(sr_req), .sr_sel(sr_sel), .sr_addr(sr_addr),
        .sr_ack(sr_ack), .sr_rdata(sr_rdata), .s_req(ss_req), .s_addr(ss_addr),
        .s_ack(ss_ack), .s_rvalid(ss_rvalid), .s_rdata(ss_rdata));
    nds_sdram_xport #(.QW(4), .SHARED(1)) x_sr (.clk_sys(clk_sys), .clk_mem(clk_mem), .reset(rst_sys),
        .s_req(ss_req), .s_we(1'b0), .s_quad(1'b0), .s_addr(ss_addr), .s_wdata(32'd0), .s_be(4'hF),
        .s_ack(ss_ack), .s_rvalid(ss_rvalid), .s_rdata(ss_rdata),
        .m_valid(p_valid[4]), .m_we(p_we[4]), .m_addr(p_addr[119:96]), .m_n(p_n[19:16]), .m_wdata(p_wdata[159:128]),
        .m_be(p_be[19:16]), .m_take(p_take[4]), .w_valid(ws_v[4]), .w_data(ws_d));

    // the save's write-back on quit: SDRAM client 6, the lowest; idle until
    // APF 0x0080 for slot 10, so no traffic while the game runs
    wire save_sel;
    wire [31:0] save_rd;
    nds_save_read #(.BASE_W(24'h04_0000), .TWO(DIAG != 0)) save_read (.clk(clk_74a), .reset(rst_74),
        .rq(rq), .rq_id(rq_id), .rq_ack(rq_ack), .words(save_bytes[20:2]),
        .bridge_rd(bridge_rd), .bridge_addr(bridge_addr), .selected(save_sel), .bridge_data(save_rd),
        .runs(), .errors(),
        .clk_bus(clk_bus), .reset_bus(rst_bus), .m_valid(c_valid[6]), .m_addr(c_addr[167:144]),
        .m_ready(c_ready[6]), .m_rvalid(r_valid[6]), .m_rdata(r_data6));
    assign c_write[6] = 1'b0, c_quad[6] = 1'b0, c_wdata[223:192] = 32'b0, c_be[27:24] = 4'b0;
    // the shell's save facts to the DS: a plain two-flop synchroniser of a
    // multi-bit value, safe only because the host sets them in its data-table
    // scan before sizes_valid, so they are static long before go (cache_ready)
    // starts the DS; anything that changes them later needs a bundle crossing
    // (save_info, save_loaded: static before the DS starts, read directly on clk_sys, as the RTC words)

    // card ROM: the ROM cache's client (16-byte reads at a ROM byte address)
    wire [31:0] cr_c_wdata;
    wire [3:0] cr_c_be;
    wire cr_c_write, cr_c_quad;
    nds_x2b #(.AW(32)) x_cart (.clk_sys(clk_sys), .clk_bus(clk_bus), .reset(rst_bus), .take(take),
        .s_req(cr_req), .s_we(1'b0), .s_quad(1'b1), .s_addr({cr_addr, 4'd0}), .s_wdata(32'd0), .s_be(4'hF),
        .s_ack(cr_ack), .s_rvalid(cr_rvalid), .s_rdata(cr_rdata),
        .c_valid(cl_valid), .c_write(cr_c_write), .c_quad(cr_c_quad), .c_addr(cl_addr), .c_wdata(cr_c_wdata), .c_be(cr_c_be),
        .c_ready(cl_ready), .r_valid(cl_rvalid), .r_data(cl_rdata));

    // ---------------- video (clk_sys) ----------------
    wire vw_req, vw_ack, vr_req, vr_ack, vr_rvalid;
    wire [23:0] vw_addr, vr_addr;
    wire [31:0] vw_data, vr_rdata;
    wire [15:0] underruns;
    wire [1:0] layout;
    wire [23:0] s_rgb;
    wire s_de, s_hs, s_vs;
    reg vid_t = 0;                          // nds_video's output phase
    always @(posedge clk_vid) vid_t <= !vid_t;
    nds_video video (.clk(clk_sys), .reset(rst_sys), .vid_t(vid_t), .layout_in(layout_sel), .rotation(set_b[SET_SCREEN_ROTATION_BIT +: 2]), .touch(cursor), .pen(pen),
        // the drawn cursor is the pen's point: it follows a gesture and returns to the cursor after it
        // (docs/touch-gestures.md; pen_x/pen_y are cur_x/cur_y when no gesture runs)
        .cur_x(pen_x), .cur_y(pen_y),
        .px_valid(px_valid), .px_eng(px_eng), .px_line(px_line), .px_x(px_x), .px_rgb(px_rgb),
        .line_start(line_start), .vcount(vcount), .swap(powcnt1[15]), .frame_pulse(frame_pulse),
        .w_req(vw_req), .w_addr(vw_addr), .w_data(vw_data), .w_ack(vw_ack),
        .r_req(vr_req), .r_addr(vr_addr), .r_ack(vr_ack), .r_rvalid(vr_rvalid), .r_rdata(vr_rdata),
        .underruns(underruns), .layout(layout), .rgb(s_rgb), .de(s_de), .hs(s_hs), .vs(s_vs));
    wire [31:0] vr_c_wdata;
    wire [3:0] vr_c_be;
    nds_sdram_xport #(.QW(4), .SHARED(1)) x_vrd (.clk_sys(clk_sys), .clk_mem(clk_mem), .reset(rst_sys),
        .s_req(vr_req), .s_we(1'b0), .s_quad(1'b1), .s_addr(vr_addr), .s_wdata(32'd0), .s_be(4'hF),
        .s_ack(vr_ack), .s_rvalid(vr_rvalid), .s_rdata(vr_rdata),
        .m_valid(p_valid[0]), .m_we(p_we[0]), .m_addr(p_addr[23:0]), .m_n(p_n[3:0]), .m_wdata(p_wdata[31:0]),
        .m_be(p_be[3:0]), .m_take(p_take[0]), .w_valid(ws_v[0]), .w_data(ws_d));
    // RING: the line ring's 32-byte block reads, bus port 6 (last: the others
    // keep their order)
    generate if (RING_I != 0) begin : g_ring
        nds_sdram_xport #(.QW(8), .SHARED(1)) x_rg (.clk_sys(clk_sys), .clk_mem(clk_mem), .reset(rst_sys),
            .s_req(rg_rreq), .s_we(1'b0), .s_quad(1'b1), .s_addr(rg_raddr), .s_wdata(32'd0), .s_be(4'hF),
            .s_ack(rg_rack), .s_rvalid(rg_rvalid), .s_rdata(rg_rdata),
            .m_valid(p_valid[6]), .m_we(p_we[6]), .m_addr(p_addr[167:144]), .m_n(p_n[27:24]), .m_wdata(p_wdata[223:192]),
            .m_be(p_be[27:24]), .m_take(p_take[6]), .w_valid(ws_v[6]), .w_data(ws_d));
    end else begin : g_noring
        assign rg_rack = 1'b0; assign rg_rvalid = 1'b0; assign rg_rdata = 32'd0;
        if (NP > 6) begin : g_p6idle
            assign p_valid[6] = 1'b0; assign p_we[6] = 1'b0; assign p_addr[167:144] = 24'd0; assign p_n[27:24] = 4'd0;
            assign p_wdata[223:192] = 32'd0; assign p_be[27:24] = 4'd0;
        end
    end endgenerate
    // DIAG: the recorder's SDRAM writes (single words, lowest priority: bus port 7)
    wire        diag_w_req, diag_w_ack;
    wire [23:0] diag_w_addr;                // SDRAM word address (the log at byte 0x400000: word 0x100000)
    wire [31:0] diag_w_data;
    generate if (DIAG != 0) begin : g_diagport
        nds_sdram_xport #(.QW(4), .SHARED(1)) x_dg (.clk_sys(clk_sys), .clk_mem(clk_mem), .reset(rst_sys),
            .s_req(diag_w_req), .s_we(1'b1), .s_quad(1'b0), .s_addr(diag_w_addr), .s_wdata(diag_w_data), .s_be(4'hF),
            .s_ack(diag_w_ack), .s_rvalid(), .s_rdata(),
            .m_valid(p_valid[7]), .m_we(p_we[7]), .m_addr(p_addr[191:168]), .m_n(p_n[31:28]), .m_wdata(p_wdata[255:224]),
            .m_be(p_be[31:28]), .m_take(p_take[7]), .w_valid(1'b0), .w_data(32'd0));
    end else begin : g_nodiagport
        assign diag_w_ack = 1'b0;
    end endgenerate
    // the ring's client: the 3D line ring (nds_gpu3d, through nds_top's rg_*);
    // RING_GEN (simulation) drives it with nds_ring_gen's checked traffic instead
`ifdef RING_GEN
    nds_ring_gen ring_gen (.clk(clk_sys), .rst(rst_sys), .en(go), .wdrained(bw_empty), .w_req(rg_wreq), .w_addr(rg_waddr), .w_data(rg_wdata), .w_ack(rg_wack),
        .r_req(rg_rreq), .r_addr(rg_raddr), .r_ack(rg_rack), .r_valid(rg_rvalid), .r_data(rg_rdata));
`else
    assign rg_wreq = ds_rg_wreq; assign rg_waddr = ds_rg_waddr; assign rg_wdata = ds_rg_wdata;
    assign rg_rreq = ds_rg_rreq; assign rg_raddr = ds_rg_raddr;
`endif
    // bottom-screen writes: {word address, data} into a FIFO to clk_mem, whose
    // head the SDRAM controller writes in row chains (#222: 128 single
    // writes per line fell behind VRAM traffic and lost lines)
    // RING: the line ring's block writes share this FIFO (the controller
    // chains a block's 8 consecutive words in one row opening). A block
    // starts only while the bottom screen isn't writing, then goes in whole
    // (the bottom screen waits up to 8 clocks).
    reg  [3:0]  rg_k = 0;                   // words of the ring block taken (0: none in progress)
    wire        rg_go  = RING_I != 0 && rg_wreq && !bw_full && (rg_k != 0 || !vw_req);
    wire        rg_wack = rg_go;
    // the display capture's word pairs (nds_vram CAP_CHAIN): the lowest priority, and never inside a ring block
    wire        cw_go = CAP_CHAIN != 0 && cw_valid && !bw_full && rg_k == 4'd0 && !rg_wreq && !vw_req;
    assign cw_ack = cw_go;
    always @(posedge clk_sys) if (rst_sys) rg_k <= 0; else if (rg_go) rg_k <= rg_k == 4'd7 || ds_rg_wlast ? 4'd0 : rg_k + 1'b1;
    assign vw_ack = vw_req && !bw_full && !rg_go;
    nds_dcfifo #(.W(56), .A(6)) x_vwr (.wclk(clk_sys), .wreset(rst_sys), .wr(vw_ack || rg_go || cw_go),
        .wdata(rg_go ? {rg_waddr, rg_wdata} : cw_go ? {cw_addr, cw_data} : {vw_addr, vw_data}),
        .full(bw_full), .wempty(bw_empty), .wfill(bw_fill), .overflow(), .rclk(clk_mem), .rd(bw_read), .valid(bw_valid), .rdata(bw_q));
    // one pixel per clk_vid (clk_sys / 4, same PLL): nds_video changes s_* two clk_sys clocks after each clk_vid edge (vid_t)
    reg [23:0] o_rgb = 0;
    reg o_de = 0, o_hs = 0, o_vs = 0;
    always @(posedge clk_vid) begin o_rgb <= s_rgb; o_de <= s_de; o_hs <= s_hs; o_vs <= s_vs; end
    assign video_rgb = o_rgb, video_de = o_de, video_hs = o_hs, video_vs = o_vs, video_skip = 1'b0;
    assign video_rgb_clock = clk_vid, video_rgb_clock_90 = clk_vid90;

    // ---------------- audio ----------------
    // The DS mixer's 32,768 Hz samples are linearly interpolated on clk_sys
    // (from the previous sample to the newest over one 2,048-clock period,
    // one sample late) and the running value crosses to audio_sclk as held
    // words (nds_bundle_cdc), which the I2S takes at 48 kHz. Sample-and-hold
    // at 48 kHz repeated samples irregularly and sounded buzzy (#95, NSMB's
    // menu) although the DS output matched melonDS's spectrum.
    wire audio_sclk;
    mf_audio_pll audio_pll (.refclk(clk_74b), .rst(!power_reset_n), .outclk_0(audio_mclk), .outclk_1(audio_sclk), .locked());
    wire signed [15:0] ai_l, ai_r;
    wire [31:0] aud_s;
    wire aud_busy;
    nds_audio_interp audio_interp (.clk(clk_sys), .in_pre(aud_pre), .hold(aud_busy), .in_l(aud_l), .in_r(aud_r), .out_l(ai_l), .out_r(ai_r));
    nds_bundle_cdc #(.W(32), .SOURCE_HOLDS(1)) x_audio (.a_clk(clk_sys), .a_send(!aud_busy), .a_data({ai_l, ai_r}), .a_busy(aud_busy),
        .b_clk(audio_sclk), .b_recv(), .b_data(aud_s));
    sound_i2s #(.SIGNED_INPUT(1)) sound (.audio_sclk(audio_sclk), .audio_l(aud_s[31:16]), .audio_r(aud_s[15:0]),
        .audio_lrck(audio_lrck), .audio_dac(audio_dac));

    // ---------------- log (32 words, Saves/nds/common/nds-log.bin) ----------------
    // sys words: frames, retired instructions and the last PC of each CPU, video underruns
    // the debug log (NDS_DEBUG=1): status words, the per-second history and
    // nds_log behind the bridge at 0x40000000 (tools/ds/decode_log.py)
    wire [31:0] log_rd;
    generate if (NDS_DEBUG != 0) begin : g_log
        reg [31:0] frames = 0, ret9 = 0, ret7 = 0, pc9 = 0, pc7 = 0;
        always @(posedge clk_sys) begin
            if (frame_pulse) frames <= frames + 1'b1;
            if (dbg_retire) begin
                if (dbg_tid) begin ret7 <= ret7 + 1'b1; pc7 <= dbg_pc; end
                else begin ret9 <= ret9 + 1'b1; pc9 <= dbg_pc; end
            end
            if (rst_sys) begin frames <= 0; ret9 <= 0; ret7 <= 0; end
        end
        // per-second history (words 32..127, a ring by second; word 22 = seconds):
        // {ARM9, ARM7} instructions retired in each 60 DS frames, in 1,024s
        reg [5:0] sec_f = 0;
        reg [31:0] secs = 0, r9_0 = 0, r7_0 = 0, h_word = 0;
        reg [6:0] h_idx = 0, h_next = 7'd32;
        reg h_turn = 0;
        wire [31:0] d9 = ret9 - r9_0, d7 = ret7 - r7_0;
        always @(posedge clk_sys) begin
            if (frame_pulse) begin
                if (sec_f == 6'd59) begin
                    sec_f <= 0; secs <= secs + 1'b1;
                    h_idx <= h_next; h_next <= h_next == 7'd127 ? 7'd32 : h_next + 1'b1;
                    h_word <= {d9[25:10], d7[25:10]};
                    r9_0 <= ret9; r7_0 <= ret7;
                end else sec_f <= sec_f + 1'b1;
            end
            if (rst_sys) begin sec_f <= 0; secs <= 0; r9_0 <= 0; r7_0 <= 0; h_idx <= 0; h_next <= 7'd32; end
        end
        // DS lines not drawn in time (nds_disp stat_late): the total, the most
        // in one frame, and the last one's line and frame
        reg [31:0] late_n = 0, late_fr = 0;
        reg [15:0] late_f = 0, late_max = 0;
        reg [8:0]  late_line = 0;
        always @(posedge clk_sys) begin
            if (stat_late) begin late_n <= late_n + 1'b1; late_line <= vcount; late_fr <= frames; end
            if (frame_pulse) begin
                if (late_f > late_max) late_max <= late_f;
                late_f <= stat_late ? 16'd1 : 16'd0;
            end else if (stat_late) late_f <= late_f + 1'b1;
            if (rst_sys) begin late_n <= 0; late_f <= 0; late_max <= 0; end
        end
        wire [8*32-1:0] sys_words = {{14'd0, layout, underruns}, {31'd0, running}, pc7, pc9, ret7, ret9, frames, 32'h4E44_5332};
        wire ss_send, ss_busy, ss_recv, sw_send;
        wire [38:0] ss_data, ss_data74, sw_data;
        nds_status_stream #(.N(8), .BASE(7'd8)) sys_stream (.clk(clk_sys), .words(sys_words), .busy(ss_busy || h_turn),
            .send(sw_send), .data(sw_data));
        // after each round of the fixed words one more, in turn: the seconds
        // (word 22), sound steps that started late (23), the longest sound memory
        // access in clk_sys cycles (24), the newest history entry, late DS
        // lines (25), {the most in a frame, the last one's line} (26), the
        // last one's frame (27)
        reg [2:0] h_sel = 0;
        always @(posedge clk_sys)
            if (sw_send && sw_data[38:32] == 7'd15) h_turn <= 1;
            else if (h_turn && !ss_busy) begin h_turn <= 0; h_sel <= h_sel == 3'd6 ? 3'd0 : h_sel + 1'b1; end
        assign ss_send = sw_send || (h_turn && !ss_busy);
        assign ss_data = !h_turn ? sw_data : h_sel == 3'd0 ? {7'd22, secs} : h_sel == 3'd1 ? {7'd23, snd_late} :
                         h_sel == 3'd2 ? {7'd24, 16'd0, snd_wait_max} : h_sel == 3'd4 ? {7'd25, late_n} :
                         h_sel == 3'd5 ? {7'd26, late_max, 7'd0, late_line} : h_sel == 3'd6 ? {7'd27, late_fr} :
                         h_idx != 0 ? {h_idx, h_word} : {7'd22, secs};
        nds_bundle_cdc #(.W(39)) x_sys (.a_clk(clk_sys), .a_send(ss_send), .a_data(ss_data), .a_busy(ss_busy),
            .b_clk(clk_74a), .b_recv(ss_recv), .b_data(ss_data74));
        // bus words: ROM cache
        wire [6*32-1:0] bus_words = {st_wait, st_blocks, st_cmds, st_lookups, {30'd0, cache_fail, cache_ready}, rom_size_b};
        wire bs_send, bs_busy, bs_recv;
        wire [38:0] bs_data, bs_data74;
        nds_status_stream #(.N(6), .BASE(7'd16)) bus_stream (.clk(clk_bus), .words(bus_words), .busy(bs_busy),
            .send(bs_send), .data(bs_data));
        nds_bundle_cdc #(.W(39)) x_bus (.a_clk(clk_bus), .a_send(bs_send), .a_data(bs_data), .a_busy(bs_busy),
            .b_clk(clk_74a), .b_recv(bs_recv), .b_data(bs_data74));
        wire [8*32-1:0] local_words = {sizefw, size7, size9, rom_size, ms, {31'd0, f_overflow}, 32'h0200_0000, 32'h4E44_5331};
        nds_log #(.NLOCAL(8)) log (.clk(clk_74a), .local_words(local_words),
            .b_recv(bs_recv), .b_data(bs_data74), .m_recv(ss_recv), .m_data(ss_data74),
            .rd_addr(bridge_addr[8:2]), .rd_data(log_rd), .vclk(clk_74a), .v_addr(7'd0), .v_data());
    end else begin : g_nolog
        assign log_rd = 32'd0;
    end endgenerate
    reg log_window = 0;
    always @(posedge clk_74a) log_window <= bridge_addr[31:24] == 8'h40 && bridge_addr[23:9] == 0;
    always @* begin
        bridge_rd_data = 0;
        if (bridge_addr[31:24] == 8'hF8) bridge_rd_data = cmd_bridge_rd_data;
        else if (log_window) bridge_rd_data = log_rd;
        else if (save_sel) bridge_rd_data = save_rd;
    end

    // ---------------- diagnostics taps (docs/diag.md; the DIAG recorder reads
    // them; unused, they are pruned) ----------------
    // clk_sys events, one bit per clock
    // the ROM cache (clk_bus = clk_sys / 2, same PLL): waiting for an APF fetch, in clk_sys clocks; a fetch
    // command, once (its clk_bus pulse spans two clk_sys clocks)
    reg dk_wait = 0, dk_cmd = 0, dk_cmd_d = 0;
    always @(posedge clk_sys) begin dk_wait <= diag_k_wait; dk_cmd <= diag_k_cmd; dk_cmd_d <= dk_cmd; end
    wire [1:0] diag_k_ev = {dk_cmd && !dk_cmd_d, dk_wait};
    wire [5:0] diag_i_ev = {
        !bw_empty,                          // [5] ring/bottom-screen writes not yet in the SDRAM controller
        rg_rreq && !rg_rack,                // [4] a ring read waiting
        rg_wreq && !rg_wack,                // [3] a ring write word waiting
        mr_req && !mr_ack,                  // [2] a main-RAM (PSRAM) request waiting
        mr_req && mr_ack,                   // [1] a main-RAM request taken
        vm_req && vm_blk && !vm_we && vm_ack};  // [0] a VRAM block read taken
    // clk_mem events (count them on clk_mem, cross per-frame totals)
    wire [2*NP:0] diag_m_ev = {sd_ref_late, p_take, p_valid & ~p_take};
    // values (clk_sys)
    wire [6:0]  diag_i_wfifo_fill = bw_fill;   // the write-chain FIFO's fill (a few clocks high); max it per frame
    wire [15:0] diag_i_underruns  = underruns;
    // latency pulses (clk_sys): a VRAM block read taken, then its 8th word;
    // a PSRAM read taken, then its first word
    reg  [1:0] dm_pend = 0;                 // VRAM blocks in flight (<= 2, in order)
    reg  [2:0] dm_w = 0;
    wire diag_m_start = vm_req && vm_blk && !vm_we && vm_ack;
    wire diag_m_stop  = vm_rvalid && dm_pend != 2'd0 && dm_w == 3'd7;
    always @(posedge clk_sys) begin
        if (rst_sys) begin dm_pend <= 0; dm_w <= 0; end
        else begin
            if (vm_rvalid && dm_pend != 2'd0) dm_w <= dm_w + 3'd1;
            dm_pend <= dm_pend + (diag_m_start ? 2'd1 : 2'd0) - (diag_m_stop ? 2'd1 : 2'd0);
        end
    end
    reg  dp_wait = 0;                       // a PSRAM read waiting for its first word
    wire diag_p_start = mr_req && mr_ack && !mr_we;
    wire diag_p_stop  = mr_rvalid && dp_wait;
    always @(posedge clk_sys)
        if (rst_sys) dp_wait <= 0;
        else if (diag_p_start) dp_wait <= 1;
        else if (diag_p_stop) dp_wait <= 0;

    // the recorder (nds_diag, docs/diag.md): events 0-41 one bit a clock (40-41: the ROM cache's APF waits and fetch commands), 42-48 the clk_mem counts
    // (the grant waits of bus ports 0-4 and 6, then refresh late; port 5, the save's quit read-back, and 7,
    // the recorder's own writes, are not crossed), 0-3 a clock; the 6 value words; 4 latency histograms.
    // The line histograms (late 3D/2D lines by position) are off (#608: ~150 ALMs; NL = 2 restores them).
    generate if (DIAG != 0) begin : g_diag
        wire [13:0] xm_inc;
        nds_diag_xmem #(.N(7)) xm (.clk_mem(clk_mem), .clk_sys(clk_sys), .rst_sys(rst_sys),
            .ev_mem({diag_m_ev[2*NP], diag_m_ev[6], diag_m_ev[4:0]}), .inc(xm_inc));
        wire [3:0] hv; wire [15:0] hb;
        nds_diag_lat #(.MODE(0))           lt_tex  (.clk(clk_sys), .rst(rst_sys), .start(diag_t_start), .stop(diag_t_stop), .v(hv[0]), .bin(hb[3:0]));
        nds_diag_lat #(.MODE(2))           lt_vm   (.clk(clk_sys), .rst(rst_sys), .start(diag_m_start), .stop(diag_m_stop), .v(hv[1]), .bin(hb[7:4]));
        nds_diag_lat #(.MODE(1), .STEP(4)) lt_ps   (.clk(clk_sys), .rst(rst_sys), .start(diag_p_start), .stop(diag_p_stop), .v(hv[2]), .bin(hb[11:8]));
        nds_diag_lat #(.MODE(3))           lt_v2d  (.clk(clk_sys), .rst(rst_sys), .start(diag_v_start), .stop(diag_v_stop), .v(hv[3]), .bin(hb[15:12]));
        // the write-chain FIFO's high-water mark in the last frame; DS frames since boot (line 192 starts)
        reg [6:0] wf_max = 0, wf_held = 0;
        reg [31:0] dsf = 0;
        always @(posedge clk_sys) begin
            if (rst_sys) begin wf_max <= 0; wf_held <= 0; dsf <= 0; end
            else begin
                if (frame_pulse) begin wf_held <= wf_max; wf_max <= diag_i_wfifo_fill; end
                else if (diag_i_wfifo_fill > wf_max) wf_max <= diag_i_wfifo_fill;
                if (line_start && vcount == 9'd192) dsf <= dsf + 1'b1;
            end
        end
        // the build's options (header word 3; tools/ds/diag_log.py)
        localparam [31:0] CFG = {G3D_TL[3:0], G3D_TXD[3:0], 3'd0, G3D_NXB != 0, G3D_TCV2 != 0, G2D_MOSAIC != 0, WIFI != 0,
            G3D_TCWAYS[1:0], G3D_TCMIF2 != 0, G3D_TCFAST != 0, G3D_LOWER != 0, G3D_SHADOW != 0, G3D_EDGE != 0,
            G3D_ATEST != 0, G3D_FOG != 0, G3D_TOON != 0, G3D_AA != 0, CPU_FAST != 0, ARM7_CACHE != 0,
            NDS_DEBUG != 0, RING != 0, SOUND != 0, GPU3D != 0};
        nds_diag #(.NE(42), .N2(7), .NV(6), .NH(4), .NL(0), .SEC_EVERY(DIAG_SEC), .CONFIG(CFG)) rec (.clk(clk_sys), .rst(rst_sys),
            .frame(frame_pulse),
            .ev({diag_k_ev, diag_i_ev, diag_d_ev, diag_c_ev, diag_g_ev, diag_r_ev}), .ev2(xm_inc),
            .val({32'd0, dsf, diag_d_bgmax, diag_i_underruns, diag_g_used, 9'd0, wf_held, diag_g_val, diag_r_val}),
            .h_v(hv), .h_bin(hb),
            .l_v(1'b0), .l_line(9'd0),
            .w_req(diag_w_req), .w_addr(diag_w_addr), .w_data(diag_w_data), .w_ack(diag_w_ack));
    end else begin : g_nodiag
        assign diag_w_req = 1'b0; assign diag_w_addr = 24'd0; assign diag_w_data = 32'd0;
    end endgenerate
endmodule
`default_nettype wire
