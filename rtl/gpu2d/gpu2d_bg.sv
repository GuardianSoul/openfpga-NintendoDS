// NDS 2D engine, BG side: renders one engine-line (BG layers, the 3D layer,
// OBJ interleave, colour effects, display mode, master brightness, display
// capture) pixel-exact against melonDS's SoftRenderer2D::DrawScanline plus
// SoftRenderer::DrawScanlineA/B and DoCapture. See docs/2d-engine.md.
//
// A job is one engine-line. It runs as a sequence of passes over x = 0..255,
// one pixel per clock through a 7-stage pipeline:
//   one pass per enabled layer, back to front (priority 3..0, BG3..BG0), each
//   painting into a 256-entry line buffer that keeps the two front-most
//   pixels {top, second} (melonDS's BGOBJLine); the OBJ pixel of a priority
//   is painted just before the first layer in front of it;
//   then a composite pass: colour effects, display mode, master brightness,
//   capture, output.
// Stages: S0 coordinates -> map cache; S1 tile entry -> texel cache;
// S2 texel -> palette RAM / ext-palette cache, line buffers, 3D, FIFO;
// S3 colour, window, OBJ mosaic, paint; S4 write (BG) or colour effect
// (composite); S5 display mode, master brightness, capture; S6 output.
// A miss in any of the three caches stalls the whole pipeline until the
// block is filled; every RAM re-reads its held address while stalled.
module gpu2d_bg
    import gpu2d_pkg::*;
#(
    parameter bit PERSIST  = 0,   // keep cached blocks across lines until VRAM is written
    parameter int MAP_IDXW = 6,   // log2 blocks per cache
    parameter int TEX_IDXW = 6,
    parameter int EXT_IDXW = 6,
    parameter bit EXT_TAG_MLAB = 0, // ext-palette cache's tags in its data words (gpu2d_cache TAG_DATA)
    parameter bit PREFETCH = 1,   // prefetch pass before each text layer
    // WST_RF: the per-pass words (scroll, affine reference and parameters,
    // state words 3..12) come from the state register file, not from st:
    // a look-ahead scan finds the job's next layer early and its words are
    // read into one "next" set before the plan scan reaches it, so the job's
    // clock schedule is the same as without (docs/2d-engine.md)
    parameter bit WST_RF   = 0,
    parameter bit MOSAIC   = 1    // 0: no BG or OBJ mosaic (a fit setting; behaves as mosaic size 0)
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic        eng,         // 0 = engine A, 1 = engine B
    input  logic [7:0]  line,
    input  logic        objslot,     // OBJ line buffer holding this line
    output logic        busy,
    output logic        done,
    input  eng_state_t  st,          // state of `eng`, constant during the job
    output logic [4:0]  rf_raddr,    // WST_RF: state word of `eng` (data next clock)
    input  logic [31:0] rf_rdata,
    input  logic        rf_free,     // the address is taken this clock (the loader has the port otherwise)
    input  logic        pre,         // the job's DISPCNT, BGnCNT and misc words are in st: scan for the first layer
    input  logic [31:0] capcnt,
    input  logic        cap_en,
    input  logic [3:0]  lcdc_map,    // banks A-D mapped to LCDC
    input  logic        vram_wr,     // VRAM or VRAMCNT written (PERSIST)
    // fills: request per cache (0 map, 1 texel, 2 ext palette)
    output logic [3:0]  fill_req,    // [3]: texel prefetch, never stalls
    output blk_t [3:0]  fill_blk,
    input  logic        pf_ack,      // prefetch taken (or dropped as already in flight)
    input  logic [2:0]  fill_we,
    input  blk_t        fill_fblk,   // block the beats belong to
    input  logic [1:0]  fill_beat,
    input  logic        fill_last,
    input  logic [63:0] fill_data,
    // palette RAM (BG copy), word = 2 halfwords
    output logic [8:0]  pal_raddr,
    input  logic [31:0] pal_rdata,
    // OBJ line buffer of objslot: entry {win, opaque, prio[1:0], mosaic, flag[7:0], colour[15:0]}
    output logic [8:0]  olb_raddr,
    input  logic [28:0] olb_rdata,
    output logic        olb_we,      // composite pass clears each entry after reading it
    output logic [8:0]  olb_waddr,
    // 3D line (melonDS Output3D format) and display FIFO line, read next clock
    output logic [7:0]  l3d_raddr,
    input  logic [31:0] l3d_rdata,
    output logic [7:0]  fifo_raddr,
    input  logic [15:0] fifo_rdata,
    // pixels after master brightness: r[5:0] g[11:6] b[17:12]
    output logic        out_valid,
    output logic        out_eng,
    output logic [7:0]  out_x,
    output logic [17:0] out_rgb,
    // capture writes: halfword address {bank[1:0], index[15:0]}
    output logic        cap_we,
    output logic [17:0] cap_addr,
    output logic [15:0] cap_data,
    input  logic        cap_ready,
    // statistics (testbench)
    output logic        stat_stall
);
    typedef enum logic [2:0] {K_TEXT, K_AFF, K_EXT16, K_BMP8, K_BMPD, K_LARGE, K_3D, K_COMP} kind_t;
    typedef enum logic [2:0] {J_IDLE, J_INIT, J_BACK, J_PLAN, J_SETUP, J_RUN, J_DRAIN} jst_t;

    typedef struct packed {
        logic [17:0] c;
        logic [7:0]  f;
    } px_t;
    typedef struct packed {
        px_t  top;
        px_t  sec;
        logic done;      // OBJ pixel already painted
    } lbe_t;

    // ---------------------------------------------------------------- job
    jst_t        js;
    logic        j_eng;
    logic [7:0]  j_line;
    logic        j_slot;
    logic [4:0]  plan_k;       // {end, prio, bg} counting down from 15
    logic        first;        // no layer painted yet
    logic [17:0] backdrop;
    logic        stall;

    // pass configuration
    kind_t       c_kind;
    logic        c_comp, c_3d; // c_kind == K_COMP / K_3D, registered with it (timing: c_kind -> s4.ka, #1562 -0.87 ns)
    logic        c_pf;         // prefetch pass: tile rows only, no pixels
    logic [1:0]  c_bg, c_prio;
    logic        c_mos;
    logic        c_bpp8;       // text: 256 colours
    logic        c_ext;        // extended palette lookup
    logic [1:0]  c_slot;
    logic [18:0] c_map;        // text: map row base; affine: map base; bitmap: base
    logic [18:0] c_tile;
    logic        c_wide;
    logic [2:0]  c_yfine;
    logic [1:0]  c_size;
    logic [2:0]  c_kx, c_ky;   // a coordinate is outside the layer when its bits k and up are not all 0:
                               // [2] such a limit, [1:0] k - 15 (k is 15..18)
    // composite
    logic        c_capline, c_capB, c_vdisp, c_cap3d;
    logic [8:0]  c_capw;       // 128 or 256
    logic [1:0]  c_dmode;

    logic [8:0]  x;            // S0 pixel (256 = pass issued)
    logic [3:0]  mcnt;
    logic [15:0] tx0;          // text: x scroll
    // The affine accumulators keep 28 bits (the DS's BGxX/BGxY width). From a
    // 28-bit reference, 192 lines of PB and 256 pixels of PA stay within
    // +-(2^27 + 2^24): a value the 32-bit sum would hold beyond +-2^27 wraps
    // to one that is out of range too (a layer is at most 2^18 in 20.8), and
    // the low bits that address the layer are the same: the pixels are too
    logic [27:0] rx, ry, hx, hy;
    logic [15:0] ra, rc;
    // (WST_RF) the next layer's words: {VOFS, HOFS}, X ref, Y ref, {PC, PA};
    // before the composite pass words 18 and 19 (BLDALPHA:BLDCNT,
    // MASTER_BRIGHT:BLDY) in n_scr and n_x
    logic [31:0] n_scr, n_x, n_y, n_rr;
    function automatic logic [4:0] ev16(input logic [4:0] v);
        return v > 5'd16 ? 5'd16 : v;
    endfunction
    logic [13:0] bldcnt;
    logic [4:0]  c_eva, c_evb, c_evy;
    logic [15:0] mbright;
    assign bldcnt  = WST_RF ? n_scr[13:0]       : st.blendcnt;
    assign c_eva   = WST_RF ? ev16(n_scr[20:16]) : st.eva;
    assign c_evb   = WST_RF ? ev16(n_scr[28:24]) : st.evb;
    assign c_evy   = WST_RF ? ev16(n_x[4:0])     : st.evy;
    assign mbright = WST_RF ? n_x[31:16]        : st.mbright;

    logic [2:0] mode;

    assign mode = st.dispcnt[2:0];
    logic bg0_3d;
    assign bg0_3d = !j_eng && st.dispcnt[3];
    logic [1:0] pk_bg;
    assign pk_bg = plan_k[1:0];
    function automatic logic [3:0] kind_of(input logic [1:0] b, input logic [2:0] m,
                                           input logic is3d, input logic [13:0] cnt);
        // {valid, kind}
        kind_t ex;
        ex = cnt[7] ? (cnt[2] ? K_BMPD : K_BMP8) : K_EXT16;
        case (b)
            2'd0: kind_of = is3d ? {1'b1, K_3D} : (m == 3'd6 ? 4'b0 : {1'b1, K_TEXT});
            2'd1: kind_of = m == 3'd6 ? 4'b0 : {1'b1, K_TEXT};
            2'd2: case (m)
                      3'd2, 3'd4: kind_of = {1'b1, K_AFF};
                      3'd5:       kind_of = {1'b1, ex};
                      3'd6:       kind_of = {1'b1, K_LARGE};
                      3'd7:       kind_of = 4'b0;
                      default:    kind_of = {1'b1, K_TEXT};
                  endcase
            default: case (m)
                      3'd0:             kind_of = {1'b1, K_TEXT};
                      3'd1, 3'd2:       kind_of = {1'b1, K_AFF};
                      3'd3, 3'd4, 3'd5: kind_of = {1'b1, ex};
                      default:          kind_of = 4'b0;
                  endcase
        endcase
    endfunction

    logic [15:0] pk_cnt;
    logic [3:0]  pk_kind;
    logic        pk_ok;
    always_comb begin
        pk_cnt  = st.bgcnt[pk_bg];
        pk_kind = kind_of(pk_bg, mode, bg0_3d, pk_cnt);
        pk_ok   = !plan_k[4] && pk_kind[3] && st.layer_enable[pk_bg] && pk_cnt[1:0] == plan_k[3:2]
                  && st.enabled && !st.forced_blank;
    end

    // text map row: tilemap + Y part (DrawBG_Text)
    logic [15:0] t_yoff;
    logic [18:0] t_map, t_tile, a_map, a_tile;
    always_comb begin
        t_yoff = (WST_RF ? n_scr[31:16] : st.bgypos[pk_bg]) + ((MOSAIC && pk_cnt[6]) ? {7'd0, st.bg_mos_line} : {8'd0, j_line});
        a_map  = (j_eng ? 19'd0 : {st.dispcnt[29:27], 16'd0}) | {3'd0, pk_cnt[12:8], 11'd0};   // disjoint bits
        a_tile = (j_eng ? 19'd0 : {st.dispcnt[26:24], 16'd0}) + {pk_cnt[5:2], 14'd0};
        // 64 bytes per map row; a 512-tall map adds its second 2 KB screen
        t_map  = a_map + (pk_cnt[15] ? {7'd0, t_yoff[8:3], 6'd0} + (pk_cnt[14] ? {7'd0, t_yoff[8], 11'd0} : 19'd0)
                                     : {8'd0, t_yoff[7:3], 6'd0});
        t_tile = a_tile;
    end

    // overflow masks, fixed per pass: DrawBG_Affine/_Extended's
    // ~(coordmask | 0x7FF) for tiled layers, ~xmask/~ymask for bitmaps,
    // nothing when the layer wraps
    function automatic logic [5:0] oob_masks(input kind_t k, input logic [1:0] sz, input logic wrap);
        logic [3:0] bx, by;
        case ({k == K_LARGE, sz})
            3'b000: begin bx = 4'd7;  by = 4'd7;  end
            3'b001: begin bx = 4'd8;  by = 4'd8;  end
            3'b010: begin bx = 4'd9;  by = 4'd8;  end
            3'b011: begin bx = 4'd9;  by = 4'd9;  end
            3'b100: begin bx = 4'd9;  by = 4'd10; end
            3'b101: begin bx = 4'd10; by = 4'd9;  end
            3'b110: begin bx = 4'd9;  by = 4'd8;  end
            default: begin bx = 4'd9; by = 4'd9;  end
        endcase
        // as {x, y}: limit present, k - 15 (the masks were ~0 << k)
        if (wrap) return 6'd0;
        if (k == K_AFF || k == K_EXT16) return {2{1'b1, sz}};
        if (k == K_BMP8 || k == K_BMPD || k == K_LARGE)
            return {1'b1, 2'(bx - 4'd7), 1'b1, 2'(by - 4'd7)};
        return 6'd0;
    endfunction
    // some bit k and up of v is set
    function automatic logic oob_of(input logic [27:0] v, input logic [2:0] kk);
        return kk[2] && (|v[27:18] || (kk[1:0] <= 2'd2 && v[17]) || (kk[1:0] <= 2'd1 && v[16]) || (kk[1:0] == 2'd0 && v[15]));
    endfunction

    // The pass's layer fields, from its BGnCNT: plan_k (so pk_bg and pk_cnt)
    // stays put from the clock the plan picks the layer until its pass has
    // drained, and the state is constant for the job, so these need no copy
    assign c_bg   = pk_bg;
    assign c_prio = plan_k[3:2];
    assign c_bpp8 = pk_cnt[7];
    assign c_tile = t_tile;
    assign c_wide = pk_cnt[14];
    assign c_size = pk_cnt[15:14];
    assign {c_kx, c_ky} = oob_masks(kind_t'(pk_kind[2:0]), pk_cnt[15:14], pk_cnt[13]);

    // capture geometry (DoCapture)
    logic [1:0]  cap_sz;
    logic        cap_hit;
    always_comb begin
        cap_sz  = capcnt[21:20];
        cap_hit = !j_eng && cap_en && lcdc_map[capcnt[17:16]]
                  && (cap_sz == 2'd0 ? j_line < 8'd128 : {1'b0, j_line} < {cap_sz, 6'd0} + 9'd0);
    end

    // ---------------------------------------------------------------- pipeline regs
    typedef struct packed {
        logic        v;
        logic [7:0]  x;
        logic        oob;         // affine/bitmap outside the layer
        logic [2:0]  xf, yf;      // fine coordinates (text: xf only)
        logic [18:0] taddr;       // bitmap texel address (from S0)
    } s1_t;
    typedef struct packed {
        logic        v;
        logic [7:0]  x;
        logic        oob;
        logic [18:0] taddr;
        logic        hi;          // 4bpp: high nibble
        logic [3:0]  pal;         // tile palette
    } s2_t;
    typedef struct packed {
        logic        v;
        logic [7:0]  x;
        logic        op;          // opaque BG pixel (before window)
        logic        direct;      // colour in dcol, no palette
        logic        pal_hi;      // palette RAM halfword select
        logic        ext;         // colour from the ext-palette cache
        logic [15:0] dcol;        // direct colour
    } s3_t;
    typedef struct packed {
        logic        v;
        logic [7:0]  x;
        lbe_t        e;
        logic [5:0]  ka, kb;      // colour-effect factors (from S3)
        logic        b63;         // brightness up: b = 63
        logic [15:0] fifo;
    } s4_t;
    typedef struct packed {
        logic        v;
        logic [7:0]  x;
        logic [17:0] o2d;         // Output2D (pre display mode)
        logic [22:0] c3d;         // the 3D pixel for capture A (alpha, 5:5:5 of 6:6:6)
        logic [15:0] vdisp, capb; // VRAM display pixel, capture source B
        logic [15:0] fifo;
    } s5_t;
    typedef struct packed {
        logic        v;
        logic [7:0]  x;
        logic [17:0] rgb;
        logic        cw;          // capture write
        logic [15:0] cdata;
    } s6_t;

    s1_t s1; s2_t s2; s3_t s3; s4_t s4; s5_t s5; s6_t s6;
    logic [18:0] s1_maddr_q;   // map read address, latched with S1
    logic [14:0] s3_eaddr_q;   // ext-palette read address, latched with S3
    logic [28:0] s3_olb;       // OBJ line buffer entry for S3 (read at S1)

    // caches
    blk_t        m_ablk, t_ablk, e_ablk;
    logic [1:0]  m_aword, t_aword, e_aword;
    logic [63:0] m_q, t_q, e_q;
    logic        m_hit, t_hit, e_hit;
    blk_t        m_cur, t_cur, e_cur;
    logic [1:0]  m_curw, t_curw, e_curw;
    logic        cclear;

    // one generation and scrub counter for this side's caches (gpu2d_cgen)
    // (the ext-palette cache with its tag in the data words scrubs words: EXT_IDXW + 2 bits)
    localparam int ESW = EXT_TAG_MLAB ? EXT_IDXW + 2 : EXT_IDXW;
    localparam int CSW = ((MAP_IDXW > TEX_IDXW ? MAP_IDXW : TEX_IDXW) > ESW ? (MAP_IDXW > TEX_IDXW ? MAP_IDXW : TEX_IDXW) : ESW);
    logic [9:0]     c_gen;
    logic [CSW-1:0] c_scrub, c_scrub_q;
    logic           c_scrub_v;
    gpu2d_cgen #(.SW(CSW)) u_cgen (.clk, .clear(cclear), .idle(js == J_IDLE), .gen(c_gen), .scrub(c_scrub),
        .scrub_q(c_scrub_q), .scrub_v(c_scrub_v));
    gpu2d_cache #(.IDXW(MAP_IDXW), .HASH(1)) u_mc (.clk, .idle(js == J_IDLE), .gen(c_gen), .scrub(c_scrub[MAP_IDXW-1:0]),
        .scrub_q(c_scrub_q[MAP_IDXW-1:0]), .scrub_v(c_scrub_v), .hold(stall), .a_blk(m_ablk), .a_word(m_aword),
        .q(m_q), .hit(m_hit), .cur_blk(m_cur), .cur_word(m_curw),
        .fill_we(fill_we[0]), .fill_blk(fill_fblk), .fill_beat, .fill_last, .fill_data);
    gpu2d_cache #(.IDXW(TEX_IDXW), .HASH(1)) u_tc (.clk, .idle(js == J_IDLE), .gen(c_gen), .scrub(c_scrub[TEX_IDXW-1:0]),
        .scrub_q(c_scrub_q[TEX_IDXW-1:0]), .scrub_v(c_scrub_v), .hold(stall), .a_blk(t_ablk), .a_word(t_aword),
        .q(t_q), .hit(t_hit), .cur_blk(t_cur), .cur_word(t_curw),
        .fill_we(fill_we[1]), .fill_blk(fill_fblk), .fill_beat, .fill_last, .fill_data);
    gpu2d_cache #(.IDXW(EXT_IDXW), .TAG_DATA(EXT_TAG_MLAB), .HASH(2), .VLO(10)) u_ec (.clk, .idle(js == J_IDLE), .gen(c_gen), .scrub(c_scrub[ESW-1:0]),
        .scrub_q(c_scrub_q[ESW-1:0]), .scrub_v(c_scrub_v), .hold(stall), .a_blk(e_ablk), .a_word(e_aword),
        .q(e_q), .hit(e_hit), .cur_blk(e_cur), .cur_word(e_curw),
        .fill_we(fill_we[2]), .fill_blk(fill_fblk), .fill_beat, .fill_last, .fill_data);

    // S1/S2/S3 track which cache read their pixel needs (latched with the address)
    logic s1_nm, s2_nt, s3_ne;
    logic s4_nm, s4_nt;        // composite: capture B / VRAM display needed (looked up at S3)
    logic [1:0] s4_mw;         // capture B halfword
    assign fill_req[0] = ((s1.v && s1_nm) || (s4.v && s4_nm)) && !m_hit;
    assign fill_req[1] = ((s2.v && s2_nt) || (s4.v && s4_nt)) && !t_hit;
    assign fill_req[2] = s3.v && s3_ne && !e_hit;
    assign fill_blk[0] = m_cur;
    assign fill_blk[1] = t_cur;
    assign fill_blk[2] = e_cur;
    logic pipe_empty;
    assign pipe_empty = !s1.v && !s2.v && !s3.v && !s4.v && !s5.v && !s6.v;
    // texel prefetch: the prefetch pass queues each missing tile-row block
    // (2^PFQW deep, in a RAM) and ends; the pixel pass then overlaps those
    // fills. A pixel-pass miss on the block at the head of the queue takes
    // that entry over; what is left when the layer ends is dropped.
    localparam int PFQW = 5;
    logic             pf_miss, pf_bp, pf_push, pf_pop, pf_take;
    logic [PFQW-1:0]  pf_wp, pf_rp;
    logic [PFQW:0]    pf_n;
    blk_t             pf_rd, pf_byp, pf_head;
    logic             pf_bypv;
    blk_t  pf_last;            // the block queued last (a bitmap row repeats a block)
    logic  pf_lastv;
    assign pf_miss = s2.v && c_pf && !s2.oob && !t_hit && !(pf_lastv && t_cur == pf_last);
    assign pf_bp   = pf_miss && pf_n[PFQW];
    assign pf_push = pf_miss && !stall;
    always_ff @(posedge clk) begin
        if (js == J_SETUP) pf_lastv <= 1'b0;
        else if (pf_push) begin pf_lastv <= 1'b1; pf_last <= t_cur; end
    end
    // taking over the queue head is only a hint; it uses the miss of the last
    // clock so no tag compare reaches the queue's RAM address
    logic  tmiss_q;
    blk_t  tcur_q;
    // (a texel miss stalls in the clock it shows, so t_cur still holds its block)
    always_ff @(posedge clk) tmiss_q <= fill_req[1];
    assign tcur_q = t_cur;
    // the arbiter sees a one-entry register (pfr_*) loaded from the queue
    // head, never the queue RAM (nds-fit #230); it reloads a clock after it
    // empties
    logic  pfr_v;
    blk_t  pfr_blk;
    assign pf_take = tmiss_q && pfr_v && tcur_q == pfr_blk;
    assign pf_pop  = pf_n != 0 && !pfr_v;
    gpu2d_ram #(.W($bits(blk_t)), .AW(PFQW)) u_pfq (
        .clk, .we(pf_push), .waddr(pf_wp), .wdata(t_cur),
        .raddr(pf_pop ? pf_rp + 1'b1 : pf_rp), .rdata(pf_rd));
    assign pf_head = pf_bypv ? pf_byp : pf_rd;
    assign fill_req[3] = pfr_v;
    assign fill_blk[3] = pfr_blk;
    assign stall = |fill_req[2:0] || pf_bp || (s6.v && s6.cw && !cap_ready);
    assign stat_stall = stall;

    // line buffer
    lbe_t        lb_q;
    logic [7:0]  lb_raddr;
    lbe_t        s3_lb;        // its entry for S3 (read at S1, the backdrop for the first layer)
    logic [31:0] s3_l3d;       // the 3D line's pixel for S3 (the 3D pass reads it at S1)
    logic        s3_l3op;      // that pixel's alpha is not 0
    gpu2d_ram #(.W($bits(lbe_t)), .AW(8)) u_lb (
        .clk, .we(s4.v && !stall && c_kind != K_COMP), .waddr(s4.x), .wdata(s4.e),
        .raddr(lb_raddr), .rdata(lb_q));

    function automatic logic [7:0] byte_of(input logic [63:0] w, input logic [2:0] a);
        return w[a*8 +: 8];
    endfunction
    function automatic logic [15:0] hw_of(input logic [63:0] w, input logic [1:0] a);
        return w[a*16 +: 16];
    endfunction
    function automatic blk_t blk_of(input logic [2:0] sp, input logic e, input logic [18:0] a);
        return {sp, e, a[18:5]};
    endfunction

    // ---------------------------------------------------------------- S0
    logic [16:0] t_xpos;
    logic [27:0] fx, fy;
    logic        s0_oob;
    logic [18:0] s0_maddr, s0_taddr, s0_off, s0_sum;
    logic [6:0]  a_tx, a_ty;
    logic [9:0]  b_px, b_py;
    logic [3:0]  xw, yw, ys;
    logic        s0_nm;
    logic [15:0] c3_cb;
    logic        c3_nm;
    always_comb begin
        t_xpos = {1'b0, tx0 + {7'd0, x}} - (c_mos ? {13'd0, mcnt} : 17'd0);
        fx = (c_mos && mcnt != 0) ? hx : rx;
        fy = (c_mos && mcnt != 0) ? hy : ry;
        // affine tiled: map index (ty << (4+size)) | tx
        a_tx = 7'(fx[17:11] & {c_size == 2'd3, c_size >= 2'd2, c_size != 2'd0, 4'hF});
        a_ty = 7'(fy[17:11] & {c_size == 2'd3, c_size >= 2'd2, c_size != 2'd0, 4'hF});
        // bitmaps: pixel bits per axis and the row shift
        case ({c_kind == K_LARGE, c_size})
            3'b000: begin xw = 4'd7;  yw = 4'd7;  ys = 4'd7;  end
            3'b001: begin xw = 4'd8;  yw = 4'd8;  ys = 4'd8;  end
            3'b010: begin xw = 4'd9;  yw = 4'd8;  ys = 4'd9;  end
            3'b011: begin xw = 4'd9;  yw = 4'd9;  ys = 4'd9;  end
            3'b100: begin xw = 4'd9;  yw = 4'd10; ys = 4'd9;  end
            3'b101: begin xw = 4'd10; yw = 4'd9;  ys = 4'd10; end
            3'b110: begin xw = 4'd9;  yw = 4'd8;  ys = 4'd9;  end
            default: begin xw = 4'd9; yw = 4'd9;  ys = 4'd9;  end
        endcase
        b_px = 10'(fx[17:8] & ~(10'h3FF << xw));
        b_py = 10'(fy[17:8] & ~(10'h3FF << yw));
        s0_oob = 1'b0;
        s0_maddr = '0;
        s0_taddr = '0;
        s0_nm = 1'b0;
        // one adder: every kind's offset is a concatenation or an OR of fields
        // in disjoint bits (a_tx < 2^(4+size); b_px < 2^xw, and ys == xw)
        s0_off = '0;
        case (c_kind)
            K_TEXT: begin
                s0_off = {10'd0, t_xpos[7:3], 1'b0} | ((c_wide && t_xpos[8]) ? 19'h800 : 19'd0);
                s0_nm = 1'b1;
            end
            K_AFF, K_EXT16: begin
                s0_oob = oob_of(fx, c_kx) || oob_of(fy, c_ky);
                s0_off = c_kind == K_EXT16 ? ({12'd0, a_ty} << (4'd5 + {2'd0, c_size})) | {11'd0, a_tx, 1'b0}
                                           : ({12'd0, a_ty} << (4'd4 + {2'd0, c_size})) | {12'd0, a_tx};
                s0_nm = !s0_oob;
            end
            K_BMP8, K_BMPD, K_LARGE: begin
                s0_oob = oob_of(fx, c_kx) || oob_of(fy, c_ky);
                s0_off = c_kind == K_BMPD ? ({9'd0, b_py} << (ys + 1)) | {8'd0, b_px, 1'b0}
                                          : ({9'd0, b_py} << ys) | {9'd0, b_px};
            end
            default: ;
        endcase
        s0_sum = c_map + s0_off;
        case (c_kind)
            K_TEXT, K_AFF, K_EXT16: s0_maddr = s0_sum;
            K_BMP8, K_BMPD, K_LARGE: s0_taddr = s0_sum;
            default: ;
        endcase
        // the composite pass looks up capture source B for S3's pixel, checks
        // the miss in S4 and registers the halfword into S5, where the capture
        // uses it (DoCapture: srcB + (offset & 0xFFFF) + x); the other passes
        // look up their map entry for S0's
        c3_cb   = {j_line, s3.x} + (c_dmode != 2'd2 ? {capcnt[27:26], 14'd0} : 16'd0);
        c3_nm   = c_capB && {1'b0, s3.x} < c_capw;
        if (c_kind == K_COMP) begin
            m_ablk  = blk_of(SP_LCDC, j_eng, {st.dispcnt[19:18], c3_cb, 1'b0});
            m_aword = c3_cb[3:2];
        end else begin
            m_ablk  = blk_of(SP_BG, j_eng, s0_maddr & (!j_eng ? 19'h7FFFF : 19'h1FFFF));
            m_aword = s0_maddr[4:3];
        end
    end

    // ---------------------------------------------------------------- S1
    logic [15:0] s1_ent;
    logic [9:0]  s1_num;
    logic [2:0]  s1_row, s1_col;
    logic [18:0] s1_taddr, s1_off, s1_sum;
    logic        s1_nt;
    always_comb begin
        s1_ent = hw_of(m_q, s1_maddr_q[2:1]);
        if (c_kind == K_AFF) s1_ent = {8'd0, byte_of(m_q, s1_maddr_q[2:0])};
        s1_num = s1_ent[9:0];
        s1_row = (c_kind == K_TEXT) ? (s1_ent[11] ? ~c_yfine : c_yfine) : (s1_ent[11] && c_kind == K_EXT16 ? ~s1.yf : s1.yf);
        s1_col = (s1_ent[10] && c_kind != K_AFF) ? ~s1.xf : s1.xf;
        s1_taddr = s1.taddr;
        s1_nt = 1'b0;
        // one adder for the tile base (the offsets are concatenations)
        case (c_kind)
            K_AFF:   s1_off = {3'd0, s1_ent[7:0], s1.yf, s1.xf};
            K_EXT16: s1_off = {3'd0, s1_num, s1_row, s1_col};
            default: s1_off = c_bpp8 ? {3'd0, s1_num, s1_row, s1_col} : {4'd0, s1_num, s1_row, s1_col[2:1]};
        endcase
        s1_sum = c_tile + s1_off;
        case (c_kind)
            K_TEXT: begin
                s1_taddr = s1_sum;
                s1_nt = 1'b1;
            end
            K_AFF:   begin s1_taddr = s1_sum; s1_nt = !s1.oob; end
            K_EXT16: begin s1_taddr = s1_sum; s1_nt = !s1.oob; end
            K_BMP8, K_BMPD, K_LARGE: s1_nt = !s1.oob;
            default: ;
        endcase
        // composite: the VRAM display pixel, likewise looked up for S3's pixel
        if (c_kind == K_COMP) begin
            t_ablk  = blk_of(SP_LCDC, j_eng, {st.dispcnt[19:18], j_line, s3.x, 1'b0});
            t_aword = s3.x[3:2];
        end else begin
            t_ablk  = blk_of(SP_BG, j_eng, s1_taddr & (!j_eng ? 19'h7FFFF : 19'h1FFFF));
            t_aword = s1_taddr[4:3];
        end
    end

    // ---------------------------------------------------------------- S2
    // window mask (GPU2D::CalculateWindowMask), per pixel in closed form
    function automatic logic hwin(input logic s0, input logic [7:0] x1, input logic [7:0] x2, input logic [7:0] i);
        if (x2 <= i && (x2 >= x1 || x1 > i)) return 1'b0;
        if (x1 <= i) return 1'b1;
        return s0;
    endfunction
    logic [7:0]  s2_byte;
    logic [7:0]  s2_ci;        // colour index
    logic [15:0] s2_hw;
    logic        s2_op, s2_direct, s2_ext;
    logic [8:0]  s2_palh;      // palette halfword within the engine's 512
    logic [14:0] s2_eaddr;
    logic [1:0]  s2_win;
    logic [5:0]  s2_wmask;
    always_comb begin
        s2_byte = byte_of(t_q, s2.taddr[2:0]);
        s2_hw   = hw_of(t_q, s2.taddr[2:1]);
        s2_ci   = (c_kind == K_TEXT && !c_bpp8) ? {4'd0, s2.hi ? s2_byte[7:4] : s2_byte[3:0]} : s2_byte;
        s2_direct = c_kind == K_BMPD;
        s2_op   = !s2.oob && (s2_direct ? s2_hw[15] : s2_ci != 8'd0);
        s2_ext  = c_ext;
        s2_palh = (c_kind == K_TEXT && !c_bpp8) ? {1'b0, s2.pal, s2_ci[3:0]} : {1'b0, s2_ci};
        s2_eaddr = {c_slot, (c_kind == K_TEXT || c_kind == K_EXT16) ? s2.pal : 4'd0, s2_ci, 1'b0};
        e_ablk  = blk_of(SP_BGEXT, j_eng, {4'd0, s2_eaddr});
        // the window hits depend only on x and the job's window registers, so
        // they are taken a stage early (timing: win1 -> s4.kb, #466)
        s2_win[0] = st.w0act[0] && hwin(st.w0act[1], st.win0[0], st.win0[1], s2.x);
        s2_win[1] = st.w1act[0] && hwin(st.w1act[1], st.win1[0], st.win1[1], s2.x);
        e_aword = s2_eaddr[4:3];
        // window (st is constant during the job)
        if (st.dispcnt[15:13] == 3'd0) s2_wmask = 6'h3F;
        else begin
            s2_wmask = 6'(st.wincnt[2]);
            if (st.dispcnt[15] && olb_rdata[28]) s2_wmask = 6'(st.wincnt[3]);
            if (st.dispcnt[14] && s2_win[1]) s2_wmask = 6'(st.wincnt[1]);
            if (st.dispcnt[13] && s2_win[0]) s2_wmask = 6'(st.wincnt[0]);
        end
    end

    // ---------------------------------------------------------------- S3

    logic [28:0] ob;          // OBJ entry after mosaic
    logic [28:0] ob_lat;
    logic [3:0]  omx;
    logic        ob_latch;
    logic [5:0]  wmask;       // (registered with s3_olb: s3_win -> wmask -> s3_e -> s4.ka/kb, #1329 -0.08 ns)
    logic [15:0] s3_col;
    logic [17:0] s3_c18;
    px_t         s3_bg;
    logic        s3_bgop, s3_pre, objq;
    lbe_t        s3_in, s3_e;
    always_comb begin
        // OBJ X mosaic (SoftRenderer2D::ApplySpriteMosaicX), left to right
        ob_latch = omx == 4'd0 || !s3_olb[24] || !ob_lat[24] || s3_olb[26:25] < ob_lat[26:25];
        ob = (!MOSAIC || st.obj_mos_w == 4'd0 || ob_latch) ? s3_olb : ob_lat;
        // BG colour
        s3_col = s3.direct ? {1'b0, s3.dcol[14:0]} : s3.ext ? hw_of(e_q, s3_eaddr_q[2:1])
                                                       : (s3.pal_hi ? pal_rdata[31:16] : pal_rdata[15:0]);
        s3_c18 = c15to18(s3_col);
        if (c_3d) begin
            s3_bg = {s3_l3d[21:16], s3_l3d[13:8], s3_l3d[5:0], s3_l3d[31:24] | 8'h40};
            s3_bgop = s3_l3op && wmask[0];
        end else begin
            s3_bg = {s3_c18, 8'd1 << c_bg};
            s3_bgop = s3.op && wmask[c_bg];
        end
        s3_in = s3_lb;
        objq = st.layer_enable[4] && ob[27] && wmask[4];
        s3_pre = !s3_in.done && objq && (c_comp || ob[26:25] > c_prio);
        s3_e = s3_in;
        if (s3_pre) begin
            s3_e.sec = s3_e.top;
            s3_e.top = px_t'({c15to18(ob[15:0]), ob[23:16]});
            s3_e.done = 1'b1;
        end
        if (!c_comp && s3_bgop) begin
            s3_e.sec = s3_e.top;
            s3_e.top = s3_bg;
        end
    end

    // ---------------------------------------------------------------- S4: colour effects
    // ColorComposite: every effect is (a*ka + b*kb + 16) >> 5 per channel. The
    // factors are chosen from S3's pixel (s3_e, wmask) and registered into s4,
    // so S4 holds only the multiply (timing: n_scr/bldcnt -> o2d, #464); the
    // blend registers (n_scr, n_x) only change between passes, so S3 and S4
    // see the same values
    function automatic logic [5:0] ch(input logic [17:0] c, input int i);
        return c[i*6 +: 6];
    endfunction
    logic [7:0]  f1, f2;
    logic        t2, t2_sec, t2_top, t2_ob;
    logic [5:0]  ka, kb;
    function automatic logic t2_of(input logic [7:0] f, input logic [13:0] cnt);
        return f[7] ? cnt[12] : f[6] ? cnt[8] : |(cnt[13:8] & f[5:0]);
    endfunction
    logic        b63;       // brightness up: b = 63
    logic [17:0] eff;
    logic [2:0][12:0] esum;
    logic [17:0] o2d;
    always_comb begin
        f1 = s3_e.top.f; f2 = s3_e.sec.f;
        // t2 for each pixel S3 can make second, chosen by S3's own selects
        // (the same value as from f2, a level shorter)
        t2_sec = t2_of(s3_in.sec.f, bldcnt); t2_top = t2_of(s3_in.top.f, bldcnt); t2_ob = t2_of(ob[23:16], bldcnt);
        t2 = (!c_comp && s3_bgop) ? (s3_pre ? t2_ob : t2_top) : (s3_pre ? t2_top : t2_sec);
        ka = 6'd32; kb = 6'd0; b63 = 1'b0;
        if (f1[7] && t2) begin
            if (f1[6]) begin ka = {f1[4:0], 1'b0}; kb = 6'(6'd32 - {f1[4:0], 1'b0}); end
            else       begin ka = {c_eva, 1'b0};  kb = {c_evb, 1'b0}; end
        end else if (f1[6] && t2) begin
            ka = {1'b0, f1[4:0]} + 6'd1;
            kb = 6'(6'd32 - ka);
        end else if (|(bldcnt[5:0] & (f1[7] ? 6'h10 : f1[6] ? 6'h01 : f1[5:0])) && wmask[5]) begin
            case (bldcnt[7:6])
                2'd1: if (t2) begin ka = {c_eva, 1'b0}; kb = {c_evb, 1'b0}; end
                2'd2: begin ka = 6'(6'd32 - {c_evy, 1'b0}); kb = {c_evy, 1'b0}; b63 = 1'b1; end
                2'd3: ka = 6'(6'd32 - {c_evy, 1'b0});
                default: ;
            endcase
        end
    end
    always_comb begin
        for (int i = 0; i < 3; i++) begin
            esum[i] = 13'(ch(s4.e.top.c, i) * s4.ka) + 13'((s4.b63 ? 6'd63 : ch(s4.e.sec.c, i)) * s4.kb) + 13'd16;
            eff[i*6 +: 6] = esum[i][12:5] > 8'd63 ? 6'd63 : esum[i][10:5];
        end
        if (!st.enabled)          o2d = j_eng ? 18'h3FFFF : 18'h0;
        else if (st.forced_blank) o2d = 18'h3FFFF;
        else                      o2d = eff;
    end

    // ---------------------------------------------------------------- S5: display, master brightness, capture
    function automatic logic [17:0] c15to18n(input logic [15:0] c);   // VRAM/FIFO display: no bit-15 green
        return {c[14:10], 1'b0, c[9:5], 1'b0, c[4:0], 1'b0};
    endfunction
    logic [17:0] disp, mb;
    logic        white;
    logic [4:0]  mbf;
    logic [15:0] ca, cb, cw;
    logic [4:0]  ceva, cevb;
    logic        cbnull;
    logic [2:0][10:0] msum, csum;
    always_comb begin
        white = 1'b0;
        disp = s5.o2d;
        if (!j_eng) case (st.dispcnt[17:16])
            2'd0: white = 1'b1;
            2'd2: disp = lcdc_map[st.dispcnt[19:18]] ? c15to18n(s5.vdisp) : 18'd0;
            2'd3: disp = c15to18n(s5.fifo);
            default: ;
        endcase
        else if (!st.dispcnt[16]) white = 1'b1;
        mbf = mbright[4:0] > 5'd16 ? 5'd16 : mbright[4:0];
        for (int i = 0; i < 3; i++) begin
            case (mbright[15:14])
                2'd1: msum[i] = 11'(ch(disp, i) * (5'd16 - mbf)) + 11'({mbf, 6'd0} - mbf);
                2'd2: msum[i] = 11'(ch(disp, i) * (5'd16 - mbf));
                default: msum[i] = {1'b0, ch(disp, i), 4'd0};
            endcase
            mb[i*6 +: 6] = msum[i][9:4];
        end
        if (white) mb = 18'h3FFFF;
        // capture (DoCapture)
        if (capcnt[24]) ca = {s5.c3d[22:15] != 8'd0, s5.c3d[14:0]};
        else            ca = {1'b1, s5.o2d[17:13], s5.o2d[11:7], s5.o2d[5:1]};
        cbnull = !capcnt[25] && !lcdc_map[st.dispcnt[19:18]];
        cb = capcnt[25] ? s5.fifo : cbnull ? 16'd0 : s5.capb;
        ceva = capcnt[4:0] > 5'd16 ? 5'd16 : capcnt[4:0];
        cevb = capcnt[12:8] > 5'd16 ? 5'd16 : capcnt[12:8];
        case (capcnt[30:29])
            2'd0: cw = ca;
            2'd1: cw = cb;
            default: begin
                for (int i = 0; i < 3; i++) begin
                    csum[i] = 11'(ca[i*5 +: 5] * (ca[15] ? ceva : 5'd0)) + 11'(cb[i*5 +: 5] * (cb[15] ? cevb : 5'd0)) + 11'd8;
                    cw[i*5 +: 5] = csum[i][10:4] > 7'd31 ? 5'd31 : csum[i][8:4];
                end
                cw[15] = (ceva != 0 && ca[15]) || (cevb != 0 && cb[15]);
            end
        endcase
    end

    // ---------------------------------------------------------------- sequencing
    // the RAM read of a just-written head is not ready yet: bypass it
    always_ff @(posedge clk) begin
        pf_bypv <= pf_push && (pf_n == 0 || (pf_n == 1 && pf_pop));
        pf_byp  <= t_cur;
        if (rst || (js == J_DRAIN && pipe_empty && !c_pf)) begin
            pf_wp <= '0; pf_rp <= '0; pf_n <= '0; pf_bypv <= 1'b0; pfr_v <= 1'b0;
        end else begin
            if (pf_pop) begin pfr_v <= 1'b1; pfr_blk <= pf_head; end
            else if (pf_ack || pf_take) pfr_v <= 1'b0;
            if (pf_push) pf_wp <= pf_wp + 1'b1;
            if (pf_pop)  pf_rp <= pf_rp + 1'b1;
            pf_n <= pf_n + (pf_push ? 1'b1 : 1'b0) - (pf_pop ? 1'b1 : 1'b0);
        end
    end
    // (WST_RF) look-ahead: from the start of the job (pre) and from the
    // start of each layer's own pass, scan the plan order on from the layer
    // after the current one (the order depends on state that is constant for
    // the job) and read the next layer's four words into n_*, one a clock
    // where the port is free. The plan scan reaches that layer no earlier
    // than the reads are done: at the job start they overlap the 21-clock
    // load, later they overlap a pass of at least 256 clocks.
    logic [4:0]  la_k;
    logic        la_on;
    logic [1:0]  la_bg;
    logic [2:0]  f_n;          // reads still to issue (4..1), 0 = none
    logic        la_comp;      // no layer left: the composite pass's words 18, 19 into n_scr, n_x
    logic        f_v;          // a read was taken last clock
    logic [1:0]  f_w;          // which word it was
    logic [15:0] la_cnt;
    logic [3:0]  la_kind;
    logic        la_ok;
    always_comb begin
        la_cnt  = st.bgcnt[la_k[1:0]];
        la_kind = kind_of(la_k[1:0], mode, bg0_3d, la_cnt);
        la_ok   = !la_k[4] && la_kind[3] && st.layer_enable[la_k[1:0]] && la_cnt[1:0] == la_k[3:2]
                  && st.enabled && !st.forced_blank;
        if (la_comp) rf_raddr = f_n == 3'd2 ? 5'd18 : 5'd19;
        else case (3'd4 - f_n)
            3'd0:    rf_raddr = 5'd3 + {3'd0, la_bg};
            3'd1:    rf_raddr = 5'd7 + {3'd0, la_bg[0], 1'b0};
            3'd2:    rf_raddr = 5'd8 + {3'd0, la_bg[0], 1'b0};
            default: rf_raddr = 5'd11 + {4'd0, la_bg[0]};
        endcase
    end
    always_ff @(posedge clk) begin
        f_v <= 1'b0;
        if (rst || !WST_RF) begin la_on <= 1'b0; f_n <= 3'd0; end
        else begin
            if (pre) begin la_on <= 1'b1; la_k <= 5'd15; f_n <= 3'd0; la_comp <= 1'b0; end
            else if (js == J_SETUP && !c_pf && !plan_k[4]) begin la_on <= 1'b1; la_k <= plan_k - 5'd1; f_n <= 3'd0; la_comp <= 1'b0; end
            else if (la_on) begin
                if (la_ok) begin la_on <= 1'b0; la_bg <= la_k[1:0]; f_n <= 3'd4; end
                else if (la_k[4]) begin la_on <= 1'b0; la_comp <= 1'b1; f_n <= 3'd2; end
                else la_k <= la_k - 5'd1;
            end else if (f_n != 3'd0 && rf_free) begin
                f_n <= f_n - 3'd1; f_v <= 1'b1;
                f_w <= la_comp ? (f_n == 3'd2 ? 2'd0 : 2'd1) : 2'(3'd4 - f_n);
            end
            if (f_v) case (f_w)
                2'd0: n_scr <= rf_rdata;
                2'd1: n_x <= rf_rdata;
                2'd2: n_y <= rf_rdata;
                default: n_rr <= rf_rdata;
            endcase
        end
    end
`ifndef SYNTHESIS
    // synthesis translate_off
    // the next set must be this layer's, complete, when the plan scan finds it
    always_ff @(posedge clk)
        if (WST_RF && !rst && js == J_PLAN && (pk_ok || plan_k[4])
            && (la_on || f_n != 3'd0 || f_v || (pk_ok ? la_bg != pk_bg || la_comp : !la_comp)))
            $error("gpu2d_bg: WST_RF look-ahead not ready (plan_k %0d la_on %b f_n %0d la_bg %0d comp %b)", plan_k, la_on, f_n, la_bg, la_comp);
    // synthesis translate_on
`endif

    logic issue;
    assign issue = js == J_RUN && (c_pf ? x <= 9'd256 : !x[8]);
    assign busy = js != J_IDLE;
    // caches start a new generation per job, or with PERSIST only after VRAM
    // (or this unit's own capture) was written since the last one
    logic dirty;
    assign cclear = js == J_INIT && (!PERSIST || dirty);
    always_ff @(posedge clk)
        if (rst) dirty <= 1'b1;
        else if (vram_wr || (cap_we && cap_ready)) dirty <= 1'b1;
        else if (cclear) dirty <= 1'b0;

    // RAM read addresses (held by the RAMs' own address mux while stalled)
    logic [8:0] pal_a_q;
    logic [7:0] lb_a_q, l3_a_q, ff_a_q;
    logic [8:0] olb_a_q;
    logic [8:0] pal_a_n;
    assign pal_a_n = (js == J_INIT) ? {j_eng, 8'd0} : {j_eng, s2_palh[8:1]};
    always_comb begin
        pal_raddr = stall ? pal_a_q : pal_a_n;
        // the line buffer is read a stage early too and registered into S3
        // (timing: u_lb -> s4.ka, #1509 -0.39 ns): a pass reads each x once,
        // before that pixel's own S4 write, and the passes do not overlap
        lb_raddr  = stall ? lb_a_q  : s1.x;
        // the OBJ line buffer is read a stage early (S1 for S2) and registered
        // into S3, so S3's OBJ alpha into the blend factors starts at a flop
        // (timing: u_olb -> s4.ka, #474). Each entry is cleared at S4 by its
        // own pixel, after this read
        olb_raddr = stall ? olb_a_q : {j_eng, s1.x};
        // the 3D pass reads the line at S1, registered into S3 (timing: the
        // ring's RAM -> s4.ka, #1511 -1.28 ns); the composite pass reads it at
        // S3, registered into S5 for capture source A (the passes do not
        // overlap in the pipeline: c_kind holds S1..S4)
        l3d_raddr = stall ? l3_a_q  : c_kind == K_COMP ? s3.x : s1.x;
        fifo_raddr = stall ? ff_a_q : s2.x;
    end

    always_ff @(posedge clk) begin
        pal_a_q <= pal_raddr; lb_a_q <= lb_raddr; olb_a_q <= olb_raddr;
        l3_a_q <= l3d_raddr; ff_a_q <= fifo_raddr;
        done <= 1'b0;
        if (rst) begin
            js <= J_IDLE;
            s1.v <= 1'b0; s2.v <= 1'b0; s3.v <= 1'b0; s4.v <= 1'b0; s5.v <= 1'b0; s6.v <= 1'b0;
        end else begin
            case (js)
                J_IDLE: if (start) begin
                    js <= J_INIT; j_eng <= eng; j_line <= line; j_slot <= objslot;
                end
                J_INIT: js <= J_BACK;              // caches clear, backdrop read issued
                J_BACK: begin                      // backdrop arrives
                    backdrop <= c15to18(pal_rdata[15:0]);
                    first <= 1'b1;
                    plan_k <= 5'd15;
                    js <= J_PLAN;
                end
                J_PLAN: begin
                    if (pk_ok) begin
                        c_kind <= kind_t'(pk_kind[2:0]);
                        c_comp <= kind_t'(pk_kind[2:0]) == K_COMP;
                        c_3d <= kind_t'(pk_kind[2:0]) == K_3D;
                        c_pf <= PREFETCH && kind_t'(pk_kind[2:0]) != K_3D;
                        c_mos <= MOSAIC && pk_cnt[6] && st.bg_mos_w != 4'd0;
                        c_ext <= st.dispcnt[30] && ((kind_t'(pk_kind[2:0]) == K_TEXT && pk_cnt[7]) || kind_t'(pk_kind[2:0]) == K_EXT16);
                        c_slot <= (kind_t'(pk_kind[2:0]) == K_TEXT && !pk_bg[1] && pk_cnt[13]) ? {1'b1, pk_bg[0]} : pk_bg;
                        c_map <= kind_t'(pk_kind[2:0]) == K_TEXT ? t_map
                               : (kind_t'(pk_kind[2:0]) == K_BMP8 || kind_t'(pk_kind[2:0]) == K_BMPD) ? {pk_cnt[12:8], 14'd0}
                               : kind_t'(pk_kind[2:0]) == K_LARGE ? 19'd0 : a_map;
                        c_yfine <= t_yoff[2:0];
                        if (WST_RF) begin
                            tx0 <= n_scr[15:0];
                            rx <= n_x[27:0]; ry <= n_y[27:0];
                            ra <= n_rr[15:0]; rc <= n_rr[31:16];
                        end else begin
                            tx0 <= st.bgxpos[pk_bg];
                            rx <= st.xref[pk_bg[0]][27:0]; ry <= st.yref[pk_bg[0]][27:0];
                            ra <= st.rota[pk_bg[0]]; rc <= st.rotc[pk_bg[0]];
                        end
                        js <= J_SETUP;
                    end else if (plan_k[4]) begin
                        c_kind <= K_COMP;
                        c_comp <= 1'b1;
                        c_3d <= 1'b0;
                        c_pf <= 1'b0;
                        c_dmode <= j_eng ? {1'b0, st.dispcnt[16]} : st.dispcnt[17:16];
                        c_capline <= cap_hit;
                        c_capw <= cap_sz == 2'd0 ? 9'd128 : 9'd256;
                        c_capB <= cap_hit && capcnt[30:29] != 2'd0 && !capcnt[25] && lcdc_map[st.dispcnt[19:18]];
                        c_vdisp <= !j_eng && st.dispcnt[17:16] == 2'd2 && lcdc_map[st.dispcnt[19:18]];
                        c_cap3d <= capcnt[24];
                        c_mos <= 1'b0;
                        js <= J_SETUP;
                    end
                    if (!pk_ok && !plan_k[4]) plan_k <= plan_k - 5'd1;
                end
                J_SETUP: begin
                    x <= 9'd0; mcnt <= 4'd0; omx <= 4'd0;
                    // again after a prefetch pass
                    if (WST_RF) begin rx <= n_x[27:0]; ry <= n_y[27:0]; end
                    else begin rx <= st.xref[c_bg[0]][27:0]; ry <= st.yref[c_bg[0]][27:0]; end
                    js <= J_RUN;
                end
                J_RUN: if (!stall && !issue) js <= J_DRAIN;
                J_DRAIN: if (pipe_empty) begin
                    if (c_pf) begin c_pf <= 1'b0; js <= J_SETUP; end   // now the layer itself
                    else if (c_kind == K_COMP) begin js <= J_IDLE; done <= 1'b1; end
                    else begin
                        first <= 1'b0;
                        plan_k <= plan_k - 5'd1;
                        js <= J_PLAN;
                    end
                end
                default: js <= J_IDLE;
            endcase

            if (!stall) begin
                // S0 -> S1
                s1.v <= issue;
                s1.x <= x[7:0];
                s1.oob <= s0_oob;
                s1.xf <= c_kind == K_TEXT ? t_xpos[2:0] : fx[10:8];
                s1.yf <= fy[10:8];
                s1.taddr <= s0_taddr;
                s1_nm <= s0_nm;
                s1_maddr_q <= s0_maddr;
                // a prefetch pass samples one pixel in 8 (x = 0..256): one adder
                // per axis, the step scaled by 8 there
                if (issue) begin
                    x <= x + (c_pf ? 9'd8 : 9'd1);
                    rx <= rx + (c_pf ? {{9{ra[15]}}, ra, 3'd0} : {{12{ra[15]}}, ra});
                    ry <= ry + (c_pf ? {{9{rc[15]}}, rc, 3'd0} : {{12{rc[15]}}, rc});
                end
                if (issue && !c_pf) begin
                    mcnt <= mcnt == st.bg_mos_w ? 4'd0 : mcnt + 4'd1;
                    if (mcnt == 4'd0) begin hx <= rx; hy <= ry; end
                end
                // S1 -> S2
                s2.v <= s1.v;
                s2.x <= s1.x;
                s2.oob <= s1.oob;
                s2.taddr <= s1_taddr;
                s2.hi <= s1_col[0];
                s2.pal <= s1_ent[15:12];
                s2_nt <= s1_nt && s1.v && !c_pf;
                // S2 -> S3
                s3.v <= s2.v && !c_pf;
                s3.x <= s2.x;
                s3.op <= s2_op;
                s3.direct <= s2_direct;
                s3.pal_hi <= s2_palh[0];
                s3.ext <= s2_ext && !s2_direct;
                s3.dcol <= s2_hw;
                s3_ne <= s2.v && s2_ext && !s2_direct && s2_op && c_kind != K_COMP && c_kind != K_3D;
                s3_eaddr_q <= s2_eaddr;
                wmask <= s2_wmask;
                s3_olb <= olb_rdata;
                s3_lb <= first ? lbe_t'({backdrop, 8'h20, 26'd0, 1'b0}) : lb_q;
                s3_l3d <= l3d_rdata;
                s3_l3op <= l3d_rdata[31:24] != 8'd0;
                // S3 -> S4
                s4.v <= s3.v;
                s4.x <= s3.x;
                s4_nm <= c3_nm && s3.v && c_kind == K_COMP;
                s4_nt <= c_vdisp && s3.v && c_kind == K_COMP;
                s4_mw <= c3_cb[1:0];
                s4.e <= s3_e;
                s4.ka <= ka; s4.kb <= kb; s4.b63 <= b63;
                s4.fifo <= fifo_rdata;
                if (s3.v) begin
                    omx <= omx == st.obj_mos_w ? 4'd0 : omx + 4'd1;
                    ob_lat <= ob;
                end
                // S4 -> S5 (composite only)
                s5.v <= s4.v && c_kind == K_COMP;
                s5.x <= s4.x;
                s5.o2d <= o2d;
                s5.c3d <= {l3d_rdata[31:24], l3d_rdata[21:17], l3d_rdata[13:9], l3d_rdata[5:1]};
                s5.vdisp <= hw_of(t_q, s4.x[1:0]);
                s5.capb <= hw_of(m_q, s4_mw);
                s5.fifo <= s4.fifo;
                // S5 -> S6
                s6.v <= s5.v;
                s6.x <= s5.x;
                s6.rgb <= mb;
                s6.cw <= s5.v && c_capline && {1'b0, s5.x} < c_capw;
                s6.cdata <= cw;
            end
        end
    end

    // OBJ line buffer clear: the composite pass is its last reader
    assign olb_we    = s4.v && !stall && c_kind == K_COMP;
    assign olb_waddr = {j_eng, s4.x};

    assign out_valid = s6.v && !stall;
    assign out_eng   = j_eng;
    assign out_x     = s6.x;
    assign out_rgb   = s6.rgb;
    assign cap_we    = s6.v && s6.cw && !(|fill_req[2:0]) && !pf_bp;
    assign cap_addr  = {capcnt[17:16], 16'({capcnt[19:18], 14'd0} + (c_capw[8] ? {j_line, 8'd0} : {1'b0, j_line, 7'd0}) + {8'd0, s6.x})};
    assign cap_data  = s6.cdata;
endmodule
