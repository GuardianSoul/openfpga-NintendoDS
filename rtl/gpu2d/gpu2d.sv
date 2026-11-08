// NDS 2D engine (docs/2d-engine.md): one engine at double rate serving DS
// engines A and B. The BG side (gpu2d_bg) renders a line of one engine while
// the OBJ side (gpu2d_obj) prepares a following line's OBJs; the scheduler
// outside alternates engines. At 67.03 MHz an engine-line has 2,130 clocks.
//
// Held here: both engines' line state, palette RAM (two copies, one per
// side), OAM, the two OBJ line buffers (one per line parity; each holds A and
// B), and the arbiter that serves the five caches' 32-byte fills from one
// external VRAM block port.
//
// State port word map (per engine, st_addr 0..19; 20..21 are global):
//   0 DISPCNT           1 BG1CNT:BG0CNT     2 BG3CNT:BG2CNT
//   3..6 BGnVOFS:BGnHOFS (n = 0..3)
//   7 BG2 X ref (internal)  8 BG2 Y ref  9 BG3 X ref  10 BG3 Y ref
//   11 BG2 C:A          12 BG3 C:A
//   13 Win0 {y2,y1,x2,x1}   14 Win1     15 WINCNT {objwin,out,in1,in0}
//   16 misc: [0] enabled [1] forced blank [2] OBJ enable [7:3] layer enable
//      [9:8] Win0Active [11:10] Win1Active [15:12] BG mosaic W [19:16] OBJ mosaic W
//   17 [8:0] BG mosaic line, [23:16] OBJ mosaic line
//   18 BLDALPHA:BLDCNT as written ([13:0] BLDCNT, [20:16] EVA, [28:24] EVB)
//   19 [4:0] EVY as written, [31:16] MASTER_BRIGHT
//      (EVA, EVB and EVY are clamped to 16 here)
//   20 DISPCAPCNT       21 [3:0] VRAM A-D mapped to LCDC, [4] capture enabled this frame
module gpu2d
    import gpu2d_pkg::*;
#(
    // PERSIST keeps cached VRAM blocks across lines; it then needs vram_wr
    // pulsed on every VRAM write and VRAMCNT change. Without it the caches
    // start empty every line and vram_wr is ignored.
    parameter bit PERSIST   = 0,
    parameter int MAP_IDXW  = 6,
    parameter int TEX_IDXW  = 6,
    parameter bit MOSAIC    = 1,  // 0: no BG/OBJ mosaic (fit setting)
    parameter bit CAPTURE   = 1,  // 0: no display capture (gpu2d_bg CAPTURE, a temporary fit setting)
    // 1: CPU OAM reads (oam_cre/oam_cra) take the OAM read port while the OBJ engine is idle (oam_cgnt; the
    // word in oam_cq the clock after), so nds_fabric keeps no OAM copy (nds_top OAM_SHARE)
    parameter bit OAM_CPU   = 0,
    parameter int EXT_IDXW  = 6,
    parameter int OTEX_IDXW = 6,
    parameter int OEXT_IDXW = 6,
    parameter int MAXQ      = 2,  // VRAM blocks in flight (1 or 2)
    parameter bit PREFETCH  = 1,  // prefetch passes (BG layers, OBJ rows)
    parameter bit PF_OBJ_FIRST = 0,
    parameter bit TAG_MLAB  = 0,  // the BG and OBJ ext-palette caches' tags in their data words (gpu2d_cache TAG_DATA: frees 2 M10K, no MLAB)
    // WST_RF: the BG side reads the per-pass state words (3..12: scroll,
    // affine reference points and parameters) from the register file as it
    // sets up each pass, so the working copy holds only the rest
    parameter bit WST_RF = 1
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        vram_wr,
    // state
    input  logic        st_we,
    input  logic        st_eng,
    input  logic [4:0]  st_addr,
    input  logic [31:0] st_data,
    // palette (2 KB) and OAM (2 KB), CPU writes: 32-bit word address
    input  logic        pal_we,
    input  logic [8:0]  pal_waddr,
    input  logic [31:0] pal_wdata,
    input  logic [3:0]  pal_be,
    output logic [31:0] pal_cq,         // CPU palette read: word pal_waddr, the clock after
    input  logic        oam_cre,        // OAM_CPU: a CPU OAM read of word oam_cra, held until oam_cgnt
    input  logic [8:0]  oam_cra,
    output logic        oam_cgnt,
    output logic [31:0] oam_cq,         // the granted word, the clock after oam_cgnt
    input  logic        oam_we,
    input  logic [8:0]  oam_waddr,
    input  logic [31:0] oam_wdata,
    input  logic [3:0]  oam_be,
    // jobs
    input  logic        bg_start,
    input  logic        bg_eng,
    input  logic [7:0]  bg_line,
    input  logic        bg_slot,
    output logic        bg_busy,
    output logic        bg_done,
    input  logic        obj_start,
    input  logic        obj_eng,
    input  logic [7:0]  obj_line,
    input  logic        obj_slot,
    output logic        obj_busy,
    output logic        obj_done,
    // external VRAM: 32-byte block reads, data in four 64-bit beats
    output logic        vr_req,
    output blk_t        vr_blk,
    input  logic        vr_ack,
    input  logic        vr_rvalid,
    input  logic [63:0] vr_rdata,
    // capture writes
    output logic        cap_we,
    output logic [17:0] cap_addr,
    output logic [15:0] cap_data,
    input  logic        cap_ready,
    // 3D line and display FIFO line (synchronous read)
    output logic [7:0]  l3d_raddr,
    input  logic [31:0] l3d_rdata,
    output logic [7:0]  fifo_raddr,
    input  logic [15:0] fifo_rdata,
    // pixels
    output logic        out_valid,
    output logic        out_eng,
    output logic [7:0]  out_x,
    output logic [17:0] out_rgb,
    output logic        stat_bg_stall,
    output logic        stat_obj_stall
);
    // ---------------------------------------------------------------- state
    // Both engines' state words live in a register file (an M10K). A BG job first
    // copies its engine's 20 words into the one working copy the BG side
    // reads (21 clocks), so state written during a line applies from the
    // next. With WST_RF the copy skips words 3..12 (the BG side reads them
    // from the file itself) and leaves the file's port to the BG side for its
    // last ten slots. The file is written only between jobs. The OBJ side reads only DISPCNT, the enables and the OBJ mosaic
    // line, kept as flip-flops per engine.
    logic [31:0] capcnt;
    logic        cap_en;
    logic [3:0]  lcdc_map;
    logic [1:0][31:0] o_dispcnt;
    logic [1:0]       o_en, o_oen;
    logic [1:0][7:0]  o_mosl;

    always_ff @(posedge clk) begin
        if (st_we) begin
            if (st_addr == 5'd20) capcnt <= st_data;
            if (st_addr == 5'd21) begin lcdc_map <= st_data[3:0]; cap_en <= st_data[4]; end
            if (st_addr == 5'd0)  o_dispcnt[st_eng] <= st_data;
            if (st_addr == 5'd16) begin o_en[st_eng] <= st_data[0]; o_oen[st_eng] <= st_data[2]; end
            if (st_addr == 5'd17) o_mosl[st_eng] <= st_data[23:16];
        end
    end

    function automatic logic [4:0] ev16(input logic [4:0] v);
        return v > 5'd16 ? 5'd16 : v;
    endfunction
    function automatic eng_state_t apply_word(input eng_state_t s, input logic [4:0] a, input logic [31:0] d);
        eng_state_t r;
        r = s;
        case (a)
            5'd0:  r.dispcnt = d;
            5'd1:  begin r.bgcnt[0] = d[15:0]; r.bgcnt[1] = d[31:16]; end
            5'd2:  begin r.bgcnt[2] = d[15:0]; r.bgcnt[3] = d[31:16]; end
            5'd3:  begin r.bgxpos[0] = d[15:0]; r.bgypos[0] = d[31:16]; end
            5'd4:  begin r.bgxpos[1] = d[15:0]; r.bgypos[1] = d[31:16]; end
            5'd5:  begin r.bgxpos[2] = d[15:0]; r.bgypos[2] = d[31:16]; end
            5'd6:  begin r.bgxpos[3] = d[15:0]; r.bgypos[3] = d[31:16]; end
            5'd7:  r.xref[0] = d;
            5'd8:  r.yref[0] = d;
            5'd9:  r.xref[1] = d;
            5'd10: r.yref[1] = d;
            5'd11: begin r.rota[0] = d[15:0]; r.rotc[0] = d[31:16]; end
            5'd12: begin r.rota[1] = d[15:0]; r.rotc[1] = d[31:16]; end
            5'd13: r.win0 = d;
            5'd14: r.win1 = d;
            5'd15: r.wincnt = d;
            5'd16: begin
                r.enabled = d[0]; r.forced_blank = d[1]; r.obj_enable = d[2]; r.layer_enable = d[7:3];
                r.w0act = d[9:8]; r.w1act = d[11:10]; r.bg_mos_w = d[15:12]; r.obj_mos_w = d[19:16];
            end
            5'd17: begin r.bg_mos_line = d[8:0]; r.obj_mos_line = d[23:16]; end
            5'd18: begin r.blendcnt = d[13:0]; r.eva = ev16(d[20:16]); r.evb = ev16(d[28:24]); end
            5'd19: begin r.evy = ev16(d[4:0]); r.mbright = d[31:16]; end
            default: ;
        endcase
        return r;
    endfunction

    logic [5:0]  rf_ra;
    logic [31:0] rf_q;
    // (an M10K: written only while the engine is idle)
    gpu2d_m10k #(.W(32), .AW(6)) u_rf (.clk, .we(st_we && st_addr < 5'd20), .waddr({st_eng, st_addr}),
        .wdata(st_data), .raddr(rf_ra), .rdata(rf_q));

    eng_state_t  wst;              // the BG job's working copy
    logic        ld, ld_q, ld_go;
    logic [4:0]  ld_k, ld_kq;
    logic        ld_eng, ld_slot;
    logic [7:0]  ld_line;
    logic [4:0]  b_rf_ra;
    logic        b_rf_free, b_pre;
    // WST_RF load order: words 0, 1, 2, 16 (what the BG side's look-ahead
    // needs), then 13..15, 17..19; slots 10..19 read nothing
    function automatic logic [4:0] lword(input logic [4:0] k);
        if (!WST_RF) return k;
        if (k <= 5'd2) return k;
        if (k == 5'd3) return 5'd16;
        if (k <= 5'd6) return k + 5'd9;
        return k + 5'd10;
    endfunction
    wire ld_rd = !WST_RF || ld_k < 5'd10;
    assign b_rf_free = !(ld && ld_rd);
    assign rf_ra = {ld_eng, b_rf_free ? b_rf_ra : lword(ld_k)};
    always_ff @(posedge clk) begin
        ld_go <= 1'b0;
        ld_q <= ld; ld_kq <= ld_k;
        if (ld_q && (!WST_RF || ld_kq < 5'd10)) wst <= apply_word(wst, lword(ld_kq), rf_q);
        b_pre <= WST_RF && ld_q && ld_kq == 5'd3;
        if (rst) ld <= 1'b0;
        else if (bg_start) begin
            ld <= 1'b1; ld_k <= 5'd0; ld_eng <= bg_eng; ld_slot <= bg_slot; ld_line <= bg_line;
        end else if (ld) begin
            if (ld_k == 5'd19) ld <= 1'b0;
            else ld_k <= ld_k + 5'd1;
        end
        // the last word lands the clock after it is read
        if (ld_q && ld_kq == 5'd19) ld_go <= 1'b1;
    end

    // ---------------------------------------------------------------- jobs
    logic bg_eng_q, obj_eng_q, bg_slot_q, obj_slot_q;
    always_ff @(posedge clk) begin
        if (bg_start)  begin bg_eng_q <= bg_eng;  bg_slot_q <= bg_slot;  end
        if (obj_start) begin obj_eng_q <= obj_eng; obj_slot_q <= obj_slot; end
    end
    logic obj_e;
    assign obj_e = obj_start ? obj_eng : obj_eng_q;
    // palette RAM: copy 0 serves the BG side, copy 1 the OBJ side
    logic [8:0]  bpal_ra, opal_ra;
    logic [31:0] bpal_q, opal_q;
    // (copy 0 is true dual port: its write port also serves the CPU's
    // palette reads, so nds_fabric keeps no copy of its own)
    nds_tdp_ram #(.AW(9), .MIXED("OLD_DATA")) u_pal0 (.clk,
        .a_addr(pal_waddr), .a_we(pal_we ? pal_be : 4'd0), .a_d(pal_wdata), .a_q(pal_cq),
        .b_addr(bpal_ra), .b_we(4'd0), .b_d(32'd0), .b_q(bpal_q));
    gpu2d_ram_be #(.AW(9)) u_pal1 (.clk, .we(pal_we), .be(pal_be), .waddr(pal_waddr), .wdata(pal_wdata),
        .raddr(opal_ra), .rdata(opal_q));

    // OAM as 256 x 64: entry n of engine e is word {e, n}
    logic [7:0]  oam_ra, o_oam_ra;
    logic [63:0] oam_q;
    // OAM_CPU: the CPU's read goes in a cycle the OBJ engine neither runs nor starts (its first OAM read is
    // states later; on the DS the CPU also waits for the OBJ engine's OAM use outside blanking)
    logic oam_ch;
    assign oam_cgnt = OAM_CPU && oam_cre && !obj_busy && !obj_start;
    assign oam_ra   = oam_cgnt ? oam_cra[8:1] : o_oam_ra;
    always_ff @(posedge clk) oam_ch <= oam_cra[0];
    assign oam_cq   = oam_ch ? oam_q[63:32] : oam_q[31:0];
    gpu2d_ram_be #(.AW(8)) u_oam_lo (.clk, .we(oam_we && !oam_waddr[0]), .be(oam_be), .waddr(oam_waddr[8:1]),
        .wdata(oam_wdata), .raddr(oam_ra), .rdata(oam_q[31:0]));
    gpu2d_ram_be #(.AW(8)) u_oam_hi (.clk, .we(oam_we && oam_waddr[0]), .be(oam_be), .waddr(oam_waddr[8:1]),
        .wdata(oam_wdata), .raddr(oam_ra), .rdata(oam_q[63:32]));

    // OBJ line buffers, one per line parity; the BG side owns the one it reads
    logic [8:0]  b_olb_ra, o_olb_ra, b_olb_wa, o_olb_wa;
    logic        b_olb_we, o_olb_we;
    logic [28:0] o_olb_wd;
    logic [28:0] olb_q [2];
    logic [8:0]  olb_ra [2], olb_wa [2];
    logic        olb_we [2];
    logic [28:0] olb_wd [2];
    always_comb begin
        for (int p = 0; p < 2; p++) begin
            if (bg_busy && bg_slot_q == 1'(p)) begin
                olb_ra[p] = b_olb_ra; olb_we[p] = b_olb_we; olb_wa[p] = b_olb_wa; olb_wd[p] = 29'd0;
            end else begin
                olb_ra[p] = o_olb_ra; olb_we[p] = o_olb_we && obj_slot_q == 1'(p); olb_wa[p] = o_olb_wa; olb_wd[p] = o_olb_wd;
            end
        end
    end
    gpu2d_ram #(.W(29), .AW(9)) u_olb0 (.clk, .we(olb_we[0]), .waddr(olb_wa[0]), .wdata(olb_wd[0]),
        .raddr(olb_ra[0]), .rdata(olb_q[0]));
    gpu2d_ram #(.W(29), .AW(9)) u_olb1 (.clk, .we(olb_we[1]), .waddr(olb_wa[1]), .wdata(olb_wd[1]),
        .raddr(olb_ra[1]), .rdata(olb_q[1]));

    // ---------------------------------------------------------------- fill arbiter
    // Requesters: 0..2 BG map/texel/ext-palette misses, 3..4 OBJ texel/ext
    // misses, 5 BG texel prefetch (fills the BG texel cache), 6 OBJ texel
    // prefetch (fills the OBJ texel cache). Up to MAXQ blocks
    // are in flight, answered in order (nds_vram's block contract), so an
    // in-order list says which cache each arriving block is for. A request
    // for a block already in flight to the same cache, or landed in the last
    // two clocks (its tag is not readable yet), is not issued again: a miss
    // waits for it, a prefetch is dropped.
    logic [3:0]       b_req;
    blk_t [3:0]       b_blk;
    logic             b_pf_ack, o_pf_ack;
    logic [2:0]       o_req;
    blk_t [2:0]       o_blk;
    // Miss requests are registered here: the path from a cache's tag RAM
    // through its hit compare into this arbiter and out to vr_req was the 2D
    // build's critical path (nds-fit #204). A miss is therefore issued a clock
    // after it shows; the two-clock window after a block lands still covers
    // the delayed request, so it is not issued twice. The prefetch queue head
    // (requester 5) comes from a RAM, not a tag compare, and stays direct: a
    // delayed copy would ask again for the head just issued.
    // The block needs no copy: a miss stalls its side in the clock it shows
    // (the caches hold), so the cache's latched block is unchanged when the
    // registered request is seen, and the block is only read with it.
    logic [4:0]       mreq;
    blk_t [4:0]       mblk;
    always_ff @(posedge clk)
        mreq <= rst ? 5'd0 : {o_req[1:0], b_req[2:0]};
    assign mblk = {o_blk[1:0], b_blk[2:0]};
    logic [6:0]       reqs;
    blk_t [6:0]       rblk;
    assign reqs = {o_req[2], b_req[3], mreq};
    assign rblk = {o_blk[2], b_blk[3], mblk};

    // in flight: entry 0 is the block whose beats come next; q_r is the
    // requester, which also names the cache (prefetch fills the BG texel cache)
    logic [1:0]       q_v;
    logic [1:0][2:0]  q_r;
    blk_t [1:0]       q_blk;
    logic [1:0]       fbeat;
    logic             rec_v;
    logic [1:0]       rec_n;
    logic [2:0]       rec_r;
    blk_t             rec_blk;
    logic [1:0][2:0]  q_t;
    function automatic logic [2:0] tgt(input logic [2:0] r);
        return r == 3'd5 ? 3'd1 : r == 3'd6 ? 3'd3 : r;
    endfunction
    assign q_t[0] = tgt(q_r[0]);
    assign q_t[1] = tgt(q_r[1]);
    logic [2:0] rec_t;
    assign rec_t = tgt(rec_r);

    // The chosen request waits in an issue register (out_*) that drives
    // vr_req/vr_blk until vr_ack: the pick never reaches the port or the
    // in-flight list combinationally (nds-fit #230/#231 in the full chip).
    logic       out_v;
    logic [2:0] out_r;
    blk_t       out_blk;
    logic [2:0] out_t;
    assign out_t = tgt(out_r);

    // A miss requester has at most one fill outstanding: it waits while its
    // own fill is waiting to issue, in flight or landed in the last two
    // clocks (its tag is not readable yet). The BG and OBJ texel caches have a second source, their
    // prefetch: a texel miss waits for a prefetch of its block, and a
    // prefetch of a block already on its way is dropped.
    // The duplicate checks compare only the low DUPW bits of the blocks: they
    // only steer timing (a miss waits for a prefetch, a prefetch is dropped),
    // so a false match costs a later fill, never a wrong pixel
    localparam int DUPW = 8;
    function automatic logic dk(input blk_t a, input blk_t b);
        return a[DUPW-1:0] == b[DUPW-1:0];
    endfunction
    logic [6:0] mine, elig;
    logic       tex_dup, pf_dup, otex_dup, opf_dup;
    logic [2:0] pick;
    logic       qfull;
    always_comb begin
        for (int r = 0; r < 7; r++)
            mine[r] = (q_v[0] && q_r[0] == 3'(r)) || (q_v[1] && q_r[1] == 3'(r)) || (rec_v && rec_r == 3'(r))
                   || (out_v && out_r == 3'(r));
        tex_dup = (q_v[0] && q_r[0] == 3'd5 && dk(q_blk[0], rblk[1])) || (q_v[1] && q_r[1] == 3'd5 && dk(q_blk[1], rblk[1]))
               || (rec_v && rec_r == 3'd5 && dk(rec_blk, rblk[1])) || (out_v && out_r == 3'd5 && dk(out_blk, rblk[1]));
        pf_dup  = (q_v[0] && q_t[0] == 3'd1 && dk(q_blk[0], rblk[5])) || (q_v[1] && q_t[1] == 3'd1 && dk(q_blk[1], rblk[5]))
               || (rec_v && rec_t == 3'd1 && dk(rec_blk, rblk[5])) || (out_v && out_t == 3'd1 && dk(out_blk, rblk[5]));
        otex_dup = (q_v[0] && q_r[0] == 3'd6 && dk(q_blk[0], rblk[3])) || (q_v[1] && q_r[1] == 3'd6 && dk(q_blk[1], rblk[3]))
               || (rec_v && rec_r == 3'd6 && dk(rec_blk, rblk[3])) || (out_v && out_r == 3'd6 && dk(out_blk, rblk[3]));
        opf_dup = (q_v[0] && q_t[0] == 3'd3 && dk(q_blk[0], rblk[6])) || (q_v[1] && q_t[1] == 3'd3 && dk(q_blk[1], rblk[6]))
               || (rec_v && rec_t == 3'd3 && dk(rec_blk, rblk[6])) || (out_v && out_t == 3'd3 && dk(out_blk, rblk[6]));
        for (int r = 0; r < 5; r++) elig[r] = reqs[r] && !mine[r];
        elig[1] = elig[1] && !tex_dup;
        elig[3] = elig[3] && !otex_dup;
        elig[5] = reqs[5] && !pf_dup;
        elig[6] = reqs[6] && !opf_dup;
        // misses first (OBJ, then BG), then the prefetch queues (PF_OBJ_FIRST
        // picks which goes first)
        pick = elig[3] ? 3'd3 : elig[4] ? 3'd4 : elig[0] ? 3'd0 : elig[1] ? 3'd1 : elig[2] ? 3'd2
             : (elig[5] && (!elig[6] || !PF_OBJ_FIRST)) ? 3'd5 : 3'd6;
        qfull = MAXQ == 1 ? q_v[0] : q_v[1];
        vr_req = out_v && !qfull;
        vr_blk = out_blk;
        // a prefetch is taken when it moves into the issue register
        b_pf_ack = (reqs[5] && pf_dup) || (!out_v && !qfull && |elig && pick == 3'd5);
        o_pf_ack = (reqs[6] && opf_dup) || (!out_v && !qfull && |elig && pick == 3'd6);
    end

    logic pop, push;
    assign pop  = vr_rvalid && fbeat == 2'd3;
    assign push = vr_req && vr_ack;
    always_ff @(posedge clk)
        if (rst) out_v <= 1'b0;
        else if (push) out_v <= 1'b0;
        // committed only while a slot is free: a miss arriving meanwhile still
        // goes ahead of a prefetch
        else if (!out_v && !qfull && |elig) out_v <= 1'b1;
    // (not gated by push: push needs out_v. #1323 fabric/vram/ack -> out_blk, q_blk -0.46 ns)
    always_ff @(posedge clk)
        if (!out_v && !qfull && |elig) begin out_r <= pick; out_blk <= rblk[pick]; end
    always_ff @(posedge clk) begin
        if (rst) begin
            q_v <= '0; fbeat <= 2'd0; rec_v <= 1'b0;
        end else begin
            if (vr_rvalid) fbeat <= fbeat + 2'd1;
            // shift out the head on its last beat, append accepted requests
            if (pop) begin
                q_v[0] <= q_v[1]; q_v[1] <= 1'b0;
                rec_v <= 1'b1; rec_n <= 2'd2; rec_r <= q_r[0]; rec_blk <= q_blk[0];
            end else if (rec_v) begin
                rec_n <= rec_n - 2'd1;
                if (rec_n == 2'd1) rec_v <= 1'b0;
            end
            if (push) begin
                if (pop ? !q_v[1] : !q_v[0]) q_v[0] <= 1'b1;
                else q_v[1] <= 1'b1;
            end
        end
    end
    // The slot that a push would fill is loaded while the request waits (a free slot, read only under q_v), so the
    // ack's long path ends at q_v alone. vr_rvalid only comes for an entry in slot 0, which pop keeps moved up.
    always_ff @(posedge clk) begin
        if (pop) begin q_r[0] <= q_r[1]; q_blk[0] <= q_blk[1]; end
        if (vr_req) begin
            if (pop ? !q_v[1] : !q_v[0]) begin q_r[0] <= out_r; q_blk[0] <= out_blk; end
            else begin q_r[1] <= out_r; q_blk[1] <= out_blk; end
        end
    end
    logic flast;
    assign flast = fbeat == 2'd3;
    logic [2:0] b_fwe;
    assign b_fwe = {vr_rvalid && q_t[0] == 3'd2, vr_rvalid && q_t[0] == 3'd1, vr_rvalid && q_t[0] == 3'd0};
    logic [1:0] o_fwe;
    assign o_fwe = {vr_rvalid && q_t[0] == 3'd4, vr_rvalid && q_t[0] == 3'd3};
    blk_t fblk;
    assign fblk = q_blk[0];
    // ---------------------------------------------------------------- units
    eng_state_t st_obj;
    always_comb begin
        st_obj = '0;
        st_obj.dispcnt = o_dispcnt[obj_e];
        st_obj.enabled = o_en[obj_e];
        st_obj.obj_enable = o_oen[obj_e];
        st_obj.obj_mos_line = o_mosl[obj_e];
    end
    logic bg_ubusy;
    assign bg_busy = bg_ubusy || ld || ld_q || ld_go;

    gpu2d_bg #(.PERSIST(PERSIST), .MAP_IDXW(MAP_IDXW), .TEX_IDXW(TEX_IDXW), .EXT_IDXW(EXT_IDXW), .PREFETCH(PREFETCH),
               .WST_RF(WST_RF), .MOSAIC(MOSAIC), .CAPTURE(CAPTURE), .EXT_TAG_MLAB(TAG_MLAB)) u_bg (
        .clk, .rst, .start(ld_go), .eng(ld_eng), .line(ld_line), .objslot(ld_slot),
        .busy(bg_ubusy), .done(bg_done), .st(wst), .rf_raddr(b_rf_ra), .rf_rdata(rf_q), .rf_free(b_rf_free), .pre(b_pre), .capcnt, .cap_en, .lcdc_map, .vram_wr,
        .fill_req(b_req), .fill_blk(b_blk), .pf_ack(b_pf_ack), .fill_we(b_fwe), .fill_fblk(fblk), .fill_beat(fbeat), .fill_last(flast),
        .fill_data(vr_rdata),
        .pal_raddr(bpal_ra), .pal_rdata(bpal_q),
        .olb_raddr(b_olb_ra), .olb_rdata(olb_q[bg_slot_q]), .olb_we(b_olb_we), .olb_waddr(b_olb_wa),
        .l3d_raddr, .l3d_rdata, .fifo_raddr, .fifo_rdata,
        .out_valid, .out_eng, .out_x, .out_rgb,
        .cap_we, .cap_addr, .cap_data, .cap_ready, .stat_stall(stat_bg_stall));

    // An OBJ line buffer slot is dirty from the OBJ job that fills it until the
    // BG job that reads it (whose composite pass clears it) is done. A job
    // starting on a dirty slot -- the scheduler skipped a late line's BG jobs
    // -- clears it first.
    logic [1:0][1:0] olb_dirty;   // [slot][engine]
    always_ff @(posedge clk)
        if (rst) olb_dirty <= '0;
        else begin
            if (bg_done) olb_dirty[ld_slot][ld_eng] <= 1'b0;
            if (obj_start) olb_dirty[obj_slot][obj_eng] <= 1'b1;
        end

    gpu2d_obj #(.PERSIST(PERSIST), .TEX_IDXW(OTEX_IDXW), .EXT_IDXW(OEXT_IDXW), .MOSAIC(MOSAIC), .EXT_TAG_MLAB(TAG_MLAB)) u_obj (
        .clk, .rst, .start(obj_start), .clr(olb_dirty[obj_slot][obj_eng]), .eng(obj_eng), .line(obj_line),
        .busy(obj_busy), .done(obj_done), .st(st_obj), .vram_wr,
        .fill_req(o_req), .fill_blk(o_blk), .pf_ack(o_pf_ack), .fill_we(o_fwe), .fill_fblk(fblk), .fill_beat(fbeat), .fill_last(flast),
        .fill_data(vr_rdata),
        .oam_raddr(o_oam_ra), .oam_rdata(oam_q), .pal_raddr(opal_ra), .pal_rdata(opal_q),
        .olb_raddr(o_olb_ra), .olb_rdata(olb_q[obj_slot_q]), .olb_we(o_olb_we), .olb_waddr(o_olb_wa),
        .olb_wdata(o_olb_wd), .stat_stall(stat_obj_stall));
endmodule
