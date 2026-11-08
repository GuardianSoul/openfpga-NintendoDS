// Line tag store for the direct-mapped caches (docs/phase2-integration.md,
// "M3"): each line's tag and valid state in one M10K word, which
// replaces a client's register valid bits. The clients keep their data RAMs
// and fill engines.
//
// Entry: {valid state, tag}, always written whole (one M10K per copy; byte
// lanes made Quartus split each copy into one M10K per lane, nds-fit #314).
// Every write that only clears the valid state writes back the tag the entry
// holds, as clearing a valid register left the tag RAM:
//   - an invalidation, the tag its check read (the last edge's write
//     forwarded); a queued one carries it (only a fill end changes a tag, and
//     it drops queued invalidations of its line);
//   - the sweep and the scrubber, the tag they read the cycle before.
//   G = 0: valid is one bit. inv_all (and rst) sweeps every entry to invalid,
//          one per cycle, busy meanwhile (the ARM7 port: reset only).
//   G > 0: valid is a generation: an entry is valid when it holds cur
//          (1..2^G-1; 0 is never valid). inv_all moves cur on in one cycle;
//          a scrubber, on cycles without a lookup (l_en low), rewrites
//          entries holding an older generation to 0, so cur can come round
//          again. inv_all waits (busy, lookups miss) only while the next
//          generation may still be in some entry; a fill that ends
//          meanwhile is written with the old generation, so it is invalid
//          once cur moves (a miss more, never a stale hit). With no fill
//          since the last move, inv_all changes nothing (no entry holds cur).
//
// Timing is that of a register valid array read at the request edge:
//   - lookup: l_idx this cycle; l_v and l_tag the next (l_v as the valid bit
//     was before this edge's writes; l_tag as the tag RAM read was);
//   - check (CHECK = 1, a second copy): c_idx this cycle; the next, c_v is
//     the valid state now (after this edge's writes) and c_tag the tag as
//     read (before them), as `iv[cki_a] && itq2 == ...` were;
//   - fill: while f_busy, lookups and checks of f_idx miss (the client used
//     to clear the valid bit at fill start); f_end writes {f_tag, f_ok}
//     (valid only if f_ok);
//   - inv: entry inv_idx (CHECK = 1: the line last cycle's check read, c_idx
//     a cycle earlier) invalid from the next edge. One write port: an
//     invalidation meeting a fill end waits in a CQ-entry queue, whose
//     entries lookups and checks see as invalid; a fill end supersedes
//     queued invalidations of its line.
//
// PUMP = 1 (CHECK = 1, M10K, no WLATE; clk2 = 2 x clk, phase 0, from the same
// PLL; docs/phase2-integration.md "Double-pumped RAMs"): the two copies are one
// true dual-port M10K (gpu3d_tdp2c), 2 -> 1 block. Port A, on clk, is the
// lookup's read (unchanged: the block's output from the clk edge E). Port B,
// on clk2, reads c_idx at E (the clk2 edge that coincides with it) and, at the
// clk2 edge in the middle E + 1/2, writes what this edge decided (registered at
// E on clk2), so both reads at E see every earlier write and not this one, as
// the copies' old-data reads did. The check's word is taken into a register at
// E + 1/2 (port B's write changes its output): half a clk cycle later than the
// copy's, the same value at the next edge. `ph` (a clk2 register) is 1 before
// the middle edge: a toggle on clk and its copy on clk2 are equal at E.
module nds_lcache #(
    parameter int LB    = 6,            // log2 lines
    parameter int TW    = 8,            // tag bits
    parameter int G     = 0,            // generation bits (0: one valid bit)
    parameter int CHECK = 0,            // second tag copy for tag-checked invalidations
    parameter int CQ    = 4,            // invalidation queue entries
    // "MLAB" for small stores (G = 0 only: the reset sweep initialises
    // them). An MLAB's read of an address written at the same edge is
    // undefined, so writes then go in a cycle late from a one-entry buffer
    // that reads of its address take their data from.
    parameter     STYLE = "M10K",
    // 1: writes go in a cycle late from the one-entry buffer (as MLAB) also
    // with M10K: the RAM's write port takes a register, not this cycle's
    // write decision (the ARM7 port: x_valid -> its tag RAM, nds-fit #676)
    parameter bit WLATE = 1'b0,
    parameter bit PUMP  = 1'b0          // the copies as one double-pumped block (above)
) (
    input  logic          clk,
    input  logic          clk2,         // PUMP: 2 x clk, phase 0
    input  logic          rst,
    // lookup
    input  logic          l_en,         // G > 0: the read port is the lookup's this cycle
    input  logic [LB-1:0] l_idx,
    output logic          l_v,          // valid as before the edge that read it
    output logic          l_vn,         // valid now (as `vld[line]` read after that edge)
    output logic [TW-1:0] l_tag,
    // check (CHECK = 1)
    input  logic [LB-1:0] c_idx,
    output logic          c_v,
    output logic [TW-1:0] c_tag,
    // fill
    input  logic          f_busy,
    input  logic [LB-1:0] f_idx,
    input  logic          f_end,
    input  logic          f_ok,
    input  logic [TW-1:0] f_tag,
    // invalidate one line / all
    input  logic          inv,
    input  logic [LB-1:0] inv_idx,
    input  logic          inv_all,
    output logic          busy
);
    localparam int VW = G == 0 ? 1 : G;
    localparam int N  = 1 << LB;
    localparam int TL = (TW + 7) / 8;  // tag bytes

    // ---- RAMs (power up 0: every line invalid)
    localparam int EW = VW + TW;
    localparam bit MLAB = STYLE == "MLAB";
    localparam bit LATE = MLAB || WLATE;
    (* ramstyle = STYLE *) logic [EW-1:0] mem  [0:N-1];
    (* ramstyle = STYLE *) logic [EW-1:0] mem2 [0:N-1];
    initial for (int i = 0; i < N; i++) begin mem[i] = '0; mem2[i] = '0; end
    logic          we;                  // the write: {wv, wt} at wa
    logic [LB-1:0] wa;
    logic [TW-1:0] wt;
    logic [VW-1:0] wv;
    logic [LB-1:0] ra;
    logic [EW-1:0] rq, rq2, mq, mq2;
    // what the RAMs write this edge: the write itself (M10K), or the one
    // decided last cycle (MLAB), which reads at this edge then take
    logic          ww;
    logic [LB-1:0] wwa;
    logic [EW-1:0] wwd;
    logic          f1, f2;              // last edge's read took the buffer's data
    logic [EW-1:0] fd;
    generate if (LATE) begin : g_wb
        logic          pv = 1'b0;
        logic [LB-1:0] pa;
        logic [EW-1:0] pd;
        always_ff @(posedge clk) begin pv <= we; pa <= wa; pd <= {wv, wt}; end
        assign ww = pv; assign wwa = pa; assign wwd = pd;
        always_ff @(posedge clk) begin
            f1 <= pv && pa == ra; f2 <= pv && pa == c_idx; fd <= pd;
        end
    end else begin : g_wd
        assign ww = we; assign wwa = wa; assign wwd = {wv, wt};
        assign f1 = 1'b0; assign f2 = 1'b0; assign fd = '0;
    end endgenerate
    generate if (PUMP) begin : g_pump
        logic          tg = 1'b0, tq = 1'b0, ph = 1'b0;
        logic          bw = 1'b0;
        logic [LB-1:0] bwa;
        logic [EW-1:0] bwd, qb, hb;
        always_ff @(posedge clk) tg <= !tg;
        always_ff @(posedge clk2) begin
            tq <= tg;
            ph <= tg == tq;
            if (!ph) begin bw <= ww; bwa <= wwa; bwd <= wwd; end
            if (ph) hb <= qb;
        end
        gpu3d_tdp2c #(.W(EW), .AW(LB)) u_m (.clk_a(clk), .a_addr(ra), .a_q(mq),
            .clk_b(clk2), .b_addr(ph ? bwa : c_idx), .b_we(ph && bw), .b_d(bwd), .b_q(qb));
        assign mq2 = hb;
`ifndef ALTERA_RESERVED_QIS
        initial if (CHECK == 0 || LATE) $error("nds_lcache: PUMP needs CHECK = 1 and M10K without WLATE");
`endif
    end else begin : g_plain
        always_ff @(posedge clk) begin
            if (ww) mem[wwa] <= wwd;
            mq <= mem[ra];
`ifndef SYNTHESIS
            // synthesis translate_off
            // an MLAB's read of the address written at the same edge: garbage
            // (the buffer's forwarding must cover it; with WLATE the same check)
            if (LATE && ww && wwa == ra) mq <= ~mem[ra];
            // synthesis translate_on
`endif
        end
    end endgenerate
    assign rq = f1 ? fd : mq;
    generate if (CHECK != 0) begin : g_chk
        if (!PUMP) begin : g_copy
            always_ff @(posedge clk) begin
                if (ww) mem2[wwa] <= wwd;
                mq2 <= mem2[c_idx];
`ifndef SYNTHESIS
                // synthesis translate_off
                if (LATE && ww && wwa == c_idx) mq2 <= ~mem2[c_idx];
                // synthesis translate_on
`endif
            end
        end
        assign rq2 = f2 ? fd : mq2;
    end else begin : g_nochk
        assign rq2 = '0;
    end endgenerate
    wire [VW-1:0] rq_v  = rq[EW-1:TW];
    wire [TW-1:0] rq_t  = rq[TW-1:0];
    wire [VW-1:0] rq2_v = rq2[EW-1:TW];
    wire [TW-1:0] rq2_t = rq2[TW-1:0];

    // ---- state
    logic [VW-1:0] cur = VW'(1);        // the valid code (G = 0: 1)
    logic          sw_on = 1'b0;               // G = 0: sweep reading
    logic          sw_wv = 1'b0;               // G = 0: sweep writing back the entry read last cycle
    logic [LB-1:0] sw_wa;
    logic [LB-1:0] sp = '0;                // sweep / scrub pointer
    logic          pend = 1'b0;                // G > 0: inv_all waiting for a clean generation
    logic          any_fill = 1'b0;            // G > 0: a line written valid since cur moved
    // G > 0: generations some entry may hold (power-up: only cur, 1)
    logic [(1<<VW)-1:0] dirty = (1 << VW)'(2);
    logic          sc_q = 1'b0;                // G > 0: last cycle's read was the scrubber's
    logic [LB-1:0] sc_a;
    logic          sc_hold = 1'b0;             // the pass restarted since that read
    // generations no longer current when this scrub pass started: clean
    // once it ends (nothing writes a generation after cur has left it)
    logic [(1<<VW)-1:0] snap = '0;
    // the invalidation queue
    logic [CQ-1:0]     qv = '0;
    logic [LB-1:0]     qa [CQ];
    logic [TW-1:0]     qt [CQ];         // the tag each keeps

    function automatic logic queued(input logic [LB-1:0] a);
        for (int i = 0; i < CQ; i++) if (qv[i] && qa[i] == a) return 1'b1;
        return 1'b0;
    endfunction
    wire [VW-1:0] nxt = (G == 0) ? VW'(1) : (cur == VW'((1 << VW) - 1) ? VW'(1) : cur + VW'(1));

    // ---- the write port: fill end, then the queue's head, then a new
    // invalidation, then the sweep / scrubber
    logic          qh_v;
    int            qh;
    always_comb begin
        qh_v = 1'b0; qh = 0;
        for (int i = CQ - 1; i >= 0; i--) if (qv[i]) begin qh_v = 1'b1; qh = i; end
    end
    logic          lw_v;                // the last edge's write and what it wrote
    logic [LB-1:0] lw_a;
    logic [VW-1:0] lw_d;
    logic [TW-1:0] lw_t;
    wire scrub_w = G != 0 && sc_q && !sc_hold && rq_v != '0 && rq_v != cur &&
                   !(lw_v && lw_a == sc_a);
    logic          inv_w;               // the new invalidation is written now
    logic [LB-1:0] cq_a;
    // the tag the checked entry holds now (an invalidation writes it back)
    wire  [TW-1:0] c_tnow = (lw_v && lw_a == cq_a) ? lw_t : rq2_t;
    always_comb begin
        we = 1'b0; wa = f_idx; wt = f_tag; wv = '0; inv_w = 1'b0;
        if (f_end) begin
            we = 1'b1; wv = f_ok ? cur : '0;
        end else if (qh_v) begin
            we = 1'b1; wa = qa[qh]; wt = qt[qh];
        end else if (inv) begin
            we = 1'b1; wa = inv_idx; wt = c_tnow; inv_w = 1'b1;
        end else if (G == 0 && sw_wv) begin
            we = 1'b1; wa = sw_wa; wt = rq_t;
        end else if (scrub_w) begin
            we = 1'b1; wa = sc_a; wt = rq_t;
        end
    end
    assign ra = G == 0 ? (sw_on ? sp : l_idx) : l_en ? l_idx : sp;

    // ---- lookup: masks as they were before the edge
    logic          lm_q;
    logic [VW-1:0] lc_q;
    always_ff @(posedge clk) begin
        lm_q <= (f_busy && f_idx == l_idx) || queued(l_idx) || sw_on || sw_wv || pend;
        lc_q <= cur;
    end
    assign l_v   = !lm_q && rq_v == lc_q && lc_q != '0;
    // ... and now: the last edge's write forwarded, today's masks
    logic [LB-1:0] la_q;
    always_ff @(posedge clk) la_q <= ra;
    wire [VW-1:0] lvs = (lw_v && lw_a == la_q) ? lw_d : rq_v;
    assign l_vn  = lvs == cur && !(f_busy && f_idx == la_q) && !queued(la_q) && !sw_on && !sw_wv && !pend;
    assign l_tag = rq_t;

    // ---- check: the valid state now, the tag as read
    always_ff @(posedge clk) cq_a <= c_idx;
    wire [VW-1:0] cvs = (lw_v && lw_a == cq_a) ? lw_d : rq2_v;
    assign c_v   = CHECK != 0 && cvs == cur && !(f_busy && f_idx == cq_a) && !queued(cq_a) && !sw_on && !sw_wv && !pend;
    assign c_tag = rq2_t;

    assign busy = sw_on || sw_wv || pend;

    always_ff @(posedge clk) begin
        lw_v <= we; lw_a <= wa; lw_d <= wv; lw_t <= wt;
        sc_q <= G != 0 && !l_en; sc_a <= sp; sc_hold <= 1'b0;
        // the queue: a fill end supersedes queued invalidations of its line;
        // the head leaves when written; a new invalidation not written joins
        if (f_end) for (int i = 0; i < CQ; i++) if (qa[i] == f_idx) qv[i] <= 1'b0;
        if (!f_end && qh_v) qv[qh] <= 1'b0;
        if (inv && !inv_w && !(f_end && inv_idx == f_idx)) begin : push
            logic done;
            done = 1'b0;
            for (int i = 0; i < CQ; i++)
                if (!done && !qv[i] && !(!f_end && qh_v && qh == i)) begin
                    qv[i] <= 1'b1; qa[i] <= inv_idx; qt[i] <= c_tnow; done = 1'b1;
                end
        end
        if (G == 0) begin
            // the sweep reads entry sp, and writes it back invalid with its
            // tag the next cycle
            sw_wv <= sw_on; sw_wa <= sp;
            if (sw_on) begin
                sp <= sp + 1'b1;
                if (sp == LB'(N - 1)) sw_on <= 1'b0;
            end
            if (rst || inv_all) begin sw_on <= 1'b1; sp <= '0; end
        end else begin : gen
            logic retry, ex_done;
            if (f_end && f_ok) any_fill <= 1'b1;
            // the scrubber: each cycle without a lookup reads the entry at
            // sp, examined the next cycle; a clear that did not get the
            // write port reads that entry again (the read issued meanwhile
            // is dropped)
            retry   = sc_q && !sc_hold && scrub_w && (f_end || qh_v || inv);
            ex_done = sc_q && !sc_hold && !retry;
            if (retry) begin sp <= sc_a; sc_hold <= 1'b1; end
            else if (!l_en) sp <= sp + 1'b1;
            // a whole pass: the generations stale when it began are clean
            if (ex_done && sc_a == LB'(N - 1)) begin
                dirty <= dirty & ~snap;
                snap  <= dirty & ~snap & ~((1 << VW)'(1) << cur);
            end
            // inv_all: cur moves on once its next value is clean
            if ((rst || inv_all) && (any_fill || (f_end && f_ok))) pend <= 1'b1;
            if ((pend || ((rst || inv_all) && (any_fill || (f_end && f_ok)))) && !dirty[nxt]) begin
                cur <= nxt; dirty[nxt] <= 1'b1; pend <= 1'b0; any_fill <= 1'b0;
            end
        end
        if (rst) for (int i = 0; i < CQ; i++) qv[i] <= 1'b0;
    end

`ifndef ALTERA_RESERVED_QIS
    always_ff @(posedge clk) begin
        if (inv && !inv_w && !(f_end && inv_idx == f_idx) && &qv)
            $display("nds_lcache: invalidation queue overflow (an invalidation is lost)");
        if (f_end && f_ok && !dirty[cur]) $display("nds_lcache: internal: cur not marked dirty");
        if (CHECK != 0 && inv && inv_idx != cq_a) $display("nds_lcache: an invalidation not of the line last checked");
        if (G == 0 && sw_wv && (f_end || qh_v || inv)) $display("nds_lcache: a sweep write lost (a write during the sweep)");
        if (MLAB && G != 0) $display("nds_lcache: STYLE MLAB is for G = 0 only (no sweep initialises the generations)");
    end
`endif
endmodule

// nds_lcache_n: WAYS tag stores of LB lines each with one controller (nds_g3d_cache2 WAYS > 1; budget-3d "Span
// overlap's area"): the generation (cur, dirty, snap, pend), the scrubber, the lookup and check masks and the
// pump's phase are shared, since every way is looked up, checked and scrubbed at the same line; each way keeps its
// RAM (and check copy), its write enable and word, and its last write's forwarding. One write address a clock: a
// fill end writes its way (f_way); a scrub rewrites every way of line sc_a holding an older generation. The
// configuration nds_g3d_cache2 uses only: G > 0, CHECK 1, M10K, no WLATE, no single-line invalidations (inv) and
// no fill-busy masking (f_busy), which nds_lcache's other clients need. Against WAYS nds_lcache instances: the same
// lookups and checks; a scrub that meets a fill end is retried for every way, not only the filled one.
module nds_lcache_n #(
    parameter int LB    = 6,
    parameter int TW    = 8,
    parameter int G     = 3,
    parameter int WAYS  = 4,
    parameter int PUMP  = 0,
    // PACK (four ways of 10 bits or fewer, no PUMP): each copy's ways in one M10K, a 40-bit word with a byte
    // enable a way (gpu3d_ram_be4), instead of an M10K a way and copy (128 x 10 bits each: 8 M10K -> 2)
    parameter bit PACK  = 1
) (
    input  logic                 clk,
    input  logic                 clk2,
    input  logic                 rst,
    input  logic                 l_en,
    input  logic [LB-1:0]        l_idx,
    output logic [WAYS-1:0]      l_vn,
    output logic [TW-1:0]        l_tag [0:WAYS-1],
    input  logic [LB-1:0]        c_idx,
    output logic [WAYS-1:0]      c_v,
    output logic [TW-1:0]        c_tag [0:WAYS-1],
    input  logic [LB-1:0]        f_idx,
    input  logic                 f_end,
    input  logic [$clog2(WAYS)-1:0] f_way,
    input  logic                 f_ok,
    input  logic [TW-1:0]        f_tag,
    input  logic                 inv_all,
    output logic                 busy
);
    localparam int VW = G;
    localparam int N  = 1 << LB;
    localparam int EW = VW + TW;
    // ---- the write: one address, a word and an enable a way
    logic [WAYS-1:0] we;
    logic [LB-1:0]   wa;
    logic [EW-1:0]   wd [0:WAYS-1];
    logic [LB-1:0]   ra;
    logic [EW-1:0]   rq [0:WAYS-1];       // the lookup's word a way
    logic [EW-1:0]   rq2 [0:WAYS-1];      // the check's word a way
    genvar gw;
    generate if (PUMP) begin : g_pump
        logic          tg = 1'b0, tq = 1'b0, ph = 1'b0;
        logic [WAYS-1:0] bw = '0;
        logic [LB-1:0] bwa;
        always_ff @(posedge clk) tg <= !tg;
        always_ff @(posedge clk2) begin
            tq <= tg;
            ph <= tg == tq;
            if (!ph) begin bw <= we; bwa <= wa; end
        end
        for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_w
            logic [EW-1:0] bwd, qb, hb;
            always_ff @(posedge clk2) begin
                if (!ph) bwd <= wd[gw];
                if (ph) hb <= qb;
            end
            gpu3d_tdp2c #(.W(EW), .AW(LB)) u_m (.clk_a(clk), .a_addr(ra), .a_q(rq[gw]),
                .clk_b(clk2), .b_addr(ph ? bwa : c_idx), .b_we(ph && bw[gw]), .b_d(bwd), .b_q(qb));
            assign rq2[gw] = hb;
        end
    end else if (PACK && WAYS == 4 && EW <= 10) begin : g_pack
        logic [3:0][EW-1:0] pwd, pq, pq2;
        logic [3:0]         pwe;
        always_comb
            for (int w = 0; w < 4; w++) begin
`ifdef G3D_TPACK_MUT
                pwe[w] = we[(w + 1) % 4]; pwd[w] = wd[(w + 1) % 4];   // (mutant: each way's word into the next lane)
`else
                pwe[w] = we[w]; pwd[w] = wd[w];
`endif
                rq[w] = pq[w]; rq2[w] = pq2[w];
            end
        gpu3d_ram_be4 #(.W(EW), .AW(LB)) u_l (.clk, .we(pwe), .waddr(wa), .wdata(pwd), .raddr(ra), .rdata(pq));
        gpu3d_ram_be4 #(.W(EW), .AW(LB)) u_c (.clk, .we(pwe), .waddr(wa), .wdata(pwd), .raddr(c_idx), .rdata(pq2));
    end else begin : g_plain
        for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_w
            (* ramstyle = "M10K" *) logic [EW-1:0] mem  [0:N-1];
            (* ramstyle = "M10K" *) logic [EW-1:0] mem2 [0:N-1];
            initial for (int i = 0; i < N; i++) begin mem[i] = '0; mem2[i] = '0; end
            always_ff @(posedge clk) begin
                if (we[gw]) begin mem[wa] <= wd[gw]; mem2[wa] <= wd[gw]; end
                rq[gw] <= mem[ra];
                rq2[gw] <= mem2[c_idx];
            end
        end
    end endgenerate

    // ---- state, shared
    logic [VW-1:0] cur = VW'(1);
    logic [LB-1:0] sp = '0;
    logic          pend = 1'b0, any_fill = 1'b0;
    logic [(1<<VW)-1:0] dirty = (1 << VW)'(2);
    logic          sc_q = 1'b0, sc_hold = 1'b0;
    logic [LB-1:0] sc_a;
    logic [(1<<VW)-1:0] snap = '0;
    wire  [VW-1:0] nxt = cur == VW'((1 << VW) - 1) ? VW'(1) : cur + VW'(1);
    // the last edge's write: the address shared, the word a way
    logic [WAYS-1:0] lw_v;
    logic [LB-1:0]   lw_a;
    logic [VW-1:0]   lw_d [0:WAYS-1];
    logic [WAYS-1:0] scrub_w;
    always_comb
        for (int w = 0; w < WAYS; w++)
            scrub_w[w] = sc_q && !sc_hold && rq[w][EW-1:TW] != '0 && rq[w][EW-1:TW] != cur && !(lw_v[w] && lw_a == sc_a);
    always_comb begin
        we = '0; wa = f_idx;
        for (int w = 0; w < WAYS; w++) wd[w] = {VW'(0), rq[w][TW-1:0]};
        if (f_end) begin
`ifdef G3D_TSH_MUT
            we[0] = 1'b1; wd[0] = {f_ok ? cur : VW'(0), f_tag};          // (mutant: every fill's tag into way 0)
`else
            we[f_way] = 1'b1; wd[f_way] = {f_ok ? cur : VW'(0), f_tag};
`endif
        end else if (|scrub_w) begin
            we = scrub_w; wa = sc_a;
        end
    end
    assign ra = l_en ? l_idx : sp;

    // ---- lookup and check: the last edge's write forwarded
    logic [LB-1:0] la_q, cq_a;
    always_ff @(posedge clk) begin la_q <= ra; cq_a <= c_idx; end
    always_comb
        for (int w = 0; w < WAYS; w++) begin
            l_vn[w]  = ((lw_v[w] && lw_a == la_q) ? lw_d[w] : rq[w][EW-1:TW]) == cur && !pend;
            l_tag[w] = rq[w][TW-1:0];
            c_v[w]   = ((lw_v[w] && lw_a == cq_a) ? lw_d[w] : rq2[w][EW-1:TW]) == cur && !pend;
            c_tag[w] = rq2[w][TW-1:0];
        end
    assign busy = pend;

    always_ff @(posedge clk) begin : st
        logic retry, ex_done;
        lw_v <= we; lw_a <= wa;
        for (int w = 0; w < WAYS; w++) lw_d[w] <= wd[w][EW-1:TW];
        sc_q <= !l_en; sc_a <= sp; sc_hold <= 1'b0;
        if (f_end && f_ok) any_fill <= 1'b1;
        retry   = sc_q && !sc_hold && |scrub_w && f_end;
        ex_done = sc_q && !sc_hold && !retry;
        if (retry) begin sp <= sc_a; sc_hold <= 1'b1; end
        else if (!l_en) sp <= sp + 1'b1;
        if (ex_done && sc_a == LB'(N - 1)) begin
            dirty <= dirty & ~snap;
            snap  <= dirty & ~snap & ~((1 << VW)'(1) << cur);
        end
        if ((rst || inv_all) && (any_fill || (f_end && f_ok))) pend <= 1'b1;
        if ((pend || ((rst || inv_all) && (any_fill || (f_end && f_ok)))) && !dirty[nxt]) begin
            cur <= nxt; dirty[nxt] <= 1'b1; pend <= 1'b0; any_fill <= 1'b0;
        end
    end
`ifndef ALTERA_RESERVED_QIS
    always_ff @(posedge clk) if (f_end && f_ok && !dirty[cur]) $display("nds_lcache_n: internal: cur not marked dirty");
    initial if (G == 0 || WAYS < 2) $error("nds_lcache_n: G > 0 and WAYS > 1 only");
`endif
endmodule
