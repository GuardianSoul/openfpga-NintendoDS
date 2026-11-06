// NDS 2D engine, OBJ side: renders the OBJ line one line ahead into an OBJ
// line buffer, pixel-exact against melonDS's SoftRenderer2D::DrawSprites
// (DrawSprite_Normal/_Rotscale, DrawSpritePixel). See docs/2d-engine.md.
//
// A job is one engine-line: OAM is scanned one entry per clock; each OBJ on
// the line gets a short setup (affine: four parameter reads into one shared
// multiplier), then its pixels at one per clock through P0 (texel address)
// -> P1 (texel cache; palette RAM or ext-palette cache, line-buffer read)
// -> P2 (colour, priority read-modify-write). The pipeline drains between
// OBJs so two OBJs never race on one line-buffer entry.
//
// Unlike melonDS the palette is looked up here, not when the line is
// composited; the result differs only if the palette changes in the line
// between the two (docs/2d-engine.md).
module gpu2d_obj
    import gpu2d_pkg::*;
#(
    parameter bit PERSIST  = 0,
    parameter int TEX_IDXW = 6,
    parameter int EXT_IDXW = 6,
    parameter bit MOSAIC   = 1,
    parameter bit EXT_TAG_MLAB = 0   // ext-palette cache tags in its data words (gpu2d_cache TAG_DATA)
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic        clr,         // the line buffer still holds an unread line: clear it first
    input  logic        eng,
    input  logic [7:0]  line,        // the line being prepared
    output logic        busy,
    output logic        done,
    input  eng_state_t  st,
    input  logic        vram_wr,
    // fills: 0 texel, 1 ext palette
    output logic [2:0]  fill_req,    // [2]: texel prefetch, never stalls
    output blk_t [2:0]  fill_blk,
    input  logic        pf_ack,
    input  logic [1:0]  fill_we,
    input  blk_t        fill_fblk,
    input  logic [1:0]  fill_beat,
    input  logic        fill_last,
    input  logic [63:0] fill_data,
    output logic [7:0]  oam_raddr,   // {engine, entry}
    input  logic [63:0] oam_rdata,
    output logic [8:0]  pal_raddr,
    input  logic [31:0] pal_rdata,
    output logic [8:0]  olb_raddr,   // {engine, x}
    input  logic [28:0] olb_rdata,
    output logic        olb_we,
    output logic [8:0]  olb_waddr,
    output logic [28:0] olb_wdata,
    output logic        stat_stall
);
    typedef enum logic [3:0] {O_IDLE, O_CLR, O_INIT, O_PREQ, O_PSCAN, O_PBASE, O_PPUSH, O_REQ, O_SCAN, O_BASE, O_AFF, O_DRAW, O_DRAIN} ost_t;
    ost_t        os;
    logic        j_eng;
    logic [7:0]  j_line;
    logic [6:0]  n;
    logic        stall;

    // ---------------------------------------------------------------- OAM entry decode
    logic [15:0] a0, a1, a2;
    logic [1:0]  e_type;
    logic        e_win;
    logic [6:0]  e_w, e_h;       // 8..64
    logic [7:0]  e_bw, e_bh;     // bound size
    logic [7:0]  e_yy, e_ym, e_ypos;
    logic signed [9:0] e_xpos;
    logic        e_on, e_skip;
    always_comb begin
        a0 = oam_rdata[15:0]; a1 = oam_rdata[31:16]; a2 = oam_rdata[47:32];
        e_type = a0[9:8];
        e_win  = a0[11:10] == 2'd2;
        case ({a1[15:14], a0[15:14]})
            4'h0: begin e_w = 7'd8;  e_h = 7'd8;  end
            4'h1: begin e_w = 7'd16; e_h = 7'd8;  end
            4'h2: begin e_w = 7'd8;  e_h = 7'd16; end
            4'h4: begin e_w = 7'd16; e_h = 7'd16; end
            4'h5: begin e_w = 7'd32; e_h = 7'd8;  end
            4'h6: begin e_w = 7'd8;  e_h = 7'd32; end
            4'h8: begin e_w = 7'd32; e_h = 7'd32; end
            4'h9: begin e_w = 7'd32; e_h = 7'd16; end
            4'hA: begin e_w = 7'd16; e_h = 7'd32; end
            4'hC: begin e_w = 7'd64; e_h = 7'd64; end
            4'hD: begin e_w = 7'd64; e_h = 7'd32; end
            4'hE: begin e_w = 7'd32; e_h = 7'd64; end
            default: begin e_w = 7'd8; e_h = 7'd8; end
        endcase
        e_bw = e_type == 2'd3 ? {e_w, 1'b0} : {1'b0, e_w};
        e_bh = e_type == 2'd3 ? {e_h, 1'b0} : {1'b0, e_h};
        e_yy = j_line - a0[7:0];
        e_xpos = {a1[8], a1[8:0]};
        e_on = e_type != 2'd2 && {1'b0, e_yy} < {1'b0, e_bh} && (e_xpos + $signed({2'b0, e_bw})) > 0;
        e_ym = st.obj_mos_line - a0[7:0];
        e_ypos = (MOSAIC && a0[12] && !e_win) ? ({1'b0, e_ym} >= {1'b0, e_bh} ? 8'd0 : e_ym) : e_yy;
        // bitmap OBJs with alpha 0, and bitmap OBJs in the reserved mode, draw nothing
        e_skip = !e_win && a0[11:10] == 2'd3 && (a2[15:12] == 4'd0 || (st.dispcnt[6] && st.dispcnt[5]));
    end

    // ---------------------------------------------------------------- per-OBJ registers
    logic        o_aff, o_win, o_bmp, o_bpp8, o_ext, o_xflip;
    logic [1:0]  o_prio;
    logic        o_mos;
    logic [7:0]  o_flag;
    logic [3:0]  o_pal;
    logic [6:0]  o_w, o_h;
    logic [7:0]  o_xo, o_xend;      // sprite-local x, end
    logic [7:0]  o_sx;              // screen x
    logic [17:0] o_base;            // OBJ VRAM byte address of the row / sprite
    logic [3:0]  o_ysh;             // affine: row shift
    logic signed [26:0] o_rx, o_ry;
    logic signed [15:0] o_pa, o_pc;
    logic signed [8:0]  o_dx, o_dy;
    logic [2:0]  o_k;               // affine parameter step
    logic [17:0] o_mask;
    logic [17:0] o_mask_n;
    assign o_mask_n = j_eng ? 18'h1FFFF : 18'h3FFFF;

    // base addresses (DrawSprite_Normal / DrawSprite_Rotscale)
    logic [7:0]  yp;
    logic [17:0] tb;                // tiled: tile-number base in 32-byte units
    logic [17:0] bb;                // bitmap base
    logic [3:0]  wl;                // log2(w / 8)
    logic        bpp8;
    always_comb begin
        bpp8 = a0[13];
        wl = e_w[6] ? 4'd3 : e_w[5] ? 4'd2 : e_w[4] ? 4'd1 : 4'd0;
        yp = (e_type[0] == 1'b0 && a1[13]) ? 8'({1'b0, e_h} - 8'd1 - e_ypos) : e_ypos;
        tb = st.dispcnt[4] ? ({8'd0, a2[9:0]} << st.dispcnt[21:20]) : {8'd0, a2[9:0]};
        if (st.dispcnt[6])      bb = {8'd0, a2[9:0]} << (4'd7 + {3'd0, st.dispcnt[22]});
        else if (st.dispcnt[5]) bb = {9'd0, a2[4:0], 4'd0} + {1'b0, a2[9:5], 12'd0};
        else                    bb = {10'd0, a2[3:0], 4'd0} + {1'b0, a2[9:4], 11'd0};
    end

    // the row's texel address of a normal OBJ (DrawSprite_Normal), and the
    // 32-byte blocks the row covers, for the prefetch scan
    // The scans register the decoded pieces (d_*) and the row base is formed
    // from them a clock later: OAM -> y test -> flip -> shift -> add in one
    // clock missed 67 MHz (nds-fit #225, #227).
    logic        e_bmp;
    assign e_bmp = a0[11:10] == 2'd3 && !e_win;
    logic [7:0]  d_yp;
    logic [17:0] d_b;               // the bitmap base (d_bmp) or the tile-number base
    logic [3:0]  d_wl;
    logic        d_bmp, d_bpp8;
    logic [6:0]  d_w;
    always_ff @(posedge clk) begin
        d_yp <= yp; d_b <= e_bmp ? bb : tb; d_wl <= wl; d_bmp <= e_bmp; d_bpp8 <= a0[13]; d_w <= e_w;
    end
    logic [17:0] e_base, e_row, e_sum;
    logic [3:0]  e_nblk;
    always_comb begin
        // the bitmap and tiled bases share the first adder
        if (d_bmp) e_row = st.dispcnt[6] ? {10'd0, d_yp} << (d_wl + 4'd4) : {10'd0, d_yp} << (st.dispcnt[5] ? 4'd9 : 4'd8);
        else       e_row = st.dispcnt[4] ? ({13'd0, d_yp[7:3]} << (d_wl + {3'd0, d_bpp8})) : {8'd0, d_yp[7:3], 5'd0};
        e_sum = d_b + e_row;
        if (d_bmp) e_base = e_sum;
        else       e_base = (e_sum << 5) + (d_bpp8 ? {12'd0, d_yp[2:0], 3'd0} : {13'd0, d_yp[2:0], 2'd0});
        // tiled: one block per 8-pixel tile; bitmap: the blocks of w*2 bytes
        e_nblk = d_bmp ? 4'(((e_base & 18'h1F) + {10'd0, d_w, 1'b0} - 18'd1) >> 5) + 4'd1 : {1'b0, d_w[6:3]};
    end

    // ---------------------------------------------------------------- caches
    logic dirty, cclear;
    assign cclear = os == O_INIT && (!PERSIST || dirty);
    always_ff @(posedge clk)
        if (rst) dirty <= 1'b1;
        else if (vram_wr) dirty <= 1'b1;
        else if (cclear) dirty <= 1'b0;
    blk_t        t_ablk, e_ablk;
    logic [1:0]  t_aword, e_aword;
    logic [63:0] t_q, e_q;
    logic        t_hit, e_hit;
    blk_t        t_cur, e_cur;
    logic [1:0]  t_curw, e_curw;
    // one generation and scrub counter for this side's caches (gpu2d_cgen)
    // (the ext-palette cache with its tag in the data words scrubs words: EXT_IDXW + 2 bits)
    localparam int ESW = EXT_TAG_MLAB ? EXT_IDXW + 2 : EXT_IDXW;
    localparam int CSW = (TEX_IDXW > ESW ? TEX_IDXW : ESW);
    logic [9:0]     c_gen;
    logic [CSW-1:0] c_scrub, c_scrub_q;
    logic           c_scrub_v;
    gpu2d_cgen #(.SW(CSW)) u_cgen (.clk, .clear(cclear), .idle(os == O_IDLE), .gen(c_gen), .scrub(c_scrub),
        .scrub_q(c_scrub_q), .scrub_v(c_scrub_v));
    gpu2d_cache #(.IDXW(TEX_IDXW)) u_tc (.clk, .idle(os == O_IDLE), .gen(c_gen), .scrub(c_scrub[TEX_IDXW-1:0]),
        .scrub_q(c_scrub_q[TEX_IDXW-1:0]), .scrub_v(c_scrub_v), .hold(stall), .a_blk(t_ablk), .a_word(t_aword),
        .q(t_q), .hit(t_hit), .cur_blk(t_cur), .cur_word(t_curw),
        .fill_we(fill_we[0]), .fill_blk(fill_fblk), .fill_beat, .fill_last, .fill_data);
    gpu2d_cache #(.IDXW(EXT_IDXW), .TAG_DATA(EXT_TAG_MLAB), .VLO(8)) u_ec (.clk, .idle(os == O_IDLE), .gen(c_gen), .scrub(c_scrub[ESW-1:0]),
        .scrub_q(c_scrub_q[ESW-1:0]), .scrub_v(c_scrub_v), .hold(stall), .a_blk(e_ablk), .a_word(e_aword),
        .q(e_q), .hit(e_hit), .cur_blk(e_cur), .cur_word(e_curw),
        .fill_we(fill_we[1]), .fill_blk(fill_fblk), .fill_beat, .fill_last, .fill_data);

    typedef struct packed {
        logic        v;
        logic [7:0]  x;
        logic [17:0] a;      // texel byte address
        logic        hi;     // 4bpp: high nibble
    } p1_t;
    typedef struct packed {
        logic        v;
        logic [7:0]  x;
        logic        op;
        logic [15:0] dc;     // bitmap colour
        logic        pal_hi;
        logic [12:0] ea;     // ext palette address
    } p2_t;
    p1_t p1; p2_t p2;
    logic p1_need, p2_need;
    assign fill_req[0] = p1.v && p1_need && !t_hit;
    assign fill_req[1] = p2.v && p2_need && !e_hit;
    assign fill_blk[0] = t_cur;
    assign fill_blk[1] = e_cur;
    assign stall = |fill_req[1:0];

    // texel prefetch: a first OAM scan queues the row blocks of every normal
    // OBJ on the line (2^PFQW deep, in a RAM) before the drawing scan, whose
    // pixels then overlap the fills. A drawing miss on the head takes that
    // entry over (from the last clock's miss: no tag compare reaches the
    // queue's RAM address); the queue is emptied at the job's start.
    localparam int PFQW = 6;
    logic             pf_push, pf_pop, pf_take;
    logic [PFQW-1:0]  pf_wp, pf_rp;
    logic [PFQW:0]    pf_n;
    blk_t             pf_rd, pf_byp, pf_head, pf_in;
    logic [6:0]       pf_rdi, pf_bypi, pf_headi, p_idx;   // OAM index of the entry's OBJ
    logic             pf_stale;
    logic             pf_bypv, tmiss_q;
    blk_t             tcur_q;
    // the scan decodes an entry in one clock (O_PSCAN) into p_* and pushes its
    // blocks from there (O_PPUSH): OAM -> decode -> queue RAM in one clock
    // was 3.6 ns too long (nds-fit #225)
    logic [3:0]       pk, p_n;
    logic             p_last;     // the entry being pushed is entry 127
    logic [17:0]      p_base, p_step;
    logic             pf_ok;
    assign pf_ok   = os == O_PSCAN && e_on && !e_skip && !e_type[0];
    assign pf_push = os == O_PPUSH && !pf_n[PFQW];
    assign pf_in   = {SP_OBJ, j_eng, 1'b0, 13'((p_base & o_mask_n) >> 5)};
    // (a texel miss stalls in the clock it shows, so t_cur still holds its block)
    always_ff @(posedge clk) tmiss_q <= fill_req[0];
    assign tcur_q = t_cur;
    logic       pfr_v;
    blk_t       pfr_blk;
    logic [6:0] pfr_idx;
    assign pf_take = tmiss_q && pfr_v && tcur_q == pfr_blk;
    // an entry for an OBJ the drawing scan has passed is dropped, not issued:
    // its block was fetched on demand, and fetching it again would take it
    // away while it is in use (a fill invalidates its slot first)
    // the arbiter sees a one-entry register (pfr_*) loaded from the queue
    // head, never the queue RAM; it reloads a clock after it empties
    assign pf_stale = os >= O_REQ && pfr_idx < n;
    assign pf_pop  = pf_n != 0 && !pfr_v;
    gpu2d_ram #(.W($bits(blk_t) + 7), .AW(PFQW)) u_pfq (
        .clk, .we(pf_push), .waddr(pf_wp), .wdata({p_idx, pf_in}),
        .raddr(pf_pop ? pf_rp + 1'b1 : pf_rp), .rdata({pf_rdi, pf_rd}));
    assign pf_head  = pf_bypv ? pf_byp  : pf_rd;
    assign pf_headi = pf_bypv ? pf_bypi : pf_rdi;
    assign fill_req[2] = pfr_v && !pf_stale;
    assign fill_blk[2] = pfr_blk;
    always_ff @(posedge clk) begin
        pf_bypv <= pf_push && (pf_n == 0 || (pf_n == 1 && pf_pop));
        pf_byp  <= pf_in;
        pf_bypi <= p_idx;
        if (rst || os == O_INIT) begin
            pf_wp <= '0; pf_rp <= '0; pf_n <= '0; pf_bypv <= 1'b0; pfr_v <= 1'b0;
        end else begin
            if (pf_pop) begin pfr_v <= 1'b1; pfr_blk <= pf_head; pfr_idx <= pf_headi; end
            else if (pf_ack || pf_take || (pfr_v && pf_stale)) pfr_v <= 1'b0;
            if (pf_push) pf_wp <= pf_wp + 1'b1;
            if (pf_pop)  pf_rp <= pf_rp + 1'b1;
            pf_n <= pf_n + (pf_push ? 1'b1 : 1'b0) - (pf_pop ? 1'b1 : 1'b0);
        end
    end
    assign stat_stall = stall;

    // ---------------------------------------------------------------- P0: texel address
    logic        p0_v, p0_in;
    logic [17:0] p0_a;
    logic        p0_hi;
    logic [7:0]  tx;
    logic [17:0] arow, p0_off;
    always_comb begin
        p0_v = os == O_DRAW && o_xo < o_xend;
        tx = o_xflip ? 8'({1'b0, o_w} - 8'd1 - o_xo) : o_xo;
        arow = {9'd0, 9'(o_ry >>> (o_bmp ? 8 : 11))} << o_ysh;
        p0_in = 1'b1;
        p0_hi = 1'b0;
        // one add path, base + row + offset; each offset's fields are in
        // disjoint bits, so they are ORed
        if (!o_aff) begin
            if (o_bmp)       p0_off = {9'd0, tx, 1'b0};
            else if (o_bpp8) p0_off = {7'd0, tx[7:3], 6'd0} | {15'd0, tx[2:0]};
            else begin       p0_off = {8'd0, tx[7:3], 5'd0} | {16'd0, tx[2:1]}; p0_hi = tx[0]; end
        end else begin
            p0_in = o_rx >= 0 && o_rx < $signed({12'd0, o_w, 8'd0}) && o_ry >= 0 && o_ry < $signed({12'd0, o_h, 8'd0});
            if (o_bmp)       p0_off = {9'd0, o_rx[15:8], 1'b0};
            else if (o_bpp8) p0_off = {12'd0, o_ry[10:8], 3'd0} | {7'd0, o_rx[15:11], 6'd0} | {15'd0, o_rx[10:8]};
            else begin       p0_off = {13'd0, o_ry[10:8], 2'd0} | {8'd0, o_rx[15:11], 5'd0} | {16'd0, o_rx[10:9]}; p0_hi = o_rx[8]; end
        end
        p0_a = o_base + (o_aff ? arow : 18'd0) + p0_off;
        t_ablk  = {SP_OBJ, j_eng, 1'b0, 13'((p0_a & o_mask) >> 5)};
        t_aword = p0_a[4:3];
    end

    // ---------------------------------------------------------------- P1: colour index, palette address
    logic [7:0]  b1;
    logic [15:0] h1;
    logic [7:0]  ci;
    logic        op1;
    logic [12:0] ea1;
    always_comb begin
        b1 = t_q[p1.a[2:0]*8 +: 8];
        h1 = t_q[p1.a[2:1]*16 +: 16];
        ci = o_bpp8 ? b1 : {4'd0, p1.hi ? b1[7:4] : b1[3:0]};
        op1 = o_bmp ? h1[15] : ci != 8'd0;
        ea1 = {o_pal, ci, 1'b0};
        e_ablk  = {SP_OBJEXT, j_eng, 1'b0, 13'(ea1 >> 5)};
        e_aword = ea1[4:3];
    end
    // OBJ palette: halfword 0x100 of the engine's 512 (melonDS Palette[0x200 / 0x600])
    logic [8:0] pal_a_q, olb_a_q;
    logic [7:0] palidx;
    assign palidx = o_bpp8 ? ci : {o_pal, ci[3:0]};
    always_comb begin
        pal_raddr = stall ? pal_a_q : {j_eng, 1'b1, palidx[7:1]};
        olb_raddr = stall ? olb_a_q : {j_eng, p1.x};
    end

    // ---------------------------------------------------------------- P2: DrawSpritePixel
    logic [15:0] col;
    logic [28:0] old, nw;
    logic        pri_ok;
    always_comb begin
        col = o_bmp ? {1'b0, p2.dc[14:0]} : o_ext ? e_q[p2.ea[2:1]*16 +: 16]
                                                 : (p2.pal_hi ? pal_rdata[31:16] : pal_rdata[15:0]);
        old = olb_rdata;
        nw = old;
        pri_ok = o_prio < old[26:25];
        if (o_win) begin
            if (p2.op) nw[28] = 1'b1;
        end else if (p2.op && (!old[27] || pri_ok)) begin
            nw[27:0] = {1'b1, o_prio, o_mos, o_flag, col};
        end else if (!p2.op && !old[27]) begin
            nw[26:24] = {o_prio, o_mos};
        end
    end
    logic [7:0] clr_x;
    assign olb_we    = os == O_CLR || (p2.v && !stall);
    assign olb_waddr = os == O_CLR ? {j_eng, clr_x} : {j_eng, p2.x};
    assign olb_wdata = os == O_CLR ? 29'd0 : nw;

    // ---------------------------------------------------------------- affine multiply
    logic signed [15:0] m_b, mb_q;   // parameter read last clock (OAM -> multiplier was the critical path)
    always_ff @(posedge clk) mb_q <= oam_rdata[63:48];
    logic signed [8:0]  m_a;
    logic signed [24:0] m_p;
    always_comb begin
        m_b = mb_q;
        m_a = (o_k == 3'd2 || o_k == 3'd4) ? o_dx : o_dy;
        m_p = m_a * m_b;
    end

    // ---------------------------------------------------------------- sequencing
    logic [4:0] o_dx_g;   // affine group
    always_comb begin
        oam_raddr = {j_eng, n};
        // prefetch scan: the next entry is read while this one is decoded
        if (os == O_PSCAN && n != 7'd127) oam_raddr = {j_eng, n + 7'd1};
        // the scan reads the next entry whether or not this one is drawn: a
        // drawn OBJ goes on to O_BASE or O_AFF, which use none of this read
        // (O_BASE the decode registered here, O_AFF its own parameter reads,
        // and O_REQ reads the entry again afterwards), so the OAM data does
        // not steer the OAM address (speed9f #743: OAM read -> y test ->
        // address was the worst path)
        if (os == O_SCAN && n != 7'd127) oam_raddr = {j_eng, n + 7'd1};
        if (os == O_AFF) oam_raddr = {j_eng, o_dx_g, o_k[1:0]};
    end
    assign busy = os != O_IDLE;
    logic pipe_empty;
    assign pipe_empty = !p1.v && !p2.v;
    always_ff @(posedge clk) begin
        pal_a_q <= pal_raddr; olb_a_q <= olb_raddr;
        done <= 1'b0;
        if (rst) begin
            os <= O_IDLE; p1.v <= 1'b0; p2.v <= 1'b0;
        end else begin
            case (os)
                O_IDLE: if (start) begin
                    j_eng <= eng; j_line <= line; clr_x <= 8'd0;
                    // a line skipped by the scheduler left its OBJs here
                    // (melonDS's OBJLine is cleared by every DrawSprites)
                    if (st.enabled && clr) os <= O_CLR;
                    else if (st.enabled && st.obj_enable) os <= O_INIT;
                    else done <= 1'b1;
                end
                O_CLR: begin
                    clr_x <= clr_x + 8'd1;
                    if (clr_x == 8'd255) begin
                        if (st.obj_enable) os <= O_INIT;
                        else begin os <= O_IDLE; done <= 1'b1; end
                    end
                end
                O_INIT: begin n <= 7'd0; pk <= 4'd0; os <= O_PREQ; end
                O_PREQ: os <= O_PSCAN;
                O_PSCAN: begin
                    pk <= 4'd0; p_idx <= n;
                    p_step <= (e_bmp || !a0[13]) ? 18'd32 : 18'd64;
                    if (pf_ok) os <= O_PBASE;
                    else if (n == 7'd127) begin n <= 7'd0; os <= O_REQ; end
                    if (n != 7'd127) n <= n + 7'd1;
                    if (pf_ok && n == 7'd127) p_last <= 1'b1; else p_last <= 1'b0;
                end
                O_PBASE: begin p_base <= e_base; p_n <= e_nblk; os <= O_PPUSH; end
                O_PPUSH: begin
                    // a full queue ends the scan: the rest is fetched on demand
                    if (pf_n[PFQW]) begin n <= 7'd0; os <= O_REQ; end
                    else begin
                        p_base <= p_base + p_step; pk <= pk + 4'd1;
                        if (pk == p_n - 4'd1) begin
                            if (p_last) begin n <= 7'd0; os <= O_REQ; end
                            else os <= O_PSCAN;
                        end
                    end
                end
                O_REQ: os <= O_SCAN;
                O_SCAN: begin
                    if (e_on && !e_skip) begin
                        o_aff <= e_type[0];
                        o_win <= e_win;
                        o_bmp <= !e_win && a0[11:10] == 2'd3;
                        o_bpp8 <= a0[13];
                        o_ext <= !e_win && a0[11:10] != 2'd3 && a0[13] && st.dispcnt[31];
                        o_xflip <= !e_type[0] && a1[12];
                        o_prio <= a2[11:10];
                        o_mos <= a0[12] && !e_win;
                        o_flag <= a0[11:10] == 2'd3 && !e_win ? {4'hC, 4'h0} | {3'd0, 5'({1'b0, a2[15:12]} + 5'd1)}
                                : (a0[11:10] == 2'd1 && !e_win) ? 8'h80 : 8'h10;
                        o_pal <= (a0[13] && !st.dispcnt[31]) ? 4'd0 : a2[15:12];
                        o_w <= e_w; o_h <= e_h;
                        o_mask <= j_eng ? 18'h1FFFF : 18'h3FFFF;
                        if (e_xpos >= 0) begin
                            o_xo <= 8'd0; o_sx <= e_xpos[7:0];
                            o_xend <= ({2'b0, e_xpos} + {2'b0, (e_type[0] ? e_bw : {1'b0, e_w})} > 10'd256)
                                    ? 8'(10'd256 - {2'b0, e_xpos}) : (e_type[0] ? e_bw : {1'b0, e_w});
                        end else begin
                            o_xo <= 8'(-e_xpos); o_sx <= 8'd0;
                            o_xend <= e_type[0] ? e_bw : {1'b0, e_w};
                        end
                        // sprite base address
                        if (!e_type[0]) begin
                            os <= O_BASE;
                        end else begin
                            if (a0[11:10] == 2'd3 && !e_win) begin
                                o_base <= bb;
                                o_ysh <= st.dispcnt[6] ? wl + 4'd4 : (st.dispcnt[5] ? 4'd9 : 4'd8);
                            end else begin
                                o_base <= tb << 5;
                                o_ysh <= st.dispcnt[4] ? wl + {3'd0, a0[13]} + 4'd5 : 4'd10;
                            end
                            o_dx <= (e_xpos >= 0) ? -$signed({2'b0, e_bw[7:1]}) : $signed(9'(-e_xpos) - {2'b0, e_bw[7:1]});
                            o_dy <= $signed({1'b0, e_ypos}) - $signed({2'b0, e_bh[7:1]});
                            o_dx_g <= a1[13:9];
                            o_k <= 3'd0;
                            os <= O_AFF;
                        end
                    end else if (n == 7'd127) os <= O_DRAIN;
                    else n <= n + 7'd1;
                end
                O_BASE: begin o_base <= e_base; os <= O_DRAW; end
                O_AFF: begin
                    // parameter k (A, B, C, D) is read at k, registered, used at k + 2
                    o_k <= o_k + 3'd1;
                    case (o_k)
                        3'd2: begin o_pa <= m_b; o_rx <= 27'(m_p) + $signed({13'd0, o_w, 7'd0}); end
                        3'd3: o_rx <= o_rx + 27'(m_p);
                        3'd4: begin o_pc <= m_b; o_ry <= 27'(m_p) + $signed({13'd0, o_h, 7'd0}); end
                        3'd5: begin o_ry <= o_ry + 27'(m_p); os <= O_DRAW; end
                        default: ;
                    endcase
                end
                O_DRAW: if (!stall) begin
                    if (o_xo < o_xend) begin
                        o_xo <= o_xo + 8'd1;
                        o_sx <= o_sx + 8'd1;
                        if (o_aff) begin o_rx <= o_rx + o_pa; o_ry <= o_ry + o_pc; end
                    end else os <= O_DRAIN;
                end
                O_DRAIN: if (pipe_empty) begin
                    if (n == 7'd127) begin os <= O_IDLE; done <= 1'b1; end
                    else begin n <= n + 7'd1; os <= O_REQ; end
                end
                default: os <= O_IDLE;
            endcase

            if (!stall) begin
                p1.v <= p0_v && p0_in;
                p1.x <= o_sx;
                p1.a <= p0_a;
                p1.hi <= p0_hi;
                p1_need <= p0_v && p0_in;
                p2.v <= p1.v;
                p2.x <= p1.x;
                p2.op <= op1;
                p2.dc <= h1;
                p2.pal_hi <= palidx[0];
                p2.ea <= ea1;
                p2_need <= p1.v && op1 && o_ext;
            end
        end
    end
endmodule
