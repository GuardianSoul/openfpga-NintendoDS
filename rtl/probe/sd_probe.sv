// SPDX-License-Identifier: MIT
// APF data-slot read probe (docs/sd-probe.md). Issues target_dataslot_read
// (opcode 0x180) commands through the pinned core_bridge_cmd and times each
// one in clk cycles: to the host's "busy" acknowledge, to the first and last
// data word written into the bridge window, and to done. Records go to an
// on-chip log that the Pocket saves as a nonvolatile slot when the core quits.
//
// Version 2 also measures the Pocket's start-up load of the same slot: the
// slot is not deferred, so the Pocket writes the whole file to bridge
// LOAD_BASE.. before the core runs. The probe counts and sums those words and
// keeps the first and last write times, the largest gap between writes, and
// the gaps over 1 ms. The data itself is not stored.
//
// Everything runs on the bridge clock (clk_74a). Cases, in order:
//   0: 4 B random   1: 512 B random   2: 512 B sequential
//   3: 32 KiB random  4: 32 KiB sequential  5: 256 KiB random  6: 256 KiB sequential
// Random offsets are aligned to max(length, 512) and uniform over the whole
// file; a sequential case starts at a random aligned offset and wraps to 0.
//
// Log layout (32-bit words; the Pocket saves them big-endian and one word
// late, dropping the magic; decode.py realigns):
//   0 "SDPB"   1 {version 2, words per record 8, cases 16}   2 records written
//   3 ROM slot size in bytes   4 clock in Hz   5 {done, stuck seen, 2'b0,
//   fail code 4, 16'b0, current case 8}   6 records per case
//   7 run time in clocks / 256   8..14 case c: {seq, 2'b0, align log2 5, length 24}
//   15 random offset mask
//   start-up load (times in clocks since power-up, 48 bits as lo, hi words):
//   16 words written   17 their sum   18,19 first write   20,21 last write
//   22 largest gap between writes   23 words before that gap
//   24 gaps over 1 ms   25 clocks in those gaps / 256   26,27 slots complete
//   28 writes not at the previous address + 4   29 last write address
//   30 address window (LOAD_BASE)   31 GAP_LONG
//   32 + 8r: record r:
//     0 {4'hA, case 4, error 3, ack seen, timed out, 3'b0, index in case 16}
//     1 slot offset  2 clocks to the host's busy acknowledge (0: none seen)
//     3 clocks to the first window write  4 clocks to the last window write
//     5 clocks to done  6 window words written  7 sum of the written words
// Clocks count from the cycle target_read rises (t=0) and saturate at 2^32-1.
// Fail codes: 1 ROM slot not in the data table, 2 file under 512 KiB.
`default_nettype none
module sd_probe #(
    parameter integer N = 64,                   // records per case
    parameter [15:0] ROM_SLOT = 16'd1,        // nonzero: an empty table pair reads as ID 0
    parameter [31:0] WINDOW = 32'h3000_0000,    // bridge address the reads land at
    parameter [31:0] LOAD_BASE = 32'h0000_0000, // data.json address of the slot: 512 MiB window
    parameter [31:0] GAP_LONG = 32'd74_250,     // 1 ms
    parameter [31:0] CLOCK_HZ = 32'd74_250_000,
    parameter [31:0] START_DELAY = 32'd37_125_000,  // 0.5 s after allcomplete and Reset Exit
    parameter [31:0] TIMEOUT = 32'd148_500_000      // a command over 2 s shows "stuck"
) (
    input wire clk, reset,
    input wire start,                     // level: slots complete and core out of reset
    input wire slots_done,                // level: APF all slots complete
    // APF ID/size table, port A of core_bridge_cmd's mf_datatable
    output wire [9:0] dt_addr,
    output wire dt_wren,
    output wire [31:0] dt_data,
    input wire [31:0] dt_q,
    // core_bridge_cmd target command
    output reg tgt_read = 0,
    output wire [15:0] tgt_id,
    output reg [31:0] tgt_offset = 0,
    output wire [31:0] tgt_bridge,
    output wire [31:0] tgt_length,
    input wire tgt_ack, tgt_done,
    input wire [2:0] tgt_err,
    // bridge writes (data arriving in the window)
    input wire bridge_wr,
    input wire [31:0] bridge_addr, bridge_wr_data,
    // log readout, one clock of latency
    input wire [14:0] read_index,
    output reg [31:0] read_data,
    // status for the screen
    output reg [1:0] state_out = 0,       // 0 waiting, 1 running, 2 done, 3 failed
    output wire [13:0] case_state,        // 2 bits per case: 0 pending, 1 running, 2 ok, 3 error
    output reg stuck = 0,                 // some command ran past TIMEOUT
    output wire [1:0] load_state,         // 0 nothing yet, 1 loading, 2 loaded (slots complete), 3 none arrived
    output reg [15:0] records = 0
);
    localparam integer NCASE = 7;
    localparam integer REC_WORDS = 8;
    localparam integer HDR = 32;
    localparam integer LOG_WORDS = HDR + REC_WORDS*NCASE*N;
    // Saved size: four spare words, so the Pocket's one-word read lag drops none of the log.
    localparam [31:0] SAVE_BYTES = (LOG_WORDS + 4)*4;
    localparam [9:0] SAVE_SIZE_ENTRY = 10'd3;   // data.json slot 1's size word (pairs of id, size)

    // case table
    function automatic [23:0] case_len(input [2:0] c);
        case (c)
            3'd0: case_len = 24'd4;
            3'd1, 3'd2: case_len = 24'd512;
            3'd3, 3'd4: case_len = 24'd32768;
            default: case_len = 24'd262144;
        endcase
    endfunction
    function automatic [4:0] case_align(input [2:0] c);
        case (c)
            3'd0, 3'd1, 3'd2: case_align = 5'd9;
            3'd3, 3'd4: case_align = 5'd15;
            default: case_align = 5'd18;
        endcase
    endfunction
    function automatic case_seq(input [2:0] c);
        case_seq = c==3'd2 || c==3'd4 || c==3'd6;
    endfunction

    (* ramstyle = "M10K" *) reg [31:0] log_ram[0:LOG_WORDS-HDR-1];

    localparam [3:0] S_IDLE=0, S_DELAY=1, S_LOOK=2, S_MASK=3, S_CASE=4, S_PICK=5,
                     S_ISSUE=6, S_WRITE=7, S_DONE=8, S_FAIL=9;
    reg [3:0] st = S_IDLE;
    reg [31:0] delay = 0;
    reg [4:0] entry = 0;          // data-table pair being looked up
    reg [1:0] look_wait = 0;
    reg look_size = 0;            // reading the size word of the matching pair
    reg [31:0] rom_size = 0, mask = 0;
    reg [3:0] fail = 0;
    reg [2:0] cs = 0;             // current case
    reg [15:0] idx = 0;           // record index within the case
    reg [31:0] lfsr = 32'h2545_F491;
    reg [31:0] seq_off = 0;
    reg seq_started = 0;
    reg [13:0] cstate = 0;
    reg [39:0] run_clocks = 0;
    reg run_on = 0;

    // per-command measurement
    reg [31:0] t = 0, t_ack = 0, t_first = 0, t_last = 0, t_done = 0, words = 0, sum = 0;
    reg ack_seen = 0, ack_prev = 0, low_seen = 0, timed_out = 0;
    reg [2:0] err = 0;
    reg [2:0] wphase = 0;
    reg [14:0] waddr = 0;

    wire [23:0] len = case_len(cs);
    wire [4:0] align = case_align(cs);
    wire [31:0] align_mask = ~((32'd1 << align) - 1);
    wire [31:0] rnd_off = lfsr & mask & align_mask;
    wire [31:0] lfsr_next0 = lfsr ^ (lfsr << 13);
    wire [31:0] lfsr_next1 = lfsr_next0 ^ (lfsr_next0 >> 17);
    wire [31:0] lfsr_next = lfsr_next1 ^ (lfsr_next1 << 5);
    wire in_window = bridge_addr[31:18] == WINDOW[31:18];

    assign tgt_id = ROM_SLOT;
    assign tgt_bridge = WINDOW;
    assign tgt_length = {8'b0, len};
    assign case_state = cstate;
    assign dt_addr = st == S_LOOK ? {4'b0, entry, look_size} : SAVE_SIZE_ENTRY;
    assign dt_wren = st != S_LOOK;
    assign dt_data = SAVE_BYTES;

    always @(posedge clk) begin
        ack_prev <= tgt_ack;
        if (run_on && run_clocks != {40{1'b1}}) run_clocks <= run_clocks + 1'b1;
        if (reset) begin
            st <= S_IDLE; tgt_read <= 0; state_out <= 0; stuck <= 0; records <= 0;
            cstate <= 0; fail <= 0; run_on <= 0; run_clocks <= 0; lfsr <= 32'h2545_F491;
        end else case (st)
            S_IDLE: if (start) begin delay <= 0; st <= S_DELAY; end
            S_DELAY: if (!start) st <= S_IDLE;
                else if (delay == START_DELAY) begin
                    entry <= 0; look_size <= 0; look_wait <= 0; st <= S_LOOK;
                end else delay <= delay + 1'b1;
            // Table positions are not IDs: search the 32 pairs for ROM_SLOT.
            // The table RAM answers within two clocks; wait three.
            S_LOOK: if (look_wait != 2'd3) look_wait <= look_wait + 1'b1;
                else begin
                    look_wait <= 0;
                    if (!look_size) begin
                        if (dt_q == {16'b0, ROM_SLOT}) look_size <= 1;
                        else if (entry == 5'd31) begin fail <= 4'd1; st <= S_FAIL; end
                        else entry <= entry + 1'b1;
                    end else begin
                        rom_size <= dt_q;
                        mask <= 0;
                        if (dt_q < 32'h0008_0000) begin fail <= 4'd2; st <= S_FAIL; end
                        else st <= S_MASK;
                    end
                end
            // smallest 2^k-1 covering every offset below the size
            S_MASK: if (mask < rom_size - 1'b1) mask <= {mask[30:0], 1'b1};
                else begin cs <= 0; st <= S_CASE; state_out <= 2'd1; run_on <= 1; end
            S_CASE: begin
                idx <= 0; seq_started <= 0;
                cstate[2*cs +: 2] <= 2'd1;
                st <= S_PICK;
            end
            S_PICK: begin
                lfsr <= lfsr_next;
                if (case_seq(cs) && seq_started) begin
                    if (seq_off + len > rom_size) begin tgt_offset <= 0; seq_off <= len; end
                    else begin tgt_offset <= seq_off; seq_off <= seq_off + len; end
                    st <= S_ISSUE;
                end else if (rnd_off + len <= rom_size) begin
                    tgt_offset <= rnd_off; seq_off <= rnd_off + len; seq_started <= 1;
                    st <= S_ISSUE;
                end
                t <= 0; t_ack <= 0; t_first <= 0; t_last <= 0; words <= 0; sum <= 0;
                ack_seen <= 0; low_seen <= 0; timed_out <= 0;
                tgt_read <= case_seq(cs) && seq_started || rnd_off + len <= rom_size;
            end
            // core_bridge_cmd queues the rising edge. Its done output still
            // shows the previous command until it starts this one, so done
            // counts only after it has been seen low.
            S_ISSUE: begin
                if (t != 32'hFFFF_FFFF) t <= t + 1'b1;
                if (t == TIMEOUT) begin timed_out <= 1; stuck <= 1; end
                if (!tgt_done) begin low_seen <= 1; tgt_read <= 0; end
                if (tgt_ack && !ack_prev && !ack_seen) begin ack_seen <= 1; t_ack <= t; end
                if (bridge_wr && in_window) begin
                    if (words == 0) t_first <= t;
                    t_last <= t;
                    words <= words + 1'b1;
                    sum <= sum + bridge_wr_data;
                end
                if (low_seen && tgt_done) begin
                    err <= tgt_err; t_done <= t; wphase <= 0;
                    waddr <= records * REC_WORDS;
                    st <= S_WRITE;
                end
            end
            S_WRITE: begin
                wphase <= wphase + 1'b1;
                waddr <= waddr + 1'b1;
                if (wphase == 3'd7) begin
                    records <= records + 1'b1;
                    if (err != 0) cstate[2*cs +: 2] <= 2'd3;
                    if (idx == N-1) begin
                        if (cstate[2*cs +: 2] != 2'd3 && err == 0) cstate[2*cs +: 2] <= 2'd2;
                        if (cs == NCASE-1) begin st <= S_DONE; state_out <= 2'd2; run_on <= 0; end
                        else begin cs <= cs + 1'b1; st <= S_CASE; end
                    end else begin
                        idx <= idx + 1'b1; st <= S_PICK;
                    end
                end
            end
            S_FAIL: state_out <= 2'd3;
            default: ;
        endcase
    end

    reg [31:0] rec_word;
    always @* case (wphase)
        3'd0: rec_word = {4'hA, 1'b0, cs, err, ack_seen, timed_out, 3'b0, idx};
        3'd1: rec_word = tgt_offset;
        3'd2: rec_word = t_ack;
        3'd3: rec_word = t_first;
        3'd4: rec_word = t_last;
        3'd5: rec_word = t_done;
        3'd6: rec_word = words;
        default: rec_word = sum;
    endcase
    always @(posedge clk) if (st == S_WRITE) log_ram[waddr] <= rec_word;

    // ---- start-up load
    reg [47:0] now = 0, l_first = 0, l_last = 0, l_prev = 0, l_done = 0;
    reg [31:0] l_words = 0, l_sum = 0, l_gap = 0, l_gap_at = 0, l_long = 0;
    reg [39:0] l_long_clocks = 0;   // stored / 256: a slow load can gap for over 57 s in all
    reg [31:0] l_jumps = 0, l_addr = 0;
    reg l_seen = 0, l_closed = 0;
    wire in_load = bridge_addr[31:29] == LOAD_BASE[31:29];
    wire [47:0] gap48 = now - l_prev;
    wire [31:0] gap = gap48[47:32] != 0 ? 32'hFFFF_FFFF : gap48[31:0];
    always @(posedge clk) begin
        if (reset) begin
            now <= 0; l_words <= 0; l_sum <= 0; l_gap <= 0; l_gap_at <= 0; l_long <= 0;
            l_long_clocks <= 0; l_jumps <= 0; l_seen <= 0; l_closed <= 0; l_done <= 0;
        end else begin
            now <= now + 1'b1;
            if (slots_done && !l_closed) begin l_closed <= 1; l_done <= now; end
            if (bridge_wr && in_load && !l_closed) begin
                l_seen <= 1;
                if (!l_seen) l_first <= now;
                else begin
                    if (gap > l_gap) begin l_gap <= gap; l_gap_at <= l_words; end
                    if (gap >= GAP_LONG) begin l_long <= l_long + 1'b1; l_long_clocks <= l_long_clocks + gap; end
                    if (bridge_addr != l_addr + 3'd4) l_jumps <= l_jumps + 1'b1;
                end
                l_last <= now; l_prev <= now; l_addr <= bridge_addr;
                l_words <= l_words + 1'b1;
                l_sum <= l_sum + bridge_wr_data;
            end
        end
    end
    assign load_state = !l_seen ? (l_closed ? 2'd3 : 2'd0) : l_closed ? 2'd2 : 2'd1;

    // readout
    reg [31:0] q = 0, hword = 0, lword = 0;
    reg lsel = 0;
    reg header = 0;
    wire [14:0] ram_index = read_index - HDR;
    always @(posedge clk) begin
        q <= log_ram[ram_index];
        header <= read_index < HDR;
        lsel <= read_index[4];
        case (read_index[3:0])
            4'd0: lword <= l_words;
            4'd1: lword <= l_sum;
            4'd2: lword <= l_first[31:0];
            4'd3: lword <= {16'b0, l_first[47:32]};
            4'd4: lword <= l_last[31:0];
            4'd5: lword <= {16'b0, l_last[47:32]};
            4'd6: lword <= l_gap;
            4'd7: lword <= l_gap_at;
            4'd8: lword <= l_long;
            4'd9: lword <= l_long_clocks[39:8];
            4'd10: lword <= l_done[31:0];
            4'd11: lword <= {16'b0, l_done[47:32]};
            4'd12: lword <= l_jumps;
            4'd13: lword <= l_addr;
            4'd14: lword <= LOAD_BASE;
            default: lword <= GAP_LONG;
        endcase
        case (read_index[3:0])
            4'd0: hword <= 32'h5344_5042;
            4'd1: hword <= {8'd2, 8'd8, 16'd7};
            4'd2: hword <= {16'b0, records};
            4'd3: hword <= rom_size;
            4'd4: hword <= CLOCK_HZ;
            4'd5: hword <= {st == S_DONE, stuck, 2'b0, fail, 16'b0, 5'b0, cs};
            4'd6: hword <= N;
            4'd7: hword <= run_clocks[39:8];
            4'd15: hword <= mask;
            // 8..14: case read_index-8
            default: hword <= {case_seq(read_index[2:0]), 2'b0, case_align(read_index[2:0]), case_len(read_index[2:0])};
        endcase
    end
    always @* read_data = !header ? q : lsel ? lword : hword;
endmodule
`default_nettype wire
