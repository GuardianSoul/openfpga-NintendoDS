// The ARM7's two ports (docs/phase2-integration.md, "ARM7 port"). The
// pipeline asks in one cycle and takes the answer (ok + data) in the next;
// an access it does not get answered is replayed (docs/arm-pipeline.md,
// "Third round"). A fetch (F) and a data access (E3) of the ARM7 can come in
// the same cycle, so each RAM gives the fetch one port and the data access
// another.
//
// Boot ROM (0x00008000-0x00009FFF), M10K, answered the next cycle; the
// fabric uses its port B in cycles without an ARM7 data access (d_boot).
//
// BIOS7, shared WRAM and ARM7 WRAM live in the external SRAM (x_*, "First
// fit with 3D"), at SRAM byte addresses:
//   0x00000-0x0FFFF  ARM7 WRAM (64 KiB, 0x03800000-)
//   0x10000-0x17FFF  shared WRAM (32 KiB, as WRAMCNT maps it)
//   0x18000-0x1BFFF  BIOS7 (16 KiB)
// in front of which sit a 2 KiB fetch cache and a 1 KiB write-through data
// cache (direct-mapped, 16-byte lines, by SRAM address). A hit is answered
// the next cycle, as M10K was; a miss is refused and its line read into the
// cache (four words), and the replay hits. Stores update a cached line,
// invalidate the fetch cache's line at their index (code written by the
// ARM7) and go into a four-entry FIFO to the SRAM, which drains before any
// line is read, so a fill never reads older data than the ARM7 wrote. A
// write by anyone else (inv: ARM9, DMA through the fabric) invalidates
// both caches' lines at its index; a line being filled that a store or
// such a write touches is discarded at the end of its fill.
//
// Everything else goes to the bus fabric, one access at a time:
//   - a store is posted into a one-entry buffer and answered ok at once
//     (refused while the buffer is full);
//   - a load is refused, read on the fabric, and its word kept in a buffer
//     for the replay of the same address;
//   - a fetch is refused and its 16-byte line read on the fabric (four word
//     reads) into one of two line buffers, which then answer every fetch in
//     them. (Single fetched words made the two fetches the pipeline keeps in
//     flight evict each other forever.) A write to a buffered line by the
//     ARM7 or anyone else on the fabric (wr_*) invalidates it.
//   Reads wait for the store buffer to drain, so they never pass an older
//   store.
module nds_arm7_port #(
    parameter int IL = 7,               // log2 fetch cache lines
    parameter int DL = 6,               // log2 data cache lines
    // 1: the boot ROM (0x8000-0x9FFF) is read through the fabric, not ports
    // A/B (cpu_domain with CPU_FAST: the ROM stays on clk_sys)
    parameter int BOOT_FAB = 0,
    // the tag stores in MLAB instead of M10K (nds_lcache STYLE): 4 M10K for
    // about 4 LABs with the 3D build's 32/16-line caches, should M10K bind
    parameter     TAG_STYLE = "M10K",
    parameter bit TAG_WLATE = 1'b1      // tag writes a cycle late (nds_lcache WLATE): timing, same cycles
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [1:0]  wramcnt,
    // pipeline ports
    input  logic        i_req,
    input  logic [31:0] i_addr,
    output logic [31:0] i_rdata,
    output logic        i_ok,
    input  logic        d_req,
    input  logic        d_we,
    input  logic [3:0]  d_be,
    input  logic [31:0] d_addr,
    input  logic [31:0] d_wdata,
    output logic [31:0] d_rdata,
    output logic        d_ok,
    // boot ROM: fetch on port A, data on port B
    output logic [10:0] ib_addr,
    input  logic [31:0] i_boot_q,
    output logic [10:0] db_addr,
    output logic        d_boot,         // port B to the ARM7 data side this cycle
    input  logic [31:0] d_boot_q,
    // SRAM (through nds_fr_arb): request held until done
    output logic        x_req,
    output logic        x_we,
    output logic [17:2] x_addr,
    output logic [3:0]  x_be,
    output logic [31:0] x_wdata,
    output logic        x_stores,       // posted stores waiting (others' reads wait)
    input  logic        x_done,
    input  logic [31:0] x_rdata,
    input  logic        inv,            // someone else wrote the SRAM word inv_addr
    input  logic [17:2] inv_addr,
    // bus fabric (request held until ack; read data with ack)
    output logic        f_req,
    output logic        f_we,
    output logic [31:0] f_addr,
    output logic [3:0]  f_be,
    output logic [31:0] f_wdata,
    input  logic        f_ack,
    input  logic [31:0] f_rdata,
    // writes completed on the fabric (any master): invalidate fetch lines
    input  logic        wr_mon,
    input  logic [31:0] wr_addr
);
    // region: 1 boot ROM, 2 SRAM (x: its byte address), 0 fabric
    function automatic logic [1:0] reg_of(input logic [31:0] a);
        if (a[31:14] == 18'd0) return 2'd2;                   // BIOS7
        if (a[31:13] == 19'h00004) return BOOT_FAB ? 2'd0 : 2'd1;               // 0x8000-0x9FFF
        if (a[31:24] == 8'h03) return 2'd2;
        return 2'd0;
    endfunction
    function automatic logic [17:0] xa_of(input logic [31:0] a, input logic [1:0] wc);
        if (a[31:24] != 8'h03) return {4'b0110, a[13:0]};    // BIOS7
        if (a[23] || wc == 2'd0) return {2'b00, a[15:0]};    // ARM7 WRAM
        case (wc)
            2'd1: return {3'b010, 1'b0, a[13:0]};
            2'd2: return {3'b010, 1'b1, a[13:0]};
            default: return {3'b010, a[14:0]};
        endcase
    endfunction

    wire [1:0]  ireg = reg_of(i_addr);
    wire [1:0]  dreg = reg_of(d_addr);
    wire [17:0] ixa  = xa_of(i_addr, wramcnt);
    wire [17:0] dxa  = xa_of(d_addr, wramcnt);
    assign ib_addr = i_addr[12:2];
    assign db_addr = d_addr[12:2];
    assign d_boot  = d_req && dreg == 2'd1;

    // ---- fill engine and store FIFO (SRAM side)
    logic         fl_v, fl_i, fl_bad;
    logic [17:4]  fl_a;
    logic [1:0]   fl_k;
    // the store FIFO's entries {address, byte enables, data} in an MLAB; the
    // head's entry shows a cycle after sf_rp moves (the SRAM arbiter takes
    // a cycle to grant, so x_* are steady before the SRAM latches them)
    logic [51:0]  sf_q;
    logic [1:0]   sf_rp, sf_wp;
    logic [2:0]   sf_n;
    logic         xs_busy, xs_w;       // SRAM access in flight (a store?)
    // the line whose fill ended at the last edge: a lookup registered at that
    // edge read its valid bit before it was set, so its miss starts no new fill
    logic         fd_v, fd_i;
    // a data miss that could not start its fill gets the next free one before
    // any fetch fill (fetch misses running ahead of a refused load could
    // otherwise take every fill: HeartGold's ARM7 froze, docs "ARM7 port")
    logic         dm_v;
    logic [17:4]  dm_a;
    logic [17:4]  fd_a;
    assign x_stores = sf_n != 3'd0;

    // the data cache line a store updates this cycle (from last cycle's store)
    logic        su_v;
    logic [17:2] su_a;
    logic [3:0]  su_be;
    logic [31:0] su_d;
    // ---- caches: data, and tags with valid state (nds_lcache, M3)
    localparam int ITW = 18 - 4 - IL, DTW = 18 - 4 - DL;
    logic [31:0]  iq, dq;
    logic [ITW-1:0] itq;
    logic [DTW-1:0] dtq;
    // fills and store updates write port A
    logic          ic_we, dc_we, it_we, dt_we;
    logic [IL+1:0] ic_wa;
    logic [DL+1:0] dc_wa;
    logic [3:0]    dc_wbe;
    logic [31:0]   ic_wd, dc_wd;
    gpu3d_ram #(.W(32), .AW(IL + 2)) u_ic (.clk, .we(ic_we), .waddr(ic_wa), .wdata(ic_wd),
        .raddr(ixa[IL+3:2]), .rdata(iq));
    nds_sdp_ram #(.AW(DL + 2)) u_dc (.clk, .we(dc_we ? dc_wbe : 4'd0), .waddr(dc_wa), .wdata(dc_wd),
        .raddr(dxa[DL+3:2]), .rdata(dq));
    // Invalidation checks: a write forgets a cached line only if that line is
    // the one cached (nds_lcache's copy of each tag RAM, read at the write's
    // index, is compared the next cycle). Invalidating by index alone evicted HeartGold's
    // code line on every store to an aliasing WRAM address (a livelock).
    // The fetch cache checks the ARM7's stores and others' writes (an
    // others' write meeting a store waits a cycle in ck_h*); the data cache
    // checks others' writes (its own stores update it).
    logic          cki_v, ckd_v, ck_h;
    logic [17:4]   cki_a, ckd_a, ck_ha, cki_ra;
    logic [ITW-1:0] itq2;
    logic [DTW-1:0] dtq2;
    assign cki_ra = su_v ? su_a[17:4] : ck_h ? ck_ha : inv_addr[17:4];

    // ---- slow path state
    logic        wb_v;                  // posted store
    // (fabric addresses: 28 bits, the ARM7 has nothing from 0x10000000 up, docs/ds-rules.md)
    logic [27:0] wb_a;
    logic [31:0] wb_d;
    logic [3:0]  wb_be;
    logic        rp_v, rp_i;            // read on the fabric: fetch line (1) or data word (0)
    logic [27:0] rp_a;
    logic [3:0]  rp_be;                 // a data read's byte enables (I/O reads with side effects)
    logic [1:0]  rp_k;                  // fetch line: word being read
    logic        rb_v;                  // finished data read
    logic [27:0] rb_a;
    logic [31:0] rb_d;
    logic [1:0]  il_v;                  // fetch lines
    logic [27:4] il_a [2];
    // the two fetch lines' words in an MLAB {line, word}: a hit's word comes
    // the cycle after the request, as the answer does
    logic [31:0] il_q;
    logic        il_new;                // the line to fill next
    logic        busy, busy_w;          // fabric access in flight (the store?)

    // answers for the next cycle
    logic        ia_v, ia_ok, da_v, da_ok, ia_c, da_c, da_w, da_x, iv_q, dv_q;
    logic [1:0]  ia_r, da_r;
    logic [17:0] ia_xa, da_xa;
    logic        prot_q;

    wire il_hit0 = il_v[0] && il_a[0] == i_addr[27:4];
    wire il_hit1 = il_v[1] && il_a[1] == i_addr[27:4];
    wire i_pend  = rp_v && rp_i && rp_a[27:4] == i_addr[27:4];   // its line is on its way
    logic       d_blk;               // a main-RAM data read was refused the read slot (below)
    logic [4:0] d_blk_n;
    wire d_hit   = rb_v && rb_a[27:2] == d_addr[27:2];

    // hits of last cycle's requests
    wire ic_hit = ia_c && iv_q && itq == ia_xa[17:IL+4];
    wire dc_hit = da_c && dv_q && dtq == da_xa[17:DL+4];
    wire su_hit = su_v && su_a[17:14] != 4'b0110 && da_c && da_w && dc_hit;   // last cycle's store hits a line

    // BIOS read protection (melonDS ARM7Read*): a data read of the BIOS gives
    // 0xFFFFFFFF unless the code runs inside it, and below BIOSPROT unless
    // the code runs below BIOSPROT too. The last fetch address stands in for
    // the PC (fetch runs a few instructions ahead: only boundaries differ).
    // the last fetch address as the protection needs it: above the BIOS
    // (bits 31:14 not all 0), and its bits 13:0
    logic        lf_hi;

    // store updates and fills share the caches' port A; a fill word that
    // meets a store update is dropped and its line discarded
    wire fill_w = xs_busy && !xs_w && x_done;
    // a fill ends without its line if a store or a write meets it on the last
    // edge (the store's own lookup ran before the line was valid)
    wire fl_kill = (su_v && su_a[17:4] == fl_a) || (inv && inv_addr[17:4] == fl_a) ||
                   (d_req && d_we && dreg == 2'd2 && dxa[17:4] == fl_a);
    always_comb begin
        dc_we = su_hit; dc_wa = da_xa[DL+3:2]; dc_wbe = su_be; dc_wd = su_d;
        ic_we = 1'b0; ic_wa = {fl_a[IL+3:4], fl_k}; ic_wd = x_rdata;
        if (fill_w && fl_i) ic_we = 1'b1;
        if (fill_w && !fl_i && !su_hit) begin
            dc_we = 1'b1; dc_wa = {fl_a[DL+3:4], fl_k}; dc_wbe = 4'hF; dc_wd = x_rdata;
        end
        it_we = fill_w && fl_i && fl_k == 2'd3;
        dt_we = fill_w && !fl_i && fl_k == 2'd3;
    end

    // The line tags and valid state. A line is invalid while it is being
    // filled (the valid bit used to be cleared at the fill's start) and
    // becomes valid at the fill's end unless a store or a write met it.
    wire fl_good = !fl_bad && !(!fl_i && su_hit) && !fl_kill;
    logic ic_cv, dc_cv;
    wire  ic_inv = cki_v && ic_cv && itq2 == cki_a[17:IL+4];
    wire  dc_inv = ckd_v && dc_cv && dtq2 == ckd_a[17:DL+4];
    nds_lcache #(.LB(IL), .TW(ITW), .CHECK(1), .CQ(2), .STYLE(TAG_STYLE), .WLATE(TAG_WLATE)) u_itag (.clk, .clk2(1'b0), .rst,
        .l_en(1'b1), .l_idx(ixa[IL+3:4]), .l_v(iv_q), .l_vn(), .l_tag(itq),
        .c_idx(cki_ra[IL+3:4]), .c_v(ic_cv), .c_tag(itq2),
        .f_busy(fl_v && fl_i), .f_idx(fl_a[IL+3:4]), .f_end(it_we), .f_ok(fl_good), .f_tag(fl_a[17:IL+4]),
        .inv(ic_inv), .inv_idx(cki_a[IL+3:4]), .inv_all(1'b0), .busy());
    nds_lcache #(.LB(DL), .TW(DTW), .CHECK(1), .CQ(2), .STYLE(TAG_STYLE), .WLATE(TAG_WLATE)) u_dtag (.clk, .clk2(1'b0), .rst,
        .l_en(1'b1), .l_idx(dxa[DL+3:4]), .l_v(dv_q), .l_vn(), .l_tag(dtq),
        .c_idx(inv_addr[DL+3:4]), .c_v(dc_cv), .c_tag(dtq2),
        .f_busy(fl_v && !fl_i), .f_idx(fl_a[DL+3:4]), .f_end(dt_we), .f_ok(fl_good), .f_tag(fl_a[17:DL+4]),
        .inv(dc_inv), .inv_idx(ckd_a[DL+3:4]), .inv_all(1'b0), .busy());

    always_ff @(posedge clk) begin
        ia_v <= i_req; ia_r <= ireg; ia_ok <= 1'b0; ia_c <= i_req && ireg == 2'd2; ia_xa <= ixa;
        da_v <= d_req; da_r <= dreg; da_ok <= 1'b0; da_c <= d_req && dreg == 2'd2; da_xa <= dxa;
        da_w <= d_we; da_x <= 1'b0;
        prot_q <= dreg == 2'd2 && d_addr[31:14] == 18'd0 && lf_hi;
        su_v <= 1'b0;
        fd_v <= 1'b0;
        if (rst) begin
            wb_v <= 1'b0; rp_v <= 1'b0; busy <= 1'b0; busy_w <= 1'b0; d_blk <= 1'b0;
            rb_v <= 1'b0; il_v <= 2'b00; il_new <= 1'b0; ia_v <= 1'b0; da_v <= 1'b0;
            lf_hi <= 1'b0;
            fl_v <= 1'b0; xs_busy <= 1'b0; dm_v <= 1'b0; sf_rp <= 2'd0; sf_wp <= 2'd0; sf_n <= 3'd0;
            ia_c <= 1'b0; da_c <= 1'b0;
        end else begin
            if (i_req) lf_hi <= i_addr[31:14] != 18'd0;

            // ---- SRAM side: the store FIFO first, then the fill's words
            if (xs_busy && x_done) begin
                xs_busy <= 1'b0;
                if (xs_w) begin sf_rp <= sf_rp + 2'd1; end
                else begin
                    fl_k <= fl_k + 2'd1;
                    if (fl_k == 2'd3) begin
                        fl_v <= 1'b0; fd_v <= 1'b1; fd_i <= fl_i; fd_a <= fl_a;
                        // (the line valid unless fl_good is low: nds_lcache)
                    end else if (!fl_i && su_hit) fl_bad <= 1'b1;
                end
            end else if (fill_w && !fl_i && su_hit) fl_bad <= 1'b1;
            if (!xs_busy || x_done) begin
                if (sf_n - ((xs_busy && x_done && xs_w) ? 3'd1 : 3'd0) != 3'd0) begin
                    xs_busy <= 1'b1; xs_w <= 1'b1;
                end else if (fl_v && !(xs_busy && x_done && !xs_w && fl_k == 2'd3)) begin
                    xs_busy <= 1'b1; xs_w <= 1'b0;
                end
            end

            // ---- last cycle's cached requests: a miss starts a fill (a
            // remembered data miss first, then a fetch, then a data miss)
            if (!fl_v && dm_v) begin
                dm_v <= 1'b0;
                if (!(fd_v && !fd_i && fd_a == dm_a)) begin
                    fl_v <= 1'b1; fl_i <= 1'b0; fl_a <= dm_a; fl_k <= 2'd0; fl_bad <= 1'b0;
                end
            end else begin
                if (ia_v && ia_c && !ic_hit && !fl_v && !(fd_v && fd_i && fd_a == ia_xa[17:4])) begin
                    fl_v <= 1'b1; fl_i <= 1'b1; fl_a <= ia_xa[17:4]; fl_k <= 2'd0; fl_bad <= 1'b0;
                end
                if (da_v && da_c && !da_w && !dc_hit && !(fd_v && !fd_i && fd_a == da_xa[17:4])) begin
                    if (!fl_v && !(ia_v && ia_c && !ic_hit)) begin
                        fl_v <= 1'b1; fl_i <= 1'b0; fl_a <= da_xa[17:4]; fl_k <= 2'd0; fl_bad <= 1'b0;
                    end else if (!(fl_v && !fl_i && fl_a == da_xa[17:4])) begin
                        dm_v <= 1'b1; dm_a <= da_xa[17:4];
                    end
                end
            end
            // a store (accepted last cycle) into the FIFO; the fetch cache
            // forgets the line it writes (code written by the ARM7)
            if (su_v) begin
                if (su_a[17:14] != 4'b0110) begin              // BIOS7 is read-only
                    sf_wp <= sf_wp + 2'd1;
                end
                if (fl_v && fl_a == su_a[17:4]) fl_bad <= 1'b1;
            end
            sf_n <= sf_n + ((su_v && su_a[17:14] != 4'b0110) ? 3'd1 : 3'd0)
                         - ((xs_busy && x_done && xs_w) ? 3'd1 : 3'd0);
            // someone else's write
            if (inv && fl_v && fl_a == inv_addr[17:4]) fl_bad <= 1'b1;
            // tag-checked invalidations (read last cycle)
            cki_v <= su_v || ck_h || inv; cki_a <= cki_ra;
            ck_h <= su_v && (inv || ck_h); if (su_v && inv) ck_ha <= inv_addr[17:4];
            ckd_v <= inv; ckd_a <= inv_addr[17:4];
            // (the clears themselves: ic_inv, dc_inv into nds_lcache)

            // ---- fabric completion
            if (busy && f_ack) begin
                busy <= 1'b0;
                if (busy_w) wb_v <= 1'b0;
                else if (!rp_i) begin
                    rp_v <= 1'b0; rb_v <= 1'b1; rb_a <= rp_a; rb_d <= f_rdata;
                end else begin
                    rp_k <= rp_k + 2'd1;
                    if (rp_k == 2'd3) begin
                        rp_v <= 1'b0;
                        il_v[il_new] <= 1'b1; il_a[il_new] <= rp_a[27:4];
                        il_new <= !il_new;
                    end
                end
            end
            // start the next fabric access: the store first
            if (!busy || f_ack) begin
                if (wb_v && !(busy && f_ack && busy_w)) begin busy <= 1'b1; busy_w <= 1'b1; end
                else if (rp_v && !(busy && f_ack && !busy_w && (!rp_i || rp_k == 2'd3))) begin
                    busy <= 1'b1; busy_w <= 1'b0;
                end
            end
            // data access
            if (d_req) begin
                if (dreg == 2'd1) da_ok <= 1'b1;
                else if (dreg == 2'd2) begin
                    if (d_we) begin
                        // room: the FIFO counts this cycle's push (su_v) already
                        if (sf_n + (su_v ? 3'd1 : 3'd0) < 3'd4) begin
                            da_ok <= 1'b1; su_v <= 1'b1;
                            su_a <= dxa[17:2]; su_be <= d_be; su_d <= d_wdata;
                        end
                    end else
                        // a word the store update writes this cycle reads stale
                        da_x <= su_v && su_a[DL+3:2] == dxa[DL+3:2];
                end else if (d_we) begin
                    if (!wb_v) begin
                        wb_v <= 1'b1; wb_a <= d_addr[27:0]; wb_d <= d_wdata; wb_be <= d_be; da_ok <= 1'b1;
                    end
                end else if (d_hit) begin
                    da_ok <= 1'b1; rb_v <= 1'b0;
                end else if (!rp_v && !wb_v) begin
                    // a different word may be waiting: it is dropped (its
                    // access was not replayed, e.g. an IRQ came in between)
                    rb_v <= 1'b0;
                    rp_v <= 1'b1; rp_i <= 1'b0; rp_a <= d_addr[27:0]; rp_be <= d_be;
                end
            end
            // a main-RAM data read found the read slot busy: no fetch refill
            // may take the slot until that read has issued. The core replays
            // the load only every few cycles, in the same cycles as its fetches,
            // so without this a refill wins every time the slot frees (calico's
            // ARM7 code and data in main RAM, three fetch lines through two
            // buffers: livelock). It lapses after 32 cycles without the
            // request (an IRQ took the core elsewhere).
            if (d_req && dreg == 2'd0 && !d_we && !d_hit && (rp_v || wb_v)) begin d_blk <= 1'b1; d_blk_n <= 5'd31; end
            else if (d_req && dreg == 2'd0 && !d_we && !d_hit) d_blk <= 1'b0;   // it issues now
            else if (d_blk) begin d_blk_n <= d_blk_n - 5'd1; if (d_blk_n == 5'd0) d_blk <= 1'b0; end
            // fetch (the data side wins the read slot)
            if (i_req) begin
                if (ireg == 2'd1) ia_ok <= 1'b1;
                else if (ireg == 2'd2) ;
                else if (il_hit0 || il_hit1) begin
                    ia_ok <= 1'b1;
                    il_new <= !il_hit1;              // keep the line in use
                end else if (!rp_v && !wb_v && !(d_req && dreg == 2'd0) && !d_blk && !i_pend) begin
                    rp_v <= 1'b1; rp_i <= 1'b1; rp_a <= {i_addr[27:4], 4'd0}; rp_k <= 2'd0;
                    il_v[il_new] <= 1'b0;            // the line being refilled
                end
            end
            // writes invalidate the fetch lines they hit
            if (wr_mon) begin
                if (il_a[0] == wr_addr[27:4]) il_v[0] <= 1'b0;
                if (il_a[1] == wr_addr[27:4]) il_v[1] <= 1'b0;
            end
        end
    end

`ifndef ALTERA_RESERVED_QIS   // (Quartus rejects $test$plusargs)
    // simulation (+a7dbg): the port's state once nothing has been answered
    // for 200K cycles
    integer dbg_quiet = 0;
    logic   dbg_on = 1'b0, dbg_said = 1'b0;
    initial dbg_on = $test$plusargs("a7dbg");
    // +a7trace=C: the port's state every cycle for 400 cycles from cycle C
    longint dbg_cyc = 0, dbg_from = -1;
    initial if (!$value$plusargs("a7trace=%d", dbg_from)) dbg_from = -1;
    // (a checkpoint restores the saving run's settings: read them again
    // now and then, so +a7trace/+a7dbg work after --load)
    always_ff @(posedge clk) if (dbg_cyc[19:0] == 20'd0) begin
        if (!$value$plusargs("a7trace=%d", dbg_from)) dbg_from <= -1;
        dbg_on <= $test$plusargs("a7dbg");
    end
    always_ff @(posedge clk) begin
        dbg_cyc <= dbg_cyc + 1;
        if (dbg_from >= 0 && dbg_cyc >= dbg_from && dbg_cyc < dbg_from + 400)
            $display("a7t %0d: i %b %h ok %b | ia %b c %b hit %b iv %b tag %h/%h | d %b w %b %h ok %b dc %b x %b | fl %b i %b a %h k %0d bad %b kill %b | xs %b w %b done %b sf %0d | su %b %h | ck %b %h ckd %b inv %b %h | fd %b %h",
                dbg_cyc, i_req, i_addr, i_ok, ia_v, ia_c, ic_hit, iv_q, itq, ia_xa[17:IL+4], d_req, d_we, d_addr, d_ok, dc_hit, da_x,
                fl_v, fl_i, fl_a, fl_k, fl_bad, fl_kill, xs_busy, xs_w, x_done, sf_n, su_v, su_a, cki_v, cki_a, ckd_v, inv, inv_addr, fd_v, fd_a);
    end
    always_ff @(posedge clk) begin
        dbg_quiet <= (i_ok || d_ok) ? 0 : dbg_quiet + 1;
        if (dbg_on && !dbg_said && dbg_quiet == 200000) begin
            dbg_said <= 1'b1;
            $display("a7dbg: i_req %b %h ireg %0d | d_req %b we %b %h dreg %0d | ia_v %b ia_c %b ic_hit %b iv_q %b itq %h ia_xa %h",
                     i_req, i_addr, ireg, d_req, d_we, d_addr, dreg, ia_v, ia_c, ic_hit, iv_q, itq, ia_xa);
            $display("a7dbg: da_v %b da_c %b da_w %b dc_hit %b dv_q %b dtq %h da_xa %h da_x %b | fl_v %b fl_i %b fl_a %h fl_k %0d fl_bad %b | xs_busy %b xs_w %b sf_n %0d x_done %b",
                     da_v, da_c, da_w, dc_hit, dv_q, dtq, da_xa, da_x, fl_v, fl_i, fl_a, fl_k, fl_bad, xs_busy, xs_w, sf_n, x_done);
            $display("a7dbg: slow: wb_v %b rp_v %b rp_i %b rp_a %h busy %b busy_w %b rb_v %b il_v %b",
                     wb_v, rp_v, rp_i, rp_a, busy, busy_w, rb_v, il_v);
        end
    end
`endif

    assign x_req   = xs_busy;
    assign x_we    = xs_w;
    gpu2d_mlab #(.W(52), .AW(2), .STYLE("M10K")) u_sf (.clk, .we(su_v && su_a[17:14] != 4'b0110), .waddr(sf_wp),
        .wdata({su_a, su_be, su_d}), .raddr(sf_rp), .rdata(sf_q));
    gpu2d_mlab #(.W(32), .AW(3), .STYLE("M10K")) u_il (.clk, .we(busy && f_ack && !busy_w && rp_i), .waddr({il_new, rp_k}),
        .wdata(f_rdata), .raddr({il_hit1, i_addr[3:2]}), .rdata(il_q));
    assign x_addr  = xs_w ? sf_q[51:36] : {fl_a, fl_k};
    assign x_be    = xs_w ? sf_q[35:32] : 4'hF;
    assign x_wdata = sf_q[31:0];

    assign f_req   = busy;
    assign f_we    = busy_w;
    assign f_addr  = {4'd0, busy_w ? wb_a : rp_i ? {rp_a[27:4], rp_k, 2'b00} : rp_a};
    // a data read goes out with the load's own byte enables (a 16-bit read
    // of a register with read side effects must stay 16 bits); fetch lines
    // read whole words
    assign f_be    = busy_w ? wb_be : rp_i ? 4'hF : rp_be;
    assign f_wdata = wb_d;

    // ---- answers
    always_comb begin
        unique case (ia_r)
            2'd1:    i_rdata = i_boot_q;
            2'd2:    i_rdata = iq;
            default: i_rdata = il_q;
        endcase
        unique case (da_r)
            2'd1:    d_rdata = d_boot_q;
            2'd2:    d_rdata = prot_q ? 32'hFFFF_FFFF : dq;
            default: d_rdata = rb_d;      // a data hit's word: rb_d stays until the next data read completes (>= 2 cycles after this answer; a new read issue clears rb_v first)
        endcase
    end
    assign i_ok = ia_v && (ia_r == 2'd2 ? ic_hit : ia_ok);
    assign d_ok = da_v && (da_r == 2'd2 ? (da_w ? da_ok : dc_hit && !da_x) : da_ok);
endmodule
