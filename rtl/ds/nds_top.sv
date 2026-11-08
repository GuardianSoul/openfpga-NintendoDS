// The integrated DS system (docs/phase2-integration.md): both CPUs, the
// system blocks, memories, VRAM banks, display and 2D engine, card, SPI,
// RTC and the boot program, on one clock (clk = 67.03 MHz = 2 x the DS bus
// clock). The Pocket shell (rtl/pocket/core_top_ds.sv) provides the
// external memories through the ports below; the simulation (sim/ds)
// provides models of them.
//
// Start-up: after rst the BIOS loader copies BIOS9 and BIOS7 from the boot
// image port into their RAMs once `go` is high (the shell raises it when the
// slots are loaded and the ROM cache is ready). Then both CPUs start in the
// boot ROM (sw/boot): ARM9 at 0xFFFF8000, ARM7 at 0x00008004. The boot
// program direct-boots the cartridge the way melonDS's SetupDirectBoot does.
module nds_top #(
    parameter BOOTROM = "build/boot/bootrom.hex",
    // 1: the boot ROM (8 KiB) is loaded with the BIOS from the boot image port (sel 3) into the external SRAM
    // (byte 0x1E000) and read there like the BIOS, instead of an M10K ROM (7 M10K); 0: the M10K ROM (BOOTROM)
    parameter integer BOOT_SRAM = 0,
    // 1: CPU OAM reads through the 2D engine's OAM read port while the OBJ engine is idle (nds_fabric OAM_SHARE,
    // gpu2d OAM_CPU): frees the fabric's OAM copy (2 M10K); 0: the copy
    parameter integer OAM_SHARE = 0,
    parameter bit SND_CAPTURE = 1'b1,   // sound CAPTURE (0: temporary, docs/ds-rules.md)
    parameter integer SOUND = 0,        // 1: rtl/sound (16 channels, capture); 0: a register stub
    parameter integer GPU3D = 0,        // 1: rtl/gpu3d (geometry engine, rasterizer: nds_gpu3d); 0: a register stub
    parameter integer GX_USORT = 1,     // GPU3D=1: the polygon sort in the geometry microcode (gpu3d_geom USORT; 0: gpu3d_gxsort)
    parameter integer GX_LUNIT = 1,     // GPU3D=1: gpu3d_geom LUNIT, the lighting unit (mkds-heavy: with VFIN 2, engine −17.2%)
    parameter integer GX_VFIN = 2,      // GPU3D=1: gpu3d_geom VFIN (2: VFIN-lite)
    parameter integer GX_FF = 1,        // GPU3D=1: gpu3d_geom FF, the geometry redesign (with GX_USORT, GX_LUNIT, GX_VFIN 1)
    parameter integer GX_GATH16 = 0,    // gpu3d_gxfront GATH16: the GX spill's gather 16 entries deep
    parameter integer GX_ENGM10K = 1,   // nds_gpu3d GX_ENGM10K: the engine's VC and VOC tables in M10K (0: MLAB, -2 M10K)
    parameter integer G3D_VYSM10K = 1,  // nds_gpu3d VYS_M10K: the raster front's vertex y table in M10K (0: MLAB, -1 M10K)
    parameter integer GX_SPAW = 12,     // gpu3d_gxfront SP_AW: the GX spill ring, 2^GX_SPAW entries at SDRAM byte 0x300000 (14: 128 KiB)
    parameter integer DX_SKID = 0,      // nds_gpu3d DX_SKID: a skid word for posted DMA_GX words
    parameter integer GX_SPILL = 1,     // GPU3D=1: the GX entries beyond the on-chip 512 spill to SDRAM (with RING's ports)
    parameter integer ARM7_CACHE = 1,   // 1: ARM7 port caches in front of the SRAM; 0: none (nds_arm7_port_min)
    // with ARM7_CACHE: log2 fetch and data cache lines (16 bytes each); with 3D
    // the small ones, as core_top_ds (512 B / 256 B, nds-fit #198)
    parameter integer A7_IL = GPU3D != 0 ? 5 : 7,
    parameter integer A7_DL = GPU3D != 0 ? 4 : 6,
    parameter integer DISP_AR_RAM = 1,  // nds_disp: 2D engine registers in MLAB (AR_RAM)
    parameter integer G2D_WST_RF = 1,   // gpu2d: per-pass state words from its register file (WST_RF)
    parameter integer G3D_PLANE = 1,    // GPU3D=0: the 3D layer shows the clear colour / rear-plane bitmap (nds_g3d_plane)
    // gpu2d's BG texel cache: 512 blocks without 3D (M10K to spare: KSSU's
    // five text layers need ~165 blocks a line pair), 128 with 3D. With the
    // hashed index 128 keeps NSMB 1-1 and KH's menu free of late lines under
    // the calibrated and a harsher VRAM model (docs/2d-engine.md); the maintainer's #557
    // (256, hashed) showed KH's menu clean on hardware
    parameter integer G2D_TEX_IDXW = GPU3D != 0 ? 7 : 9,
    // BG/OBJ mosaic (1); 0 drops it (~90 ALMs) when the fit needs room: no census run of
    // the maintainer's games uses it (docs/2d-engine.md)
    parameter integer G2D_MOSAIC = 1,
    parameter integer G2D_CAPTURE = 1,  // nds_disp CAPTURE: 0 no display capture (temporary fit setting)
    // the ext-palette caches' tag RAMs in MLAB with 3D: 2 M10K for ~8 LABs
    parameter integer G2D_TAG_MLAB = GPU3D != 0 ? 1 : 0,
    parameter integer WIFI = 1,         // the WiFi block: 1 nds_wifi (memory at VRAM-port 0x0F0000);
                                        // 2 external on the wx_* ports (tb_ds's C++ model); 0 absent
    parameter integer SYS_PUMP = 0,     // nds_sys PUMP: sys_math u_res written on clk_2x (2 -> 1 M10K) and its sqrt on clk_2x
    parameter integer WIFI_MC = 1,      // WIFI = 1: 1 the microcoded nds_wifi_mc, 0 nds_wifi's state machine
    // GPU3D=1: switchable 3D features (nds_gpu3d FEAT_*; 1 = as the DS)
    parameter integer G3D_AA = 1,       // anti-aliasing
    parameter integer G3D_TOON = 1,     // toon and highlight shading
    parameter integer G3D_FOG = 1,      // fog
    parameter integer G3D_ATEST = 1,    // the alpha test
    parameter integer G3D_EDGE = 1,     // edge marking
    parameter integer G3D_SHADOW = 1,   // shadow polygons
    parameter integer G3D_LOWER = 1,    // the lower 3D layer (AA, shadows, translucent edges blend with it)
    parameter integer G3D_TCFAST = 0,   // texture/palette caches: one lookup per clock (timing only)
    parameter integer G3D_TCMIF2 = 0,   // ... two blocks in flight (timing only)
    parameter integer G3D_TCV2 = 0,     // ... nds_g3d_cache2: a scanner prefetches ahead of the head (timing only)
    parameter integer G3D_TCWAYS = 1,   // ... texture cache ways (1, 2; timing only)
    parameter integer G3D_TXD = 0,      // gpu3d_raster TXD: texel misses overlap the pixels behind (timing only)
    parameter integer G3D_PXD = 0,      // gpu3d_raster PXD: palette request-to-use stages added (timing only)
    parameter integer G3D_FPSKIP = 0,   // gpu3d_raster FPSKIP: the final pass skips unused fog steps
    parameter integer G3D_TRU = 0,      // gpu3d_raster TRU: texture reads of the last two halfwords reused
    parameter integer G3D_TRUL = 0,     // gpu3d_raster TRUL: TRU with one entry per read slot
    parameter integer G3D_FPCLR = 0,    // gpu3d_raster FPCLR: the final pass's clear waits from F_3 on
    parameter integer G3D_YLIM2 = 0,    // nds_gpu3d YLIM2: the store two lines further past the ring's writes
    parameter integer G3D_NX2 = 0,      // nds_gpu3d NX2: the 3D ring also fetches line dline+2 (the display skips a late 2D line)
    parameter integer G2D_HURRY = 0,    // nds_disp HURRY_AT: the BG job's blocks urgent after that many clocks (hurry2d; 0: never)
    parameter integer G3D_RH_AT = 0,    // nds_gpu3d RH_AT: the ring's needed-line read urgent after that many clocks (rg_hurry; 0: never)
    parameter integer G3D_RPRI = 0,     // nds_gpu3d RPRI: the 3D ring reads the needed line before writing a staged one
    parameter integer G3D_LLR = 0,      // nds_gpu3d LLR: a late line shows the polygons drawn so far over the clear colour (DS rule)
    parameter integer CAP_CHAIN = 0,    // nds_vram CAP_CHAIN: capture word pairs through cw_* (core_top_ds)
    parameter integer VR_POST = 0,      // nds_vram VR_POST: CPU and DMA word writes through cw_* too
    parameter integer VR_RDB = 0,       // nds_vram VR_RDB: reads through an 8-word line
    parameter integer VR_PASS = 0,      // nds_vram VR_PASS: 2D reads wait only for posted words in their lines
    parameter integer VR_WB = 0,
    parameter integer VR_CWF = 0,
    parameter integer VR_HIT = 0,
    parameter integer VR_PF = 0,        // nds_vram VR_PF: next-line prefetch for DMA reads
    parameter integer VR_PDRAIN = 0,    // nds_vram VR_PDRAIN: a post ends when its own word leaves the FIFO
    parameter integer VR_YIELD = 0,     // nds_vram VR_YIELD: CPU waits give way to a 2D block request       // nds_vram VR_HIT: a read-line hit answered from S_IDLE       // nds_vram VR_CWF: a line fill acks the read with its word        // nds_vram VR_WB: a full-word write is acked from a one-word buffer
    parameter integer G3D_STORE_SD = 0, // nds_gpu3d STORE_SD: the polygon store in SDRAM, not PSRAM (needs GX_SPILL)
    parameter integer G3D_RING = 0,     // nds_gpu3d RING: the 3D line ring in SDRAM (core_top_ds RING)
    parameter integer G3D_DSHARE = 0,   // gpu3d_raster DSHARE: one front divider (edge + AA coverage)
    parameter integer G3D_LB2 = 0,      // gpu3d_raster LB2: line buffers as two RAMs per layer (2:1 read muxes)
    parameter integer G3D_LOV = 0,      // gpu3d_raster LOV: the next line starts while this one's pixels drain
    parameter integer G3D_EDIV4 = 0,    // gpu3d_raster EDIV4: the edge's perspective divider four bits a clock
    parameter integer G3D_SPO = 0,      // gpu3d_raster SPO: span overlap (four descriptor slots)
    parameter integer G3D_SPOSL = 4,    // ... its descriptor slots (gpu3d_raster SPO_SL)
    parameter integer G3D_SPOG = 0,     // ... or the descriptor through registers per pair of stages (gpu3d_raster SPOG; with G3D_SPO only)
    parameter integer G3D_SPOGN = 2,    // ... stages per group (gpu3d_raster SPOG_N)
    parameter integer G3D_EDGE2 = 0,    // gpu3d_raster EDGE2: a second edge unit (a polygon's two edges at once)
    parameter integer G3D_EP2 = 0,      // gpu3d_raster EP2: the edge unit as two stages (two edges at once)
    parameter integer G3D_FDB = 0,      // gpu3d_raster FDB (EP2): the input stage one polygon ahead of stage 1
    parameter integer G3D_VREG = 0,     // gpu3d_edge VREG: vertex RAM output registered (timing only; nds-fit #589)
    parameter integer G3D_NXB = 0,      // gpu3d_raster NXB: no next-span register, ~500 flops (timing only)
    parameter integer G3D_TL = 6,       // log2 texture cache sets
    parameter integer G3D_PL = 4,       // log2 palette cache lines
    parameter integer G3D_PUMP = 0,     // nds_gpu3d PUMP: the 3D caches' tag stores double-pumped on clk_2x (needs clk_2x)
    parameter integer G3D_RESTART = 1,  // 3D frame starts at line 215 even when the raster is busy (DS, run 24)
    parameter integer G3D_SWHOLD = 1,   // 3D: a swap the engine reaches by line 215 is drawn, the frame start waits for its sort (nds_gpu3d SWHOLD)
    parameter integer G3D_SWPC = 1,     // 3D: a late sort runs once the started frame is drawn (nds_gpu3d SWPC)
    parameter integer G3D_TCV2W = 1,    // 3D: texture cache ways at the same size (nds_gpu3d TC_V2W)
    parameter integer G3D_LMARK = 0,    // 3D (debug cards): late lines in colours by cause (nds_gpu3d LMARK)
    parameter integer G3D_SWL = 15,     // 3D: the late-swap window stays open this many lines past line 215 (nds_gpu3d SWHOLD; at most 40)
    // 3D: a 3D frame shown late (the engine behind the DS model's swap: SWHOLD/SWPC) is shown with the POWCNT1 bit 15
    // of the frame the DS shows it in, not the live one (disp_swap; docs/ds-rules.md, a known difference)
    parameter integer G3D_SWROUTE = 0,
    parameter integer G3D_LEAD = 46,    // 3D: the lines the raster may run ahead of the display (nds_gpu3d RLEAD, RING)
    parameter integer G3D_CL = 10,      // 3D: log2 polygon-store pool vertex chunks (nds_g3d_store CL)
    parameter integer G3D_DROP = 0,     // nds_g3d_store DROP (item 16): drop what the pool can't hold, not the frame
    parameter integer G3D_SL = 8,       // 3D: log2 polygon-store pool slots (nds_g3d_store SL)
    parameter integer CPU_FAST = 0,     // 1: the CPUs on clk_cpu (rtl/arm/cpu_domain.sv)
    // 1: the ARM9 keeps running during its DMA (the DS, hwref run 22 dmacpu): TCM, cache hits and
    // buffered work go on, any ARM9 bus request waits until the DMA ends; 0: it halts (melonDS)
    parameter integer DMA9_RUN = 1,
    // 1: ARM9 line fills as one request (arm9_mem BURST): with CPU_FAST it crosses to clk_sys once
    // per line, not once per word
    parameter integer A9_BURST = 1,
    parameter integer A9_EVB = 0,    // 1: the ARM9's dirty fill victim goes to an eviction buffer, the fill starts at once (arm9_mem EVB)
    parameter integer A9_XD = 0,      // ARM9 cache sets: 2^XD (D) / 2^XI (I) times the DS's
    parameter integer A9_XI = 0,
    parameter integer A9_OPT = 0,     // ARM9 speed options (arm_core / arm9_mem bitmask)
    parameter integer A9_EARLYD = 0, // 1: a refused D access's fetch hold ends with the fill's last word (arm9_mem EARLYD)
    parameter integer A9_EVBW = 0,   // 1: the eviction buffer drains as one block write (PSRAM_BW; CPU_FAST = 0)
    // 1: solo mode (arm_core A9_SOLO): the ARM9 issues every cycle while the ARM7 is halted
    parameter integer A9_SOLO = 0,
    parameter integer MR_BLOCK = 1,  // 1: the ARM9's 32-byte main-RAM blocks (mr_n8/mr_wnext; nds_fabric); on with 3D off (KH speed set)
    parameter integer A7_IO = 0,     // 1: an ARM7 request goes before an ARM9 DMA unit (nds_fabric A7_IO; the DS's ARM7 bus)
    parameter integer DMA_UNIT = 0,  // 1: an ARM9 DMA unit from main RAM is one fabric request (sys_dma FAST, nds_fabric DMA_FAST)
    parameter integer DMA_RA = 0,    // 1 (with DMA_UNIT): a unit's write reads the next source quad ahead (nds_fabric DMA_RA)
    parameter integer DMA_B8 = 0,    // nds_fabric DMA_B8: DMA lines of 32 bytes, one PSRAM burst
    parameter integer DMA_PACE = 0,  // nonzero: DMA units no faster than the DS per route (nds_fabric DMA_PACE; 0 off)
    parameter integer DMA_PACE_GX = 80, // nds_fabric DMA_PACE_GX: the GX FIFO route's floor, eighths of a clk_sys
    parameter integer DMA_PW = 0,         // nds_fabric DMA_PW: a DMA's main-RAM word write posted
    parameter integer PO_WD = 0,          // nds_fabric PO_WD: palette/OAM writes skip S_RAM
    parameter integer DMA_GX = 0     // 1 (with DMA_UNIT, GPU3D): a unit's GX FIFO/command word posted to the geometry engine (nds_fabric DMA_GX); 3: the ARM9's too
) (
    input  logic        clk,
    input  logic        clk_cpu,        // CPU_FAST: the CPUs' clock (unused otherwise)
    input  logic        clk_2x,         // 2 x clk_sys, phase 0 (double-pumped RAMs: G3D_PUMP)
    input  logic        rst,
    input  logic        go,
    input  logic [31:0] rom_size,
    input  logic        mem_dirty,      // 1: memories power up random (the Pocket); 0: zero (the simulation models)
    input  logic [7:0]  save_info,      // the shell's save types for the boot program (docs/saves.md), static
    input  logic [20:0] sv_loaded,      // bytes of the loaded save file, static
    output logic [2:0]  save_type,      // BOOTCTL[6:4], the boot program's save type (static after boot)
    // the WiFi block's bus, ARM7 0x04800000+: requests out always; with WIFI = 2 the
    // answer (wx_ack any later cycle, wx_rdata) and IRQ pulses (wx_irq, the ARM7's IF
    // bit 24) come in; with WIFI = 1 nds_wifi's answers go out on wx_rtl_* (lockstep checks)
    output logic        wx_req,
    output logic        wx_we,
    output logic [3:0]  wx_be,
    output logic [23:2] wx_addr,
    output logic [31:0] wx_wdata,
    input  logic        wx_ack,
    input  logic [31:0] wx_rdata,
    input  logic        wx_irq,
    output logic        wx_power,       // POWCNT2 bit 1 (WiFi enabled)
    output logic        wx_rtl_ack,
    output logic [31:0] wx_rtl_rdata,
    output logic        wx_rtl_irq,
    // player
    input  logic [11:0] keys,           // DS order: A B Sel Start Right Left Up Down R L X Y
    input  logic        pen,
    input  logic [7:0]  pen_x,
    input  logic [7:0]  pen_y,
    input  logic        rtc_valid,
    input  logic [31:0] rtc_date,
    input  logic [31:0] rtc_time,
    // main RAM (4 MiB) and, from 0x400000, the 3D polygon store
    output logic        mr_req,
    output logic        mr_we,
    output logic [22:2] mr_addr,
    output logic [3:0]  mr_be,
    output logic [31:0] mr_wdata,
    input  logic        mr_ack,
    output logic        mr_n8,              // MR_BLOCK: a 32-byte block (8 read words; writes on mr_wnext)
    input  logic        mr_wnext,
    // the 3D line ring's SDRAM ports (nds_gpu3d; core_top_ds RING)
    output logic        cw_valid,       // the display capture's word pairs for the SDRAM write FIFO (nds_vram CAP_CHAIN)
    output logic [23:0] cw_addr,
    output logic [31:0] cw_data,
    input  logic        cw_ack,
    output logic        rg_wreq,
    output logic [23:0] rg_waddr,
    output logic [31:0] rg_wdata,
    input  logic        rg_wack,
    output logic        rg_rreq,
    output logic [23:0] rg_raddr,
    input  logic        rg_rack,
    input  logic        rg_rvalid,
    input  logic [31:0] rg_rdata,
    input  logic        rg_wdrained,        // every ring write so far has reached the SDRAM controller (core_top_ds bw_empty)
    input  logic [6:0]  rg_wfill,           // that FIFO's fill and pop count (nds_vram VR_PDRAIN; tie 0 without it)
    input  logic [6:0]  rg_wpcnt,
    input  logic        mr_rvalid,
    input  logic [31:0] mr_rdata,
    // VRAM (656 KiB physical)
    output logic        vm_req,
    output logic        vm_we,
    output logic        vm_blk,
    output logic [20:2] vm_addr,
    output logic [3:0]  vm_be,
    output logic [31:0] vm_wdata,
    input  logic        vm_ack,
    input  logic        vm_rvalid,
    input  logic [31:0] vm_rdata,
    // the external SRAM (256 KiB): ARM7 WRAM, shared WRAM, BIOS7
    // (nds_arm7_port); request held until done, read data with done
    output logic        fr_req,
    output logic        fr_we,
    output logic [17:2] fr_addr,
    output logic [3:0]  fr_be,
    output logic [31:0] fr_wdata,
    input  logic        fr_done,
    input  logic [31:0] fr_rdata,
    // boot images: 0 BIOS9, 1 BIOS7, 2 firmware; word reads
    output logic        sr_req,
    output logic [1:0]  sr_sel,
    output logic [19:2] sr_addr,
    input  logic        sr_ack,
    input  logic [31:0] sr_rdata,
    // cartridge ROM (16-byte reads)
    output logic        cr_req,
    output logic [31:4] cr_addr,
    input  logic        cr_ack,
    input  logic        cr_rvalid,
    input  logic [31:0] cr_rdata,
    // video
    output logic        px_valid,
    output logic        px_eng,
    output logic [7:0]  px_line,
    output logic [7:0]  px_x,
    output logic [17:0] px_rgb,
    output logic        line_start,
    output logic [8:0]  vcount,
    output logic [15:0] powcnt1,
    output logic        disp_swap,       // the screens' POWCNT1 bit 15 for nds_video (G3D_SWROUTE: a late 3D frame's own)
    // sound: one stereo sample per output step (32,768 Hz), melonDS's 16-bit values
    output logic        aud_valid,
    output logic        aud_pre,        // the clock before aud_l/aud_r load (sound out_pre)
    output logic [31:0] snd_late,       // sound steps that started late (since reset)
    output logic [15:0] snd_wait_max,   // longest sound memory access, clk_sys cycles
    output logic [15:0] aud_l,
    output logic [15:0] aud_r,
    // status and debug
    output logic        running,
    output logic        dbg_retire,
    output logic        dbg_tid,
    output logic [31:0] dbg_pc,
    output logic [31:0] dbg_cpsr,
    // diagnostics (docs/diag.md; NDSDiag connects them, the release build leaves them
    // unconnected): per clk_sys clock [0] ARM9 retire, [1] ARM9 halted, [2] ARM9 bus wait
    // main RAM, [3] DMA9 busy, [4] I fill start, [5] D fill start, [6] ARM9 bus wait GX
    // (0x04000400-7FF), [7] ARM9 bus wait other, [8] ARM7 retire, [9] ARM7 halted;
    // a block (n8) request rising, and its ack
    output wire  [9:0]  diag_c_ev,
    output wire         diag_f_start,
    output wire         diag_f_stop,
    output logic        dbg_wen,
    output logic [5:0]  dbg_wa,
    output logic [31:0] dbg_wd,
    output logic        mon_we,
    output logic [1:0]  mon_master,
    output logic        mon_cpu,
    output logic [31:0] mon_addr,
    output logic [3:0]  mon_be,
    output logic [31:0] mon_wdata,
    output logic        stat_late,
    output logic        hurry2d,        // nds_disp HURRY_AT (G2D_HURRY): the 2D engine's VRAM blocks are urgent
    output logic        rg_wlast,       // nds_gpu3d rg_wlast
    output logic        rg_hurry,       // nds_g3d_ring RH_AT (G3D_RH_AT): the ring's read is urgent
    // NDSDiag 2D (docs/diag.md; nds_disp): pruned when unconnected
    output wire  [4:0]  diag_d_ev,
    output wire  [15:0] diag_d_bgmax,
    output wire         diag_v_start,
    output wire         diag_v_stop,
    output wire         diag_l2d_v,
    output wire  [8:0]  diag_l2d_line,
    // NDSDiag geometry (docs/diag.md; nds_gpu3d): pruned when unconnected, 0 without 3D
    output wire  [7:0]  diag_g_ev,
    output wire  [31:0] diag_g_val,
    output wire  [15:0] diag_g_used,
    // NDSDiag raster (nds_gpu3d): 0 without 3D
    output wire  [10:0] diag_r_ev,
    output wire  [31:0] diag_r_val,
    output wire         diag_t_start,
    output wire         diag_t_stop,
    output wire         diag_l3d_v,
    output wire  [8:0]  diag_l3d_line
);
    // ---------------------------------------------------------------- clock phase
    logic tick;                         // the 33.51 MHz half of each pair of cycles
    always_ff @(posedge clk) tick <= rst ? 1'b0 : !tick;

    // ---------------------------------------------------------------- BIOS loader
    // BIOS9: 1K words, BIOS7: 4K words (BOOT_SRAM: then the boot ROM, 2K words, sel 3), from the boot image port
    logic        ld_busy, ld_done, ld_sel, ld_bt;
    logic [11:0] ld_a;
    logic        ld_we;
    logic [31:0] ld_d;
    logic        fw_req, fw_ack;
    logic [17:2] fw_addr;
    always_ff @(posedge clk) begin
        ld_we <= 1'b0;
        if (rst) begin
            ld_busy <= 1'b0; ld_done <= 1'b0; ld_sel <= 1'b0; ld_bt <= 1'b0; ld_a <= 12'd0;
        end else if (!ld_done) begin
            if (!ld_busy) begin if (go) ld_busy <= 1'b1; end
            else if (sr_ack) begin ld_we <= 1'b1; ld_d <= sr_rdata; end
            else if (lw_done) begin
                if (!ld_sel && ld_a == 12'd1023) begin ld_sel <= 1'b1; ld_a <= 12'd0; end
                else if (BOOT_SRAM != 0 && ld_sel && !ld_bt && ld_a == 12'd4095) begin ld_bt <= 1'b1; ld_a <= 12'd0; end
                else if (BOOT_SRAM == 0 ? ld_sel && ld_a == 12'd4095 : ld_bt && ld_a == 12'd2047) begin ld_done <= 1'b1; ld_busy <= 1'b0; end
                else ld_a <= ld_a + 12'd1;
            end
        end
    end
    // BIOS9 and BIOS7 go to the SRAM: the next word waits for the last one's write
    logic        lw_v, lw_done;
    always_ff @(posedge clk)
        if (rst) lw_v <= 1'b0;
        else if (ld_we) lw_v <= 1'b1;
        else if (lw_done) lw_v <= 1'b0;
    wire ld_fin = ld_done && !lw_v && !ld_we;
    assign sr_req  = ld_busy ? !lw_v && !ld_we : fw_req;
    assign sr_sel  = ld_busy ? (ld_bt ? 2'd3 : {1'b0, ld_sel}) : 2'd2;
    assign sr_addr = ld_busy ? {6'd0, ld_a} : {2'd0, fw_addr};
    assign fw_ack  = !ld_busy && sr_ack;
    assign running = ld_fin;

    // clk_2x's keeper while no double-pumped RAM uses it: one flop so the PLL output and its timing exist
    generate if (GPU3D == 0 || G3D_PUMP == 0) begin : g_c2keep
        (* preserve *) logic c2_keep = 1'b0;
        always_ff @(posedge clk_2x) c2_keep <= !c2_keep;
    end endgenerate

    // ---------------------------------------------------------------- CPUs
    logic        b9_req, b9_we, b9_ack;
    logic [31:0] b9_addr, b9_wdata, b9_rdata;
    logic [3:0]  b9_be, b9_tmr;
    logic        a7_i_req, a7_i_ok, a7_d_req, a7_d_we, a7_d_ok;
    logic [31:0] a7_i_addr, a7_i_rdata, a7_d_addr, a7_d_wdata, a7_d_rdata;
    logic [3:0]  a7_d_be;
    logic        irq9, irq7, wake7;             // ARM7 HALTCNT: halt until IE & IF (melonDS HaltInterrupted)
    logic [1:0]  dma_busy;
    logic [1:0]  dg_halt, dg_fill;              // {ARM7, ARM9} halted; ARM9 {I, D} fill starts

    // ---------------------------------------------------------------- memories
    logic        exmem_o7;
    logic [1:0]  wramcnt;
    // ARM7 fetch (port A), ARM7 data or fabric (port B)
    logic [10:0] p7_ib, p7_db;
    logic        p7_dboot;
    logic [10:0] f_boot_a;
    logic [31:0] f_wd;
    logic [31:0] boot_qa, boot_qb;
    wire         use_d = p7_dboot;          // port B to the ARM7 data side this cycle

    generate if (BOOT_SRAM == 0) begin : g_boot
        nds_tdp_ram #(.AW(11), .INIT(BOOTROM)) u_boot (.clk,
            .a_addr(p7_ib), .a_we(4'd0), .a_d(32'd0), .a_q(boot_qa),
            .b_addr(use_d ? p7_db : f_boot_a), .b_we(4'd0), .b_d(32'd0), .b_q(boot_qb));
    end else begin : g_noboot
        assign boot_qa = 32'd0; assign boot_qb = 32'd0;     // (the ARM7 and the fabric read the SRAM copy)
    end endgenerate

    // the SRAM's clients
    logic        x7_req, x7_we, x7_done, x7_stores, fx_req, fx_we, fx_done, fr_inv;
    logic [17:2] x7_addr, fx_addr, fr_inv_a;
    logic [3:0]  x7_be, fx_be;
    logic [31:0] x7_wdata, fx_wdata;
    nds_fr_arb u_frarb (.clk, .rst,
        .l_req(lw_v), .l_addr(ld_bt ? {5'b01111, ld_a[10:0]} : ld_sel ? {4'b0110, ld_a} : {6'b011100, ld_a[9:0]}), .l_wdata(ld_d), .l_done(lw_done),
        .a_req(x7_req), .a_we(x7_we), .a_addr(x7_addr), .a_be(x7_be), .a_wdata(x7_wdata), .a_stores(x7_stores),
        .a_done(x7_done),
        .f_req(fx_req), .f_we(fx_we), .f_addr(fx_addr), .f_be(fx_be), .f_wdata(fx_wdata), .f_done(fx_done),
        .inv(fr_inv), .inv_addr(fr_inv_a),
        .fr_req, .fr_we, .fr_addr, .fr_be, .fr_wdata, .fr_done);

    logic        f7_req, f7_we, f7_ack;
    logic [31:0] f7_addr, f7_wdata, f7_rdata;
    logic [3:0]  f7_be;
    generate if (ARM7_CACHE != 0 && CPU_FAST == 0) begin : g_a7mon
`ifndef ALTERA_RESERVED_QIS   // (Quartus rejects $test$plusargs)
    // simulation (+a7dbg): the ARM7's surroundings once it has retired
    // nothing for 2M cycles
    integer a7_quiet = 0;
    logic   a7_dbg = 1'b0, a7_said = 1'b0;
    initial a7_dbg = $test$plusargs("a7dbg");
    always_ff @(posedge clk) begin
        a7_quiet <= (dbg_retire && dbg_tid) ? 0 : a7_quiet + 1;
        if (a7_dbg && !a7_said && a7_quiet == 2000000) begin
            a7_said <= 1'b1;
            $display("a7dbg top: dma_busy %b fab st %0d tgt %0d mst %0d addr %h we %b | frarb own %0d a_req %b a_stores %b f_req %b fr_req %b",
                     dma_busy, u_fab.st, u_fab.tgt_q, u_fab.mst, u_fab.addr, u_fab.we, u_frarb.own, x7_req, x7_stores, fx_req, fr_req);
            $display("a7dbg top: a7 i_req %b i_ok %b i_addr %h d_req %b d_ok %b d_addr %h | p7 fl_v %b sf_n %0d xs_busy %b rp_v %b wb_v %b busy %b",
                     a7_i_req, a7_i_ok, a7_i_addr, a7_d_req, a7_d_ok, a7_d_addr, u_cpud.g_a7c.u_p7.fl_v, u_cpud.g_a7c.u_p7.sf_n, u_cpud.g_a7c.u_p7.xs_busy, u_cpud.g_a7c.u_p7.rp_v, u_cpud.g_a7c.u_p7.wb_v, u_cpud.g_a7c.u_p7.busy);
        end
    end
`endif
`ifndef ALTERA_RESERVED_QIS   // (Quartus rejects $test$plusargs)
    // simulation (+a7chk): a shadow of the SRAM, written by every writer
    // (ARM7 stores as the port accepts them, the others as they complete);
    // every cached ARM7 load and fetch must return its word
    logic [31:0] a7sh [0:65535];
    logic        a7chk = 1'b0;
    integer      a7bad = 0;
    initial begin
        a7chk = $test$plusargs("a7chk");
        for (int i = 0; i < 65536; i++) a7sh[i] = 32'd0;
    end
    // (re-read now and then: a loaded checkpoint brings the saving run's)
    logic [19:0] a7_rd = '0;
    always_ff @(posedge clk) begin
        a7_rd <= a7_rd + 1'b1;
        if (a7_rd == 20'd0) begin a7chk <= $test$plusargs("a7chk"); a7_dbg <= $test$plusargs("a7dbg"); end
    end
    always_ff @(posedge clk) if (a7chk) begin
        if (u_cpud.g_a7c.u_p7.su_v && u_cpud.g_a7c.u_p7.su_a[17:14] != 4'b0110)
            for (int b = 0; b < 4; b++) if (u_cpud.g_a7c.u_p7.su_be[b]) a7sh[u_cpud.g_a7c.u_p7.su_a][b*8 +: 8] <= u_cpud.g_a7c.u_p7.su_d[b*8 +: 8];
        if (fr_done && fr_we && u_frarb.own != 2'd2)
            for (int b = 0; b < 4; b++) if (fr_be[b]) a7sh[fr_addr][b*8 +: 8] <= fr_wdata[b*8 +: 8];
        if (a7_d_ok && u_cpud.g_a7c.u_p7.da_r == 2'd2 && !u_cpud.g_a7c.u_p7.da_w && !u_cpud.g_a7c.u_p7.prot_q && a7_d_rdata != a7sh[u_cpud.g_a7c.u_p7.da_xa[17:2]]) begin
            a7bad <= a7bad + 1;
            if (a7bad < 8) $display("a7chk: load %h (SRAM %h) = %h, expected %h", a7_d_addr_q, u_cpud.g_a7c.u_p7.da_xa, a7_d_rdata, a7sh[u_cpud.g_a7c.u_p7.da_xa[17:2]]);
        end
        if (a7_i_ok && u_cpud.g_a7c.u_p7.ia_r == 2'd2 && a7_i_rdata != a7sh[u_cpud.g_a7c.u_p7.ia_xa[17:2]]) begin
            a7bad <= a7bad + 1;
            if (a7bad < 8) $display("a7chk: fetch SRAM %h = %h, expected %h", u_cpud.g_a7c.u_p7.ia_xa, a7_i_rdata, a7sh[u_cpud.g_a7c.u_p7.ia_xa[17:2]]);
        end
    end
    logic [31:0] a7_d_addr_q;
    always_ff @(posedge clk) a7_d_addr_q <= a7_d_addr;
`endif
    end endgenerate
`ifndef ALTERA_RESERVED_QIS
    // +vcmon: each VRAMCNT change (the 3D caches' flush) with the line it lands on and the new banks A-G
    bit vc_on;
    initial vc_on = $test$plusargs("vcmon");
    always_ff @(posedge clk) if (vc_on && vramcnt_chg) $display("vcmon: VRAMCNT change at line %0d: A-D %h E-G %h", vcount, vramcnt[31:0], vramcnt[55:32]);
    // +g3dmon: per frame, GX register writes, geometry output and swaps
    bit gm_on;
    integer gm_gx = 0, gm_po = 0, gm_pv = 0, gm_sw = 0;
    initial gm_on = $test$plusargs("g3dmon");
    if (GPU3D != 0) begin : g_gmon
        always_ff @(posedge clk) if (gm_on) begin
            if (gx_req && io_we && gx_ack) gm_gx++;
            if (g_3d.u_gpu3d.po_valid && g_3d.u_gpu3d.po_ready) begin if (g_3d.u_gpu3d.po_type) gm_pv++; else gm_po++; end
            if (g_3d.u_gpu3d.so_done) gm_sw++;
            if (line_start && vcount == 9'd0) begin
                $display("g3dmon gx_writes %0d polys %0d verts %0d swaps %0d powcnt1 %h", gm_gx, gm_po, gm_pv, gm_sw, powcnt1);
                gm_gx = 0; gm_po = 0; gm_pv = 0; gm_sw = 0;
            end
        end
    end
`endif
`ifndef ALTERA_RESERVED_QIS
`ifndef SYNTHESIS
    // +a9prof: per frame (clk_sys cycles), where the ARM9's time goes, from diag_c_ev: retired
    // instructions; halted (WFI / IntrWait); its own DMA busy; waiting on its bus by target
    // (main RAM, VRAM, GX registers and FIFO, other); the rest runs. Each cycle counts once,
    // in that order.
    bit a9p_on;
    integer a9p_ret = 0, a9p_halt = 0, a9p_dma = 0, a9p_gx = 0, a9p_mr = 0, a9p_vr = 0, a9p_io = 0, a9p_cyc = 0;
    initial a9p_on = $test$plusargs("a9prof");
    always_ff @(posedge clk) if (a9p_on) begin
        a9p_cyc++;
        if (diag_c_ev[0]) a9p_ret++;
        if (diag_c_ev[1]) a9p_halt++;
        else if (diag_c_ev[3]) a9p_dma++;
        else if (diag_c_ev[2]) a9p_mr++;
        else if (dg_wait && b9_addr[27:24] == 4'h6) a9p_vr++;
        else if (diag_c_ev[6]) a9p_gx++;
        else if (diag_c_ev[7]) a9p_io++;
        if (line_start && vcount == 9'd0) begin
            $display("a9prof cyc %0d retired %0d halt %0d dma %0d bus_gx %0d bus_mainram %0d bus_vram %0d bus_other %0d run %0d",
                     a9p_cyc, a9p_ret, a9p_halt, a9p_dma, a9p_gx, a9p_mr, a9p_vr, a9p_io,
                     a9p_cyc - a9p_halt - a9p_dma - a9p_gx - a9p_mr - a9p_vr - a9p_io);
            a9p_ret = 0; a9p_halt = 0; a9p_dma = 0; a9p_gx = 0; a9p_mr = 0; a9p_vr = 0; a9p_io = 0; a9p_cyc = 0;
        end
    end
`endif
`endif
    // the CPUs and the ARM7's port (caches with ARM7_CACHE=1), on clk_cpu with CPU_FAST
    // the CPU reset as a register so it can go on a global line (one LAB input
    // freed in every LAB it reaches, #817): the CPUs leave reset one clk after
    // ld_fin instead of with it, the loader's handover only
    reg cpu_rst_q = 1'b1;
    always_ff @(posedge clk) cpu_rst_q <= rst || !ld_fin;
    cpu_domain #(.CPU_FAST(CPU_FAST), .ARM9_WAYS(GPU3D ? 2 : 4), .ARM7_CACHE(ARM7_CACHE),
                 .A7_IL(A7_IL), .A7_DL(A7_DL), .A9_BURST(A9_BURST), .A9_EVB(A9_EVB), .A9_EVBW(A9_EVBW), .A9_EARLYD(A9_EARLYD), .A7_BOOTF(BOOT_SRAM), .A9_OPT(A9_OPT), .A9_XD(A9_XD), .A9_XI(A9_XI), .MR_BLOCK(MR_BLOCK), .A9_SOLO(A9_SOLO)) u_cpud (
        .clk, .clk_cpu, .rst, .cpu_rst(cpu_rst_q),
        .run({!dma_busy[1], DMA9_RUN != 0 || !dma_busy[0]}), .irq({irq7, irq9}), .wake7, .wramcnt,
        .b9_n8, .b9_rvalid, .b9_wnext, .b9_req, .b9_we, .b9_addr, .b9_wdata, .b9_be, .b9_tmr, .b9_ack, .b9_rdata,
        .p7_ib, .boot_qa, .p7_db, .p7_dboot, .boot_qb,
        .x7_req, .x7_we, .x7_addr, .x7_be, .x7_wdata, .x7_stores, .x7_done, .x7_rdata(fr_rdata),
        .fr_inv, .fr_inv_a,
        .f7_req, .f7_we, .f7_addr, .f7_be, .f7_wdata, .f7_ack, .f7_rdata,
        .mon_we, .mon_addr,
        .dbg_wen, .dbg_wa, .dbg_wd, .dbg_retire, .dbg_tid, .dbg_pc, .dbg_cpsr, .dbg_halt(dg_halt), .dg_fill(dg_fill));
`ifndef ALTERA_RESERVED_QIS
    // (the ARM7 port's pipeline side, for the simulation monitors below)
    assign a7_i_req = u_cpud.a7_i_req; assign a7_i_ok = u_cpud.a7_i_ok; assign a7_i_addr = u_cpud.a7_i_addr;
    assign a7_i_rdata = u_cpud.a7_i_rdata; assign a7_d_req = u_cpud.a7_d_req; assign a7_d_ok = u_cpud.a7_d_ok;
    assign a7_d_addr = u_cpud.a7_d_addr; assign a7_d_rdata = u_cpud.a7_d_rdata;
`endif

    // ---------------------------------------------------------------- fabric
    logic        sn_req, sn_we, sn_ack;
    logic [31:0] sn_addr, sn_wdata, sn_rdata;
    logic        snd_ack;
    logic [31:0] snd_rdata;
    logic        dm_req, dm_we, dm_cpu, dm_size32, dm_ack;
    logic [31:0] dm_addr, dm_wdata, dm_rdata, dm_dst;
    logic        dm_unit, dm_more;
    logic        dx_valid, dx_ready, dx_idle;     // DMA_GX: a unit's word posted to the geometry engine
    logic        io_req, io_pre, io_cpu, io_we, io_ack;
    logic [3:0]  io_be;
    logic [23:2] io_addr;
    logic [31:0] io_wdata, io_rdata;
    logic        vc_req, vc_cpu, vc_we, vc_ack, vc_dma;
    logic [23:2] vc_addr;
    logic [3:0]  vc_be;
    logic [31:0] vc_wdata, vc_rdata;
    logic        pal_we, oam_we;
    // main RAM: the fabric and the 3D polygon store
    logic        fm_req, fm_we, fm_ack, fm_rvalid, g3_req, g3_we, g3_ack, g3_rvalid;
    logic        fm_n8, fm_wnext;
    // the ARM9's block requests (MR_BLOCK; arm9_mem's side connects b9_n8)
    logic        b9_n8, b9_rvalid, b9_wnext;

    // diagnostics (outputs diag_*, docs/diag.md): plain wires, pruned when unconnected
    logic        dg_b9q;
    wire         dg_wait = b9_req && !b9_ack;
    wire         dg_mr   = b9_addr[27:24] == 4'h2;
    wire         dg_gx   = b9_addr[27:24] == 4'h4 && b9_addr[23:12] == 12'h000 && b9_addr[11:10] == 2'b01;
    always_ff @(posedge clk) dg_b9q <= b9_req && b9_n8;
    assign diag_c_ev = {dg_halt[1], dbg_retire && dbg_tid, dg_wait && !dg_mr && !dg_gx, dg_wait && dg_gx,
                        dg_fill[0], dg_fill[1], dma_busy[0], dg_wait && dg_mr, dg_halt[0], dbg_retire && !dbg_tid};
    assign diag_f_start = b9_req && b9_n8 && !dg_b9q;
    assign diag_f_stop  = b9_ack && b9_n8;
    logic [21:2] fm_addr;
    logic [22:2] g3_addr;
    logic [3:0]  fm_be;
    logic [31:0] fm_wdata, g3_wdata;
    nds_mr_arb u_mrarb (.clk, .rst,
        .a_req(fm_req), .a_we(fm_we), .a_addr(fm_addr), .a_be(fm_be), .a_wdata(fm_wdata), .a_ack(fm_ack), .a_rvalid(fm_rvalid), .a_n8(fm_n8), .a_wnext(fm_wnext),
        .b_req(g3_req), .b_we(g3_we), .b_addr(g3_addr), .b_wdata(g3_wdata), .b_ack(g3_ack), .b_rvalid(g3_rvalid),
        .mr_req, .mr_we, .mr_addr, .mr_be, .mr_wdata, .mr_ack, .mr_rvalid, .mr_n8, .mr_wnext);
    logic [8:0]  po_waddr;
    logic [31:0] po_wdata;
    logic [3:0]  po_be;
    logic [31:0] pal_cq, oam_cq;
    logic        oam_cre, oam_cgnt;
    logic [7:0] io_tmr_oh;               // timer writes, decoded by the fabric on its grant edge
    nds_fabric #(.A9_CWF((A9_OPT >> 30) & 1), .MR_BLOCK(MR_BLOCK), .BOOT_SRAM(BOOT_SRAM), .OAM_SHARE(OAM_SHARE), .A7_IO(A7_IO), .DMA_FAST(DMA_UNIT != 0), .DMA_RA(DMA_RA), .DMA_B8(DMA_B8), .DMA_PACE(DMA_PACE), .DMA_PACE_GX(DMA_PACE_GX), .DMA_GX(GPU3D != 0 ? DMA_GX : 0), .DMA_PW(DMA_PW), .PO_WD(PO_WD)) u_fab (.clk, .rst, .wramcnt, .pb_busy(use_d),
        .dm_req, .dm_we, .dm_cpu, .dm_size32, .dm_addr, .dm_unit, .dm_more, .dm_dst, .dx_valid, .dx_ready, .dx_idle, .dm_wdata, .dm_ack, .dm_rdata,
        .a9_req(b9_req && !(DMA9_RUN != 0 && dma_busy[0])), .a9_we(b9_we), .a9_addr(b9_addr), .a9_be(b9_be), .a9_tmr(b9_tmr), .a9_wdata(b9_wdata),
        .a9_ack(b9_ack), .a9_rdata(b9_rdata), .a9_n8(b9_n8), .a9_rvalid(b9_rvalid), .a9_wnext(b9_wnext),
        .a7_req(f7_req), .a7_we(f7_we), .a7_addr(f7_addr), .a7_be(f7_be), .a7_wdata(f7_wdata),
        .a7_ack(f7_ack), .a7_rdata(f7_rdata),
        .sn_req(sn_req), .sn_we(sn_we), .sn_addr(sn_addr), .sn_wdata(sn_wdata), .sn_ack(sn_ack), .sn_rdata(sn_rdata),
        .mr_req(fm_req), .mr_we(fm_we), .mr_addr(fm_addr), .mr_be(fm_be), .mr_wdata(fm_wdata),
        .mr_ack(fm_ack), .mr_rvalid(fm_rvalid), .mr_rdata, .mr_n8(fm_n8), .mr_wnext(fm_wnext),
        .fx_req, .fx_we, .fx_addr, .fx_be, .fx_wdata, .fx_done, .fx_rdata(fr_rdata),
        .boot_addr(f_boot_a), .boot_q(boot_qb), .ram_wdata(f_wd),
        .io_req, .io_pre, .io_cpu, .io_we, .io_be, .io_addr, .io_wdata, .io_ack, .io_rdata,
        .vr_req(vc_req), .vr_cpu(vc_cpu), .vr_dma(vc_dma), .vr_we(vc_we), .vr_addr(vc_addr), .vr_be(vc_be),
        .vr_wdata(vc_wdata), .vr_ack(vc_ack), .vr_rdata(vc_rdata),
        .pal_we, .oam_we, .po_waddr, .po_wdata, .po_be, .pal_cq, .oam_cre, .oam_cgnt, .oam_cq,
        .mon_we, .mon_master, .mon_cpu, .mon_addr, .mon_be, .mon_wdata, .io_tmr_oh);

    // ---------------------------------------------------------------- I/O
    logic        sys_req, disp_req, cart_req, spi_req, rtc_req, snd_req;
    logic [2:0]  cart_reg;
    logic [31:0] sys_rdata, disp_rdata, cart_rdata, spi_rdata, rtc_rdata;
    logic [1:0]  powcnt2, vramstat;
    logic [71:0] vramcnt;
    logic [31:0] bootctl;
    logic        irq_key9, irq_key7, gx_irq_stub, pen_down;
    logic        gx_req, gx_ack, gx_ovf, gx_irq, gx_dma_low;
    logic        wf_req, wf_ack, wf_irq;
    logic [31:0] wf_rdata;
    logic [31:0] gx_rdata;
    logic [15:0] disp3dcnt;
    nds_io u_io (.clk, .rst,
        .io_req, .io_cpu, .io_we, .io_be, .io_addr, .io_wdata, .io_ack, .io_rdata,
        .sys_req, .sys_rdata, .disp_req, .disp_rdata, .cart_req, .cart_reg, .cart_rdata,
        .spi_req, .spi_rdata, .rtc_req, .rtc_rdata,
        .snd_req, .snd_ack, .snd_rdata, .snd_real(SOUND != 0),
        .gx_req, .gx_ack, .gx_rdata, .gx_real(GPU3D != 0), .gx_ovf, .disp3dcnt_o(disp3dcnt),
        .wf_req, .wf_ack, .wf_rdata,
        .keys, .pen_down, .lid_closed(1'b0), .rom_size, .mem_dirty, .save_info, .rtc_valid, .rtc_date, .rtc_time, .vramstat,
        .powcnt1, .powcnt2, .exmem_o(exmem_o7), .wramcnt, .vramcnt, .vramcnt_chg, .bootctl,
        .halt7(), .irq_key9, .irq_key7, .gx_irq(gx_irq_stub));

    // display
    logic [1:0]  irq_vbl, irq_hbl, irq_vct;
    logic        dma_vbl, dma_hbl, dma_dst, dma_dstop, dma_mmstop, frame_start;
    logic        g_req, g_ack, g_rvalid, d_req, d_ack, d_rvalid, t_req, t_ack, t_rvalid;
    gpu2d_pkg::blk_t g_blk, d_blk, t_blk;
    logic        l3d_go;
    logic [7:0]  l3d_line, l3d_raddr;
    logic [31:0] l3d_rdata;
    logic [63:0] g_rdata;
    logic        cap_we, cap_ready;
    logic [17:0] cap_addr;
    logic [15:0] cap_data;
    wire  [3:0]  lcdc_ab = {vramcnt[31] && vramcnt[26:24] == 3'd0, vramcnt[23] && vramcnt[18:16] == 3'd0,
                            vramcnt[15] && vramcnt[9:8] == 2'd0, vramcnt[7] && vramcnt[1:0] == 2'd0};
    // a VRAM write (CPU or DMA) or a VRAMCNT change: the 2D engine's caches start over
    logic        vramcnt_chg;
    wire vram_wr = (vc_req && vc_we && vc_ack) || vramcnt_chg;
    // the 3D caches start over only on a VRAMCNT change: the CPU port (and
    // DMA) reaches the ARM7, BG, OBJ and LCDC views only (nds_vram), so no
    // write lands in a bank mapped as texture or texture palette
    wire g3d_flush = vramcnt_chg;
    nds_disp #(.AR_RAM(DISP_AR_RAM != 0), .OAM_CPU(OAM_SHARE != 0), .WST_RF(G2D_WST_RF != 0), .TEX_IDXW(G2D_TEX_IDXW), .MOSAIC(G2D_MOSAIC != 0), .CAPTURE(G2D_CAPTURE != 0), .TAG_MLAB(G2D_TAG_MLAB != 0), .HURRY_AT(G2D_HURRY)) u_disp (.hurry2d, .clk, .rst, .vram_wr,
        .io_req(disp_req), .io_cpu, .io_we, .io_be, .io_addr(io_addr[12:2]), .io_wdata, .io_rdata(disp_rdata),
        .powcnt1, .lcdc_ab, .vcount, .line_start,
        .irq_vblank(irq_vbl), .irq_hblank(irq_hbl), .irq_vcount(irq_vct),
        .dma_vblank(dma_vbl), .dma_hblank(dma_hbl), .dma_dstart(dma_dst), .dma_dstop, .dma_mmstop, .frame_start,
        .vr_req(d_req), .vr_blk(d_blk), .vr_ack(d_ack), .vr_rvalid(d_rvalid), .vr_rdata(g_rdata),
        .l3d_go, .l3d_line, .l3d_raddr, .l3d_rdata,
        .cap_we, .cap_addr, .cap_data, .cap_ready,
        .pal_we, .oam_we, .po_waddr, .po_wdata, .po_be, .pal_cq, .oam_cre, .oam_cgnt, .oam_cq,
        .px_valid, .px_eng, .px_line, .px_x, .px_rgb, .stat_late,
        .diag_d_ev, .diag_d_bgmax, .diag_v_start, .diag_v_stop, .diag_l2d_v, .diag_l2d_line);

    // G3D_SWROUTE: the screens of a 3D frame shown late. Dual-screen 3D games flip POWCNT1 bit 15 every frame and
    // pair each 3D frame with the flip of the frame the DS shows it in (the one after the VBlank that takes its swap).
    // When the engine sorts a swap after the DS model took it (SWHOLD, SWPC: the engine behind) its frame shows a
    // frame late, and with the live bit on the other screen (GS title, MKDS intro: the views swap screens). So a
    // swap the model takes at a VBlank is tagged with its DS display frame (fc + 1); the tag moves to the bank when
    // the engine's sort ends, to the frame that draws it at its start; at line 0 a frame whose shown 3D is older
    // than the model's newest swap takes its tag's bit 15 (bh) instead of the live one. On time (the shown tag the
    // newest), with no 3D frame started, or with nothing taken: the live bit, as before. nds_video takes the bit per
    // line (the DS's rule), so the frame's choice is made at line 0 and held for its lines (sr_fl, sr_fb)
    logic       g3_swtake, g3_swdone, g3_frgo;
    logic [2:0] sr_fc;                   // frames, counted at line 0
    logic [7:0] sr_bh;                   // POWCNT1 bit 15 at each frame's line 0, by sr_fc
    logic [2:0] sr_q [0:3];              // swaps the model took, the engine's sort not ended: their display frames
    logic [2:0] sr_n;
    logic       sr_ovf;                  // more than 4 (until the queue drains: the live bit)
    logic [2:0] sr_rt, sr_st, sr_dt;     // the newest sorted bank's tag, the shown frame's, the model's newest
    logic       sr_rv, sr_sv, sr_dv, sr_fg;
    logic       sr_fl, sr_fb;            // this frame shows a late 3D frame, and that frame's bit 15
    wire        sr_l0 = line_start && vcount == 9'd0;
    wire  [2:0] sr_lag = sr_dt - sr_st;
    wire        sr_late = G3D_SWROUTE != 0 && sr_fg && sr_sv && sr_dv && !sr_ovf && sr_lag != 3'd0 && sr_lag < 3'd4;
    assign disp_swap = sr_fl ? sr_fb : powcnt1[15];
    always_ff @(posedge clk) begin
        if (rst || G3D_SWROUTE == 0) begin
            sr_fc <= 3'd0; sr_n <= 3'd0; sr_ovf <= 1'b0; sr_rv <= 1'b0; sr_sv <= 1'b0; sr_dv <= 1'b0; sr_fg <= 1'b0; sr_fl <= 1'b0;
        end else begin
            if (sr_l0) begin
                sr_fc <= sr_fc + 3'd1; sr_bh[sr_fc + 3'd1] <= powcnt1[15]; sr_fg <= 1'b0;
                sr_fl <= sr_late;
`ifdef G3D_SWROUTE_MUT
                sr_fb <= sr_bh[sr_st + 3'd1];   // (mutation: the frame after its own, the old pairing)
`else
                sr_fb <= sr_bh[sr_st];
`endif
            end
            if (g3_swtake) begin sr_dt <= sr_fc + 3'd1; sr_dv <= 1'b1; end
            // the queue: a take pushes, a sort's end pops (never both in one clock: a sort ends long after its take)
            if (g3_swtake) begin
                if (sr_n == 3'd4) sr_ovf <= 1'b1;
                else begin sr_q[sr_n[1:0]] <= sr_fc + 3'd1; sr_n <= sr_n + 3'd1; end
            end else if (g3_swdone && sr_n != 3'd0) begin
                sr_rt <= sr_q[0]; sr_rv <= 1'b1;
                sr_q[0] <= sr_q[1]; sr_q[1] <= sr_q[2]; sr_q[2] <= sr_q[3];
                sr_n <= sr_n - 3'd1;
                if (sr_n == 3'd1) sr_ovf <= 1'b0;
            end
            if (g3_frgo) begin sr_st <= sr_rt; sr_sv <= sr_rv; sr_fg <= 1'b1; end
        end
    end
`ifndef ALTERA_RESERVED_QIS
    // +srmon: a frame shown with a late 3D frame's bit
    bit sr_mon;
    initial sr_mon = $test$plusargs("srmon");
    always_ff @(posedge clk) if (sr_mon && sr_l0 && G3D_SWROUTE != 0)
        if (sr_late) $display("srmon: frame %0d shows a 3D frame %0d late: bit 15 %0d (its frame's) for %0d (live)", sr_fc + 3'd1, sr_lag, sr_bh[sr_st], powcnt1[15]);
`endif

    // 3D: the geometry engine and rasterizer; their texture caches share the
    // VRAM block port with the 2D engine (which goes first)
    generate if (GPU3D != 0) begin : g_3d
        logic [7:0]  g3_ra;           // the 3D line read after the X scroll
        logic [31:0] g3_rd;
        nds_blk_arb u_arb (.clk, .rst,
            .a_req(d_req), .a_blk(d_blk), .a_ack(d_ack), .a_rvalid(d_rvalid),
            .b_req(t_req), .b_blk(t_blk), .b_ack(t_ack), .b_rvalid(t_rvalid),
            .g_req, .g_blk, .g_ack, .g_rvalid);
        nds_gpu3d #(.FEAT_AA(G3D_AA != 0), .FEAT_TOON(G3D_TOON != 0), .FEAT_FOG(G3D_FOG != 0), .FEAT_ATEST(G3D_ATEST != 0),
            .FEAT_EDGE(G3D_EDGE != 0), .FEAT_SHADOW(G3D_SHADOW != 0), .FEAT_LOWER(G3D_LOWER != 0), .GX_USORT(GX_USORT != 0), .GX_LUNIT(GX_LUNIT != 0), .GX_VFIN(GX_VFIN), .GX_FF(GX_FF != 0), .GX_SPILL(GX_SPILL != 0), .STORE_SD(G3D_STORE_SD != 0), .GX_GATH16(GX_GATH16 != 0), .GX_ENGM10K(GX_ENGM10K != 0), .GX_SPAW(GX_SPAW), .DX_SKID(DX_SKID != 0),
            .TC_FAST(G3D_TCFAST != 0), .VYS_M10K(G3D_VYSM10K != 0), .TC_MIF2(G3D_TCMIF2 != 0), .TC_V2(G3D_TCV2 != 0), .TC_WAYS(G3D_TCWAYS), .TC_V2W(G3D_TCV2W), .SPO(G3D_SPO != 0), .SPO_SL(G3D_SPOSL), .SPOG(G3D_SPO != 0 && G3D_SPOG != 0), .SPOG_N(G3D_SPOGN), .TXD(G3D_TXD), .PXD(G3D_PXD), .FPSKIP(G3D_FPSKIP != 0), .TRU(G3D_TRU != 0), .TRUL(G3D_TRUL != 0), .FPCLR(G3D_FPCLR != 0), .YLIM2(G3D_YLIM2 != 0), .LLR(G3D_LLR != 0), .RPRI(G3D_RPRI != 0), .NX2(G3D_NX2 != 0), .RH_AT(G3D_RH_AT), .NXB(G3D_NXB != 0), .VREG(G3D_VREG != 0), .DSHARE(G3D_DSHARE != 0), .LB2(G3D_LB2 != 0), .LOV(G3D_LOV != 0), .EDIV4(G3D_EDIV4 != 0), .EDGE2(G3D_EDGE2 != 0), .EP2(G3D_EP2 != 0), .FDB(G3D_FDB != 0), .RING(G3D_RING != 0), .TL(G3D_TL), .PL(G3D_PL), .RESTART(G3D_RESTART != 0), .PUMP(G3D_PUMP != 0), .SWHOLD(G3D_SWHOLD != 0), .SWPC(G3D_SWPC != 0), .LMARK(G3D_LMARK != 0), .RLEAD(G3D_LEAD), .SSL(G3D_SL), .SCL(G3D_CL), .SDROP(G3D_DROP != 0)) u_gpu3d (.clk, .clk_2x, .rst, .tick, .geom_en(powcnt1[3]), .rend_en(powcnt1[2]),
            .vblank(line_start && vcount == 9'd192), .line215(line_start && vcount == 9'd215), .sw_close(line_start && vcount == 9'(215 + G3D_SWL)), .sw_lim(line_start && vcount == 9'(222 + G3D_SWL)),
            .disp3dcnt,
            .io_req(gx_req), .io_we, .io_be, .io_addr(io_addr[11:2]), .io_wdata, .io_ack(gx_ack), .io_rdata(gx_rdata), .dx_valid, .dx_ready, .dx_idle,
            .irq_gxfifo(gx_irq), .dma_gx_low(gx_dma_low), .ovf_set(gx_ovf),
            .p_req(g3_req), .p_we(g3_we), .p_addr(g3_addr), .p_wdata(g3_wdata), .p_ack(g3_ack),
            .p_rvalid(g3_rvalid), .p_rdata(mr_rdata),
            .vram_wr(g3d_flush), .t_req, .t_blk, .t_ack, .t_rvalid, .t_rdata(g_rdata),
            .l3d_go, .l3d_line, .l3d_raddr(g3_ra), .l3d_rdata(g3_rd),
            .rg_wlast, .rg_wreq, .rg_waddr, .rg_wdata, .rg_wack, .rg_rreq, .rg_hurry, .rg_raddr, .rg_rack, .rg_rvalid, .rg_rdata, .rg_wdrained,
            .diag_g_ev, .diag_g_val, .diag_g_used, .diag_s_start(), .diag_s_stop(),
            .ev_swtake(g3_swtake), .ev_swdone(g3_swdone), .ev_frgo(g3_frgo),
            .diag_r_ev, .diag_r_val, .diag_t_start, .diag_t_stop, .diag_l3d_v, .diag_l3d_line);
        // engine A's BG0HOFS scrolls the 3D layer (as nds_g3d_plane does without 3D)
        nds_l3d_xscroll u_xscroll (.clk, .rst, .rend_en(powcnt1[2]),
            .io_req, .io_cpu, .io_we, .io_be, .io_addr, .io_wdata,
            .raddr(l3d_raddr), .rdata(l3d_rdata), .l3d_raddr(g3_ra), .l3d_rdata(g3_rd));
    end else if (G3D_PLANE != 0) begin : g_plane
        // no 3D engine: the 3D layer is the clear plane (its bitmap rows share
        // the block port behind the 2D engine)
        nds_blk_arb u_arb (.clk, .rst,
            .a_req(d_req), .a_blk(d_blk), .a_ack(d_ack), .a_rvalid(d_rvalid),
            .b_req(t_req), .b_blk(t_blk), .b_ack(t_ack), .b_rvalid(t_rvalid),
            .g_req, .g_blk, .g_ack, .g_rvalid);
        nds_g3d_plane u_plane (.clk, .rst, .powcnt1(powcnt1[3:2]), .disp3dcnt,
            .io_req, .io_cpu, .io_we, .io_be, .io_addr, .io_wdata,
            .line_start, .vcount,
            .t_req, .t_blk, .t_ack, .t_rvalid, .t_rdata(g_rdata),
            .l3d_go, .l3d_line, .l3d_raddr, .l3d_rdata);
        assign gx_ack = 1'b0; assign gx_rdata = 32'd0; assign gx_ovf = 1'b0; assign dx_ready = 1'b1; assign dx_idle = 1'b1;
        assign gx_irq = gx_irq_stub; assign gx_dma_low = 1'b1;
        assign g3_req = 1'b0; assign g3_we = 1'b0; assign g3_addr = '0; assign g3_wdata = 32'd0;
        assign rg_wlast = 1'b0; assign rg_wreq = 1'b0; assign rg_waddr = '0; assign rg_wdata = 32'd0; assign rg_rreq = 1'b0; assign rg_hurry = 1'b0; assign rg_raddr = '0;
        assign diag_g_ev = 8'd0; assign diag_g_val = 32'd0; assign diag_g_used = 16'd0;
        assign g3_swtake = 1'b0; assign g3_swdone = 1'b0; assign g3_frgo = 1'b0;
        assign diag_r_ev = 11'd0; assign diag_r_val = 32'd0; assign diag_t_start = 1'b0; assign diag_t_stop = 1'b0;
        assign diag_l3d_v = 1'b0; assign diag_l3d_line = 9'd0;
    end else begin : g_no3d
        assign g_req = d_req; assign g_blk = d_blk; assign d_ack = g_ack; assign d_rvalid = g_rvalid;
        assign t_req = 1'b0; assign t_blk = '0; assign t_ack = 1'b0; assign t_rvalid = 1'b0;
        assign gx_ack = 1'b0; assign gx_rdata = 32'd0; assign gx_ovf = 1'b0; assign dx_ready = 1'b1; assign dx_idle = 1'b1;
        assign gx_irq = gx_irq_stub; assign gx_dma_low = 1'b1; assign l3d_rdata = 32'd0;
        assign g3_req = 1'b0; assign g3_we = 1'b0; assign g3_addr = '0; assign g3_wdata = 32'd0;
        assign rg_wlast = 1'b0; assign rg_wreq = 1'b0; assign rg_waddr = '0; assign rg_wdata = 32'd0; assign rg_rreq = 1'b0; assign rg_hurry = 1'b0; assign rg_raddr = '0;
        assign diag_g_ev = 8'd0; assign diag_g_val = 32'd0; assign diag_g_used = 16'd0;
        assign g3_swtake = 1'b0; assign g3_swdone = 1'b0; assign g3_frgo = 1'b0;
        assign diag_r_ev = 11'd0; assign diag_r_val = 32'd0; assign diag_t_start = 1'b0; assign diag_t_stop = 1'b0;
        assign diag_l3d_v = 1'b0; assign diag_l3d_line = 9'd0;
    end endgenerate

    nds_vram #(.CAP_CHAIN(CAP_CHAIN != 0), .VR_POST(VR_POST != 0), .VR_RDB(VR_RDB != 0), .VR_PASS(VR_PASS != 0), .VR_WB(VR_WB != 0), .VR_CWF(VR_CWF != 0), .VR_HIT(VR_HIT != 0), .VR_YIELD(VR_YIELD != 0), .VR_PDRAIN(VR_PDRAIN != 0), .VR_PF(VR_PF != 0)) u_vram (.clk, .rst, .vramcnt,
        .c_req(vc_req), .c_cpu(vc_cpu), .c_dma(vc_dma), .c_we(vc_we), .c_addr(vc_addr), .c_be(vc_be), .c_wdata(vc_wdata),
        .c_ack(vc_ack), .c_rdata(vc_rdata),
        .g_req, .g_blk, .g_ack, .g_rvalid, .g_rdata,
        .cap_we, .cap_addr, .cap_data, .cap_ready, .cw_valid, .cw_addr, .cw_data, .cw_ack, .cw_drained(rg_wdrained), .cw_fill(rg_wfill), .cw_pcnt(rg_wpcnt),
        .sv_req(vs_req), .sv_we(vs_we), .sv_addr(vs_addr), .sv_be(vs_be), .sv_wdata(vs_wdata),
        .sv_ack(vs_ack), .sv_rdata(vs_rdata),
        .vm_req, .vm_we, .vm_blk, .vm_addr, .vm_be, .vm_wdata, .vm_ack, .vm_rvalid, .vm_rdata,
        .vramstat);

    // card
    logic cart_irq, cart_drq;
    logic        sv_req, sv_we, sv_ack;
    logic [19:2] sv_addr;
    // nds_vram's lowest-priority port: the cart's save memory (VRAM-port 0x100000+)
    // and the WiFi block's memory, one owner from grant to ack
    logic        wm_req, wm_we, wm_ack;
    logic [20:2] wm_addr;
    logic [3:0]  wm_be;
    logic [31:0] wm_wdata;
    logic        vs_busy, vs_wifi, vs_ack;
    logic [31:0] vs_rdata;
    always_ff @(posedge clk)
        if (rst) begin vs_busy <= 1'b0; vs_wifi <= 1'b0; end
        else if (!vs_busy) begin
            if (sv_req) begin vs_busy <= 1'b1; vs_wifi <= 1'b0; end
            else if (wm_req) begin vs_busy <= 1'b1; vs_wifi <= 1'b1; end
        end else if (vs_ack) vs_busy <= 1'b0;
    wire         vs_req   = vs_busy && (vs_wifi ? wm_req : sv_req);
    wire         vs_we    = vs_wifi ? wm_we : sv_we;
    wire  [20:2] vs_addr  = vs_wifi ? wm_addr : {1'b1, sv_addr};
    wire  [3:0]  vs_be    = vs_wifi ? wm_be : sv_be;
    wire  [31:0] vs_wdata = vs_wifi ? wm_wdata : sv_wdata;
    assign sv_ack = vs_ack && !vs_wifi, wm_ack = vs_ack && vs_wifi, sv_rdata = vs_rdata;
    logic [3:0]  sv_be;
    logic [31:0] sv_wdata, sv_rdata;
    assign save_type = bootctl[6:4];
    nds_cart u_cart (.clk, .rst, .tick, .owner7(exmem_o7), .raw(bootctl[0]), .ir(bootctl[1]), .dsi(bootctl[7]),
        .save_type(bootctl[6:4]), .sv_loaded, .rom_size,
        .io_req(cart_req), .io_cpu, .io_we, .io_be, .io_reg(cart_reg), .io_wdata, .io_rdata(cart_rdata),
        .irq(cart_irq), .drq(cart_drq),
        .cr_req, .cr_addr, .cr_ack, .cr_rvalid, .cr_rdata,
        .sv_req, .sv_we, .sv_addr, .sv_be, .sv_wdata, .sv_ack, .sv_rdata);

    // SPI (firmware, touchscreen, power management) and RTC
    logic spi_irq;
    nds_spi u_spi (.clk, .rst, .tick,
        .io_req(spi_req), .io_we, .io_be, .io_wdata, .io_rdata(spi_rdata), .irq(spi_irq), .pwr_off(),
        .fw_req, .fw_addr, .fw_ack, .fw_rdata(sr_rdata),
        .pen, .tx(pen_x), .ty(pen_y), .pen_down);
    nds_rtc u_rtc (.clk, .rst, .tick,
        .io_req(rtc_req), .io_we, .io_be, .io_wdata, .io_rdata(rtc_rdata));

    // ---------------------------------------------------------------- sound
    logic        sys_f1024;
    // rtl/sound runs on every clk_sys cycle (ce = 1, 67.03 MHz); its output
    // step is every 2,048 of them (1,024 system cycles, 32,768 Hz).
    generate if (SOUND != 0) begin : g_snd
        logic        step;
        always_ff @(posedge clk) step <= !rst && sys_f1024;     // one clk (the timers' divider)
        // registers: hold the request until the engine answers (its ack lasts one
        // clock); the fabric holds io_we/io_be/io_addr/io_wdata in S_WAIT until then
        logic        r_busy;
        logic        reg_ack;
        logic [31:0] reg_rdata;
        always_ff @(posedge clk) begin
            snd_ack <= 1'b0;
            if (rst) r_busy <= 1'b0;
            else if (snd_req) r_busy <= 1'b1;
            else if (r_busy && reg_ack) begin
                r_busy <= 1'b0; snd_ack <= 1'b1; snd_rdata <= reg_rdata;
            end
        end
        wire [1:0]   r_size = io_be == 4'hF ? 2'd2 : (io_be == 4'b0011 || io_be == 4'b1100) ? 2'd1 : 2'd0;
        wire [8:0]   r_addr = {io_addr[8:2], io_be[0] ? 2'd0 : io_be[1] ? 2'd1 : io_be[2] ? 2'd2 : 2'd3};
        // memory: one access at a time. The engine holds its request, write data
        // and address until the fabric's answer, which is its ack and read data.
        logic        mem_req, mem_we, m_pend;
        logic [24:0] mem_addr;
        logic [31:0] mem_wdata;
        wire         mem_ack = m_pend && sn_ack;
        wire         mem_rvalid = mem_ack && !mem_we;
        always_ff @(posedge clk) begin
            if (rst) m_pend <= 1'b0;
            else if (mem_ack) m_pend <= 1'b0;
            else if (mem_req && !m_pend) begin m_pend <= 1'b1; sn_addr <= {5'd0, mem_addr, 2'b00}; end
        end
        assign sn_req = m_pend;
        assign sn_we  = mem_we;
        assign sn_wdata = mem_wdata;
        logic        late_p;
        sound #(.CAPTURE(SND_CAPTURE)) u_snd (.clk, .ce(1'b1), .rst, .tick(step), .power(powcnt2[0]),
            .reg_req(r_busy), .reg_we(io_we), .reg_size(r_size), .reg_addr(r_addr), .reg_wdata(io_wdata),
            .reg_ack, .reg_rdata,
            .mem_req, .mem_we, .mem_addr, .mem_wdata, .mem_ack, .mem_rvalid, .mem_rdata(sn_rdata),
            .out_valid(aud_valid), .out_pre(aud_pre), .out_l(aud_l), .out_r(aud_r), .dac_l(), .dac_r(), .overrun(), .late(late_p));
        // diagnostics: late steps and the longest memory access (#95: buzzy at times)
        logic [15:0] wait_n;
        always_ff @(posedge clk) begin
            if (rst) begin snd_late <= 32'd0; snd_wait_max <= 16'd0; wait_n <= 16'd0; end
            else begin
                if (late_p) snd_late <= snd_late + 32'd1;
                if (m_pend) begin
                    wait_n <= wait_n + 16'd1;
                    if (wait_n >= snd_wait_max) snd_wait_max <= wait_n + 16'd1;
                end else wait_n <= 16'd0;
            end
        end
    end else begin : g_nosnd
        assign sn_req = 1'b0; assign sn_we = 1'b0; assign sn_addr = 32'd0; assign sn_wdata = 32'd0;
        assign snd_ack = 1'b0; assign snd_rdata = 32'd0;
        assign aud_valid = 1'b0; assign aud_pre = 1'b0; assign aud_l = 16'd0; assign aud_r = 16'd0;
        assign snd_late = 32'd0; assign snd_wait_max = 16'd0;
    end endgenerate

    // ---------------------------------------------------------------- system blocks
    wire [31:0] ext9 = {10'd0, gx_irq, 1'b0, cart_irq && !exmem_o7, 6'd0, irq_key9, 9'd0,
                        irq_vct[0], irq_hbl[0], irq_vbl[0]};
    // the WiFi block
    assign wx_req = wf_req;
    assign wx_we = io_we, wx_be = io_be, wx_addr = io_addr, wx_wdata = io_wdata, wx_power = powcnt2[1];
    assign wx_rtl_ack = wf_ack, wx_rtl_rdata = wf_rdata, wx_rtl_irq = wf_irq;
    generate if (WIFI == 2) begin : g_wifi_ext
        assign wf_ack = wx_ack, wf_rdata = wx_rdata, wf_irq = wx_irq;
        assign wm_req = 1'b0, wm_we = 1'b0, wm_addr = '0, wm_be = 4'd0, wm_wdata = 32'd0;
    end else if (WIFI == 1 && WIFI_MC != 0) begin : g_wifi_mc
        nds_wifi_mc u_wifi (.clk, .rst, .tick, .power(powcnt2[1]), .id_lite(1'b1),
            .wf_req, .wf_we(io_we), .wf_be(io_be), .wf_addr(io_addr), .wf_wdata(io_wdata),
            .wf_ack, .wf_rdata, .irq(wf_irq),
            .wm_req, .wm_we, .wm_addr, .wm_be, .wm_wdata, .wm_ack, .wm_rdata(vs_rdata));
    end else if (WIFI == 1) begin : g_wifi
        nds_wifi u_wifi (.clk, .rst, .tick, .power(powcnt2[1]), .id_lite(1'b1),
            .wf_req, .wf_we(io_we), .wf_be(io_be), .wf_addr(io_addr), .wf_wdata(io_wdata),
            .wf_ack, .wf_rdata, .irq(wf_irq),
            .wm_req, .wm_we, .wm_addr, .wm_be, .wm_wdata, .wm_ack, .wm_rdata(vs_rdata));
    end else if (WIFI == 3) begin : g_wifi_store
        // pocket-now: no radio, no timers, no interrupts: just what a game's WiFi start reads back (docs/wifi.md,
        // HeartGold's "communication error": the register self-test, the WiFi RAM test, the RF and baseband polls).
        // Registers, baseband registers and RAM are plain words in SDRAM on nds_vram's lowest-priority port.
        // W_BBBusy and W_RFBusy read 0, W_PowerState 0x200 and W_RFStatus 9 (Pokemon's WiFi start waits for them
        // after CONTINUE; the WiFi stays "on" for good).
        logic       wl_busy, wl_ack, wl_zl, wl_zh, wl_on, wl_rfs;
        logic [7:0] wl_bbv, wl_bbi;                                             // W_BBWrite, W_BBCnt's register
        wire  wl_ram = io_addr[14];
        wire  wl_rd  = !wl_ram && io_addr[11:2] == 10'h057;                     // 0x15C, 0x15E
        wire  wl_rf  = !wl_ram && io_addr[11:2] == 10'h060;                     // 0x180
        wire  wl_ps  = !wl_ram && io_addr[11:2] == 10'h00F;                     // 0x03C
        wire  wl_st  = !wl_ram && io_addr[11:2] == 10'h085;                     // 0x214
        wire  wl_w15 = !wl_ram && io_addr[11:2] == 10'h056 && io_we;            // 0x158, 0x15A
        wire  wl_bwr = wl_w15 && io_be[0] && io_wdata[15:12] == 4'h5;           // W_BBCnt: write wl_bbv to the register
        always_ff @(posedge clk) begin
            wl_ack <= wm_ack || (wf_req && wl_rf);
            if (rst || wm_ack) wl_busy <= 1'b0;
            else if (wf_req && !wl_rf) wl_busy <= 1'b1;
            if (wf_req) begin wl_zl <= wl_rf || wl_ps || wl_st; wl_zh <= wl_rf || wl_rd; wl_on <= wl_ps; wl_rfs <= wl_st; end
            if (wf_req && wl_w15 && io_be[2]) wl_bbv <= io_wdata[23:16];
            if (wf_req && wl_w15 && io_be[0]) wl_bbi <= io_wdata[7:0];
        end
        assign wf_ack = wl_ack, wf_irq = 1'b0;
        assign wf_rdata = {wl_zh ? 16'd0 : vs_rdata[31:16],
                           wl_zl ? {6'd0, wl_on, 5'd0, wl_rfs, 2'd0, wl_rfs} : vs_rdata[15:0]};
        assign wm_req = wl_busy, wm_we = io_we, wm_be = io_be;
        assign wm_wdata = wl_bwr ? {24'd0, wl_bbv} : io_wdata;
        // baseband register r: the word at 0x800 + 4r in the register block (nothing else is there)
        assign wm_addr = {7'h3C, !wl_ram, wl_ram ? io_addr[12:2] :
                                          wl_bwr ? {3'b100, io_wdata[7:0]} : (wl_rd && !io_we) ? {3'b100, wl_bbi} : {1'b0, io_addr[11:2]}};
    end else begin : g_wifi_none
        always_ff @(posedge clk) wf_ack <= wf_req;
        assign wf_rdata = 32'd0, wf_irq = 1'b0;
        assign wm_req = 1'b0, wm_we = 1'b0, wm_addr = '0, wm_be = 4'd0, wm_wdata = 32'd0;
    end endgenerate
    wire [31:0] ext7 = {7'd0, wf_irq, spi_irq, 3'd0, cart_irq && exmem_o7, 6'd0, irq_key7, 9'd0,
                        irq_vct[1], irq_hbl[1], irq_vbl[1]};
    nds_sys #(.DMA_FAST(DMA_UNIT != 0), .PUMP(SYS_PUMP != 0)) u_sys (.clk, .clk2(clk_2x), .rst, .tick, .f1024(sys_f1024),
        .io_req(sys_req), .io_pre, .tmr_oh(io_tmr_oh), .io_cpu, .io_we, .io_be, .io_addr(io_addr[20:2]), .io_wdata,
        .io_rdata(sys_rdata), .io_hit(),
        .dma_trig9({1'b0, 1'b0, cart_drq && !exmem_o7, 1'b0, dma_dst, dma_hbl, dma_vbl}),
        .dma_gx_low(gx_dma_low),
        .dma_stop9({3'b000, dma_mmstop, dma_dstop, 2'b00}),
        .dma_trig7({1'b0, cart_drq && exmem_o7, dma_vbl}),
        .m_req(dm_req), .m_we(dm_we), .m_cpu(dm_cpu), .m_size32(dm_size32), .m_addr(dm_addr), .m_unit(dm_unit), .m_more(dm_more), .m_dst(dm_dst),
        .m_wdata(dm_wdata), .m_ack(dm_ack), .m_rdata(dm_rdata), .dma_busy,
        .irq_ext9(ext9), .irq_ext7(ext7), .irq9, .irq7, .wake7,
        .math_late(), .dbg_dma_run(), .dma_lat_lost());
endmodule
