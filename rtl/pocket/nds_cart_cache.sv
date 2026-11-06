// SPDX-License-Identifier: MIT
// SDRAM ROM cache over APF target_dataslot_read (docs/phase1-foundation.md,
// "Cartridge streaming"). Runs on clk_bus.
//
// Strategy (docs/memory-replay.md, "Cartridge streaming strategies", ra16):
// 4 KiB blocks; a miss on block b fetches b plus up to four more blocks of the
// NitroFS file that contains b's first byte, as one APF command, stopping at
// the first block already cached. The client waits for the whole command.
//
// SDRAM layout (word addresses; bytes = 4x):
//   TABLE_W + b      block b: [31:29] read-ahead blocks (0..4), [16] cached,
//                    [13:0] slot. One entry per 4 KiB of the ROM (512 KiB
//                    for a 512 MiB ROM).
//   OWNER_W + s      slot s: [31] used, [17:0] the block it holds.
//   CACHE_W + 1024 s the slot's 4 KiB of ROM data.
// Replacement: CLOCK (second chance) over SLOTS slots, one reference bit per
// slot on chip; a hit sets it. Evicting a slot clears its old block's entry
// with byte enables 0111, keeping the read-ahead field.
//
// Read-ahead fields come from the plugin's ROM tables (<game>.ndt,
// docs/pocket-plugin.md): the APF loads slot 5 before the core runs, and
// nds_apf_host maps it 1:1 into SDRAM so that its 4 KiB header lands at
// NDT_W = TABLE_W - 1024 words and its table on the table: one initial entry
// per block, [31:29] min(4, blocks left in the NitroFS file), cached bit and
// slot clear (the same rule as tools/mem-replay/cart_sim.py). At start the
// cache reads the header's magic (NDT_W), version (NDT_W + 1) and ROM size
// (NDT_W + 3): when they are "NDT1", 1 and this ROM's size, the table is
// used as loaded and the magic
// is cleared (a later start clears the table). Otherwise (a plain .nds, or a
// table for another ROM) the table is cleared: no read-ahead, demand
// fetches only. nds_apf_host clears the magic at power-up through the same
// FIFO, so a table left in SDRAM by an earlier session is never taken.
// (Until 2026-10-24 the cache built the table itself by walking the header
// and the FAT; the plugin does that now, docs/phase1-foundation.md "Squeeze".)
//
// Sequential prefetch (streams: movies, music): when a demand miss's run ends
// inside its file, the next run (up to five more blocks of the file) is
// fetched in the background; when the client first reads a prefetched run,
// the run after it is fetched (double buffering). A prefetch only starts
// when the client is idle, and the client keeps being served from the cache
// while its command runs; a client miss waits for that one command, then
// goes first.
//
// Client: c_valid with a 16-byte aligned ROM byte address, held until c_ready;
// four words follow on r_valid/r_data. One request at a time.
// Fetch commands go to the APF side as fc_data {length[14:0], offset[31:0],
// blocks[2:0], slot4..slot0[13:0]}; the APF side's marker (mk_valid, mk_err)
// arrives through the SDRAM write FIFO after the data. A command with an APF
// error is sent again, up to three times; then fail is set and the blocks are
// marked cached anyway (the test's signature then fails).
`default_nettype none
module nds_cart_cache #(
    parameter [23:0] TABLE_W = 24'h30_0000,
    parameter [23:0] OWNER_W = 24'h34_0000,
    parameter [23:0] CACHE_W = 24'h40_0000,
    parameter integer SLOTS = 12288,
    parameter bit PREFETCH = 1,             // sequential prefetch (0: demand fetches only)
    parameter [23:0] NDT_W = TABLE_W - 24'h400   // where slot 5's header lands
) (
    input wire clk, reset,
    input wire start,                       // rom_size valid; level
    input wire [31:0] rom_size,
    output reg ready = 0,                   // table ready (loaded or cleared)
    output reg fail = 0,                    // a fetch failed after retries
    output reg init_capped = 0,             // always 0 (the scan is gone; kept for the interface)
    // client
    input wire c_valid,
    input wire [31:0] c_addr,
    output reg c_ready = 0,
    output reg r_valid = 0,
    output reg [31:0] r_data = 0,
    // fetch command to the APF side, and its completion marker
    output reg fc_send = 0,
    output wire [119:0] fc_data,
    input wire fc_busy,
    input wire mk_valid,
    input wire [2:0] mk_err,
    // SDRAM client
    output reg m_valid = 0,
    output reg m_write = 0,
    output reg m_quad = 0,
    output reg [23:0] m_addr = 0,
    output reg [31:0] m_wdata = 0,
    output reg [3:0] m_be = 0,
    input wire m_ready,
    input wire m_rvalid,
    input wire [31:0] m_rdata,
    // statistics (stat_clear zeroes them)
    input wire stat_clear,
    input wire tick_ms,                     // one pulse per millisecond
    output reg [31:0] st_lookups = 0,       // table reads for a client block
    output reg [31:0] st_fast = 0,          // same block as the last lookup
    output reg [31:0] st_cmds = 0,          // APF commands
    output reg [31:0] st_blocks = 0,        // blocks fetched
    output reg [31:0] st_evict = 0,
    output reg [31:0] st_wait = 0,          // milliseconds waiting for fetches
    output reg [15:0] st_errors = 0,
    output reg [31:0] st_spans = 0,         // file spans marked at init
    output reg [31:0] st_marks = 0,         // read-ahead fields written at init
    // NDSDiag (docs/diag.md; unconnected in the release, pruned): a client waits for a fetch (level), and an
    // APF fetch command goes out (one clock)
    output wire dg_wait,
    output wire dg_cmd
);
    localparam integer SB = $clog2(SLOTS);

    // ---------------- reference bits ----------------
    reg refmem [0:SLOTS-1];
    reg ref_q = 0, ref_we = 0, ref_wd = 0;
    reg [SB-1:0] ref_raddr = 0, ref_waddr = 0;
    always @(posedge clk) begin
        ref_q <= refmem[ref_raddr];
        if (ref_we) refmem[ref_waddr] <= ref_wd;
    end

    // ---------------- SDRAM access helper ----------------
    // mem_go starts one access; mem_busy until its (last) data word.
    reg mem_busy = 0;
    reg [1:0] mem_n = 0;
    reg [31:0] q0 = 0;                      // the last single read
    reg fwd = 0;                            // forward quad words to the client
    task automatic mem_go(input w, input quad, input [23:0] a, input [31:0] d, input [3:0] be);
        m_valid <= 1; m_write <= w; m_quad <= quad; m_addr <= a; m_wdata <= d; m_be <= be;
        mem_busy <= 1; mem_n <= 0;
    endtask

    // ---------------- state ----------------
    localparam [5:0]
        S_WAIT = 0, S_CLR_T = 1, S_CLR_O = 2, S_NDT0 = 3, S_NDT1 = 4, S_NDT2 = 5, S_REFS = 6,
        S_READY = 9,
        Q_LOOK = 16, Q_READ = 17, Q_DATA = 18,
        L_ENTRY = 20, L_RA = 21, L_ALLOC = 22, L_REF = 23, L_OWN = 24, L_OWN_GOT = 25, L_OWN_W = 26,
        L_FETCH = 27, L_WAITF = 28, L_VALID = 29, L_DONE = 30, P_WAIT = 31;
    reg [5:0] st = S_WAIT, q_ret = S_WAIT;

    reg [17:0] nblocks = 0;
    reg [31:0] qaddr = 0;                   // ROM byte address of the quad being read
    reg [17:0] lb = 0;                      // block being looked up
    reg [SB-1:0] slot = 0;
    reg [17:0] last_b = 0;
    reg [SB-1:0] last_slot = 0;
    reg last_v = 0;
    // miss run
    reg [2:0] run_n = 0, run_k = 0, run_ext = 0;
    (* ramstyle = "logic" *) reg [2:0] run_ra [0:4];
    (* ramstyle = "logic" *) reg [SB-1:0] run_slot [0:4];
    reg [SB-1:0] hand = 0;
    reg [1:0] tries = 0;
    reg ref_pending = 0;
    // prefetch
    reg pf_pend = 0, pfm = 0, pf_fly = 0, pf_mk = 0, pf_err = 0, pf_fin = 0, pf_trig_v = 0, pf_cont = 0;
    reg [17:0] pf_b = 0, pf_lb = 0, pf_trig = 0, pf_next = 0;
    reg [5:0] pf_ret = 0;
    wire [17:0] run_end = lb + run_n;       // first block after the run
    wire run_cont = run_ra[run_n - 1'b1] != 3'd0 && run_end < nblocks;
    reg ndt_magic = 0;
    // the fetch command, read by the host from send until its marker
    // (SOURCE_HOLDS crossing): the run's slots and count stay put until
    // then (a new lookup waits for the marker), the base block and length
    // are kept at the send (pf_lb, fl_q) since lb moves on during a
    // background prefetch
    reg [14:0] fl_q = 0;

    wire [17:0] blocks_after = nblocks - 1'b1 - lb;
    function automatic [17:0] ceil_blk(input [31:0] x);
        ceil_blk = x[29:12] + (x[11:0] != 12'd0);
    endfunction
    function automatic [31:0] min32(input [31:0] a, input [31:0] b);
        min32 = a < b ? a : b;
    endfunction
    // min(run_n blocks, bytes left in the ROM), in block arithmetic: only a run
    // that ends at the ROM's last block can be short, by the ROM's tail
    wire [14:0] fetch_len = run_end == nblocks && rom_size[11:0] != 12'd0
                          ? {run_n - 3'd1, 12'b0} + {3'b0, rom_size[11:0]} : {run_n, 12'b0};
    // Table and owner addresses are {base, index}: both bases are multiples of
    // 2^18 words (checked below), so no adders. One adder serves the three
    // "block after lb" addresses: lb + 1 (L_ENTRY), lb + run_n + 1 (L_RA),
    // lb + run_k (L_OWN_W, L_VALID).
    localparam [5:0] TB = TABLE_W[23:18], OB = OWNER_W[23:18];
    wire [2:0] off_sel = st == L_ENTRY ? 3'd1 : st == L_RA ? run_n + 3'd1 : run_k;
    wire [17:0] lb_off = lb + off_sel;
    function automatic [17:0] pad18(input [SB-1:0] x);
        pad18 = x;
    endfunction
    // synthesis translate_off
    initial if (TABLE_W[17:0] != 0 || OWNER_W[17:0] != 0 || CACHE_W[9:0] != 0)
        $error("nds_cart_cache: TABLE_W/OWNER_W must be multiples of 2^18 words, CACHE_W of 1024");
    // synthesis translate_on
    function automatic [13:0] pad14(input [SB-1:0] x);
        pad14 = x;
    endfunction

    assign fc_data = {fl_q, 2'b0, pf_lb, 12'b0, run_n,
                      pad14(run_slot[4]), pad14(run_slot[3]), pad14(run_slot[2]), pad14(run_slot[1]), pad14(run_slot[0])};

    assign dg_wait = (st == L_FETCH || st == L_WAITF || st == P_WAIT) && !pfm;
    assign dg_cmd = fc_send;
    always @(posedge clk) begin
        c_ready <= 0; r_valid <= 0; fc_send <= 0; ref_we <= 0;
        if (m_ready) m_valid <= 0;
        if (stat_clear) begin
            st_lookups <= 0; st_fast <= 0; st_cmds <= 0; st_blocks <= 0; st_evict <= 0; st_wait <= 0;
        end
        // SDRAM results
        if (mem_busy) begin
            if (m_write && m_ready) mem_busy <= 0;
            if (m_rvalid) begin
                q0 <= m_rdata;
                mem_n <= mem_n + 1'b1;
                if (fwd && m_quad) begin r_valid <= 1; r_data <= m_rdata; end   // data, not table reads
                if (!m_quad || mem_n == 2'd3) mem_busy <= 0;
            end
        end
        if (dg_wait && tick_ms) st_wait <= st_wait + 1'b1;
        if (mk_valid && pf_fly) begin pf_mk <= 1; pf_err <= mk_err != 0; end

        if (reset) begin
            st <= S_WAIT; ready <= 0; fail <= 0; init_capped <= 0; m_valid <= 0; mem_busy <= 0; fwd <= 0;
            last_v <= 0; hand <= 0;
            pf_pend <= 0; pfm <= 0; pf_fly <= 0; pf_mk <= 0; pf_fin <= 0; pf_trig_v <= 0;
        end else if (!mem_busy) case (st)
            // ---------------- init ----------------
            S_WAIT: if (start) begin
                nblocks <= ceil_blk(rom_size); lb <= 0;   // lb: the init loops' index (no lookup runs before ready)
                st_spans <= 0; st_marks <= 0;
                mem_go(0, 0, NDT_W, 32'h0, 4'b0000); st <= S_NDT0;     // magic
            end
            S_NDT0: begin
                ndt_magic <= q0 == 32'h3154_444E;                        // "NDT1"
                mem_go(0, 0, NDT_W + 24'd1, 32'h0, 4'b0000); st <= S_NDT2;  // version
            end
            S_NDT2: begin
                ndt_magic <= ndt_magic && q0 == 32'd1;
                mem_go(0, 0, NDT_W + 24'd3, 32'h0, 4'b0000); st <= S_NDT1;  // ROM size
            end
            S_NDT1: if (ndt_magic && q0 == rom_size) begin
                mem_go(1, 0, NDT_W, 32'h0, 4'b1111); st <= S_CLR_O;      // use it once: clear the magic
            end else st <= S_CLR_T;
            S_CLR_T: begin
                if (lb == nblocks) begin lb <= 0; st <= S_CLR_O; end
                else begin mem_go(1, 0, {TB, lb}, 32'h0, 4'b1111); lb <= lb + 1'b1; end
            end
            S_CLR_O: begin
                // the reference bits are cleared alongside the owner entries
                if (lb != SLOTS) begin ref_we <= 1; ref_waddr <= lb[SB-1:0]; ref_wd <= 0; end
                if (lb == SLOTS) st <= S_REFS;
                else begin mem_go(1, 0, {OB, lb}, 32'h0, 4'b1111); lb <= lb + 1'b1; end
            end
            S_REFS: begin ready <= 1; st <= S_READY; end
            // ---------------- client ----------------
            S_READY: if (c_valid) begin
                c_ready <= 1; qaddr <= {c_addr[31:4], 4'b0}; fwd <= 1; q_ret <= S_READY; st <= Q_LOOK;
            end else if (pf_mk) begin
                // the prefetch's data is in: mark its blocks cached
                pf_ret <= S_READY; st <= P_WAIT;
            end else if (pf_pend && !pf_fly) begin
                pf_pend <= 0; pfm <= 1; fwd <= 0; lb <= pf_b;
                mem_go(0, 0, {TB, pf_b}, 32'h0, 4'b0000); st <= L_ENTRY;
            end
            // a client miss while a prefetch runs: wait for it, finish it, look again
            P_WAIT: if (pf_mk) begin
                pf_mk <= 0; pf_fly <= 0; lb <= pf_lb; run_k <= 0;
                if (pf_err) begin st_errors <= st_errors + 1'b1; pf_trig_v <= 0; st <= pf_ret; end
                else begin pf_fin <= 1; st <= L_VALID; end
            end
            // ---------------- quad read of ROM bytes qaddr ----------------
            Q_LOOK: begin
                lb <= qaddr[29:12];
                if (fwd) st_lookups <= st_lookups + 1'b1;
                // the client reached a prefetched run: fetch the next one
                if (fwd && pf_trig_v && qaddr[29:12] == pf_trig) begin
                    pf_trig_v <= 0;
                    if (pf_cont) begin pf_pend <= 1; pf_b <= pf_next; end
                end
                if (last_v && last_b == qaddr[29:12]) begin
                    slot <= last_slot; st <= Q_READ;
                    if (fwd) st_fast <= st_fast + 1'b1;
                end else begin
                    mem_go(0, 0, {TB, qaddr[29:12]}, 32'h0, 4'b0000); st <= L_ENTRY;
                end
            end
            Q_READ: begin
                mem_go(0, 1, {CACHE_W[23:10] + pad14(slot), qaddr[11:2]}, 32'h0, 4'b0000);
                st <= Q_DATA;
            end
            Q_DATA: begin fwd <= 0; st <= q_ret; end
            // ---------------- lookup of block lb ----------------
            L_ENTRY: if (pfm && q0[16]) begin
                pfm <= 0; st <= S_READY;            // prefetch: already cached
            end else if (!pfm && !q0[16] && pf_fly) begin
                pf_ret <= Q_LOOK; st <= P_WAIT;     // demand miss: the prefetch's command first
            end else if (q0[16]) begin
                slot <= q0[SB-1:0];
                last_b <= lb; last_slot <= q0[SB-1:0]; last_v <= 1;
                ref_we <= 1; ref_waddr <= q0[SB-1:0]; ref_wd <= 1;
                st <= Q_READ;
            end else begin
                run_ra[0] <= q0[31:29]; run_n <= 1;
                run_ext <= {15'b0, q0[31:29]} > blocks_after ? blocks_after[2:0] : q0[31:29];
                if (q0[31:29] != 0 && blocks_after != 0) begin
                    mem_go(0, 0, {TB, lb_off}, 32'h0, 4'b0000); st <= L_RA;
                end else begin run_k <= 0; ref_pending <= 0; st <= L_ALLOC; end
            end
            L_RA: begin
                if (q0[16]) begin run_k <= 0; ref_pending <= 0; st <= L_ALLOC; end   // already cached: stop
                else begin
                    run_ra[run_n] <= q0[31:29];
                    run_n <= run_n + 1'b1;
                    if (run_n == run_ext) begin run_k <= 0; ref_pending <= 0; st <= L_ALLOC; end
                    else mem_go(0, 0, {TB, lb_off}, 32'h0, 4'b0000);
                end
            end
            // CLOCK: read the hand's bit (one clock), then clear and move on, or take it
            L_ALLOC: begin ref_raddr <= hand; ref_pending <= 1; st <= L_REF; end
            L_REF: if (ref_pending) ref_pending <= 0;
            else begin
                if (ref_q) begin
                    ref_we <= 1; ref_waddr <= hand; ref_wd <= 0;
                    hand <= hand == SLOTS - 1 ? {SB{1'b0}} : hand + 1'b1;
                    st <= L_ALLOC;
                end else begin
                    run_slot[run_k] <= hand;
                    ref_we <= 1; ref_waddr <= hand; ref_wd <= 1;
                    hand <= hand == SLOTS - 1 ? {SB{1'b0}} : hand + 1'b1;
                    mem_go(0, 0, {OB, pad18(hand)}, 32'h0, 4'b0000);
                    st <= L_OWN_GOT;
                end
            end
            L_OWN_GOT: begin
                if (q0[31]) begin
                    mem_go(1, 0, {TB, q0[17:0]}, 32'h0, 4'b0111);
                    st_evict <= st_evict + 1'b1;
                    if (last_b == q0[17:0]) last_v <= 0;
                end
                st <= L_OWN_W;
            end
            L_OWN_W: begin
                mem_go(1, 0, {OB, pad18(run_slot[run_k])}, {1'b1, 13'b0, lb_off}, 4'b1111);
                if (run_k + 1'b1 == run_n) begin tries <= 0; st <= L_FETCH; end
                else begin run_k <= run_k + 1'b1; st <= L_ALLOC; end
            end
            L_FETCH: if (!fc_busy) begin
                fc_send <= 1;
                fl_q <= fetch_len; pf_lb <= lb;
                st_cmds <= st_cmds + 1'b1; st_blocks <= st_blocks + run_n;
                if (pfm) begin
                    // background: back to the client; the marker is caught as it comes
                    pfm <= 0; pf_fly <= 1;
                    pf_trig <= lb; pf_trig_v <= 1; pf_next <= run_end; pf_cont <= run_cont;
                    st <= S_READY;
                end else st <= L_WAITF;
            end
            L_WAITF: if (mk_valid) begin
                if (mk_err != 0) begin
                    st_errors <= st_errors + 1'b1;
                    if (tries != 2'd3) begin tries <= tries + 1'b1; st <= L_FETCH; end
                    else begin fail <= 1; run_k <= 0; st <= L_VALID; end
                end else begin run_k <= 0; st <= L_VALID; end
            end
            L_VALID: begin
                mem_go(1, 0, {TB, lb_off}, {run_ra[run_k], 12'b0, 1'b1, 2'b0, pad14(run_slot[run_k])}, 4'b1111);
                if (run_k + 1'b1 == run_n) st <= L_DONE;
                else run_k <= run_k + 1'b1;
            end
            L_DONE: if (pf_fin) begin
                pf_fin <= 0; st <= pf_ret;
            end else begin
                slot <= run_slot[0];
                last_b <= lb; last_slot <= run_slot[0]; last_v <= 1;
                st <= Q_READ;
                // the file goes on after this run: fetch the next one in the background
                if (PREFETCH && run_cont && fwd) begin pf_pend <= 1; pf_b <= run_end; end
            end
            default: st <= S_WAIT;
        endcase
    end
endmodule
`default_nettype wire
