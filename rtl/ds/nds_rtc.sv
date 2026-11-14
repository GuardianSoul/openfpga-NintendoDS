// ARM7 RTC register 0x04000138 and the Seiko S-35180 behind it, after
// melonDS's RTC (behaviour only) and GBATEK "DS Real-Time Clock (RTC)".
//
// The register keeps the low 8 written bits (the high byte has no function and
// reads 0, docs/ds-rules.md). While CS (bit 2) stays high, every
// write with SCK (bit 1) low clocks one bit, LSB first: with bit 4 set the
// bit in bit 0 goes to the chip, otherwise the chip's next output bit lands
// in bit 0 (and bit 0 of the written value is ignored). A write that raises
// CS starts a transfer. 8-bit writes reach 0x138 only (0x139 is ignored, as
// in melonDS). The first byte is the command: 0110 + register number with
// bit order reversed, or the register form `rrrr0110` (bit 7 = read)
// directly. Registers: status 1 and 2, date+time (7 bytes), time (3), INT1
// (1 or 3 bytes by status 2 bit 2), INT2 (3), clock adjust, free register;
// written date and time fields are masked and sanitized as the DS does
// (rtcprobe v1, 2026-11-12, R121; after Jello's port of melonDS's
// WriteDateTime, GuardianSoul/openfpga-NintendoDS PR 7): a bad BCD digit or a
// value out of range becomes the field's minimum (year 00, month 01, day 01,
// weekday 0, hour and minute 00), except the second, which keeps any valid
// BCD value (the DS reads a written 60 back as 60); a day past the month's end
// becomes 01 and carries into the month (and year). The clock counts a
// canonical 24-hour hour; status 1's 12/24-hour bit converts the hour on
// writes and reads (12-hour: 00-11 plus the PM bit, 0x40; an invalid 12-hour
// hour is 00 with no PM bit, as on the DS). The hour's PM bit reads as the
// hour's (>= 12) in both modes, as the DS shows it.
//
// Not modelled: interrupts (INT1/INT2 settings and the alarm registers are
// stored and read back, but nothing fires and status 1 bits 4-6 stay 0),
// DSi registers, the reset values after power loss of a real chip. Output
// bytes come from the live registers rather than a copy taken at the
// command; the second count instead waits while CS is high (one pending
// second is kept), so a read sees one consistent time. Status 1 read clears
// its bit 7 (power-on) when CS drops.
//
// Area: seconds, minutes, day, day of week, status 2, clock adjust, the free
// register and both alarms live in a 16-byte RAM (one MLAB; M10K is the
// scarce block on the chip); year, month, hour and pm stay in flops (a
// written day and the 12/24-hour switch need them inside a transfer). The
// second count runs one field per clock (up to 5) and only while CS is low,
// the reset command clears the RAM over 16 clocks (all done before the next
// field access can come: a command byte is 16 register writes); a second
// due during a clear or a count waits (up to two are held). Behaviour is the
// same as the all-flop version (b4eb578), cycle for cycle at the register,
// for accesses at least 3 clocks apart (nds_fabric's IO path takes 4)
// (docs/archive/mlab-tables.md: sim/ds_dev/equiv/rtc_eq.sh).
//
// Time: the boot program sets it (sw/boot/boot7.s rtcset, 2026-10-28): it
// reads the APF bridge's date and time from core registers 0xF20/0xF24 and
// writes them through this register as a game would (date+time command,
// the day of week computed with 0 = Sunday as melonDS's SetDateTime), then
// reads status 1 (clearing the power-on bit). Until then the chip is as
// after a reset command (2000-01-01 00:00:00). The hardware load from the
// bridge (day of week, 12-hour form, the field copies) is gone: area (room
// sprint, about a quarter of the module). Seconds count SEC_TICKS DS system
// clocks (33,513,982 Hz; melonDS divides it to 32768 Hz with an error
// accumulator, the same average), from reset.
module nds_rtc #(
    parameter int SEC_TICKS = 33513982
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        tick,
    input  logic        io_req,
    input  logic        io_we,
    input  logic [3:0]  io_be,
    input  logic [31:0] io_wdata,
    output logic [31:0] io_rdata
);
    // ---- BCD helpers. Increment digit by digit: melonDS's BCDIncrement for
    // valid BCD, the only values the registers can hold (99 wraps to 00).
    function automatic logic [7:0] binc(input logic [7:0] v);
        if (v[3:0] != 4'h9) return {v[7:4], v[3:0] + 4'd1};
        return {v[7:4] == 4'h9 ? 4'h0 : v[7:4] + 4'd1, 4'h0};
    endfunction
    function automatic logic leap(input logic [7:0] y);   // 2000-2099
        return y[4] ? (y[3:0] == 4'h2 || y[3:0] == 4'h6)
                    : (y[3:0] == 4'h0 || y[3:0] == 4'h4 || y[3:0] == 4'h8);
    endfunction
    function automatic logic [7:0] dim(input logic [4:0] m, input logic lp);
        case (m)
            5'h01, 5'h03, 5'h05, 5'h07, 5'h08, 5'h10, 5'h12: return 8'h31;
            5'h04, 5'h06, 5'h09, 5'h11:                      return 8'h30;
            5'h02:   return lp ? 8'h29 : 8'h28;
            default: return 8'h00;
        endcase
    endfunction

    // A bad BCD digit or a value outside lo..hi gives lo (after the field's mask)
    function automatic logic [7:0] sanitize(input logic [7:0] v, input logic [7:0] lo, input logic [7:0] hi);
        return (v[3:0] > 4'd9 || v[7:4] > 4'd9 || v < lo || v > hi) ? lo : v;
    endfunction
    // a written hour to the canonical 24-hour BCD hour: 12-hour mode adds 12 with the PM bit (BCD: +0x12, or +0x18
    // when the low digit is 8 or 9); an invalid hour is 00 without the PM bit (DS rtcprobe: 59 in 12-hour mode -> 00)
    function automatic logic [5:0] hour24(input logic [7:0] v, input logic mode24);
        logic [7:0] h;
        logic       bad;
        h = v & 8'h3f;
        bad = h[3:0] > 4'd9 || h > (mode24 ? 8'h23 : 8'h11);
`ifdef RTC_SAN_MUT2
        if (bad) h = 8'h00;                             // (mutant: the PM bit still adds 12 to an invalid hour)
        if (!mode24 && v[6]) h = h + (h[3:0] >= 4'd8 ? 8'h18 : 8'h12);
`else
        if (bad) h = 8'h00;
        else if (!mode24 && v[6]) h = h + (h[3:0] >= 4'd8 ? 8'h18 : 8'h12);
`endif
        return h[5:0];
    endfunction
    // the canonical hour as a 12-hour read shows it (BCD -12: -0x12, or -0x18 when the low digit is 0 or 1)
    function automatic logic [5:0] hour12(input logic [5:0] h);
        return h >= 6'h12 ? h - (h[3:0] < 4'd2 ? 6'h18 : 6'h12) : h;
    endfunction

    // ---- state
    logic [7:0]  io;
    // the year, month and hour are RAM bytes too (R_YR, R_MO, R_HR; RC11 card 3b room: they were 19 flops with a
    // second BCD incrementer); the day's end of month needs the month and the year's leap bit, read and latched
    // ahead of the day (mo_l, lp) in the count; a date write latches its own month and the year's leap bit there
    // too, for the written day's end of month (no count runs inside a transfer: counts start with CS low)
    logic [4:0]  mo_l;
    logic        lp;
    logic        poc;           // status 1 bit 7
    logic [3:1]  s1;            // status 1 bits 3:1 (bit 1: 24-hour mode)
    logic        s2_2;          // status 2 bit 2 (INT1 layout), a copy of the RAM's
    // RAM: 0 second, 1 minute, 2 day, 3 day of week, 4 status 2, 5 clock
    // adjust, 6 free, 7 year, 8-10 INT1 alarm, 11 month (5 bits), 12-14 INT2 alarm, 15 hour (6 bits)
    localparam logic [3:0] R_SE = 4'd0, R_MI = 4'd1, R_DY = 4'd2, R_DW = 4'd3, R_S2 = 4'd4,
                           R_ADJ = 4'd5, R_FRE = 4'd6, R_YR = 4'd7, R_AL1 = 4'd8, R_MO = 4'd11, R_AL2 = 4'd12,
                           R_HR = 4'd15;
    logic        rm_we;
    logic [3:0]  rm_wa, rm_ra;
    logic [7:0]  rm_wd, rq;
    (* ramstyle = "M10K" *) logic [7:0] rm [0:15];   // (M10K: the chip is short of LABs)
    // sequences: the second count (K_*), the reset clear; every field a RAM byte, one BCD incrementer (k_inc)
    // on the byte read in the step before: second, minute, hour, then on a new day the month and year read
    // for the month's length (K_MOR, K_YRR), day of week, day, month, year
    // K_DCR: a written day past the month's end reads the month for the carry (then K_MOW, K_YRW as the count's)
    typedef enum logic [3:0] { K_IDLE, K_SE, K_SEW, K_MIW, K_DWW, K_DYW, K_CLR,
                               K_HRW, K_MOR, K_YRR, K_MOW, K_YRW, K_DCR } kst_t;
    kst_t        ks;
    logic [3:0]  kc;            // clear step
    logic [6:0]  in_b;
    logic [2:0]  in_bit, out_bit, out_pos;
    logic [3:0]  in_pos;        // saturates at 8
    logic        c_ok, c_rd;    // command received; read command
    logic [2:0]  c_reg;
    // the second: a 25-bit maximal LFSR (x^25 + x^22 + 1, period 2^25 - 1)
    // instead of a binary counter, so no adder. It starts at SC0 and the
    // second is due at SC_END, the state SEC_TICKS - 1 steps later: the same
    // count. SC_END is found at elaboration by jumping ahead with GF(2)
    // matrix powers.
    logic [24:0] sc;
    localparam logic [24:0] SC0 = 25'd1;
    function automatic logic [24:0] sc_step(input logic [24:0] x);
        return {x[23:0], x[24] ^ x[21]};
    endfunction
    function automatic logic [24:0] sc_jump(input int unsigned k, input logic [24:0] s0);
        logic [24:0] a [25], r [25], t [25];
        logic [24:0] v;
        for (int i = 0; i < 25; i++) begin a[i] = '0; r[i] = 25'd1 << i; end
        a[0] = (25'd1 << 24) | (25'd1 << 21);           // row i: the bits that XOR into bit i
        for (int i = 1; i < 25; i++) a[i] = 25'd1 << (i - 1);
        while (k != 0) begin
            if (k[0]) begin                             // r = a * r
                for (int i = 0; i < 25; i++) begin
                    t[i] = '0;
                    for (int j = 0; j < 25; j++) if (a[i][j]) t[i] = t[i] ^ r[j];
                end
                for (int i = 0; i < 25; i++) r[i] = t[i];
            end
            for (int i = 0; i < 25; i++) begin          // a = a * a
                t[i] = '0;
                for (int j = 0; j < 25; j++) if (a[i][j]) t[i] = t[i] ^ a[j];
            end
            for (int i = 0; i < 25; i++) a[i] = t[i];
            k = k >> 1;
        end
        for (int i = 0; i < 25; i++) v[i] = ^(r[i] & s0);
        return v;
    endfunction
    localparam logic [24:0] SC_END = sc_jump(SEC_TICKS - 1, SC0);
    logic        pend;

    // ---- register write decode
    wire        wr     = io_req && io_we && io_be[0];
    wire [7:0]  val    = io_wdata[7:0];
    wire        start  = wr && val[2] && !io[2];
    wire        stop   = wr && !val[2] && io[2];
    wire        clk_lo = wr && val[2] && io[2] && !val[1];
    wire        ibit   = clk_lo && val[4];
    wire        rbit   = clk_lo && !val[4];
    wire [7:0]  ib     = {1'b0, in_b} | ({7'd0, val[0]} << in_bit);
    wire        byte_in = ibit && in_bit == 3'd7;
    wire        cmd_in = byte_in && in_pos == 4'd0;
    wire        dat_in = byte_in && in_pos != 4'd0 && c_ok;
    wire [7:0]  cmd    = ib[7:4] == 4'h6 ? {ib[0], ib[1], ib[2], ib[3], 4'h6} : ib;
    wire        p1     = in_pos == 4'd1;
    wire        xfer   = c_ok && c_rd;   // read command received

    // date/time field this byte would write: 1 year .. 7 second. fld_r
    // leaves out dat_in (and so the I/O request): the RAM's write data and
    // address follow from it, and only its enable waits for the request
    // (timing: #455/#463, nds_fabric's address into rw_d)
    logic [2:0] fld_r;
    always_comb begin
        fld_r = 3'd0;
        if (c_reg == 3'd2 && in_pos <= 4'd7) fld_r = in_pos[2:0];
        if (c_reg == 3'd6 && in_pos <= 4'd3) fld_r = in_pos[2:0] + 3'd4;
    end
    wire [2:0] fld = dat_in ? fld_r : 3'd0;

    // ---- output byte: flops, or the RAM byte at ob_a (rq, addressed while idle)
    logic [7:0] ob0, obf;
    logic [3:0] ob_a;
    logic       ob_ram;
    always_comb begin
        obf = 8'h00; ob_a = R_SE; ob_ram = 1'b0;
        if (xfer) case (c_reg)
            3'd0: if (out_pos == 3'd0) obf = {poc, 3'd0, s1, 1'b0};
            3'd4: if (out_pos == 3'd0) begin ob_ram = 1'b1; ob_a = R_S2; end
            3'd2: case (out_pos)
                3'd0: begin ob_ram = 1'b1; ob_a = R_YR; end
                3'd1: begin ob_ram = 1'b1; ob_a = R_MO; end
                3'd2: begin ob_ram = 1'b1; ob_a = R_DY; end
                3'd3: begin ob_ram = 1'b1; ob_a = R_DW; end
                3'd4: begin ob_ram = 1'b1; ob_a = R_HR; end
                3'd5: begin ob_ram = 1'b1; ob_a = R_MI; end
                3'd6: begin ob_ram = 1'b1; ob_a = R_SE; end
                default: ;
            endcase
            3'd6: case (out_pos)
                3'd0: begin ob_ram = 1'b1; ob_a = R_HR; end
                3'd1: begin ob_ram = 1'b1; ob_a = R_MI; end
                3'd2: begin ob_ram = 1'b1; ob_a = R_SE; end
                default: ;
            endcase
            3'd1: if (s2_2) begin if (out_pos < 3'd3) begin ob_ram = 1'b1; ob_a = R_AL1 + {2'd0, out_pos[1:0]}; end end
                  else if (out_pos == 3'd0) begin ob_ram = 1'b1; ob_a = R_AL1 + 4'd2; end
            3'd5: if (out_pos < 3'd3) begin ob_ram = 1'b1; ob_a = R_AL2 + {2'd0, out_pos[1:0]}; end
            3'd3: if (out_pos == 3'd0) begin ob_ram = 1'b1; ob_a = R_ADJ; end
            3'd7: if (out_pos == 3'd0) begin ob_ram = 1'b1; ob_a = R_FRE; end
        endcase
        // (the hour byte with its PM bit, bit 6, as the chip reads it out; 12-hour mode (status 1 bit 1 clear) reads
        // the hour as 00-11)
`ifdef RTC_RAM_MUT
        ob0 = ob_ram ? (ob_a == R_HR ? {1'b0, rq[5:0] > 6'h12, s1[1] ? rq[5:0] : hour12(rq[5:0])} : rq) : obf;   // (mutant: noon read as AM)
`else
        ob0 = ob_ram ? (ob_a == R_HR ? {1'b0, rq[5:0] >= 6'h12, s1[1] ? rq[5:0] : hour12(rq[5:0])} : rq) : obf;
`endif
    end

    // ---- one second later (melonDS's CountSecond chain), one field per step:
    // each step writes the field read in the step before (rq) and reads the
    // next: second, minute (if the second wrapped), day of week and day (if
    // the hour wrapped the day)
    wire [7:0] k_inc = binc(rq);
    wire        n_day = k_inc == 8'h24;  // the hour when the minute wraps (K_HRW)
    // end of month for the counted day
    // (a count never runs while a data byte comes in: a byte takes 16
    // register writes, a count at most 11 clocks, and counts start with CS low)
    wire       eom    = k_inc > dim(mo_l, lp);          // the counted day (K_DYW)
    wire       yr_inc = k_inc == 8'h13;                 // in K_MOW

    wire [7:0] ob = ob0;



    // ---- RAM ports: the second count and the clear sequence, else the
    // field writes of a command; reads follow the output byte while idle
    logic [3:0] dat_a;                  // RAM byte a command data byte writes
    logic [7:0] dat_d;
    logic       dat_wr;                 // the byte would write (dat_w without dat_in)
    // the written date's sanitized fields; the day against its month's end (mo_l, lp latched from this write)
    wire [7:0]  yr_in = sanitize(ib, 8'h00, 8'h99);
    wire [7:0]  mo_in = sanitize(ib & 8'h1f, 8'h01, 8'h12);
    wire [7:0]  dy_in = sanitize(ib & 8'h3f, 8'h01, 8'h31);
    wire        dy_carry = dy_in > dim(mo_l, lp);
    always_comb begin
        dat_wr = 1'b0; dat_a = R_SE; dat_d = ib;
        case (c_reg)
            3'd4: if (p1) begin dat_wr = 1'b1; dat_a = R_S2; end
            3'd1: if (s2_2) begin if (in_pos <= 4'd3) begin dat_wr = 1'b1; dat_a = R_AL1 + {2'd0, in_pos[1:0] - 2'd1}; end end
                  else if (p1) begin dat_wr = 1'b1; dat_a = R_AL1 + 4'd2; end
            3'd5: if (in_pos <= 4'd3) begin dat_wr = 1'b1; dat_a = R_AL2 + {2'd0, in_pos[1:0] - 2'd1}; end
            3'd3: if (p1) begin dat_wr = 1'b1; dat_a = R_ADJ; end
            3'd7: if (p1) begin dat_wr = 1'b1; dat_a = R_FRE; end
            default: ;
        endcase
        case (fld_r)
            3'd1: begin dat_wr = 1'b1; dat_a = R_YR; dat_d = yr_in; end
            3'd2: begin dat_wr = 1'b1; dat_a = R_MO; dat_d = mo_in; end
            3'd5: begin dat_wr = 1'b1; dat_a = R_HR; dat_d = {2'd0, hour24(ib, s1[1])}; end
            3'd3: begin dat_wr = 1'b1; dat_a = R_DY; dat_d = dy_carry ? 8'h01 : dy_in; end
            3'd4: begin dat_wr = 1'b1; dat_a = R_DW; dat_d = sanitize(ib & 8'h07, 8'h00, 8'h06); end
            3'd6: begin dat_wr = 1'b1; dat_a = R_MI; dat_d = sanitize(ib & 8'h7f, 8'h00, 8'h59); end
`ifdef RTC_SAN_MUT1
            3'd7: begin dat_wr = 1'b1; dat_a = R_SE; dat_d = sanitize(ib & 8'h7f, 8'h00, 8'h59); end   // (mutant: melonDS's range)
`else
            // the second keeps any valid BCD value: the DS reads a written 60 back as 60 (rtcprobe v1)
            3'd7: begin dat_wr = 1'b1; dat_a = R_SE; dat_d = sanitize(ib & 8'h7f, 8'h00, 8'h79); end
`endif
            default: ;
        endcase
    end
    wire dat_w = dat_in && dat_wr;
    // a second due while CS is low is committed then (as the all-flop
    // version counts it then) and counted as soon as the sequencer is free;
    // k_n holds up to two (a held second and the next one, during a clear)
    logic [1:0] k_n;
    wire k_rel = pend && !io[2];
    wire k_start = (k_n != 2'd0 || k_rel) && ks == K_IDLE;
    // the command's byte (dat_*) or the sequence's (rm_wa/rm_wd): rm_sel,
    // the one choice that waits for the I/O request, is registered beside
    // both and applied after the registers
    wire rm_sel = !(ks == K_SEW || ks == K_MIW || ks == K_HRW || ks == K_DWW || ks == K_DYW || ks == K_MOW || ks == K_YRW || ks == K_CLR);
    always_comb begin
        rm_we = 1'b0; rm_wa = dat_a; rm_wd = dat_d;
        rm_ra = ob_a;
        case (ks)
            K_SE: rm_ra = R_SE;
            K_SEW: begin rm_we = 1'b1; rm_wa = R_SE; rm_wd = k_inc == 8'h60 ? 8'h00 : k_inc; rm_ra = R_MI; end
            K_MIW: begin rm_we = 1'b1; rm_wa = R_MI; rm_wd = k_inc == 8'h60 ? 8'h00 : k_inc; rm_ra = R_HR; end
            K_HRW: begin rm_we = 1'b1; rm_wa = R_HR; rm_wd = n_day ? 8'h00 : k_inc; rm_ra = R_MO; end
            K_MOR: rm_ra = R_YR;            // (mo_l takes the month)
            K_YRR: rm_ra = R_DW;            // (lp takes the year's leap bit)
            K_DWW: begin rm_we = 1'b1; rm_wa = R_DW; rm_wd = {5'd0, rq[2:0] >= 3'd6 ? 3'd0 : rq[2:0] + 3'd1}; rm_ra = R_DY; end
            K_DYW: begin rm_we = 1'b1; rm_wa = R_DY; rm_wd = eom ? 8'h01 : k_inc; rm_ra = R_MO; end
            K_MOW: begin rm_we = 1'b1; rm_wa = R_MO; rm_wd = yr_inc ? 8'h01 : {3'd0, k_inc[4:0]}; rm_ra = R_YR; end
            K_YRW: begin rm_we = 1'b1; rm_wa = R_YR; rm_wd = k_inc; end
            K_DCR: rm_ra = R_MO;            // (a written day's carry: the month, then K_MOW)
            K_CLR: begin rm_we = 1'b1; rm_wa = kc; rm_wd = (kc == R_DY || kc == R_MO) ? 8'h01 : 8'h00; end
            default: rm_we = dat_w;
        endcase
    end

    // Writes land a clock after rm_* (registered: the write decode starts
    // at the I/O request, nds_fabric's address, #455 -1.25 ns). Nothing reads
    // a byte in the clock after writing it: a command's field writes and
    // the reads of a field are separate transfers, each count step writes
    // one field and reads another.
    logic        rw_v, rw_sel;
    logic [3:0]  rw_a, rw_ca;
    logic [7:0]  rw_d, rw_cd;
    always_ff @(posedge clk) begin
        rw_v <= rm_we; rw_sel <= rm_sel;
        rw_a <= rm_wa; rw_d <= rm_wd; rw_ca <= dat_a; rw_cd <= dat_d;
        if (rw_v) rm[rw_sel ? rw_ca : rw_a] <= rw_sel ? rw_cd : rw_d;
        rq <= rm[rm_ra];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            io <= '0;
            poc <= 1'b1; s1 <= 3'b001; s2_2 <= 1'b0;
            in_b <= '0; in_bit <= '0; out_bit <= '0; out_pos <= '0; in_pos <= '0;
            c_ok <= 1'b0; c_rd <= 1'b0; c_reg <= '0;
            sc <= SC0; pend <= 1'b0; k_n <= '0; io_rdata <= '0;
            ks <= K_CLR; kc <= '0;   // the RAM starts as after a reset command
        end else begin
            io_rdata <= {24'd0, io};

            // seconds: counted while CS is low, held as one pending second otherwise
            case (ks)
                K_IDLE: if (k_start) ks <= K_SE;
                K_SE:  ks <= K_SEW;
                K_SEW: ks <= k_inc == 8'h60 ? K_MIW : K_IDLE;
                K_MIW: ks <= k_inc == 8'h60 ? K_HRW : K_IDLE;
                K_HRW: ks <= n_day ? K_MOR : K_IDLE;
                K_MOR: begin mo_l <= rq[4:0]; ks <= K_YRR; end
                K_YRR: begin lp <= leap(rq); ks <= K_DWW; end
                K_DWW: ks <= K_DYW;
                K_DYW: ks <= eom ? K_MOW : K_IDLE;
                K_MOW: ks <= yr_inc ? K_YRW : K_IDLE;
                K_YRW: ks <= K_IDLE;
                K_DCR: ks <= K_MOW;
                K_CLR: begin
                        kc <= kc + 4'd1;
                        if (kc == 4'd15) ks <= K_IDLE;
                    end
                default: ks <= K_IDLE;
            endcase
            if (k_rel) pend <= 1'b0;
            k_n <= k_n + {1'b0, k_rel} - {1'b0, k_start};
            if (tick) begin
                if (sc == SC_END) begin sc <= SC0; pend <= 1'b1; end
                else sc <= sc_step(sc);
            end

            // register and serial protocol
            if (wr) io <= val[4] ? val : {val[7:1], rbit ? ob[out_bit] : io[0]};
            if (start) begin
                in_b <= '0; in_bit <= '0; in_pos <= '0; out_bit <= '0; out_pos <= '0; c_ok <= 1'b0;
            end
            if (stop && c_ok && c_rd && c_reg == 3'd0 && in_pos != 4'd0) poc <= 1'b0;
            if (rbit) begin
                out_bit <= out_bit + 3'd1;
                if (out_bit == 3'd7 && out_pos != 3'd7) out_pos <= out_pos + 3'd1;
            end
            if (ibit) begin
                in_b <= ib[6:0];
                in_bit <= in_bit + 3'd1;
                if (in_bit == 3'd7) begin
                    in_b <= '0;
                    if (in_pos != 4'd8) in_pos <= in_pos + 4'd1;
                end
            end
            if (cmd_in) begin
                c_ok <= cmd[3:0] == 4'h6; c_rd <= cmd[7]; c_reg <= cmd[6:4];
            end

            // command writes (melonDS's CmdWrite: the read bit is not checked);
            // RAM bytes through rm_* above
            if (dat_in) case (c_reg)
                3'd0: if (p1) begin
                    s1 <= ib[3:1];
                    if (ib[0]) begin
                        poc <= 1'b0; s2_2 <= 1'b0;
                        ks <= K_CLR; kc <= '0;
                        k_n <= '0;   // a second committed before this was counted, then cleared
                    end
                end
                3'd4: if (p1) s2_2 <= ib[2];
                default: ;
            endcase
            // the date's month and leap year for the written day's end of month, and its carry into the month
            case (fld)
                3'd1: lp <= leap(yr_in);
                3'd2: mo_l <= mo_in[4:0];
                3'd3: if (dy_carry) ks <= K_DCR;
                default: ;
            endcase
        end
    end
endmodule
