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
// written date and time fields are taken as sent, without melonDS's range
// checks, and the clock always counts 24 hours: status 1's 12/24-hour bit only
// reads back, as games keep 24-hour mode (docs/ds-rules.md). The hour's pm bit
// is its value's, as a 24-hour read shows it.
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
// (docs/mlab-tables.md: sim/ds_dev/equiv/rtc_eq.sh).
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

    // ---- state
    logic [7:0]  io;
    logic [7:0]  yr;
    logic [4:0]  mo;
    logic [5:0]  hr;
    wire         pm = hr >= 6'h12;
    logic        poc;           // status 1 bit 7
    logic [3:1]  s1;            // status 1 bits 3:1 (bit 1: 24-hour mode)
    logic        s2_2;          // status 2 bit 2 (INT1 layout), a copy of the RAM's
    // RAM: 0 second, 1 minute, 2 day, 3 day of week, 4 status 2, 5 clock
    // adjust, 6 free, 8-10 INT1 alarm, 12-14 INT2 alarm
    localparam logic [3:0] R_SE = 4'd0, R_MI = 4'd1, R_DY = 4'd2, R_DW = 4'd3, R_S2 = 4'd4,
                           R_ADJ = 4'd5, R_FRE = 4'd6, R_AL1 = 4'd8, R_AL2 = 4'd12;
    logic        rm_we;
    logic [3:0]  rm_wa, rm_ra;
    logic [7:0]  rm_wd, rq;
    (* ramstyle = "M10K" *) logic [7:0] rm [0:15];   // (M10K: the chip is short of LABs)
    // sequences: the second count (K_*), the reset clear
    // K_HR, K_MO, K_YR: the flops' arithmetic, one shared BCD incrementer
    // (the hour after the minute, the month and year after the day)
    typedef enum logic [3:0] { K_IDLE, K_SE, K_SEW, K_MIW, K_DWW, K_DYW, K_CLR,
                               K_HR, K_MO, K_YR } kst_t;
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
                3'd0: obf = yr;
                3'd1: obf = {3'd0, mo};
                3'd2: begin ob_ram = 1'b1; ob_a = R_DY; end
                3'd3: begin ob_ram = 1'b1; ob_a = R_DW; end
                3'd4: obf = {1'b0, pm, hr};
                3'd5: begin ob_ram = 1'b1; ob_a = R_MI; end
                3'd6: begin ob_ram = 1'b1; ob_a = R_SE; end
                default: ;
            endcase
            3'd6: case (out_pos)
                3'd0: obf = {1'b0, pm, hr};
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
        ob0 = ob_ram ? rq : obf;
    end

    // ---- one second later (melonDS's CountSecond chain), one field per step:
    // each step writes the field read in the step before (rq) and reads the
    // next: second, minute (if the second wrapped), day of week and day (if
    // the hour wrapped the day)
    wire [7:0] k_inc = binc(rq);
    // the flops' incrementer: the month in K_MO, the year in K_YR, else the hour
    wire [7:0] f_inc = binc(ks == K_MO ? {3'b0, mo} : ks == K_YR ? yr : {2'b0, hr});
    wire        n_day = f_inc == 8'h24;  // the hour when the minute wraps (K_HR)
    // end of month for the counted day
    // (a count never runs while a data byte comes in: a byte takes 16
    // register writes, a count 5 clocks, and counts start with CS low)
    wire       eom    = k_inc > dim(mo, leap(yr));      // the counted day
    wire       yr_inc = f_inc == 8'h13;                 // in K_MO

    wire [7:0] ob = ob0;



    // ---- RAM ports: the second count and the clear sequence, else the
    // field writes of a command; reads follow the output byte while idle
    logic [3:0] dat_a;                  // RAM byte a command data byte writes
    logic [7:0] dat_d;
    logic       dat_wr;                 // the byte would write (dat_w without dat_in)
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
            3'd3: begin dat_wr = 1'b1; dat_a = R_DY; end
            3'd4: begin dat_wr = 1'b1; dat_a = R_DW; end
            3'd6: begin dat_wr = 1'b1; dat_a = R_MI; end
            3'd7: begin dat_wr = 1'b1; dat_a = R_SE; end
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
    wire rm_sel = !(ks == K_SEW || ks == K_MIW || ks == K_DWW || ks == K_DYW || ks == K_CLR);
    always_comb begin
        rm_we = 1'b0; rm_wa = dat_a; rm_wd = dat_d;
        rm_ra = ob_a;
        case (ks)
            K_SE: rm_ra = R_SE;
            K_SEW: begin rm_we = 1'b1; rm_wa = R_SE; rm_wd = k_inc == 8'h60 ? 8'h00 : k_inc; rm_ra = R_MI; end
            K_MIW: begin rm_we = 1'b1; rm_wa = R_MI; rm_wd = k_inc == 8'h60 ? 8'h00 : k_inc; rm_ra = R_DW; end
            K_HR:  rm_ra = R_DW;            // the day of week stays fetched for K_DWW
            K_DWW: begin rm_we = 1'b1; rm_wa = R_DW; rm_wd = {5'd0, rq[2:0] >= 3'd6 ? 3'd0 : rq[2:0] + 3'd1}; rm_ra = R_DY; end
            K_DYW: begin rm_we = 1'b1; rm_wa = R_DY; rm_wd = eom ? 8'h01 : k_inc; end
            K_CLR: begin rm_we = 1'b1; rm_wa = kc; rm_wd = kc == R_DY ? 8'h01 : 8'h00; end
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
            io <= '0; yr <= 8'h00; mo <= 5'h01; hr <= '0;
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
                K_MIW: ks <= k_inc == 8'h60 ? K_HR : K_IDLE;
                K_HR: begin
                        hr <= n_day ? 6'h00 : f_inc[5:0];
                        ks <= n_day ? K_DWW : K_IDLE;
                    end
                K_DWW: ks <= K_DYW;
                K_DYW: ks <= eom ? K_MO : K_IDLE;
                K_MO: begin
                        mo <= yr_inc ? 5'h01 : f_inc[4:0];
                        ks <= yr_inc ? K_YR : K_IDLE;
                    end
                K_YR: begin yr <= f_inc; ks <= K_IDLE; end
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
                        yr <= 8'h00; mo <= 5'h01; hr <= '0;
                        ks <= K_CLR; kc <= '0;
                        k_n <= '0;   // a second committed before this was counted, then cleared
                    end
                end
                3'd4: if (p1) s2_2 <= ib[2];
                default: ;
            endcase
            case (fld)
                3'd1: yr <= ib;
                3'd2: mo <= ib[4:0];
                3'd5: hr <= ib[5:0];
                default: ;
            endcase
        end
    end
endmodule
