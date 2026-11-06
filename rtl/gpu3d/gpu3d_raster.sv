// NDS 3D rasterizer, scanline order, pixel-exact against melonDS's
// SoftRenderer3D (references/melonDS/src/GPU3D_Soft.cpp). See
// docs/renderer-3d.md for the design and what is still missing.
//
// Structure: span setup is three overlapped stages (input, two edge units
// in gpu3d_edge.sv, span) handing each span to a pixel pipeline (one pixel
// per clock) through two descriptor slots. Per frame:
//   for y in 0..191:
//     request the polygon stream for line y; for each polygon covering y:
//       set up its left/right edges at y (Slope::Setup), the span
//       (EdgeParams, fill rules, attribute interpolation along Y); the
//       pipeline walks the span's three parts (left edge, inside, right edge)
//   and beside it, a final-pass engine: once line f+1 is rendered, edge
//   marking, fog and anti-aliasing of line f -> pixels, clearing line f-1
//   (whose slot line f+3 reuses) as it goes.
// Edge state is recomputed from the vertices every line instead of being
// stepped; Slope::Step is closed-form so the result is identical.
//
// Line buffer: 4 lines x 2 layers (topmost and the one beneath, for AA),
// each entry {attr[31:0], depth[23:0], color[22:0]}; color is
// r[5:0] g[11:6] b[17:12] a[22:18]; attr uses melonDS's AttrBuffer layout.
module gpu3d_raster #(
    // 0 (the default): full rate, eight divider stages, a divider each.
    // 1: half-rate pixel pipeline with the four-stage folded divider, one
    // divider shared by the edge unit and the span stage (make
    // test-gpu3d-area checks it). nds-fit #187: no area gain for +75K
    // cycles on KH, so it is off.
    parameter bit AREA = 0,
    // 1: linear spans step their five attributes on one stepper, one per
    // cycle (five cycles per linear pixel, see g_lser)
    parameter bit LINSER = 0,
    // 1: linear spans by reciprocal: the descriptor carries ceil(2^37/xdiff)
    // instead of five quotients and remainders, and a linear pixel's five
    // offsets floor(ad * f / xdiff) (f = ix or xdiff - ix) are formed in
    // P12 on one lane, (ad * f * R) >> 37, exact for ad * f < 2^27 (see g_lrec)
    parameter bit RECIP = 1,
    // DS-verified rules (AGENTS.md: the real DS is ground truth; 0 = melonDS)
    // DS_AA0: an AA pixel of coverage 0 over a transparent lower pixel keeps
    // its colour with alpha 0 (hwref cap3d ui_text, aa_over_2d)
    parameter bit DS_AA0 = 1,
    // DS_TOON: the toon/highlight index is red interpolated from the vertex
    // colours without their 0xF fill, >> 4, along X with a truncated 12-bit
    // factor (x << 12) / xdiff on linear spans (hwref rules3d toon_span,
    // tris_toon; docs/hw-reference.md "Rule DS_TOON"). Needs RECIP.
    parameter bit DS_TOON = 1,
    // DS_HILITE: in highlight mode the vertex colour (all = red) is the
    // fill-less red >> 3 (the DS_TOON value), and the toon colour is added as
    // c << 1 without melonDS's + 1 (hwref rules3d hilite_span, tris_hilite;
    // docs/hw-reference.md "Rule DS_HILITE"). Needs DS_TOON.
    parameter bit DS_HILITE = 1,
    // DS_LIN17: linear interpolation (X and Y, every attribute) is
    // y0 + ((y1 - y0) * f >> 17), f = floor((k << 17) / len), descending
    // mirrored (hwref rules3d v2; docs/hw-reference.md "Rule DS_LIN17"). Along
    // X f = (ix * ceil(2^37/xdiff)) >> 20 (exact for len < 1024; the RECIP
    // reciprocal), on the perspective product lanes: no linear lane, linear
    // pixels at one per clock. Needs RECIP.
    parameter bit DS_LIN17 = 1,
    // DS_LINZ: Z-buffer Z (X and Y) is the DS_LIN17 factor on the full 24-bit
    // difference, zmin + (dz * f) >> 17 (hwref "Z-buffer interpolation",
    // partly pinned: depth_y 11,722 -> 134 px against the DS); replaces
    // melonDS's (dz >> 9) * x * xrecip and the edge's normalisation.
    // W-buffer Z unchanged. Needs DS_LIN17.
    parameter bit DS_LINZ = 1,
    // DS_YPERSP: along Y (edges) the linear mode needs w bits 0-5 clear and
    // the perspective factor uses the full w (hwref run 6: persp_y_w,
    // persp_eqw to 0 px; small open regressions in cap3d persp_30, depth_w)
    parameter bit DS_YPERSP = 1,
    // DS_XPERSP16: the X perspective factor uses w0 >> 8 and w1 >> 8 when
    // max(w0, w1) >= 0x8000, Z-buffered polygons only (hwref run 7: persp_xbig
    // 3,274 -> 0 px; run 20: with the W-buffer the DS keeps the full w,
    // wbuf_* ~4,000 -> 0/144 px, depth_wbuf 5 -> 0)
    parameter bit DS_XPERSP16 = 1,
    // DS_AACOV: X-major AA coverage start ((startx << 10) + 0x200) * ylen / xlen,
    // minus 1 in the numerator on Negative edges (hwref run 7: aa_xfan 65 ->
    // 4, aa_sliver 56 -> 0, aa_short 684 -> 43, aa 369 -> 177 px; the rest
    // are Y-major edges)
    parameter bit DS_AACOV = 1,
    // DS_AAYCOV: a Y-major edge pixel gets full coverage when the edge crosses
    // into the next pixel within the scanline, ((dx + inc - 1) >> 18) !=
    // (dx >> 18) (hwref run 7: 7,964 of 7,965 Y-major edge pixels, melonDS
    // 7,741)
    parameter bit DS_AAYCOV = 1,
    // DS_TEXRND: linear texcoords round with + 2^12 (along X) and + 2^13
    // (along Y, gpu3d_edge) before the >> 17; colours and Z don't (hwref run
    // 11: tex_exact/_y and run 10's subpix_step exact; with DS_LIN17 18,988
    // texel/colour samples miss 14, against 3,853 for DS_LIN17 alone and
    // 1,697 for melonDS's exact division)
    parameter bit DS_TEXRND = 1,
    // DS_ZFACE: with the Z-buffer, a front-facing pixel over an opaque
    // back-facing one passes up to 1 unit behind it, and a back-facing pixel
    // over an opaque front-facing one must be more than 1 unit in front;
    // W-buffer unchanged (hwref runs 14-17: zbuf_same 5,774 -> 0,
    // zbuf_back_front 6,945 -> 0; v12's zwin panels allow 1..4, not 0x200)
    parameter bit DS_ZFACE = 1,
    // DS_TEX4X4: texels of a 4x4-compressed block whose palette mode has bit
    // 14 set (modes 1 and 3, the blending modes) expand 5 -> 6 bits as c << 1
    // (no +1), all four indices; modes 0 and 2 and the other formats keep
    // (c << 1) + 1 for c != 0 (hwref run 16: MKDS replay 15,218 -> 4,245 px,
    // NSMB 7,765 -> 2,166, rand3d scenes)
    parameter bit DS_TEX4X4 = 1,
    // Fit-first feature switches (1 = full behaviour). A feature switched off
    // behaves as on a DS whose game has it disabled, never as garbage:
    //   FEAT_AA     DISP3DCNT bit 4 (anti-aliasing) reads 0: hard edges
    //   FEAT_EDGE   bit 5 (edge marking) reads 0: no outlines
    //   FEAT_FOG    bits 6-7 (fog) read 0: no fog
    //   FEAT_ATEST  the alpha-test reference reads 0 (only alpha 0 is dropped)
    //   FEAT_TOON   toon/highlight polygons (mode 2) draw as modulate
    //   FEAT_SHADOW shadow-mask and shadow polygons (mode 3) are skipped: no shadows
    //   FEAT_LOWER  no lower layer (the second line buffer): it reads as the
    //               clear entry and nothing is written to it, so AA edges,
    //               shadows and translucent edges blend and test against the
    //               clear plane (and through its alpha against the 2D layers)
    parameter bit FEAT_AA = 1,
    parameter bit FEAT_EDGE = 1,
    parameter bit FEAT_FOG = 1,
    parameter bit FEAT_ATEST = 1,
    parameter bit FEAT_TOON = 1,
    parameter bit FEAT_SHADOW = 1,
    parameter bit FEAT_LOWER = 1,
    // TXD: stages between the texture request (P15) and the texel's use
    // (P17) beyond the one there is (P16): up to TXD + 2 requests outstanding
    // before P17 waits, so a miss overlaps the pixels behind it. Timing only.
    // (At most 10: the late descriptor still reaches P17 from P14.)
    parameter int TXD = 0,
    // PXD: stages between the palette request (P17, out a clock later) and
    // the palette word's use (P19) beyond the one there is (P18): the palette
    // cache's hit latency is longer than that, so without them most paletted
    // pixels stall at P19 (wait19)
    parameter int PXD = 0,
    parameter bit FPSKIP = 0,     // gpu3d_fpass FPSKIP: the final pass skips the fog steps a frame does not use
    // TRU: a texture read whose halfword one of the last two reads fetched is
    // not made again: P15 keeps the last two addresses, P17 the last two
    // words (the same order), and each read slot of a pixel carries which
    // (a 4x4 texel's two reads repeat its neighbour's almost always)
    parameter bit TRU = 0,
    // LLR (with nds_g3d_ring LLR): a late line's top-layer slot can be read
    // out (ll_*: the ring copies it as drawn so far, the DS rule) - read
    // when the final pass does not read that slot, the pixel pipeline
    // holding at P20 if it reads it
    parameter bit LLR = 0,
    // TRUL (with TRU): one entry per read slot instead of the shared two
    // (slot A the texel word or the only read, slot B a 4x4's palette info),
    // a match being "the same halfword as this slot's last": the 4x4 case at
    // about half the logic (nds-fit #700: TRU 14 LABs)
    parameter bit TRUL = 0,
    parameter bit FPCLR = 0,      // gpu3d_fpass FPCLR: its clear waits for a free write clock from F_3 on
    // NXB: no next-span register (sd_nx): the walker loads the front's span
    // (fe_desc) when it takes it, and the front holds it until then. Pixels
    // unchanged; one span less buffered between front and walker.
    parameter bit NXB = 0,
    parameter bit VREG = 0,       // gpu3d_edge VREG: the vertex RAM's output registered (timing only)
    // LOV: line overlap. The front starts line y+1 once line y's spans are
    // handed over, while its pixels drain (two lines in the pipeline at most:
    // gpu3d_front starts y+2 only once y is final). A pixel's line slot is
    // the front's or the one before, by its line parity (lp, through u_dt20)
    parameter bit LOV = 0,
    parameter bit EDIV4 = 0,      // gpu3d_front EDIV4: the edge's perspective divider four bits a clock
    parameter bit EDGE2 = 0,      // gpu3d_front EDGE2: a second edge unit (a polygon's two edges at once)
    parameter bit EP2 = 0,        // gpu3d_front EP2: the edge unit as two stages (two edges at once)
    // LB2: the line buffers mostly in 512-deep RAMs of two slots ({0,1},
    // {2,3}) instead of four 256-deep ones: the same M10K, 2:1 read muxes
    // instead of 4:1 for 40 of the top layer's 71 bits and all of the lower
    // layer's (below, "LB2"). Pixels and cycles unchanged.
    parameter bit LB2 = 0,
    // DSHARE: one divider in gpu3d_front for the edge unit and the span stage's
    // AA coverage start (AREA's divider half without its half-rate pixels)
    parameter bit DSHARE = 0,
    // RMERGE: two pairs of the dly_wp delay rings share an M10K each (g_rmrg,
    // g_rmz; gpu3d_dring2): the same outputs, 2 M10K fewer (TXD > 0, AREA 0)
    parameter bit RMERGE = 1,
    // TOONR (with DS_TOON, DS_LIN17): the toon index on lane 0. On a
    // toon/highlight polygon the vertex red is never drawn (toon replaces the
    // colour, highlight takes the fill-less red), and the fill-less red is
    // interpolated by the colour lanes' own formula (Y: the edge items' factor;
    // X: (ad * f + base << 17) >> 17), so the edge units load red without the
    // 0xF fill and lane 0 carries it: no sixth attribute (edge item 7, the
    // span's talt/tbase/tad, p13_tv's multiply). docs/renderer-3d.md
    parameter bit TOONR = 1,
    // TR3 (needs FEAT_EDGE 0, not LB2): the line buffers in three slots
    // (line mod 3), not four. The fourth held the final pass's line above
    // for edge marking; without it the pass reads lines f, f+1 and the
    // pipeline renders f+2 at most (gpu3d_front starts y once fp_done >=
    // y-2), so line y reuses line y-3's slot, which the pass cleared behind
    // its reads. The pass's read of the line above meets the pipeline's
    // line there (its data is unused); nds_g3d_ring's LLR uses TR3 too
    parameter bit TR3 = 0
) (
    input  logic         clk,
    input  logic         rst,
    // latched render state (GPU3D::VBlank)
    input  logic [15:0]  dispcnt,
    input  logic [4:0]   alpharef,     // effective (0 when the alpha test is off)
    input  logic [31:0]  clear_attr1,
    input  logic [14:0]  clear_depth,
    input  logic [20:0]  fog_color,    // [14:0] colour, [20:16] alpha
    input  logic [14:0]  fog_offset,
    input  logic         tbl_we,
    input  logic [1:0]   tbl_sel,      // 0 toon, 1 edge colour, 2 fog density
    input  logic [4:0]   tbl_addr,
    input  logic [14:0]  tbl_data,
    input  logic         frame_start,
    output logic         busy,
    output logic         frame_done,
    input  logic         px_hold,      // the final pass may not write its line's pixels yet (3D ring staging)
    output logic [7:0]   fp_line,      // the final pass's line
    output logic         fp_act,       // ... a line of it in progress
    output logic [8:0]   r_go,         // lines started this frame (LLR: a slot holds the newest of them)
    input  logic         ll_rd,        // LLR: read slot ll_slot at ll_x
    input  logic [1:0]   ll_slot,
    input  logic [7:0]   ll_x,
    output logic         ll_ack,       // ... read now (ll_q next clock)
    output logic [22:0]  ll_q,
    // polygon stream, re-sent for every line
    output logic         ps_line_req,
    output logic [7:0]   ps_line_y,
    input  logic         ps_valid,
    output logic         ps_ready,
    input  logic [1:0]   ps_type,      // 0 header, 1 vertex, 3 end of line
    input  logic [127:0] ps_data,
    // texture and palette VRAM (16-bit word at addr & ~1, any latency)
    output logic         tex_req,
    output logic [18:0]  tex_addr,
    input  logic         tex_inval,    // TRU: texture memory written (the reuse history is dropped)
    input  logic         tex_valid,
    input  logic [15:0]  tex_data,
    output logic         pal_req,
    output logic [16:0]  pal_addr,
    input  logic         pal_valid,
    input  logic [15:0]  pal_data,
    // finished pixels, line by line
    output logic         px_valid,
    output logic [7:0]   px_x,
    output logic [7:0]   px_y,
    output logic [22:0]  px_color,
    // profiling (testbench only): 1 clear, 2 stream, 3 edge, 4 span, 5 pixel, 6 final pass
    output logic [2:0]   dbg_phase,
    output logic         dbg_span,
    output logic         dbg_pixel
);
    // the render state as the features see it (FEAT_*)
    wire [15:0] dcnt = dispcnt & ~{8'h00, !FEAT_FOG, !FEAT_FOG, !FEAT_EDGE, !FEAT_AA, 4'h0};
    wire [4:0]  aref = FEAT_ATEST ? alpharef : 5'd0;
    // NOBOT: no lower layer, no AA and no shadows: nothing the lower layer's
    // depth test decides is visible (P22 drops a lower-layer write, and with
    // AA off a pixel that passes only there changes nothing else either)
    localparam bit NOBOT = !FEAT_LOWER && !FEAT_AA && !FEAT_SHADOW;
    // NOEDGE: NOBOT, no edge marking and no fog: no one reads a line-buffer
    // entry's edge flags (attr 3-0; the final pass only for AA, edge marking
    // and fog, P21 only for the lower layer and shadows), so none are written
    localparam bit NOEDGE = NOBOT && !FEAT_EDGE && !FEAT_FOG;

    // Pipeline tags, declared before the line buffers use T20/T22 (Quartus
    // needs struct-typed signals declared before a member access).
    typedef struct packed {
        logic       lp;       // LOV: its line's parity (wk_tag and P20-P22 only)
        logic       v;        // stage holds a pixel
        logic       slot;     // its span descriptor
        logic       ghost;    // linear-path step only (no fetch, no write)
        logic       first;    // first pixel of the span (resets the steppers)
        logic       last;     // last pixel of the span (frees the slot)
        logic       covrst;   // first pixel of part 1 / part 3 (resets xcov)
        logic [1:0] part;
        logic [7:0] x;
        logic [9:0] ix;
    } ptag_t;
    ptag_t T0, T2, T10, T11, T12, T13, T15, T17, T19, T20, T21, T22, wk_tag;


    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    function automatic [5:0] exp5(input [4:0] c);  // 5-bit -> 6-bit colour
        exp5 = (c != 0) ? {c, 1'b1} : 6'd0;
    endfunction

    // the slot-1 palette-info address, 0x20000 + (a & 0x1FFFC) / 2 (+ 0x10000
    // from slot 2 on): no carries, wires of the texel address
    function automatic [18:0] s1addr(input [18:0] a);
        s1addr = {2'b01, a[18], a[16:2], 1'b0};
    endfunction
    function automatic [4:0] bitlen25(input [24:0] v);
        bitlen25 = 0;
        for (int i = 0; i < 25; i++) if (v[i]) bitlen25 = 5'(i + 1);
    endfunction

    // vertex record fields (ps_data, type 1)
    function automatic [8:0]  v_x(input [115:0] v); v_x = v[8:0];     endfunction
    function automatic [7:0]  v_y(input [115:0] v); v_y = v[16:9];    endfunction
    function automatic [23:0] v_z(input [115:0] v); v_z = v[40:17];   endfunction
    function automatic [15:0] v_w(input [115:0] v); v_w = v[56:41];   endfunction
    function automatic [8:0]  v_c(input [115:0] v, input [1:0] k);
        v_c = (k == 0) ? v[65:57] : (k == 1) ? v[74:66] : v[83:75];
    endfunction
    function automatic [15:0] v_s(input [115:0] v); v_s = v[99:84];   endfunction
    function automatic [15:0] v_t(input [115:0] v); v_t = v[115:100]; endfunction

    wire [23:0] clearz = {clear_depth, 9'h1FF};
    wire [5:0]  clear_pid = clear_attr1[29:24];

    // ------------------------------------------------------------------
    // line buffers
    // ------------------------------------------------------------------
    // Four lines in a ring, addressed {slot, x} (slot = line & 3): while
    // line y renders, the final pass of line y-2 reads lines y-3, y-2, y-1
    // and clears line y-3 for y+1. One copy per layer, a 256-deep RAM per
    // slot: the pipeline reads slot y & 3 and the final pass reads one of
    // the other three, so each slot RAM takes its read address from
    // the pipeline on slot y & 3 and from the final pass otherwise; a 4:1 mux returns each reader's data.
    localparam int LW = 71;   // {attr (packed) 24, depth 24, colour 23}
    logic          lbt_we, lbb_we;
    logic [9:0]    lbt_waddr, lbb_waddr;
    logic [LW-1:0] lbt_wdata, lbb_wdata;
    logic [9:0]    fpt_raddr, fpb_raddr;
    logic [LW-1:0] lt_top, lt_bot, fpt_q, fpb_q;
    logic [3:0][LW-1:0] lbt_q, lbb_q;
    logic [1:0]    pp_sl_q, fpt_sl_q, fpb_sl_q;    // slot of each reader, a cycle late
    always_ff @(posedge clk) begin
        pp_sl_q <= sl20; fpt_sl_q <= fpt_raddr[9:8]; fpb_sl_q <= fpb_raddr[9:8];
    end
    wire           pp_rd = T20.v;                  // the pipeline reads this cycle
    // the line slot of the P20 / P22 pixel (LOV: the front may be a line on)
    wire  [1:0]    s_prev = (TR3 && s_cur == 2'd0) ? 2'd2 : s_cur - 2'd1;
    wire  [1:0]    sl20 = (!LOV || T20.lp == y[0]) ? s_cur : s_prev;
    wire  [1:0]    sl22 = (!LOV || T22.lp == y[0]) ? s_cur : s_prev;
    genvar gv_g_lb;
    generate
    if (LB2) begin : g_lb2
    // LB2. While both run, the pipeline renders line f+2 when the final pass
    // is on line f (gpu3d_front starts line y once line y-3 is final), so
    // the final pass's own line (slot f & 3) is in the other group and only
    // its neighbour lines f-1, f+1 share the pipeline's group. Those reads
    // use the polygon ID and depth alone: with one more attribute bit (31
    // bits, a 256x40 M10K a slot) they stay in four slot RAMs; the other 40
    // top-layer bits, and all of the lower layer (the final pass reads only
    // line f there), are in the two group RAMs, the pipeline's group read
    // by the pipeline. A neighbour read gets the pipeline's data in those
    // bits, which the final pass masks off (M_NB). No read waits.
    function automatic [30:0] lb_a(input [LW-1:0] e); lb_a = {e[70:64], e[46:23]}; endfunction
    function automatic [39:0] lb_b(input [LW-1:0] e); lb_b = {e[63:47], e[22:0]}; endfunction
    function automatic [LW-1:0] lb_e(input [30:0] a, input [39:0] b);
        lb_e = {a[30:24], b[39:23], a[23:0], b[22:0]};
    endfunction
    logic [3:0][30:0] lta_q;
    logic [1:0][39:0] ltb_q;
    logic [1:0][LW-1:0] lbg_q;
    for (gv_g_lb = 0; gv_g_lb < 4; gv_g_lb = gv_g_lb + 1) begin : g_la
        gpu3d_ram #(.W(31), .AW(8)) u_top (
            .clk, .we(lbt_we && lbt_waddr[9:8] == 2'(gv_g_lb)), .waddr(lbt_waddr[7:0]), .wdata(lb_a(lbt_wdata)),
            .raddr(pp_rd && sl20 == 2'(gv_g_lb) ? T20.x : fpt_raddr[7:0]), .rdata(lta_q[gv_g_lb]));
    end
    for (gv_g_lb = 0; gv_g_lb < 2; gv_g_lb = gv_g_lb + 1) begin : g_lb
        gpu3d_ram #(.W(40), .AW(9)) u_top (
            .clk, .we(lbt_we && lbt_waddr[9] == 1'(gv_g_lb)), .waddr(lbt_waddr[8:0]), .wdata(lb_b(lbt_wdata)),
            .raddr(pp_rd && sl20[1] == 1'(gv_g_lb) ? {sl20[0], T20.x} : fpt_raddr[8:0]), .rdata(ltb_q[gv_g_lb]));
        if (FEAT_LOWER) begin : g_bot
            gpu3d_ram #(.W(LW), .AW(9)) u_bot (
                .clk, .we(lbb_we && lbb_waddr[9] == 1'(gv_g_lb)), .waddr(lbb_waddr[8:0]), .wdata(lbb_wdata),
                .raddr(pp_rd && sl20[1] == 1'(gv_g_lb) ? {sl20[0], T20.x} : fpb_raddr[8:0]), .rdata(lbg_q[gv_g_lb]));
        end
    end
    assign lt_top = lb_e(lta_q[pp_sl_q], ltb_q[pp_sl_q[1]]);
    assign fpt_q  = lb_e(lta_q[fpt_sl_q], ltb_q[fpt_sl_q[1]]);
    assign lt_bot = lbg_q[pp_sl_q[1]];
    assign fpb_q  = lbg_q[fpb_sl_q[1]];
    end else begin : g_lb4
    for (gv_g_lb = 0; gv_g_lb < (TR3 ? 3 : 4); gv_g_lb = gv_g_lb + 1) begin : g_lb
        gpu3d_ram #(.W(LW), .AW(8)) u_top (
            .clk, .we(lbt_we && lbt_waddr[9:8] == 2'(gv_g_lb)), .waddr(lbt_waddr[7:0]), .wdata(lbt_wdata),
            .raddr((ll_ack && ll_slot == 2'(gv_g_lb)) ? ll_x : pp_rd && sl20 == 2'(gv_g_lb) ? T20.x : fpt_raddr[7:0]),
            .rdata(lbt_q[gv_g_lb]));
        if (FEAT_LOWER) begin : g_bot
            gpu3d_ram #(.W(LW), .AW(8)) u_bot (
                .clk, .we(lbb_we && lbb_waddr[9:8] == 2'(gv_g_lb)), .waddr(lbb_waddr[7:0]), .wdata(lbb_wdata),
                .raddr(pp_rd && sl20 == 2'(gv_g_lb) ? T20.x : fpb_raddr[7:0]), .rdata(lbb_q[gv_g_lb]));
        end
    end
    if (TR3) begin : g_tr3
        assign lbt_q[3] = '0;                   // (no fourth slot)
        if (FEAT_LOWER) begin : g_b3 assign lbb_q[3] = '0; end
    end
    // LLR: the late-line read
    // (granted when the final pass does not read that slot now; LB2's grouped
    // RAMs are not covered: LLR needs the four slot RAMs)
    assign ll_ack = LLR && ll_rd && !(fp_act && fpt_raddr[9:8] == ll_slot);

    logic [1:0] ll_sl_q;
    always_ff @(posedge clk) ll_sl_q <= ll_slot;
    assign ll_q  = lbt_q[ll_sl_q][22:0];
    assign lt_top = lbt_q[pp_sl_q];
    assign lt_bot = lbb_q[pp_sl_q];
    assign fpt_q  = lbt_q[fpt_sl_q];
    assign fpb_q  = lbb_q[fpb_sl_q];
    end
    endgenerate

    // shadow stencil (StencilBuffer: two lines by y parity, 2 bits per pixel)
    logic        st_we;
    logic [8:0]  st_waddr;
    logic [1:0]  st_wdata, st_rdata;
    gpu3d_ram #(.W(2), .AW(9)) u_stencil (
        .clk, .we(st_we), .waddr(st_waddr), .wdata(st_wdata),
        .raddr({LOV ? T20.lp : y[0], T20.x}), .rdata(st_rdata));
    // line-buffer entry fields
    // The attribute keeps only the bits any write can set (0-4, 8-12, 15,
    // 16-22, 24-29), packed to 24.
    function automatic [23:0] a_pack(input [31:0] a);
        a_pack = {a[29:24], a[22:16], a[15], a[12:8], a[4:0]};
    endfunction
    function automatic [31:0] a_unpack(input [23:0] p);
        a_unpack = {2'b0, p[23:18], 1'b0, p[17:11], p[10], 2'b0, p[9:5], 3'b0, p[4:0]};
    endfunction
    function automatic [22:0] e_color(input [LW-1:0] e); e_color = e[22:0];  endfunction
    function automatic [23:0] e_depth(input [LW-1:0] e); e_depth = e[46:23]; endfunction
    function automatic [31:0] e_attr (input [LW-1:0] e); e_attr  = a_unpack(e[70:47]); endfunction
    function automatic [5:0]  e_pid  (input [LW-1:0] e); e_pid   = e[70:65]; endfunction


    // ------------------------------------------------------------------
    // line-buffer writes: the pixel pipeline (or a clear of lines 0-2) has
    // the write port; the final pass's clear of line fp_y-1 waits for a
    // cycle the pipeline does not write the top layer
    // ------------------------------------------------------------------
    logic        pxt_we, pxb_we;
    logic        fp_run, fp_clr_req;
    logic [9:0]  fp_clr_addr;
    logic [7:0]  fp_y, fp_done;
    wire         fp_clr_ack = fp_clr_req && !pxt_we && !clr_we;
    assign fp_line = fp_y;
    gpu3d_fpass #(.DS_AA0(DS_AA0), .FOG(FEAT_FOG), .FPSKIP(FPSKIP), .FPCLR(FPCLR), .TR3(TR3)) u_fpass (
        .clk, .rst, .dispcnt(dcnt), .clear_attr1, .clear_depth, .fog_color, .fog_offset,
        .tbl_we, .tbl_sel, .tbl_addr, .tbl_data, .frame_go, .lines_done,
        .top_raddr(fpt_raddr), .bot_raddr(fpb_raddr), .top_q(fpt_q), .bot_q(fpb_q),
        .fp_clr_req, .fp_clr_addr, .fp_clr_ack, .px_hold, .fp_act, .fp_y, .fp_done, .fp_run,
        .frame_done, .px_valid, .px_x, .px_y, .px_color);
`ifndef SYNTHESIS
    // synthesis translate_off
    // The final pass never reads the slot the pipeline reads in the same
    // cycle (the pipeline has that slot's read port then). Quartus does not
    // define SYNTHESIS and takes a hierarchical reference for a declaration.
    always_ff @(posedge clk)
        if (!rst && pp_rd && u_fpass.fst inside {u_fpass.F_0, u_fpass.F_2, u_fpass.F_3, u_fpass.F_3B} &&
            ((fpt_raddr[9:8] == sl20 && !(TR3 && u_fpass.fst == u_fpass.F_2)) || (u_fpass.fst == u_fpass.F_2 && fpb_raddr[9:8] == sl20)))
            $error("gpu3d_raster: line-buffer slot read by both the pipeline and the final pass");
    // LB2: the final pass's own line (top x = 0 and x+1, the lower layer) is
    // never in the group the pipeline reads
    always_ff @(posedge clk)
        if (LB2 && !rst && pp_rd && u_fpass.fst inside {u_fpass.F_0, u_fpass.F_2, u_fpass.F_3B} &&
            ((u_fpass.fst != u_fpass.F_2 && fpt_raddr[9] == sl20[1]) || (u_fpass.fst == u_fpass.F_2 && fpb_raddr[9] == sl20[1])))
            $error("gpu3d_raster: LB2 group read by both the pipeline and the final pass's own line");
    // synthesis translate_on
`endif
    logic [LW-1:0] pxt_wdata, pxb_wdata;
    wire  [LW-1:0] clear_entry = {a_pack(clear_attr1 & 32'h3F008000), clearz,
                                  clear_attr1[20:16], exp5(clear_attr1[14:10]),
                                  exp5(clear_attr1[9:5]), exp5(clear_attr1[4:0])};
    generate if (!FEAT_LOWER) begin : g_nobot
        assign lbb_q = {4{clear_entry}};        // FEAT_LOWER = 0: the lower layer is the clear plane
    end endgenerate
    always_comb begin
        lbt_we    = pxt_we || clr_we || fp_clr_ack;
        lbt_waddr = pxt_we ? {sl22, T22.x} : clr_we ? {s_cur, clr_x[7:0]} : fp_clr_addr;
        lbt_wdata = pxt_we ? pxt_wdata : clear_entry;
        lbb_we    = pxb_we;
        lbb_waddr = {sl22, T22.x};
        lbb_wdata = pxb_wdata;
    end

    assign tex_req = pp_tex_req; assign tex_addr = pp_tex_addr;
    assign pal_req = pp_pal_req; assign pal_addr = pp_pal_addr;

    gpu3d_front #(.AREA(AREA || DSHARE), .RECIP(RECIP), .DS_TOON(DS_TOON), .DS_LIN17(DS_LIN17), .DS_LINZ(DS_LINZ),
                  .DS_YPERSP(DS_YPERSP), .DS_XPERSP16(DS_XPERSP16), .DS_AACOV(DS_AACOV), .DS_AAYCOV(DS_AAYCOV), .DS_TEXRND(DS_TEXRND),
                  .FEAT_TOON(FEAT_TOON), .FEAT_SHADOW(FEAT_SHADOW), .VREG(VREG), .LOV(LOV), .EDIV4(EDIV4), .EDGE2(EDGE2), .EP2(EP2), .TOONR(TR)) u_front (
        .clk, .rst, .dispcnt(dcnt), .fill_all(dispcnt[4] || dispcnt[5]), .alpharef(aref), .frame_start,
        .ps_line_req, .ps_line_y, .ps_valid, .ps_ready, .ps_type, .ps_data,
        .fe_desc, .fe_wr, .nx_full(nx_hold), .pipe_idle, .pipe_lp,
        .y, .y3, .clr_x, .clr_we, .st_clr, .lines_done, .lines_go(r_go), .frame_go, .fp_done, .fp_run,
        .busy, .dbg_phase, .dbg_span);

    // ==================================================================
    // pixel pipeline: one pixel per clock (docs/renderer-3d.md, v1)
    // ==================================================================
    // The span setup above hands each span over as a descriptor (two slots,
    // double-buffered). A walker issues the span's pixels in order; every
    // pixel carries its slot, so pixels of two spans can be in flight.
    //   P0      walker output (x, part)
    //   P1-P2   perspective numerator / denominator (Interpolator::SetX)
    //   P3-P11  perspective factor, one restoring divider stage each
    //   P12-P13 Z and the five attributes (products, or the linear steppers)
    //   P14     toon lookup, texture address
    //   P15     texture request(s)        P17  texel decode, palette request(s)
    //   P19     palette data -> texel     P20  shading, line-buffer/stencil read
    //   P21     depth test, alpha test, shadow stencil
    //   P22     plot (write)
    // P0-P20 advance together (adv); P21-P22 always drain. P20 holds while a
    // pixel of the same x is in P21/P22 (only the next span can collide).
    typedef gpu3d_pkg::span_t span_t;


    // The span stage writes the next span to sd_nx. The walker takes it into
    // sd_cur, which P0-P13 read (one span at a time there: a new span starts
    // once P0-P13 hold no pixel of the last one). When the span's first
    // pixel enters P14 it is copied to sd_late, which P15-P22 read: the last
    // span's pixels are then at least 14 stages ahead, past P22.
    span_t      sd_nx, sd_cur, sd_late, sd_late2, fe_desc;   // sd_late2: TXD, below
    logic [7:0] y, lines_done;
    logic [8:0] clr_x;
    logic       clr_we, st_clr, frame_go;
    logic [1:0] y3;                   // y mod 3, counted by gpu3d_front
    wire  [1:0] s_cur = TR3 ? y3 : y[1:0];      // ring slot of the line being rendered
    logic       nx_full;              // sd_nx holds a span not yet walked (NXB: 0)
    logic       nx_hold;              // the front must hold its span
    logic       fe_wr;
    logic       pipe_any;             // some stage holds a pixel
    wire        pipe_idle = !nx_full && !wk_act && !pipe_any;
    // LOV: the pipeline's spans and pixels by line parity: pixels counted in
    // at P0 and out at P22, plus the walker's and the next span
    // (a count is at most the stages a pixel can be in, P0-P22 and the TXD /
    // PXD stages: LPW bits)
    localparam int LPW = $clog2(23 + TXD + PXD + 1);
    logic [LPW-1:0] lp_n [0:1];
    logic [1:0] pipe_lp;
    always_ff @(posedge clk)
        for (int b = 0; b < 2; b++)
            if (rst || !LOV) lp_n[b] <= '0;
            else lp_n[b] <= lp_n[b] + LPW'(wk_emit && wk_tag.lp == 1'(b)) - LPW'(T22.v && T22.lp == 1'(b));
`ifndef SYNTHESIS
    always_ff @(posedge clk)
        if (!rst && LOV && 32'(lp_n[0]) + 32'(lp_n[1]) > 23 + TXD + PXD) $error("gpu3d_raster: lp_n above the pipeline's stages");
`endif
    always_comb
        for (int b = 0; b < 2; b++)
            pipe_lp[b] = lp_n[b] != '0 || (wk_act && sd_cur.lp == 1'(b)) || (!NXB && nx_full && sd_nx.lp == 1'(b));

    function automatic [31:0] s_polyattr(input span_t d);
        s_polyattr = (d.attr & 32'h3F008000) | {27'b0, ~d.facing, 4'b0};
    endfunction
    function automatic s_mask(input span_t d);
        s_mask = FEAT_SHADOW && (d.attr & 32'h3F000030) == 32'h00000030;
    endfunction
    function automatic s_textured(input span_t d);
        s_textured = dcnt[0] && d.texparam[28:26] != 0;
    endfunction

    // tags as plain vectors (Yosys mishandles arrays of structs); T<n> is
    // the struct view of stage n
    localparam int TGW = 27;          // $bits(ptag_t)
    localparam int TV = 25;           // ptag_t bit v
`ifndef SYNTHESIS
    initial if ($bits(ptag_t) != TGW) $error("gpu3d_raster: TGW");
    initial if (DS_TOON && !RECIP) $error("gpu3d_raster: DS_TOON needs RECIP (the linear toon factor)");
    initial if (TR3 && (FEAT_EDGE || LB2)) $error("gpu3d_raster: TR3 needs FEAT_EDGE 0 and the four slot RAMs' layout (not LB2)");
    initial if (DS_HILITE && !DS_TOON) $error("gpu3d_raster: DS_HILITE needs DS_TOON (the fill-less red)");
    initial if (DS_LIN17 && !RECIP) $error("gpu3d_raster: DS_LIN17 needs RECIP (ceil(2^37/xdiff))");
    initial if (DS_LINZ && !DS_LIN17) $error("gpu3d_raster: DS_LINZ needs DS_LIN17 (the factor)");
`endif
    logic [TGW-1:0] tg [0:22];
    logic         adv;
    // TXD: the P16 pixel through TXD more stages. P17-P20 read only v and
    // ghost of their tags (x, part, covrst come from u_dt20) and P17 first
    // (sd_late2): those three in registers, the texel fields in u_dx
    localparam int XN = TXD > 0 ? TXD : 1;
    logic [3*XN-1:0] txd_tag;         // {v, ghost, first} per stage, the last stage on top
    logic [TGW-1:0] tg16x;            // tg[16] with only those
    wire  [TGW-1:0] tg16o = TXD > 0 ? tg16x : tg[16];
`ifndef SYNTHESIS
    initial if (TXD > 10) $error("gpu3d_raster: TXD > 10 (the late descriptor's P14 -> P17 copy)");
    initial if (TXD + PXD > 10) $error("gpu3d_raster: TXD + PXD > 10 (the delay rings' depth)");
    initial if (PXD > 0 && TXD == 0) $error("gpu3d_raster: PXD needs TXD (the 32-deep delay rings)");
    initial if (LLR && LB2) $error("gpu3d_raster: LLR needs the four slot RAMs (LB2 0)");
`endif
    // Delay lines in MLAB for values that only pass through stages: a ring
    // written on every adv at dly_wp, so the copy in stage k (written k
    // advs ago) is at dly_wp - (k+1) - the same as a chain of registers
    // enabled by adv. The tag's x, part and covrst are read from P20 on and
    // ix only at P0 and P10 (the divider's last stage: tg[6] with AREA,
    // where P7-P10 are gone and P20 is 16 advs from P0), so the other tags
    // keep just v, ghost and first.
    logic [4:0]  dly_wp;
    logic [11:0] dt_x20;              // {lp (LOV), covrst, part, x} of the P20 pixel
    logic [9:0]  dt_ix10;             // ix of the P10 pixel (registered: the ring is read for P9)
    logic [9:0]  dt_ix9;
    // the rings are M10Ks with a registered read (gpu3d_dring: the same
    // values as the MLAB rings they were, ~1 LAB per 20 bits); dly_en is
    // the clocks dly_wp moves on
    wire         dly_en = adv && !rst;
    gpu3d_dring #(.W(12), .AW(5), .D((AREA ? 17 : 21) + TXD + PXD), .K(2)) u_dt20 (
        .clk, .we(adv), .en(dly_en), .wp(dly_wp), .wdata({LOV && wk_tag.lp, wk_tag.covrst, wk_tag.part, wk_tag.x}),
        .rdata(dt_x20));
    // RMERGE: u_dt10 shares an M10K with u_dz (g_rmz)
    localparam bit RM = RMERGE && TXD > 0 && !AREA;
    logic [23:0] p13_z, p20_z;
    generate if (RM) begin : g_rmz
        gpu3d_dring2 #(.W0(10), .D0(10), .W1(24), .D1(7 + TXD + PXD), .C(9), .AW(5)) u_dtz (
            .clk, .we(adv), .en(dly_en), .wp(dly_wp), .wdata0(wk_tag.ix), .wdata1(p13_z),
            .rdata0(dt_ix9), .rdata1(p20_z));
    end else begin : g_t10
        gpu3d_dring #(.W(10), .AW(5), .D(AREA ? 6 : 10), .K(1)) u_dt10 (
            .clk, .we(adv), .en(dly_en), .wp(dly_wp), .wdata(wk_tag.ix), .rdata(dt_ix9));
    end endgenerate
    // register the ring's output with the stage, so P11's factor multiply
    // starts from a register (nds-fit #245)
    always_ff @(posedge clk) if (adv) dt_ix10 <= dt_ix9;
    logic [TGW-1:0] tg20f, tg10f;     // tg[20], tg[10] with those fields from the rings
    // (bit slices of ptag_t: {covrst, part, x} = [20:10], ix = [9:0]; a
    // struct-typed local here made Yosys drop everything after P20)
    wire [TGW-1:0] tg_dl = AREA ? tg[6] : tg[10];    // the last divider stage
    assign tg20f = {dt_x20[11], tg[20][TGW-2:21], dt_x20[10:0], tg[20][9:0]};
    assign tg10f = {tg_dl[TGW-1:10], dt_ix10};
`ifndef SYNTHESIS
    initial begin
        ptag_t t;
        t = '0; t.covrst = 1'b1; if (TGW'(t) != TGW'(1) << 20) $error("gpu3d_raster: ptag_t layout");
        t = '0; t.v = 1'b1; t.ghost = 1'b1; t.first = 1'b1;   // TXD's tg16x
        if (TGW'(t) != TGW'({1'b1, 1'b0, 1'b1, 1'b1, 22'd0})) $error("gpu3d_raster: ptag_t layout");
        t = '0; t.ix = 10'h3FF;  if (TGW'(t) != TGW'(10'h3FF)) $error("gpu3d_raster: ptag_t layout");
    end
`endif
    assign T0 = tg[0];   assign T2 = tg[2];   assign T10 = tg10f; assign T11 = tg[11];
    assign T12 = tg[12]; assign T13 = tg[13]; assign T15 = tg[15]; assign T17 = tg[17];
    assign T19 = tg[19]; assign T20 = tg20f;  assign T21 = tg[21]; assign T22 = tg[22];

    // ---------------- walker ----------------
    logic        wk_act, wk_first;
    logic [1:0]  wk_k;
    logic signed [11:0] wk_x;
    span_t       wd;
    assign wd = sd_cur;
    logic        early_busy;          // P0-P13 hold a pixel
    always_comb begin
        early_busy = 1'b0;
        for (int i = 0; i <= 13; i++) if (!AREA || i < 7 || i > 10) early_busy |= tg[i][TV];
        pipe_any = 1'b0;
        for (int i = 0; i <= 22; i++) if (!AREA || i < 7 || i > 10) pipe_any |= tg[i][TV];
        if (TXD > 0) for (int i = 0; i < XN; i++) pipe_any |= txd_tag[3*i+2];
        if (PXD > 0) for (int i = 0; i < PN; i++) pipe_any |= pxd_tag[3*i+2];
    end
    function automatic seg_ne(input span_t d, input [1:0] k);   // segment k (1-3) has pixels
        seg_ne = d.en[k - 2'd1] && d.sb[k - 2'd1] < d.se[k - 2'd1];
    endfunction
    logic        wk_emit, wk_ghost, wk_last;
    logic [3:2]  wk_ne;               // seg_ne(sd_cur, 2 / 3), taken with sd_cur from nx_k's compares
    logic [1:0]  wk_nk;               // next nonempty segment after wk_k (0: none)
    always_comb begin
        logic signed [11:0] sbk, sek;
        sbk = wd.sb[wk_k - 2'd1]; sek = wd.se[wk_k - 2'd1];
        // only linear spans start before a segment, and only without DS_LIN17:
        // with it every segment is walked from its sb (the load and the step
        // to the next segment), so wk_x >= sb and no pixel is a ghost
        wk_ghost = !DS_LIN17 && wk_x < sbk;
        wk_nk = 2'd0;
        if (wk_k == 2'd1 && wk_ne[2]) wk_nk = 2'd2;
        else if (wk_k != 2'd3 && wk_ne[3]) wk_nk = 2'd3;
        wk_emit = wk_act && adv;
        wk_last = !wk_ghost && wk_x + 12'sd1 >= sek && wk_nk == 2'd0;
    end
    assign dbg_pixel = wk_emit && !wk_ghost;
    always_comb begin
        wk_tag = '0;
        wk_tag.v = wk_act;
        wk_tag.lp = wd.lp;
        wk_tag.ghost = wk_ghost;
        wk_tag.first = wk_first;
        wk_tag.last = wk_last;
        // (P22 reads covrst only for the AA coverage, part also for the edge
        // flags: constant without them)
        wk_tag.covrst = FEAT_AA && !wk_ghost && wk_x == wd.sb[wk_k - 2'd1] && wk_k != 2'd2;
        wk_tag.part = (FEAT_AA || !NOEDGE) ? wk_k : 2'd0;
        wk_tag.x = wk_x[7:0];
        wk_tag.ix = 10'(wk_x - wd.xs);
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk)
        if (!rst && DS_LIN17 && wk_act && wk_x < wd.sb[wk_k - 2'd1]) $error("gpu3d_raster: DS_LIN17 walker left of its segment (a ghost pixel)");
    // build_ds.sh drops the hold check sd_nx -> sd_cur: sd_nx is never written
    // in a clock where the walker may load sd_cur from it
    always_ff @(posedge clk)
        if (!rst && fe_wr && nx_full && !NXB) $error("gpu3d_raster: sd_nx written while full (the sd_nx -> sd_cur hold exception)");
`endif
    // the span the walker loads next: sd_nx, or (NXB) the front's, taken as
    // fe_wr; its first nonempty segment (0: nothing to draw)
    span_t      nx_d;
    assign nx_d = NXB ? fe_desc : sd_nx;
    wire  [1:0] nx_k = seg_ne(nx_d, 2'd1) ? 2'd1 : seg_ne(nx_d, 2'd2) ? 2'd2 : seg_ne(nx_d, 2'd3) ? 2'd3 : 2'd0;
    assign nx_hold = NXB ? !(!wk_act && (nx_k == 2'd0 || !early_busy)) : nx_full;
    // The span's attribute bases and linear steps (abase, aqs: 160 bits, read
    // from P10 on) are not in sd_cur but in g_dram's word, written at the load
    // with sd_cur; a load waits for P0-P13 to empty, so P10 first reads them
    // 11 clocks after it (AREA lets P7-P10 run on: sd_cur's)
    logic        sd_load;
    assign sd_load = !rst && !wk_act && (NXB ? fe_wr : nx_full) && nx_k != 2'd0 && !early_busy;
    // MLOAD (DS_LIN17, not AREA): the P12 lanes' span operands p12_ma (ad) and
    // p12_mc (abase << 17 and the rounding) are loaded with the span instead
    // of copied from it at every advance: the load waits for P0-P13 to empty,
    // so no P12 pixel of the last span is left, and the new span's pixels
    // reach P12 twelve or more advances later. sd_cur.ad and the word's
    // abase are then not needed (with DS_LIN17 the lanes are their only
    // readers).
    localparam bit MLOAD = !AREA && DS_LIN17;
    localparam int DW = MLOAD ? 80 : 160;
    logic [4:0][15:0] sd_abase, sd_aqs;
    logic [DW-1:0]    sd_dq;
    generate if (!AREA) begin : g_dram
        gpu3d_dword #(.W(DW)) u_dram (.clk, .we(sd_load), .wd(DW'({nx_d.abase, nx_d.aqs})), .q(sd_dq));
        assign sd_aqs = sd_dq[79:0];
        assign sd_abase = MLOAD ? '0 : 80'(sd_dq >> 80);
    end else begin : g_dflop
        assign sd_abase = sd_cur.abase; assign sd_aqs = sd_cur.aqs;
    end endgenerate
    always_ff @(posedge clk) begin
        if (rst) begin
            wk_act <= 1'b0; nx_full <= 1'b0;
        end else begin
            if (fe_wr && !NXB) begin sd_nx <= fe_desc; nx_full <= 1'b1; end
            if (!wk_act && (NXB ? fe_wr : nx_full)) begin
                // load: first nonempty segment; a linear span walks from xs so
                // its steppers start at ix = 0
                if (nx_k == 2'd0) nx_full <= 1'b0;       // nothing to draw
                else if (!early_busy) begin
                    nx_full <= 1'b0;
                    sd_cur <= nx_d;
                    wk_ne <= {seg_ne(nx_d, 2'd3), seg_ne(nx_d, 2'd2)};
                    wk_act <= 1'b1;
                    wk_k <= nx_k;
                    wk_x <= (nx_d.lin && !DS_LIN17) ? nx_d.xs : nx_d.sb[nx_k - 2'd1];
                    wk_first <= 1'b1;
                end
            end else if (wk_emit) begin
                wk_first <= 1'b0;
                wk_x <= wk_x + 12'sd1;
                if (!wk_ghost && wk_x + 12'sd1 >= wd.se[wk_k - 2'd1]) begin
                    if (wk_nk == 2'd0) wk_act <= 1'b0;
                    else begin
                        wk_k <= wk_nk;
                        if (!wd.lin || DS_LIN17) wk_x <= wd.sb[wk_nk - 2'd1];
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    // build_ds.sh times sd_cur -> p12_ma / p12_mc as a two-cycle path: a P11
    // pixel's operands are taken from an sd_cur unchanged for two cycles
    span_t      sdc_q;
    logic [1:0] sdc_age = 2'd0;
    always_ff @(posedge clk) begin
        sdc_q <= sd_cur;
        sdc_age <= (sd_cur != sdc_q) ? 2'd0 : (sdc_age == 2'd3 ? 2'd3 : sdc_age + 2'd1);
        if (!rst && adv && T11.v && (sd_cur != sdc_q || sdc_age < 2'd1))
            $error("gpu3d_raster: the span descriptor changed under a P11 pixel (the sd_cur -> P12 multicycle)");
    end
    // the same for g_dram's word (abase/aqs), which changes with sd_cur
    logic [159:0] sdd_q;
    logic [1:0]   sdd_age = 2'd0;
    always_ff @(posedge clk) begin
        sdd_q <= {sd_abase, sd_aqs};
        sdd_age <= ({sd_abase, sd_aqs} != sdd_q) ? 2'd0 : (sdd_age == 2'd3 ? 2'd3 : sdd_age + 2'd1);
        if (!rst && adv && T11.v && ({sd_abase, sd_aqs} != sdd_q || sdd_age < 2'd1))
            $error("gpu3d_raster: abase/aqs changed under a P11 pixel (the g_dram -> P12 multicycle)");
    end
`endif
    // ---------------- per-stage data ----------------
    logic [25:0] p1_m1;
    // the denominator x*w0 + (xdiff-x)*w1 is one sum-of-two multiply in P2
    // (w0, w1 from the descriptor); its zero tests come from the operands
    logic [9:0]  p1_ix, p1_xr;
    logic        p1_z1, p1_z2;        // x*w0 = 0, (xdiff-x)*w1 = 0
    logic [31:0] p2_num;
    logic [24:0] p2_den;
    logic        p2_den0, p2_256;
    // P3..P10: restoring division, 8 quotient bits; P11 holds it. With AREA
    // the pipeline advances at most every other cycle and the divider is
    // P3..P6, two bits per stage: one step as the pixel enters (from the
    // stage before), one in place in the cycle between advs (pd_h: done),
    // on one subtractor per stage.
    localparam int DVL = AREA ? 6 : 10;   // the divider's last stage
    logic [24:0] pd_rem [3:10];
    logic [24:0] pd_den [3:10];
    logic [6:0]  pd_nl  [3:10];
    logic [7:0]  pd_q   [3:11];
    logic        pd_z   [3:11];       // denominator 0: factor 0
    logic        pd_256 [3:11];       // factor exactly 256
    logic        pd_h   [3:6];
    generate
    if (AREA) begin : g_dfold
    always_ff @(posedge clk) begin
        for (int i = 3; i <= 6; i++) begin
            logic [24:0] rem, den;
            logic [6:0]  nl;
            logic [7:0]  q;
            logic        b;
            logic [25:0] sh, t;
            if (!adv)        begin rem = pd_rem[i]; b = pd_nl[i][6]; nl = {pd_nl[i][5:0], 1'b0}; q = pd_q[i]; den = pd_den[i]; end
            else if (i == 3) begin rem = {1'b0, p2_num[31:8]}; b = p2_num[7]; nl = p2_num[6:0]; q = 8'd0; den = p2_den; end
            else begin rem = pd_rem[i - 1]; b = pd_nl[i - 1][6]; nl = {pd_nl[i - 1][5:0], 1'b0}; q = pd_q[i - 1]; den = pd_den[i - 1]; end
            sh = {rem, b};
            t  = sh - {1'b0, den};
            if (adv || !pd_h[i]) begin
                pd_rem[i] <= t[25] ? sh[24:0] : t[24:0];
                pd_q[i]   <= {q[6:0], ~t[25]};
                pd_nl[i]  <= nl;
                pd_h[i]   <= !adv;
            end
            if (adv) begin
                pd_den[i] <= den;
                pd_z[i]   <= (i == 3) ? p2_den0 : pd_z[i - 1];
                pd_256[i] <= (i == 3) ? p2_256 : pd_256[i - 1];
            end
        end
    end
    end else if (RECIP) begin : g_drec
    // RECIP: the factor by reciprocal. q = floor(256 * m1 / den) with
    // m1 = num >> 8 < den, so q < 256 (256 and den = 0 are flagged):
    // P3 leading zeros of den; P4 m1 and den normalised by multiplies by
    // 2^lz; P5 table read; P6 q0 = (mn * R) >> 26 (q or q - 1); P7 q0 * dn;
    // P8 q = q0 + (256 * mn - q0 * dn >= dn); P9, P10 carry q.
    logic [4:0]  r3_lz;
    logic [23:0] r3_m1;
    logic [24:0] r3_den, r4_mn, r4_dn, r5_mn, r5_dn, r6_mn, r7_dn;
    // kept a fabric register: packed into the q0 * dn multiplier's input
    // register it took r5_dn across the DSP's clock skew (nds-fit #502: hold
    // -0.003 ns, skew 0.534 ns over a 0.531 ns copy); the DSP reads it as an
    // input instead, and its own product register holds r7_p
    (* preserve *) logic [24:0] r6_dn;
    logic [24:0] r7_mn;
    logic [9:0]  r6_q0, r7_q0;
    logic [34:0] r7_p;
    logic [10:0] fr_q;
    // (the read is registered: P4's denominator on an advance, P5's while
    // the pipeline holds, so fr_q always belongs to the P5 pixel)
    // the hold address is its own copy of r5_dn[23:14], so r5_dn need not sit
    // by the table (nds-fit #492: r5_dn -> r6_dn at -0.019 ns)
    (* preserve *) logic [9:0] r5_dna;
    gpu3d_frecip u_frecip (.clk, .addr(adv ? r4_dn[23:14] : r5_dna), .q(fr_q));
    always_ff @(posedge clk) if (adv) begin
        logic [4:0]  lz;
        logic signed [35:0] rem;
        lz = 5'd24;
        for (int i = 0; i < 25; i++) if (p2_den[i]) lz = 5'(24 - i);
        r3_lz <= lz; r3_m1 <= p2_num[31:8]; r3_den <= p2_den;
        r4_mn <= 25'(50'(r3_m1) * 50'(25'd1 << r3_lz));
        r4_dn <= 25'(50'(r3_den) * 50'(25'd1 << r3_lz));
        r5_mn <= r4_mn; r5_dn <= r4_dn; r5_dna <= r4_dn[23:14];
        r6_q0 <= 10'((36'(r5_mn) * 36'(fr_q)) >> 26); r6_mn <= r5_mn; r6_dn <= r5_dn;
        r7_p  <= 35'(r6_q0 * r6_dn); r7_q0 <= r6_q0; r7_mn <= r6_mn; r7_dn <= r6_dn;
        rem = $signed({3'b0, r7_mn, 8'b0}) - $signed({1'b0, r7_p});
        pd_q[8] <= 8'(r7_q0 + 10'(rem >= $signed({11'b0, r7_dn})));
        pd_q[9] <= pd_q[8]; pd_q[10] <= pd_q[9];
        pd_z[3] <= p2_den0; pd_256[3] <= p2_256;
        for (int i = 4; i <= 10; i++) begin pd_z[i] <= pd_z[i - 1]; pd_256[i] <= pd_256[i - 1]; end
    end
    end else begin : g_dfull
    always_ff @(posedge clk) if (adv) begin
        logic [25:0] sh, t;
        sh = {1'b0, p2_num[31:7]};
        t  = sh - {1'b0, p2_den};
        pd_rem[3] <= t[25] ? sh[24:0] : t[24:0];
        pd_q[3]   <= {7'b0, ~t[25]};
        pd_nl[3]  <= p2_num[6:0];
        pd_den[3] <= p2_den;
        pd_z[3]   <= p2_den0;
        pd_256[3] <= p2_256;
        for (int i = 4; i <= 10; i++) begin
            sh = {pd_rem[i - 1], pd_nl[i - 1][6]};
            t  = sh - {1'b0, pd_den[i - 1]};
            pd_rem[i] <= t[25] ? sh[24:0] : t[24:0];
            pd_q[i]   <= {pd_q[i - 1][6:0], ~t[25]};
            pd_nl[i]  <= {pd_nl[i - 1][5:0], 1'b0};
            pd_den[i] <= pd_den[i - 1];
            pd_z[i]   <= pd_z[i - 1];
            pd_256[i] <= pd_256[i - 1];
        end
    end
    end
    endgenerate
    logic [24:0] p11_zp;              // (dz >> 9) * factor, Z-buffer path
    logic [8:0]  p12_yf;
    logic [4:0][33:0] p12_ap;         // ad * factor (DS_LIN17: 17-bit factors on linear spans)
    logic [26:0] p12_tp;              // DS_TOON: tad * factor
    logic [16:0] p11_lf, p11_lfn;     // DS_LIN17: f = floor((ix << 17) / xdiff) of the P11 pixel, 2^17 - f (mod 2^17)
    logic        p11_lf0;             // ... f = 0 (2^17 - f is then 2^17: the whole difference)
    logic [4:0]  p12_full;            // DS_LIN17: lane k takes its whole difference (descending, f = 0)
    // DS_LIN17: lane k as one multiply-add (a DSP's 18x18 plus 36 mode, its
    // input registers and output register): p13_av = (ad * fk + c) >> 17 with
    // fk = f, 2^17 - f (to 2^17) on linear spans and (yf or 256 - yf) << 9
    // otherwise, c = abase << 17 plus the DS_TEXRND 2^12 on s, t. Equal to
    // abase + (ap >> 8 | ap >> 17 | ad) + cy: abase << 17 has no low bits, and
    // the 2^12 carries into bit 17 exactly when ap[16:12] are all set.
    logic [4:0][16:0] p12_ma;
    logic [4:0][17:0] p12_mf;
    logic [4:0][32:0] p12_mc;
    logic [9:0]  p12_ta;              // DS_TOON: the same for the fill-less red, (tad * ft + (tbase << 17)) >> 17
    logic [17:0] p12_tf;
    logic [8:0]  p12_tc;
    logic        p12_tfull, p12_zfull;
    logic [8:0]  p13_tv;              // DS_TOON: the fill-less red (the toon index << 4)
    localparam bit TR = TOONR && DS_TOON && DS_LIN17;
    logic [8:0]  tv13;                // ... as read (TOONR: lane 0)
    logic [47:0] p12_zm;
    logic [4:0][15:0] p12_lq;         // linear stepper quotient
    logic [4:0]  p12_lr;              // ... remainder != 0
    logic [4:0][15:0] lst_q;           // stepper state
    logic [4:0][9:0]  lst_r;
    logic        lin_hold;            // LINSER: P11 holds while its lanes are stepped
    logic [4:0][15:0] p13_av;
    assign tv13 = TR ? p13_av[0][8:0] : p13_tv;
    // P14 onward
    // Z (P13 -> P20), vertex colour {b,g,r} (P13 -> P19) and toon colour
    // (P14 -> P19) only pass through: delay lines on dly_wp
    logic [17:0] p19_sv, p20_sv;
    logic [5:0]  p19_tr6;             // DS_HILITE: the fill-less red >> 3 of the P19 pixel
    logic [14:0] p14_toon, p19_toon;
    localparam int DA = TXD > 0 ? 5 : 3;          // their depth (log2)
    // (p20_z goes into p21_z: K 1; the P19 values feed logic: K 2)
    // RMERGE (TXD > 0): u_dsv + u_dtoon in one M10K word (read at wp - (3 +
    // TXD + PXD): u_dtoon K 2 as before, u_dsv one register more), and u_dz
    // with u_dt10 (read at wp - 9: u_dt10 K 1 as before, u_dz 4 registers
    // more); gpu3d_dring2, the same outputs as the single rings
    // (TOONR: the fill-less red is lane 0's colour: 18 bits, p19_tr6 from p19_sv)
    localparam int SVW = TR ? 18 : 24;
    wire  [SVW-1:0] dsv_wd = SVW'({p13_tv[8:3], p13_av[2][8:3], p13_av[1][8:3], p13_av[0][8:3]});
    logic [SVW-1:0] dsv_q;
    assign p19_sv  = dsv_q[17:0];
    assign p19_tr6 = TR ? dsv_q[5:0] : dsv_q[SVW-1 -: 6];
    generate if (RM) begin : g_rmrg
        gpu3d_dring2 #(.W0(15), .D0(5 + TXD + PXD), .W1(SVW), .D1(6 + TXD + PXD), .C(3 + TXD + PXD), .AW(DA)) u_dst (
            .clk, .we(adv), .en(dly_en), .wp(dly_wp[DA-1:0]), .wdata0(p14_toon), .wdata1(dsv_wd),
            .rdata0(p19_toon), .rdata1(dsv_q));
    end else begin : g_rsep
        gpu3d_dring #(.W(24), .AW(DA), .D(7 + TXD + PXD), .K(1)) u_dz (
            .clk, .we(adv), .en(dly_en), .wp(dly_wp[DA-1:0]), .wdata(p13_z), .rdata(p20_z));
        gpu3d_dring #(.W(SVW), .AW(DA), .D(6 + TXD + PXD), .K(2)) u_dsv (
            .clk, .we(adv), .en(dly_en), .wp(dly_wp[DA-1:0]), .wdata(dsv_wd), .rdata(dsv_q));
        gpu3d_dring #(.W(15), .AW(DA), .D(5 + TXD + PXD), .K(2)) u_dtoon (
            .clk, .we(adv), .en(dly_en), .wp(dly_wp[DA-1:0]), .wdata(p14_toon), .rdata(p19_toon));
    end endgenerate
    // toon table: a RAM read for the pixel entering P14, its output is
    // p14_toon (the address is held while the pipeline stalls)
    logic [4:0]  p14_toon_a;
    gpu3d_ram #(.W(15), .AW(5), .STYLE("MLAB")) u_toon (
        .clk, .we(tbl_we && tbl_sel == 2'd0), .waddr(tbl_addr), .wdata(tbl_data),
        .raddr(adv ? (DS_TOON ? tv13[8:4] : p13_av[0][8:4]) : p14_toon_a), .rdata(p14_toon));
    logic [18:0] p15_ta;                      // texel address
    wire  [18:0] p15_s1 = s1addr(p15_ta);     // 4x4 slot-1 palette-info address
    wire         p15_slot1 = p15_ta[18:17] == 2'b01;   // the texel address is in slot 1
    logic        p16_slot1, p17_slot1;
    logic        p16_b1, p17_b1;              // texel address bit 0 (byte select)
    logic [1:0]  p15_ss, p16_ss, p17_ss;      // s & 3 (sub-byte texel select)
    logic        p15_sent, p17_sent;
    logic [1:0]  p15_ntex, p16_ntex, p17_ntex; // texture reads
    logic        p15_tex;                      // (p14_tex a stage on: p15_ntex from P15's registers)
    logic [3:0]  p16_cd, p17_cd;               // TRU: per read slot (A, B) 0 read, 1/2 the last / the one before
    logic [9:0]  p16x;                         // {b1, slot1, ss, ntex, cd} TXD advs ago
    wire  [9:0]  p16o = TXD > 0 ? p16x : {p16_b1, p16_slot1, p16_ss, p16_ntex, p16_cd};   // what P17 takes
    // (unused at TXD 0: synthesis drops it)
    // u_dx and u_dp (below) in one M10K when TXD = PXD (written on the same
    // advances, read as far back): their outputs go into the P17, P19 registers
    wire  [9:0]  p16xw = {p16_b1, p16_slot1, p16_ss, p16_ntex, p16_cd};
    generate if (TXD != PXD) begin : g_dx
        gpu3d_dring #(.W(10), .AW(5), .D(TXD), .K(1)) u_dx (
            .clk, .we(adv), .en(dly_en), .wp(dly_wp), .wdata(p16xw), .rdata(p16x));
    end endgenerate
    // ptag_t bits: v 25, ghost 23, first 22 (the layout check above);
    // {v, ghost, first} go in at the bottom of txd_tag with each adv
    wire  [2:0]  t16_vgf = {tg[16][25], tg[16][23], tg[16][22]};
    generate if (TXD > 1) begin : g_txd_n
        always_ff @(posedge clk)
            if (rst) txd_tag <= '0;
            else if (adv) txd_tag <= {txd_tag[3*XN-4:0], t16_vgf};
    end else if (TXD == 1) begin : g_txd_1
        always_ff @(posedge clk)
            if (rst) txd_tag <= '0;
            else if (adv) txd_tag <= t16_vgf;
    end else begin : g_txd_0
        assign txd_tag = '0;
    end endgenerate
    assign tg16x = {1'b0, txd_tag[3*XN-1], 1'b0, txd_tag[3*XN-2], txd_tag[3*XN-3], 22'd0};
    logic [1:0]  p18_npal, p19_npal;          // palette reads
    logic [16:0] p18_pa0, p18_pa1;
    logic [1:0]  p18_mix, p19_mix;            // 1: (c0+c1)/2, 2: 5:3, 3: 3:5
    logic        p18_c4, p19_c4;              // DS_TEX4X4: a 4x4 block in palette mode 1 or 3
    logic [15:0] p18_tc, p19_tc;              // texel colour when no palette read
    logic [4:0]  p18_ta, p19_ta;              // texel alpha
    // PXD: the P18 fields and {v, ghost, first} through PXD more stages
    localparam int PN = PXD > 0 ? PXD : 1;
    logic [3*PN-1:0] pxd_tag;
    logic [25:0] p18x;                        // {npal, mix, c4, tc, ta} PXD advs ago
    wire  [25:0] p18xw = {p18_npal, p18_mix, p18_c4, p18_tc, p18_ta};
    generate if (TXD != PXD) begin : g_dp
        gpu3d_dring #(.W(26), .AW(5), .D(PXD), .K(1)) u_dp (
            .clk, .we(adv), .en(dly_en), .wp(dly_wp), .wdata(p18xw), .rdata(p18x));
    end else begin : g_dxp
        gpu3d_dring #(.W(36), .AW(5), .D(PXD), .K(1)) u_dxp (
            .clk, .we(adv), .en(dly_en), .wp(dly_wp), .wdata({p16xw, p18xw}), .rdata({p16x, p18x}));
    end endgenerate
    wire  [2:0]  t18_vgf = {tg[18][25], tg[18][23], tg[18][22]};
    generate if (PXD > 1) begin : g_pxd_n
        always_ff @(posedge clk)
            if (rst) pxd_tag <= '0;
            else if (adv) pxd_tag <= {pxd_tag[3*PN-4:0], t18_vgf};
    end else if (PXD == 1) begin : g_pxd_1
        always_ff @(posedge clk)
            if (rst) pxd_tag <= '0;
            else if (adv) pxd_tag <= t18_vgf;
    end else begin : g_pxd_0
        assign pxd_tag = '0;
    end endgenerate
    wire  [TGW-1:0] tg18x = {1'b0, pxd_tag[3*PN-1], 1'b0, pxd_tag[3*PN-2], pxd_tag[3*PN-3], 22'd0};
    logic [4:0]  p20_tal;
    logic [17:0] p20_hl, p20_tt;              // toon colour and texel, 6 bits per channel
    logic [31:0] p20_slx, p20_slf;            // shading lane operands, 4 x 8 bits
    logic [3:0][11:0] p20_slc;                // ... and addends: decal v * 31, modulate -1 (one multiply-add a lane)
    logic [22:0] p21_sh, p22_sh;              // shaded pixel {a, b, g, r}
    logic [23:0] p21_z, p22_z;
    logic        p22_kill, p22_bot;
    logic [31:0] p22_dattr;                   // dstattr as melonDS holds it at plot time
    logic [LW-1:0] p22_top, p22_lo;           // line-buffer entries read at x
    logic [10:0] xcov;                // bit 10: past 32 x 32 (the coverage saturated; xcov only grows)

    // descriptor of the pixel in stage N
    span_t d0, d10, d11, d12, d13, d15, d17, d20, d21, d22;
    assign d0  = sd_cur;
    assign d10 = sd_cur;
    assign d11 = sd_cur;
    assign d12 = sd_cur;
    assign d13 = sd_cur;
    // TXD: P17-P22 read sd_late2, which the span's first pixel brings from
    // sd_late into P17 (sd_late is still that span's: the next one reaches
    // P14 at least 14 stages after it)
    assign d15 = sd_late;
    assign d17 = TXD > 0 ? sd_late2 : sd_late;
    assign d20 = TXD > 0 ? sd_late2 : sd_late;
    assign d21 = TXD > 0 ? sd_late2 : sd_late;
    assign d22 = TXD > 0 ? sd_late2 : sd_late;

    // Linear spans: y0 + d*ix/xdiff, stepped (quotient and remainder of
    // d*ix/xdiff per attribute). LINSER = 0: all five attributes at once in
    // P11 -> P12 (p12_lq, p12_lr). LINSER = 1: one stepper, one attribute
    // per cycle while the pixel waits in P11 (six cycles per linear pixel;
    // the front-bound frames have the pixel pipeline idle); the offset
    // (alt ? q : ad - q - (r != 0)) is formed there too, so p12_lq holds it.
    // The results wait in ls_off for the advance: p12_* still belong to the
    // P12 pixel until then.
    logic [3:0]  ls_k;                // LINSER / RECIP: attribute being stepped
    logic [12:0] ls_tf;               // DS_TOON: (ix << 12) / xdiff of a linear toon pixel
    logic [8:0]  ls_toff;             // ... and the fill-less red's offset
    logic [4:0][15:0] ls_off;         // ... and the offsets so far
    logic [9:0]  p11_ix, p12_ix;      // RECIP: ix of the P11 / P12 pixel
    generate
    if (DS_LIN17) begin : g_l17
        assign lin_hold = 1'b0;       // linear spans go through the product lanes
    end else if (RECIP) begin : g_lrec
        // RECIP: while a linear pixel waits in P12, lane ls_k forms ad * f
        // (cycles 0-4) and, a cycle later, (ad * f * R) >> 37 into
        // ls_off[ls_k - 1], which P13 reads; P12 holds for seven cycles.
        // DS_TOON toon spans: cycle 5 forms ix << 12, cycle 6 the factor
        // (ix << 12) / xdiff = (ix * 2^12 * R) >> 37 (exact, ix * 2^12 < 2^22),
        // cycle 7 the fill-less red's offset; nine cycles. Ghost pixels need
        // no offsets.
        logic [26:0] lr_m;
        wire  [37:0] lr_r = 38'(sd_aqs);
        wire ls_on = T12.v && !T12.ghost && d12.lin;
        wire [3:0] ls_n = (DS_TOON && d12.toon) ? 4'd8 : 4'd6;
        assign lin_hold = ls_on && ls_k < ls_n;
        always_ff @(posedge clk) begin
            logic [16:0] ad;
            logic [9:0]  f;
            logic        al;
            ad = '0; al = 1'b0;
            for (int j = 0; j < 5; j++) if (ls_k == 4'(j)) begin ad = d12.ad[j]; al = d12.alt[j]; end
            f = al ? p12_ix : 10'(d12.xdiff - p12_ix);
            lr_m <= (ls_k == 4'd5) ? 27'({p12_ix, 12'b0}) : 27'(ad * f);
            if (ls_on && ls_k != 4'd0 && ls_k < 4'd6)
                for (int j = 0; j < 5; j++) if (ls_k == 4'(j + 1))
                    ls_off[j] <= 16'((65'(lr_m) * 65'(lr_r)) >> 37);
            if (ls_on && ls_k == 4'd6) ls_tf <= 13'((65'(lr_m) * 65'(lr_r)) >> 37);
            if (ls_on && ls_k == 4'd7)
                ls_toff <= 9'((22'(d12.tad) * 22'(d12.talt ? ls_tf : 13'd4096 - ls_tf)) >> 12);
            if (adv) ls_k <= 4'd0;
            else if (ls_on && ls_k < ls_n) ls_k <= ls_k + 4'd1;
        end
    end else if (LINSER) begin : g_lser
        wire ls_on = T11.v && d11.lin;
        assign lin_hold = ls_on && ls_k < 3'd5;
        always_ff @(posedge clk) begin
            logic [15:0] q, aq, off;
            logic [9:0]  r, ar;
            logic [16:0] ad;
            logic        al, c;
            logic [10:0] rn;
            q = '0; r = '0; aq = '0; ar = '0; ad = '0; al = 1'b0;
            for (int j = 0; j < 5; j++) if (ls_k == 3'(j)) begin
                q = lst_q[j]; r = lst_r[j]; aq = sd_aqs[j]; ar = d11.ars[j]; ad = d11.ad[j]; al = d11.alt[j];
            end
            if (T11.first) begin q = '0; r = '0; end
            off = al ? q : 16'(ad) - q - 16'(r != 0);
            rn = {1'b0, r} + {1'b0, ar};
            c  = rn >= {1'b0, d11.xdiff};
            if (ls_on && ls_k < 3'd5)
                for (int j = 0; j < 5; j++) if (ls_k == 3'(j)) begin
                    lst_r[j]  <= c ? 10'(rn - {1'b0, d11.xdiff}) : rn[9:0];
                    lst_q[j]  <= q + aq + 16'(c);
                    ls_off[j] <= off;
                end
            if (adv) ls_k <= 3'd0;
            else if (ls_on && ls_k < 3'd5) ls_k <= ls_k + 3'd1;
            if (adv && ls_on) p12_lq <= ls_off;
        end
    end else begin : g_lpar
        assign lin_hold = 1'b0;
        always_ff @(posedge clk) if (adv && T11.v && d11.lin) begin
            for (int k = 0; k < 5; k++) begin
                logic [15:0] q;
                logic [9:0]  r;
                logic [10:0] rn;
                logic        c;
                q = T11.first ? 16'd0 : lst_q[k];
                r = T11.first ? 10'd0 : lst_r[k];
                p12_lq[k] <= q;
                p12_lr[k] <= r != 0;
                rn = {1'b0, r} + {1'b0, d11.ars[k]};
                c  = rn >= {1'b0, d11.xdiff};
                lst_r[k] <= c ? 10'(rn - {1'b0, d11.xdiff}) : rn[9:0];
                lst_q[k] <= q + sd_aqs[k] + 16'(c);
            end
        end
    end
    endgenerate

    // ---------------- texture / palette response FIFOs ----------------
    // Requests go out in order; responses are queued (any latency) and
    // consumed in order by P17 (texture) and P19 (palette).
    // (8 entries each in MLAB, the head read combinationally)
    // log2 entries: up to 2 (TXD + 3) answers wait with TXD (8 without)
    localparam int QA = TXD == 0 ? 3 : 2 * (TXD + PXD + 3) <= 16 ? 4 : 5;
    localparam int QN = QA + 1;
    logic [QA-1:0] tq_rd, tq_wr, pq_rd, pq_wr;
    logic [QA:0]   tq_n, pq_n;
    logic       tq_pop, pq_pop;
    logic [15:0] tq_h0, pq_h0;
    wire        fq_rst = rst || frame_go;
    gpu3d_lram #(.W(16), .AW(QA)) u_tq (
        .clk, .we(tex_valid && !fq_rst), .waddr(tq_wr), .wdata(tex_data), .raddr(tq_rd), .rdata(tq_h0));
    gpu3d_lram #(.W(16), .AW(QA)) u_pq (
        .clk, .we(pal_valid && !fq_rst), .waddr(pq_wr), .wdata(pal_data), .raddr(pq_rd), .rdata(pq_h0));
    // a pixel that needs two entries takes the first one a cycle early
    logic        p17_w0v, p19_w0v;    // first entry held
    logic [15:0] p17_w0, p19_w0;
    always_ff @(posedge clk) begin
        if (rst || (frame_go)) begin
            tq_rd <= '0; tq_wr <= '0; tq_n <= '0;
            pq_rd <= '0; pq_wr <= '0; pq_n <= '0;
        end else begin
            if (tex_valid) tq_wr <= tq_wr + 1'b1;
            if (pal_valid) pq_wr <= pq_wr + 1'b1;
            tq_rd <= tq_rd + QA'(tq_pop);
            pq_rd <= pq_rd + QA'(pq_pop);
            tq_n <= tq_n + QN'(tex_valid) - QN'(tq_pop);
            pq_n <= pq_n + QN'(pal_valid) - QN'(pq_pop);
`ifndef SYNTHESIS
            if (tq_n + QN'(tex_valid) > QN'(1 << QA) || pq_n + QN'(pal_valid) > QN'(1 << QA)) $error("gpu3d_raster: response FIFO overflow");
`endif
        end
    end

    // ---------------- TextureLookup: wrap/clamp into P14, address into P15 ----------------
    logic [18:0] tx_a;
    logic        tx_slot1;
    logic [9:0]  tx_sw, tx_tw;
    logic [9:0]  p14_sw, p14_tw;
    logic        p14_tex;                 // the pixel reads texture
    always_comb begin
        logic signed [11:0] s, t;
        logic [10:0] wd_, ht;
        logic [2:0]  szs, szt;
        logic [31:0] tp;
        tp = d13.texparam;
        szs = tp[22:20]; szt = tp[25:23];
        wd_ = 11'd8 << szs; ht = 11'd8 << szt;
        s = 12'($signed(p13_av[3]) >>> 4);
        t = 12'($signed(p13_av[4]) >>> 4);
        // repeat: s mod size; flip (mirrored odd repeat): size - 1 - (s mod
        // size), which is ~s mod size (size a power of two)
        if (tp[16]) tx_sw = 10'(((tp[18] && (s & 12'(wd_)) != 0) ? ~s : s) & 12'(wd_ - 1));
        else tx_sw = (s < 0) ? 10'd0 : (s >= $signed({1'b0, wd_})) ? 10'(wd_ - 1) : 10'(s);
        if (tp[17]) tx_tw = 10'(((tp[19] && (t & 12'(ht)) != 0) ? ~t : t) & 12'(ht - 1));
        else tx_tw = (t < 0) ? 10'd0 : (t >= $signed({1'b0, ht})) ? 10'(ht - 1) : 10'(t);
    end
    always_comb begin
        logic [2:0]  szs;
        logic [19:0] off;
        logic [18:0] base, sc;
        logic        f5;
        logic [31:0] tp;
        tp = d15.texparam;                // the late descriptor is the P14 pixel's
        szs = tp[22:20];
        base = {tp[15:0], 3'b0};
        // one row and one base adder for every format: 4x4 adds
        // (t & ~3) << (szs + 1) and (s & ~3) | (t & 3) (its low bits are clear).
        // The row term's low szs + 3 bits are clear and the column term is
        // below 8 << szs (s < width), so the row "adder" is an OR.
        f5   = tp[28:26] == 3'd5;
        off  = (20'(f5 ? p14_tw & 10'h3FC : p14_tw) << (f5 ? 4'(szs) + 4'd1 : 4'(szs) + 4'd3))
             | 20'(f5 ? {p14_sw[9:2], p14_tw[1:0]} : p14_sw);
        case (tp[28:26])
            3'd2:    sc = 19'(off >> 2);
            3'd3:    sc = 19'(off >> 1);
            3'd7:    sc = 19'(off << 1);
            default: sc = 19'(off);
        endcase
        tx_a = base + sc;
        tx_slot1  = tx_a[18:17] == 2'b01;
    end

    // ---------------- P17: texel decode, palette addresses ----------------
    // (texture-read part of TextureLookup; P19 finishes with the palette)
    logic [1:0]  tx_npal, tx_mix;
    logic        tx_c4;
    logic [16:0] tx_pa0, tx_pa1;
    logic [15:0] tx_tc;
    logic [4:0]  tx_ta;
    // One adder for the palette address: base + a per-format offset. The
    // palette base (texpal << 4) has its low 4 bits clear and 4x4 adds
    // info << 2, so pb + 2 is a bit set and pb + 4 / pb + 6 increment info.
    always_comb begin
        logic [15:0] w, info;
        logic [7:0]  byt, px8, val;
        logic [4:0]  a0;
        logic [16:0] pbase, off;
        logic [1:0]  md, k;
        logic [31:0] tp;
        tp = d17.texparam;
        pbase = (tp[28:26] == 3'd2) ? {1'b0, d17.texpal, 3'b0} : {d17.texpal, 4'b0};
        w = TRU ? t17_wa : (p17_ntex == 2'd2) ? p17_w0 : tq_h0;   // 4x4: the texel word came first
        byt = p17_b1 ? w[15:8] : w[7:0];
        a0 = tp[29] ? 5'd0 : 5'd31;
        tx_npal = 2'd1; tx_mix = 2'd0; tx_tc = '0; tx_ta = 5'd31; tx_c4 = 1'b0;
        px8 = '0; val = '0; info = '0; md = '0; k = 2'd0; off = '0;
        case (tp[28:26])
            3'd7: begin tx_tc = w; tx_ta = w[15] ? 5'd31 : 5'd0; tx_npal = 2'd0; end
            3'd5: begin
                // compressed: texel word then palette-info word (slot 1 alone
                // when the texel address is itself in slot 1); colour k of the
                // block's palette at pb + 2k, pb = base + (info << 2)
                info = TRU ? ((p17_ntex == 2'd2) ? t17_wb : t17_wa) : tq_h0;
                val  = p17_slot1 ? 8'd0 : (byt >> (2 * p17_ss));
                md   = info[15:14];
                tx_c4 = DS_TEX4X4 && md[0];
                case (val[1:0])
                    2'd0: ;
                    2'd1: k = 2'd1;
                    2'd2: begin
                        if (md == 2'd1 || md == 2'd3) begin
                            tx_npal = 2'd2; tx_mix = (md == 2'd1) ? 2'd1 : 2'd2;
                        end else k = 2'd2;
                    end
                    default: begin
                        if (md == 2'd2) k = 2'd3;
                        else if (md == 2'd3) begin tx_npal = 2'd2; tx_mix = 2'd3; end
                        else begin tx_npal = 2'd0; tx_tc = 16'd0; tx_ta = 5'd0; end
                    end
                endcase
                // + k[1] at bit 2 is the adder's carry in (below)
                off = {1'b0, info[13:0], k[0], 1'b0};
            end
            3'd1: begin
                tx_ta = 5'({byt[7:5], 2'b0} + {3'b0, byt[7:6]});
                off   = {11'b0, byt[4:0], 1'b0};
            end
            3'd2: begin
                px8 = (byt >> {p17_ss, 1'b0}) & 8'h3;
                tx_ta = (px8 == 0) ? a0 : 5'd31;
                off   = {14'b0, px8[1:0], 1'b0};
            end
            3'd3: begin
                px8 = p17_ss[0] ? {4'b0, byt[7:4]} : {4'b0, byt[3:0]};
                tx_ta = (px8 == 0) ? a0 : 5'd31;
                off   = {12'b0, px8[3:0], 1'b0};
            end
            3'd4: begin
                tx_ta = (byt == 0) ? a0 : 5'd31;
                off   = {8'b0, byt, 1'b0};
            end
            default: begin // 6: A5I3
                tx_ta = byt[7:3];
                off   = {13'b0, byt[2:0], 1'b0};
            end
        endcase
        // (pbase's low three bits are clear: bits 1-0 are off's alone.) 4x4's
        // info + k[1] wraps at 14 bits: then bit 16 is flipped back.
        tx_pa0 = {15'(pbase[16:2] + off[16:2] + 15'(tp[28:26] == 3'd5 && k[1])), off[1:0]};
        tx_pa0[16] = tx_pa0[16] ^ (tp[28:26] == 3'd5 && k[1] && &info[13:0]);
        tx_pa1 = {tx_pa0[16:2], 2'b10};           // pb + 2 (two-colour 4x4 modes, k = 0)
    end

    // ---------------- P19: texel colour from the palette ----------------
    logic [15:0] tx_col;
    always_comb begin
        logic [4:0] c0, c1, a;
        logic [5:0] s;
        logic [6:0] u;
        logic [7:0] t;
        tx_col = (p19_npal == 2'd0) ? p19_tc : pq_h0;
        // (c0 + c1) / 2, (5 c0 + 3 c1) / 8 (mix 2), (3 c0 + 5 c1) / 8:
        // with s = c0 + c1 and a the colour weighted 5, 5a + 3b = s + 2 (s + a)
        for (int c = 0; c < 3; c++) begin
            c0 = p19_w0[c*5 +: 5]; c1 = pq_h0[c*5 +: 5];
            a = (p19_mix == 2'd2) ? c0 : c1;
            s = {1'b0, c0} + {1'b0, c1};
            u = {1'b0, s} + {2'b0, a};
            t = {2'b0, s} + {u, 1'b0};
            if (p19_npal == 2'd2) tx_col[c*5 +: 5] = (p19_mix == 2'd1) ? s[5:1] : t[7:3];
        end
        if (p19_npal == 2'd2) tx_col[15] = 1'b0;
    end

    // ---------------- P20: RenderPixel ----------------
    // Every DS blend is (x*f + y*(2^k - f)) >> k = y + (((x - y) * f) >>> k)
    // (exact: y * 2^k is a multiple of 2^k), or a single product (modulate,
    // decal), on lanes of signed 8 x unsigned 8.
    function automatic [5:0] lerp6(input [5:0] base, input [16:0] p, input [3:0] k);
        lerp6 = 6'($signed({1'b0, base}) + ($signed(p) >>> k));
    endfunction
    logic [3:0][7:0]  sl_x, sl_f;     // shading lanes
    logic [3:0][16:0] sl_p;
    // the addend as a second product (c * sl_k, sl_k a kept register at 1), so the lane is one DSP in
    // "sum of two 18x18" mode with no adder in logic (#886: each lane an "independent 9x9" block, + c in ALMs)
    (* preserve *) logic [1:0] sl_k = 2'd1;
    always_ff @(posedge clk) sl_k <= 2'd1;
    genvar gv_g_slane;
    generate
    for (gv_g_slane = 0; gv_g_slane < 4; gv_g_slane = gv_g_slane + 1) begin : g_slane
        assign sl_p[gv_g_slane] = 17'($signed(sl_x[gv_g_slane]) * $signed({1'b0, sl_f[gv_g_slane]})
                                      + $signed(p20_slc[gv_g_slane]) * $signed({1'b0, sl_k}));
    end
    endgenerate
    // operands: vertex colour after toon/highlight, texel
    logic [5:0] sv_r, sv_g, sv_b, tt_r, tt_g, tt_b, sh_hr, sh_hg, sh_hb;
    logic [4:0] palpha, talpha;
    logic [1:0] blend;
    always_comb begin
        blend = d20.attr[5:4];
        palpha = d20.attr[20:16];
        talpha = p20_tal;
        // vertex colour after toon/highlight and the texel, selected in P19
        sv_r = p20_sv[5:0]; sv_g = p20_sv[11:6]; sv_b = p20_sv[17:12];
        sh_hr = p20_hl[5:0]; sh_hg = p20_hl[11:6]; sh_hb = p20_hl[17:12];
        tt_r = p20_tt[5:0]; tt_g = p20_tt[11:6]; tt_b = p20_tt[17:12];
        sl_x = p20_slx; sl_f = p20_slf;   // computed in P19
    end
    logic [22:0] rp_col;
    always_comb begin
        logic [5:0]  rp_r, rp_g, rp_b;
        logic [4:0]  rp_a;
        logic [6:0]  sr, sg, sb;
        logic [10:0] dr, dg, db;
        logic [16:0] mr, mg, mb, ma;
        sr = '0; sg = '0; sb = '0;
        // the lanes add their P19 addends: modulate (t+1)*(v+1) - 1, decal
        // (t*ta + v*(31-ta)) = v*31 + (t-v)*ta (mod 2^11, bits 10:5 used)
        mr = sl_p[0]; mg = sl_p[1]; mb = sl_p[2]; ma = sl_p[3];
        dr = sl_p[0][10:0]; dg = sl_p[1][10:0]; db = sl_p[2][10:0];
        if (s_textured(d20)) begin
            if (blend[0]) begin
                if (talpha == 0)       begin rp_r = sv_r; rp_g = sv_g; rp_b = sv_b; end
                else if (talpha == 31) begin rp_r = tt_r; rp_g = tt_g; rp_b = tt_b; end
                else begin rp_r = dr[10:5]; rp_g = dg[10:5]; rp_b = db[10:5]; end
                rp_a = palpha;
            end else begin
                // modulate: ((t+1)*(v+1)-1) >> 6, alpha ((ta+1)*(pa+1)-1) >> 5
                rp_r = mr[11:6]; rp_g = mg[11:6]; rp_b = mb[11:6]; rp_a = ma[9:5];
            end
        end else begin
            rp_r = sv_r; rp_g = sv_g; rp_b = sv_b; rp_a = palpha;
        end
        if (FEAT_TOON && blend == 2 && dcnt[1]) begin
            sr = rp_r + sh_hr; sg = rp_g + sh_hg; sb = rp_b + sh_hb;
            rp_r = sr[6] ? 6'd63 : sr[5:0];
            rp_g = sg[6] ? 6'd63 : sg[5:0];
            rp_b = sb[6] ? 6'd63 : sb[5:0];
        end
        if (palpha == 0) rp_a = 5'd31;   // wireframe
        rp_col = {rp_a, rp_b, rp_g, rp_r};
    end

    // ---------------- P21: depth test, shadow stencil ----------------
    logic        dt_pass, dt_bot;
    logic [31:0] dt_attr;
    logic [1:0]  dt_sv;               // mask: new stencil value
    // depth test (DepthTest_* in GPU3D_Soft.cpp).
    // One comparison per layer (one subtract gives the equal window, < and
    // <=); the destination attribute only picks <= or < (bits 4 and 22), so
    // the shadow's cleared edge bits never change it.
    function automatic [4:0] dcmp(input [23:0] dstz, input [23:0] z, input wbuf);
        // {z < dstz - 1, z <= dstz + 1, equal window, z <= dstz, z < dstz}
        logic signed [25:0] diff;
        diff = $signed({2'b0, dstz}) - $signed({2'b0, z});
        // |diff| <= 255 (W-buffer) or <= 512 (Z), from the high bits
        dcmp[2] = wbuf ? (diff[25:8] == 0 || (&diff[25:8] && diff[7:0] != 0))
                       : ((diff[25:10] == 0 && (!diff[9] || diff[8:0] == 0)) || &diff[25:9]);
        dcmp[1] = !diff[25];
        dcmp[0] = !diff[25] && diff != 0;
        dcmp[3] = !diff[25] || &diff;                 // DS_ZFACE: diff >= -1
        dcmp[4] = !diff[25] && diff[25:1] != 0;       //           diff > 1
    endfunction
    function automatic dsel(input [4:0] c, input [31:0] dstattr, input eq, input facing, input wbuf);
        if (eq) dsel = c[2];
        else if (facing && (dstattr & 32'h00400010) == 32'h00000010) dsel = (DS_ZFACE && !wbuf) ? c[3] : c[1];
        else if (DS_ZFACE && !wbuf && !facing && (dstattr & 32'h00400010) == 32'h00000000) dsel = c[4];
        else dsel = c[0];
    endfunction
    always_comb begin
        logic [31:0] ta, ba;
        logic eq, b0, wb, fc;
        logic [4:0] ct, cb;
        logic t_top, t_bot_ta, t_bot_ba;
        ta = e_attr(lt_top); ba = e_attr(lt_bot);
        eq = d21.attr[14]; wb = d21.wbuf; fc = d21.facing;
        ct = dcmp(e_depth(lt_top), p21_z, wb);
        cb = dcmp(e_depth(lt_bot), p21_z, wb);
        t_top    = dsel(ct, ta, eq, fc, wb);
        // NOBOT: a pass on the lower layer only writes the lower layer (gone),
        // steps the AA coverage (no AA) or feeds the shadow stencil (no
        // shadows), so it is taken as a fail: no lower-layer depth test
        t_bot_ta = !NOBOT && dsel(cb, ta, eq, fc, wb);
        t_bot_ba = !NOBOT && dsel(cb, ba, eq, fc, wb);
        // mask: stencil bit 0 = top fails, bit 1 = lower fails under an edge
        dt_sv = st_rdata;
        if (!t_top) dt_sv = 2'd1;
        if (ta[3:0] != 0 && !t_bot_ba) dt_sv = dt_sv | 2'd2;
        // shadows: stencil bit 0 picks the layer, bit 1 keeps the edge flags;
        // the attribute tested stays the top one even on the lower layer
        b0 = 1'b0;
        if (FEAT_SHADOW && d21.attr[5:4] == 2'd3 && !s_mask(d21)) begin
            b0 = !st_rdata[0];
            if (!st_rdata[1]) ta[3:0] = 4'd0;
        end
        dt_pass = 1'b0; dt_bot = b0; dt_attr = ta;
        if (FEAT_SHADOW && d21.attr[5:4] == 2'd3 && !s_mask(d21) && st_rdata == 0) dt_pass = 1'b0;
        else if (b0 ? t_bot_ta : t_top) dt_pass = 1'b1;
        else if (ta[3:0] != 0 && !b0 && t_bot_ba) begin   // (FEAT_LOWER = 0: still steps the coverage; the write is dropped)
            dt_pass = 1'b1; dt_bot = 1'b1; dt_attr = ba;
        end
    end

    // ---------------- P22: AlphaBlend + PlotTranslucentPixel, writes ----------------
    logic [2:0][7:0]  plt_x, plb_x;   // plot lanes, top and lower layer
    logic [7:0]       pl_f;
    logic [2:0][16:0] plt_p, plb_p;
    genvar gv_g_plane;
    generate
    for (gv_g_plane = 0; gv_g_plane < 3; gv_g_plane = gv_g_plane + 1) begin : g_plane
        assign plt_p[gv_g_plane] = 17'($signed(plt_x[gv_g_plane]) * $signed({1'b0, pl_f}));
        assign plb_p[gv_g_plane] = 17'($signed(plb_x[gv_g_plane]) * $signed({1'b0, pl_f}));
    end
    endgenerate
    function automatic [LW:0] plot(input [LW-1:0] dst, input [2:0][16:0] p, input span_t d,
                                   input [22:0] sh, input [23:0] z);
        // {we, entry}
        logic [31:0] da, na, pa;
        logic [4:0]  sa, dal;
        logic [22:0] col;
        logic        shadow;
        pa = s_polyattr(d);
        shadow = FEAT_SHADOW && d.attr[5:4] == 2'd3 && !s_mask(d);
        da = e_attr(dst);
        na = (pa & 32'hE0F0) | ((pa >> 8) & 32'hFF0000) | 32'h400000 | (da & (NOEDGE ? 32'hFF001F00 : 32'hFF001F0F));
        if (!da[15]) na[15] = 1'b0;
        sa = sh[22:18]; dal = dst[22:18];
        if (dal == 0) col = sh;
        else if (dcnt[3])
            col = {(sa > dal) ? sa : dal, lerp6(dst[17:12], p[2], 5),
                   lerp6(dst[11:6], p[1], 5), lerp6(dst[5:0], p[0], 5)};
        else col = {(sa > dal) ? sa : dal, sh[17:0]};
        plot[LW] = !(shadow && !da[22] ? (da & 32'h3F000000) == (pa & 32'h3F000000)
                                       : (da & 32'h7F0000) == (na & 32'h7F0000));
        plot[LW-1:0] = {a_pack(na), d.attr[11] ? z : e_depth(dst), col};
    endfunction

    logic        w_top, w_bot;
    logic [LW-1:0] w_topd, w_botd;
    logic [10:0] w_xcov;              // xcov after this pixel
    always_comb begin
        logic [31:0] attr;
        logic [3:0]  edge_f;
        logic        aa_here, opaque;
        logic [10:0] xc0;
        logic [4:0]  cov;
        logic [LW:0] pt, pb;
        logic        lft, covx;
        lft = 1'b0; covx = 1'b0;
        for (int i = 0; i < 3; i++) begin
            plt_x[i] = 8'(p22_sh[6*i +: 6]) - 8'(p22_top[6*i +: 6]);
            plb_x[i] = 8'(p22_sh[6*i +: 6]) - 8'(p22_lo[6*i +: 6]);
        end
        pl_f = 8'(p22_sh[22:18]) + 8'd1;
        pt = plot(p22_top, plt_p, d22, p22_sh, p22_z);
        pb = plot(p22_lo,  plb_p, d22, p22_sh, p22_z);
        attr = '0; aa_here = 1'b0; cov = 5'd0;
        w_top = 1'b0; w_bot = 1'b0; w_topd = '0; w_botd = '0;
        // xcov restarts at the left (part 1) and right (part 3) edge
        xc0 = xcov;
        if (T22.covrst) begin
            if (T22.part == 2'd1) xc0 = (d22.l_cstart == 10'h3FF) ? 11'd0 : 11'(d22.l_cstart);
            else                xc0 = (d22.r_cstart == 10'h3FF) ? 11'd0 : 11'(d22.r_cstart);
        end
        w_xcov = xc0;
        edge_f = NOEDGE ? 4'd0 : d22.yedge | ((T22.part == 2'd1) ? 4'd1 : (T22.part == 2'd3) ? 4'd2 : 4'd0);
        opaque = p22_sh[22:18] == 5'd31;
        if (!T22.v || T22.ghost || p22_kill) ;
        else if (opaque) begin
            attr = s_polyattr(d22) | {28'b0, edge_f};
            aa_here = dcnt[4] && (T22.part != 2'd2 || edge_f != 0);
            if (aa_here) begin
                // left edge (part 1) or right edge (part 3): one datapath
                lft  = T22.part == 2'd1;
                covx = lft ? d22.l_covx : d22.r_covx;
                if (T22.part == 2'd2) cov = 5'h1F;
                else if (covx) begin
                    if (xc0[10]) cov = lft ? 5'd31 : 5'd0;
                    else         cov = lft ? xc0[9:5] : 5'(5'd31 - xc0[9:5]);
                    // 10 bits + a 10-bit step: bit 10 is the carry past 1024, kept once set
                    w_xcov = xc0[10] ? xc0 : 11'({1'b0, xc0[9:0]} + 11'(lft ? d22.l_cinc : d22.r_cinc));
                end else cov = lft ? d22.l_cov5 : d22.r_cov5;
                attr[12:8] = cov;
                if (!p22_bot) begin w_bot = 1'b1; w_botd = p22_top; end   // push down
            end
            if (p22_bot) begin w_bot = 1'b1; w_botd = {a_pack(attr), p22_z, p22_sh}; end
            else begin w_top = 1'b1; w_topd = {a_pack(attr), p22_z, p22_sh}; end
        end else if (p22_bot) begin
            w_bot = pb[LW]; w_botd = pb[LW-1:0];
        end else begin
            // translucent on the top layer: blend into the pixel beneath too
            // when the top one is an edge
            w_top = pt[LW]; w_topd = pt[LW-1:0];
            if (p22_dattr[3:0] != 0) begin w_bot = pb[LW]; w_botd = pb[LW-1:0]; end
        end
    end
    assign pxt_we = w_top;
    assign pxb_we = FEAT_LOWER && w_bot;
    assign pxt_wdata = w_topd;
    assign pxb_wdata = w_botd;

    // stencil: cleared by the input stage (st_clr), set by mask pixels in P21
    always_comb begin
        // (the clear waits in S_STCLR until everything before it has drained)
        st_we    = st_clr || (T21.v && !T21.ghost && s_mask(d21));
        st_waddr = st_clr ? {y[0], clr_x[7:0]} : {LOV ? T21.lp : y[0], T21.x};
        st_wdata = st_clr ? 2'd0 : dt_sv;
    end

    // ---------------- TRU: the reuse history ----------------
    // P15: slot A is the pixel's first read (a 4x4's texel word, else its one
    // read), slot B a 4x4's palette-info word. Each matches the last two
    // halfwords read or reused (t15_h1 the latest), which move to the front.
    function automatic [1:0] tr_m(input [17:0] a, input [17:0] h1, input v1, input [17:0] h2, input v2);
        tr_m = (v1 && a == h1) ? 2'd1 : (v2 && a == h2) ? 2'd2 : 2'd0;
    endfunction
    logic [17:0] t15_h1, t15_h2;
    logic        t15_v1, t15_v2;
    wire         f5_15 = d15.texparam[28:26] == 3'd5;
    // the reads of the P15 pixel, from P15's registers (d15 holds for a span's
    // P14-P22 pixels; p15_slot1 is P14's tx_slot1), not from P14's texture
    // address chain (texparam -> format -> shift -> add -> slot compare: timing)
    assign p15_ntex = !p15_tex ? 2'd0 : (f5_15 && !p15_slot1) ? 2'd2 : 2'd1;
    wire  [18:0] t15_a = (p15_ntex == 2'd2) ? p15_ta : ((f5_15 && p15_slot1) ? p15_s1 : p15_ta);
    wire  [1:0]  t15_ca = !TRU ? 2'd0 : TRUL ? {1'b0, t15_v1 && t15_a[18:1] == t15_h1}
                                       : tr_m(t15_a[18:1], t15_h1, t15_v1, t15_h2, t15_v2);
    // the history after slot A
    wire  [17:0] t15_g1 = (t15_ca == 2'd0) ? t15_a[18:1] : (t15_ca == 2'd1) ? t15_h1 : t15_h2;
    wire  [17:0] t15_g2 = (t15_ca == 2'd1) ? t15_h2 : t15_h1;
    wire         t15_w2 = (t15_ca == 2'd1) ? t15_v2 : t15_v1;
    wire  [1:0]  t15_cb = !(TRU && p15_ntex == 2'd2) ? 2'd0
                        : TRUL ? {1'b0, t15_v2 && p15_s1[18:1] == t15_h2}
                        : tr_m(p15_s1[18:1], t15_g1, 1'b1, t15_g2, t15_w2);
    // reads that go out: the slots without a match
    wire  [1:0]  t15_n  = !TRU ? p15_ntex : 2'(t15_ca == 2'd0) + 2'(p15_ntex == 2'd2 && t15_cb == 2'd0);
    // P17: the words, in the same order
    logic [15:0] t17_d1, t17_d2;
    wire  [1:0]  t17_ca = p17_cd[3:2], t17_cb = p17_cd[1:0];
    wire  [1:0]  t17_n  = !TRU ? p17_ntex : 2'(t17_ca == 2'd0) + 2'(p17_ntex == 2'd2 && t17_cb == 2'd0);
    wire  [15:0] t17_wa = (t17_ca == 2'd0) ? ((t17_n == 2'd2) ? p17_w0 : tq_h0) : (t17_ca == 2'd1 || TRUL) ? t17_d1 : t17_d2;
    wire  [15:0] t17_g1 = (t17_ca == 2'd0) ? t17_wa : (t17_ca == 2'd1) ? t17_d1 : t17_d2;
    wire  [15:0] t17_g2 = (t17_ca == 2'd1) ? t17_d2 : t17_d1;
    wire  [15:0] t17_wb = (t17_cb == 2'd0) ? tq_h0 : TRUL ? t17_d2 : (t17_cb == 2'd1) ? t17_g1 : t17_g2;

    // the histories move with the pixel leaving P15 / P17 (slot A, then B);
    // a frame start or a texture memory write drops P15's (P17's entries are
    // then never pointed at until written again)
    always_ff @(posedge clk)
        if (!TRU || rst || frame_go || tex_inval) begin t15_v1 <= 1'b0; t15_v2 <= 1'b0; end
        else if (adv && p15_need && TRUL) begin
            // TRUL: entry 1 slot A's last halfword, entry 2 slot B's
            t15_h1 <= t15_a[18:1]; t15_v1 <= 1'b1;
            if (p15_ntex == 2'd2) begin t15_h2 <= p15_s1[18:1]; t15_v2 <= 1'b1; end
        end else if (adv && p15_need) begin
            if (p15_ntex == 2'd2) begin
                if (t15_cb == 2'd0)      begin t15_h1 <= p15_s1[18:1]; t15_h2 <= t15_g1; t15_v1 <= 1'b1; t15_v2 <= 1'b1; end
                else if (t15_cb == 2'd1) begin t15_h1 <= t15_g1; t15_h2 <= t15_g2; t15_v1 <= 1'b1; t15_v2 <= t15_w2; end
                else                     begin t15_h1 <= t15_g2; t15_h2 <= t15_g1; t15_v1 <= 1'b1; t15_v2 <= 1'b1; end
            end else begin t15_h1 <= t15_g1; t15_h2 <= t15_g2; t15_v1 <= 1'b1; t15_v2 <= t15_w2; end
        end
    always_ff @(posedge clk)
        if (TRU && TRUL && adv && p17_need) begin
            t17_d1 <= t17_wa;
            if (p17_ntex == 2'd2) t17_d2 <= t17_wb;
        end else if (TRU && adv && p17_need) begin
            if (p17_ntex == 2'd2) begin
                if (t17_cb == 2'd0)      begin t17_d1 <= t17_wb; t17_d2 <= t17_g1; end
                else if (t17_cb == 2'd1) begin t17_d1 <= t17_g1; t17_d2 <= t17_g2; end
                else                     begin t17_d1 <= t17_g2; t17_d2 <= t17_g1; end
            end else begin t17_d1 <= t17_g1; t17_d2 <= t17_g2; end
        end

    // ---------------- stalls ----------------
    // P15: a 4x4 texel needs two texture reads (two cycles)
    wire p15_need = T15.v && !T15.ghost && p15_ntex != 2'd0;
    wire hold15   = p15_need && t15_n == 2'd2 && !p15_sent;
    // P17: wait for the texture data; two palette reads take two cycles
    wire p17_need = T17.v && !T17.ghost && p17_ntex != 2'd0;
    wire p17_rd   = p17_need && t17_n != 2'd0;          // (TRU: some read of it went out)
    wire wait17   = p17_rd && tq_n == '0;
    wire take17   = p17_rd && !wait17 && t17_n == 2'd2 && !p17_w0v;   // first of two
    wire hold17   = p17_need && !wait17 && !take17 && tx_npal == 2'd2 && !p17_sent;
    // P19: wait for the palette data
    wire p19_need = T19.v && !T19.ghost && p19_npal != 2'd0;
    wire wait19   = p19_need && pq_n == '0;
    wire take19   = p19_need && !wait19 && p19_npal == 2'd2 && !p19_w0v;
    // P20: the line-buffer/stencil read must see the writes of P21/P22
    wire hz20     = T20.v && !T20.ghost &&
                    ((T21.v && !T21.ghost && T21.x == T20.x) ||
                     (T22.v && !T22.ghost && T22.x == T20.x));
    // LLR: the late-line read has the slot P20 reads
    wire ll20     = ll_ack && T20.v && !T20.ghost && sl20 == ll_slot;
    // half rate: the pipeline advances at most every other cycle (the
    // divider's two steps per stage need the cycle in between)
    logic hr_t;
    always_ff @(posedge clk) hr_t <= rst ? 1'b0 : !hr_t;
    assign adv = !lin_hold && (!AREA || hr_t) && !(hold15 || wait17 || take17 || hold17 || wait19 || take19 || hz20 || ll20);
    assign tq_pop = take17 || (adv && p17_rd);
    assign pq_pop = take19 || (adv && p19_need);

    // ---------------- stage registers ----------------
    // texture/palette requests are the ones the main FSM used to make
    logic        pp_tex_req, pp_pal_req;
    logic [18:0] pp_tex_addr;
    logic [16:0] pp_pal_addr;
    always_ff @(posedge clk) begin
        pp_tex_req <= 1'b0;
        pp_pal_req <= 1'b0;
        if (rst) begin
            for (int i = 0; i <= 22; i++) tg[i] <= '0;
            p15_sent <= 1'b0; p17_sent <= 1'b0; p17_w0v <= 1'b0; p19_w0v <= 1'b0;
        end else begin
            // P21, P22 always drain
            tg[22] <= tg[21];
            tg[21] <= adv ? tg20f : '0;
            p21_sh <= rp_col; p21_z <= p20_z;
            p22_sh <= p21_sh; p22_z <= p21_z;
            p22_kill <= !dt_pass || p21_sh[22:18] <= aref || s_mask(d21);
            p22_bot <= dt_bot; p22_dattr <= dt_attr;
            p22_top <= lt_top; p22_lo <= lt_bot;
            if (T22.v && !T22.ghost) xcov <= w_xcov;

            // the second texture / palette read of a pixel goes out first, alone
            if (hold15) begin
                pp_tex_req <= 1'b1; pp_tex_addr <= p15_ta; p15_sent <= 1'b1;
            end
            if (take17) begin p17_w0 <= tq_h0; p17_w0v <= 1'b1; end
            if (take19) begin p19_w0 <= pq_h0; p19_w0v <= 1'b1; end
            if (adv) begin p17_w0v <= 1'b0; p19_w0v <= 1'b0; end
            if (hold17) begin
                pp_pal_req <= 1'b1; pp_pal_addr <= tx_pa0; p17_sent <= 1'b1;
            end

            if (MLOAD && sd_load)    // (MLOAD, above)
                for (int k = 0; k < 5; k++) begin
                    p12_ma[k] <= nx_d.ad[k];
                    p12_mc[k] <= {nx_d.abase[k], 17'((DS_TEXRND && nx_d.lin && k >= 3) ? 17'h1000 : 17'h0)};
                end
            if (adv) begin
                // the span's late fields follow its first pixel into P14
                if (T13.v && T13.first) sd_late <= sd_cur;
                if (TXD > 0 && tg16o[25] && tg16o[22]) sd_late2 <= sd_late;   // {v, first} (ptag_t bits; Quartus: no member access here)
                for (int i = 20; i > 0; i--) if (!AREA || i < 7 || i > 11) tg[i] <= tg[i - 1];
                if (TXD > 0) begin
                    tg[17] <= tg16o;
                end
                if (PXD > 0) tg[19] <= tg18x;
                if (AREA) tg[11] <= tg[6];    // (P7-P10 removed: the divider is P3-P6)
                // P0: walker
                tg[0] <= wk_tag;
                dly_wp <= dly_wp + 5'd1;
                if (wk_act) begin
`ifndef SYNTHESIS
                    if (wk_x < wd.xs) $error("gpu3d_raster: pixel left of the span start");
`endif
                end
                // P1: x * w0, (xdiff - x) * w1
                p1_m1 <= 26'(T0.ix * d0.wl);
                p1_ix <= T0.ix; p1_xr <= 10'(d0.xdiff - T0.ix);
                p1_z1 <= T0.ix == 10'd0 || d0.wl == 16'd0;
                p1_z2 <= 10'(d0.xdiff - T0.ix) == 10'd0 || d0.wr == 16'd0;
                // P2: num = (x * w0) << 8 (u32, wraps as in melonDS), den
                p2_num <= {p1_m1[23:0], 8'b0};
                p2_den <= 25'(26'(p1_ix * d0.wl) + 26'(p1_xr * d0.wr));
                p2_den0 <= p1_z1 && p1_z2;     // (the sum stays below 2^25: no wrap to 0)
                // 256*a/(a+b) is exactly 256 when b = 0 (a = x*w0 < 2^24 for x
                // <= 255, so a << 8 never wraps); otherwise it is below 256
                p2_256 <= p1_z2 && !p1_z1;
`ifndef SYNTHESIS
                if (tg[1][TV] && (p1_m1 >= 26'h1000000 || 27'(p1_m1) + 27'(p1_xr * d0.wr) >= 27'h2000000))
                    $error("gpu3d_raster: perspective numerator wraps or denominator >= 2^25");
`endif
`ifndef SYNTHESIS
                if (T2.v && !p2_den0 && !p2_256 && {1'b0, p2_num[31:8]} >= p2_den)
                    $error("gpu3d_raster: perspective factor >= 256");
`endif
                pd_q[11] <= pd_q[DVL]; pd_z[11] <= pd_z[DVL]; pd_256[11] <= pd_256[DVL];
                // P11: Z-buffer path, (disp >> 9) * factor
                p11_zp <= 25'((d10.dz >> 9) * (d10.zlt ? T10.ix : d10.xdiff - T10.ix));
                p11_ix <= T10.ix; p12_ix <= p11_ix;
                begin   // DS_LIN17: the factor and its mirror, registered for the P12 lanes
                    logic [16:0] f;
                    f = 17'((48'(T10.ix) * 48'(38'(sd_aqs))) >> 20);   // < 2^17 (ix < xdiff)
                    p11_lf <= f; p11_lfn <= 17'(18'h20000 - 18'(f)); p11_lf0 <= f == 17'd0;
                end
                // P12: products / linear steppers
                begin
                    logic [8:0] yf;
                    yf = pd_z[11] ? 9'd0 : pd_256[11] ? 9'd256 : {1'b0, pd_q[11]};
                    p12_yf <= yf;
                    // factors fit 17 bits (one 18x18 DSP half per lane): a
                    // linear 2^17 (descending, f = 0) is flagged and taken as
                    // the whole difference in P13
                    for (int k = 0; k < 5; k++) begin
                        logic [16:0] fk;
                        fk = (DS_LIN17 && d11.lin) ? (d11.alt[k] ? p11_lf : p11_lfn) : 17'(d11.alt[k] ? yf : 9'd256 - yf);
                        p12_ap[k]   <= 34'(d11.ad[k]) * 34'(fk);
                        p12_full[k] <= DS_LIN17 && d11.lin && !d11.alt[k] && p11_lf0;
                        if (!MLOAD) p12_ma[k] <= d11.ad[k];
                        p12_mf[k] <= d11.lin ? (d11.alt[k] ? {1'b0, p11_lf} : {p11_lf0, p11_lfn})
                                             : {(d11.alt[k] ? yf : 9'd256 - yf), 9'd0};
                        if (!MLOAD) p12_mc[k] <= {sd_abase[k], 17'((DS_TEXRND && d11.lin && k >= 3) ? 17'h1000 : 17'h0)};
                    end
                    begin   // DS_TOON
                        logic [16:0] ft;
                        ft = (DS_LIN17 && d11.lin) ? (d11.talt ? p11_lf : p11_lfn) : 17'(d11.talt ? yf : 9'd256 - yf);
                        p12_tp    <= 27'(d11.tad) * 27'(ft);
                        p12_tfull <= DS_LIN17 && d11.lin && !d11.talt && p11_lf0;
                        p12_ta <= d11.tad; p12_tc <= d11.tbase;
                        p12_tf <= d11.lin ? (d11.talt ? {1'b0, p11_lf} : {p11_lf0, p11_lfn})
                                          : {(d11.talt ? yf : 9'd256 - yf), 9'd0};
                    end
                    // DS_LINZ: one multiply for both buffers, the W-buffer's factor
                    // << 9 as on the attribute lanes ((dz * f << 9) >> 17 = (dz * f) >> 8)
                    if (DS_LINZ)    p12_zm <= 48'(42'(d11.dz) * 42'(d11.wbuf ? {(d11.zlt ? yf : 9'd256 - yf), 9'd0}
                                                                         : {1'b0, d11.zlt ? p11_lf : p11_lfn}));
                    else if (d11.wbuf) p12_zm <= 48'(d11.dz * (d11.zlt ? yf : 9'd256 - yf));
                    else            p12_zm <= 48'(p11_zp * d11.xrecip);
                    p12_zfull <= DS_LINZ && !d11.wbuf && !d11.zlt && p11_lf0;
                end
                // P13: attribute values (mod 2^16), Z
                for (int k = 0; k < 5; k++) begin
                    logic [15:0] off;
                    logic        cy;   // DS_TEXRND: s, t round with + 2^12 before the >> 17
                    if (d12.lin) off = RECIP ? ls_off[k] : LINSER ? p12_lq[k]   // (already the offset)
                                     : d12.alt[k] ? p12_lq[k] : 16'(d12.ad[k]) - p12_lq[k] - 16'(p12_lr[k]);
                    if (DS_LIN17)  off = !d12.lin ? 16'(p12_ap[k] >> 8) : p12_full[k] ? 16'(d12.ad[k]) : 16'(p12_ap[k] >> 17);
                    else if (!d12.lin) off = 16'(p12_ap[k] >> 8);
                    cy = DS_TEXRND && DS_LIN17 && d12.lin && !p12_full[k] && k >= 3 && (&p12_ap[k][16:12]);
                    if (DS_LIN17) p13_av[k] <= 16'((36'(p12_ma[k]) * 36'(p12_mf[k]) + 36'(p12_mc[k])) >> 17);
                    else          p13_av[k] <= sd_abase[k] + off + 16'(cy);
                end
                p13_z <= d12.zbase + 24'(DS_LINZ ? (p12_zfull ? 48'(d12.dz) : (p12_zm >> 17))
                                         : d12.wbuf ? (p12_zm >> 8) : (p12_zm >> 13));
                if (DS_LIN17) p13_tv <= 9'((36'(p12_ta) * 36'(p12_tf) + {p12_tc, 17'd0}) >> 17);
                else p13_tv <= d12.tbase + (DS_LIN17 ? (!d12.lin ? 9'(p12_tp >> 8) : p12_tfull ? 9'(d12.tad) : 9'(p12_tp >> 17))
                                                : (d12.lin ? ls_toff : 9'(p12_tp >> 8)));
                // P14: toon, texture address
                p14_toon_a <= DS_TOON ? tv13[8:4] : p13_av[0][8:4];
                p14_sw <= tx_sw; p14_tw <= tx_tw;
                p14_tex <= !(T13.ghost || !s_textured(d13) || s_mask(d13));
                // P15: texture request(s); a 4x4 texel reads the texel word
                // (during hold15), then the slot-1 palette info
                p15_ta <= tx_a; p15_ss <= p14_sw[1:0];
                p15_tex <= p14_tex;
                if (p15_need && t15_n != 2'd0) begin
                    pp_tex_req <= 1'b1;
                    if (TRU) pp_tex_addr <= (t15_n == 2'd2 || t15_ca != 2'd0) ? p15_s1 : t15_a;
                    else     pp_tex_addr <= (p15_ntex == 2'd2 || (d15.texparam[28:26] == 3'd5 && p15_slot1)) ? p15_s1 : p15_ta;
                end
                p16_cd <= {t15_ca, t15_cb};
                p15_sent <= 1'b0;
                // P16: in flight
                p16_b1 <= p15_ta[0]; p16_slot1 <= p15_slot1; p16_ss <= p15_ss; p16_ntex <= p15_ntex;
                // P17: texel decode, palette request(s)
                {p17_b1, p17_slot1, p17_ss, p17_ntex, p17_cd} <= p16o;
                p18_npal <= p17_need ? tx_npal : 2'd0;
                p18_mix <= tx_mix; p18_tc <= tx_tc; p18_ta <= tx_ta; p18_c4 <= tx_c4;
                if (p17_need && tx_npal != 2'd0) begin
                    pp_pal_req <= 1'b1;
                    pp_pal_addr <= (tx_npal == 2'd2) ? tx_pa1 : tx_pa0;
                end
                p17_sent <= 1'b0;
                // P18: in flight
                if (PXD > 0) {p19_npal, p19_mix, p19_c4, p19_tc, p19_ta} <= p18x;
                else begin p19_npal <= p18_npal; p19_mix <= p18_mix; p19_tc <= p18_tc; p19_ta <= p18_ta; p19_c4 <= p18_c4; end
                // P19: palette -> texel
                p20_tal <= p19_ta;
                begin
                    logic [5:0] vr, vg, vb, hr, hg, hb, xr, xg, xb;
                    logic [31:0] lx, lf;
                    logic [31:0] at;
                    logic [4:0]  pa;
                    at = d20.attr;              // struct fields into plain locals first
                    pa = at[20:16];
                    vr = p19_sv[5:0]; vg = p19_sv[11:6]; vb = p19_sv[17:12];
                    hr = exp5(p19_toon[4:0]); hg = exp5(p19_toon[9:5]); hb = exp5(p19_toon[14:10]);
                    if (FEAT_TOON && at[5:4] == 2'd2) begin             // toon / highlight (same late descriptor)
                        if (dcnt[1]) begin
                            if (DS_HILITE) vr = p19_tr6;   // the fill-less red (DS)
                            vg = vr; vb = vr;
                        end else begin vr = hr; vg = hg; vb = hb; end
                    end
                    p20_sv <= {vb, vg, vr};
                    // the highlight addition: c << 1 on the DS, (c << 1) + 1 (c != 0) in melonDS
                    p20_hl <= DS_HILITE ? {p19_toon[14:10], 1'b0, p19_toon[9:5], 1'b0, p19_toon[4:0], 1'b0}
                                        : {hb, hg, hr};
                    if (p19_c4) begin
                        xr = {tx_col[4:0], 1'b0}; xg = {tx_col[9:5], 1'b0}; xb = {tx_col[14:10], 1'b0};
                    end else begin
                        xr = exp5(tx_col[4:0]); xg = exp5(tx_col[9:5]); xb = exp5(tx_col[14:10]);
                    end
                    p20_tt <= {xb, xg, xr};
                    if (at[4]) begin         // decal: (t - v) * ta
                        lx = {8'(p19_ta) + 8'd1, 8'(xb - vb), 8'(xg - vg), 8'(xr - vr)};
                        lf = {8'(pa) + 8'd1, 8'(p19_ta), 8'(p19_ta), 8'(p19_ta)};
                    end else begin           // modulate: (t + 1) * (v + 1)
                        lx = {8'(p19_ta) + 8'd1, 8'(xb) + 8'd1, 8'(xg) + 8'd1, 8'(xr) + 8'd1};
                        lf = {8'(pa) + 8'd1, 8'(vb) + 8'd1, 8'(vg) + 8'd1, 8'(vr) + 8'd1};
                    end
                    p20_slx <= lx;
                    p20_slf <= lf;
                    p20_slc[3] <= 12'hFFF;
                    p20_slc[2] <= at[4] ? 12'({vb, 5'b0} - vb) : 12'hFFF;
                    p20_slc[1] <= at[4] ? 12'({vg, 5'b0} - vg) : 12'hFFF;
                    p20_slc[0] <= at[4] ? 12'({vr, 5'b0} - vr) : 12'hFFF;
                end
            end
        end
    end

endmodule
