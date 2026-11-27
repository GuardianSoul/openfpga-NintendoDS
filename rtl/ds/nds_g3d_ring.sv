// The 3D line ring in SDRAM (docs/budget-3d.md, "The SDRAM line ring"):
// the raster may run up to LEAD lines ahead of the line the display composes
// (the DS's 48-line buffer, RDLINES 46), with only two lines on chip each way.
//   - write: the final pass writes each line into a 2-line staging RAM; it
//     then goes to SDRAM as 32 blocks of 8 pixels (one per word), line y at
//     BASE + y * 1 KiB;
//   - read: the 2D engine composes line d from a 2-line read buffer (slot
//     d[0]); line d + 1 is read into the other slot while d is composed, once
//     it is in SDRAM. A line not there in time is late, as before (the
//     buffer shows what the slot held).
// The pixels the 2D engine reads are the raster's; only the time a line is
// ready changes. A block once requested always completes (also across a
// frame start). Reads go before writes: they have the display's deadline.
module nds_g3d_ring #(
    parameter int          LEAD = 46,
    // YLAG: lines the final pass is behind the store's line at least (2 in
    // the core: the final pass of line f starts once line f+1 is rendered);
    // the store may stream 3 + YLAG lines past the last one written. With
    // YLAG > 0 the final pass holds on a staging slot still full (st_busy)
    parameter int          YLAG = 0,
    // LLR: a needed line the raster has started but not finished in time is
    // copied from the raster's line buffer as drawn so far (ll_*: the DS shows
    // a late line's polygons drawn so far over the clear colour, hwref run
    // 33), LC_AT clocks after the last line's composition began; a complete
    // line still replaces it before its composition
    parameter bit          LLR = 0,
    parameter bit          COPY_SHARE = 0, // mutually exclusive staging/late-copy metadata
    parameter int          LC_AT = 3600,
    // RPRI: the display's line first. The read of the needed line (its next
    // block, a copy from staging, or its start) goes before a staged line's
    // write; with writes first, a raster running lines ahead keeps the write
    // side busy and the needed line's read misses its composition (MKDS's
    // pre-race pan: ~20 lines a frame shown as the rear plane)
    parameter bit          RPRI = 0,
    // WYLD (with RPRI): a line's write gives way to the needed line's read at
    // each block boundary, not only between lines. A line write is 32 blocks
    // into the SDRAM write FIFO, which drains only while no read waits: one
    // that began just before the needed line's turn held its read 2,600 clk
    // (MKDS Figure-8 in race, line 49 delivery-late with RPRI). The write
    // resumes at its next block: W0's idle read of the staging RAM (below)
    // then reads that block's first word
    parameter bit          WYLD = 0,
    // NX2: once the line being composed has been swept (its 256 reads) and the
    // needed line is in, line dline+2 is read (or copied) into the swept
    // line's slot: the display asks for a line out of order when the 2D engine
    // is late (nds_disp skips a late line's BG job), and the line after the
    // skipped one is then there
    parameter bit          NX2 = 0,
    // TR3 (gpu3d_raster TR3): the raster's line buffers are three slots
    // (line mod 3): the LLR copy's slot and "newest in its slot" follow
    parameter bit          TR3 = 0,
    // RH_AT: the needed line's read is urgent once the line being composed
    // began this many clocks ago (a line takes 4,260): rg_hurry asks the
    // SDRAM bus to serve the ring's port before the others. 0: never
    parameter int          RH_AT = 0,
    // RING3 (S2c step A): three read slots (line mod 3, read RAM 768 of 1,024
    // words): once the needed line is in, line need+1 is read (or copied) into
    // the third slot, so a line need not wait for the composition of the line
    // before it to begin. The prefetch does not go before a staged line's write
    // (RPRI is the needed line's), and a direct line taking the RAM's write port
    // voids a read (as a copy). 0: two slots by line parity (RC7)
    parameter bit          RING3 = 0,
    parameter logic [23:0] BASEW = 24'h080000 // SDRAM word (4 bytes) address of byte 0x200000
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         frame_go,      // a frame starts: the last one's lines are dropped
    input  logic         l3d_go,        // the 2D engine starts composing l3d_line
    input  logic [7:0]   l3d_line,
    input  logic [7:0]   l3d_raddr,     // the pixel it reads (registered RAM: data next clock)
    output logic [22:0]  l3d_rdata,
    output logic [8:0]   y_lim,         // the last line the store may stream now
    output logic         l3d_have,      // the read buffer holds line l3d_line (nds_gpu3d: else the line shows the rear plane)
    output logic [3:0]   st_busy,       // staging slot holds a line not yet written out
    // LLR: the raster's front line, its final pass, and the slot read
    input  logic [8:0]   r_go,          // lines 0 .. r_go-1 started this frame
    input  logic [7:0]   fp_line,
    input  logic         fp_act,
    output logic         ll_rd,
    output logic [1:0]   ll_slot,
    output logic [7:0]   ll_x,
    input  logic         ll_ack,
    input  logic [22:0]  ll_q,
    // the raster's final pass: each line's 256 pixels, x ascending
    input  logic         px_valid,
    input  logic [7:0]   px_x,
    input  logic [7:0]   px_y,
    input  logic [22:0]  px_color,
    // the SDRAM ring ports (core_top_ds RING): a block write is 8 consecutive
    // words, one per rg_wack; a block read is held until rg_rack, then 8
    // rg_rvalid words
    output logic         rg_wreq,
    output logic [23:0]  rg_waddr,
    output logic [31:0]  rg_wdata,
    input  logic         rg_wack,
    output logic         rg_rreq,
    output logic         rg_hurry,      // RH_AT: the read in progress is the needed line, late in its composition
    output logic [23:0]  rg_raddr,
    input  logic         rg_rack,
    input  logic         rg_rvalid,
    input  logic [31:0]  rg_rdata,
    input  logic         rg_wdrained    // every word written so far has reached SDRAM (lags; drops after a write)
);
    // ---- the display side: d is the line being composed (as nds_gpu3d's dline)
    // (l3d_line follows l3d_go by a clock: nds_disp registers it then)
    logic [7:0]  dline;
    logic        d_on;              // a line of this frame has been composed
    logic        go_q;
    always_ff @(posedge clk) begin
        go_q <= !rst && l3d_go;
        if (rst || frame_go) begin dline <= 8'd0; d_on <= 1'b0; end
        else if (go_q) begin dline <= l3d_line; d_on <= 1'b1; end
    end

    // ---- write side
    logic [8:0]  wdone;             // lines below wdone are written (into the write FIFO)
    logic [8:0]  wdone_q, wsafe;    // lines below wsafe have reached SDRAM: wdone a clock old, taken while drained
    // staging: 4 lines (slot = y[1:0]). The raster holds about three lines
    // between the store and its final pass, so the store may stream up to
    // three lines past the last one written (with 2 lines and one, the raster
    // waited on the writes: KH plaza 284-318K clocks a frame)
    logic [3:0]  st_full;           // staging slot holds a finished line
    // staging slot s holds line {st_t[s], s}: only y[7:2] is kept (the slot is y[1:0])
    logic [5:0]  st_t [4];
    logic [3:0]  st_pres;           // ... still holds it (finished, not yet overwritten), written out or not
    wire  [8:0]  lead_lim = {1'b0, dline} + 9'(LEAD);
    assign y_lim = lead_lim < wdone + 9'(3 + YLAG) ? lead_lim : wdone + 9'(3 + YLAG);
    assign st_busy = st_full;
    // the block engine's state (its steps below)
    typedef enum logic [2:0] { E_IDLE, E_WREQ, E_WDAT, E_RREQ, E_RDAT, E_COPY, E_LCOPY } est_t;
    est_t        est;
    logic [4:0]  blk;               // the write's block
    logic        w_mid;             // WYLD: the oldest staged line's write paused at block blk
    logic [9:0]  sr_a;              // the write's next word {slot, x}
    logic [22:0] st_q;
    // W0: the staging RAM's read is registered and rg_wack may come in E_WDAT's
    // first clock (core_top_ds: rg_wack = rg_go), so word 0 of the next line to
    // write ({wdone[1:0], 0}) is read while the engine is idle. Before, the
    // first word was whatever sr_a pointed at then: right only when the last
    // operation was the previous line's write (sr_a ends on the next slot's
    // word 0); after a staging copy it was a stale word (x = 0 of a line in
    // SDRAM: Golden Sun's continue screen, the bottom screen's far-left column)
`ifdef RING_W0_MUT
    wire  [9:0]  st_ra = rg_wack ? sr_a + 10'd1 : sr_a;
`else
    // (WYLD: a paused write resumes at its block, so the idle read is that block's word 0)
`ifdef G3D_WYLD_MUT
    wire  [9:0]  st_ra = rg_wack ? sr_a + 10'd1 : est == E_IDLE ? {wdone[1:0], 8'd0} : sr_a;   // (mutant: the line's word 0)
`else
    wire  [9:0]  st_ra = rg_wack ? sr_a + 10'd1 : est == E_IDLE ? {wdone[1:0], WYLD && w_mid ? blk : 5'd0, 3'd0} : sr_a;
`endif
`endif
    gpu3d_ram #(.W(23), .AW(10)) u_stage (.clk, .we(px_valid), .waddr({px_y[1:0], px_x}),
        .wdata(px_color), .raddr(st_ra), .rdata(st_q));

    // ---- read side: slot = line[0] (RING3: line mod 3)
    logic [2:0]  rb_v;              // slot holds rb_y's line, complete
    logic [2:0]  rb_p;              // LLR: ... as drawn so far (a complete one may replace it)
    logic [7:0]  rb_y [3];
    logic [1:0]  rd_s;              // RING3: the read's slot (registered with rd_y)
    logic        rd_ab;             // RING3: a direct line took the write port during the read: void
    logic        rd_on;             // a line is being read into slot rd_y[0]
    logic [7:0]  rd_y;
    logic [2:0]  rk;                // word within the block
    // the next line the display needs: d + 1 while composing d (0 before the frame's first)
    wire  [7:0]  need = d_on ? dline + 8'd1 : 8'd0;
    // direct: the raster's line is the one needed next (and not being read):
    // its pixels go into the read buffer as well, so a line finished just in
    // time does not wait for its SDRAM round trip
    logic        dir;               // the line being written goes in directly
    wire         dir_now = (px_x == 8'd0) ? (px_y == need && !(rd_on && rd_y == need)) : dir;
    wire         rb_we_px = px_valid && dir_now;
    // copy: a needed line still in staging goes into the read buffer from
    // there, one word a clock, without its SDRAM round trip (whose read waits
    // for the writes to drain: phase1's ring underruns at a frame's top lines)
    logic [7:0]  cp_y;
    logic [1:0]  cp_s;
    logic [8:0]  cp_x;              // the word written this clock (0-255; 256 = done)
    wire         cp_we = est == E_COPY && cp_x != 9'd0 && !cp_ab;
    logic        cp_ab;             // the raster began overwriting the slot: the copy is void
    // LLR: the line-buffer copy (lc_*: the word read last clock is written now)
    logic [7:0]  lc_y_raw;
    wire  [7:0]  lc_y = COPY_SHARE ? cp_y : lc_y_raw;
    logic [8:0]  lc_x_raw;
    wire  [8:0]  lc_x = COPY_SHARE ? cp_x : lc_x_raw; // next word to read (256: all read)
    logic        lc_pv, lc_ab, lc_pend;
    logic [7:0]  lc_px;
    logic [11:0] lc_cnt;            // clocks since the last line's composition began
    wire         lc_we = est == E_LCOPY && lc_pv && !lc_ab && !rb_we_px;
    assign ll_rd   = LLR && est == E_LCOPY && !lc_x[8] && !lc_ab;
    function automatic [1:0] m3(input [7:0] v);   // v mod 3 (4 = 1 mod 3)
        logic [3:0] a;
        a = 4'(v[7:6]) + 4'(v[5:4]) + 4'(v[3:2]) + 4'(v[1:0]);
        a = 4'(a[3:2]) + 4'(a[1:0]);
        m3 = (a >= 4'd3) ? 2'(a - 4'd3) : a[1:0];
    endfunction
    // RING3: v mod 3 as a tree of 4-input mod-3 sums of its 2-bit digits (LUTs, no
    // carry chains; m3 above is the same function)
    localparam logic [31:0] A3T = 32'h24924924;   // {x, y}: (x + y) mod 3, a digit 3 counting 0
    function automatic [1:0] a3(input [1:0] x, input [1:0] y);
        a3 = A3T[{x, y, 1'b0} +: 2];
    endfunction
    function automatic [1:0] rs(input [7:0] v);  // the read slot of line v
        rs = RING3 ? a3(a3(v[7:6], v[5:4]), a3(v[3:2], v[1:0])) : {1'b0, v[0]};
    endfunction
    localparam int RAW = RING3 ? 10 : 9;
    logic [1:0]  cp_r, lc_r;        // RING3: the copy's / LLR copy's read slot
    wire  [1:0]  cp_rs = RING3 ? cp_r : {1'b0, cp_y[0]};
    wire  [1:0]  lc_rs = RING3 ? lc_r : {1'b0, lc_y[0]};
    wire  [1:0]  rd_rs = RING3 ? rd_s : {1'b0, rd_y[0]};
    wire  [1:0]  l3_s  = rs(l3d_line);
    logic [1:0]  lc_y3_raw;
    wire  [1:0]  lc_y3 = COPY_SHARE ? cp_s : lc_y3_raw; // registered line mod 3
    assign ll_slot = TR3 ? lc_y3 : lc_y[1:0];
    assign ll_x    = lc_x[7:0];
    wire  [9:0]  rb_wa = rb_we_px ? {rs(px_y), px_x} : cp_we ? {cp_rs, 8'(cp_x - 9'd1)} : lc_we ? {lc_rs, lc_px} : {rd_rs, rblk, rk};
    wire  [9:0]  rb_ra = {l3_s, l3d_raddr};
    gpu3d_ram #(.W(23), .AW(RAW)) u_rbuf (.clk, .we(rb_we_px || (rg_rvalid && rd_on && !drop) || cp_we || lc_we),
        .waddr(rb_wa[RAW-1:0]),
        .wdata(rb_we_px ? px_color : cp_we ? st_q : lc_we ? ll_q : rg_rdata[22:0]), .raddr(rb_ra[RAW-1:0]), .rdata(l3d_rdata));
    assign l3d_have = rb_v[l3_s] && rb_y[l3_s] == l3d_line;
    // RING3: the needed line's slot from dline mod 3, registered as the composition
    // begins (d3), not from need's own mod-3 tree; the prefetch's slot is the next
    function automatic [1:0] inc3(input [1:0] v); inc3 = v == 2'd2 ? 2'd0 : v + 2'd1; endfunction
    logic [1:0]  d3;                // RING3: dline mod 3
    always_ff @(posedge clk) if (go_q) d3 <= l3_s;   // (unused before the frame's first composition: need_s 0)
    wire  [1:0]  need_s = RING3 ? (d_on ? inc3(d3) : 2'd0) : rs(need);
    wire         rb_full_need = rb_v[need_s] && rb_y[need_s] == need && !rb_p[need_s];
    // NX2: the line read or copied next: the needed one, or once it is in and
    // the composed line swept, dline+2 (same slot as dline)
    logic        sw_done;           // the composed line's 256 reads are done
    always_ff @(posedge clk)
        if (rst || frame_go || go_q) sw_done <= 1'b0;
        else if (d_on && l3d_raddr == 8'd255) sw_done <= 1'b1;
    wire  [7:0]  need2 = dline + 8'd2;
    wire         nx2_on = NX2 && d_on && sw_done && rb_full_need && dline < 8'd190;
    // RING3: the line after the needed one once that is in (its slot is the
    // composed line's predecessor's)
    wire         r3_on = RING3 && rb_full_need;   // (need 191: tgt 192 is not read)
    wire  [7:0]  tgt = r3_on ? need + 8'd1 : nx2_on ? need2 : need;
    wire  [1:0]  tgt_s = RING3 ? (r3_on ? inc3(need_s) : need_s) : rs(tgt);
    wire         rb_full_tgt = rb_v[tgt_s] && rb_y[tgt_s] == tgt && !rb_p[tgt_s];
    wire         rd_ok = tgt < 8'd192 && {1'b0, tgt} < wsafe && !rb_full_tgt &&
                         !(dir && px_y == tgt);
    wire         cp_ok = tgt < 8'd192 && st_pres[tgt[1:0]] && st_t[tgt[1:0]] == tgt[7:2] &&
                         !rb_full_tgt && !(dir && px_y == tgt);
    // LLR: the needed line not available otherwise, started by the raster and
    // still the newest line in its slot (one of the last four started), not
    // through the final pass yet (a finished line's slot is cleared: it is in
    // staging or on its way to SDRAM), its slot not read by the final pass
    // (its lines f-1..f+1)
    // the final pass waiting for its staging slot (nds_gpu3d fp_hold): only the
    // ring's writes free it, so no line-buffer copy then. The raster refuses the
    // copy's reads while the final pass reads that slot (lines f-1 .. f+1), and a
    // held final pass keeps them: a copy waiting on it would never end
    wire         fp_wait = fp_act && st_full[fp_line[1:0]];
    // lines the final pass has finished this frame (a line ends as fp_act falls)
    logic [8:0]  fp_d;
    logic        fp_act_q;
    always_ff @(posedge clk) begin
        fp_act_q <= fp_act;
        if (rst || frame_go) fp_d <= 9'd0;
        else if (fp_act_q && !fp_act) fp_d <= {1'b0, fp_line} + 9'd1;
    end
    wire         lc_ok = LLR && need < 8'd192 && !(rb_v[need_s] && rb_y[need_s] == need) && !cp_ok && !rd_ok &&
                         !(rd_on && rd_y == need) && !(dir && px_y == need) && {1'b0, need} < r_go && {1'b0, need} + (TR3 ? 9'd3 : 9'd4) >= r_go &&
                         {1'b0, need} >= fp_d && (!fp_act || {1'b0, fp_line} + 9'd1 < {1'b0, need}) && !fp_wait;

    // LLR: the copy's trigger, LC_AT clocks into the composition of the line
    // before the needed one (a line takes 4,260 clocks)
    always_ff @(posedge clk)
        if (rst || !LLR) begin lc_cnt <= 12'd0; lc_pend <= 1'b0; end
        else begin
            if (l3d_go) lc_cnt <= 12'd0;
            else if (lc_cnt != 12'hFFF) lc_cnt <= lc_cnt + 12'd1;
            if (l3d_go || frame_go || (est == E_IDLE && lc_pend && lc_ok)) lc_pend <= 1'b0;
            else if (lc_cnt == 12'(LC_AT)) lc_pend <= 1'b1;
        end

    // ---- the block engine: reads first
    logic        drop;              // a frame started during this transfer: finish the block, keep nothing
    logic [1:0]  w_slot;
    logic [4:0]  rblk;              // the read's block
    logic [2:0]  w;
    // RPRI: a read of the needed line waits or runs (RING3: the prefetch of need+1 does not count)
    wire         r_pend = RING3 ? ((rd_on && !drop && rd_y == need) || ((cp_ok || rd_ok) && !r3_on))
                                : ((rd_on && !drop) || cp_ok || rd_ok);
    assign rg_wreq  = est == E_WDAT;
    assign rg_waddr = BASEW + {8'd0, st_t[w_slot], w_slot, blk, w};
    assign rg_wdata = {9'd0, st_q};
    assign rg_rreq  = est == E_RREQ;
    logic [11:0] rh_n;              // RH_AT: clocks since the last line's composition began
    always_ff @(posedge clk) begin
        if (rst || l3d_go || RH_AT == 0) rh_n <= 12'd0;
        else if (rh_n != 12'hFFF) rh_n <= rh_n + 12'd1;
`ifdef S2C_RH_ALL
        // S2c priority-only run (simulation only): every ring read urgent while the display runs
        rg_hurry <= !rst && d_on && rd_on;
`else
        rg_hurry <= RH_AT != 0 && !rst && d_on && rd_on && rd_y == need && rh_n >= 12'(RH_AT);
`endif
    end
    assign rg_raddr = BASEW + {8'd0, rd_y, rblk, 3'd0};

    always_ff @(posedge clk) begin
        if (rst) begin
            wdone <= 9'd0; wdone_q <= 9'd0; wsafe <= 9'd0;
            st_full <= 4'b0000; rb_v <= 3'b000; rd_on <= 1'b0; est <= E_IDLE; drop <= 1'b0; dir <= 1'b0; rb_p <= 3'b000;
            st_pres <= 4'b0000; w_mid <= 1'b0;
        end else begin
            wdone_q <= wdone;
            if (rg_wdrained) wsafe <= wdone_q;
            if (px_valid && px_x == 8'd0) dir <= dir_now;
            if (px_valid && px_x == 8'd0) st_pres[px_y[1:0]] <= 1'b0;   // the slot's new line begins
            if (px_valid && px_x == 8'hFF) begin
                st_full[px_y[1:0]] <= 1'b1; st_t[px_y[1:0]] <= px_y[7:2]; st_pres[px_y[1:0]] <= 1'b1;
                if (dir_now) begin rb_v[rs(px_y)] <= 1'b1; rb_y[rs(px_y)] <= px_y; rb_p[rs(px_y)] <= 1'b0; end
            end
            case (est)
                // writes first (a full staging stops the raster; the read has
                // the rest of the line), and a read gives way after each block
                E_IDLE: begin
                    // LLR: a late line's copy first (its composition is near)
                    if (lc_pend && lc_ok) begin
                        lc_y_raw <= need; lc_y3_raw <= m3(need); lc_x_raw <= 9'd0;
                        // E_COPY and E_LCOPY cannot overlap. Each initializes the
                        // shared metadata before its first qualified RAM access.
                        if (COPY_SHARE) begin cp_y <= need; if (TR3) cp_s <= m3(need); cp_x <= 9'd0; end
                        lc_pv <= 1'b0; lc_ab <= 1'b0; rb_v[need_s] <= 1'b0; lc_r <= need_s;
                        est <= E_LCOPY;
                    // lines finish in order: the oldest staged line is wdone's
                    end else if (st_full[wdone[1:0]] && !(RPRI && r_pend)) begin
                        // (WYLD: a paused write resumes at its block; w_slot is wdone[1:0] then too)
                        w_slot <= wdone[1:0]; w <= 3'd0; w_mid <= 1'b0;
                        blk <= WYLD && w_mid ? blk : 5'd0;
                        sr_a <= {wdone[1:0], WYLD && w_mid ? blk : 5'd0, 3'd0};
                        est <= E_WDAT;
                    end else if (rd_on && !drop) begin
                        est <= E_RREQ;                        // the line being read: its next block
                    end else if (cp_ok) begin
                        cp_y <= tgt; cp_s <= tgt[1:0]; cp_x <= 9'd0; cp_ab <= 1'b0; rb_v[tgt_s] <= 1'b0; cp_r <= tgt_s;
                        sr_a <= {tgt[1:0], 8'd0}; est <= E_COPY;
                    end else if (rd_ok) begin
                        rd_y <= tgt; rd_on <= 1'b1; rb_v[tgt_s] <= 1'b0; rblk <= 5'd0; est <= E_RREQ; rd_s <= tgt_s; rd_ab <= 1'b0;
                    end
                end
                E_WDAT: if (rg_wack) begin
                    sr_a <= sr_a + 10'd1; w <= w + 3'd1;
                    if (w == 3'd7) begin
                        blk <= blk + 5'd1;
                        if (drop) begin drop <= 1'b0; est <= E_IDLE; end
                        else if (blk == 5'd31) begin
                            st_full[w_slot] <= 1'b0; wdone <= {1'b0, st_t[w_slot], w_slot} + 9'd1; est <= E_IDLE;
                        end else if (WYLD && RPRI && r_pend) begin est <= E_IDLE; w_mid <= 1'b1; end
                    end
                end
                E_RREQ: if (rg_rack) begin rk <= 3'd0; est <= E_RDAT; end
                E_LCOPY: begin
                    lc_pv <= ll_ack; lc_px <= lc_x[7:0];
                    if (ll_ack) begin lc_x_raw <= lc_x + 9'd1; if (COPY_SHARE) cp_x <= lc_x + 9'd1; end
                    if (rb_we_px) lc_ab <= 1'b1;              // a direct line takes the port: void
                    if (fp_wait) est <= E_IDLE;                // the final pass waits for a write: void, at once
                    else if (lc_x[8] && !lc_pv) begin
                        if (!lc_ab && !rb_we_px) begin rb_v[lc_rs] <= 1'b1; rb_y[lc_rs] <= lc_y; rb_p[lc_rs] <= 1'b1; end
                        est <= E_IDLE;
                    end
                end
                E_COPY: begin
                    // raddr is sr_a: word cp_x arrives (st_q) the clock after, written at cp_x + 1
                    sr_a <= sr_a + 10'd1; cp_x <= cp_x + 9'd1;
                    // void if the raster starts overwriting the slot, or a direct line takes the
                    // read buffer's write port
                    if ((px_valid && px_x == 8'd0 && px_y[1:0] == cp_s) || rb_we_px) cp_ab <= 1'b1;
                    if (cp_x == 9'd256) begin
                        if (!cp_ab && !(px_valid && px_x == 8'd0 && px_y[1:0] == cp_s) && !rb_we_px) begin
                            rb_v[cp_rs] <= 1'b1; rb_y[cp_rs] <= cp_y; rb_p[cp_rs] <= 1'b0;
                        end
                        est <= E_IDLE;
                    end
                end
                default: if (rg_rvalid) begin           // E_RDAT
                    rk <= rk + 3'd1;
                    if (RING3 && rb_we_px) rd_ab <= 1'b1;   // the direct line took the word's write: void
                    if (rk == 3'd7) begin
                        rblk <= rblk + 5'd1;
                        if (drop) begin drop <= 1'b0; rd_on <= 1'b0; end
                        else if (rblk == 5'd31) begin
                            if (!(RING3 && (rd_ab || rb_we_px))) begin rb_v[rd_rs] <= 1'b1; rb_y[rd_rs] <= rd_y; rb_p[rd_rs] <= 1'b0; end
                            rd_on <= 1'b0;
                        end
                        est <= E_IDLE;
                    end
                end
            endcase
            if (frame_go) begin
                wdone <= 9'd0; wdone_q <= 9'd0; wsafe <= 9'd0; st_full <= 4'b0000; rb_v <= 3'b000; rb_p <= 3'b000; dir <= 1'b0;
                if (est == E_LCOPY) est <= E_IDLE;              // (a line-buffer copy: dropped)
                st_pres <= 4'b0000; w_mid <= 1'b0;
                if (est == E_COPY) begin cp_ab <= 1'b1; end    // (the copy's last clock leaves rb_v clear)
                else if (est != E_IDLE) drop <= 1'b1;          // a request once out completes
                else rd_on <= 1'b0;                            // a read between its blocks: dropped
            end
        end
    end
`ifdef G3D_RING_WHY
    // S2c step 0 (simulation only, no design signal driven): why a line is not in
    // the read buffer at its composition. Per line of the current frame:
    //   t_fin   its final pass ended (in staging from then on: a copy may start)
    //   t_sd    it reached SDRAM (wsafe > y)
    //   t_need  it became the needed line (composition of y-1 began)
    //   t3      the earliest a third read slot (line mod 3) could start it:
    //           max(t_fin, composition of y-2 began, y-1 complete in the buffer)
    //   t_st    its read or copy began (first time)
    // and, from max(t_need, t_fin) until it is complete, the engine's clocks:
    //   cw write blocks, crq/crd its read's request/data waits, ccp its copy,
    //   coth other lines' reads/copies/LLR copies, cidle idle (nothing eligible)
    // RWHY is printed for every composed line not in the buffer (nds_gpu3d's
    // lv_go clock, same as the raster observer's ROW).
    longint wy_cyc = 0, wy_gen = 0;
    longint wy_fin[256], wy_sd[256], wy_need[256], wy_go[256], wy_full[256], wy_st[256];
    longint wy_cw[256], wy_crq[256], wy_crd[256], wy_ccp[256], wy_coth[256], wy_cidle[256], wy_lost[256];
    integer wy_blk[256];
    integer wy_fd = 0, wy_sdp = 0;
    initial begin
        string fn;
        if ($value$plusargs("ringwhy=%s", fn)) wy_fd = $fopen(fn, "w");
        foreach (wy_fin[i]) begin wy_fin[i] = -1; wy_sd[i] = -1; wy_need[i] = -1; wy_go[i] = -1; wy_full[i] = -1; wy_st[i] = -1;
            wy_cw[i] = 0; wy_crq[i] = 0; wy_crd[i] = 0; wy_ccp[i] = 0; wy_coth[i] = 0; wy_cidle[i] = 0; wy_lost[i] = 0; wy_blk[i] = 0; end
    end
    // the engine's steps (est changes, need changes), the last 400, dumped with each RWHY (RWEV)
    string  wy_ev [$];
    est_t   wy_est = E_IDLE;
    logic [7:0] wy_nd = 8'd0;
    always @(posedge clk) if (wy_fd != 0 && !rst) begin
        longint e, t3, g2;
        int y;
        wy_cyc++;
        if (est != wy_est || need != wy_nd) begin
            wy_ev.push_back($sformatf("%0d,%0d,need=%0d,tgt=%0d,rd_on=%0d,rd_y=%0d,rblk=%0d,wslot=%0d,wy=%0d,wblk=%0d,st_full=%b,wdone=%0d,wsafe=%0d,rb_v=%b,rb_y=%0d/%0d/%0d,dir=%0d,px_y=%0d,drained=%0d",
                wy_cyc, est, need, tgt, rd_on, rd_y, rblk, w_slot, {st_t[w_slot], w_slot}, blk, st_full, wdone, wsafe, rb_v, rb_y[0], rb_y[1], rb_y[2], dir, px_y, rg_wdrained));
            if (wy_ev.size() > 400) void'(wy_ev.pop_front());
            wy_est = est; wy_nd = need;
        end
        if (frame_go) begin
            wy_gen++; wy_sdp = 0;
            foreach (wy_fin[i]) begin wy_fin[i] = -1; wy_sd[i] = -1; wy_need[i] = -1; wy_go[i] = -1; wy_full[i] = -1; wy_st[i] = -1;
                wy_cw[i] = 0; wy_crq[i] = 0; wy_crd[i] = 0; wy_ccp[i] = 0; wy_coth[i] = 0; wy_cidle[i] = 0; wy_lost[i] = 0; wy_blk[i] = 0; end
        end else begin
            if (px_valid && px_x == 8'hFF) wy_fin[px_y] = wy_cyc;
            while (wy_sdp < 192 && 9'(wy_sdp) < wsafe) begin wy_sd[wy_sdp] = wy_cyc; wy_sdp++; end
            if (wy_need[need] < 0) wy_need[need] = wy_cyc;
            if (go_q) wy_go[l3d_line] = wy_cyc;
            for (int s = 0; s < 3; s++) if (rb_v[s] && !rb_p[s]) begin
                if (wy_full[rb_y[s]] < 0) wy_full[rb_y[s]] = wy_cyc;
            end
            // a line complete once, gone before its composition
            for (int s = 0; s < 3; s++) begin
                y = int'(rb_y[s]);
                if (wy_full[y] >= 0 && wy_go[y] < 0 && !(rb_v[s] && !rb_p[s])) wy_lost[y] = 1;
            end
            if (est == E_RREQ && rd_on && rblk == 5'd0 && wy_st[rd_y] < 0) wy_st[rd_y] = wy_cyc;
            if (est == E_COPY && cp_x == 9'd0 && wy_st[cp_y] < 0) wy_st[cp_y] = wy_cyc;
            if (est == E_RDAT && rg_rvalid && rk == 3'd7 && !drop) wy_blk[rd_y]++;
            // the needed line's clocks, once eligible (needed and finished) until complete
            y = int'(need);
            if (d_on && need < 8'd192 && wy_need[y] >= 0 && wy_fin[y] >= 0 && !rb_full_need) begin
                if (est == E_WDAT || est == E_WREQ) wy_cw[y]++;
                else if (est == E_RREQ && rd_y == need) wy_crq[y]++;
                else if (est == E_RDAT && rd_y == need) wy_crd[y]++;
                else if (est == E_COPY && cp_y == need) wy_ccp[y]++;
                else if (est != E_IDLE) wy_coth[y]++;
                else wy_cidle[y]++;
            end
        end
        // nds_gpu3d's lv_go is go_q: the composed line is l3d_line now
        if (go_q && !l3d_have) begin
            y = int'(l3d_line);
            g2 = (y >= 2) ? wy_go[y-2] : 0;
            t3 = wy_fin[y];
            if (g2 > t3) t3 = g2;
            if (y >= 1 && wy_full[y-1] > t3) t3 = wy_full[y-1];
            if (y >= 1 && wy_full[y-1] < 0) t3 = -1;   // y-1 never complete before y's composition
            $fdisplay(wy_fd, "RWHY,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                wy_cyc, wy_gen, y, wy_fin[y], wy_sd[y], wy_need[y], t3, wy_st[y], wy_full[y], wy_blk[y],
                wy_cw[y], wy_crq[y], wy_crd[y], wy_ccp[y], wy_coth[y], wy_cidle[y], wy_lost[y],
                rd_on && rd_y == l3d_line, est, rb_p[l3_s], wy_go[y > 0 ? y-1 : 0], fp_d);
            foreach (wy_ev[i]) begin
                longint c;
                void'($sscanf(wy_ev[i], "%d,", c));
                if (c + 9000 >= wy_cyc) $fdisplay(wy_fd, "RWEV,%0d,%0d,%s", wy_gen, y, wy_ev[i]);
            end
        end
    end
`endif
`ifndef SYNTHESIS
`ifndef G3D_ABL_RING   // (S2b ideal ring: this ring is cut off, its staging never drains)
    always_ff @(posedge clk) if (!rst && px_valid && px_x == 8'd0 && st_full[px_y[1:0]])
        $error("nds_g3d_ring: staging slot %0d still holds line %0d (line %0d)", px_y[1:0], {st_t[px_y[1:0]], px_y[1:0]}, px_y);
`endif
`endif
`ifndef ALTERA_RESERVED_QIS
    // simulation: every word the write side hands the SDRAM is the staged pixel at its {slot, x}
    logic [22:0] st_sh [1024];
    always @(posedge clk) if (!rst) begin
        if (rg_wreq && rg_wack && !drop && rg_wdata[22:0] !== st_sh[{w_slot, blk, w}])
            $error("nds_g3d_ring: ring write of line %0d x %0d is %h, staged %h", {st_t[w_slot], w_slot}, {blk, w}, rg_wdata[22:0], st_sh[{w_slot, blk, w}]);
        if (px_valid) st_sh[{px_y[1:0], px_x}] <= px_color;
    end
`endif
endmodule
