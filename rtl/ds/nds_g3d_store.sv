// The 3D polygon store at the DS's full capacity (2,048 polygons and 6,144
// vertices per frame), kept in PSRAM, with the polygons that cover the
// current line in an on-chip pool (docs/phase2-integration.md, "3D";
// memory-replay.md, "What it means" 2). Between gpu3d_geom's records
// (po_*, so_*) and gpu3d_raster's per-line stream (ps_*).
//
// PSRAM (p_*: main-RAM word addresses through nds_mr_arb), double-buffered:
//   0x400000 + bank * 0x20000   headers, 16 bytes per polygon index
//   0x408000 + bank * 0x20000   vertices, 16 bytes each, in arrival order
// A header keeps its polygon's first vertex number in bits 127:115.
//
// On chip, for the bank being drawn:
//   - Y table {skip, ytop, ybot} per polygon index, written with each
//     header; after a swap geom waits (po_ready) while it is read;
//   - render order (position -> index, from the sort);
//   - arrival lists: per line, the positions whose polygon starts there, in
//     render order, built after the swap (four cycles per position);
//   - a pool of 2^SL polygon slots and 2^CL vertex chunks: the loader reads
//     each polygon once, line by line ahead of the rasterizer, into a slot
//     (its header) and a chain of chunks (its vertices);
//   - two active lists {position, slot} in render order: the polygons of
//     the last line that reach the next.
// For line y the fetcher merges the active list with line y's arrivals by
// position. Every one of them covers y (an arrival starts on y; an active
// polygon was kept because it reaches y). Each is sent as a header and its
// vertices, then kept for y+1 if it reaches it (y + 1 < ybot) or freed; an
// end-of-line beat follows. A polygon the pool can't hold waits until
// lines retire. A frame start drains what an unfinished frame left.
module nds_g3d_store #(
    parameter int SL = 8,               // log2 pool slots
    parameter int CL = 10,             // log2 pool vertex chunks
    // 1: the write queue is filled from geom's output words as they are written (po_w*), so geom's
    // 128-bit po_data register is not needed; 0: from po_data at the push (the first version)
    parameter bit WORDS = 1'b1,
    // 0: ps_data is the RAM data itself (the vertex lanes hold it while a vertex beat waits; cycle-identical);
    // 1: a 128-bit beat register (the first version)
    parameter bit PSREG = 1'b0,
    // WORDS: 1 puts the write queue's lanes in M10K (a registered read at wq_rp, every clock) instead of MLAB
    // (#867: the 4-entry queue took ~113 ALMs of MLAB, ~11 LABs, for 161 bits x 4); the writer reads wh only from
    // the clock after p_busy rises, which comes at least a clock after the entry's last write and after wq_rp moves
    parameter bit WQ_M10K = 1'b1,
    // WQ_M10K: 1 puts the four lanes in one M10K, a word per {lane, entry}: the writer sends one 32-bit word a
    // clock, so the block is read every clock at the word the writer sends next ({lane of wk', wq_rp'}, the
    // registers' next values): 5 -> 2 blocks (docs/phase2-integration.md "Double-pumped RAMs")
    parameter bit WQ_PACK = 1'b1,
    // WQ_PACK: log2 write-queue entries. A polygon's beats come ~17 clocks apart and a PSRAM record takes 20-40, so 4 entries
    // hold the engine ~21 clocks a beat; the M10Ks hold 16 as well as 4 (B_DRAIN empties the queue before the bank is read)
    parameter int WQ_AW = 4
) (
    input  logic         clk,
    input  logic         rst,
    // geometry engine
    input  logic         po_valid,
    output logic         po_ready,
    input  logic         po_type,
    input  logic [127:0] po_data,
    input  logic [10:0]  po_index,
    input  logic         po_wv,          // geom writes word po_wk of the next record
    input  logic [1:0]   po_wk,
    input  logic [31:0]  po_wd,
    input  logic         so_we,
    input  logic [10:0]  so_pos,
    input  logic [10:0]  so_idx,
    input  logic         so_done,
    input  logic [11:0]  so_count,
    // rasterizer
    output logic         drawing,        // a frame is drawn from the on-chip lists (f_live): a swap's sort output must wait
    input  logic         frame_go,       // a frame starts (line 0 next)
    input  logic         abort,          // the raster restarts unfinished (the clock before its frame_go): this frame stops
    // diagnostics (docs/diag.md): {loader beat, loader granted, loader waiting for the PSRAM grant,
    // fetcher waiting for the loader}
    output logic [3:0]   diag_ld,
    input  logic         ps_line_req,
    input  logic [7:0]   ps_line_y,
    input  logic [8:0]   y_lim,          // the last line it may stream now (3D ring)
    output logic         ps_valid,
    input  logic         ps_ready,
    output logic [1:0]   ps_type,
    output logic [127:0] ps_data,
    // PSRAM: request held until ack; a read returns 4 words (rvalid)
    output logic         p_req,
    output logic         p_we,
    output logic [22:2]  p_addr,
    output logic [31:0]  p_wdata,
    input  logic         p_ack,
    input  logic         p_rvalid,
    input  logic [31:0]  p_rdata,
    input  logic         p_wdrained      // the record writes have reached their memory (STORE_SD; PSRAM: 1)
);
    // ================================================================ write side
    logic        wb;                     // bank geom writes
    logic [12:0] vptr;
    logic        building;
    logic [146:0] wh;                    // the queue's oldest entry {byte address [22:4], record}
    localparam int QA = WORDS && WQ_M10K && WQ_PACK ? WQ_AW : 2;
    localparam int QN = QA + 1;
    logic [QA-1:0] wq_rp, wq_wp;         // WORDS: 2^QA entries, else 2 (bit 0)
    logic [QA:0] wq_n;
    logic [1:0]  wk;                     // word of the record being written
    logic        p_own_l;                // the PSRAM access in flight is the loader's
    logic        p_busy;
    assign po_ready = wq_n < QN'((1 << QA) - 2) && !building;
    wire         po_go = po_valid && po_ready;
    wire [22:4]  h_a = {2'b10, wb, 5'd0, po_index};                        // 0x400000 + wb*0x20000 + idx*16
    wire [22:4]  v_a = {2'b10, wb, 16'd0} + {6'd0, 13'h0800 + vptr};      // + 0x8000 + v*16
    wire         w_done = p_busy && !p_own_l && p_ack && wk == 2'd3;
    // WQ_PACK: the writer's word and entry after this edge (wk, wq_rp's next values)
    wire  [1:0]  wk_n  = rst ? 2'd0 : wk + 2'(p_busy && !p_own_l && p_ack);
    wire  [QA-1:0] wrp_n = rst ? '0 : wq_rp + QA'(w_done);
    logic [18:0] wq_ha;                  // the oldest entry's byte address [22:4]
    logic [31:0] wq_d;                   // ... and word wk of its record, as the writer sends it
    always_ff @(posedge clk) begin
        if (rst) begin
            wb <= 1'b0; vptr <= 13'd0; wq_rp <= '0; wq_wp <= '0; wq_n <= '0;
        end else begin
            if (po_go) begin
                wq_wp <= WORDS ? wq_wp + QA'(1) : QA'(!wq_wp[0]);
                if (po_type) vptr <= vptr + 13'd1;
            end
            wq_n <= wq_n + QN'(po_go) - QN'(w_done);
            if (w_done) wq_rp <= WORDS ? wq_rp + QA'(1) : QA'(!wq_rp[0]);
            if (so_done) begin wb <= !wb; vptr <= 13'd0; end
        end
    end

    // the write queue in MLAB, read combinationally (an M10K costs 4 blocks for
    // 2 x 147 bits, fit #314; registers 294 FFs): wh is entry wq_rp, complete
    // before the writer starts on it, and no write reaches the entry in flight.
    // WORDS: geom's words go into four 32-bit lanes of entry wq_wp as they are
    // written, the address, vptr and type with the push. Geom writes the next
    // record's words only after its last push was taken, when up to 2 entries
    // wait: hence 4 entries, so the one being filled is never one that waits
    logic [31:0] wq_lane [4];
    logic        wq_type;
    logic [12:0] wq_vptr;
    logic [22:4] wq_addr;
    generate if (WORDS) begin : g_wqw
        genvar wl;
        if (WQ_M10K && WQ_PACK) begin : g_pk
            // the lanes: word {lane, entry}; lane of word k = {k[1], k[1] ^ k[0]} (words 0, 1, 3, 2)
            logic [31:0] wq_w;
            gpu3d_ram #(.W(32), .AW(QA + 2), .STYLE("M10K")) u_wl (.clk, .we(po_wv), .waddr({po_wk, wq_wp}),
                .wdata(po_wd), .raddr({wk_n[1], wk_n[1] ^ wk_n[0], wrp_n}), .rdata(wq_w));
            gpu3d_ram #(.W(33), .AW(QA), .STYLE("M10K")) u_wa (.clk, .we(po_go), .waddr(wq_wp),
                .wdata({po_type, po_type ? v_a : h_a, vptr}), .raddr(wq_rp), .rdata({wq_type, wq_addr, wq_vptr}));
            for (wl = 0; wl < 4; wl = wl + 1) begin : g_l
                assign wq_lane[wl] = wq_w;   // (wh: only its address bits are used)
            end
            // lane 3 is word 2
            assign wq_d = (wk == 2'd2 && !wq_type) ? {wq_vptr, 7'd0, wq_w[11:0]} : wq_w;
        end else if (WQ_M10K) begin : g_m
            for (wl = 0; wl < 4; wl = wl + 1) begin : g_l
                gpu3d_ram #(.W(32), .AW(2), .STYLE("M10K")) u_wl (.clk, .we(po_wv && po_wk == 2'(wl)), .waddr(wq_wp),
                    .wdata(po_wd), .raddr(wq_rp), .rdata(wq_lane[wl]));
            end
            gpu3d_ram #(.W(33), .AW(2), .STYLE("M10K")) u_wa (.clk, .we(po_go), .waddr(wq_wp),
                .wdata({po_type, po_type ? v_a : h_a, vptr}), .raddr(wq_rp), .rdata({wq_type, wq_addr, wq_vptr}));
        end else begin : g_ml
            for (wl = 0; wl < 4; wl = wl + 1) begin : g_l
                gpu3d_lram #(.W(32), .AW(2)) u_wl (.clk, .we(po_wv && po_wk == 2'(wl)), .waddr(wq_wp), .wdata(po_wd),
                    .raddr(wq_rp), .rdata(wq_lane[wl]));
            end
            gpu3d_lram #(.W(33), .AW(2)) u_wa (.clk, .we(po_go), .waddr(wq_wp),
                .wdata({po_type, po_type ? v_a : h_a, vptr}), .raddr(wq_rp), .rdata({wq_type, wq_addr, wq_vptr}));
        end
`ifndef ALTERA_RESERVED_QIS
        // synthesis translate_off
        // WQ_M10K: the MLAB queue beside it; the writer must see the same entry on every clock it uses wh
        if (WQ_M10K) begin : g_chk
            logic [31:0] cl [4];
            logic [32:0] ca;
            for (wl = 0; wl < 4; wl = wl + 1) begin : g_l
                gpu3d_lram #(.W(32), .AW(QA)) u_cl (.clk, .we(po_wv && po_wk == 2'(wl)), .waddr(wq_wp), .wdata(po_wd),
                    .raddr(wq_rp), .rdata(cl[wl]));
            end
            gpu3d_lram #(.W(33), .AW(QA)) u_ca (.clk, .we(po_go), .waddr(wq_wp),
                .wdata({po_type, po_type ? v_a : h_a, vptr}), .raddr(wq_rp), .rdata(ca));
            wire [146:0] wh_ref = {ca[31:13], ca[32] ? cl[3] : {ca[12:0], 7'd0, cl[3][11:0]}, cl[2], cl[1], cl[0]};
            // what the writer sends: its address and word (WQ_PACK: all wh holds that is used)
            wire [31:0]  wd_ref = wh_ref[{wk[1], wk[1] ^ wk[0]}*32 +: 32];
            always_ff @(posedge clk)
                if (!rst && p_busy && !p_own_l && (WQ_PACK ? (wq_ha != wh_ref[146:128] || wq_d != wd_ref) : wh != wh_ref))
                    $error("nds_g3d_store WQ_M10K: the queue's entry %0d word %0d reads %h %h, the MLAB queue %h %h", wq_rp, wk,
                           wq_ha, wq_d, wh_ref[146:128], wd_ref);
        end
        // synthesis translate_on
`endif
        assign wh = {wq_addr, wq_type ? wq_lane[3] : {wq_vptr, 7'd0, wq_lane[3][11:0]}, wq_lane[2], wq_lane[1], wq_lane[0]};
        if (!(WQ_M10K && WQ_PACK)) begin : g_wd
            assign wq_d = wh[{wk[1], wk[1] ^ wk[0]}*32 +: 32];
        end
    end else begin : g_wqr
        gpu3d_lram #(.W(147), .AW(1)) u_wq (.clk, .we(po_go), .waddr(wq_wp[0]),
            .wdata(po_type ? {v_a, po_data} : {h_a, vptr, 7'd0, po_data[107:0]}), .raddr(wq_rp[0]), .rdata(wh));
        assign wq_d = wh[{wk[1], wk[1] ^ wk[0]}*32 +: 32];
    end endgenerate
    assign wq_ha = wh[146:128];

    // Y table, render order
    logic [10:0] yt_ra, or_ra, or_q;
    logic [16:0] yt_q;
    // the header's Y bits (107, 96:89, 104:97): WORDS takes them from the words as written
    logic [6:0]  yw2;                    // word 2 bits 31:25 (header bits 95:89)
    logic [11:0] yw3;                    // word 3 bits 11:0 (header bits 107:96)
    always_ff @(posedge clk) if (po_wv) begin
        if (po_wk == 2'd2) yw2 <= po_wd[31:25];
        if (po_wk == 2'd3) yw3 <= po_wd[11:0];
    end
    wire  [107:89] yh = WORDS ? {yw3, yw2} : po_data[107:89];
    gpu3d_ram #(.W(17), .AW(11)) u_ytab (.clk, .we(po_go && !po_type), .waddr(po_index),
        .wdata({yh[107], yh[96:89], yh[104:97]}), .raddr(yt_ra), .rdata(yt_q));
    gpu3d_ram #(.W(11), .AW(11)) u_ord (.clk, .we(so_we), .waddr(so_pos), .wdata(so_idx), .raddr(or_ra), .rdata(or_q));

    // ================================================================ arrival lists
    // bucket per line {tag, head, tail}; link per position: the next one.
    // One copy for the build and the loader, one for the fetcher.
    logic        tag;
    logic        bk_we, lk_we;
    logic [7:0]  bk_wa, bk_ra, bkf_ra;
    logic [22:0] bk_wd, bk_q, bkf_q;
    logic [10:0] lk_wa, lk_wd, lk_ra, lk_q, lkf_ra, lkf_q;
    gpu3d_ram #(.W(23), .AW(8))  u_bk  (.clk, .we(bk_we), .waddr(bk_wa), .wdata(bk_wd), .raddr(bk_ra),  .rdata(bk_q));
    gpu3d_ram #(.W(23), .AW(8))  u_bkf (.clk, .we(bk_we), .waddr(bk_wa), .wdata(bk_wd), .raddr(bkf_ra), .rdata(bkf_q));
    // the links in one true dual-port RAM: port A the build's writes and the loader's reads (the loader
    // waits for ready, so it never reads while the build writes; checked below), port B the fetcher
    gpu3d_tdp #(.W(11), .AW(11)) u_lk (.clk, .a_addr(lk_we ? lk_wa : lk_ra), .a_we(lk_we), .a_d(lk_wd), .a_q(lk_q),
                                       .b_addr(lkf_ra), .b_q(lkf_q));
    // position -> slot (the loader writes it, the fetcher reads it)
    logic        sp_we;
    logic [10:0] sp_wa, sp_ra;
    logic [SL-1:0] sp_wd, sp_q;
    gpu3d_ram #(.W(SL), .AW(11)) u_sp (.clk, .we(sp_we), .waddr(sp_wa), .wdata(sp_wd), .raddr(sp_ra), .rdata(sp_q));

    logic        rb;                     // bank being drawn
    logic [11:0] rcount;
    logic        ready;                  // lists built, the bank's records in PSRAM
    typedef enum logic [2:0] { B_IDLE, B_CLR, B_DRAIN, B_ORD, B_YT, B_BK, B_LINK } bst_t;
    bst_t        bst;
    logic [11:0] bpos;
    wire  [7:0]  b_ytop = yt_q[15:8];
    wire         b_take = bst == B_LINK && !yt_q[16] && b_ytop < 8'd192;
    always_ff @(posedge clk) begin
        if (rst) begin
            bst <= B_IDLE; building <= 1'b0; tag <= 1'b0; ready <= 1'b0; rb <= 1'b1; rcount <= 12'd0;
        end else case (bst)
            B_IDLE: if (so_done) begin
                building <= 1'b1; ready <= 1'b0; rb <= wb; rcount <= so_count; tag <= !tag; bpos <= 12'd0;
                bst <= B_CLR;
            end
            // every bucket starts empty: a bucket this frame doesn't write
            // would otherwise keep a tag that matches every second frame
            B_CLR: begin
                bpos <= bpos + 12'd1;
                if (bpos == 12'd191) begin bpos <= 12'd0; bst <= B_DRAIN; end
            end
            B_DRAIN: if (wq_n == '0 && !(p_busy && !p_own_l) && p_wdrained) begin
                if (rcount == 12'd0) begin building <= 1'b0; ready <= 1'b1; bst <= B_IDLE; end
                else bst <= B_ORD;
            end
            B_ORD: bst <= B_YT;                          // order[bpos]
            B_YT:  bst <= B_BK;                          // ytab[index]
            B_BK:  bst <= B_LINK;                        // bucket[ytop]
            default: begin                               // B_LINK: bpos joins its line
                bpos <= bpos + 12'd1;
                if (bpos + 12'd1 == rcount) begin building <= 1'b0; ready <= 1'b1; bst <= B_IDLE; end
                else bst <= B_ORD;
            end
        endcase
    end
    always_comb begin
        bk_we = b_take; bk_wa = b_ytop; lk_we = 1'b0; lk_wa = bk_q[10:0]; lk_wd = bpos[10:0];
        bk_wd = {tag, bpos[10:0], bpos[10:0]};
        if (b_take && bk_q[22] == tag) begin bk_wd = {tag, bk_q[21:11], bpos[10:0]}; lk_we = 1'b1; end
        if (bst == B_CLR) begin bk_we = 1'b1; bk_wa = bpos[7:0]; bk_wd = {!tag, 22'd0}; end
    end

    // ================================================================ pool
    logic          fs_pop, fs_push, fs_ok, fc_pop, fc_push, fc_ok;
    logic [SL-1:0] fs_pd, fs_q;
    logic [CL-1:0] fc_pd, fc_q;
    logic [SL:0]   fs_n;
    logic [CL:0]   fc_n;
    // The loader writes a header's and a vertex's PSRAM words straight into
    // their 32-bit lanes: header words 0-2 into the free list's next slot
    // as they arrive (it is popped once the polygon has room; the slot is
    // free until then), word 3 with the first chunk once the vertices are in.
    logic          sh_we, cn_we;
    logic [SL-1:0] sh_wa, sh_ra;
    logic [CL+8:0] sh_wd;                // lane 3: {first chunk, header bits 104:96}; bits 106:105 ride in lane 2
    logic [127:0]  sh_q;                 // header bits 106:0, first chunk in 127:128-CL
    logic [CL-1:0] ch_ra, cn_wa, cn_wd, cn_ra, cn_q;
    logic [115:0]  ch_q;
    // !PSREG: a beat shows from the clock after it is sent, and is the RAM data then: ch_q for a vertex,
    // whose lanes hold while it waits (the fetcher has meanwhile set the next chunk's address; they read it
    // at the clock the beat is taken, so the next beat finds it), sh_q for a header, whose slot keeps its
    // address and data until all the polygon's vertex beats are out
    logic          ch_re;
    logic [127:0]  ps_data_r;
    logic [3:0]    hl_we, vl_we;         // header, vertex lane written by this beat
    logic [1:0]    sh_hi;                // header bits 106:105 (lane 2's RAM)
    logic [33:0]   hl_wd;                // a header lane's word (lane 2: with header bits 106:105)
    // (generate blocks with their own genvars: Quartus Standard rejects
    // bare module-level for loops)
    genvar hk, vk;
    generate
        for (hk = 0; hk < 3; hk = hk + 1) begin : g_hl
            // lane 2 also keeps header bits 106:105 (word 3 arrives first: the record's words 2 and 3 are
            // swapped in PSRAM), in its M10K pair's spare width, so lane 3 fits one M10K
            localparam int HW2 = hk == 2 ? 34 : 32;
            logic [33:0] q;
            gpu3d_ram #(.W(HW2), .AW(SL)) u_sh (.clk, .we(hl_we[hk]), .waddr(fs_q), .wdata(hl_wd[HW2-1:0]), .raddr(sh_ra),
                .rdata(q[HW2-1:0]));
            assign sh_q[hk*32 +: 32] = q[31:0];
            if (hk == 2) begin : g_hi
                assign sh_hi = q[33:32];
            end
        end
        for (vk = 0; vk < 4; vk = vk + 1) begin : g_vl
            localparam int LW = vk == 3 ? 20 : 32;
            gpu3d_ram_re #(.W(LW), .AW(CL)) u_ch (.clk, .we(vl_we[vk]), .waddr(fc_q), .wdata(p_rdata[LW-1:0]),
                .re(ch_re), .raddr(ch_ra), .rdata(ch_q[vk*32 +: LW]));
        end
    endgenerate
    logic [CL+8:0] sh3_q;
    gpu3d_ram #(.W(CL + 9), .AW(SL)) u_sh3 (.clk, .we(sh_we), .waddr(sh_wa), .wdata(sh_wd), .raddr(sh_ra), .rdata(sh3_q));
    assign sh_q[127:96] = {sh3_q[CL+8:9], {(21-CL){1'b0}}, sh_hi, sh3_q[8:0]};
    gpu3d_ram #(.W(CL),  .AW(CL)) u_cn (.clk, .we(cn_we), .waddr(cn_wa), .wdata(cn_wd), .raddr(cn_ra), .rdata(cn_q));
    logic          f_live, f_dead, f_clr, f_clr_go;    // an abandoned frame (below, with lgo)
    assign drawing = f_live;
    nds_g3d_fl #(.W(SL)) u_fs (.clk, .rst, .clr(f_clr_go), .pop(fs_pop), .push(fs_push), .pd(fs_pd), .q(fs_q), .ok(fs_ok), .n(fs_n));
    nds_g3d_fl #(.W(CL)) u_fc (.clk, .rst, .clr(f_clr_go), .pop(fc_pop), .push(fc_push), .pd(fc_pd), .q(fc_q), .ok(fc_ok), .n(fc_n));

    // ================================================================ loader
    typedef enum logic [3:0] { L_IDLE, L_LINE, L_LINE2, L_POS, L_POS2, L_HREQ, L_HDAT, L_ROOM,
                               L_VREQ, L_VDAT, L_SLOT, L_LINK, L_DONE } lst_t;
    lst_t          lst;
    logic [8:0]    ly;                   // line whose arrivals load next; 192 = all loaded
    logic          lgo;                  // this bank's loading has started
    // A bank is drawn once per frame until the next swap (a game at 30 fps shows it twice), and every
    // frame frees the slots and chunks it drew: the loader loads it again for each frame after the
    // first (l_re, from frame_go until it restarts; the fetcher waits). Without this the second frame
    // drew from freed slots and freed them again: slots twice in the free list, later given to two
    // polygons (KH 833, NSMB 927: a polygon above its line)
    logic          l_drawn, l_re;
    // A frame the raster has not finished when the next swap starts (the sort writes the order, the
    // loader restarts on the new bank) is abandoned: its remaining lines go out empty (f_dead), and at
    // the swap its slots and chunks come back by starting both free lists again once the fetcher is
    // idle (f_clr; the loader waits). Before, the old frame's lines took the new bank's lists and
    // waited on its loader: HG crawled one line every two frames once a frame was late
    // (f_live, f_dead, f_clr, f_clr_go: declared with the pool)
    always_ff @(posedge clk) begin
        if (rst || so_done) begin l_drawn <= 1'b0; l_re <= 1'b0; end
        else begin
            if (frame_go) begin l_drawn <= 1'b1; if (l_drawn) l_re <= 1'b1; end
            if (l_re && (lst == L_IDLE || lst == L_LINE || lst == L_DONE)) l_re <= 1'b0;
        end
    end
    logic [10:0]   lpos, ltail, lidx;
    logic [10:0]   lh3;                  // header bits 106:96
    logic [3:0]    lnv, lk;
    logic [12:0]   lv;
    logic [1:0]    lw;
    // beat lw brings word lw_w: a record's words 2 and 3 are swapped in PSRAM (p_wdata below)
    wire  [1:0]    lw_w = {lw[1], lw[1] ^ lw[0]};
    logic [SL-1:0] lslot;
    logic [CL-1:0] lc_first, lc_prev;
    logic          l_req;
    logic [22:2]   l_addr;
    wire           l_ack = p_busy && p_own_l && p_ack;
    wire           l_beat = p_rvalid;    // the loader is the only reader
    assign hl_wd = {lh3[10:9], p_rdata};
    always_comb begin
        hl_we = '0; vl_we = '0;
        if (l_beat && lst == L_HDAT && lw_w != 2'd3) hl_we[lw_w] = 1'b1;
        if (l_beat && lst == L_VDAT) vl_we[lw_w] = 1'b1;
    end
    always_ff @(posedge clk) begin
        sh_we <= 1'b0; cn_we <= 1'b0; sp_we <= 1'b0;
        if (rst || so_done) begin
            lst <= L_IDLE; ly <= 9'd192; l_req <= 1'b0; lgo <= 1'b0;
        end else if (l_re && (lst == L_IDLE || lst == L_LINE || lst == L_DONE)) begin
            // the bank is drawn again (no swap since its last frame): load it again from line 0, at a
            // state that holds no slot or chunk
            lst <= L_IDLE; ly <= 9'd192; lgo <= 1'b0;
        end else case (lst)
            L_IDLE: if (ready && !lgo && !f_clr) begin lgo <= 1'b1; ly <= 9'd0; lst <= L_LINE; end
            L_LINE: lst <= L_LINE2;                                  // bucket[ly]
            L_LINE2: if (bk_q[22] == tag) begin lpos <= bk_q[21:11]; ltail <= bk_q[10:0]; lst <= L_POS; end
                     else lst <= L_DONE;
            L_POS:  lst <= L_POS2;                                   // order[lpos]
            L_POS2: begin lidx <= or_q; lst <= L_HREQ; end
            // the header's words go to the next free slot, so one must be there
            L_HREQ: if (fs_ok) begin l_req <= 1'b1; l_addr <= {2'b10, rb, 5'd0, lidx, 2'b00}; lw <= 2'd0; lst <= L_HDAT; end
            L_HDAT: begin
                if (l_ack) l_req <= 1'b0;
                if (l_beat) begin
                    lw <= lw + 2'd1;
                    if (lw_w == 2'd3) begin lv <= p_rdata[31:19]; lh3 <= p_rdata[10:0]; end
                    if (lw_w == 2'd2) begin lnv <= p_rdata[16:13]; lst <= L_ROOM; end   // header bits 80:77
                end
            end
            L_ROOM: begin
                lk <= 4'd0;
                if (fs_ok && fc_n >= {{(CL-3){1'b0}}, lnv}) begin lslot <= fs_q; lst <= L_VREQ; end
            end
            L_VREQ: if (fc_ok) begin
                l_req <= 1'b1; l_addr <= {2'b10, rb, 18'd0} + {6'd0, 13'h0800 + lv, 2'b00}; lw <= 2'd0;
                lst <= L_VDAT;
            end
            L_VDAT: begin
                if (l_ack) l_req <= 1'b0;
                if (l_beat) begin
                    lw <= lw + 2'd1;
                    if (lw == 2'd3) begin
                        if (lk == 4'd0) lc_first <= fc_q;
                        else begin cn_we <= 1'b1; cn_wa <= lc_prev; cn_wd <= fc_q; end
                        lc_prev <= fc_q;
                        lk <= lk + 4'd1; lv <= lv + 13'd1;
                        lst <= lk + 4'd1 == lnv ? L_SLOT : L_VREQ;
                    end
                end
            end
            L_SLOT: begin
                sh_we <= 1'b1; sh_wa <= lslot; sh_wd <= {lc_first, lh3[8:0]};
                sp_we <= 1'b1; sp_wa <= lpos; sp_wd <= lslot;
                lst <= L_LINK;                                       // link[lpos]
            end
            L_LINK: if (lpos == ltail) lst <= L_DONE; else begin lpos <= lk_q; lst <= L_POS; end
            default: begin                                           // L_DONE
                if (ly == 9'd191) begin ly <= 9'd192; lst <= L_IDLE; end
                else begin ly <= ly + 9'd1; lst <= L_LINE; end
            end
        endcase
    end
    assign fs_pop = lst == L_ROOM && fs_ok && fc_n >= {{(CL-3){1'b0}}, lnv};
    assign fc_pop = lst == L_VDAT && l_beat && lw == 2'd3;
    // the loader's lines are loaded once it has passed them (or all are)
    wire           l_through = lgo && lst == L_IDLE;

    // ================================================================ PSRAM port
    // the writer first; one access at a time
    logic p_lastw;                       // the writer went last
    always_ff @(posedge clk) begin
        if (rst) begin p_busy <= 1'b0; wk <= 2'd0; p_lastw <= 1'b0; end
        else if (!p_busy) begin
            if (wq_n != '0 && !(l_req && p_lastw)) begin p_busy <= 1'b1; p_own_l <= 1'b0; p_lastw <= 1'b1; end
            else if (l_req) begin p_busy <= 1'b1; p_own_l <= 1'b1; p_lastw <= 1'b0; end
        end else if (p_ack) begin
            if (!p_own_l) begin
                wk <= wk + 2'd1;
                if (wk == 2'd3) p_busy <= 1'b0;
            end else p_busy <= 1'b0;
        end
    end
    assign p_req   = p_busy;
    assign p_we    = !p_own_l;
    assign p_addr  = p_own_l ? l_addr : {wq_ha, wk};
    assign p_wdata = wq_d;               // words 0, 1, 3, 2 (the loader needs word 3 first)

    // ================================================================ fetcher
    typedef enum logic [3:0] { F_IDLE, F_WAIT, F_HEADS, F_HEADS2, F_PICK, F_SP, F_SH, F_HDR,
                               F_VRD, F_VOUT, F_ADV, F_ADV2, F_END } fst_t;
    fst_t          fst;
    logic [7:0]    fy;
    assign diag_ld = {l_beat, l_ack, l_req && !l_ack, fst == F_WAIT && {1'b0, fy} <= y_lim};
    assign f_clr_go = f_clr && fst == F_IDLE && lst == L_IDLE;   // the loader holds no slot or chunk
    logic          fquiet;               // draining a frame's leftovers: nothing sent
    logic          fa;                   // the active list read this line
    logic [SL:0]   fa_n, fb_n, fa_i;
    logic          al_we;
    logic [SL:0]   al_wa, al_ra;
    logic [10+SL:0] al_wd, al_q;         // {position, slot}
    gpu3d_ram #(.W(11 + SL), .AW(SL + 1)) u_al (.clk, .we(al_we), .waddr(al_wa), .wdata(al_wd), .raddr(al_ra), .rdata(al_q));
    logic          ha_v, hr_v;           // heads valid: active list, arrivals
    logic [10:0]   hr_p, hr_t;           // arrival head and the line's last arrival
    logic          f_arr;
    logic [10:0]   f_pos;
    logic [SL-1:0] f_slot;
    logic [3:0]    f_k;
    logic [CL-1:0] f_c;
    logic          f_keep;
    logic          rq_v;                 // a line asked for, not yet started
    logic [7:0]    rq_y;
    wire           out_free = !ps_valid || ps_ready;
    always_ff @(posedge clk) begin
        if (rst) begin f_live <= 1'b0; f_dead <= 1'b0; f_clr <= 1'b0; end
        else begin
            if (frame_go) begin f_live <= 1'b1; f_dead <= 1'b0; end
            else if (fst == F_END && !fquiet && out_free && fy == 8'd191) f_live <= 1'b0;
            if ((so_we || so_done) && f_live && !frame_go) begin f_live <= 1'b0; f_dead <= 1'b1; end
            if (so_done && (f_dead || f_live)) f_clr <= 1'b1;
            else if (f_clr_go) f_clr <= 1'b0;
            // the raster restarts on a frame the store still draws (the DS starts every frame at line 215):
            // its slots and chunks come back as for an abandoned frame, once the loader is back at a state that
            // holds none (the next frame_go redraws the same bank: l_re). An abandoned frame (f_dead) already
            // has its clear from so_done, and the loader may hold the next bank's slots by now
            if (abort && f_live && !so_done) begin f_live <= 1'b0; f_clr <= 1'b1; end
        end
    end
`ifndef ALTERA_RESERVED_QIS
    int ab_n = 0;           // abandoned frames (the first ones are logged)
    always_ff @(posedge clk)
        if (!rst && (so_we || so_done) && f_live && !frame_go) begin
            ab_n <= ab_n + 1;
            if (ab_n < 20) $display("g3d store: frame abandoned at the next swap (line %0d, %0d so far)", fy, ab_n + 1);
        end
    always_ff @(posedge clk)
        if (!rst && abort && (f_live || f_dead))
            $display("g3d store: frame aborted by the raster's restart (line %0d, %s)", fy, f_live ? "drawing" : "abandoned");
`endif
    wire  [10:0]   ha_p = al_q[10+SL:SL];
    wire  [SL-1:0] ha_s = al_q[SL-1:0];
    always_comb begin
        // read addresses
        yt_ra  = or_q;
        // the build reads order[bpos] in B_ORD and needs it on the port
        // until B_BK, where it addresses the Y-table read that B_LINK uses
        // (the loader, the other user, never runs while the lists build)
        or_ra  = (bst == B_ORD || bst == B_YT || bst == B_BK || bst == B_LINK) ? bpos[10:0] : lpos;
        bk_ra  = (bst == B_BK || bst == B_LINK) ? b_ytop : ly[7:0];
        lk_ra  = lpos;
        bkf_ra = fy;
        lkf_ra = hr_p;
        sp_ra  = hr_p;
        sh_ra  = f_slot;
        ch_ra  = f_c;
        cn_ra  = f_c;
        al_ra  = {fa, fa_i[SL-1:0]};
    end
    assign fs_push = fst == F_ADV && !f_keep;
    assign fs_pd   = f_slot;
    assign fc_push = fst == F_VOUT && (out_free || fquiet) && !f_keep;
    assign ch_re   = PSREG || !(ps_valid && !ps_ready && ps_type == 2'd1);
    assign ps_data = PSREG ? ps_data_r : ps_type == 2'd1 ? {12'd0, ch_q} : {21'd0, sh_q[106:0]};
    assign fc_pd   = f_c;
    wire  [7:0]    f_ybot = sh_q[104:97];
    always_ff @(posedge clk) begin
        al_we <= 1'b0;
        if (ps_valid && ps_ready) ps_valid <= 1'b0;
        if (ps_line_req) begin rq_v <= 1'b1; rq_y <= ps_line_y; end
        if (rst || abort && (f_live || f_dead)) begin
            // abort: the stopped frame's beat, line request and lists go; its slots come back by f_clr
            fst <= F_IDLE; fa <= 1'b0; fa_n <= '0; fb_n <= '0; ps_valid <= 1'b0; fquiet <= 1'b0; rq_v <= 1'b0;
            ha_v <= 1'b0; hr_v <= 1'b0;
        end else case (fst)
            F_IDLE: begin
                if (f_clr) begin fa_n <= '0; fb_n <= '0; end        // the abandoned frame's lists go (f_clr_go)
                else if (frame_go && fa_n != '0) begin fquiet <= 1'b1; fst <= F_HEADS; fa_i <= '0; hr_v <= 1'b0; end
                else if (rq_v && !ps_line_req) begin fy <= rq_y; rq_v <= 1'b0; fquiet <= 1'b0; fst <= f_dead ? F_END : F_WAIT; end
            end
            F_WAIT: begin
                // the line's arrivals loaded and the 3D ring has room
                if (!l_re && (!ready || (lgo && (l_through || ly > {1'b0, fy}) && {1'b0, fy} <= y_lim))) begin
                    fa_i <= '0; fst <= F_HEADS;
                end
            end
            F_HEADS: fst <= F_HEADS2;                                // active head, bucket[fy]
            F_HEADS2: begin
                ha_v <= fa_i < fa_n;
                if (!fquiet) begin
                    hr_v <= ready && lgo && bkf_q[22] == tag;
                    hr_p <= bkf_q[21:11]; hr_t <= bkf_q[10:0];
                end
                fst <= F_PICK;
            end
            F_PICK: begin
                if (!ha_v && !hr_v) fst <= F_END;
                else if (ha_v && (!hr_v || ha_p < hr_p)) begin
                    f_arr <= 1'b0; f_pos <= ha_p; f_slot <= ha_s; fst <= F_SH;
                end else begin
                    f_arr <= 1'b1; f_pos <= hr_p; fst <= F_SP;      // pos -> slot
                end
            end
            F_SP: begin f_slot <= sp_q; fst <= F_SH; end
            F_SH: fst <= F_HDR;                                      // slot header
            F_HDR: if (out_free || fquiet) begin
                if (!fquiet) begin ps_valid <= 1'b1; ps_type <= 2'd0; if (PSREG) ps_data_r <= {21'd0, sh_q[106:0]}; end
                f_k <= sh_q[80:77]; f_c <= sh_q[127:128-CL];
                f_keep <= !fquiet && {1'b0, fy} + 9'd1 < {1'b0, f_ybot};
                fst <= F_VRD;
            end
            F_VRD: fst <= F_VOUT;                                    // chunk and its link
            F_VOUT: if (out_free || fquiet) begin
                if (!fquiet) begin ps_valid <= 1'b1; ps_type <= 2'd1; if (PSREG) ps_data_r <= {12'd0, ch_q}; end
                f_c <= cn_q; f_k <= f_k - 4'd1;
                fst <= f_k == 4'd1 ? F_ADV : F_VRD;
            end
            F_ADV: begin
                if (f_keep) begin al_we <= 1'b1; al_wa <= {!fa, fb_n[SL-1:0]}; al_wd <= {f_pos, f_slot}; fb_n <= fb_n + 1'b1; end
                if (!f_arr) begin fa_i <= fa_i + 1'b1; fst <= F_ADV2; end
                else if (hr_p == hr_t) begin hr_v <= 1'b0; fst <= F_PICK; end
                else fst <= F_ADV2;                                  // link[hr_p]
            end
            F_ADV2: begin
                if (f_arr) begin hr_p <= lkf_q; fst <= F_PICK; end
                else begin ha_v <= fa_i < fa_n; fst <= F_PICK; end   // the next active entry is read
            end
            default: begin                                           // F_END
                if (fquiet) begin
                    fa <= !fa; fa_n <= '0; fb_n <= '0; fquiet <= 1'b0; fst <= F_IDLE;
                end else if (out_free) begin
                    ps_valid <= 1'b1; ps_type <= 2'd3;
                    fa <= !fa; fa_n <= fb_n; fb_n <= '0; fst <= F_IDLE;
                end
            end
        endcase
    end
`ifndef ALTERA_RESERVED_QIS
    // the build files each position under its own polygon's ytop
    always_ff @(posedge clk)
        if (!rst && bst == B_LINK && yt_q != u_ytab.mem[u_ord.mem[bpos[10:0]]])
            $error("nds_g3d_store: building position %0d with the Y range %h of another polygon (its own: %h)",
                   bpos, yt_q, u_ytab.mem[u_ord.mem[bpos[10:0]]]);
    // the loader does not run while the lists build (they share the order RAM's port)
    always_ff @(posedge clk)
        if (!rst && building && bst != B_IDLE && bst != B_CLR && bst != B_DRAIN && lst != L_IDLE)
            $error("nds_g3d_store: the loader runs during the build");
    // u_lk's port A: a build write never meets a loader read (the loader is idle while links are written)
    always_ff @(posedge clk)
        if (!rst && lk_we && lst != L_IDLE)
            $error("nds_g3d_store: link write at %0d while the loader reads (state %0d)", lk_wa, lst);
    // a polygon goes out only for a line in [ytop, ybot], with 3..10 vertices
    always_ff @(posedge clk)
        if (!rst && fst == F_HDR && out_free && !fquiet &&
            (fy < sh_q[96:89] || fy > sh_q[104:97] || sh_q[80:77] < 4'd3 || sh_q[80:77] > 4'd10))
            $error("nds_g3d_store: polygon at slot %0d pos %0d for line %0d: ytop %0d ybot %0d nv %0d",
                   f_slot, f_pos, fy, sh_q[96:89], sh_q[104:97], sh_q[80:77]);
    // +g3dtrace: records in, beats out, PSRAM accesses
    // (+g3dtrace_from=N: from clock N on)
    bit tr_en, tr_on;
    longint tr_from, tr_cyc;
    initial begin
        tr_en = $test$plusargs("g3dtrace");
        if (!$value$plusargs("g3dtrace_from=%d", tr_from)) tr_from = 0;
        tr_cyc = 0;
    end
    always_ff @(posedge clk) begin tr_cyc <= tr_cyc + 1; tr_on <= tr_en && tr_cyc >= tr_from; end
    always_ff @(posedge clk) if (tr_on) begin
        if (po_go) $display("G3T in  %s idx %0d vptr %0d wb %0d data %h", po_type ? "V" : "H", po_index, vptr, wb, po_data);
        if (so_done) $display("G3T swap count %0d", so_count);
        if (p_req && p_ack) $display("G3T psram %s %06x %08x", p_we ? "W" : "R", {p_addr, 2'b00}, p_wdata);
        if (ps_valid && ps_ready) $display("G3T out t%0d line %0d %h", ps_type, fy, ps_data);
        if (p_rvalid) $display("G3T rd %08x", p_rdata);
        if (fst == F_HEADS) $display("G3T line %0d ready %0d lgo %0d ly %0d fa %0d fa_n %0d fb_n %0d quiet %0d", fy, ready, lgo, ly, fa, fa_n, fb_n, fquiet);
        if (fst == F_PICK) $display("G3T pick ha %0d p %0d s %0d | hr %0d p %0d t %0d", ha_v, ha_p, ha_s, hr_v, hr_p, hr_t);
        if (fst == F_SP) $display("G3T sp pos %0d -> slot %0d", f_pos, sp_q);
        if (fst == F_ADV) $display("G3T adv pos %0d slot %0d keep %0d arr %0d", f_pos, f_slot, f_keep, f_arr);
        if (sp_we) $display("G3T spw pos %0d slot %0d", sp_wa, sp_wd);
        if (b_take) $display("G3T file pos %0d ytop %0d", bpos, b_ytop);
        if (frame_go) $display("G3T frame_go fa_n %0d fst %0d", fa_n, fst);
        if (so_done) $display("G3T build start ready->0");
    end
`endif
`ifndef ALTERA_RESERVED_QIS   // (Quartus rejects $test$plusargs)
    // +g3dsmon: per frame (at frame_go), where the store's time goes: the fetcher waiting for the loader,
    // for the raster's line limit, with a beat held, idle (no line asked), walking vertex chunks; the
    // loader waiting for the PSRAM grant, for data, for free slots/chunks; the writer's port time; records
    // and chunks loaded
    bit sm_on;
    initial sm_on = $test$plusargs("g3dsmon");
    longint sm_fld, sm_flim, sm_fout, sm_fidle, sm_fv, sm_lgnt, sm_ldat, sm_lroom, sm_wr, sm_rec, sm_chk, sm_cy;
    always_ff @(posedge clk) if (sm_on && !rst) begin
        sm_cy <= sm_cy + 1;
        if (fst == F_WAIT && {1'b0, fy} > y_lim) sm_flim <= sm_flim + 1;
        else if (fst == F_WAIT) sm_fld <= sm_fld + 1;
        if (ps_valid && !ps_ready) sm_fout <= sm_fout + 1;
        if (fst == F_IDLE && !rq_v) sm_fidle <= sm_fidle + 1;
        if (fst == F_VRD || fst == F_VOUT) sm_fv <= sm_fv + 1;
        if (l_req && !l_ack) sm_lgnt <= sm_lgnt + 1;
        if ((lst == L_HDAT || lst == L_VDAT) && !l_req && !l_beat) sm_ldat <= sm_ldat + 1;
        if (lst == L_ROOM && !(fs_ok && fc_n >= {{(CL-3){1'b0}}, lnv})) sm_lroom <= sm_lroom + 1;
        if (p_busy && !p_own_l) sm_wr <= sm_wr + 1;
        if (lst == L_SLOT) sm_rec <= sm_rec + 1;
        if (fc_pop) sm_chk <= sm_chk + 1;
        if (frame_go) begin
            $display("g3dsmon: fetch wait-loader %0d wait-limit %0d out-held %0d idle %0d chunks %0d | load wait-grant %0d wait-data %0d wait-room %0d | writer %0d | records %0d chunks %0d | of %0d",
                     sm_fld, sm_flim, sm_fout, sm_fidle, sm_fv, sm_lgnt, sm_ldat, sm_lroom, sm_wr, sm_rec, sm_chk, sm_cy);
            {sm_fld, sm_flim, sm_fout, sm_fidle, sm_fv, sm_lgnt, sm_ldat, sm_lroom, sm_wr, sm_rec, sm_chk, sm_cy} <= '0;
        end
    end
`endif
endmodule

// A list of free indices, full after reset (0 .. 2^W-1), as a FIFO: q is
// the next free one when ok. A pop or a push into an empty list takes a
// cycle to show (the RAM reads q at the read pointer).
module nds_g3d_fl #(
    parameter int W = 9
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         clr,            // start again full (as after reset)
    input  logic         pop,
    input  logic         push,
    input  logic [W-1:0] pd,
    output logic [W-1:0] q,
    output logic         ok,
    output logic [W:0]   n
);
    logic [W-1:0] rp, wp, ic;
    logic         init, settle;
    gpu3d_ram #(.W(W), .AW(W)) u_m (.clk, .we(init || push), .waddr(init ? ic : wp), .wdata(init ? ic : pd),
        .raddr(rp), .rdata(q));
    always_ff @(posedge clk) begin
        if (rst || clr) begin
            init <= 1'b1; ic <= '0; rp <= '0; wp <= '0; n <= '0; settle <= 1'b1;
        end else if (init) begin
            ic <= ic + 1'b1;
            if (&ic) begin init <= 1'b0; n <= {1'b1, {W{1'b0}}}; end
        end else begin
            if (pop) rp <= rp + 1'b1;
            if (push) wp <= wp + 1'b1;
            n <= n + (push ? 1'b1 : 1'b0) - (pop ? 1'b1 : 1'b0);
            settle <= pop || (push && n == '0);
        end
    end
    assign ok = !init && !settle && n != '0;
`ifndef ALTERA_RESERVED_QIS
    // every index is in the list once: a push into a full list is a double free
    always_ff @(posedge clk)
        if (!rst && !init && push && !pop && n[W]) $error("nds_g3d_fl: push into a full list (index %0d freed twice)", pd);
`endif
endmodule
