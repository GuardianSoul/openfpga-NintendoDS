// The ARM7 SPI bus (0x040001C0) as nds_spi.sv (same register behaviour, same
// devices: docs in nds_spi.sv), with the devices' byte handling moved into
// nds_wifi_mc's microcode engine (SPI_MC; the engine's SPI routines,
// sim/ds/wifi_mc_asm.py). What stays here is what the DS's timing needs every
// clock: SPICNT, busy and its timer, the transfer-end IRQ, the answer
// register sd, the touchscreen's samples taken at the control byte, and the
// firmware's word queue as nds_spi's (fetches run ahead of the bus; a data
// byte the engine marks waiting (e_fwait) is answered from the queue, and holds
// busy until it is, as nds_spi's f_wait). The engine shifts the address in
// (e_frsh) and starts the stream at its last byte (e_flush), a few clocks
// after the byte rather than at it: the fetches start that much later.
//
// A byte (go) or a chip-select release becomes an event the engine takes
// when it is free; busy holds until the engine has written the answer, but
// a byte's routine is far shorter than busy's 64 << baud DS clocks (128
// clk_sys and up), so it never decides when busy drops. A release without a
// byte (SPICNT disabling the bus) is kept as a pending mask and applied
// before the next byte, which is the first thing that can see it.
`default_nettype none
module nds_spi_mc (
    input  logic        clk,
    input  logic        rst,
    input  logic        tick,
    input  logic        io_req,
    input  logic        io_we,
    input  logic [3:0]  io_be,
    input  logic [31:0] io_wdata,
    output logic [31:0] io_rdata,
    output logic        irq,
    // touchscreen
    input  logic        pen,
    input  logic [7:0]  tx,
    input  logic [7:0]  ty,
    input  logic [15:0] kx,
    input  logic [15:0] ky,
    input  logic [15:0] ox,
    input  logic [15:0] oy,
    output logic        pen_down,
    // to the engine
    output logic        ev,             // an event waits (level, until e_done)
    output logic [15:0] ev_w,           // {pre-release mask[2:0], release after, byte, dev[1:0], 1'b0, v[7:0]}
    output logic [15:0] t_prd,          // (t * k) >> 8 of the control byte's sample
    output logic [15:0] t_off,          // its offset
    output logic [15:0] t_st,           // {14'd0, pen, the sample is X}
    input  logic        e_sdw,          // write the answer
    input  logic [7:0]  e_sd,
    input  logic        e_done,         // the event is done
    input  logic        e_frsh,         // f_ra = {f_ra[9:0], v}
    input  logic        e_flush,        // the address is complete: stream from f_ra
    input  logic        e_fwait,        // this byte is the data at f_ra (answered from the queue)
    input  logic        e_fstop,        // the firmware's chip select is released
    // firmware image
    output logic        fw_req,
    output logic [17:2] fw_addr,
    input  logic        fw_ack,
    input  logic [31:0] fw_rdata
);
    logic       en, ie, hold, m16, busy;
    logic [1:0] dev, baud;
    logic [8:0] tmr;
    logic [7:0] sd;
    // firmware word queue (nds_spi's)
    logic        f_stream, f_wait, f_drop;
    logic [17:0] f_ra;
    logic [31:0] q0, q1;
    logic [1:0]  qn;
    logic [18:0] f_ra1;
    logic [16:0] fw_a1;
    nds_dsp_add #(.W(18)) u_ra1 (.clk, .a(f_ra), .b(18'd1), .s(f_ra1));
    nds_dsp_add #(.W(16)) u_fa1 (.clk, .a(fw_addr), .b(16'd1), .s(fw_a1));
    wire        f_take = f_wait && qn != 2'd0;
    wire        f_pop  = f_take && f_ra[1:0] == 2'b11;
    wire        f_push = fw_ack && !f_drop && !e_flush;
    wire [1:0]  qk     = qn - {1'b0, f_pop};
    logic [7:0] f_byte;
    always_comb case (f_ra[1:0])
        2'd0: f_byte = q0[7:0];
        2'd1: f_byte = q0[15:8];
        2'd2: f_byte = q0[23:16];
        2'd3: f_byte = q0[31:24];
    endcase

    wire       wcnt   = io_req && io_we && io_be[1:0] == 2'b11;
    wire       wdat   = io_req && io_we && io_be[2];
    wire       n_en   = wcnt ? io_wdata[15] : en;
    wire       n_hold = wcnt ? io_wdata[11] : hold;
    wire [1:0] n_dev  = wcnt ? io_wdata[9:8] : dev;
    wire [1:0] n_baud = wcnt ? io_wdata[1:0] : baud;
    wire [7:0] v      = io_wdata[23:16];
    wire       go     = wdat && n_en && !busy;
    wire       rel    = (go && !n_hold) || (wcnt && en && !io_wdata[15]);
    wire [1:0] rdev   = go ? n_dev : dev;

    // events: a byte, with its own release after it; a release alone joins the pending mask
    logic [2:0] relm;               // devices released since the last byte (applied before it)
    logic       evb;

    // touchscreen samples at the control byte, as nds_spi's conversion takes them:
    // the product of the cursor and the scale a clock after the byte (t_ld), the
    // offset and the pen two clocks after (t_ld2)
    logic        t_ld, t_ld2, t_x;
    logic [15:0] t_p, t_o;
    logic        t_pen;
    wire         t_ctl_go = go && n_dev == 2'd2 && v[7];
    wire  [23:0] prd = (t_x ? tx : ty) * (t_x ? kx : ky);
    assign t_prd = t_p;
    assign t_off = t_o;
    assign t_st  = {14'd0, t_pen, t_x};
    assign pen_down = pen;

    always_ff @(posedge clk) begin
        if (rst) begin
            en <= 1'b0; ie <= 1'b0; hold <= 1'b0; m16 <= 1'b0; busy <= 1'b0;
            dev <= '0; baud <= '0; tmr <= '0; sd <= '0; irq <= 1'b0;
            io_rdata <= '0; ev <= 1'b0; ev_w <= '0; relm <= '0; evb <= 1'b0;
            f_ra <= '0; f_stream <= 1'b0; f_wait <= 1'b0; f_drop <= 1'b0; q0 <= '0; q1 <= '0; qn <= '0;
            fw_req <= 1'b0; fw_addr <= '0; t_ld <= 1'b0; t_ld2 <= 1'b0; t_x <= 1'b0; t_p <= '0; t_o <= '0; t_pen <= 1'b0;
        end else begin
            irq <= 1'b0;
            io_rdata <= {8'd0, en && !busy ? sd : 8'd0, en, ie, 2'd0, hold, m16, dev, busy, 5'd0, baud};
            if (wcnt) begin
                en <= io_wdata[15]; ie <= io_wdata[14]; hold <= io_wdata[11];
                m16 <= io_wdata[10]; dev <= io_wdata[9:8]; baud <= io_wdata[1:0];
            end
            if (go) begin
                busy <= 1'b1;
                tmr <= (9'd64 << n_baud) - 9'd1;
            end else if (busy && tick) begin
                if (tmr != 9'd0) tmr <= tmr - 9'd1;
                else if (!ev && !f_wait) begin busy <= 1'b0; irq <= ie; end
            end
            if (go) begin
                ev <= 1'b1;
                ev_w <= {relm, !n_hold, 1'b1, n_dev, 1'b0, v};
                relm <= '0;
            end else begin
                if (e_done) ev <= 1'b0;
                if (rel && rdev != 2'd3) relm[rdev] <= 1'b1;
            end
            if (e_sdw) sd <= e_sd;
            if (e_frsh) f_ra <= {f_ra[9:0], ev_w[7:0]};
            // firmware: the word queue (nds_spi's, the flush from the engine)
            if (e_fwait) f_wait <= 1'b1;
            if (e_flush) f_stream <= 1'b1;
            if (e_fstop) f_stream <= 1'b0;
            if (f_take) begin sd <= f_byte; f_ra <= f_ra1[17:0]; f_wait <= 1'b0; end
            if (f_pop) q0 <= q1;
            if (f_push) begin
                if (qk == 2'd0) q0 <= fw_rdata; else q1 <= fw_rdata;
            end
            qn <= e_flush ? 2'd0 : qk + {1'b0, f_push};
            if (e_flush) begin
                if (fw_req && !fw_ack) f_drop <= 1'b1;
                else fw_addr <= f_ra[17:2];
            end else if (fw_ack) begin
                if (f_drop) begin f_drop <= 1'b0; fw_addr <= f_ra[17:2]; end
                else fw_addr <= fw_a1[15:0];
            end
            if (fw_req) begin
                if (fw_ack) fw_req <= 1'b0;
            end else if ((f_stream || f_wait) && qn != 2'd2 && !e_flush)
                fw_req <= 1'b1;
            t_ld <= t_ctl_go; t_ld2 <= t_ld;
            if (t_ctl_go) t_x <= v[6:4] == 3'd5;
            if (t_ld) t_p <= prd[23:8];
            if (t_ld2) begin t_o <= t_x ? ox : oy; t_pen <= pen; end
        end
    end
`ifndef ALTERA_RESERVED_QIS
    // the engine answers well inside busy (128 clk_sys at the fastest baud)
    // (+spidiag: every clock busy is held past its time for the engine)
    longint cyc = 0;
    bit     diag = 1'b0;
    initial diag = $test$plusargs("spidiag");
    always_ff @(posedge clk) begin
        cyc <= cyc + 1;
        if (diag && !rst && busy && tick && tmr == 9'd0 && ev)
            $display("nds_spi_mc %0d: busy held for the engine (SPI event not done at the end of the transfer)", cyc);
    end
`endif
endmodule
`default_nettype wire
