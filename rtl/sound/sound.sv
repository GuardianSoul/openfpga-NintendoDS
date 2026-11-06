// Nintendo DS sound: 16 channels and two capture units, processed one after
// another with all per-channel state in block RAM (docs/sound.md).
//
// Behaviour follows melonDS's SPU (references/melonDS/src/SPU.cpp), which is
// the golden model: once per output step (tick, 32,768 Hz) every channel
// timer advances by 512, each overflow produces one sample, and the step's
// output is the current samples mixed. Register write semantics follow
// melonDS's SPU::Write8/16/32, quirks included.
//
// Per step: for each entry (channels 0-15, then captures 0-1) load its eight
// state words into one working set (w0-w3 register words, w4-w7 run-time
// words: one row of each of two RAMs), run its timer and sample loop, store
// w4-w7 back in one write, and mix. The entry boundaries are where ARM7 register accesses are
// served. The design clock is the 33.51 MHz system clock with tick every
// 1,024 clocks; a typical step uses ~400 of them.
//
// Sample data: each channel has an 8-word FIFO (melonDS's own FIFO size) in
// one RAM. Refills go through a request queue to the memory port, so memory
// latency overlaps everything else; each FIFO word carries a 2-bit lap tag
// (in its own small RAM), and the engine waits only if the word it needs has
// not arrived. Starting a channel moves it to a new lap and retags its eight
// words as the old lap, so stale words can never look current.
//
// A capture unit runs on the channel datapath: its position, end test, word
// offset and address use the channel's position adder, end comparator and
// refill address logic, with the unit as a looping PCM8/PCM16 "channel".
//
// Area: each working-set field is written in one place, from a small encoded
// choice of sources, so Quartus builds one narrow mux per field instead of
// one input per assignment.

module sound #(
    // 1: rst also clears the register words (SAD, TMR, PNT, LEN and
    // SOUNDxCNT's low bits), as melonDS's Reset does. 0: they start at 0 from
    // configuration (the RAM's initial contents) and keep their values over
    // a later rst; busy and start still reset, so no channel plays until
    // SOUNDxCNT is written. About 30 ALUTs.
    parameter bit CLEAR_REGS = 1'b0,
    // 0: TEMPORARY for the test build's room (docs/ds-rules.md): no capture units and no output
    // select. SNDCAPxCNT reads back with the start bit clear and nothing is written to memory.
    parameter bit CAPTURE = 1'b1
) (
    input  logic        clk,
    input  logic        ce,             // clock enable: the engine steps on clk edges with ce high
    input  logic        rst,
    input  logic        tick,           // one pulse per output step
    input  logic        power,          // POWCNT2 bit 0: 0 mutes the output
    // ARM7 registers 0x04000400-0x0400051F; size 0/1/2 = 8/16/32 bits.
    // Write data sits in its byte lanes; reads return the aligned word.
    input  logic        reg_req,
    input  logic        reg_we,
    input  logic [1:0]  reg_size,
    input  logic [8:0]  reg_addr,
    input  logic [31:0] reg_wdata,
    output logic        reg_ack,
    output logic [31:0] reg_rdata,      // valid with reg_ack
    // memory: word addresses; reads answer in order on mem_rvalid
    output logic        mem_req,
    output logic        mem_we,
    output logic [24:0] mem_addr,
    output logic [31:0] mem_wdata,
    input  logic        mem_ack,
    input  logic        mem_rvalid,
    input  logic [31:0] mem_rdata,
    // output, one pair per step: melonDS's 16-bit value and the 10-bit DAC value
    output logic        out_valid,
    output wire         out_pre,        // the clock before out_l, then out_r, take this step's values
    output logic [15:0] out_l,
    output logic [15:0] out_r,
    output logic [9:0]  dac_l,
    output logic [9:0]  dac_r,
    output logic        overrun,        // a step started late (sticky)
    output logic        late            // pulse: this step starts before the last one finished
);
    // ------------------------------------------------------------ state words
    // Channel entry: w0 SOUNDxCNT (busy and start are flops), w1 source word
    // address, w2 {loop start, timer reload}, w3 length, w4 {loop index,
    // sample, timer}, w5 {timer bit 16, write lap, read lap, FIFO write
    // word, FIFO read byte, position in nibbles} (melonDS can leave the timer
    // at >= 0x10000 when a channel stops), w6 {ADPCM byte, FIFO level, fetch
    // word offset}, w7 {loop value, index, ADPCM value or noise LFSR}.
    // The ADPCM loop state (loop index, loop value) lives only in the RAM
    // row: written through its own byte lanes, read from the row as stored.
    // Capture entry: w1 destination, w2 timer reload, w3 length, w4 timer,
    // w5 position in nibbles, w6 write word offset.
    // Samples go straight into their byte lanes of the unit's 4-word buffer
    // (sound_capbuf);
    // words are written out four at a time, or at the end of the buffer, as
    // melonDS's capture FIFO does, and restarting a unit drops them, as in
    // melonDS. The buffer slot and the byte in the word follow from the
    // position.
    logic [31:0] w0, w1, w2, w3;
    logic [39:0] w4, w5, w6, w7;
    logic [4:0]  ent;                   // the entry: 0-15 channels, 16-17 captures
    logic [159:0] rr_q;                 // the entry's run-time row as stored

    logic [6:0]  f_vol;   assign f_vol  = w0[6:0];
    logic [1:0]  f_div;   assign f_div  = w0[9:8];
    logic [6:0]  f_pan;   assign f_pan  = w0[22:16];
    logic [2:0]  f_duty;  assign f_duty = w0[26:24];
    logic [1:0]  f_rep;   assign f_rep  = w0[28:27];
    logic [1:0]  f_fmt;   assign f_fmt  = w0[30:29];
    logic [24:0] f_sad;   assign f_sad  = w1[26:2];
    logic [15:0] f_tmr;   assign f_tmr  = w2[15:0];
    logic [15:0] f_pnt;   assign f_pnt  = w2[31:16];
    logic [20:0] f_len;   assign f_len  = w3[20:0];
    logic        f_t17;   assign f_t17  = w5[38];
    logic [15:0] f_timer; assign f_timer = w4[15:0];
    logic [15:0] f_cs;    assign f_cs   = w4[31:16];
    logic [6:0]  f_idxl;  assign f_idxl = rr_q[38:32];     // the row's w4[38:32]
    logic [25:0] f_pos;   assign f_pos  = w5[25:0];
    logic [4:0]  f_rp;    assign f_rp   = w5[30:26];
    logic [2:0]  f_wp;    assign f_wp   = w5[33:31];
    logic [1:0]  f_rlap;  assign f_rlap = w5[35:34];
    logic [1:0]  f_wlap;  assign f_wlap = w5[37:36];
    logic [21:0] f_roff;  assign f_roff = w6[21:0];
    logic [6:0]  f_level; assign f_level = w6[28:22];
    logic [7:0]  f_byte;  assign f_byte = w6[36:29];
    logic [15:0] f_val;   assign f_val  = w7[15:0];
    logic [6:0]  f_idx;   assign f_idx  = w7[22:16];
    logic [15:0] f_vall;  assign f_vall = rr_q[159:144];   // the row's w7[39:24]

    // ------------------------------------------------------------ global registers
    logic [15:0] soundcnt /*verilator public_flat_rw*/;
    logic [9:0]  bias /*verilator public_flat_rw*/;
    logic [7:0]  capcnt0 /*verilator public_flat_rw*/;
    logic [7:0]  capcnt1 /*verilator public_flat_rw*/;
    logic [1:0]  cap_start;             // capture started; reset at its next run
    logic [15:0] busy /*verilator public_flat_rw*/;    // SOUNDxCNT bit 31
    logic [15:0] keyon /*verilator public_flat_rw*/;   // busy went 0 -> 1: start at the next run

    // ------------------------------------------------------------ RAMs
    // the register words, {word, entry}: one M10K (S_LOAD reads an entry's
    // four words in four clocks)
    logic         cr_we;
    logic [3:0]   cr_be;                // byte lanes
    logic [6:0]   cr_wa, cr_ra;
    logic [31:0]  cr_wd, cr_q;
    sound_cpu_ram #(.AW(7)) u_cpu (.clk, .ce, .we(cr_we), .be(cr_be), .wa(cr_wa), .wd(cr_wd), .ra(cr_ra), .q(cr_q));
    logic         rr_we;
    logic [19:0]  rr_be;
    logic [159:0] rr_wd;
    sound_run_ram u_run (.clk, .ce, .we(rr_we), .be(rr_be), .wa(ent), .wd(rr_wd), .ra(ent), .q(rr_q));
    logic         cb_we;
    logic [3:0]   cb_be;
    logic [2:0]   cb_wa, cb_ra;
    logic [31:0]  cb_wd, cb_q;
    generate if (CAPTURE) begin : g_cb
        sound_capbuf u_cb (.clk, .ce, .we(cb_we), .be(cb_be), .wa(cb_wa), .wd(cb_wd), .ra(cb_ra), .q(cb_q));
    end else begin : g_nocb
        assign cb_q = 32'd0;
    end endgenerate

    // ADPCM {next index, difference}: the step from the FIFO RAM's upper half,
    // read in the cycle S_ITB completes a decode (the FIFO word is not needed
    // after it), with the address registered beside it
    logic [9:0]  rom_ra, rom_ra_q;
    logic [22:0] rom_q;

    logic        ff_we;
    logic [6:0]  ff_wa;
    logic [7:0]  ff_ra;
    logic [31:0] ff_wd, ff_q;
    sound_ram #(.AW(8), .DW(32), .ADPCM(1)) u_fifo (.clk, .ce, .we(ff_we), .wa({1'b0, ff_wa}), .wd(ff_wd), .ra(ff_ra), .q(ff_q));
    always_ff @(posedge clk) if (ce) rom_ra_q <= rom_ra;
    sound_adpcm_step u_adp (.step(ff_q[14:0]), .ra(rom_ra_q), .q(rom_q));
    logic        tg_we;
    logic [6:0]  tg_wa;
    logic [1:0]  tg_wd, tg_q;
    sound_mlab #(.AW(7), .DW(2), .STYLE("M10K")) u_tag (.clk, .ce, .we(tg_we), .wa(tg_wa), .wd(tg_wd), .ra(ff_ra[6:0]), .q(tg_q));

    // Fetch request queue: {capture write, data, channel, word address, zero,
    // words, FIFO word, lap}. Capture words are one-word write entries.
    localparam int QW = (CAPTURE ? 1 + 32 : 0) + 4 + 25 + 1 + 3 + 3 + 2;
    logic          q_we;
    logic [3:0]    q_wa, q_ra;
    logic [QW-1:0] q_wd, q_q;
    sound_ram #(.AW(4), .DW(QW)) u_queue (.clk, .ce, .we(q_we), .wa(q_wa), .wd(q_wd), .ra(q_ra), .q(q_q));
    logic [4:0]    q_cnt;
    logic          q_pop;

    // ------------------------------------------------------------ engine control
    typedef enum logic [4:0] {
        S_CLEAR, S_IDLE, S_BOUND, S_REG, S_REG2, S_LOAD, S_CH, S_RETAG, S_FILL,
        S_ITA, S_ITB, S_ITC, S_CAP, S_CAPA, S_CFL, S_STORE, S_MIX, S_OUT
    } state_t;
    state_t      st /*verilator public_flat_rd*/;
    logic [3:0]  cnt;                   // load/store/mix/output step
    logic [7:0]  clr;
    logic        tick_pend;
    logic        win;                   // a step is being processed
    logic        reg_ret;               // register access came from S_BOUND
    logic [2:0]  cfl_k, cfl_n;          // capture flush: next and number of words
    logic        cfl_rdy;               // cb_q holds buffered word cfl_k
    logic        cap_wrap;              // flush ends at the end of the buffer
    logic [1:0]  fills;                 // start-up refills left
    logic        dec_fill;              // refill after the ADPCM decode step
    logic        adp_upd;               // the ADPCM value changed: the next S_ITA copies it to the sample
    logic [2:0]  act;
    logic signed [27:0] accl, accr;     // mixer
    logic        selpass;               // output select: channels 1 and 3 mixed again

    localparam logic [2:0] A_NONE = 3'd0, A_READ8 = 3'd1, A_READ16 = 3'd2, A_HDR = 3'd3,
                           A_LOOP = 3'd4, A_DECRD = 3'd5, A_DECSH = 3'd6, A_HOLD = 3'd7;

    wire        e4 = CAPTURE && ent[4];         // a capture unit's entry
    logic       e_busy, e_keyon;
    assign e_busy = busy[ent[3:0]];
    assign e_keyon = keyon[ent[3:0]];
    logic       noise_ch;               // channels 14-15 play noise as format 3
    assign noise_ch = ent[3:1] == 3'b111;

    logic [7:0]  ccnt;                  // the capture unit's SNDCAPxCNT
    assign ccnt = ent[0] ? capcnt1 : capcnt0;
    // a capture unit is a looping PCM8 (8-bit) or PCM16 (16-bit) channel
    logic [1:0]  e_fmt, e_rep;
    assign e_fmt = e4 ? {1'b0, !ccnt[3]} : f_fmt;
    assign e_rep = e4 ? 2'b01 : f_rep;

    // Multipliers: vp = volume x pan (mix steps 0 and 2, its own DSP
    // half), and the shared one for sample x vp (steps 1 and 3) and the
    // master volume (S_OUT); both registered.
    logic        [7:0]  vp_b;
    (* multstyle = "dsp" *) logic [19:0] vp;
    logic signed [27:0] mul_a;
    logic signed [19:0] mul_b;
    logic signed [47:0] mul_p;
    always_ff @(posedge clk) if (ce) mul_p <= mul_a * mul_b;

    // ------------------------------------------------------------ datapath
    logic [7:0]  vol8, pan8;
    assign vol8 = (f_vol == 7'd127) ? 8'd128 : {1'b0, f_vol};
    assign pan8 = (f_pan == 7'd127) ? 8'd128 : {1'b0, f_pan};
    logic [11:0] vs;                    // volume << shift
    always_comb case (f_div)
        2'd0: vs = {vol8, 4'd0};
        2'd1: vs = {1'b0, vol8, 3'd0};
        2'd2: vs = {2'b0, vol8, 2'd0};
        default: vs = {4'b0, vol8};
    endcase

    // loop start + length, words (a capture length 0 is one word): added at
    // the load from the RAM words, so the refill's address and burst
    // (tot - roff, then sad + roff) don't wait for this carry chain too
    logic [21:0] tot;
    logic        short;                 // under 16 bytes: melonDS's Run plays nothing
    assign short = f_pnt[15:2] == 14'd0 && f_len[20:2] == 19'd0 && {1'b0, f_pnt[1:0]} + {1'b0, f_len[1:0]} < 3'd4;
    logic        inactive;              // S_CH: the channel outputs 0 and keeps its state
    assign inactive = !e_busy || (f_fmt == 2'd3 && !ent[3]) || (f_fmt != 2'd3 && short);

    // Positions count nibbles in every format (a sample is 2 for PCM8, 4 for
    // PCM16, 1 for ADPCM and PSG), so the end and the loop start are the
    // same shift of the word counts for all of them.
    logic [2:0]  pinc;
    assign pinc = (e_fmt == 2'd0) ? 3'd2 : (e_fmt == 2'd1) ? 3'd4 : 3'd1;
    logic [25:0] posn;
    assign posn = f_pos + {23'b0, pinc};
    logic [25:0] lim, lstart;
    assign lim = {1'b0, tot, 3'b0};
    assign lstart = {7'b0, f_pnt, 3'b0};
    logic past_end;
    assign past_end = !posn[25] && (posn >= lim);
    logic sat;                          // position stops counting near the top
    assign sat = (f_pos[25:24] == 2'b01) && f_pos[23:2] == 22'h3FFFFF;
    logic psg_hi;
    assign psg_hi = (f_duty != 3'd7) && ({1'b0, posn[2:0]} + {1'b0, f_duty} >= 4'd7);

    // S_ITA decisions for formats 0-2 (melonDS NextSample_*)
    logic        it_pre;                // still in the start delay (ADPCM: or the header)
    assign it_pre = posn[25] || (f_fmt == 2'd2 && posn < 26'd8);
    logic        it_stop;               // one-shot end
    assign it_stop = past_end && !f_rep[0] && f_rep[1];
    logic        it_loop;
    assign it_loop = past_end && f_rep[0];
    logic [2:0]  it_act;
    always_comb begin
        if (f_fmt == 2'd2) begin
            if (it_pre) it_act = (posn == 26'd0) ? A_HDR : A_NONE;
            else if (past_end) it_act = f_rep[0] ? A_LOOP : A_HOLD;   // (a stop leaves S_ITA)
            else it_act = posn[0] ? A_DECSH : A_DECRD;
        end else it_act = posn[25] ? A_NONE : f_fmt[0] ? A_READ16 : A_READ8;
    end

    // Timer: +512 per step (S_CH, S_CAP), reload + timer - 0x10000 per sample
    logic        tm_tmr;                // start: reload + 512
    assign tm_tmr = (st == S_CH && e_keyon) || (CAPTURE && st == S_CAP && cap_start[ent[0]]);
    logic        tm_reload;
    assign tm_reload = (st == S_ITA) || (CAPTURE && st == S_CAPA);
    logic [16:0] tm_sum;
    logic [17:0] tm_s;                  // in a DSP block (nds_dsp_add): the chip is short of LABs
    nds_dsp_add #(.W(17)) u_tma (.clk, .a({f_t17 && !tm_reload && !tm_tmr, tm_tmr ? f_tmr : f_timer}),
        .b(tm_reload ? {1'b0, f_tmr} : 17'd512), .s(tm_s));
    assign tm_sum = tm_s[16:0];

    // FIFO data for the read at f_rp
    logic [7:0]  fbyte;
    always_comb case (f_rp[1:0])
        2'd0: fbyte = ff_q[7:0];
        2'd1: fbyte = ff_q[15:8];
        2'd2: fbyte = ff_q[23:16];
        default: fbyte = ff_q[31:24];
    endcase
    logic [15:0] fpcm;                  // the PCM8/PCM16 sample read
    assign fpcm = f_fmt[0] ? (f_rp[1] ? ff_q[31:16] : ff_q[15:0]) : {fbyte, 8'd0};
    logic [6:0]  hdr_idx;
    assign hdr_idx = (ff_q[22:16] > 7'd88) ? 7'd88 : ff_q[22:16];

    // IMA-ADPCM: the nibble is chosen in S_ITB (ROM address), decoded in
    // S_ITC from the ROM's difference and the stored ADPCM byte's low nibble
    logic [3:0]  nib_b;
    assign nib_b = (act == A_DECSH) ? f_byte[7:4] : fbyte[3:0];
    assign rom_ra = {f_idx, nib_b[2:0]};
    logic [3:0]  nib;
    assign nib = f_byte[3:0];
    // f_val -/+ the ROM's difference as one sum: the difference's four
    // step terms (u_adp's, gated with its index check: both from the
    // registered address) each inverted for a subtraction, plus 4 (the four
    // +1s of -(a+b+c+d) = ~a+~b+~c+~d+4): one adder tree from the FIFO RAM's
    // word to w7 instead of the difference's and then the add/subtract
    // (#842: u_fifo -> w7[12] -0.684 ns)
    logic        d_ok;
    assign d_ok = rom_ra_q[9:3] <= 7'd88;
    logic [17:0] dt0, dt1, dt2, dt3;
    assign dt0 = {18{nib[3]}} ^ (d_ok                ? {6'd0, ff_q[14:3]} : 18'd0);
    assign dt1 = {18{nib[3]}} ^ (d_ok && rom_ra_q[0] ? {5'd0, ff_q[14:2]} : 18'd0);
    assign dt2 = {18{nib[3]}} ^ (d_ok && rom_ra_q[1] ? {4'd0, ff_q[14:1]} : 18'd0);
    assign dt3 = {18{nib[3]}} ^ (d_ok && rom_ra_q[2] ? {3'd0, ff_q[14:0]} : 18'd0);
    logic signed [17:0] vsum;
    assign vsum = {{2{f_val[15]}}, f_val} + dt0 + dt1 + dt2 + dt3 + {15'd0, nib[3], 2'b00};
`ifndef ALTERA_RESERVED_QIS
    always @(posedge clk)
        if (!rst && st == S_ITC && vsum !== (nib[3] ? $signed({{2{f_val[15]}}, f_val}) - $signed({2'b0, rom_q[15:0]})
                                                    : $signed({{2{f_val[15]}}, f_val}) + $signed({2'b0, rom_q[15:0]})))
            $display("sound: ERROR: the folded ADPCM sum differs from f_val -/+ the ROM's difference");
`endif
    logic [15:0] vnew;
    // clamp to +-0x7FFF (melonDS): overflow and sign, one function per bit
    logic        v_ovf;
    assign v_ovf = vsum[17] ? (vsum[16:15] != 2'b11 || vsum[14:0] == 15'd0) : (vsum[16:15] != 2'b00);
    assign vnew = v_ovf ? {vsum[17], {14{!vsum[17]}}, 1'b1} : vsum[15:0];
    logic [6:0] inew;
    assign inew = rom_q[22:16];
    logic at_loop;                      // position is the loop start nibble
    assign at_loop = (f_pos == lstart);

    logic [2:0]  rsize;                 // bytes consumed by the read
    always_comb case (act)
        A_READ16: rsize = 3'd2;
        A_HDR:    rsize = 3'd4;
        A_DECSH, A_HOLD, A_NONE: rsize = 3'd0;
        default:  rsize = 3'd1;
    endcase
    logic [5:0]  rp_sum;
    assign rp_sum = {1'b0, f_rp} + {3'b0, rsize};
    logic signed [7:0] lev_sub;
    assign lev_sub = $signed({f_level[6], f_level}) - $signed({5'b0, rsize});
    logic [6:0]  lev_new;
    assign lev_new = (lev_sub < -8'sd32) ? 7'h60 : lev_sub[6:0];
    logic need_fill;                    // melonDS refills when 0 <= level <= 16
    assign need_fill = !lev_sub[7] && (lev_sub <= 8'sd16) && rsize != 3'd0;
    // A read that takes the level below zero (manual repeat past the end,
    // where melonDS no longer refills) uses whatever the FIFO holds. A word
    // written in the cycle it is read shows its old tag (the FIFO and tag
    // RAMs read old data, Quartus OLD_DATA), so the engine waits a cycle.
    logic data_ok;
    assign data_ok = (tg_q == f_rlap) || lev_sub[7];
    logic itb_go;                       // S_ITB completes this cycle
    assign itb_go = (st == S_ITB) && (act == A_NONE || act == A_DECSH || act == A_HOLD || data_ok);

    // ---- refill (melonDS FIFO_BufferData); also a capture unit's write
    // address and word offset (loop start 0, one word)
    logic [22:0] rdiff;                 // tot - roff; bit 22 = borrow
    assign rdiff = {1'b0, tot} - {1'b0, f_roff};
    logic        roff_end;
    assign roff_end = rdiff[22] || rdiff[21:0] == 22'd0;
    logic [21:0] roff_e;
    assign roff_e = (roff_end && e_rep[0]) ? {6'b0, f_pnt} : f_roff;
    logic        fill_skip;
    assign fill_skip = roff_end && !e_rep[0] && e_rep[1];
    logic [22:0] remain;                // tot - roff_e: after a loop back, the length
    assign remain = (roff_end && e_rep[0]) ? {2'b0, f_len} : rdiff;
    logic [2:0]  burst;
    assign burst = e4 ? 3'd1 : (fill_skip || remain[22]) ? 3'd0 :
                   (remain[21:2] == 20'd0) ? {1'b0, remain[1:0]} : 3'd4;
    logic [25:0] faddr;
    assign faddr = {1'b0, f_sad} + {4'b0, roff_e};
    logic [3:0]  wp_sum;
    assign wp_sum = {1'b0, f_wp} + {1'b0, burst};
    logic        fill_go;               // S_FILL commits this cycle
    assign fill_go = (st == S_FILL) && (q_cnt != 5'd16 || burst == 3'd0);

    // ---- capture
    logic        acc_r;                 // the right accumulator: mixing step 4, or capture unit 1
    assign acc_r = (st == S_MIX) ? cnt[2] : (st == S_OUT) ? cnt == 4'd1 : ent[0];
    logic signed [27:0] cap_acc;        // (also the mixer adder's input)
    assign cap_acc = acc_r ? accr : accl;
    // DS rule DS_SPU_CAPTURE (docs/hw-reference.md, sndcap v3 DC grid): the
    // sample is (sum >> 7) / 2, halved toward zero (melonDS: sum >> 8): one
    // more when the sum is negative and bit 7 is set
    // The capture unit's side by ent[0] alone (cu_acc): the buffer is written
    // only in S_CAPA, where acc_r is ent[0], so cnt stays off the path to
    // u_cb's data (#1015/#1030/#1031 cnt -> u_cb -0.006..-0.561 ns)
    logic signed [27:0] cu_acc;
    assign cu_acc = ent[0] ? accr : accl;
    logic signed [19:0] cap_sh;
    assign cap_sh = cu_acc[27:8] + {19'd0, cu_acc[27] && cu_acc[7]};
    logic [15:0] cap_smp;               // clamp(acc >> 8)
    logic        c_ovf;
    assign c_ovf = cap_sh[19:15] != {5{cap_sh[19]}};
    assign cap_smp = c_ovf ? {cap_sh[19], {15{!cap_sh[19]}}} : cap_sh[15:0];
    // DS rule DS_SPU_CAP8 (docs/hw-reference.md, run 30 sndq S1): the 8-bit
    // sample is (sum >> 15) / 2, halved toward zero, saturated (melonDS:
    // the 16-bit sample's top byte)
    logic signed [11:0] cap8_sh;
    logic [7:0]  cap8;
    logic [12:0] cap8_s;                // in a DSP block (nds_dsp_add): the chip is short of LABs
    nds_dsp_add #(.W(12)) u_c8 (.clk, .a(cu_acc[27:16]), .b({11'd0, cu_acc[27] && cu_acc[15]}), .s(cap8_s));
    assign cap8_sh = cap8_s[11:0];
    assign cap8 = cap8_sh[11:7] != {5{cap8_sh[11]}} ? {cap8_sh[11], {7{!cap8_sh[11]}}} : cap8_sh[7:0];
    logic        cword;                 // this sample completes a word
    assign cword = posn[2:1] == 2'd0;
    logic [1:0]  cslot;                 // the sample's buffer word
    assign cslot = f_pos[4:3];
    logic [4:0]  cbe;                   // and its byte lanes
    assign cbe = ccnt[3] ? (5'b1 << f_pos[2:1]) : (f_pos[2] ? 5'b01100 : 5'b00011);
    logic        capa_go;               // S_CAPA takes a sample this cycle
    assign capa_go = CAPTURE && (st == S_CAPA) && f_t17;
    logic        cfl_go;                // S_CFL queues a word this cycle
    assign cfl_go = CAPTURE && (st == S_CFL) && cfl_k != cfl_n && cfl_rdy && q_cnt != 5'd16;
    logic        cap_end;               // the capture position returns to 0
    assign cap_end = (capa_go && past_end && !cword) || (CAPTURE && st == S_CFL && cfl_k == cfl_n && cap_wrap);

    // ------------------------------------------------------------ register access decode
    // melonDS SPU::Write8/16/32: up to two byte-enabled RAM writes per access.
    logic        op1_v, op2_v;
    logic [6:0]  op1_a, op2_a;
    logic [3:0]  op1_be;
    logic        rd_ram;                // read returns a RAM word
    logic [6:0]  rd_a;

    logic [3:0] r_ch;   assign r_ch = reg_addr[7:4];
    logic [3:0] r_off;  assign r_off = reg_addr[3:0];
    logic       r_glob; assign r_glob = reg_addr[8];
    logic [7:0] r_ga;   assign r_ga = reg_addr[7:0];
    logic [6:0] r_cap;  assign r_cap = {4'b1000, r_ga[3], 2'b00};   // capture 0/1 entry
    localparam logic [31:0] CNTM = 32'hFF7F837F;
    logic        cap_tmr;               // SOUND1TMR / SOUND3TMR also set the capture timers
    assign cap_tmr = (r_ch == 4'd1) || (r_ch == 4'd3);
    assign op2_a = {4'b1000, r_ch[1], 2'd2};
    logic        cnt_hi;                // the write reaches SOUNDxCNT bit 31
    assign cnt_hi = op1_v && !r_glob && op1_a[1:0] == 2'd0 && op1_be[3];

    always_comb begin
        op1_v = 1'b0; op1_a = {1'b0, r_ch, 2'd0}; op1_be = 4'b0;
        op2_v = 1'b0;
        rd_ram = 1'b0; rd_a = {1'b0, r_ch, 2'd0};
        if (reg_we && !r_glob) begin
            // 8-bit: SOUNDxCNT bytes only. 16-bit: every halfword but SAD's.
            // 32-bit: every word. LEN keeps bits above 20 that nothing reads,
            // so its halves use the same lanes as the others.
            op1_a[1:0] = (reg_size == 2'd0) ? 2'd0 : r_off[3:2];
            case (reg_size)
                2'd0: begin op1_v = r_off[3:2] == 2'd0; op1_be = 4'b1 << r_off[1:0]; end
                2'd1: begin op1_v = r_off[3:2] != 2'd1; op1_be = r_off[1] ? 4'b1100 : 4'b0011; end
                default: begin op1_v = 1'b1; op1_be = 4'b1111; end
            endcase
            op2_v = cap_tmr && reg_size != 2'd0 && r_off[3:2] == 2'd2 && !(reg_size == 2'd1 && r_off[1]);
        end else if (reg_we) begin
            // capture DAD/LEN; SOUNDCNT, SOUNDBIAS and SNDCAPCNT are flops
            if (reg_size == 2'd2 && (r_ga == 8'h10 || r_ga == 8'h18)) begin
                op1_v = 1'b1; op1_a = r_cap | 7'd1; op1_be = 4'b1111;
            end
            if (reg_size != 2'd0 && (r_ga == 8'h14 || r_ga == 8'h1C)) begin
                op1_v = 1'b1; op1_a = r_cap | 7'd3; op1_be = 4'b0011;
            end
        end else if (!r_glob) begin
            rd_ram = 1'b1;
        end else if (r_ga == 8'h10 || r_ga == 8'h18) begin
            rd_ram = 1'b1; rd_a = r_cap | 7'd1;
        end
    end

    // read data: the aligned word (melonDS SPU::Read32; its 8/16-bit reads
    // are the same lanes except for a few registers games do not read that way)
    logic [31:0] rd_word;
    assign reg_rdata = rd_word;
    always_comb begin
        rd_word = 32'd0;
        if (!r_glob) begin
            if (r_off[3:2] == 2'd0) rd_word = {busy[r_ch], cr_q[30:0]} & CNTM;   // word 0
        end else case (r_ga[4:2])
            3'd0: rd_word = {16'b0, soundcnt};
            3'd1: rd_word = {22'b0, bias};
            3'd2: rd_word = {16'b0, capcnt1, capcnt0};
            3'd4, 3'd6: rd_word = cr_q & 32'h07FFFFFC;           // the capture's word 1
            default: ;
        endcase
    end

    function automatic logic [7:0] capset(input logic [7:0] v);
        logic [7:0] r;
        r = v & 8'h8F;
        if (!r[7] || !CAPTURE) r[0] = 1'b0;
        if (!CAPTURE) r[7] = 1'b0;
        return r;
    endfunction

    // ------------------------------------------------------------ RAM ports
    // A register write reaches word op_a[1:0] of row op_a[6:2]; every word
    // of the row gets the same data, the byte lanes pick the word.
    logic [6:0]  op_a;
    logic [3:0]  op_be;
    assign op_a = (st == S_REG2) ? op2_a : op1_a;
    assign op_be = (st == S_REG2) ? 4'b0011 : op1_be;
    assign cr_ra = (st == S_REG || st == S_REG2) ? {rd_a[1:0], rd_a[6:2]} : {cnt[1:0], ent};   // held: reg_rdata reads cr_q with reg_ack; S_LOAD: word cnt
    logic        clearing;
    assign clearing = CLEAR_REGS && st == S_CLEAR;
    assign cr_we = clearing || (st == S_REG2 && reg_we) || (st == S_REG && reg_we && op1_v);
    assign cr_wa = clearing ? clr[6:0] : {op_a[1:0], op_a[6:2]};
    assign cr_be = clearing ? 4'hF : op_be;
    assign cr_wd = clearing ? 32'd0 : reg_wdata;   // SAD/DAD kept as written; the engine uses bits 26:2
    assign cb_we = capa_go;
    assign cb_be = cb_f8 ? 4'(4'b1 << f_pos[2:1]) : (f_pos[2] ? 4'b1100 : 4'b0011);   // (cbe with the registered format)
    // The capture sample and the unit's half of the address come from
    // registers (cb_d, cb_e0, #1061 ent[0] -> u_cb -0.188 ns): during a
    // capture entry ent, the format and both accumulators hold from S_LOAD
    // on (the mixing and the second pass run outside it), so the value a
    // clock before S_CAPA's write is the same (a simulation check below)
    logic [31:0] cb_d;
    logic        cb_e0, cb_f8;
    wire  [31:0] cb_dn = ccnt[3] ? {4{cap8}} : {cap_smp, cap_smp};
    always_ff @(posedge clk) if (ce) begin cb_d <= cb_dn; cb_e0 <= ent[0]; cb_f8 <= ccnt[3]; end
`ifndef ALTERA_RESERVED_QIS
    always_ff @(posedge clk) if (ce && !rst && cb_we && (cb_d != cb_dn || cb_e0 != ent[0] || cb_f8 != ccnt[3]))
        $error("sound: capture data or unit changed in the clock before its write");
`endif
    assign cb_wa = {cb_e0, cslot};
    assign cb_wd = cb_d;
    assign cb_ra = {ent[0], cfl_k[1:0]};
    // Run-time words need no clearing: a start sets every field before use.
    // The store writes every lane but the loop state's (4, 18, 19); the
    // header and the loop point write only those.
    logic        lsv_we, lsv_itc;
    assign lsv_itc = (st == S_ITC);
    assign lsv_we = (itb_go && act == A_HDR) || (lsv_itc && at_loop);
    // the loop state goes to the RAM a clock later, from registers (#743:
    // the FIFO RAM's output into u_run's write data missed by 0.032 ns at
    // ce = 1); its lanes are its own, and S_STORE comes two clocks later at
    // the earliest
    logic        lsv_q;
    logic [15:0] lsv_v;
    logic [6:0]  lsv_i;
    always_ff @(posedge clk) if (ce) begin
        lsv_q <= lsv_we;
        lsv_v <= lsv_itc ? vnew : ff_q[15:0];
        lsv_i <= lsv_itc ? inew : hdr_idx;
    end
    assign rr_we = (st == S_STORE) || lsv_q;
    assign rr_be = ((st == S_STORE) ? 20'h3FFEF : 20'h0) | (lsv_q ? 20'hC0010 : 20'h0);
    assign rr_wd = {lsv_v, w7[23:0], w6, w5[39:26], w5[25:0], 1'b0, lsv_i, w4[31:0]};
    assign ff_ra = itb_go && (act == A_DECRD || act == A_DECSH) ? {1'b1, rom_ra[9:3]}
                                                                : {1'b0, ent[3:0], f_rp[4:2]};

    // ------------------------------------------------------------ working-set field updates
    // Each field: one assignment from an encoded source choice.
    logic        ld;                    // S_LOAD: the rows arrive
    assign ld = (st == S_LOAD) && cnt == 4'd1;
    logic        ch_start;              // S_CH: melonDS SPUChannel::Start
    assign ch_start = (st == S_CH) && !inactive && e_keyon && !selpass;
    logic        ita_go;                // S_ITA takes a sample
    assign ita_go = (st == S_ITA) && f_t17;
    logic        cap_go;                // S_CAP: a started unit resets
    assign cap_go = CAPTURE && (st == S_CAP) && cap_start[ent[0]];

    // w4: timer, sample, loop index
    logic        tm_en;
    assign tm_en = (st == S_CH && !selpass) || (CAPTURE && st == S_CAP) || ita_go || capa_go;
    // Sources: a constant (0, or a PSG/noise level), the PCM read, the
    // ADPCM value: with the load, four inputs.
    typedef enum logic [1:0] { CS_HOLD, CS_CONST, CS_PCM, CS_ADP } cs_t;
    cs_t         cs_sel;
    logic        cs_zero;               // the constant is 0 (start, inactive, one-shot end)
    assign cs_zero = !(ita_go && f_fmt == 2'd3);
    always_comb begin
        cs_sel = CS_HOLD;
        if ((st == S_CH && (inactive || (e_keyon && !selpass))) || (ita_go && (f_fmt == 2'd3 || it_stop))) cs_sel = CS_CONST;
        else if (itb_go && (act == A_READ8 || act == A_READ16)) cs_sel = CS_PCM;
        // (A_HOLD needs no write: past the end of a manual-repeat sample the
        // sample already equals the ADPCM value, as every path there decodes)
        else if (st == S_ITA && adp_upd) cs_sel = CS_ADP;
    end
    logic        psg_neg;               // PSG/noise sample is -0x7FFF
    assign psg_neg = noise_ch ? f_val[0] : !psg_hi;
    logic [15:0] adp_cs;                // the ADPCM value after a decode or a loop restore
    assign adp_cs = (st == S_ITC) ? vnew : f_vall;

    // w5: position
    // Sources: a constant (a start's -3 samples, PSG -1; or 0), the next
    // position, the loop start: with the load, four inputs.
    typedef enum logic [1:0] { PS_HOLD, PS_CONST, PS_POSN, PS_LSTART } ps_t;
    ps_t         ps_sel;
    logic [3:0]  ps_const;              // low bits of the constant (the rest are its sign)
    assign ps_const = !ch_start ? 4'h0 : (f_fmt == 2'd0) ? 4'hA : (f_fmt == 2'd1) ? 4'h4 :
                      (f_fmt == 2'd2) ? 4'hD : 4'hF;
    always_comb begin
        ps_sel = PS_HOLD;
        if (ch_start || cap_go || cap_end) ps_sel = PS_CONST;
        else if (capa_go) ps_sel = PS_POSN;
        else if (ita_go) begin
            if (f_fmt == 2'd3) ps_sel = noise_ch ? PS_HOLD : PS_POSN;
            else if (it_loop) ps_sel = PS_LSTART;
            else if (!sat) ps_sel = PS_POSN;
        end
    end

    // w6: word offset (refill offset, or a capture's write offset)
    logic        roff_zero, roff_sum;
    assign roff_zero = ch_start || cap_go;
    assign roff_sum = fill_go || cfl_go;

    always_ff @(posedge clk) if (ce) begin
        // register words (load only)
        // words 0-3 arrive in S_LOAD's clocks 1-4
        if (st == S_LOAD && cnt == 4'd1) w0 <= cr_q;
        if (st == S_LOAD && cnt == 4'd2) w1 <= cr_q;
        if (st == S_LOAD && cnt == 4'd3) w2 <= cr_q;
        if (st == S_LOAD && cnt == 4'd4) begin
            w3 <= cr_q;
            tot <= {6'b0, w2[31:16]} + {1'b0, cr_q[20:0]} + {21'b0, e4 && cr_q[20:0] == 21'd0};
        end

        // w4
        if (ld) w4 <= rr_q[39:0];
        else begin
            if (tm_en) {w5[38], w4[15:0]} <= tm_sum;
            case (cs_sel)
                CS_CONST: w4[31:16] <= cs_zero ? 16'd0 : psg_neg ? 16'h8001 : 16'h7FFF;
                CS_PCM:  w4[31:16] <= fpcm;
                CS_ADP:  w4[31:16] <= f_val;   // the sample follows the ADPCM value one cycle later
                default: ;
            endcase
        end

        // w5
        if (ld) w5 <= rr_q[79:40];
        else begin
            case (ps_sel)
                PS_CONST:  w5[25:0] <= {{22{ch_start}}, ps_const};
                PS_POSN:   w5[25:0] <= posn;
                PS_LSTART: w5[25:0] <= lstart;
                default: ;
            endcase
            if (ch_start) w5[30:26] <= 5'd0;
            else if (itb_go) w5[30:26] <= rp_sum[4:0];
            if (ch_start) w5[33:31] <= 3'd0;
            else if (fill_go) w5[33:31] <= wp_sum[2:0];
            if (ch_start && f_fmt != 2'd3) w5[35:34] <= f_wlap + 2'd1;
            else if (itb_go && rp_sum[5]) w5[35:34] <= f_rlap + 2'd1;
            if ((ch_start && f_fmt != 2'd3) || (fill_go && wp_sum[3])) w5[37:36] <= f_wlap + 2'd1;
        end

        // w6
        if (ld) w6 <= rr_q[119:80];
        else begin
            if (roff_zero) w6[21:0] <= 22'd0;
            else if (roff_sum) w6[21:0] <= roff_e + {19'b0, burst};
            if (ch_start) w6[28:22] <= 7'd0;
            else if (fill_go) w6[28:22] <= f_level + {2'b0, burst, 2'b0};
            else if (itb_go) w6[28:22] <= lev_new;
            if (itb_go && (act == A_LOOP || act == A_DECRD)) w6[36:29] <= fbyte;
            else if (itb_go && act == A_DECSH) w6[36:29] <= {4'd0, f_byte[7:4]};
        end

        // w7
        if (ld) w7 <= rr_q[159:120];
        else begin
            // sources: the noise LFSR (0x7FFF at a start), the header, the
            // loop or decoded value
            if (ch_start || (ita_go && f_fmt == 2'd3 && noise_ch))
                w7[15:0] <= ch_start ? 16'h7FFF : f_val[0] ? ({1'b0, f_val[15:1]} ^ 16'h6000) : {1'b0, f_val[15:1]};
            else if (itb_go && act == A_HDR) w7[15:0] <= ff_q[15:0];
            else if ((itb_go && act == A_LOOP) || st == S_ITC) w7[15:0] <= adp_cs;
            if (itb_go && act == A_HDR) w7[22:16] <= hdr_idx;
            else if (itb_go && act == A_LOOP) w7[22:16] <= f_idxl;
            else if (st == S_ITC) w7[22:16] <= inew;
        end
    end

    // ------------------------------------------------------------ mixer
    // melonDS PanOutput: left products in S_MIX step 2, right in step 4.
    // Channels 1 and 3 can leave the mixer (SOUNDCNT 12/13). The output
    // select (SOUNDCNT 8-11) is a second pass after the captures: the
    // selected sides are cleared and channels 1 and 3 are mixed into them
    // again from their stored samples.
    logic signed [25:0] contrib;
    assign contrib = mul_p[35:10];
    logic signed [27:0] cx;
    assign cx = {{2{contrib[25]}}, contrib};
    logic [1:0]  lsel, rsel;
    // (no capture: the mixer goes straight out. A game's output select plays channels 1 and 3 back
    // from capture buffers that are never written here, so they stay out of the mix as well)
    assign lsel = CAPTURE ? soundcnt[9:8] : 2'd0;
    assign rsel = CAPTURE ? soundcnt[11:10] : 2'd0;
    logic        sel_go;                // S_BOUND after the captures: start the second pass
    assign sel_go = (st == S_BOUND) && !(reg_req && !reg_ack) && ent == (CAPTURE ? 5'd18 : 5'd16) && (lsel != 2'd0 || rsel != 2'd0);
    logic        mix_ex;                // channel 1/3 left out of the mixer
    assign mix_ex = (ent == 5'd1 && soundcnt[12]) || (ent == 5'd3 && soundcnt[13]);
    logic        mix_l, mix_r, acc_clr;
    assign mix_l = (st == S_MIX) && cnt == 4'd2 && (selpass ? (ent[1] ? lsel[1] : lsel[0]) : !mix_ex);
    assign mix_r = (st == S_MIX) && cnt == 4'd4 && (selpass ? (ent[1] ? rsel[1] : rsel[0]) : !mix_ex);
    assign acc_clr = (st == S_IDLE) && !(reg_req && !reg_ack) && tick_pend;
    logic signed [27:0] acc_sum;        // one adder for both sides
    assign acc_sum = cap_acc + cx;
    always_ff @(posedge clk) if (ce) begin
        if (acc_clr || (sel_go && lsel != 2'd0)) accl <= '0;
        else if (mix_l) accl <= acc_sum;
        if (acc_clr || (sel_go && rsel != 2'd0)) accr <= '0;
        else if (mix_r) accr <= acc_sum;
    end

    assign vp_b = cnt[1] ? pan8 : 8'd128 - pan8;   // step 0: 128 - pan, step 2: pan
    always_ff @(posedge clk) if (ce) vp <= vs * vp_b;
    always_comb begin
        mul_a = '0; mul_b = '0;
        case (st)
            // vs*(128-pan), cs*that, vs*pan, cs*that; products one cycle later
            S_MIX: begin mul_a = {{12{f_cs[15]}}, f_cs}; mul_b = vp; end
            S_OUT: begin
                mul_a = cap_acc;                // left in step 0, right in step 1
                mul_b = {12'b0, (soundcnt[6:0] == 7'd127) ? 8'd128 : {1'b0, soundcnt[6:0]}};
            end
            default: ;
        endcase
    end

    // final output
    logic signed [20:0] mo;             // (side * master) >> 15
    assign mo = mul_p[35:15];
    logic signed [21:0] mob;
    assign mob = {mo[20], mo} + $signed({6'b0, bias, 6'b0}) - 22'sd32768;
    logic [15:0] mclamp;
    logic        m_ovf;
    assign m_ovf = mob[21:15] != {7{mob[21]}};
    assign mclamp = m_ovf ? {mob[21], {15{!mob[21]}}} : mob[15:0];

    // ------------------------------------------------------------ engine sequence
    always_ff @(posedge clk) if (ce) begin
        reg_ack <= 1'b0;
        out_valid <= 1'b0;

        case (st)
            S_CLEAR: begin
                clr <= clr + 8'd1;
                if (clr == (CLEAR_REGS ? 8'h7F : 8'h1F)) st <= S_IDLE;
            end

            S_IDLE: begin
                if (reg_req && !reg_ack) begin
                    st <= S_REG; reg_ret <= 1'b0;
                end else if (tick_pend) begin
                    tick_pend <= 1'b0;
                    win <= 1'b1;
                    ent <= 5'd0;
                    st <= soundcnt[15] ? S_BOUND : S_OUT;
                    cnt <= 4'd0;
                end
            end

            // between entries: serve a pending register access first
            S_BOUND: begin
                cnt <= 4'd0;
                if (reg_req && !reg_ack) begin
                    st <= S_REG; reg_ret <= 1'b1;
                end else if (sel_go) begin
                    selpass <= 1'b1;
                    ent <= 5'd1;
                end else if (ent == (CAPTURE ? 5'd18 : 5'd16) || (selpass && ent == 5'd5)) st <= S_OUT;
                else if (e4 && !ccnt[7]) ent <= ent + 5'd1;
                else st <= S_LOAD;
            end

            // register access: writes go to the RAM in this state (and the
            // capture timer copy in S_REG2), RAM reads come back in S_REG2
            S_REG: begin
                if (!reg_we && rd_ram) st <= S_REG2;
                else begin
                    if (reg_we && r_glob) begin
                        case (reg_size)
                            2'd0: case (r_ga)
                                8'h00: soundcnt[7:0] <= {1'b0, reg_wdata[6:0]};
                                8'h01: soundcnt[15:8] <= reg_wdata[15:8] & 8'hBF;
                                8'h08: begin capcnt0 <= capset(reg_wdata[7:0]); if (reg_wdata[7] && !capcnt0[7]) cap_start[0] <= 1'b1; end
                                8'h09: begin capcnt1 <= capset(reg_wdata[15:8]); if (reg_wdata[15] && !capcnt1[7]) cap_start[1] <= 1'b1; end
                                default: ;
                            endcase
                            default: case (r_ga)
                                8'h00: soundcnt <= reg_wdata[15:0] & 16'hBF7F;
                                8'h04: bias <= reg_wdata[9:0];
                                8'h08: begin
                                    capcnt0 <= capset(reg_wdata[7:0]); if (reg_wdata[7] && !capcnt0[7]) cap_start[0] <= 1'b1;
                                    capcnt1 <= capset(reg_wdata[15:8]); if (reg_wdata[15] && !capcnt1[7]) cap_start[1] <= 1'b1;
                                end
                                default: ;
                            endcase
                        endcase
                    end
                    // SOUNDxCNT bit 31: busy 0 -> 1 requests a start
                    if (reg_we && cnt_hi) begin
                        busy[r_ch] <= reg_wdata[31];
                        if (reg_wdata[31] && !busy[r_ch]) keyon[r_ch] <= 1'b1;
                    end
                    if (reg_we && op2_v) st <= S_REG2;
                    else begin
                        reg_ack <= 1'b1;
                        st <= reg_ret ? S_BOUND : S_IDLE;
                    end
                end
            end

            S_REG2: begin
                reg_ack <= 1'b1;
                st <= reg_ret ? S_BOUND : S_IDLE;
            end


            // two cycles: address, then both rows
            // five cycles: the register words one per clock, the run row with word 0
            S_LOAD: begin
                cnt <= cnt + 4'd1;
                if (cnt == 4'd4) st <= e4 ? S_CAP : S_CH;
            end

            S_CH: begin
                cnt <= 4'd0;
                fills <= 2'd2;
                if (inactive || selpass) st <= S_MIX;   // not stored: an inactive channel mixes 0
                else if (e_keyon) begin
                    keyon[ent[3:0]] <= 1'b0;
                    st <= (f_fmt == 2'd3) ? S_ITA : S_RETAG;   // PSG and noise read no FIFO
                end else st <= S_ITA;
            end

            // the channel's FIFO words become the old lap (tg_we when the fetcher is not writing)
            S_RETAG: if (!ff_we) begin
                cnt <= cnt + 4'd1;
                if (cnt == 4'd7) st <= S_FILL;
            end

            S_FILL: if (fill_go) begin
                if (fills != 2'd0) begin
                    fills <= fills - 2'd1;
                    if (fills == 2'd1) st <= S_ITA;
                end else st <= S_ITA;
            end

            S_ITA: begin
                act <= it_act;
                adp_upd <= 1'b0;
                if (!f_t17) st <= S_STORE;
                else if (f_fmt == 2'd3) st <= S_ITA;
                else if (it_stop) begin
                    busy[ent[3:0]] <= 1'b0;
                    st <= S_STORE;
                end else st <= S_ITB;
            end

            S_ITB: if (itb_go) begin
                if (act == A_LOOP) adp_upd <= 1'b1;
                st <= (act == A_DECRD || act == A_DECSH) ? S_ITC : need_fill ? S_FILL : S_ITA;
                dec_fill <= need_fill;
                fills <= 2'd0;
            end

            S_ITC: begin
                st <= dec_fill ? S_FILL : S_ITA;
                adp_upd <= 1'b1;
            end

            // capture unit (melonDS SPUCaptureUnit::Run)
            S_CAP: if (CAPTURE) begin
                if (cap_start[ent[0]]) cap_start[ent[0]] <= 1'b0;
                st <= S_CAPA;
            end

            S_CAPA: if (!CAPTURE) st <= S_IDLE; else if (!f_t17) st <= S_STORE;
            else begin
                cfl_k <= 3'd0; cfl_rdy <= 1'b0; cap_wrap <= past_end;
                cfl_n <= {1'b0, cslot} + 3'd1;
                if (cword && (cslot == 2'd3 || past_end)) st <= S_CFL;
                else if (past_end && ccnt[2]) begin
                    if (ent[0]) capcnt1[7] <= 1'b0; else capcnt0[7] <= 1'b0;
                    st <= S_STORE;
                end
            end

            // write the buffered capture words (melonDS SPUCaptureUnit::FIFO_FlushData)
            S_CFL: if (CAPTURE) begin
                cfl_rdy <= 1'b1;
                if (cfl_k == cfl_n) begin
                    st <= S_CAPA;
                    if (cap_wrap && ccnt[2]) begin
                        if (ent[0]) capcnt1[7] <= 1'b0; else capcnt0[7] <= 1'b0;
                        st <= S_STORE;
                    end
                end else if (cfl_go) begin
                    cfl_k <= cfl_k + 3'd1;
                    cfl_rdy <= 1'b0;
                end
            end

            S_STORE: begin
                cnt <= 4'd0;
                if (e4) begin ent <= ent + 5'd1; st <= S_BOUND; end
                else st <= S_MIX;
            end

            S_MIX: begin
                cnt <= cnt + 4'd1;
                if (cnt == 4'd4) begin
                    cnt <= 4'd0;
                    ent <= ent + (selpass ? 5'd2 : 5'd1);
                    st <= S_BOUND;
                end
            end

            // master volume, bias, clamp (melonDS SPU::Mix)
            S_OUT: begin
                cnt <= cnt + 4'd1;
                if (cnt == 4'd2) begin
                    out_valid <= 1'b1;
                    win <= 1'b0;
                    selpass <= 1'b0;
                    st <= S_IDLE;
                end
            end

            default: st <= S_IDLE;
        endcase

        late <= tick && (win || tick_pend);
        if (tick) begin
            tick_pend <= 1'b1;
            if (win || tick_pend) overrun <= 1'b1;
        end

        if (rst) begin
            st <= S_CLEAR; clr <= 8'd0; tick_pend <= 1'b0; overrun <= 1'b0; win <= 1'b0;
            soundcnt <= '0; bias <= '0; capcnt0 <= '0; capcnt1 <= '0; cap_start <= '0;
            busy <= '0; keyon <= '0; selpass <= 1'b0;
            ent <= '0; cnt <= '0;
        end
    end

    // (no reset: the outputs matter only with out_valid)
    always_ff @(posedge clk) if (ce) begin
        if (st == S_OUT && cnt == 4'd1) out_l <= mclamp & {16{power}};
        if (st == S_OUT && cnt == 4'd2) out_r <= mclamp & {16{power}};
    end
    assign out_pre = st == S_OUT && cnt == 4'd0;
    assign dac_l = {~out_l[15], out_l[14:6]};
    assign dac_r = {~out_r[15], out_r[14:6]};

    // ------------------------------------------------------------ fetcher
    // Serves the queue one entry at a time, from the queue RAM's output:
    // a refill burst, or one capture word.
    typedef enum logic [1:0] { F_IDLE, F_HEAD, F_RUN } fstate_t;
    fstate_t     fs;
    logic [3:0]  q_wp, q_rp;
    logic [2:0]  c_iss, c_rcv;
    logic        h_we, h_zero;
    logic [31:0] h_data;
    logic [3:0]  h_ch;
    logic [24:0] h_addr;
    logic [2:0]  h_n, h_wp;
    logic [1:0]  h_lap;
    generate if (CAPTURE) begin : g_qc
        assign {h_we, h_data, h_ch, h_addr, h_zero, h_n, h_wp, h_lap} = q_q;
    end else begin : g_qn
        assign h_we = 1'b0, h_data = 32'd0;
        assign {h_ch, h_addr, h_zero, h_n, h_wp, h_lap} = q_q;
    end endgenerate

    assign q_wa = q_wp;
    assign q_ra = q_rp;
    assign q_wd = QW'({e4, cb_q, ent[3:0], faddr[24:0], faddr[25:12] == 14'd0 && !e4, burst, f_wp, f_wlap});

    logic [3:0] c_wsum;
    assign c_wsum = {1'b0, h_wp} + {1'b0, c_rcv};
    assign ff_wa = {h_ch, c_wsum[2:0]};
    assign ff_wd = h_zero ? 32'd0 : mem_rdata;
    assign ff_we = (fs == F_RUN) && !h_we && (h_zero || mem_rvalid);
    assign tg_we = ff_we || st == S_RETAG;
    assign tg_wa = ff_we ? ff_wa : {ent[3:0], cnt[2:0]};
    assign tg_wd = ff_we ? h_lap + {1'b0, c_wsum[3]} : f_wlap - 2'd1;

    assign mem_req = (fs == F_RUN) && !h_zero && c_iss != h_n;
    assign mem_we = h_we;
    assign mem_addr = h_addr + {22'b0, c_iss};
    assign mem_wdata = h_data;
    assign q_pop = (fs == F_RUN) && (h_we ? mem_ack : ff_we && (c_rcv + 3'd1 == h_n));
    assign q_we = (fill_go && burst != 3'd0) || cfl_go;

    always_ff @(posedge clk) if (ce) begin
        case (fs)
            F_IDLE: if (q_cnt != 5'd0) fs <= F_HEAD;
            F_HEAD: begin                   // the queue RAM output follows q_rp
                c_iss <= 3'd0; c_rcv <= 3'd0;
                fs <= F_RUN;
            end
            F_RUN: begin
                if (mem_req && mem_ack) c_iss <= c_iss + 3'd1;
                if (ff_we) c_rcv <= c_rcv + 3'd1;
                if (q_pop) fs <= F_IDLE;
            end
            default: fs <= F_IDLE;
        endcase
        if (q_we) q_wp <= q_wp + 4'd1;
        if (q_pop) q_rp <= q_rp + 4'd1;
        q_cnt <= q_cnt + {4'b0, q_we} - {4'b0, q_pop};
        if (rst) begin
            fs <= F_IDLE; q_wp <= '0; q_rp <= '0; q_cnt <= '0;
        end
    end
endmodule
