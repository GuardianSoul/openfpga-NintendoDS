// SPDX-License-Identifier: MIT
// DS main RAM on the Pocket's two PSRAM chips (docs/psram-ds.md, room item
// H1): nds_psram_port's clk_sys contract and psx_psram_pair's sequencer in
// one, for what the DS core issues: word writes with byte enables, 16-byte
// reads and 32-byte block reads (two 16-byte reads, or B8: one 8-word burst), die 0. The chips run
// psx_pq_psram (PocketQuake's timing) unchanged, and every pin and every
// s_* output is meant to match nds_psram_port + psx_psram_pair (PAIRED=1,
// LIVE_REQ=1, WRITE_GAP=0) clock for clock (sim/pocket/psram_eq/h1_eq.sh).
// Gone: halfword packets and odd starts, the map check, the fill stream and
// block writes (no DS client issues them: a block request with s_we is a
// sim error).
`default_nettype none
module nds_psram #(parameter real CLOCK_MHZ = 100.541946, parameter integer T_INIT = 16000,
    parameter [15:0] BCR = 16'h641F,
    // 1: a 32-byte block read is one 8-word chip burst (one request, one
    // crossing each way) instead of two 16-byte reads one after the other
    // (docs/psram-ds.md "B8"); 0: as before
    parameter integer B8 = 0,
    // 1: a 32-byte block write (s_n8 with s_we): the 8 words are taken on
    // s_wnext, one a clock, s_ack with the last, then written as 8 chip
    // writes in one request (one crossing) while the client goes on; 0: a
    // block write is an error, as before (docs/psram-ds.md "BW")
    parameter integer BW = 0,
    // 1 (with B8): a block read's words go out on s_rvalid as they arrive
    // (a word count crosses to clk_sys, Gray-coded through two flops),
    // instead of after the whole burst is in and done_t has crossed
    // (docs/psram-ds.md "STREAM"); 0: as before
    parameter integer STREAM = 0,
    // 1: a block read starts at its first word (s_addr[2:0], the ARM9's missed word: nds_fabric A9_CWF), and the
    // chips burst 8 words wrapping at the 32-byte line (BCR wrap on, length 8): critical word first
    parameter integer CWF = 0) (
    input wire clk_sys, clk_mem, reset_sys, reset_mem,
    output reg initialized = 0,
    // clk_sys: s_req held until s_ack (one pulse); s_req drops the cycle after
    input wire s_req, s_we,
    input wire [23:0] s_addr,               // word address (die 0)
    input wire [31:0] s_wdata,
    input wire [3:0] s_be,
    output reg s_ack = 0,
    output reg s_rvalid = 0,
    output reg [31:0] s_rdata = 0,
    input wire s_n8,                        // a 32-byte block read (nds_fabric MR_BLOCK): 8 words
    output wire s_wnext,                    // (block writes: none; kept for the port's interface)
    output wire chip_clk_en,
    output wire [21:16] cram0_a, cram1_a,
    inout wire [15:0] cram0_dq, cram1_dq,
    input wire cram0_wait, cram1_wait,
    output wire cram0_adv_n, cram1_adv_n, cram0_cre, cram1_cre,
    output wire cram0_ce0_n, cram0_ce1_n, cram1_ce0_n, cram1_ce1_n,
    output wire cram0_oe_n, cram1_oe_n, cram0_we_n, cram1_we_n,
    output wire cram0_ub_n, cram0_lb_n, cram1_ub_n, cram1_lb_n
);
    // CWF: BCR bit 3 = 0 (the burst wraps), bits 2:0 = 010 (8 words)
    localparam [15:0] BCR_Q = CWF != 0 ? {BCR[15:4], 4'b0010} : BCR;
    // BW: a block write's words, taken while bw_c
    reg bw_c = 0;
    reg [2:0] bw_k = 0;
    reg [31:0] bwd [0:7];
    reg b_n8w = 0;                           // BW: the request is a block write (8 words from bwd)
    assign s_wnext = BW != 0 && bw_c;

    // ---------------- sys side (nds_psram_port's, reads and word writes) ----------------
    reg req_t = 0, busy = 0;
    reg b_write = 0;
    // The request, formed here at the request edge and held until its answer
    // is in (busy); the mem side reads it two clk_mem edges after it changes
    // (a two-cycle path, build_ds.sh): the word address of the first word,
    // the write's data and byte enables.
    reg [20:0] b_word = 0;
    reg [31:0] b_wdata = 0;
    reg [3:0] b_be = 0;
    reg blk = 0, half = 0;                   // a block read, and its second 16 bytes
    reg [3:0] out_n = 0;                     // words left to hand out
    reg [2:0] out_k = 0;
    reg done_t = 0, done_seen = 0;
    wire [255:0] rsp_raw;
    wire [15:0]  g0_q, g1_q;                 // B8: burst word out_k of chip 0 / 1 (MLABs below)                    // the read's 4 (B8 blocks: 8) words (mem side, final before done_t flips)
    reg b_n8 = 0;                            // B8: the request is a block (8 words; read with b_word)
    // STREAM: the block's words handed out so far (tot, mod 16, also the MLAB
    // index), the mem side's count of block words in (wc_g, Gray) seen here
    // through two flops, and a block being streamed
    reg [3:0] tot = 0;
    reg strm = 0;
    reg [3:0] wc_g = 0;                      // mem side (below)
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [3:0] wc_s1 = 0, wc_s2 = 0;
    wire [3:0] wc_b = {wc_s2[3], wc_s2[3] ^ wc_s2[2], wc_s2[3] ^ wc_s2[2] ^ wc_s2[1], wc_s2[3] ^ wc_s2[2] ^ wc_s2[1] ^ wc_s2[0]};
    wire st_on = STREAM != 0 && B8 != 0;
    always @(posedge clk_sys) begin
        s_ack <= 0; s_rvalid <= 0;
        if (st_on) begin wc_s1 <= wc_g; wc_s2 <= wc_s1; end
        if (reset_sys) begin busy <= 0; out_n <= 0; done_seen <= done_t; blk <= 0; strm <= 0; tot <= wc_b; end
        else begin
            if (BW != 0 && !busy && !bw_c && s_req && !s_ack && out_n == 0 && !blk && !strm && s_n8 && s_we) begin
                bw_c <= 1; bw_k <= 3'd0; b_word <= {s_addr[20:3], 3'b000};
            end else if (!busy && !bw_c && s_req && !s_ack && out_n == 0 && !blk && !strm && s_n8) begin
                blk <= B8 == 0; half <= 0; b_write <= 1'b0; b_n8 <= B8 != 0; strm <= st_on;
                b_word <= CWF != 0 ? s_addr[20:0] : {s_addr[20:3], 3'b000};
                busy <= 1; s_ack <= 1; req_t <= !req_t;
            end else if (!busy && !bw_c && s_req && !s_ack && out_n == 0 && !blk && !strm) begin
                busy <= 1; s_ack <= 1; req_t <= !req_t;
                b_write <= s_we; b_n8 <= 1'b0; b_n8w <= 1'b0;
                if (s_we) begin b_wdata <= s_wdata; b_be <= s_be; end
                b_word <= s_we ? s_addr[20:0] : {s_addr[20:2], 2'b00};
            end
            if (bw_c) begin
                bwd[bw_k] <= s_wdata; bw_k <= bw_k + 1'b1;
                if (bw_k == 3'd7) begin
                    bw_c <= 0; busy <= 1; s_ack <= 1; req_t <= !req_t;
                    b_write <= 1'b1; b_n8 <= 1'b0; b_n8w <= 1'b1; b_be <= 4'hF;
                end
            end
            if (busy && done_t != done_seen) begin
                done_seen <= done_t; busy <= 0;
                if (!b_write && !(st_on && b_n8)) begin out_n <= b_n8 ? 4'd8 : 4'd4; out_k <= 3'd0; end
            end
            // STREAM: word tot of the block once the mem side's count is past it
            if (strm && tot != wc_b) begin
                s_rvalid <= 1; s_rdata <= {g1_q, g0_q};
                tot <= tot + 4'd1;
                if (tot[2:0] == 3'd7) strm <= 0;
            end
            if (out_n != 0) begin
                s_rvalid <= 1; s_rdata <= B8 != 0 ? {g1_q, g0_q} : rsp_raw[out_k*32 +: 32];
                out_k <= out_k + 1'b1; out_n <= out_n - 1'b1;
                // block read: the second 16 bytes once the first are handed out
                if (out_n == 4'd1 && blk) begin
                    if (!half) begin half <= 1; b_word <= b_word + 21'd4; busy <= 1; req_t <= !req_t; end
                    else blk <= 0;
                end
            end
        end
    end
    // synthesis translate_off
    always @(posedge clk_sys)
        if (BW == 0 && !reset_sys && s_req && s_n8 && s_we)
            $display("nds_psram: ERROR: a block write (no DS client issues them) at %0t", $time);
    // synthesis translate_on

    // ---------------- mem side: the request toggle ----------------
    reg req_valid = 0, req_write = 0, req_n8 = 0, req_n8w = 0;
    reg req_seen = 0, m_busy = 0;
    wire req_ready, rsp_valid;
    always @(posedge clk_mem) begin
        if (req_valid && req_ready) req_valid <= 0;
        // req_seen follows req_t while idle (04c4aa6: req_t straight to D)
        if (!m_busy) req_seen <= req_t;
        if (!m_busy && req_t != req_seen) begin
            m_busy <= 1; req_valid <= 1;
            req_write <= b_write; req_n8 <= B8 != 0 && b_n8; req_n8w <= BW != 0 && b_n8w;
        end
        if (m_busy && rsp_valid) begin
            m_busy <= 0; done_t <= !done_t;
        end
    end

    // ---------------- the two chip controllers, in lockstep ----------------
    reg bank = 0, write_en = 0, burst_en = 0, config_en = 0;
    reg [2:0] wi = 0;                        // BW: the block write's word
    // The chips read the held request directly (b_word, b_wdata, b_be: their two-clk_mem-edge paths, build_ds.sh; no
    // copies here). The address pins follow b_word while the chips aren't selected.
    wire [21:0] chip_addr = {1'b0, b_word[20:3], req_n8w ? wi : b_word[2:0]};
    wire [15:0] wdata0 = req_n8w ? bwd[wi][15:0] : b_wdata[15:0], wdata1 = req_n8w ? bwd[wi][31:16] : b_wdata[31:16];
    wire [1:0] be0 = b_be[1:0], be1 = b_be[3:2];
    wire we0 = be0 != 2'd0, we1 = be1 != 2'd0;
    wire [1:0] avail, cbusy;
    wire [15:0] rdata0, rdata1;
    psx_pq_psram #(.CLOCK_SPEED(CLOCK_MHZ), .LATCH_DATA(0), .EARLY(B8 != 0)) chip0 (.clk(clk_mem), .bank_sel(bank), .addr(chip_addr),
        .write_en(write_en && we0), .data_in(wdata0), .write_high_byte(be0[1]), .write_low_byte(be0[0]),
        .read_en(1'b0), .sync_burst_en(burst_en), .sync_burst_len(req_n8 ? 6'd7 : 6'd3),
        .config_en(config_en), .config_data(BCR_Q),
        .read_avail(avail[0]), .data_out(rdata0), .busy(cbusy[0]),
        .dbg_wait_seen(), .dbg_wait_cycles(), .dbg_burst_count(), .dbg_stale_count(),
        .cram_a(cram0_a), .cram_dq(cram0_dq), .cram_wait(cram0_wait), .cram_clk(),
        .cram_adv_n(cram0_adv_n), .cram_cre(cram0_cre), .cram_ce0_n(cram0_ce0_n), .cram_ce1_n(cram0_ce1_n),
        .cram_oe_n(cram0_oe_n), .cram_we_n(cram0_we_n), .cram_ub_n(cram0_ub_n), .cram_lb_n(cram0_lb_n));
    psx_pq_psram #(.CLOCK_SPEED(CLOCK_MHZ), .LATCH_DATA(0), .EARLY(B8 != 0)) chip1 (.clk(clk_mem), .bank_sel(bank), .addr(chip_addr),
        .write_en(write_en && we1), .data_in(wdata1), .write_high_byte(be1[1]), .write_low_byte(be1[0]),
        .read_en(1'b0), .sync_burst_en(burst_en), .sync_burst_len(req_n8 ? 6'd7 : 6'd3),
        .config_en(config_en), .config_data(BCR_Q),
        .read_avail(avail[1]), .data_out(rdata1), .busy(cbusy[1]),
        .dbg_wait_seen(), .dbg_wait_cycles(), .dbg_burst_count(), .dbg_stale_count(),
        .cram_a(cram1_a), .cram_dq(cram1_dq), .cram_wait(cram1_wait), .cram_clk(),
        .cram_adv_n(cram1_adv_n), .cram_cre(cram1_cre), .cram_ce0_n(cram1_ce0_n), .cram_ce1_n(cram1_ce1_n),
        .cram_oe_n(cram1_oe_n), .cram_we_n(cram1_we_n), .cram_ub_n(cram1_ub_n), .cram_lb_n(cram1_lb_n));

    // ---------------- sequencer (psx_psram_pair's states, DS packets only) ----------------
    localparam [3:0] INIT = 0, CFG0 = 1, CFG_WAIT = 2, IDLE = 3, WR = 4, WR_WAIT = 5, RD = 6, RD_DATA = 7, RSP = 8, SETTLE = 9;
    reg [3:0] state = INIT, after = INIT;
    reg [15:0] timer = 0;
    reg [15:0] got0 [0:B8 ? 7 : 3], got1 [0:B8 ? 7 : 3];
    reg [3:0] n0 = 0, n1 = 0;
    reg [3:0] filled = 0;
    // words with both halves present (registered, one cycle behind the counters)
    reg [3:0] have = 0;
    always @(posedge clk_mem) have <= state != RD_DATA ? 4'd0 : (n0 < n1 ? n0 : n1);
    // STREAM: block words with both halves written (have, one behind the MLAB writes), counted mod 16 in Gray
    reg [3:0] wc = 0;
    always @(posedge clk_mem)
        if (STREAM != 0 && B8 != 0 && req_n8 && state == RD_DATA && filled < have) begin
            wc <= wc + 4'd1; wc_g <= (wc + 4'd1) ^ ((wc + 4'd1) >> 1);
        end
    // B8: the burst words in MLABs (written on clk_mem as they arrive, read
    // by clk_sys at out_k without a clock: final before done_t flips, held
    // until the next read), not 256 flops and an 8-way read mux
    generate if (B8 != 0) begin : g_raw8
        (* ramstyle = "MLAB, no_rw_check" *) reg [15:0] m0 [0:7];
        (* ramstyle = "MLAB, no_rw_check" *) reg [15:0] m1 [0:7];
        always @(posedge clk_mem) begin
            if (state == RD_DATA && avail[0]) m0[n0[2:0]] <= rdata0;
            if (state == RD_DATA && avail[1]) m1[n1[2:0]] <= rdata1;
        end
        assign g0_q = m0[strm ? tot[2:0] : out_k];
        assign g1_q = m1[strm ? tot[2:0] : out_k];
        assign rsp_raw = 256'd0;
    end else begin : g_raw4
        assign g0_q = 16'd0; assign g1_q = 16'd0;
        assign rsp_raw = {128'd0, got1[3], got0[3], got1[2], got0[2], got1[1], got0[1], got1[0], got0[0]};
    end endgenerate
    assign req_ready = !reset_mem && state == IDLE;
    assign rsp_valid = !reset_mem && state == RSP;
    assign chip_clk_en = state == RD_DATA;
    // a read is 4 words, a write 1 (the pair's words = (halfwords + 1) / 2)
    wire [3:0] words = req_write ? 4'd1 : req_n8 ? 4'd8 : 4'd4;

    always @(posedge clk_mem) begin
        write_en <= 0; burst_en <= 0; config_en <= 0;
        if (reset_mem) begin
            state <= INIT; timer <= 0; initialized <= 0; n0 <= 0; n1 <= 0; filled <= 0;
        end else case (state)
            INIT: begin
                timer <= timer + 1'b1;
                if (timer == T_INIT[15:0]) begin bank <= 0; state <= CFG0; end
            end
            CFG0: begin config_en <= 1; after <= bank ? IDLE : CFG0; state <= SETTLE; end
            SETTLE: state <= CFG_WAIT;
            CFG_WAIT: if (cbusy == 2'b00) begin
                if (after == IDLE) begin initialized <= 1; state <= IDLE; end
                else begin bank <= 1; state <= CFG0; end
            end
            IDLE: if (req_valid) begin
                bank <= 1'b0;
                n0 <= 0; n1 <= 0; filled <= 0; wi <= 3'd0;
                state <= req_write ? WR : RD;
            end
            // chip_addr moves in WR/RD, as the pair's: the chips' A pins follow it while idle
            WR: begin
                // (BW: a block write's word wi of bwd, all bytes)
                write_en <= 1; state <= WR_WAIT;
            end
            WR_WAIT: if (!write_en && cbusy == 2'b00) begin
                if (req_n8w && wi != 3'd7) begin wi <= wi + 3'd1; state <= WR; end
                else state <= RSP;
            end
            RD: begin burst_en <= 1; state <= RD_DATA; end
            RD_DATA: begin
                if (avail[0]) begin if (B8 == 0) got0[n0[1:0]] <= rdata0; n0 <= n0 + 1'b1; end
                if (avail[1]) begin if (B8 == 0) got1[n1[1:0]] <= rdata1; n1 <= n1 + 1'b1; end
                if (filled < have) filled <= filled + 1'b1;
                else if (filled == words) state <= RSP;
            end
            RSP: state <= IDLE;
            default: state <= INIT;
        endcase
    end
endmodule
`default_nettype wire
