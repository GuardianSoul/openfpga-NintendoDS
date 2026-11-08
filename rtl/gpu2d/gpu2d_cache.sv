// Per-line VRAM block cache (docs/memory-replay.md: 32-byte blocks, cleared
// at every line). Direct-mapped, 2^IDXW blocks of 4 x 64-bit words, one read
// port: the address given at cycle t is read at t+1 (q, hit). While `hold`
// is high the last address is read again every clock, so a stalled pipeline
// sees a fill land. The owner turns `need && !hit` into a fill request;
// gpu2d.sv's arbiter writes the four beats of the block `fill_blk` through
// the fill port. That may be a prefetch, not the latched address, so the
// slot's tag is invalidated on the first beat: a slot is never read
// half-written.
//
// Clearing without valid bits: each tag entry carries the generation it was
// filled in, and a hit needs the current generation. `clear` starts a new
// generation (every job, or with PERSIST only after VRAM was written).
// Generation 0 is never current; while the owner is idle a scrubber reads
// each tag and rewrites entries of older generations as generation 0, so an
// entry is retired long before its generation could come round again
// (2^GW - 1 clears; one revolution needs 2^IDXW idle clocks, and every
// VBlank has thousands).
//
// The generation and the scrub counter live in gpu2d_cgen, one per side:
// the BG side's three caches (and the OBJ side's two) clear and idle
// together, so their counters were identical copies. A cache with a
// smaller index takes the counter's low bits, which count exactly as its
// own counter did.
module gpu2d_cgen #(
    parameter int SW = 6,       // the widest IDXW it serves
    parameter int GW = 10
) (
    input  logic          clk,
    input  logic          clear,
    input  logic          idle,
    output logic [GW-1:0] gen,
    output logic [SW-1:0] scrub,
    output logic [SW-1:0] scrub_q,
    output logic          scrub_v
);
    logic [GW-1:0] g = GW'(1);  // power-up value
    assign gen = g;
    always_ff @(posedge clk) begin
        if (clear) g <= g == {GW{1'b1}} ? GW'(1) : g + GW'(1);
        if (idle) scrub <= scrub + 1'b1;
        scrub_q <= scrub;
        scrub_v <= idle;
    end

    // synthesis translate_off
    // the scrubber must complete a revolution well within a generation cycle
    int unsigned since_rev = 0;
    always_ff @(posedge clk) begin
        if (idle && scrub == '1) since_rev <= 0;
        else if (clear) since_rev <= since_rev + 1;
        if (since_rev >= (1 << GW) - 2) $fatal(1, "gpu2d_cache: scrubber starved for %0d jobs", since_rev);
    end
    // synthesis translate_on
endmodule

module gpu2d_cache
    import gpu2d_pkg::*;
#(
    parameter int IDXW = 6,
    parameter int GW   = 10,
    parameter bit TAG_MLAB = 0,  // tag RAM in MLAB (frees its M10K; ~4 LABs)
    parameter int HASH = 0,      // index function (idx_of)
    // VLO: only block-address bits [VLO-1:0] vary in this cache (and, below
    // 15, the engine bit 14): the tag stores those, the rest are constant. An
    // ext-palette cache holds one space, 32 KB (BG) or 8 KB (OBJ) per engine
    parameter int VLO = $bits(blk_t),
    // TAG_DATA: no tag RAM. Each data word carries its block's {gen, tag} in
    // the 16 bits the 64-bit word leaves free in its two 40-bit M10Ks,
    // written with that word: a word hits when its own copy matches, so a
    // block being filled serves the words already written and the old block
    // the rest. The scrubber walks words (scrub is IDXW + 2 bits) and clears
    // a word's copy of an older generation. Needs GW + tag bits <= 16 (the
    // ext-palette caches with VLO)
    parameter bit TAG_DATA = 0,
    // HALF: q is the 16-bit halfword a_half of the word (in q[15:0], the rest
    // 0), read from the data RAM as two byte lanes of mixed width (written
    // 32 bits, read 8: gpu2d_ram_w32r8), so the owner needs no 4:1 halfword
    // select; the same M10Ks as the 64-bit RAM. Not with TAG_DATA
    parameter bit HALF = 0
) (
    input  logic        clk,
    input  logic        idle,        // owner idle: scrub
    input  logic [GW-1:0]   gen,     // gpu2d_cgen
    input  logic [(TAG_DATA ? IDXW + 2 : IDXW)-1:0] scrub,
    input  logic [(TAG_DATA ? IDXW + 2 : IDXW)-1:0] scrub_q,
    input  logic            scrub_v,
    input  logic        hold,
    input  blk_t        a_blk,       // address for the next read (when !hold)
    input  logic [1:0]  a_word,
    input  logic [1:0]  a_half,      // HALF: the halfword of the word (latched with it)
    output logic [63:0] q,
    output logic        hit,
    output blk_t        cur_blk,     // block of the latched address (fill request)
    output logic [1:0]  cur_word,
    input  logic        fill_we,
    input  blk_t        fill_blk,
    input  logic [1:0]  fill_beat,
    input  logic        fill_last,
    input  logic [63:0] fill_data
);
    localparam bit SEP_ENG = VLO <= 14;
    localparam int TW = VLO - IDXW + (SEP_ENG ? 1 : 0);
    function automatic logic [TW-1:0] tag_of(input blk_t b);
        if (SEP_ENG) return TW'({b[14], b[VLO-1:IDXW]});
        return TW'(b[VLO-1:IDXW]);
    endfunction

    blk_t       q_blk;
    logic [1:0] q_word, q_half;
    always_ff @(posedge clk)
        if (!hold) begin q_blk <= a_blk; q_word <= a_word; q_half <= a_half; end
    blk_t r_blk;
    assign r_blk = hold ? q_blk  : a_blk;
    // The index folds the next block-address bits in: BG map bases are 2 KB
    // apart and char bases 16 KB, exactly a cache's size, so with the low
    // bits alone every layer's map row (and same-numbered tiles) took the
    // same slots and the layers evicted each other every line (KH's menu:
    // ~250 stall clocks per layer a line, late lines). The tag keeps all the
    // upper bits that vary (VLO), so a block is still identified exactly.
    // HASH (docs/compat.md "Mario & Luigi"): the index from the block
    // address's IDXW-bit fields c0 (low), c1, c2 (the bits above):
    //   0: c0 ^ c1 (OBJ caches)
    //   1: c0 ^ reverse(c1) ^ c2 (BG map and texel caches): a 512-wide map's
    //      second screen block is 2 KB (64 blocks) on, which plain c0 ^ c1
    //      put on its first block's slots XOR 1, so a map row's three blocks
    //      shared two slots and missed every line; c2 tells the engines apart
    //   2: c0 ^ rotl(c1, 2) ^ rotl(c2, 3) (BG ext-palette cache): a block is
    //      one 16-colour group of a palette, so a palette fills index bits
    //      0-3; slot and engine go to bits 4-5 instead of onto the groups
    function automatic logic [IDXW-1:0] idx_of(input blk_t b);
        logic [3*IDXW-1:0] w;
        logic [IDXW-1:0] c0, c1, c2, r1;
        w = (3*IDXW)'(b);
        c0 = w[IDXW-1:0]; c1 = w[2*IDXW-1:IDXW]; c2 = w[3*IDXW-1:2*IDXW];
        for (int i = 0; i < IDXW; i++) r1[i] = c1[IDXW-1-i];
        if (HASH == 1) return c0 ^ r1 ^ c2;
        if (HASH == 2) return c0 ^ {c1[IDXW-3:0], c1[IDXW-1:IDXW-2]} ^ {c2[IDXW-4:0], c2[IDXW-1:IDXW-3]};
        return c0 ^ c1;
    endfunction
    logic [IDXW-1:0] r_idx, r_bidx;
    assign r_bidx = idx_of(r_blk);
    assign r_idx = idle ? scrub[IDXW-1:0] : r_bidx;
    logic [1:0] r_word, r_half;
    assign r_word = hold ? q_word : a_word;
    assign r_half = hold ? q_half : a_half;
    logic [IDXW-1:0] fidx;
    assign fidx = idx_of(fill_blk);

    logic [GW+TW-1:0] tag_q;
    generate if (TAG_DATA) begin : g_td
        // synthesis translate_off
        initial if (GW + TW > 16) $fatal(1, "gpu2d_cache: TAG_DATA needs GW + TW <= 16, not %0d", GW + TW);
        initial if (HALF) $fatal(1, "gpu2d_cache: HALF is not for TAG_DATA");
        // synthesis translate_on
        logic [79:0] d_q, d_wd;
        logic        d_we, s_we;
        logic [IDXW+1:0] d_wa;
        assign tag_q = d_q[64 +: GW+TW];
        // the scrub read of the last clock: clear that word's copy if it is
        // of an older generation (with whatever data: the word then misses)
        assign s_we = !fill_we && scrub_v && tag_q[GW+TW-1:TW] != gen && tag_q[GW+TW-1:TW] != '0;
        assign d_we = fill_we || s_we;
        assign d_wa = fill_we ? {fidx, fill_beat} : scrub_q;
        assign d_wd = {16'(fill_we ? {gen, tag_of(fill_blk)} : '0), fill_data};
        gpu2d_ram #(.W(80), .AW(IDXW+2)) u_data (
            .clk, .we(d_we), .waddr(d_wa), .wdata(d_wd),
            .raddr(idle ? scrub : {r_bidx, r_word}), .rdata(d_q));
        assign q = d_q[63:0];
    end else begin : g_tt
        if (HALF) begin : g_h
            // lane 0: bytes 0, 2, 4, 6 of the word; lane 1: bytes 1, 3, 5, 7
            logic [7:0] q0, q1;
            gpu2d_ram_w32r8 #(.AW(IDXW+2)) u_d0 (.clk, .we(fill_we), .waddr({fidx, fill_beat}),
                .wdata({fill_data[55:48], fill_data[39:32], fill_data[23:16], fill_data[7:0]}),
                .raddr({r_bidx, r_word, r_half}), .rdata(q0));
            gpu2d_ram_w32r8 #(.AW(IDXW+2)) u_d1 (.clk, .we(fill_we), .waddr({fidx, fill_beat}),
                .wdata({fill_data[63:56], fill_data[47:40], fill_data[31:24], fill_data[15:8]}),
                .raddr({r_bidx, r_word, r_half}), .rdata(q1));
            assign q = {48'd0, q1, q0};
        end else begin : g_w
            gpu2d_ram #(.W(64), .AW(IDXW+2)) u_data (
                .clk, .we(fill_we), .waddr({fidx, fill_beat}), .wdata(fill_data),
                .raddr({r_bidx, r_word}), .rdata(q));
        end

        logic            tag_we;
        logic [IDXW-1:0] tag_wa;
        logic [GW+TW-1:0] tag_wd;
        always_comb begin
            tag_we = fill_we && (fill_last || fill_beat == 2'd0);
            tag_wa = fidx;
            tag_wd = fill_last ? {gen, tag_of(fill_blk)} : '0;
            // the scrub read of the last clock: retire it if it is an older generation
            if (!tag_we && scrub_v && tag_q[GW+TW-1:TW] != gen && tag_q[GW+TW-1:TW] != '0) begin
                tag_we = 1'b1; tag_wa = scrub_q; tag_wd = '0;
            end
        end
        if (TAG_MLAB) begin : g_tm
            gpu2d_mlab_od #(.W(GW + TW), .AW(IDXW)) u_tag (
                .clk, .we(tag_we), .waddr(tag_wa), .wdata(tag_wd),
                .raddr(r_idx), .rdata(tag_q));
        end else begin : g_tr
            gpu2d_ram #(.W(GW + TW), .AW(IDXW)) u_tag (
                .clk, .we(tag_we), .waddr(tag_wa), .wdata(tag_wd),
                .raddr(r_idx), .rdata(tag_q));
        end
    end endgenerate

    assign hit      = tag_q == {gen, tag_of(q_blk)};
    assign cur_blk  = q_blk;
    assign cur_word = q_word;
endmodule
