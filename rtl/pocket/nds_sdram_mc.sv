// SPDX-License-Identifier: MIT
// SDRAM controller for the DS core's shell (docs/phase2-integration.md,
// "Memory-system merge" M1), on clk_mem (100.54 MHz). One 16-bit SDR chip
// (AS4C32M16 class: 4 banks, 8192 rows, 1024 columns), CAS latency 3, burst
// 2 reads, single-location writes; every access opens one row and closes it
// with auto-precharge. The pin cells, the inverted chip clock and the read
// capture are psx_sdram_ctrl's (rtl/mem, MIT); the access engine is new:
//   - a read of N words (1-8, one row) issues a READ every 2 clocks, so the
//     beats come back gapless: 32 bytes in 16 clocks of data, one word per 2
//     clocks on r_*, where psx_sdram_ctrl's clk1x interface gave one word
//     per 3 clocks;
//   - a single 32-bit write is two WRITEs (byte enables on DQM);
//   - the write chain (bw_*, a first-word-fall-through FIFO head) writes
//     consecutive words of one row back to back, up to CHAIN words per row
//     opening, whenever no port request waits (the stacked bottom screen's
//     lines and the 3D line ring's writes; the FIFO absorbs the wait).
// Byte address map (psx_sdram_ctrl's): [9:1] column A8..A0, [25] A9, [22:10]
// row, [24:23] bank. Requests use word addresses (byte address / 4).
`default_nettype none
module nds_sdram_mc #(
    parameter integer POWERUP_CYCLES = 20480,   // >= 200 us at 100.54 MHz
    parameter integer REFRESH_CYCLES = 780,     // 8192 per 64 ms
    parameter integer CHAIN = 32,               // write-chain words per row opening
    parameter integer RD_LAT = 4,               // CL+1: a READ at edge e has beat 0 in dq_in after edge e+RD_LAT
    // 1: reads leave their row open (one per bank): a read of an open row starts its READs at once, back to
    // back with the last request's (no ACTIVE, tRCD, auto-precharge or tRP); a read of another row first
    // precharges that bank; writes, chains and refreshes precharge what they need first and keep closing
    // their rows (docs/phase2-integration.md "Open rows")
    parameter integer OPEN = 0,
    // 1: one register stage between the engine and the pins' I/O registers: the chip sees the same commands a
    // clk_mem later, and the read capture moves with them (RD_LAT + 1); the engine's own timeline is unchanged.
    // Gives the command/address decode (ref_owed, conf_q, the bus grant) a whole clock (#1029/#1032/#1033)
    parameter integer OUT_REG = 0
) (
    input  wire         clk,                    // clk_mem
    input  wire         init,                   // hold in power-up/initialisation
    output reg          ready = 0,
    // request: held until c_ready (one clock)
    input  wire         c_valid,
    input  wire         c_hurry,            // port 0 (video reads) waits: a write chain ends early
    input  wire         c_we,
    input  wire [23:0]  c_addr,                 // word address
    input  wire [14:0]  c_rb,                   // c_addr[22:8] (bank, row), registered at the grant
    input  wire [3:0]   c_n,                    // read: words, 1-8, within one 1 KiB row
    input  wire [31:0]  c_wdata,
    input  wire [3:0]   c_be,
    output reg          c_ready = 0,
    // read words, in order
    output reg          r_valid = 0,
    output reg  [31:0]  r_data = 0,
    output reg          r_last = 0,
    // write chain: the head of a first-word-fall-through FIFO, popped by bw_read
    input  wire         bw_valid,
    input  wire [23:0]  bw_addr,
    input  wire [31:0]  bw_data,
    output wire         bw_read,                // pops the head (the cycle its low half is written)
    output wire         ref_late,               // (diagnostics) a refresh waits behind another one
    // pins
    inout  wire [15:0]  SDRAM_DQ,
    output wire [12:0]  SDRAM_A,
    output wire [1:0]   SDRAM_BA,
    output wire         SDRAM_DQML,
    output wire         SDRAM_DQMH,
    output wire         SDRAM_nWE,
    output wire         SDRAM_nRAS,
    output wire         SDRAM_nCAS,
    output wire         SDRAM_CKE,
    output wire         SDRAM_CLK
);
    // ---------------------------------------------------------------- pins
    localparam [2:0] C_NOP = 3'b111, C_ACT = 3'b011, C_READ = 3'b101, C_WRITE = 3'b100,
                     C_PRE = 3'b010, C_REF = 3'b001, C_MRS = 3'b000;
    (* useioff = 1 *) reg [2:0]  cmd = C_NOP;
    (* useioff = 1 *) reg [12:0] a = 0;
    (* useioff = 1 *) reg [1:0]  ba = 0;
    (* useioff = 1 *) reg [1:0]  dqm = 2'b00;
    (* useioff = 1 *) reg [15:0] dq_out = 0;
    (* useioff = 1 *) reg        dq_oe = 0;
    (* useioff = 1 *) reg [15:0] dq_in = 0;
    // OUT_REG: the pins' registers, a clk_mem behind the engine's
    (* useioff = 1 *) reg [2:0]  p_cmd = C_NOP;
    (* useioff = 1 *) reg [12:0] p_a = 0;
    (* useioff = 1 *) reg [1:0]  p_ba = 0;
    (* useioff = 1 *) reg [1:0]  p_dqm = 2'b00;
    (* useioff = 1 *) reg [15:0] p_dq_out = 0;
    (* useioff = 1 *) reg        p_dq_oe = 0;
    always @(posedge clk) begin p_cmd <= cmd; p_a <= a; p_ba <= ba; p_dqm <= dqm; p_dq_out <= dq_out; p_dq_oe <= dq_oe; end
    assign {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = OUT_REG != 0 ? p_cmd : cmd;
    assign SDRAM_A = OUT_REG != 0 ? p_a : a;
    assign SDRAM_BA = OUT_REG != 0 ? p_ba : ba;
    assign {SDRAM_DQMH, SDRAM_DQML} = OUT_REG != 0 ? p_dqm : dqm;
    assign SDRAM_DQ = (OUT_REG != 0 ? p_dq_oe : dq_oe) ? (OUT_REG != 0 ? p_dq_out : dq_out) : 16'bz;
    assign SDRAM_CKE = 1'b1;
    // chip clock = inverted clk from a DDR output cell
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"), .invert_output("OFF"),
        .lpm_hint("UNUSED"), .lpm_type("altddio_out"), .oe_reg("UNREGISTERED"),
        .power_up_high("OFF"), .width(1)
    ) clock_out (
        .datain_h(1'b0), .datain_l(1'b1), .outclock(clk), .dataout(SDRAM_CLK),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0));
    always @(posedge clk) dq_in <= SDRAM_DQ;

    // address fields of a word address
    function automatic [9:0] col_of(input [23:0] w); col_of = {w[23], w[7:0], 1'b0}; endfunction  // {A9, A8..A0}
    function automatic [12:0] row_of(input [23:0] w); row_of = w[20:8]; endfunction
    function automatic [1:0] bank_of(input [23:0] w); bank_of = w[22:21]; endfunction
    function automatic [12:0] col_a(input [9:0] c, input ap);   // column address with A10 = auto-precharge
        col_a = {2'b00, ap, c[9], c[8:0]};
    endfunction

    // ------------------------------------------------------- read capture
    // A READ issued at edge e has beat 0 in dq_in after e+RD_LAT-1 and beat 1
    // one edge later: rd_tag[RD_LAT] marks the edge that takes beat 0,
    // rd_tag[RD_LAT+1] the one that completes the word.
    localparam integer RDL = RD_LAT + (OUT_REG != 0 ? 1 : 0);   // (OUT_REG: the READ reaches the pins a clock later)
    reg [RDL+1:0] rd_tag = 0;
    reg [RDL+1:0] rd_end = 0;               // the tag of a request's last READ
    reg [15:0] low_half = 0;

    // ------------------------------------------------------------- engine
    localparam [2:0] S_INIT = 0, S_IDLE = 1, S_RD = 2, S_WR = 3, S_CH = 4, S_GAP = 5;
    reg [2:0]  st = S_INIT;
    localparam [4:0] POWER_TICKS = 5'(POWERUP_CYCLES / (REFRESH_CYCLES + 1) + 1);   // the wait, in ref_timer's periods
    reg [4:0]  init_step = 0;
    reg        power_done = 0;
    reg [10:0] ref_timer = 0;
    reg [1:0]  ref_owed = 0;
    assign ref_late = ref_owed > 2'd1;
    reg [23:0] q_addr = 0;                  // the access's next word
    reg [3:0]  q_left = 0;                  // read words still to issue
    reg [31:0] q_wdata = 0;
    reg [3:0]  q_be = 0;
    reg [2:0]  step = 0;
    // step == 1, step == 2, step != 0 as registers, set with step (#845:
    // step -> a[9] -1.102 ns: a's enable and select decode step)
    reg        st1 = 0, st2 = 0, stn = 0;
    reg [3:0]  gap = 0;                     // clocks before the next ACTIVE/REFRESH
    reg [5:0]  chain_n = 0;
    reg        ch_hi = 0;                   // chain: the word's high half goes next
    // chain: the word after the one consumed, and whether it is in the same
    // bank and row, worked out when that word was consumed (so the chain's
    // end decision at the high half compares registers with the FIFO head:
    // A10 is an I/O register, #341/#343 -0.020/-0.044 ns through the adder)
    reg [7:0]  q_inc = 0;                   // chain: the next word's column bits (the row is q_addr's while q_row)
    reg        q_row = 0;
    // OPEN: each bank's open row, and the clocks since the last READ (a PRECHARGE waits out its burst)
    reg [3:0]  ob_v = 0;
    (* ramstyle = "MLAB, no_rw_check" *) reg [12:0] ob_row [0:3];
    reg [2:0]  rd_age = 0;                  // 5 after a READ: a PRECHARGE at <= 3 (out of its burst), a write at 0 (data off the bus)
    reg [2:0]  act_age = 0;                 // clocks since the last ACTIVE (saturating): a PRECHARGE at >= 5 (tRAS)
    wire       pre_ok = rd_age <= 3'd3 && act_age >= 3'd5;
    wire [1:0] cb = c_rb[14:13];
    wire       c_hit  = OPEN != 0 && ob_v[cb] && ob_row[cb] == c_rb[12:0] && !c_we;
    wire       c_conf = OPEN != 0 && ob_v[cb] && !c_hit;                // the bank holds another row (or a write)
    // the decision registered (#969: g -> c_rb -> the row compare -> a[10], -2.046 ns): hit_q/conf_q are last
    // clock's, used only if the request was there then and IDLE issued nothing that moved ob_* (dv_q)
    reg        hit_q = 0, conf_q = 0, dv_q = 0;
    wire       d_hit  = dv_q && hit_q;
    wire       d_conf = dv_q && conf_q;
    wire [1:0] wb = bank_of(bw_addr);

    // the chain's head is consumed with its low half; the next head is there
    // (or not) during the high half, which decides whether the chain goes on
    assign bw_read = !init && st == S_CH && stn && !ch_hi;
    always @(posedge clk) begin
        cmd <= C_NOP; dq_oe <= 1'b0; dqm <= 2'b00;
        c_ready <= 1'b0; r_valid <= 1'b0; r_last <= 1'b0;
        rd_tag <= {rd_tag[RDL:0], 1'b0};
        rd_end <= {rd_end[RDL:0], 1'b0};
        if (rd_tag[RDL]) low_half <= dq_in;
        if (rd_tag[RDL+1]) begin r_valid <= 1'b1; r_data <= {dq_in, low_half}; r_last <= rd_end[RDL+1]; end
        if (ref_timer != 0) ref_timer <= ref_timer - 1'b1;
        else if (ready || !power_done) begin ref_timer <= REFRESH_CYCLES[10:0]; if (ready && ref_owed != 2'd3) ref_owed <= ref_owed + 1'b1; end
        if (gap != 0) gap <= gap - 1'b1;
        if (rd_age != 0) rd_age <= rd_age - 1'b1;
        hit_q <= c_hit; conf_q <= c_conf; dv_q <= c_valid;
        if (act_age != 3'd7) act_age <= act_age + 1'b1;
        if (cmd == C_ACT) act_age <= 3'd1;

        if (init) begin
            st <= S_INIT; ready <= 1'b0; power_done <= 1'b0; init_step <= 0; st1 <= 1'b0; st2 <= 1'b0; stn <= 1'b0;
            rd_tag <= 0; rd_end <= 0; ref_owed <= 0; gap <= 0; ob_v <= 0; rd_age <= 0;
        end else case (st)
            S_INIT: if (!power_done) begin
                if (ref_timer == 0) begin
                    init_step <= init_step + 1'b1;
                    if (init_step == POWER_TICKS) begin init_step <= 0; power_done <= 1'b1; end
                end
            end else begin
                init_step <= init_step + 1'b1;
                case (init_step)
                    0:  begin cmd <= C_PRE; a <= 13'h0400; end                  // all banks
                    3:  cmd <= C_REF;
                    13: cmd <= C_REF;
                    23: begin cmd <= C_MRS; a <= 13'h0231; ba <= 2'b00; end      // BL2, CL3, single writes
                    27: begin ready <= 1'b1; st <= S_IDLE; ref_timer <= REFRESH_CYCLES[10:0]; ref_owed <= 0; end
                    default: ;
                endcase
            end
            S_IDLE: if (gap == 0) begin
                if (OPEN != 0 && ref_owed != 0 && ob_v != 0) begin
                    // OPEN: a refresh needs every bank closed
                    if (pre_ok) begin cmd <= C_PRE; a <= 13'h0400; ob_v <= 4'd0; gap <= 4'd2; dv_q <= 1'b0; end   // all banks, tRP
                end else if (ref_owed != 0) begin
                    cmd <= C_REF; ref_owed <= ref_owed - 1'b1; gap <= 4'd9;      // tRFC
                end else if (OPEN != 0 && bw_valid && !c_valid && ob_v[wb]) begin
                    // OPEN: the chain's bank holds an open row: close it first
                    if (pre_ok) begin cmd <= C_PRE; ba <= wb; a <= 13'h0000; ob_v[wb] <= 1'b0; gap <= 4'd2; dv_q <= 1'b0; end
                end else if (OPEN != 0 && c_valid && !dv_q) begin
                    // OPEN: the request's hit/conflict decision is registered this clock
                end else if (OPEN != 0 && c_valid && d_conf) begin
                    if (pre_ok) begin cmd <= C_PRE; ba <= cb; a <= 13'h0000; ob_v[cb] <= 1'b0; gap <= 4'd2; dv_q <= 1'b0; end
                end else if (OPEN != 0 && c_valid && d_hit) begin
                    // OPEN: the row is open: the READs start next clock, gapless after the last request's
                    ba <= cb;
                    q_addr <= c_addr; q_left <= c_n; step <= 3'd1; st1 <= 1'b1; st2 <= 1'b0; stn <= 1'b1;
                    c_ready <= 1'b1; st <= S_RD; dv_q <= 1'b0;
                end else if (OPEN != 0 && (bw_valid && !c_valid || c_valid && c_we) && rd_age != 0) begin
                    // OPEN: a write's ACTIVE waits for the last READ's data to leave the bus (as gap did)
                end else if (bw_valid && !c_valid) begin
                    // write chain: ACTIVE now, WRITEs from two clocks on. A
                    // waiting port goes first: the ring's blocks keep the
                    // FIFO refilled, so the chain would otherwise hold the
                    // SDRAM chain after chain and starve port 0's video
                    // reads (chain3 mkds-race: 42 underruns, 0 with this)
                    cmd <= C_ACT; ba <= bank_of(bw_addr); a <= row_of(bw_addr);
                    q_addr <= bw_addr; chain_n <= 0; ch_hi <= 1'b0; step <= 0; st1 <= 1'b0; st2 <= 1'b0; stn <= 1'b0; st <= S_CH;
                end else if (c_valid) begin
                    // bank and row from the bus's copy taken at the grant
                    // (c_addr is a port mux on g: #845 g -> a[9] -0.985 ns)
                    cmd <= C_ACT; ba <= c_rb[14:13]; a <= c_rb[12:0];
                    if (OPEN != 0 && !c_we) begin ob_v[cb] <= 1'b1; ob_row[cb] <= c_rb[12:0]; end
                    dv_q <= 1'b0;
                    q_addr <= c_addr; q_left <= c_n; q_wdata <= c_wdata; q_be <= c_be; step <= 0; st1 <= 1'b0; st2 <= 1'b0; stn <= 1'b0;
                    c_ready <= 1'b1;
                    st <= c_we ? S_WR : S_RD;
                end
            end
            S_RD: begin
                // tRCD, then a READ every 2 clocks; the last auto-precharges
                step <= step + 1'b1; st1 <= step == 3'd0; st2 <= step == 3'd1; stn <= step != 3'd7;
                if (step[0]) begin
                    cmd <= C_READ; a <= col_a(col_of(q_addr), OPEN == 0 && q_left == 4'd1);
                    rd_tag[0] <= 1'b1; rd_end[0] <= q_left == 4'd1;
                    q_addr[7:0] <= q_addr[7:0] + 1'b1; q_left <= q_left - 1'b1;   // (the column bits; a read stays in its row)
                    if (OPEN != 0) rd_age <= 3'd5;
                    // (OPEN: the row stays open, so the next READ may come a clock after IDLE: gapless)
                    if (q_left == 4'd1) begin st <= S_IDLE; gap <= OPEN != 0 ? 4'd0 : 4'd5; end    // burst end + tRP
                end
            end
            S_WR: begin
                step <= step + 1'b1; st1 <= step == 3'd0; st2 <= step == 3'd1; stn <= step != 3'd7;
                if (st1) begin
                    cmd <= C_WRITE; a <= col_a(col_of(q_addr), 1'b0);
                    dq_oe <= 1'b1; dq_out <= q_wdata[15:0]; dqm <= ~q_be[1:0];
                end else if (st2) begin
                    cmd <= C_WRITE; a <= col_a(col_of(q_addr) | 10'd1, 1'b1);
                    dq_oe <= 1'b1; dq_out <= q_wdata[31:16]; dqm <= ~q_be[3:2];
                    st <= S_IDLE; gap <= 4'd4;                                    // tWR + tRP
                end
            end
            default: begin   // S_CH: halves of the chain's words, back to back
                step <= step + 1'b1; st1 <= step == 3'd0; st2 <= step == 3'd1; stn <= step != 3'd7;
                if (stn) begin
                    logic last;
                    // the chain ends after a high half when the next word is
                    // not there, is in another row, the chain is full, or the
                    // video port waits (its line deadline; other ports wait
                    // the chain out, so the ring's writes keep moving)
                    last = ch_hi && (!bw_valid || !q_row || bw_addr != {q_addr[23:8], q_inc}
                                     || chain_n == CHAIN[5:0] - 1'b1 || ref_owed != 0 || c_hurry);
                    cmd <= C_WRITE; dq_oe <= 1'b1; dqm <= 2'b00;
                    a <= col_a(col_of(ch_hi ? q_addr : bw_addr) | {9'd0, ch_hi}, last);
                    dq_out <= ch_hi ? q_wdata[31:16] : bw_data[15:0];
                    if (!ch_hi) begin
                        q_addr <= bw_addr; q_wdata <= bw_data;
                        // bw_addr + 1 stays in bw_addr's bank and row unless
                        // the carry leaves bits 7:0
                        q_inc <= bw_addr[7:0] + 1'b1; q_row <= bw_addr[7:0] != 8'hFF;
                    end else chain_n <= chain_n + 1'b1;
                    ch_hi <= !ch_hi;
                    if (last) begin st <= S_IDLE; gap <= 4'd4; end
                end
            end
        endcase
    end
`ifndef ALTERA_RESERVED_QIS
    always @(posedge clk)
        if (!init && (st1 != (step == 3'd1) || st2 != (step == 3'd2) || stn != (step != 3'd0)))
            $display("nds_sdram_mc: ERROR: the step flags (%b%b%b) are not step %0d's", st1, st2, stn, step);
`endif
endmodule
`default_nettype wire
