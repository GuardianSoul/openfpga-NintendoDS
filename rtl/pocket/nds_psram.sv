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
    parameter integer CWF = 0,
    // B8's two 8x16 burst buffers in M10K (core_top_ds RAM_MOVE 32), read on clk_sys's falling edge: written on
    // clk_mem long before they are read (STREAM: the Gray count crosses after the write; else before done_t flips),
    // so the word is the same as the MLABs' read without a clock; s_rdata takes it at the next rising edge
    parameter integer FE_RD = 0) (
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
    wire [1:0] avail, cbusy;
    wire [15:0] rdata0, rdata1;
    // (one sequencer for both chips, nds_pq_psram2 below: psx_pq_psram's pins on each, clock for clock)
    wire [1:0] c_adv, c_cre, c_ce0, c_ce1, c_oe, c_we, c_ub, c_lb;
    // (the pins' input capture registers keep psx_pq_psram's names, psram|chipN|cram_dq_r and cram_wait_r: the SDC's
    // multicycle from the chip clock, build_ds.sh)
    wire [15:0] dq_r0, dq_r1;
    wire [1:0] wait_r;
    nds_pq_cap chip0 (.clk(clk_mem), .dq(cram0_dq), .wt(cram0_wait), .cram_dq_r(dq_r0), .cram_wait_r(wait_r[0]));
    nds_pq_cap chip1 (.clk(clk_mem), .dq(cram1_dq), .wt(cram1_wait), .cram_dq_r(dq_r1), .cram_wait_r(wait_r[1]));
    nds_pq_psram2 #(.CLOCK_SPEED(CLOCK_MHZ), .EARLY(B8 != 0)) chips (.dq_r0(dq_r0), .dq_r1(dq_r1), .wait_r(wait_r),
        .clk(clk_mem), .bank_sel(bank), .addr(chip_addr),
        .write_en(write_en), .data_in0(wdata0), .data_in1(wdata1), .be(b_be),
        .sync_burst_en(burst_en), .sync_burst_len(req_n8 ? 6'd7 : 6'd3), .config_en(config_en), .config_data(BCR_Q),
        .read_avail(avail), .data_out0(rdata0), .data_out1(rdata1), .busy(cbusy),
        .cram0_a(cram0_a), .cram1_a(cram1_a), .cram0_dq(cram0_dq), .cram1_dq(cram1_dq),
        .cram_adv_n(c_adv), .cram_cre(c_cre), .cram_ce0_n(c_ce0), .cram_ce1_n(c_ce1), .cram_oe_n(c_oe), .cram_we_n(c_we),
        .cram_ub_n(c_ub), .cram_lb_n(c_lb));
    assign {cram1_adv_n, cram0_adv_n} = c_adv; assign {cram1_cre, cram0_cre} = c_cre;
    assign {cram1_ce0_n, cram0_ce0_n} = c_ce0; assign {cram1_ce1_n, cram0_ce1_n} = c_ce1;
    assign {cram1_oe_n, cram0_oe_n} = c_oe; assign {cram1_we_n, cram0_we_n} = c_we;
    assign {cram1_ub_n, cram0_ub_n} = c_ub; assign {cram1_lb_n, cram0_lb_n} = c_lb;

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
        wire [2:0] g_ra = strm ? tot[2:0] : out_k;
        if (FE_RD != 0) begin : g_fe
            (* ramstyle = "M10K, no_rw_check" *) reg [15:0] m0 [0:7];
            (* ramstyle = "M10K, no_rw_check" *) reg [15:0] m1 [0:7];
            reg [15:0] q0, q1;
            always @(posedge clk_mem) begin
                if (state == RD_DATA && avail[0]) m0[n0[2:0]] <= rdata0;
                if (state == RD_DATA && avail[1]) m1[n1[2:0]] <= rdata1;
            end
            always @(negedge clk_sys) begin q0 <= m0[g_ra]; q1 <= m1[g_ra]; end
`ifdef PSRAM_FE_MUT
            assign g0_q = q1; assign g1_q = q0;   // deliberate bug: the chips' halves swapped
`else
            assign g0_q = q0; assign g1_q = q1;
`endif
        end else begin : g_ml
            (* ramstyle = "MLAB, no_rw_check" *) reg [15:0] m0 [0:7];
            (* ramstyle = "MLAB, no_rw_check" *) reg [15:0] m1 [0:7];
            always @(posedge clk_mem) begin
                if (state == RD_DATA && avail[0]) m0[n0[2:0]] <= rdata0;
                if (state == RD_DATA && avail[1]) m1[n1[2:0]] <= rdata1;
            end
            assign g0_q = m0[g_ra];
            assign g1_q = m1[g_ra];
        end
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

// Both chips' psx_pq_psram with one sequencer (docs/psram-ds.md, docs/space-io.md). The two controllers ran in
// lockstep but for a write's chips (a write to one chip leaves the other idle: on) and each chip's sync burst data
// phase, which follows its own WAIT (dp: data, en: the end state, bc: the halfwords left). The state counter, its
// decode and the latency count are shared; each chip's pins come from its view of the state (st), with
// psx_pq_psram's assignments in its order, so every pin is as before, clock for clock. Only what nds_psram uses:
// no async reads, LATCH_DATA 0, no debug counters.
module nds_pq_psram2 #(parameter CLOCK_SPEED = 48.0, parameter SYNC_LATENCY = 4, parameter EARLY = 0) (
    input wire clk,
    input wire bank_sel,
    input wire [21:0] addr,
    input wire write_en,
    input wire [15:0] data_in0, data_in1,
    input wire [3:0] be,                    // {chip 1 high, low, chip 0 high, low}: a chip writes with either set
    input wire sync_burst_en,
    input wire [5:0] sync_burst_len,
    input wire config_en,
    input wire [15:0] config_data,
    output wire [1:0] read_avail,
    output wire [15:0] data_out0, data_out1,
    output wire [1:0] busy,
    output wire [21:16] cram0_a, cram1_a,
    inout wire [15:0] cram0_dq, cram1_dq,
    input wire [15:0] dq_r0, dq_r1,         // the pins' capture registers (nds_pq_cap): DQ and WAIT a clock late
    input wire [1:0] wait_r,
    output wire [1:0] cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n, cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n
);
    // psx_pq_psram's cycle counts (its CEIL: the integer conversion rounds, so an exact multiple gets one more)
    // (psx_pq_psram's form: Quartus takes no real-typed function argument, so the conversion is the call's)
    localparam PERIOD = 1000.0 / CLOCK_SPEED;
    function automatic integer pq_rtoi(input integer x);
        pq_rtoi = x;
    endfunction
`define PQ_CEIL(x) ((pq_rtoi(x) > (x)) ? pq_rtoi(x) : pq_rtoi(x) + 1)
    function automatic integer pq_max(input integer a, input integer b);
        pq_max = a > b ? a : b;
    endfunction
    localparam integer ADV_CYCLE_COUNT = pq_max(pq_max(`PQ_CEIL(5 / PERIOD), `PQ_CEIL((5 + 2) / PERIOD)), `PQ_CEIL(7 / PERIOD));
    localparam integer ADDR_HOLD_AFTER_ADV_CYCLE_COUNT = `PQ_CEIL(2 / PERIOD);
    localparam integer DATA_AFTER_ADDR_UNLATCH_CYCLE_COUNT = `PQ_CEIL(8 / PERIOD);
    localparam integer TOTAL_WRITE_CYCLE_COUNT = `PQ_CEIL(70 / PERIOD);
    localparam [7:0] STATE_NONE = 0;
    localparam [7:0] WRITE_INITIAL_COUNT = 1;
    localparam [7:0] STATE_WRITE_ADV_END = WRITE_INITIAL_COUNT - 1 + ADV_CYCLE_COUNT;
    localparam [7:0] STATE_WRITE_ADDR_LATCH_END = STATE_WRITE_ADV_END + ADDR_HOLD_AFTER_ADV_CYCLE_COUNT;
    localparam [7:0] STATE_WRITE_DATA_START = STATE_WRITE_ADDR_LATCH_END + DATA_AFTER_ADDR_UNLATCH_CYCLE_COUNT;
    localparam [7:0] STATE_WRITE_DATA_END = WRITE_INITIAL_COUNT + TOTAL_WRITE_CYCLE_COUNT;
    localparam [7:0] STATE_CONFIG_CRE_WAIT = 48, STATE_CONFIG_CRE_SETUP = 49, STATE_CONFIG_START = 50;
    localparam [7:0] STATE_CONFIG_ADV_END = STATE_CONFIG_START + ADV_CYCLE_COUNT - 1;
    localparam [7:0] STATE_CONFIG_HOLD_END = STATE_CONFIG_START + TOTAL_WRITE_CYCLE_COUNT;
    localparam [7:0] STATE_SYNC_CE_SETUP = 59, STATE_SYNC_SETUP = 60, STATE_SYNC_WAIT = 61, STATE_SYNC_DATA = 62, STATE_SYNC_END = 63;

    wire [1:0] we_c = {be[3:2] != 2'd0, be[1:0] != 2'd0};

    // A chip's view of the shared state: its own data phase in the burst's (data, then STATE_SYNC_END, then idle),
    // idle through a write it has no part in (the write states are 1-19: psx_pq_psram's async reads, never used
    // here, start at 20). The shared state never holds STATE_SYNC_END.

    // ---------------- the shared sequencer
    reg [7:0] state = STATE_NONE;
    reg [7:0] sn;
    reg [5:0] latency_counter;
    reg [1:0] dp = 2'b00, en = 2'b00, on = 2'b00;
    reg [1:0] dp_n, en_n, on_n;
    reg [5:0] bc0, bc1;
    reg [1:0] wait_r2 = 2'b00;
    always @(posedge clk) wait_r2 <= wait_r;
    // the next state (combinational: the chips' cram_data flags take it, as psx_pq_psram's take its sn)
    always @* begin
        sn = state; dp_n = dp; en_n = en; on_n = on;
        if (state != STATE_NONE) sn = state + 8'd1;
        case (state)
            STATE_NONE:
                if (write_en && we_c != 2'b00) begin sn = WRITE_INITIAL_COUNT; on_n = we_c; end
                else if (config_en) sn = STATE_CONFIG_CRE_WAIT;
                else if (sync_burst_en) sn = STATE_SYNC_CE_SETUP;
            STATE_WRITE_DATA_END: sn = STATE_NONE;
            STATE_CONFIG_HOLD_END: sn = STATE_NONE;
            STATE_SYNC_CE_SETUP: sn = STATE_SYNC_SETUP;
            STATE_SYNC_SETUP: sn = STATE_SYNC_WAIT;
            STATE_SYNC_WAIT:
                if (latency_counter == 6'd0) begin sn = STATE_SYNC_DATA; dp_n = 2'b11; en_n = 2'b00; end
                else sn = STATE_SYNC_WAIT;
            STATE_SYNC_DATA: begin
                en_n = 2'b00;
                if (dp[0] && !wait_r2[0] && bc0 == 6'd0) begin dp_n[0] = 1'b0; en_n[0] = 1'b1; end
                if (dp[1] && !wait_r2[1] && bc1 == 6'd0) begin dp_n[1] = 1'b0; en_n[1] = 1'b1; end
                sn = (dp_n != 2'b00 || en_n != 2'b00) ? STATE_SYNC_DATA : STATE_NONE;
            end
            default: ;
        endcase
    end
    always @(posedge clk) begin
        state <= sn; dp <= dp_n; en <= en_n; on <= on_n;
        if (state == STATE_NONE && !(write_en && we_c != 2'b00) && !config_en && sync_burst_en) begin
            latency_counter <= SYNC_LATENCY[5:0];
            bc0 <= sync_burst_len; bc1 <= sync_burst_len;
        end
        if (state == STATE_SYNC_SETUP || (state == STATE_SYNC_WAIT && latency_counter != 6'd0)) latency_counter <= latency_counter - 6'd1;
        if (state == STATE_SYNC_DATA && dp[0] && !wait_r2[0] && bc0 != 6'd0) bc0 <= bc0 - 6'd1;
        if (state == STATE_SYNC_DATA && dp[1] && !wait_r2[1] && bc1 != 6'd0) bc1 <= bc1 - 6'd1;
    end
    // synthesis translate_off
    always @(posedge clk)
        if ((dp != 2'b00 || en != 2'b00) && state != STATE_SYNC_DATA)
            $display("nds_pq_psram2: ERROR: a chip's data phase outside the burst at %0t", $time);
    // synthesis translate_on

    // ---------------- each chip's pins: psx_pq_psram's assignments, on the chip's view of the state
    wire [21:16] ca0, ca1;
    wire [15:0] cd0, cd1, do0, do1;
    wire [1:0] doe;
    assign cram0_a = ca0; assign cram1_a = ca1;
    assign cram0_dq = doe[0] ? cd0 : 16'hZZZZ;
    assign cram1_dq = doe[1] ? cd1 : 16'hZZZZ;
    assign data_out0 = do0; assign data_out1 = do1;
    // the shared state's decode, once for both chips (eff above, as flags: a write state counts for a chip in it
    // (on), the burst's data state for a chip in its data phase (dp) or end state (en); else the chip is idle)
    wire s_none = state == STATE_NONE, s_wr = state != STATE_NONE && state < 8'd20;
    wire s_wadv = state == STATE_WRITE_ADV_END, s_wlat = state == STATE_WRITE_ADDR_LATCH_END;
    wire s_wdst = state == STATE_WRITE_DATA_START, s_wend = state == STATE_WRITE_DATA_END;
    wire s_ccs = state == STATE_CONFIG_CRE_SETUP, s_cadv = state == STATE_CONFIG_ADV_END, s_chold = state == STATE_CONFIG_HOLD_END;
    wire s_sce = state == STATE_SYNC_CE_SETUP, s_ssu = state == STATE_SYNC_SETUP, s_sdata = state == STATE_SYNC_DATA;
    wire n_none = sn == STATE_NONE, n_wr = sn != STATE_NONE && sn < 8'd20, n_wdst = sn == STATE_WRITE_DATA_START;
    wire n_ccs = sn == STATE_CONFIG_CRE_SETUP, n_sdata = sn == STATE_SYNC_DATA;
    genvar c;
    generate for (c = 0; c < 2; c = c + 1) begin : g_chip
        // The pin registers' decode, retimed (the clk_mem fix: the shared state's decode to both chips' pins, far
        // apart, failed clk_mem in 9 of 11 fits, #1761-#1771): each chip registers its own copy of every flag it
        // uses, from the next state (sn) and the next per-chip flags (on_n, dp_n, en_n), so a flag here equals the
        // decode of state the release used, clock for clock, and the long route ends in a flag beside the chip's
        // pins instead of crossing the pin logic. (st_none, below, was already this form: f_none's copy.)
        reg r_wadv = 0, r_wlat = 0, r_wdst = 0, r_wend = 0, r_ccs = 0, r_cadv = 0, r_chold = 0, r_sce = 0, r_ssu = 0;
        reg r_data = 0, r_end = 0;
        always @(posedge clk) begin
            r_wadv <= sn == STATE_WRITE_ADV_END && on_n[c]; r_wlat <= sn == STATE_WRITE_ADDR_LATCH_END && on_n[c];
            r_wdst <= sn == STATE_WRITE_DATA_START && on_n[c]; r_wend <= sn == STATE_WRITE_DATA_END && on_n[c];
            r_ccs <= sn == STATE_CONFIG_CRE_SETUP; r_cadv <= sn == STATE_CONFIG_ADV_END; r_chold <= sn == STATE_CONFIG_HOLD_END;
            r_sce <= sn == STATE_SYNC_CE_SETUP; r_ssu <= sn == STATE_SYNC_SETUP;
            r_data <= sn == STATE_SYNC_DATA && dp_n[c]; r_end <= sn == STATE_SYNC_DATA && en_n[c];
        end
        wire f_none, f_data = r_data, f_end = r_end;
        wire nx_none = n_none || (n_wr && !on_n[c]) || (n_sdata && !dp_n[c] && !en_n[c]);
        wire [15:0] din = c == 0 ? data_in0 : data_in1;
        wire [15:0] dqi = c == 0 ? dq_r0 : dq_r1;
        wire [1:0] cbe = c == 0 ? be[1:0] : be[3:2];
        wire wen = write_en && we_c[c];
        reg [21:16] cram_a;
        reg adv_n = 1, cre = 0, ce0_n = 1, ce1_n = 1, oe_n = 1, we_n = 1, ub_n = 1, lb_n = 1, bsy = 0;
        reg data_out_en = 0;
        reg [15:0] cram_data;
        reg [15:0] dq_r2;
        reg read_avail_r = 0;
        reg [15:0] data_out_r;
        reg st_none = 1, st_wdata = 0, st_cfg = 0;
        assign f_none = st_none;
        // synthesis translate_off
        always @(posedge clk)
            if (f_none != (s_none || (s_wr && !on[c]) || (s_sdata && !dp[c] && !en[c])) || r_data != (s_sdata && dp[c]) ||
                r_end != (s_sdata && en[c]) || r_wadv != (s_wadv && on[c]) || r_wlat != (s_wlat && on[c]) ||
                r_wdst != (s_wdst && on[c]) || r_wend != (s_wend && on[c]) || r_ccs != s_ccs || r_cadv != s_cadv ||
                r_chold != s_chold || r_sce != s_sce || r_ssu != s_ssu)
                $display("nds_pq_psram2: ERROR: chip %0d's retimed pin decode differs from the state's at %0t", c, $time);
        // synthesis translate_on
        always @(posedge clk) dq_r2 <= dqi;
        always @(posedge clk) begin
            bsy <= !f_none;
            read_avail_r <= 0;
            // (psx_pq_psram's case on its state, in its order; the states are distinct values)
            if (f_none) begin
                    cram_a <= addr[21:16];
                    adv_n <= 1; cre <= 0; ce0_n <= 1; ce1_n <= 1; oe_n <= 1; we_n <= 1; ub_n <= 1; lb_n <= 1;
                    if (wen) begin
                        if (bank_sel) ce1_n <= 0; else ce0_n <= 0;
                        data_out_en <= 1;
                        we_n <= 0; adv_n <= 0;
                        if (cbe[1]) ub_n <= 0;
                        if (cbe[0]) lb_n <= 0;
                        bsy <= 1;
                    end else if (config_en) begin
                        cre <= 1; bsy <= 1;
                    end else if (sync_burst_en) begin
                        if (bank_sel) ce1_n <= 0; else ce0_n <= 0;
                        data_out_en <= 1;
                        ub_n <= 0; lb_n <= 0;
                        bsy <= 1;
                    end
            end else if (r_wadv) adv_n <= 1;
            else if (r_wlat) data_out_en <= 0;
            else if (r_wdst) data_out_en <= 1;
            else if (r_wend) begin
                    data_out_en <= 0; we_n <= 1; ce0_n <= 1; ce1_n <= 1; ub_n <= 1; lb_n <= 1; bsy <= 0;
            end else if (r_ccs) begin
                    if (bank_sel) ce1_n <= 0; else ce0_n <= 0;
                    cram_a <= {2'b00, 2'b10, 2'b00};       // A[19]: the BCR (64 Mbit die)
                    data_out_en <= 1; we_n <= 0; adv_n <= 0;
            end else if (r_cadv) adv_n <= 1;
            else if (r_chold) begin
                    data_out_en <= 0; we_n <= 1; cre <= 0; ce0_n <= 1; ce1_n <= 1; bsy <= 0;
            end else if (r_sce) adv_n <= 0;
            else if (r_ssu) begin adv_n <= 1; data_out_en <= 0; oe_n <= 0; end
            else if (f_data) begin if (!wait_r2[c]) begin read_avail_r <= 1; data_out_r <= dq_r2; end end
            else if (f_end) begin ce0_n <= 1; ce1_n <= 1; oe_n <= 1; ub_n <= 1; lb_n <= 1; bsy <= 0; end
            // (cram_data from flags registered with the next state, as psx_pq_psram's: its IOE timing)
            st_none  <= nx_none;
            st_wdata <= n_wdst && on_n[c];
            st_cfg   <= n_ccs;
            if (st_none) cram_data <= addr[15:0];
            else if (st_wdata) cram_data <= din;
            else if (st_cfg) cram_data <= config_data;
        end
        if (c == 0) begin : g_o0
            assign ca0 = cram_a; assign cd0 = cram_data; assign do0 = EARLY != 0 ? dq_r2 : data_out_r;
        end else begin : g_o1
            assign ca1 = cram_a; assign cd1 = cram_data; assign do1 = EARLY != 0 ? dq_r2 : data_out_r;
        end
        assign doe[c] = data_out_en;
        assign cram_adv_n[c] = adv_n; assign cram_cre[c] = cre; assign cram_ce0_n[c] = ce0_n; assign cram_ce1_n[c] = ce1_n;
        assign cram_oe_n[c] = oe_n; assign cram_we_n[c] = we_n; assign cram_ub_n[c] = ub_n; assign cram_lb_n[c] = lb_n;
        assign busy[c] = bsy;
        assign read_avail[c] = EARLY != 0 ? f_data && !wait_r2[c] : read_avail_r;
    end endgenerate
`undef PQ_CEIL
endmodule

// a PSRAM chip's DQ and WAIT input registers (psx_pq_psram's, by its names)
module nds_pq_cap (input wire clk, input wire [15:0] dq, input wire wt, output reg [15:0] cram_dq_r, output reg cram_wait_r);
    always @(posedge clk) begin cram_dq_r <= dq; cram_wait_r <= wt; end
endmodule
`default_nettype wire
