// 3D in the integrated DS system (docs/phase2-integration.md, "3D").
// gpu3d_geom (rtl/gpu3d) takes the ARM9's GX writes at 0x400-0x7FF and
// produces polygon records and, at each swap, their render order;
// gpu3d_raster draws lines from a per-line polygon stream. This wrapper
// holds what lies between them:
//   - the render registers 0x320-0x3BF (edge colours, alpha-test
//     reference, clear colour/depth, fog colour/offset/table, toon table),
//     latched at VBlank like GPU3D::VBlank and copied into the raster's
//     tables;
//   - the polygon store: headers, vertices, the render order and a Y table,
//     double-buffered by bank (geom fills one while the raster reads the
//     other; the banks change at the swap). Capacity is 2^PW polygons and
//     2^VW vertices per bank; past it, polygons are dropped. (The full
//     2048/6144 needs ~2 Mbit and moves to PSRAM later, docs/memory-replay.md.)
//   - the per-line fetcher: for line y it walks the render order, tests each
//     polygon's Y range and streams the covering ones (header, vertices) and
//     an end-of-line beat;
//   - texture and texture-palette caches of 32-byte blocks in front of the
//     VRAM block port (spaces SP_TEX/SP_TPAL), cleared on any VRAM write;
//   - a ring of 2^RB finished 3D lines that the 2D engine reads as BG0.
//     The raster starts at line 215 (GPU::StartScanline) and may run up to
//     2^RB - 2 lines ahead of the line the 2D engine composes.
module nds_gpu3d
    import gpu2d_pkg::*;
#(
    parameter int PW = 10,      // log2 polygons per bank (HG title: 626)
    parameter int VW = 11,      // log2 vertices per bank (HG title: 1,679)
    parameter int RB = 3,       // log2 lines in the 3D ring
    parameter int TL = 6,       // log2 texture cache lines
    parameter int PL = 4,       // log2 palette cache lines
    parameter int EXT_STORE = 1, // 1: polygon store in PSRAM (full capacity); 0: on chip (PW, VW)
    // texture/palette caches: one lookup per clock (TC_FAST), two blocks in
    // flight (TC_MIF2). Answers stay in order, so pixels are unchanged
    parameter bit TC_FAST = 0,
    parameter bit TC_MIF2 = 0,
    parameter int TC_WAYS = 1,  // texture cache ways (1 or 2: 2^TL sets each)
    parameter int TC_V2W = 1,   // TC_V2: nds_g3d_cache2 WAYS (1, 2, 4) at the same size (2^TL lines)
    // TC_V2: nds_g3d_cache2 for both (direct mapped; scanner, two blocks in
    // flight; TC_FAST / TC_MIF2 / TC_WAYS unused). Pixels unchanged
    parameter bit TC_V2 = 0,
    parameter bit TC_PSCAN = 1,
    parameter int TC_NF = 2,     // TC_V2: blocks on the way per cache and on the block port (texture misses overlap)  // TC_V2: the palette cache's scanner (0: none; MKDS race +1.4% clocks, KH unchanged)
    parameter int TXD = 0,      // gpu3d_raster TXD: texel request-to-use stages added (timing only)
    parameter int PXD = 0,      // gpu3d_raster PXD: palette request-to-use stages added (timing only)
    parameter bit FPSKIP = 0,   // gpu3d_raster FPSKIP: the final pass skips the fog steps a frame does not use
    parameter bit TRU = 0,      // gpu3d_raster TRU: a texture read of one of the last two halfwords is reused
    parameter bit TRUL = 0,     // gpu3d_raster TRUL: TRU with one entry per read slot
    parameter bit FPCLR = 0,    // gpu3d_raster FPCLR: the final pass's clear waits for a free write clock from F_3 on
    // YLIM2 (RING): the store may stream two lines further past the ring's
    // writes (the final pass is two lines behind the store at least); the
    // final pass holds while its line's staging slot is still full
    parameter bit YLIM2 = 0,
    // LLR (RING, the four slot RAMs): a late line the raster has started shows
    // the polygons drawn so far over the clear colour (the DS rule, hwref run
    // 33), copied from the raster's line buffer, instead of the rear plane
    parameter bit LLR = 0,
    // RPRI (RING): nds_g3d_ring RPRI, the needed line's read before a staged line's write
    parameter bit RPRI = 0,
    // NX2 (RING): nds_g3d_ring NX2, line dline+2 fetched once the composed line is swept
    parameter bit NX2 = 0,
    // RH_AT (RING): nds_g3d_ring RH_AT, the needed line's read urgent that many clocks into a line (0: never)
    parameter int RH_AT = 0,
    // TR3: gpu3d_raster / nds_g3d_ring TR3 (three line-buffer slots), on
    // only without edge marking (it needs the fourth slot's line above)
    parameter bit TR3 = 1,
    parameter bit NXB = 0,      // gpu3d_raster NXB: no next-span register (timing only)
    parameter bit VREG = 0,     // gpu3d_raster VREG: the edge unit's vertex RAM output registered (timing only)
    parameter bit DSHARE = 0,   // gpu3d_raster DSHARE: one divider for the edge unit and the AA coverage start
    parameter bit LB2 = 0,      // gpu3d_raster LB2: line buffers as two RAMs per layer (2:1 read muxes)
    parameter bit LOV = 0,      // gpu3d_raster LOV: the next line starts while this one's pixels drain
    parameter bit EDIV4 = 0,    // gpu3d_raster EDIV4: the edge's perspective divider four bits a clock
    parameter bit SPO = 0,      // gpu3d_raster SPO: the walker loads a span without waiting for P0-P13 to empty
    parameter int SPO_SL = 4,   // ... its descriptor slots (gpu3d_raster SPO_SL)
    parameter bit SPOG = 0,     // ... or its descriptor through registers per pair of stages (gpu3d_raster SPOG)
    parameter int SPOG_N = 2,   // ... stages per group (gpu3d_raster SPOG_N)
    parameter bit EDGE2 = 0,    // gpu3d_raster EDGE2: a second edge unit (a polygon's two edges at once)
    parameter bit EP2 = 0,      // gpu3d_raster EP2: the edge unit as two stages (two edges at once)
    parameter bit FDB = 0,      // gpu3d_raster FDB (EP2): the input stage one polygon ahead of stage 1
    // RING: the 3D line ring in SDRAM (nds_g3d_ring on the rg_* ports, a 46-line
    // lead) instead of the 8 lines on chip (u_ring)
    parameter bit RING = 0,
    // RESTART: a frame starts at line 215 even when the raster is still on
    // the last one (DS, run 24: the renderer starts every frame on time); the
    // raster restarts and the old frame's texel answers are dropped. 0: the
    // frame start is skipped and the raster carries on with the old frame
    parameter bit RESTART = 0,
    // switchable 3D features (docs/budget-3d.md, options table rows 7-9, 14):
    // 1 as the DS; 0 falls back to the DS's behaviour with the feature off
    // (gpu3d_raster FEAT_*): no AA = hard edges, no toon/highlight = the
    // polygon colour as in modulate mode, no fog, no alpha test (alpha 0
    // only), no edge marking, no shadow polygons (mode 3 skipped), no lower
    // layer (AA edges, shadows and translucent edges against the clear plane)
    parameter bit FEAT_AA = 1,
    parameter bit FEAT_TOON = 1,
    parameter bit FEAT_FOG = 1,
    parameter bit FEAT_ATEST = 1,
    parameter bit FEAT_EDGE = 1,
    parameter bit FEAT_SHADOW = 1,
    parameter bit FEAT_LOWER = 1,
    parameter bit GX_USORT = 1'b1, // gpu3d_geom USORT: the polygon sort in the geometry microcode (0: gpu3d_gxsort)
    parameter bit GX_LUNIT = 1'b0, // gpu3d_geom LUNIT: the lighting unit
    parameter int GX_VFIN  = 0,    // gpu3d_geom VFIN (2: VFIN-lite)
    parameter bit GX_FF    = 1'b0, // gpu3d_geom FF: the geometry redesign (with GX_USORT, GX_LUNIT, GX_VFIN 1)
    // STORE_SD (with GX_SPILL): the polygon store's records in SDRAM at word 0x0F0000 (byte 0x3C0000, 256 KiB; the GX spill ends at 0x380000) through the
    // rg_* ports, not in PSRAM: 4 word writes a record into the write chain, reads as 8-word blocks (the 4 words of the
    // record kept). The PSRAM goes to the CPUs and DMA: ~23K word writes and ~5.7K 4-word reads less a game frame on mkds-pack
    parameter bit STORE_SD = 1'b0,
    parameter bit GX_SPILL = 1'b0, // gpu3d_geom SPILL: GX entries beyond the on-chip 512 spill to SDRAM (shares the rg_* ports)
    parameter bit GX_GATH16 = 1'b0, // gpu3d_gxfront GATH16: the spill's gather 16 entries deep
    parameter bit GX_ENGM10K = 1'b1, // gpu3d_geom ENG_TM10K: the engine's VC and VOC tables in M10K (0: MLAB, -2 M10K)
    parameter bit VYS_M10K = 1'b1,   // gpu3d_front VYS_M10K: the vertex y table in an M10K (0: MLAB, -1 M10K)
    parameter int GX_SPAW = 12,     // gpu3d_gxfront SP_AW: the spill ring 2^GX_SPAW entries (8 bytes each) in SDRAM
    parameter bit DX_SKID = 1'b0,  // a second posted DMA_GX word waits in a skid register while g_* waits for the front
    // the texture and palette caches' tag stores double-pumped on clk_2x (nds_lcache PUMP: 2 -> 1 M10K each)
    parameter bit PUMP = 1'b0,
    // SWHOLD: a swap the engine reaches late (after SWIN, up to line 215) still sorts, and the frame start waits
    // for its sort output (at most SWM clocks) instead of the swap waiting for the next VBlank (below)
    parameter bit SWHOLD = 1'b0,
    parameter bit SWPC = 1'b0,      // SWHOLD: a late sort runs once the started frame is drawn, not at the next VBlank
    // LMARK (debug cards only): a late 3D line shows an opaque colour by cause instead of the rear plane: red, the
    // raster not done and the frame start held (SWHOLD); yellow, the raster not done, the frame started at line
    // 215; green, the raster done but the ring could not deliver it (RING); magenta, a skipped frame (RESTART 0)
    parameter bit LMARK = 1'b0,
    // SSL: nds_g3d_store SL, log2 pool slots (the most polygons on one line: MKDS race intro 252-260)
    parameter int SSL = 8,
    parameter int SCL = 10,     // nds_g3d_store CL, log2 pool vertex chunks (ff4-newgame: 1,084 vertices on one line)
    parameter bit SDROP = 0,    // nds_g3d_store DROP: a line's arrival the pool can't hold is dropped, not the frame (item 16)
    // RLEAD (RING): nds_g3d_ring LEAD, the lines the raster may run ahead of the composed line (the DS's 48-line buffer: 46)
    parameter int RLEAD = 46
) (
    input  logic        clk,
    input  logic        clk_2x,         // PUMP: 2 x clk, phase 0
    input  logic        rst,
    input  logic        tick,
    input  logic        geom_en,        // POWCNT1 bit 3
    input  logic        rend_en,        // POWCNT1 bit 2
    input  logic        vblank,         // pulse: line 192 starts
    input  logic        line215,        // pulse: line 215 starts
    input  logic        sw_close,       // SWHOLD pulse: the late-swap window closes (line 215 + G3D_SWL)
    input  logic        sw_lim,         // SWHOLD pulse: the frame start waits no longer (7 lines later)
    input  logic [15:0] disp3dcnt,
    // I/O 0x320-0x7FF (ARM9): io_req for one cycle, io_ack when done
    input  logic        io_req,
    input  logic        io_we,
    input  logic [3:0]  io_be,
    input  logic [11:2] io_addr,
    input  logic [31:0] io_wdata,
    output logic        io_ack,
    output logic [31:0] io_rdata,
    // a DMA unit's word to the GX FIFO or a command port, posted (nds_fabric
    // DMA_GX): io_addr/io_wdata with dx_valid instead of io_req, no io_ack;
    // dx_ready while no word waits for the engine (the fabric holds other
    // GX accesses until then)
    input  logic        dx_valid,
    output logic        dx_ready,
    output logic        dx_idle,        // no posted word waits (g_* and the skid empty): the ARM9's 3D accesses may go
    output logic        irq_gxfifo,
    output logic        dma_gx_low,
    output logic        ovf_set,
    // PSRAM for the polygon store (main-RAM words, through nds_mr_arb)
    output logic        p_req,
    output logic        p_we,
    output logic [22:2] p_addr,
    output logic [31:0] p_wdata,
    input  logic        p_ack,
    input  logic        p_rvalid,
    input  logic [31:0] p_rdata,
    // VRAM block reads (through nds_blk_arb)
    input  logic        vram_wr,
    output logic        t_req,
    output blk_t        t_blk,
    input  logic        t_ack,
    input  logic        t_rvalid,
    input  logic [63:0] t_rdata,
    // 3D layer for the 2D engine
    input  logic        l3d_go,         // engine A's BG job for line l3d_line starts
    input  logic [7:0]  l3d_line,
    input  logic [7:0]  l3d_raddr,
    output logic [31:0] l3d_rdata,
    // the 3D line ring's SDRAM ports (core_top_ds RING; docs/phase2-integration.md
    // "3D line ring in SDRAM"): block writes, 8 consecutive words (rg_wack per
    // word), and 32-byte block reads (rg_rack, then 8 rg_rvalid). Not used yet.
    output logic        rg_wreq,
    output logic [23:0] rg_waddr,           // SDRAM word address
    output logic        rg_wlast,           // STORE_SD: this write ends a block shorter than 8 words
    output logic [31:0] rg_wdata,
    input  logic        rg_wack,
    output logic        rg_rreq,
    output logic        rg_hurry,       // RH_AT: the ring's needed-line read is late (the SDRAM bus serves port 6 first)
    output logic [23:0] rg_raddr,
    input  logic        rg_rack,
    input  logic        rg_rvalid,
    input  logic [31:0] rg_rdata,
    input  logic        rg_wdrained,        // all ring writes so far are in the SDRAM controller: a line written before
                                            // this rose may be read (the write FIFO drains in <= ~130 clk_sys)
    // geometry diagnostics (docs/diag.md, events 11-18, value words 1-2, latency histogram 1); unconnected
    // in a release build, so pruned
    output logic [7:0]  diag_g_ev,      // per clock: engine busy, GX stall DS-full, GX stall engine-behind,
                                        // engine held by the store, swap built, entry executed, fetcher
                                        // waiting for the loader, loader waiting for the PSRAM grant
    output logic [31:0] diag_g_val,     // {polygons, vertices} at the last swap built
    // the swap's display path (nds_top G3D_SWROUTE): the DS model takes a swap at the VBlank, the engine's sort of a
    // swap ends (the store builds that bank), a frame starts (it draws the newest bank)
    output logic        ev_swtake,
    output logic        ev_swdone,
    output logic        ev_frgo,
    output logic [15:0] diag_g_used,    // most entry-RAM entries in use in the last frame
    output logic        diag_s_start,   // the store's PSRAM read granted
    output logic        diag_s_stop,    // its first beat
    // raster diagnostics (docs/diag.md events 0-10, value word 0, latency
    // histogram 0, line histogram 0); unconnected in a release build, so pruned
    output logic [10:0] diag_r_ev,      // per clock: phase stream, edge, pixel, final; late line; restart;
                                        // texture block, palette block; pixel; texel request; ring underrun
    output logic [31:0] diag_r_val,     // {first late line (FFFF: none), minimum ring lead (signed)} of the last frame
    output logic        diag_t_start,   // a texture/palette block accepted
    output logic        diag_t_stop,    // the first beat of the oldest block in flight
    output logic        diag_l3d_v,     // a late line (as diag_r_ev[4]) ...
    output logic [8:0]  diag_l3d_line   // ... and which
);
    // ------------------------------------------------------------------ I/O
    // 0x320-0x3BF here (answered the next cycle); 0x400-0x7FF to the geometry
    // engine: writes are held while it signals io_wait, reads wait for its ack
    wire        own   = io_addr[11:10] == 2'b00;               // 0x000-0x3FF
    logic       g_req, g_we, g_busy, g_rd;
    logic       g_dx;           // the word in g_* is a posted DMA word (dx_valid): no io_ack
    // DX_SKID: a posted word arriving while g_* holds another posted word waits in sk_*; it moves to g_*
    // the clock after g_* completes, the clock a word from the fabric would have arrived (the front's PRE
    // needs a clock between a write's completion and the next word)
    logic       sk_v;
    logic [3:0] sk_be;
    logic [9:2] sk_addr;
    logic [31:0] sk_wdata;
    logic [20:0] sk_pre;
    assign dx_ready = DX_SKID ? !sk_v && (!g_busy || g_dx && !g_rd) : !g_busy;
    assign dx_idle  = !g_busy && !(DX_SKID && sk_v);
    logic [3:0] g_be;
    logic [9:2] g_addr;
    logic [31:0] g_wdata, g_rdata;
    // the GX front's decode of a packed command word, registered with g_wdata (a timing path, #454/#455)
    logic [20:0] g_wpre, io_pre;
    gpu3d_gxpre u_gxpre (.d(io_wdata), .pre(io_pre));
    logic       g_ack, g_wait;
    logic [15:0] edge_tab [0:7];
    logic [31:0] clear_attr1, clear_attr2, fog_color;
    logic [14:0] fog_offset;
    logic [4:0]  alpharef_val;
    // table words (edge 0x330-0x33F, fog 0x360-0x37F, toon 0x380-0x3BF) in a
    // byte-enabled RAM at index addr[7:2]; copied at VBlank
    logic [3:0]  tw_we;
    logic [5:0]  tr_a;
    logic [31:0] tr_q;
    assign tw_we = (io_req && io_we && own && io_addr[9:8] == 2'b11 &&
                    (io_addr[7:4] == 4'h3 || io_addr[7:5] == 3'b011 || io_addr[7:6] == 2'b10)) ? io_be : 4'd0;
    nds_sdp_ram #(.AW(6)) u_tab (.clk, .we(tw_we), .waddr(io_addr[7:2]), .wdata(io_wdata), .raddr(tr_a), .rdata(tr_q));

    always_ff @(posedge clk) begin
        io_ack <= 1'b0;
        if (rst) begin
            g_busy <= 1'b0; g_req <= 1'b0; g_dx <= 1'b0; sk_v <= 1'b0;
            clear_attr1 <= 32'd0; clear_attr2 <= 32'd0; fog_color <= 32'd0; fog_offset <= 15'd0; alpharef_val <= 5'd0;
        end else begin
            if (io_req && own) begin
                io_ack <= 1'b1;
                io_rdata <= io_addr[9:2] == 8'hC8 ? 32'd46 : 32'd0;     // 0x320 RDLINES_COUNT (melonDS: 46)
                if (io_we) begin
                    case (io_addr[9:2])
                        8'hD0: if (io_be[0]) alpharef_val <= io_wdata[4:0];                       // 0x340
                        8'hD4: for (int b = 0; b < 4; b++) if (io_be[b]) clear_attr1[b*8 +: 8] <= io_wdata[b*8 +: 8];
                        8'hD5: for (int b = 0; b < 4; b++) if (io_be[b]) clear_attr2[b*8 +: 8] <= io_wdata[b*8 +: 8];
                        8'hD6: for (int b = 0; b < 4; b++) if (io_be[b]) fog_color[b*8 +: 8] <= io_wdata[b*8 +: 8];
                        8'hD7: begin
                            if (io_be[0]) fog_offset[7:0]  <= io_wdata[7:0];
                            if (io_be[1]) fog_offset[14:8] <= io_wdata[14:8];
                        end
                        default: ;
                    endcase
                end
            end else if (DX_SKID && !g_busy && sk_v) begin
                g_busy <= 1'b1; g_req <= 1'b1; g_rd <= 1'b0; g_dx <= 1'b1; sk_v <= 1'b0;
                g_we <= 1'b1; g_be <= sk_be; g_addr <= sk_addr; g_wdata <= sk_wdata; g_wpre <= sk_pre;
            end else if (DX_SKID && g_busy && dx_valid) begin
                sk_v <= 1'b1; sk_be <= io_be; sk_addr <= io_addr[9:2]; sk_wdata <= io_wdata; sk_pre <= io_pre;
            end else if (io_req || dx_valid) begin
                g_busy <= 1'b1; g_req <= 1'b1; g_rd <= !io_we; g_dx <= dx_valid;
                g_we <= io_we; g_be <= io_be; g_addr <= io_addr[9:2]; g_wdata <= io_wdata; g_wpre <= io_pre;
            end
            if (g_busy) begin
                if (g_rd) begin
                    g_req <= 1'b0;
                    if (g_ack) begin g_busy <= 1'b0; io_ack <= 1'b1; io_rdata <= g_rdata; end
                end else if (!g_wait) begin
                    g_req <= 1'b0; g_busy <= 1'b0; io_ack <= !g_dx; io_rdata <= 32'd0;
                end
            end
        end
    end

    // ------------------------------------------------------------- geometry
    logic         po_valid, po_ready, po_type, so_we, so_done;
    logic         s_draw;               // a swap's sort output must wait: it could not finish before frame_go
    logic         st_draw;              // nds_g3d_store f_live
    // the sort output (first SOW to SOD: <= 12.7K clk in sm64-castle, 7.3K mkds-heavy) starts only within SWIN
    // clocks of the VBlank, so it ends before line 215's frame_go (23 lines of 4,260 clk, ~98K); a later swap waits for
    // the next VBlank, as the DS applies a late SWAP_BUFFERS there
    localparam int SWIN = 70000;        // ~28K clk (twice the longest sort seen) before frame_go
    logic [16:0]  sw_vb;                // clocks since the VBlank (saturating)
    always_ff @(posedge clk) sw_vb <= (rst || vblank) ? 17'd0 : (&sw_vb ? sw_vb : sw_vb + 17'd1);
    // (a frame still drawn at the VBlank is already late: its remaining lines have been displayed, so the
    // sort may replace its tables; a frame started after the VBlank (frame_go) must not be cut: the window
    // closes 23 lines before it)
    // SWHOLD: the window stays open from the VBlank until sw_close (nds_top: line 215 + G3D_SWL) or the frame
    // start, whichever comes first, and the frame start waits while the engine owes a swap or sorts (sw_busy),
    // until sw_lim (7 lines, ~30K clk, later) at most: a sort that passed the window has ended by then (the 28K
    // margin SWIN keeps). MKDS's race intro, startline: the engine, busy all frame at the camera cut, reached
    // the sort 83.7K clk after the VBlank (later 102K); the frame was shown a frame late, which swapped the two
    // screens for good. It also waits while the store builds the swap's lists (192 clk, the write queue's
    // drain and 4 clk a polygon after SOD): a frame started then finds no lists and draws its first lines empty
    // (the window's 28K margin used to cover that; startline: the sky's top 38 lines). Without a late swap
    // frame_go comes at line 215 as before
    logic         sw_busy;              // gpu3d_geom: a swap the engine owes or sorts
    logic         st_bld;               // nds_g3d_store: the swap's lists are being built (the fetcher would find none)
    logic         sw_open, sw_hok;      // SWHOLD: the window is open; the frame start may still wait
    always_ff @(posedge clk) begin
        sw_open <= !rst && (vblank || (sw_open && !sw_close));
        sw_hok  <= !rst && (vblank || (sw_hok && !sw_lim));
    end
    logic         fg_vb;                // a frame started since the VBlank (frame_go, below)
    logic         fg_pend;              // line 215 has come, the frame start waits for sw_busy
    wire          fg_req = (line215 || fg_pend) && rend_en && geom_en;
`ifndef ALTERA_RESERVED_QIS
    // +fgdelay=N (simulation): every frame start waits N lines (4,260 clk) past line 215, as a held one would
    int fgd_n; logic [20:0] fgd_c;
    initial if (!$value$plusargs("fgdelay=%d", fgd_n)) fgd_n = 0;
    always_ff @(posedge clk) fgd_c <= line215 ? 21'd0 : fgd_c + (fgd_c[20] ? 21'd0 : 21'd1);
    wire          fg_simhold = fgd_n != 0 && (line215 || 32'(fgd_c) < fgd_n * 4260);   // (the count restarts after line215)
`else
    wire          fg_simhold = 1'b0;
`endif
    wire          fg_hold = (SWHOLD && (sw_busy || st_bld) && sw_hok) || fg_simhold;
    wire          fg_now = fg_req && !fg_hold;     // the frame starts (line215 && rend_en && geom_en without SWHOLD)
    always_ff @(posedge clk) fg_pend <= !rst && fg_req && fg_hold;
    // SWPC: once the frame has started, a late sort may run as soon as the store has drawn that frame (st_draw
    // low) rather than at the next VBlank: its frame is shown a frame late (or skipped by the next swap), but the
    // engine does not idle a frame at SDRAW, which kept it a frame behind for good once busy (MKDS intro on the
    // Pocket, NDSPlay8: the 3D on the wrong screen for many frames)
    assign s_draw = SWHOLD ? (fg_vb ? (SWPC ? st_draw : 1'b1) : !sw_open) : sw_vb >= 17'(SWIN);
    logic [127:0] po_data;
    logic [10:0]  po_index, so_pos, so_idx;
    logic         po_wv;
    logic [1:0]   po_wk;
    logic [31:0]  po_wd;
    logic [11:0]  so_count;
    logic         g_idle;
    logic [11:0]  g_npoly;
    logic [12:0]  g_nvert;
    logic [2:0]   g_dev;
    logic [12:0]  g_dused;
    logic [3:0]   st_diag;              // nds_g3d_store's diag_ld (0 with the on-chip store)
    // the GX spill's SDRAM ports and the ring's, arbitrated onto rg_* below
    logic        s_wreq, s_wack, s_rreq, s_rack, s_rvalid;
    logic [23:0] s_waddr, s_raddr;
    logic [31:0] s_wdata;
    logic        q_wreq, q_wack, q_rreq, q_rack, q_rvalid;
    // the polygon store's memory port: PSRAM (p_*), or STORE_SD's rg_*
    logic        sm_req, sm_we, sm_ack, sm_rvalid, sm_wack, sm_rack, sm_rv;
    logic [22:2] sm_addr;
    logic [31:0] sm_wdata, sm_rdata;
    generate if (STORE_SD) begin : g_tsd
        assign p_req = 1'b0; assign p_we = 1'b0; assign p_addr = '0; assign p_wdata = 32'd0;
        assign sm_ack = sm_we ? sm_wack : sm_rack; assign sm_rvalid = sm_rv; assign sm_rdata = rg_rdata;
    end else begin : g_tp
        assign p_req = sm_req; assign p_we = sm_we; assign p_addr = sm_addr; assign p_wdata = sm_wdata;
        assign sm_ack = p_ack; assign sm_rvalid = p_rvalid; assign sm_rdata = p_rdata;
    end endgenerate
    logic [23:0] q_waddr, q_raddr;
    logic [31:0] q_wdata;
    // the divider on clk_2x where clk_2x runs (PUMP)
    gpu3d_geom #(.USORT(GX_USORT), .LUNIT(GX_LUNIT), .VFIN(GX_VFIN), .FF(GX_FF), .GX_PRE(1'b1), .DIV_P2X(1'b0), .SPILL(GX_SPILL), .GATH16(GX_GATH16), .SP_AW(GX_SPAW), .ENG_TM10K(GX_ENGM10K)) u_geom (
        .clk, .clk_2x, .rst, .tick, .geom_en, .vblank,
        .io_req(g_req), .io_we(g_we), .io_be(g_be), .io_addr(g_addr), .io_wdata(g_wdata), .io_wpre(g_wpre),
        .io_rdata(g_rdata), .io_ack(g_ack), .io_wait(g_wait),
        .irq_gxfifo, .dma_gx_low, .gx_stall(), .ovf_set,
        .po_valid, .po_ready, .s_draw, .po_type, .po_data, .po_index, .po_wv, .po_wk, .po_wd,
        .so_we, .so_pos, .so_idx, .so_done, .so_count, .sw_busy, .sw_take(ev_swtake),
        .dbg_stall(), .dbg_apply(), .dbg_upc(), .dbg_flush(), .dbg_idle(g_idle), .dbg_gxstat(),
        .dbg_npoly(g_npoly), .dbg_nvert(g_nvert), .dbg_eq_bad(), .diag_ev(g_dev), .diag_used(g_dused),
        .sp_wreq(s_wreq), .sp_waddr(s_waddr), .sp_wdata(s_wdata), .sp_wack(s_wack), .sp_wdrained(rg_wdrained), .sp_rreq(s_rreq), .sp_raddr(s_raddr),
        .sp_rack(s_rack), .sp_rvalid(s_rvalid), .sp_rdata(rg_rdata));

    // ------------------------------------------------- polygon store, fetcher
    logic         ps_line_req, ps_valid, ps_ready;
    logic [7:0]   ps_line_y;
    logic [1:0]   ps_type;
    logic [127:0] ps_data;
    // the 3D ring: line y may be streamed once it is at most 2^RB - 2 lines
    // ahead of the line the 2D engine composes
    logic [7:0]   dline;
    always_ff @(posedge clk) begin
        if (rst || line215) dline <= 8'd0;
        else if (l3d_go) dline <= l3d_line;
    end
    wire  [8:0]   y_lim_rg;
    wire  [8:0]   y_lim = RING ? y_lim_rg : 9'(dline) + 9'((1 << RB) - 2);
    logic         frame_go;
    logic         r_busy;
    // RESTART: a frame start that finds the raster busy restarts it (and
    // the store, which drops the old frame); below
    wire          r_abort = RESTART && fg_now && r_busy;
    generate if (EXT_STORE != 0) begin : g_ext
        // full capacity, in PSRAM (nds_g3d_store)
        nds_g3d_store #(.SL(SSL), .CL(SCL), .DROP(SDROP)) u_store (.clk, .rst,
            .po_valid, .po_ready, .po_type, .po_data, .po_index, .po_wv, .po_wk, .po_wd,
            .so_we, .so_pos, .so_idx, .so_done, .so_count, .drawing(st_draw), .lists_bld(st_bld),
            .frame_go, .abort(r_abort), .diag_ld(st_diag), .ps_line_req, .ps_line_y, .y_lim, .ps_valid, .ps_ready, .ps_type, .ps_data,
            .p_req(sm_req), .p_we(sm_we), .p_addr(sm_addr), .p_wdata(sm_wdata), .p_ack(sm_ack), .p_rvalid(sm_rvalid), .p_rdata(sm_rdata),
            .p_wdrained(!STORE_SD || rg_wdrained));
`ifdef G3D_EQ
        // equivalence check (simulation only): the on-chip store at full
        // capacity on the same records and line requests; its beats must be
        // the store's beats, in order (end-of-line data aside)
        logic         r_valid;
        logic [1:0]   r_type;
        logic [127:0] r_data;
        nds_g3d_onchip #(.PW(11), .VW(13)) u_ref (.clk, .rst,
            .po_valid(po_valid && po_ready), .po_ready(), .po_type, .po_data, .po_index,
            .so_we, .so_pos, .so_idx, .so_done, .so_count,
            .ps_line_req, .ps_line_y, .y_lim(9'd511), .ps_valid(r_valid), .ps_ready(1'b1), .ps_type(r_type), .ps_data(r_data));
        logic [129:0] rq [0:8191];
        logic [12:0]  rq_rp = '0, rq_wp = '0;
        integer eq_beats = 0, eq_bad = 0;
        always_ff @(posedge clk) if (!rst) begin
            if (r_valid) begin rq[rq_wp] <= {r_type, r_type == 2'd3 ? 128'd0 : r_data}; rq_wp <= rq_wp + 13'd1; end
            if (ps_valid && ps_ready) begin
                logic [129:0] e;
                eq_beats <= eq_beats + 1;
                if (rq_rp == rq_wp) begin
                    eq_bad <= eq_bad + 1;
                    if (eq_bad < 5) $display("G3D_EQ: beat %0d (line %0d) with no reference beat", eq_beats, ps_line_y);
                end else begin
                    e = rq[rq_rp]; rq_rp <= rq_rp + 13'd1;
                    if (e != {ps_type, ps_type == 2'd3 ? 128'd0 : ps_data}) begin
                        eq_bad <= eq_bad + 1;
                        if (eq_bad < 5) $display("G3D_EQ: beat %0d differs: type %0d %h, reference type %0d %h",
                                                 eq_beats, ps_type, ps_data, e[129:128], e[127:0]);
                    end
                end
            end
        end
        final $display("G3D_EQ: %0d beats, %0d differ, %0d reference beats left", eq_beats, eq_bad, rq_wp - rq_rp);
`endif
    end else begin : g_onchip
        assign st_bld = 1'b0;
        assign st_diag = 4'd0; assign st_draw = 1'b0;
        assign sm_req = 1'b0; assign sm_we = 1'b0; assign sm_addr = '0; assign sm_wdata = '0;
        nds_g3d_onchip #(.PW(PW), .VW(VW)) u_store (.clk, .rst,
            .po_valid, .po_ready, .po_type, .po_data, .po_index,
            .so_we, .so_pos, .so_idx, .so_done, .so_count,
            .ps_line_req, .ps_line_y, .y_lim, .ps_valid, .ps_ready, .ps_type, .ps_data);
    end endgenerate

    // ---------------------------------------------- render state and tables
    logic [15:0] r_dispcnt;
    logic [4:0]  r_alpharef;
    logic [31:0] r_clear_attr1;
    logic [14:0] r_clear_depth;
    logic [20:0] r_fog_color;
    logic [14:0] r_fog_offset;
    logic        tbl_we;
    logic [1:0]  tbl_sel;
    logic [4:0]  tbl_addr;
    logic [14:0] tbl_data;
    // copy: words 12-15 (edge), 24-47 (fog, toon); four steps per word
    logic        cp_on, cp_v;
    logic [5:0]  cp_w, cp_wq;
    logic [1:0]  cp_k, cp_kq;
    assign tr_a = cp_w;
    always_ff @(posedge clk) begin
        tbl_we <= 1'b0;
        if (rst) begin
            cp_on <= 1'b0; cp_v <= 1'b0;
            r_dispcnt <= 16'd0; r_alpharef <= 5'd0; r_clear_attr1 <= 32'd0; r_clear_depth <= 15'd0;
            r_fog_color <= 21'd0; r_fog_offset <= 15'd0;
        end else begin
            if (vblank && geom_en && rend_en) begin
                r_dispcnt <= disp3dcnt; r_alpharef <= disp3dcnt[2] ? alpharef_val : 5'd0;
                r_clear_attr1 <= clear_attr1; r_clear_depth <= clear_attr2[14:0];
                r_fog_color <= fog_color[20:0]; r_fog_offset <= fog_offset;
                cp_on <= 1'b1; cp_w <= 6'd12; cp_k <= 2'd0;
            end else if (cp_on) begin
                cp_k <= cp_k + 2'd1;
                if (cp_k == 2'd3) begin
                    cp_w <= cp_w == 6'd15 ? 6'd24 : cp_w + 6'd1;
                    if (cp_w == 6'd47) cp_on <= 1'b0;
                end
            end
            // the RAM answers a cycle later
            cp_v <= cp_on; cp_wq <= cp_w; cp_kq <= cp_k;
            if (cp_v) begin
                if (cp_wq < 6'd24) begin                           // edge: two entries per word
                    tbl_we <= !cp_kq[1]; tbl_sel <= 2'd1; tbl_addr <= {2'd0, cp_wq[1:0], cp_kq[0]};
                    tbl_data <= cp_kq[0] ? tr_q[30:16] : tr_q[14:0];
                end else if (cp_wq < 6'd32) begin                  // fog density: four per word
                    tbl_we <= 1'b1; tbl_sel <= 2'd2; tbl_addr <= {cp_wq[2:0], cp_kq};
                    tbl_data <= {8'd0, tr_q[cp_kq*8 +: 7]};
                end else begin                                     // toon: two per word
                    tbl_we <= !cp_kq[1]; tbl_sel <= 2'd0; tbl_addr <= {cp_wq[3:0], cp_kq[0]};
                    tbl_data <= cp_kq[0] ? tr_q[30:16] : tr_q[14:0];
                end
            end
        end
    end

    // ------------------------------------------------------------ rasterizer
    logic        tex_req, tex_valid, pal_req, pal_valid;
    logic [18:0] tex_addr;
    logic [16:0] pal_addr;
    logic [15:0] tex_data, pal_data;
    logic        px_valid;
    logic [7:0]  px_x, px_y;
    logic [22:0] px_color;
    logic [2:0]  r_phase;
    logic        r_span, r_pixel;
    // ---- diagnostics (docs/diag.md)
    assign diag_g_ev = {st_diag[1], st_diag[0], g_dev[2], so_done, po_valid && !po_ready, g_dev[1], g_dev[0], !g_idle};
    logic [12:0] dg_max;
    logic       dg_rd;                  // a PSRAM read granted, its first beat not yet seen
    always_ff @(posedge clk) begin
        if (so_done) diag_g_val <= {4'd0, g_npoly, 3'd0, g_nvert};
        if (frame_go) begin diag_g_used <= {3'd0, dg_max}; dg_max <= g_dused; end
        else if (g_dused > dg_max) dg_max <= g_dused;
        if (st_diag[2]) dg_rd <= 1'b1;
        else if (st_diag[3]) dg_rd <= 1'b0;
        if (rst) begin diag_g_val <= '0; diag_g_used <= '0; dg_max <= '0; dg_rd <= 1'b0; end
    end
    assign diag_s_start = st_diag[2];
    assign diag_s_stop  = st_diag[3] && dg_rd;
`ifndef ALTERA_RESERVED_QIS   // (Quartus rejects $test$plusargs)
    // +g3ddiag: the diagnostic outputs summed per frame and over the run (checks them against +gxmon/+g3dsmon)
    bit          dd_on;
    initial dd_on = $test$plusargs("g3ddiag");
    longint      dd_n [8], dd_t [8], dd_lat, dd_lc, dd_c0;
    always_ff @(posedge clk) if (dd_on && !rst) begin
        for (int k = 0; k < 8; k++) if (diag_g_ev[k]) begin dd_n[k] <= dd_n[k] + 1; dd_t[k] <= dd_t[k] + 1; end
        if (diag_s_start) dd_c0 <= 0; else dd_c0 <= dd_c0 + 1;
        if (diag_s_stop) begin dd_lat <= dd_lat + dd_c0 + 1; dd_lc <= dd_lc + 1; end
        if (frame_go) begin
            $display("g3ddiag: busy %0d stall-ds %0d stall-eng %0d store-held %0d swaps %0d exec %0d fetch-wait %0d grant-wait %0d | val %08x used %0d | reads %0d lat-sum %0d",
                     dd_n[0], dd_n[1], dd_n[2], dd_n[3], dd_n[4], dd_n[5], dd_n[6], dd_n[7], diag_g_val, diag_g_used, dd_lc, dd_lat);
            for (int k = 0; k < 8; k++) dd_n[k] <= diag_g_ev[k] ? 1 : 0;
        end
    end
    final if (dd_on) $display("g3ddiag total: busy %0d stall-ds %0d stall-eng %0d store-held %0d swaps %0d exec %0d fetch-wait %0d grant-wait %0d",
                              dd_t[0], dd_t[1], dd_t[2], dd_t[3], dd_t[4], dd_t[5], dd_t[6], dd_t[7]);
`endif
    always_ff @(posedge clk) frame_go <= !rst && fg_now && (RESTART || !r_busy);
    assign ev_swdone = so_done;
    assign ev_frgo = frame_go;
    always_ff @(posedge clk) fg_vb <= !rst && !vblank && (fg_vb || frame_go);
    // the caches answer in order: those for requests made before a restart
    // (outstanding when it comes) go nowhere
    logic        tc_v, pc_v;
    logic [5:0]  t_out, t_drop, p_out, p_drop;
    always_ff @(posedge clk) begin
        if (rst) begin t_out <= '0; t_drop <= '0; p_out <= '0; p_drop <= '0; end
        else begin
            t_out <= t_out + 6'(tex_req) - 6'(tc_v);
            p_out <= p_out + 6'(pal_req) - 6'(pc_v);
            if (r_abort) begin t_drop <= t_out + 6'(tex_req) - 6'(tc_v); p_drop <= p_out + 6'(pal_req) - 6'(pc_v); end
            else begin
                if (tc_v && t_drop != '0) t_drop <= t_drop - 6'd1;
                if (pc_v && p_drop != '0) p_drop <= p_drop - 6'd1;
            end
        end
    end
    assign tex_valid = tc_v && t_drop == '0;
    assign pal_valid = pc_v && p_drop == '0;
    // G3D_STALL (simulation only): a pseudo-random enable on the store -> raster handshake, so the
    // store sees the raster stall often (its beats must not change)
    logic r_ps_valid, r_ps_ready;
`ifdef G3D_STALL
    logic [15:0] stall_lfsr = 16'hACE1;
    always_ff @(posedge clk) stall_lfsr <= {stall_lfsr[14:0], stall_lfsr[15] ^ stall_lfsr[13] ^ stall_lfsr[12] ^ stall_lfsr[10]};
    wire stall_en = stall_lfsr[0] | stall_lfsr[3];
`else
    wire stall_en = 1'b1;
`endif
    assign r_ps_valid = ps_valid && stall_en;
    assign ps_ready   = r_ps_ready && stall_en;
    // AREA=0: full rate; the half-rate option measured no area gain (#187)
    gpu3d_raster #(.AREA(0), .TXD(TXD), .PXD(PXD), .FPSKIP(FPSKIP), .LLR(LLR), .TRU(TRU), .TRUL(TRUL), .FPCLR(FPCLR), .NXB(NXB), .VREG(VREG), .DSHARE(DSHARE), .LB2(LB2), .LOV(LOV), .EDIV4(EDIV4), .EDGE2(EDGE2), .EP2(EP2), .FDB(FDB), .SPO(SPO), .SPO_SL(SPO_SL), .SPOG(SPOG), .SPOG_N(SPOG_N), .FEAT_AA(FEAT_AA), .FEAT_FOG(FEAT_FOG), .FEAT_ATEST(FEAT_ATEST), .FEAT_TOON(FEAT_TOON),
                   .FEAT_EDGE(FEAT_EDGE), .FEAT_SHADOW(FEAT_SHADOW), .FEAT_LOWER(FEAT_LOWER), .TR3(TR3 && !FEAT_EDGE && !LB2), .VYS_M10K(VYS_M10K)) u_raster (
        .clk, .rst(rst || r_abort),
        .dispcnt(r_dispcnt), .alpharef(r_alpharef), .clear_attr1(r_clear_attr1), .clear_depth(r_clear_depth),
        .fog_color(r_fog_color), .fog_offset(r_fog_offset),
        .tbl_we, .tbl_sel, .tbl_addr, .tbl_data,
        .frame_start(frame_go), .busy(r_busy), .frame_done(), .px_hold(fp_hold), .fp_line, .fp_act(r_fp_act), .r_go(r_front_go),
        .ll_rd, .ll_slot, .ll_x, .ll_ack, .ll_q,
        .ps_line_req, .ps_line_y, .ps_valid(r_ps_valid), .ps_ready(r_ps_ready), .ps_type, .ps_data,
        .tex_req, .tex_addr, .tex_inval(vram_wr), .tex_valid, .tex_data,
        .pal_req, .pal_addr, .pal_valid, .pal_data,
        .px_valid, .px_x, .px_y, .px_color,
        .dbg_phase(r_phase), .dbg_span(r_span), .dbg_pixel(r_pixel));

    // ---------------------------------------------- texture/palette caches
    logic        tc_req, pc_req, tc_ack, pc_ack, tc_rv, pc_rv;
    logic [13:0] tc_blk, pc_blk;
    localparam int CQL = TXD == 0 || 2 * (TXD + 3) <= 16 ? 4 : 5;
    generate if (TC_V2) begin : g_c2
        nds_g3d_cache2 #(.AW(19), .LW(TL), .QL(CQL), .NF(TC_NF), .PUMP(PUMP), .WAYS(TC_V2W)) u_tc (.clk, .clk2(clk_2x), .rst, .flush(vram_wr), .pf_v(1'b0), .pf_a('0),
            .req(tex_req), .addr(tex_addr), .valid(tc_v), .data(tex_data),
            .b_req(tc_req), .b_blk(tc_blk), .b_ack(tc_ack), .b_rvalid(tc_rv), .b_rdata(t_rdata));
        nds_g3d_cache2 #(.AW(17), .LW(PL), .QL(CQL), .SCAN(TC_PSCAN), .PUMP(PUMP)) u_pc (.clk, .clk2(clk_2x), .rst, .flush(vram_wr), .pf_v(1'b0), .pf_a('0),
            .req(pal_req), .addr(pal_addr), .valid(pc_v), .data(pal_data),
            .b_req(pc_req), .b_blk(pc_blk), .b_ack(pc_ack), .b_rvalid(pc_rv), .b_rdata(t_rdata));
    end else begin : g_c1
        nds_g3d_cache #(.AW(19), .LW(TL), .FAST(TC_FAST), .MIF2(TC_MIF2), .WAYS(TC_WAYS), .QL(CQL)) u_tc (.clk, .rst, .flush(vram_wr),
            .req(tex_req), .addr(tex_addr), .valid(tc_v), .data(tex_data),
            .b_req(tc_req), .b_blk(tc_blk), .b_ack(tc_ack), .b_rvalid(tc_rv), .b_rdata(t_rdata));
        nds_g3d_cache #(.AW(17), .LW(PL), .FAST(TC_FAST), .MIF2(TC_MIF2), .QL(CQL)) u_pc (.clk, .rst, .flush(vram_wr),
            .req(pal_req), .addr(pal_addr), .valid(pc_v), .data(pal_data),
            .b_req(pc_req), .b_blk(pc_blk), .b_ack(pc_ack), .b_rvalid(pc_rv), .b_rdata(t_rdata));
    end endgenerate
    // one block port: a cache's request is held until ack; its four beats
    // come back in acknowledge order. One block in flight, or two with
    // TC_MIF2, TC_NF with TC_V2 (an owner queue routes the beats)
    localparam int TNF = TC_V2 ? (TC_NF > 2 ? TC_NF : 2) : TC_MIF2 ? 2 : 1;
    logic [3:0] t_n;                   // blocks in flight
    logic [TNF > 1 ? TNF - 1 : 1:0] t_ownq;   // their owners, [0] the oldest (1 = palette)
    logic [1:0] t_beat;
    wire  t_pick = tc_req ? 1'b0 : 1'b1;
    wire  t_last = t_rvalid && t_beat == 2'd3;
    assign t_req  = (t_n < 4'(TNF)) && (tc_req || pc_req);
    assign t_blk  = t_pick ? {SP_TPAL, 1'b0, pc_blk} : {SP_TEX, 1'b0, tc_blk};
    assign tc_ack = t_ack && !t_pick;
    assign pc_ack = t_ack && t_pick;
    assign tc_rv  = t_rvalid && !t_ownq[0];
    assign pc_rv  = t_rvalid && t_ownq[0];
    always_ff @(posedge clk) begin
        if (rst) begin t_n <= 4'd0; t_beat <= 2'd0; end
        else begin
            if (t_rvalid) t_beat <= t_beat + 2'd1;
            t_n <= t_n + (t_ack ? 4'd1 : 4'd0) - (t_last ? 4'd1 : 4'd0);
            // push at the next free slot (t_n, less the one popped), pop the oldest at its last beat
            if (t_last) t_ownq <= t_ownq >> 1;
            if (ow_v) t_ownq[ow_i - 4'(t_last)] <= ow_p;
        end
    end
    // the owner is written a clock after t_ack (#879: fabric cpu -> blk_arb t_ack -> t_ownq -0.221 ns): its
    // slot as taken then (t_n less a pop that clock), less a pop in the clock it is written. A block's
    // first beat comes two or more clocks after its ack (checked below), so t_ownq[0] is in place by then
    logic       ow_v, ow_p;
    logic [3:0] ow_i;
    always_ff @(posedge clk) begin
        ow_v <= !rst && t_ack; ow_p <= t_pick; ow_i <= t_n - 4'(t_last);
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!rst && t_rvalid && t_n == 4'd0) $error("nds_gpu3d: a block beat with no block in flight");
    always_ff @(posedge clk) if (!rst && t_rvalid && ow_v && ow_i == 4'd0)
        $error("nds_gpu3d: a block beat before its owner is written (t_ack one clock earlier)");
`endif

    // ---------------------------------------------------------- 3D line ring
    logic [22:0] ring_q;
    logic [3:0]  st_busy;
    logic [7:0]  fp_line;
    logic        r_fp_act;
    logic [8:0]  r_front_go;
    logic        ll_rd, ll_ack;
    logic [1:0]  ll_slot;
    logic [7:0]  ll_x;
    logic [22:0] ll_q;
    // the final pass holds a line's pixels while its staging slot still has
    // a line not yet in SDRAM: always with the ring (YLIM2 relies on it; and
    // without YLIM2 y_lim does not cover a store streaming while its lists
    // build, nds_g3d_store's !ready: gsdd-title overran staging there,
    // slot 3 line 187 under line 191)
    wire         fp_hold = RING && st_busy[fp_line[1:0]];
`ifndef SYNTHESIS
    int fh_n = 0;
    always_ff @(posedge clk)
        if (rst || !fp_hold) fh_n <= 0;
        else begin
            fh_n <= fh_n + 1;
            if (fh_n == 100000) $error("nds_gpu3d: the final pass held 100K clocks on staging slot %0d (the ring's writes stuck?)", fp_line[1:0]);
        end
`endif
    generate if (RING) begin : g_ring
        nds_g3d_ring #(.YLAG(YLIM2 ? 2 : 0), .LLR(LLR), .RPRI(RPRI), .NX2(NX2), .RH_AT(RH_AT), .TR3(TR3 && !FEAT_EDGE && !LB2), .LEAD(RLEAD)) u_ringx (.rg_hurry, .clk, .rst, .frame_go, .l3d_go, .l3d_line, .l3d_raddr, .l3d_rdata(ring_q),
            .y_lim(y_lim_rg), .px_valid, .px_x, .px_y, .px_color,
            .rg_wreq(q_wreq), .rg_waddr(q_waddr), .rg_wdata(q_wdata), .rg_wack(q_wack), .rg_rreq(q_rreq), .rg_raddr(q_raddr),
            .rg_rack(q_rack), .rg_rvalid(q_rvalid), .rg_rdata, .rg_wdrained,
            .l3d_have(ring_have), .st_busy,
            .r_go(r_front_go), .fp_line, .fp_act(r_fp_act), .ll_rd, .ll_slot, .ll_x, .ll_ack, .ll_q);
    end else begin : g_oring
        assign rg_hurry = 1'b0;
        gpu3d_ram #(.W(23), .AW(RB + 8)) u_ring (.clk, .we(px_valid), .waddr({px_y[RB-1:0], px_x}), .wdata(px_color),
            .raddr({l3d_line[RB-1:0], l3d_raddr}), .rdata(ring_q));
        assign y_lim_rg = '0; assign ring_have = 1'b1; assign st_busy = '0;
        assign ll_rd = 1'b0; assign ll_slot = '0; assign ll_x = '0;
        assign q_wreq = 1'b0; assign q_waddr = 24'd0; assign q_wdata = 32'd0;
        assign q_rreq = 1'b0; assign q_raddr = 24'd0;
    end endgenerate
    // GX_SPILL: the ring (q_*) and the GX spill (s_*) share the SDRAM ports: a block write (8 words) or a
    // block read (rack, then 8 rvalid) is one client's until done; the ring first (its lines have deadlines)
    generate if (GX_SPILL) begin : g_sparb
        logic       wr, ws, rr, rs, wt, rt; // the write/read port's owner: ring, spill, STORE_SD's store (none: free)
        logic [2:0] wc, rc;
        logic       ta4;                    // the read's record is the block's second half
        logic       tp;                     // the block's read was taken: the store's next read waits for its last word
        wire  tw = STORE_SD && sm_req && sm_we;
        wire  tr = STORE_SD && sm_req && !sm_we;
        wire  w_r = wr || (!ws && !wt && q_wreq);
        wire  w_t = STORE_SD && (wt || (!wr && !ws && !q_wreq && tw));
        wire  w_s = ws || (!wr && !wt && !q_wreq && !tw && s_wreq);
        wire  r_r = rr || (!rs && !rt && q_rreq);
        wire  r_t = STORE_SD && (rt || (!rr && !rs && !q_rreq && tr));
        wire  r_s = rs || (!rr && !rt && !q_rreq && !tr && s_rreq);
        wire  [23:0] t_sda = 24'h0F0000 + 24'({sm_addr[20], sm_addr[16:2]});   // two banks of 128 KiB
        assign rg_wreq  = (w_r && q_wreq) || (w_s && s_wreq) || (w_t && tw);
        assign rg_waddr = w_t ? t_sda : w_s ? s_waddr : q_waddr;
        assign rg_wdata = w_t ? sm_wdata : w_s ? s_wdata : q_wdata;
        assign rg_wlast = w_t && wc == 3'd3;
        assign sm_wack = w_t && rg_wack;
        assign q_wack = w_r && rg_wack;
        assign s_wack = w_s && rg_wack;
        // the read owner is fixed from the clock its request is presented (the SDRAM latches the address
        // then and acks a clock later) through its rack and 8 rvalids
        assign rg_rreq  = (r_r && q_rreq) || (r_s && s_rreq) || (r_t && tr && !tp);
        assign rg_raddr = r_t ? {t_sda[23:3], 3'd0} : r_s ? s_raddr : q_raddr;
        assign sm_rack = r_t && rg_rack && tr && !tp;
        assign sm_rv = rt && rg_rvalid && rc[2] == ta4;
        assign q_rack = r_r && rg_rack;
        assign s_rack = r_s && rg_rack;
        assign q_rvalid = rr && rg_rvalid;
        assign s_rvalid = rs && rg_rvalid;
        always_ff @(posedge clk) begin
            if (rst) begin wr <= 1'b0; ws <= 1'b0; rr <= 1'b0; rs <= 1'b0; wc <= '0; rc <= '0; wt <= 1'b0; rt <= 1'b0; tp <= 1'b0; end
            else begin
                wr <= w_r; ws <= w_s; wt <= w_t;
                if (rg_wack && (w_r || w_s || w_t)) begin
                    wc <= wc + 3'd1;
                    if (wc == 3'd7) begin wr <= 1'b0; ws <= 1'b0; end
                    if (rg_wlast) begin wc <= '0; wt <= 1'b0; end
                end
                if (!rr && !rs && !rt) begin rr <= r_r; rs <= r_s; rt <= r_t; ta4 <= sm_addr[4]; end
                else if (rg_rvalid) begin rc <= rc + 3'd1; if (rc == 3'd7) begin rr <= 1'b0; rs <= 1'b0; rt <= 1'b0; tp <= 1'b0; end end
                if (sm_rack) tp <= 1'b1;
            end
        end
`ifndef SYNTHESIS
        // synthesis translate_off
        logic rq_r, rq_s;                   // the owner whose request the SDRAM saw last clock
        always_ff @(posedge clk) begin
            rq_r <= !rst && rg_rreq && r_r; rq_s <= !rst && rg_rreq && r_s;
            if (!rst && rg_rack && (r_r != rq_r || r_s != rq_s)) $error("nds_gpu3d g_sparb: rack to ring %0d spill %0d, address presented by ring %0d spill %0d", r_r, r_s, rq_r, rq_s);
            if (!rst && STORE_SD && sm_req && (sm_addr[22:21] != 2'b10 || sm_addr[19:17] != 3'd0)) $error("nds_gpu3d STORE_SD: address %h outside the store", sm_addr);
        end
        // synthesis translate_on
`endif
    end else begin : g_nosparb
        assign rg_wreq = q_wreq; assign rg_waddr = q_waddr; assign rg_wdata = q_wdata; assign q_wack = rg_wack;
        assign rg_rreq = q_rreq; assign rg_raddr = q_raddr; assign q_rack = rg_rack; assign q_rvalid = rg_rvalid;
        assign s_wack = 1'b0; assign s_rack = 1'b0; assign s_rvalid = 1'b0;
        assign rg_wlast = 1'b0; assign sm_wack = 1'b0; assign sm_rack = 1'b0; assign sm_rv = 1'b0;
    end endgenerate
    // r6 g6 b6 a5 -> the 2D engine's {a[28:24], b[21:16], g[13:8], r[5:0]}
    // A late line (the 2D engine starts a 3D line the raster hasn't finished,
    // or RING: one the ring can't deliver) shows the rear plane, the clear
    // colour and alpha, for the whole line, never an older line's slot. The DS
    // shows the polygons drawn so far on top of it (ds-rules, run 24); this
    // core's lines reach the ring only at the final pass.
    logic [8:0]  lv_fin;              // lines of the current frame finished (all 256 pixels out)
    // RESTART=0: a frame start skipped (the raster still on the last frame):
    // every line of this display frame shows the rear plane (lv_lo past the
    // last line), including the old frame's lines the raster finishes now;
    // the DS restarts instead and draws none of the old frame
    logic [8:0]  lv_lo;
    logic        lv_skip;
    always_ff @(posedge clk) lv_skip <= !rst && fg_now && !(RESTART || !r_busy);
    logic        lv_on, lv_go, l3d_rear;
    wire         ring_have;
    // LMARK: the frame start was held past line 215; the composed line's cause (2'b00: on time)
    logic        lm_held;
    logic [2:0]  lm_why;              // 1 yellow, 2 red, 3 green, 4 magenta
    always_ff @(posedge clk) begin
        lv_go <= !rst && l3d_go;
        if (rst) begin lv_fin <= 9'd0; lv_lo <= 9'd0; lv_on <= 1'b0; l3d_rear <= 1'b0; end
        else begin
            if (frame_go) begin lv_fin <= 9'd0; lv_lo <= 9'd0; lv_on <= 1'b1; end
            if (lv_skip) lv_lo <= 9'h1FF;
            if (px_valid && px_x == 8'hFF) lv_fin <= {1'b0, px_y} + 9'd1;
            if (lv_go) l3d_rear <= lv_on && ({1'b0, l3d_line} < lv_lo ||
                                             (RING ? !ring_have
                                                   : {1'b0, l3d_line} >= lv_fin && !(px_valid && px_x == 8'hFF && px_y == l3d_line)));
        end
        if (LMARK) begin
            if (rst) begin lm_held <= 1'b0; lm_why <= 3'd0; end
            else begin
                if (fg_now) lm_held <= fg_pend;
                if (lv_go) lm_why <= {1'b0, l3d_line} < lv_lo ? 3'd4 :
                                     {1'b0, l3d_line} >= lv_fin && !(px_valid && px_x == 8'hFF && px_y == l3d_line) ?
                                         (lm_held ? 3'd2 : 3'd1) : 3'd3;
            end
        end else begin lm_held <= 1'b0; lm_why <= 3'd0; end
    end
    function automatic [5:0] cexp5(input [4:0] c);   // as gpu3d_raster's exp5
        cexp5 = (c != 0) ? {c, 1'b1} : 6'd0;
    endfunction
    // LMARK: {a5, b6, g6, r6}
    wire  [22:0] lm_q = lm_why == 3'd4 ? {5'd31, 6'd63, 6'd0, 6'd63} :     // magenta
                        lm_why == 3'd1 ? {5'd31, 6'd0, 6'd63, 6'd63} :     // yellow
                        lm_why == 3'd2 ? {5'd31, 6'd0, 6'd0, 6'd63} :      // red
                                         {5'd31, 6'd0, 6'd63, 6'd0};       // green
    wire  [22:0] rear_q = LMARK ? lm_q : {r_clear_attr1[20:16], cexp5(r_clear_attr1[14:10]), cexp5(r_clear_attr1[9:5]), cexp5(r_clear_attr1[4:0])};
`ifdef G3D_NOREAR
    wire  [22:0] l3d_q = ring_q;           // (simulation mutant: late lines show the stale slot)
`else
    wire  [22:0] l3d_q = l3d_rear ? rear_q : ring_q;
`endif
    assign l3d_rdata = {3'd0, l3d_q[22:18], 2'd0, l3d_q[17:12], 2'd0, l3d_q[11:6], 2'd0, l3d_q[5:0]};

    // ---- raster diagnostics (docs/diag.md)
    wire         lv_late  = lv_go && lv_on && {1'b0, l3d_line} >= lv_fin && !(px_valid && px_x == 8'hFF && px_y == l3d_line);
    wire         lv_under = lv_go && lv_on && RING && !ring_have;
    assign diag_r_ev = {lv_under, tex_req, r_pixel, pc_ack, tc_ack, r_abort, lv_late,
                        r_phase == 3'd6, r_phase == 3'd5, r_phase == 3'd3, r_phase == 3'd2};
    assign diag_t_start  = t_req && t_ack;
    assign diag_t_stop   = t_rvalid && t_beat == 2'd0;
    assign diag_l3d_v    = lv_late;
    assign diag_l3d_line = {1'b0, l3d_line};
    logic [15:0] dr_first, dr_lead;
    wire  [15:0] dr_ld = 16'(lv_fin) - 16'(l3d_line);   // lines finished ahead of the one composed
    always_ff @(posedge clk) begin
        if (rst) begin diag_r_val <= 32'hFFFF_7FFF; dr_first <= 16'hFFFF; dr_lead <= 16'h7FFF; end
        else if (frame_go) begin diag_r_val <= {dr_first, dr_lead}; dr_first <= 16'hFFFF; dr_lead <= 16'h7FFF; end
        else begin
            if (lv_late && dr_first == 16'hFFFF) dr_first <= 16'(l3d_line);
            if (lv_go && lv_on && $signed(dr_ld) < $signed(dr_lead)) dr_lead <= dr_ld;
        end
    end
`ifndef ALTERA_RESERVED_QIS
    // +g3dperf: per rendered frame, the raster's cycles by phase (1 clear,
    // 2 stream/store, 3 edge, 4 span, 5 pixel, 6 final pass, 0 idle), spans
    // and pixels, texture/palette requests, cache misses (block requests)
    // and flushes (VRAM writes / VRAMCNT changes), from frame start to done
    bit pf_on;
    initial pf_on = $test$plusargs("g3dperf");
    longint pf_ph [0:7];
    longint pf_spans, pf_px, pf_treq, pf_preq, pf_tmiss, pf_pmiss, pf_flush, pf_cyc;
    // ... and the diagnostic outputs summed alike (all clocks): they must match
    longint pd_n [0:10];
    always_ff @(posedge clk) if (pf_on && !rst) begin
        if (frame_go) begin
            if (pd_n[0] != pf_ph[2] || pd_n[1] != pf_ph[3] || pd_n[2] != pf_ph[5] || pd_n[3] != pf_ph[6] || pd_n[6] != pf_tmiss ||
                pd_n[7] != pf_pmiss || pd_n[8] != pf_px || pd_n[9] != pf_treq)
                $error("nds_gpu3d: diag_r_ev sums %0d %0d %0d %0d %0d %0d %0d %0d differ from g3dperf", pd_n[0], pd_n[1], pd_n[2], pd_n[3],
                       pd_n[6], pd_n[7], pd_n[8], pd_n[9]);
            $display("g3ddiag raster: stream %0d edge %0d pixel %0d final %0d late %0d restart %0d tmiss %0d pmiss %0d px %0d treq %0d underrun %0d | val %08x",
                     pd_n[0], pd_n[1], pd_n[2], pd_n[3], pd_n[4], pd_n[5], pd_n[6], pd_n[7], pd_n[8], pd_n[9], pd_n[10], diag_r_val);
            for (int i = 0; i <= 10; i++) pd_n[i] = 0;
        end else for (int i = 0; i <= 10; i++) if (diag_r_ev[i]) pd_n[i]++;
        if (frame_go) begin
            $display("g3dperf cyc %0d idle %0d clear %0d stream %0d edge %0d span %0d pixel %0d final %0d spans %0d px %0d treq %0d tmiss %0d preq %0d pmiss %0d flush %0d",
                     pf_cyc, pf_ph[0], pf_ph[1], pf_ph[2], pf_ph[3], pf_ph[4], pf_ph[5], pf_ph[6], pf_spans, pf_px,
                     pf_treq, pf_tmiss, pf_preq, pf_pmiss, pf_flush);
            for (int i = 0; i < 8; i++) pf_ph[i] = 0;
            pf_spans = 0; pf_px = 0; pf_treq = 0; pf_preq = 0; pf_tmiss = 0; pf_pmiss = 0; pf_flush = 0; pf_cyc = 0;
        end else if (r_busy) begin
            pf_cyc++; pf_ph[r_phase]++;
            if (r_span) pf_spans++;
            if (r_pixel) pf_px++;
            if (tex_req) pf_treq++;
            if (pal_req) pf_preq++;
            if (tc_ack) pf_tmiss++;
            if (pc_ack) pf_pmiss++;
            if (vram_wr) pf_flush++;
        end
    end
    // ... and the texture/palette block port's latency: request to accept
    // (wait) and accept to first beat (lat), mean / max and log2 bins of lat
    longint pl_n, pl_w, pl_l, pl_wmax, pl_lmax, pl_rq, pl_bin [0:9];
    longint pl_at [0:1];    // accept times of the (at most 2) blocks in flight
    int     pl_q, pl_b;
    longint pl_d, pl_clk;
    longint tw_at [0:63], tw_n, tw_sum, tw_max;  // texel requests: tex_req to tex_valid (in order)
    int     tw_h, tw_t;
    always_ff @(posedge clk) if (pf_on && !rst) begin
        pl_clk++;
        if (frame_go) begin
            if (pl_n != 0)
                $display("g3dlat blocks %0d wait %0.1f (max %0d) lat %0.1f (max %0d) bins <16 %0d <32 %0d <64 %0d <128 %0d <256 %0d <512 %0d >=512 %0d texel wait %0.2f (max %0d) over %0d",
                         pl_n, real'(pl_w) / pl_n, pl_wmax, real'(pl_l) / pl_n, pl_lmax,
                         pl_bin[0] + pl_bin[1] + pl_bin[2] + pl_bin[3], pl_bin[4], pl_bin[5], pl_bin[6], pl_bin[7], pl_bin[8], pl_bin[9],
                         tw_n ? real'(tw_sum) / tw_n : 0.0, tw_max, tw_n);
            pl_n = 0; pl_w = 0; pl_l = 0; pl_wmax = 0; pl_lmax = 0;
            for (int i = 0; i < 10; i++) pl_bin[i] = 0;
            tw_n = 0; tw_sum = 0; tw_max = 0;
        end
        if (r_abort) tw_t = tw_h;
        else begin
            if (tex_valid) begin pl_d = pl_clk - tw_at[tw_t[5:0]]; tw_t++; tw_n++; tw_sum += pl_d; if (pl_d > tw_max) tw_max = pl_d; end
            if (tex_req) begin tw_at[tw_h[5:0]] = pl_clk; tw_h++; end
        end
        if (t_req && !t_ack) pl_rq++;
        if (t_ack) begin
            pl_w += pl_rq; if (pl_rq > pl_wmax) pl_wmax = pl_rq; pl_rq = 0;
            pl_at[pl_q[0]] = pl_clk; pl_q++;
        end
        if (t_rvalid && t_beat == 2'd0 && pl_q != 0) begin
            pl_d = pl_clk - pl_at[0];
            pl_at[0] = pl_at[1]; pl_q--;
            pl_b = 0;
            while (pl_b < 9 && (64'd1 << (pl_b + 1)) <= pl_d) pl_b++;
            pl_n++; pl_l += pl_d; if (pl_d > pl_lmax) pl_lmax = pl_d; pl_bin[pl_b]++;
        end
    end
    // Simulation check: a 3D line the 2D engine starts composing before the
    // raster has finished it (the ring slot still holds an older line), and a
    // frame start skipped because the raster is still busy. Late lines are
    // counted per frame and reported at the next frame start; the first few
    // are listed (docs/budget-3d.md, "Cycle budget").
    logic [8:0] lt_fin;               // lines of the current frame finished (all 256 pixels out)
    logic       lt_on;                // a frame has started: its lines are checked
    integer     lt_n = 0, lt_tot = 0, lt_first = -1, ld_n = 0;
    logic       lt_go;                // l3d_go a cycle late: nds_disp registers l3d_line with it
    always_ff @(posedge clk) begin
        lt_go <= !rst && l3d_go;
        if (rst) begin lt_fin <= 9'd0; lt_on <= 1'b0; end
        else begin
            if (frame_go) begin
                if (lt_n != 0) $display("g3d LATE: %0d 3D lines late in the last frame (first: line %0d), %0d so far", lt_n, lt_first, lt_tot);
                if (ld_n != lt_n)
                    $error("nds_gpu3d: %0d late events on diag_r_ev[4], the monitor %0d", ld_n, lt_n);
                ld_n = 0;
                lt_n = 0; lt_first = -1;
                lt_fin <= 9'd0; lt_on <= 1'b1;
            end
            if (line215 && rend_en && geom_en && r_busy)
                $display("g3d LATE: frame %s, the raster is still on line %0d of the last frame", RESTART ? "restarted" : "start skipped", lt_fin);
            if (px_valid && px_x == 8'hFF) lt_fin <= {1'b0, px_y} + 9'd1;
            if (diag_r_ev[4]) ld_n++;
            if (lt_go && lt_on && {1'b0, l3d_line} >= lt_fin && !(px_valid && px_x == 8'hFF && px_y == l3d_line)) begin
                if (lt_n == 0) begin
                    lt_first = l3d_line;
                    if (lt_tot < 3) $display("g3d LATE: line %0d composed with %0d lines finished, raster lines_done %0d, final pass done %0d",
                                             l3d_line, lt_fin, u_raster.lines_done, u_raster.fp_done);
                end
                lt_n = lt_n + 1; lt_tot = lt_tot + 1;
            end
        end
    end
`endif
`ifndef ALTERA_RESERVED_QIS
    // synthesis translate_off
    // +swhmon: per frame, when the swap's sort output ended and the frame started (clocks after the VBlank)
    bit swh_on;
    initial swh_on = $test$plusargs("swhmon");
    always_ff @(posedge clk) if (swh_on && !rst) begin
        if (so_done) $display("swhmon: sort output ended at %0d", sw_vb);
        if (frame_go) $display("swhmon: frame start at %0d%s", sw_vb, sw_busy ? " (swap still owed)" : "");
    end
    always_ff @(posedge clk) begin
        if (!rst && (so_we || so_done) && st_draw && fg_vb)
            $error("nds_gpu3d: a swap's sort output while the frame started after the VBlank is drawn (the SWIN window failed)");
    end
    // SWHOLD: a frame never starts while the store builds the swap's lists (its first lines would be fetched empty),
    // unless the hold ran out (sw_hok)
    always_ff @(posedge clk)
        if (SWHOLD && !rst && frame_go && st_bld && sw_hok)
            $error("nds_gpu3d: a frame start while the store builds its lists (SWHOLD)");
    // synthesis translate_on
`endif
endmodule

// The polygon store on chip, 2^PW polygons and 2^VW vertices per bank,
// with a fetcher that scans the whole render order for every line: the
// first integration (91bf297), kept as nds_g3d_store's reference (G3D_EQ,
// at PW=11, VW=13 the DS's full capacity).
module nds_g3d_onchip #(
    parameter int PW = 10,
    parameter int VW = 11
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         po_valid,
    output logic         po_ready,
    input  logic         po_type,
    input  logic [127:0] po_data,
    input  logic [10:0]  po_index,
    input  logic         so_we,
    input  logic [10:0]  so_pos,
    input  logic [10:0]  so_idx,
    input  logic         so_done,
    input  logic [11:0]  so_count,
    input  logic         ps_line_req,
    input  logic [7:0]   ps_line_y,
    input  logic [8:0]   y_lim,
    output logic         ps_valid,
    input  logic         ps_ready,
    output logic [1:0]   ps_type,
    output logic [127:0] ps_data
);
    localparam int CAP = 1 << PW;
    localparam logic [PW:0] CAPN = CAP;
    assign po_ready = 1'b1;
// ------------------------------------------------------- polygon store
    // header: {vertex start, header bits 106:0}; Y table: {skip, ytop, ybot}
    localparam int HW = 107 + VW;
    logic          wb, rb;                 // bank geom writes / the raster reads
    logic [PW:0]   rcount;                 // polygons in the render bank (order entries)
    logic [VW:0]   vptr;                   // next free vertex (VW+1: full flag)
    logic [PW-1:0] cur;                    // polygon receiving vertices
    logic          cur_ok;
    wire           h_in  = po_valid && !po_type && po_index < 11'(CAP) && vptr + 13'(po_data[80:77]) <= 13'(1 << VW);
    wire           v_in  = po_valid && po_type && cur_ok;
    logic          h_we, v_we, y_we, o_we;
    logic [PW:0]   h_wa, y_wa, h_ra, y_ra, o_wa, o_ra;
    logic [HW-1:0] h_q;
    logic [VW:0]   v_wa, v_ra;
    logic [115:0]  v_q;
    logic [16:0]   y_wd, y_q;
    logic [PW-1:0] o_q;
    logic          o_skip;
    assign h_we = h_in;
    assign h_wa = {wb, po_index[PW-1:0]};
    assign v_we = v_in;
    assign v_wa = {wb, vptr[VW-1:0]};
    assign y_we = po_valid && !po_type && po_index < 11'(CAP);
    assign y_wa = {wb, po_index[PW-1:0]};
    assign y_wd = {po_data[107] || !h_in, po_data[96:89], po_data[104:97]};
    assign o_we = so_we && so_pos < 11'(CAP);
    assign o_wa = {wb, so_pos[PW-1:0]};
    gpu3d_ram #(.W(HW),  .AW(PW + 1)) u_hdr (.clk, .we(h_we), .waddr(h_wa), .wdata({vptr[VW-1:0], po_data[106:0]}), .raddr(h_ra), .rdata(h_q));
    gpu3d_ram #(.W(116), .AW(VW + 1)) u_vtx (.clk, .we(v_we), .waddr(v_wa), .wdata(po_data[115:0]), .raddr(v_ra), .rdata(v_q));
    gpu3d_ram #(.W(17),  .AW(PW + 1)) u_ytab (.clk, .we(y_we), .waddr(y_wa), .wdata(y_wd), .raddr(y_ra), .rdata(y_q));
    // order entries whose polygon was not stored point past the capacity
    gpu3d_ram #(.W(PW + 1), .AW(PW + 1)) u_ord (.clk, .we(o_we), .waddr(o_wa),
        .wdata({so_idx >= 11'(CAP), so_idx[PW-1:0]}), .raddr(o_ra), .rdata({o_skip, o_q}));
    always_ff @(posedge clk) begin
        if (rst) begin
            wb <= 1'b0; rb <= 1'b1; rcount <= '0; vptr <= '0; cur_ok <= 1'b0;
        end else begin
            if (po_valid && !po_type) begin
                cur <= po_index[PW-1:0]; cur_ok <= h_in;
                // vertices of a polygon that does not fit are not kept
            end
            if (v_in) vptr <= vptr + 1'b1;
            if (so_done) begin
                wb <= !wb; rb <= wb; vptr <= '0; cur_ok <= 1'b0;
                rcount <= so_count > 12'(CAP) ? CAPN : so_count[PW:0];
            end
        end
    end

`ifndef ALTERA_RESERVED_QIS   // (Quartus rejects $test$plusargs)
    // simulation: what each swap hands the raster (+g3d_stats)
    integer st_drop = 0;
    logic   st_on = 1'b0;
    initial st_on = $test$plusargs("g3d_stats");
    always_ff @(posedge clk) begin
        if (po_valid && !po_type && !h_in) st_drop <= st_drop + 1;
        if (so_done) begin
            if (st_on) $display("g3d swap: %0d polygons, %0d vertices stored, %0d polygons dropped", so_count, vptr, st_drop);
            st_drop <= 0;
        end
    end
    // simulation: each polygon's header Y range and top/bottom vertices
    // against its vertex records, by melonDS's rule (GPU3D::SubmitPolygon:
    // top = first vertex of the smallest y, bottom = largest y, then
    // largest x); the raster's edge walk relies on them
    logic [106:0] ck_h;
    logic [3:0]   ck_n, ck_i, ck_vt, ck_vb;
    logic [7:0]   ck_yt, ck_yb;
    logic [8:0]   ck_xb;
    logic         ck_on;
    integer       ck_bad = 0;
    always_ff @(posedge clk) begin
        if (rst) ck_on <= 1'b0;
        else if (po_valid && !po_type) begin
            ck_h <= po_data[106:0]; ck_n <= po_data[80:77]; ck_i <= 4'd0; ck_on <= !po_data[107];
            ck_yt <= 8'hFF; ck_yb <= 8'h00; ck_xb <= 9'd0; ck_vt <= 4'd0; ck_vb <= 4'd0;
        end else if (po_valid && po_type && ck_on) begin
            logic [7:0] yy; logic [8:0] xx;
            logic [7:0] yt, yb; logic [8:0] xb; logic [3:0] vt, vb;
            xx = po_data[8:0]; yy = po_data[16:9];
            yt = ck_yt; yb = ck_yb; xb = ck_xb; vt = ck_vt; vb = ck_vb;
            if (ck_i == 0 || yy < yt) begin yt = yy; vt = ck_i; end
            if (ck_i == 0 || yy > yb || (yy == yb && xx > xb)) begin yb = yy; xb = xx; vb = ck_i; end
            ck_yt <= yt; ck_yb <= yb; ck_xb <= xb; ck_vt <= vt; ck_vb <= vb;
            ck_i <= ck_i + 4'd1;
            if (ck_i + 4'd1 == ck_n) begin
                ck_on <= 1'b0;
                if ((yt != ck_h[96:89] || yb != ck_h[104:97] || vt != ck_h[84:81] || vb != ck_h[88:85]) && ck_bad < 20) begin
                    ck_bad <= ck_bad + 1;
                    $display("g3d check: polygon header ytop %0d ybot %0d vtop %0d vbot %0d nv %0d, vertices give ytop %0d ybot %0d vtop %0d vbot %0d",
                             ck_h[96:89], ck_h[104:97], ck_h[84:81], ck_h[88:85], ck_n, yt, yb, vt, vb);
                end
            end
        end
    end
`endif

    // -------------------------------------------------------------- fetcher
    logic         l_pend, l_act;           // a line requested / being streamed
    logic [7:0]   l_y;
    logic [PW:0]  pos;
    logic         s1, s2;                  // scan pipeline: order read, Y-table read
    logic [PW-1:0] s2_idx;
    logic          s2_skip;
    // covering polygons, in order
    logic [PW-1:0] cf [0:15];
    logic [3:0]    cf_rp, cf_wp;
    logic [4:0]    cf_n;
    wire           cf_push, cf_pop;
    wire           y_ok  = 9'(l_y) <= y_lim;
    wire           s_go  = l_act && y_ok && pos != rcount && 5'(cf_n) + 5'(s1) + 5'(s2) < 5'd15;
    wire  [7:0]    yt = y_q[15:8], yb = y_q[7:0];
    assign cf_push = s2 && !s2_skip && !y_q[16] && l_y >= yt && (l_y < yb || (l_y == yt && yb == yt));
    assign o_ra = {rb, pos[PW-1:0]};
    assign y_ra = {rb, o_q};

    typedef enum logic [2:0] { B_IDLE, B_H1, B_H2, B_V0, B_V1, B_V2 } bst_t;
    bst_t        bst;
    logic [HW-1:0] hq;
    logic [115:0]  vq;
    logic [3:0]    vcnt;
    logic [VW-1:0] vp;
    wire           out_free = !ps_valid || ps_ready;
    wire           scan_done = pos == rcount && !s1 && !s2;
    assign cf_pop = bst == B_IDLE && cf_n != 5'd0;
    assign h_ra = {rb, cf[cf_rp]};
    assign v_ra = {rb, vp};

    always_ff @(posedge clk) begin
        if (ps_valid && ps_ready) ps_valid <= 1'b0;
        if (rst) begin
            l_pend <= 1'b0; l_act <= 1'b0; s1 <= 1'b0; s2 <= 1'b0; ps_valid <= 1'b0;
            cf_rp <= 4'd0; cf_wp <= 4'd0; cf_n <= 5'd0; bst <= B_IDLE;
        end else begin
            if (ps_line_req) begin l_y <= ps_line_y; l_act <= 1'b1; pos <= '0; end
            // scan
            s1 <= s_go;
            if (s_go) pos <= pos + 1'b1;
            s2 <= s1; s2_skip <= o_skip; s2_idx <= o_q;
            if (cf_push) begin cf[cf_wp] <= s2_idx; cf_wp <= cf_wp + 4'd1; end
            if (cf_pop) cf_rp <= cf_rp + 4'd1;
            cf_n <= cf_n + (cf_push ? 5'd1 : 5'd0) - (cf_pop ? 5'd1 : 5'd0);
            // stream
            case (bst)
                B_IDLE: if (cf_pop) bst <= B_H1;
                        else if (l_act && scan_done && cf_n == 5'd0 && out_free && !ps_line_req) begin
                            ps_valid <= 1'b1; ps_type <= 2'd3; l_act <= 1'b0;
                        end
                B_H1: begin hq <= h_q; bst <= B_H2; end
                B_H2: if (out_free) begin
                    ps_valid <= 1'b1; ps_type <= 2'd0; ps_data <= {21'd0, hq[106:0]};
                    vcnt <= hq[80:77]; vp <= hq[HW-1:107];
                    bst <= hq[80:77] != 4'd0 ? B_V0 : B_IDLE;
                end
                B_V0: bst <= B_V1;
                B_V1: begin vq <= v_q; vp <= vp + 1'b1; vcnt <= vcnt - 4'd1; bst <= B_V2; end
                default: if (out_free) begin
                    ps_valid <= 1'b1; ps_type <= 2'd1; ps_data <= {12'd0, vq};
                    bst <= vcnt != 4'd0 ? B_V0 : B_IDLE;
                end
            endcase
        end
    end
    // (pipeline: s_go reads order[pos]; in s1 its index o_q reads the Y
    // table and is kept as s2_idx; in s2 the Y range y_q decides)

endmodule

// 16-bit reads through a cache of 2^LW sets of WAYS 32-byte blocks
// (WAYS 1: direct mapped; 2: two ways, the one used least recently refilled).
// Requests (one-cycle pulses) queue up and are answered in order, any
// latency. A miss reads the block through the block port. The tags and
// valid state are in nds_lcache (M3): a flush (any VRAM write) moves its
// generation on; while it waits for its scrubber (busy), no lookup starts.
module nds_g3d_cache #(
    parameter int AW = 19,
    parameter int LW = 6,
    // FAST: a hit with another request queued reads the next one's tag and
    // data in the same cycle (one lookup per clock instead of two)
    parameter bit FAST = 0,
    // MIF2: while the head's block fills, the next request's block is looked
    // up and, if it misses into another line, requested too (two blocks in
    // flight; the port returns them in order). Answers stay in order.
    parameter bit MIF2 = 0,
    parameter int WAYS = 1,
    parameter int QL = 4                // log2 request queue entries
) (
    input  logic          clk,
    input  logic          rst,
    input  logic          flush,
    input  logic          req,
    input  logic [AW-1:0] addr,
    output logic          valid,
    output logic [15:0]   data,
    output logic          b_req,
    output logic [13:0]   b_blk,
    input  logic          b_ack,
    input  logic          b_rvalid,
    input  logic [63:0]   b_rdata
);
    localparam int TW = AW - 5 - LW;
    localparam int QN = QL + 1;         // request count bits
    logic [AW-1:1] q [0:(1<<QL)-1];
    logic [QL-1:0] rp, wp;
    logic [QL:0]   n;
    logic          vld_q, tc_busy;
    logic [TW-1:0] tag_q;
    logic [63:0]   d_q;
    // WAYS 2: way 1's tag and data beside way 0's (vld_q/tag_q/d_q), the way
    // a fill goes to (fway: the head's, pway: the prefetch's) and per set the
    // way used last (mru)
    logic          vld1_q, busy1;
    logic [TW-1:0] tag1_q;
    logic [63:0]   d1_q;
    logic          fway, pway;
    logic [(1<<LW)-1:0] mru;
    logic          d_we, t_we;
    logic [LW+1:0] d_wa;
    logic [1:0]    beat;
    logic          stale;          // VRAM written while this block was read
    typedef enum logic [2:0] { C_IDLE, C_LOOK, C_REQ, C_FILL, C_PFW } cst_t;
    cst_t st;
    wire  [AW-1:1] h = q[rp];
    wire  [AW-1:1] h1 = q[QL'(rp + 1'b1)];
    wire  [LW-1:0] line = h[LW+4:5];
    wire hit0 = vld_q && tag_q == h[AW-1:LW+5];
    wire hit1 = WAYS > 1 && vld1_q && tag1_q == h[AW-1:LW+5];
    wire hit = hit0 || hit1;
    // the way a miss refills: an invalid one, else the one not used last
    wire vict = WAYS > 1 && (vld_q ? (!vld1_q || !mru[h[LW+4:5]]) : 1'b0);
    // FAST: the next lookup starts in the cycle the head hits
    wire           nxt = FAST && st == C_LOOK && hit && n >= QN'(2) && !tc_busy;
    wire  [AW-1:1] ha = nxt ? h1 : h;            // what the RAMs and tags read
    // MIF2: the next request's block, looked up during the head's fill
    typedef enum logic [2:0] { P_NONE, P_CHK, P_REQ, P_WAIT, P_SKIP } pst_t;
    pst_t          pst;
    logic [AW-1:1] pa;             // its address
    logic [1:0]    pbeat;
    logic          pstale;
    wire  [LW-1:0] pline = pa[LW+4:5];
    wire           p_look = MIF2 && st == C_FILL && pst == P_NONE && n >= QN'(2) && !tc_busy;
    wire           p_beat = MIF2 && b_rvalid && st != C_FILL;   // the head's beats come first
    wire           p_end  = p_beat && pbeat == 2'd3;
    wire           w_way = p_beat ? pway : fway;    // the way the fill (data, tag) goes to
    wire           l_en  = (st == C_IDLE && n != '0 && !tc_busy) || nxt || p_look;
    wire  [LW-1:0] l_idx = p_look ? h1[LW+4:5] : ha[LW+4:5];
    logic          busy0;
    gpu3d_ram #(.W(64), .AW(LW + 2)) u_d (.clk, .we(d_we && !w_way), .waddr(d_wa), .wdata(b_rdata),
        .raddr({ha[LW+4:5], ha[4:3]}), .rdata(d_q));
    nds_lcache #(.LB(LW), .TW(TW), .G(3)) u_t (.clk, .clk2(1'b0), .rst,
        .l_en, .l_idx, .l_v(), .l_vn(vld_q), .l_tag(tag_q),
        .c_idx('0), .c_v(), .c_tag(),
        .f_busy(1'b0), .f_idx(p_end ? pline : line), .f_end((t_we || p_end) && !w_way), .f_ok(p_end ? !pstale : !stale),
        .f_tag(p_end ? pa[AW-1:LW+5] : h[AW-1:LW+5]),
        .inv(1'b0), .inv_idx('0), .inv_all(flush), .busy(busy0));
    generate if (WAYS > 1) begin : g_w1
        gpu3d_ram #(.W(64), .AW(LW + 2)) u_d1 (.clk, .we(d_we && w_way), .waddr(d_wa), .wdata(b_rdata),
            .raddr({ha[LW+4:5], ha[4:3]}), .rdata(d1_q));
        nds_lcache #(.LB(LW), .TW(TW), .G(3)) u_t1 (.clk, .rst,
            .l_en, .l_idx, .l_v(), .l_vn(vld1_q), .l_tag(tag1_q),
            .c_idx('0), .c_v(), .c_tag(),
            .f_busy(1'b0), .f_idx(p_end ? pline : line), .f_end((t_we || p_end) && w_way), .f_ok(p_end ? !pstale : !stale),
            .f_tag(p_end ? pa[AW-1:LW+5] : h[AW-1:LW+5]),
            .inv(1'b0), .inv_idx('0), .inv_all(flush), .busy(busy1));
    end else begin : g_w0
        assign d1_q = '0; assign vld1_q = 1'b0; assign tag1_q = '0; assign busy1 = 1'b0;
    end endgenerate
    assign tc_busy = busy0 || busy1;
    wire  [63:0]   d_sel = hit1 ? d1_q : d_q;
    assign d_we  = (st == C_FILL && b_rvalid) || p_beat;
    assign d_wa  = p_beat ? {pline, pbeat} : {line, beat};
    assign t_we  = st == C_FILL && b_rvalid && beat == 2'd3;
    assign b_req = st == C_REQ || (pst == P_REQ && st != C_REQ);
    assign b_blk = st == C_REQ ? 14'(h[AW-1:5]) : 14'(pa[AW-1:5]);
    always_ff @(posedge clk) begin
        valid <= 1'b0;
        if (rst) begin
            rp <= '0; wp <= '0; n <= '0; st <= C_IDLE; beat <= 2'd0; pst <= P_NONE; pbeat <= 2'd0;
            mru <= '0; fway <= 1'b0; pway <= 1'b0;
        end else begin
            if (req) begin q[wp] <= addr[AW-1:1]; wp <= wp + 1'b1; end
            n <= n + QN'(req) - QN'(st == C_LOOK && hit);
            case (st)
                C_IDLE: if (n != '0 && !tc_busy) st <= C_LOOK;   // RAMs read the head this cycle
                C_LOOK: if (hit) begin
                    valid <= 1'b1; data <= d_sel[h[2:1]*16 +: 16]; rp <= rp + 1'b1;
                    st <= nxt ? C_LOOK : C_IDLE;
                end else if (MIF2 && (pst == P_REQ || pst == P_WAIT))
                    st <= C_PFW;                                    // a prefetched block is on the way (its own, as the
                                                                    // prefetch is always the next request): wait for it
                else begin st <= C_REQ; fway <= vict; end
                C_REQ: if (b_ack) begin st <= C_FILL; beat <= 2'd0; stale <= 1'b0; end
                C_PFW: if (pst == P_NONE) st <= C_IDLE;             // filled: look it up again
                default: if (b_rvalid) begin
                    beat <= beat + 2'd1;
                    if (beat == 2'd3) st <= C_IDLE;               // (valid unless stale: u_t)
                end
            endcase
            if (flush) stale <= 1'b1;
            if (WAYS > 1) begin
                if (st == C_LOOK && hit) mru[line] <= hit1;
                if (t_we) mru[line] <= fway;
                if (p_end) mru[pline] <= pway;
            end
            if (MIF2) begin
                if (p_beat) pbeat <= pbeat + 2'd1;
                case (pst)
                    P_NONE: if (p_look) begin pa <= h1; pst <= P_CHK; end
                    // the next request misses into another line than the head's
                    P_CHK: begin
                        pst <= (!(vld_q && tag_q == pa[AW-1:LW+5]) && !(WAYS > 1 && vld1_q && tag1_q == pa[AW-1:LW+5]) &&
                                pa[AW-1:5] != h[AW-1:5] && pline != line) ? P_REQ : P_SKIP;
                        pway <= WAYS > 1 && (vld_q ? (!vld1_q || !mru[pline]) : 1'b0);
                    end
                    P_REQ: if (b_ack && st != C_REQ) begin pst <= P_WAIT; pbeat <= 2'd0; pstale <= 1'b0; end
                    P_WAIT: if (p_end) pst <= P_NONE;
                    default: if (st != C_FILL) pst <= P_NONE;       // P_SKIP: until the head's fill is over
                endcase
                if (flush) pstale <= 1'b1;
            end
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!rst && req && n == QN'(1 << QL)) $error("nds_g3d_cache: request queue overflow");
`endif
endmodule

// nds_g3d_cache's interface and answers (in order, any latency) with a block
// port kept busy ahead of the head (direct mapped only):
//   - blocks in flight (up to 2, oldest first) and the one asked for (r) are
//     one queue; a fill writes its line as its beats come, the tag at the
//     last; a lookup of a line whose beats are being written misses;
//   - a head miss asks for its block (first) unless it is on the way, and
//     waits for it to land;
//   - a scanner looks up the queued requests behind the head, one a clock,
//     on a second tag copy (nds_lcache CHECK), and asks for the first block
//     that misses into a line no block on the way or the head uses;
//   - lookups: one a clock while requests are queued (FAST), and a request
//     with none queued before it is looked up (from addr) as it comes.
module nds_g3d_cache2 #(
    parameter int AW = 19,
    parameter int LW = 6,
    parameter int QL = 4,               // log2 request queue entries
    parameter bit SCAN = 1,             // 0: no scanner (and no second tag copy): only head misses ask for blocks
    parameter int NF = 2,               // blocks on the way at most (in flight and the one asked for)
    // PF: prefetch hints (pf_v, pf_a: a texel the raster will ask for later) in
    // a 4-entry FIFO, each looked up on the scanner's tag port when the
    // scanner has nothing to look up, its block asked for on a miss
    parameter bit PF = 0,
    // PUMP: the tag store's two copies as one block double-pumped on clk2 (nds_lcache PUMP)
    parameter bit PUMP = 0,
    // WAYS (1, 2, 4): set-associative at the same size (2^LW lines): a tag store and a data RAM per way, looked
    // up in parallel; a new block goes into an invalid way of its set, else a pseudo-random one (an LFSR: as
    // good as LRU on the bench's texel traces, and no state per set). 1: direct mapped as before
    parameter int WAYS = 1,
    // TSHARE (WAYS > 1): one tag store controller for every way (nds_lcache_n: generation, scrubber, masks shared;
    // synthesis #1711: four nds_lcache repeat ~90 ALUTs and ~80 registers each); 0: an nds_lcache a way
    parameter bit TSHARE = 1
) (
    input  logic          clk,
    input  logic          clk2,         // PUMP: 2 x clk, phase 0
    input  logic          rst,
    input  logic          flush,
    input  logic          req,
    input  logic [AW-1:0] addr,
    output logic          valid,
    output logic [15:0]   data,
    output logic          b_req,
    output logic [13:0]   b_blk,
    input  logic          b_ack,
    input  logic          b_rvalid,
    input  logic [63:0]   b_rdata,
    input  logic          pf_v,
    input  logic [AW-1:0] pf_a
);
    localparam int WB = WAYS > 1 ? $clog2(WAYS) : 0;
    localparam int WN = WB > 0 ? WB : 1;
    localparam int SB = LW - WB;        // set index bits
    localparam int TW = AW - 5 - SB;
    localparam int BW = AW - 5;         // block address bits
    localparam int QN = QL + 1;
    logic [QL-1:0] rp, wp;
    logic [QL:0]   n;
    typedef enum logic [1:0] { C_IDLE, C_LOOK, C_NEED, C_WAIT } cst_t;
    cst_t st;
    // the request queue, one MLAB copy per read: the head, the one behind it,
    // the scanner's (a register file read at three addresses costs a mux each)
    logic [AW-1:1] h, h1, hs;
    gpu3d_lram #(.W(AW - 1), .AW(QL)) u_q0 (.clk, .we(req && !rst), .waddr(wp), .wdata(addr[AW-1:1]), .raddr(rp), .rdata(h));
    gpu3d_lram #(.W(AW - 1), .AW(QL)) u_q1 (.clk, .we(req && !rst), .waddr(wp), .wdata(addr[AW-1:1]), .raddr(QL'(rp + 1'b1)), .rdata(h1));
    wire  [BW-1:0] hb = h[AW-1:5];
    wire  [SB-1:0] line = h[SB+4:5];    // the head's set
    logic [WAYS-1:0] vld_q, tc_bw, mk_q, s_vw, hit_w;   // per way: valid, tag store busy, being filled
    wire           tc_busy = |tc_bw;
    logic [TW-1:0] tag_q [0:WAYS-1];
    logic [TW-1:0] s_tagw [0:WAYS-1];
    logic [63:0]   d_w [0:WAYS-1];
    // the head's halfword: each way's from its row first (h is a register), then the hit way's (WAYS > 1: a
    // 16-bit select after the tag compares, not a 64-bit one)
    logic [15:0]   d_q;
    always_comb begin
        d_q = '0;
        for (int w = 0; w < WAYS; w++) begin
            hit_w[w] = vld_q[w] && !mk_q[w] && tag_q[w] == h[AW-1:SB+5];
            if (hit_w[w]) d_q = d_w[w][h[2:1]*16 +: 16];
        end
    end
    wire           hit = |hit_w;
    wire           nxt  = st == C_LOOK && hit && n >= QN'(2) && !tc_busy;
    wire           b_go = req && !tc_busy && ((st == C_IDLE && n == '0) || (st == C_LOOK && hit && n == QN'(1)));
    wire  [AW-1:1] ha   = nxt ? h1 : b_go ? addr[AW-1:1] : h;
    wire           l_en = (st == C_IDLE && n != '0 && !tc_busy) || nxt || b_go;

    // blocks on the way: f (in flight, [0] the oldest, a FIFO filled from
    // [0] up; its beats fb) and r (asked for); NF of them at most
    logic [NF-1:0] f_v, f_st;       // valid, VRAM written since it was asked for
    logic [BW-1:0] f_a [0:NF-1];
    logic [WN-1:0] f_w [0:NF-1];    // its way
    logic [WN-1:0] r_w;
    logic [1:0]    fb;
    logic          r_v;
    logic [BW-1:0] r_a;
    wire           slot = !f_v[NF-1] && !(r_v && f_v[NF-2]);
    function automatic logic onway(input logic [BW-1:0] b);
        logic o;
        o = r_v && r_a == b;
        for (int i = 0; i < NF; i++) o |= f_v[i] && f_a[i] == b;
        return o;
    endfunction
    function automatic logic lbusy(input logic [SB-1:0] l);    // (WAYS > 1: any way of the set)
        logic o;
        o = r_v && r_a[SB-1:0] == l;
        for (int i = 0; i < NF; i++) o |= f_v[i] && f_a[i][SB-1:0] == l;
        return o;
    endfunction
    wire           f_last = b_rvalid && fb == 2'd3;
    wire  [NF-1:0] fv_a = f_last ? f_v >> 1 : f_v;         // after this cycle's pop
    wire  [SB-1:0] f_line = f_a[0][SB-1:0];
    // a new block's way: the first invalid way of its set (by the lookup's or the check's valid bits), else
    // the LFSR's; the head's is taken at its lookup (C_NEED asks later)
    logic [15:0]   lfsr;
    always_ff @(posedge clk) lfsr <= rst ? 16'hACE1 : {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    function automatic logic [WN-1:0] victim(input logic [WAYS-1:0] v);
        logic [WN-1:0] o;
        o = WN'(lfsr);
        for (int w = WAYS - 1; w >= 0; w--) if (!v[w]) o = WN'(w);
        return o;
    endfunction
    logic [WN-1:0] h_w;             // the head's way to fill, from its last lookup
    wire           filling = f_v[0] && (b_rvalid || fb != 2'd0);

    // the scanner: sq the next entry to look up (rp < sq <= wp), sa the one
    // looked up last cycle (s_q)
    logic [QL-1:0] sq;
    logic          s_q;
    logic [AW-1:1] sa;
    generate if (SCAN) begin : g_qs
        gpu3d_lram #(.W(AW - 1), .AW(QL)) u_q2 (.clk, .we(req && !rst), .waddr(wp), .wdata(addr[AW-1:1]), .raddr(sq), .rdata(hs));
    end else begin : g_nqs
        assign hs = '0;
    end endgenerate
    logic          s_hit;           // the scanned block is in some way
    // the head asks first (its miss now, or waiting for room)
    wire           s_free = !r_v && slot && st != C_NEED && !(st == C_LOOK && !hit);
    wire           s_go  = SCAN && s_free && QN'(QL'(sq - rp)) < n && !tc_busy;
    // PF: the hint FIFO (block addresses), one looked up when the scanner is idle
    logic [AW-1:5] pq [0:3];
    logic [2:0]    pq_n;
    wire           p_go  = PF && SCAN && s_free && !s_go && pq_n != 3'd0 && !tc_busy;
    wire  [AW-1:1] s_in  = p_go ? {pq[0], 4'd0} : hs;
    // (a block on the way holds its line, so !lbusy covers !onway for sa)
    // WAYS > 1: the check's words (PUMP: taken half a clock late) go into registers at this edge and are
    // compared the next clock, so the scanner asks a clock later (#1723: hb -> r_a -0.872 ns with four compares
    // and the victim in half a clock); a block that lands meanwhile may be asked for again into another way
    // (both copies hold its data). WAYS 1: as before
    logic          s_q2;
    logic [AW-1:1] sa2;
    logic [WAYS-1:0] s_vw2;
    logic [TW-1:0] s_tagw2 [0:WAYS-1];
    always_ff @(posedge clk) begin
        s_q2 <= !rst && s_q; sa2 <= sa; s_vw2 <= s_vw;
        for (int w = 0; w < WAYS; w++) s_tagw2[w] <= s_tagw[w];
    end
    wire           s_qx = WAYS > 1 ? s_q2 : s_q;
    wire  [AW-1:1] sx   = WAYS > 1 ? sa2 : sa;
    wire  [WAYS-1:0] s_vx = WAYS > 1 ? s_vw2 : s_vw;
    always_comb begin
        s_hit = 1'b0;
        for (int w = 0; w < WAYS; w++) s_hit |= s_vx[w] && (WAYS > 1 ? s_tagw2[w] : s_tagw[w]) == sx[AW-1:SB+5];
    end
    wire           s_req = s_qx && s_free && !s_hit &&
                           sx[SB+4:5] != line && !lbusy(sx[SB+4:5]);

    genvar gw;
    generate for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_way
        wire mine = WAYS == 1 || f_w[0] == WN'(gw);     // the block being filled goes into this way
`ifdef G3D_TC2_MUT
        // (mutant: a fill's data goes into the next way, its tag into the right one)
        wire dmine = WAYS == 1 || f_w[0] == WN'((gw + 1) % WAYS);
`else
        wire dmine = mine;
`endif
        gpu3d_ram #(.W(64), .AW(SB + 2)) u_d (.clk, .we(b_rvalid && dmine), .waddr({f_line, fb}), .wdata(b_rdata),
            .raddr({ha[SB+4:5], ha[4:3]}), .rdata(d_w[gw]));
        if (!(WAYS > 1 && TSHARE && SCAN)) begin : g_t
        nds_lcache #(.LB(SB), .TW(TW), .G(3), .CHECK(SCAN ? 1 : 0), .PUMP(PUMP && SCAN)) u_t (.clk, .clk2, .rst,
            .l_en, .l_idx(ha[SB+4:5]), .l_v(), .l_vn(vld_q[gw]), .l_tag(tag_q[gw]),
            .c_idx(s_in[SB+4:5]), .c_v(s_vw[gw]), .c_tag(s_tagw[gw]),
            .f_busy(1'b0), .f_idx(f_line), .f_end(f_last && mine), .f_ok(!f_st[0]), .f_tag(f_a[0][BW-1:SB]),
            .inv(1'b0), .inv_idx('0), .inv_all(flush), .busy(tc_bw[gw]));
        end
        always_ff @(posedge clk) mk_q[gw] <= filling && mine && f_line == ha[SB+4:5];
    end endgenerate
    generate if (WAYS > 1 && TSHARE && SCAN) begin : g_tsh
        logic tb;
        nds_lcache_n #(.LB(SB), .TW(TW), .G(3), .WAYS(WAYS), .PUMP(PUMP)) u_t (.clk, .clk2, .rst,
            .l_en, .l_idx(ha[SB+4:5]), .l_vn(vld_q), .l_tag(tag_q),
            .c_idx(s_in[SB+4:5]), .c_v(s_vw), .c_tag(s_tagw),
            .f_idx(f_line), .f_end(f_last), .f_way(f_w[0][$clog2(WAYS)-1:0]), .f_ok(!f_st[0]), .f_tag(f_a[0][BW-1:SB]),
            .inv_all(flush), .busy(tb));
        assign tc_bw = {WAYS{tb}};
    end endgenerate
    assign b_req = r_v;
    assign b_blk = 14'(r_a);
    always_ff @(posedge clk) begin
        valid <= 1'b0;
        if (rst) begin
            rp <= '0; wp <= '0; n <= '0; st <= C_IDLE; f_v <= '0; fb <= 2'd0; r_v <= 1'b0;
            sq <= QL'(1); s_q <= 1'b0;
        end else begin
            if (req) wp <= wp + 1'b1;
            n <= n + QN'(req) - QN'(st == C_LOOK && hit);
            case (st)
                C_IDLE: if ((n != '0 && !tc_busy) || b_go) st <= C_LOOK;   // RAMs read the head this cycle
                C_LOOK: if (hit) begin
                    valid <= 1'b1; data <= d_q; rp <= rp + 1'b1;
                    st <= nxt || b_go ? C_LOOK : C_IDLE;
                end else if (onway(hb)) st <= C_WAIT;
                else if (!r_v && slot) begin r_v <= 1'b1; r_a <= hb; r_w <= victim(vld_q); st <= C_WAIT; end
                else begin h_w <= victim(vld_q); st <= C_NEED; end
                C_NEED: if (onway(hb)) st <= C_WAIT;
                        else if (!r_v && slot) begin r_v <= 1'b1; r_a <= hb; r_w <= h_w; st <= C_WAIT; end
                default: if (!onway(hb)) st <= C_IDLE;                 // C_WAIT: landed, look it up again
            endcase
            // the scan stays behind the head
            s_q <= s_go || p_go;
            if (s_go) begin sa <= hs; sq <= sq + 1'b1; end
            if (p_go) sa <= s_in;
            if (st == C_LOOK && hit && sq == QL'(rp + 1'b1) && !s_go) sq <= sq + 1'b1;
            if (s_req) begin r_v <= 1'b1; r_a <= sx[AW-1:5]; r_w <= victim(s_vx); end
            // in flight: pop the oldest at its last beat, push r at its ack
            if (b_rvalid) fb <= fb + 2'd1;
            if (b_ack) r_v <= 1'b0;
            if (f_last) for (int i = 0; i < NF - 1; i++) begin f_a[i] <= f_a[i + 1]; f_w[i] <= f_w[i + 1]; f_st[i] <= f_st[i + 1]; end
            // the asked-for block goes into the next free slot every clock it is
            // asked for, not only at its ack: the slot is not valid until f_v
            // takes it at the ack, and r_a holds meanwhile, so the ack (late:
            // the block port's arbiter, 2D first) only sets f_v (timing)
            if (r_v)
                for (int i = 0; i < NF; i++)
                    if (!fv_a[i] && (i == 0 || fv_a[(i == 0) ? 0 : i - 1])) begin f_a[i] <= r_a; f_w[i] <= r_w; f_st[i] <= flush; end
            f_v <= b_ack ? (fv_a << 1) | NF'(1) : fv_a;
            if (flush) f_st <= '1;
        end
    end
    // the hint FIFO: push (dropped when full), pop on its lookup
    always_ff @(posedge clk)
        if (rst || !PF) pq_n <= 3'd0;
        else begin
            if (p_go) for (int i = 0; i < 3; i++) pq[i] <= pq[i + 1];
            if (pf_v && pq_n - 3'(p_go) < 3'd4) pq[2'(pq_n - 3'(p_go))] <= pf_a[AW-1:5];
            pq_n <= pq_n - 3'(p_go) + 3'(pf_v && pq_n - 3'(p_go) < 3'd4);
        end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!rst && req && n == QN'(1 << QL)) $error("nds_g3d_cache2: request queue overflow");
    always_ff @(posedge clk) if (!rst && b_rvalid && !f_v[0]) $error("nds_g3d_cache2: a beat with no block in flight");
`endif
endmodule
