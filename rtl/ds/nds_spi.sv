// ARM7 SPI bus 0x040001C0: SPICNT (word bits 15:0) and SPIDATA (bits 23:16),
// with the power manager, firmware flash and touchscreen controller behind
// it, after melonDS's SPI (behaviour only) and GBATEK "DS Serial Peripheral
// Interface Bus (SPI)".
//
// SPICNT keeps bits 15,14,11,10,9:8,1:0 of a 16- or 32-bit write (8-bit
// writes to it are ignored, as in melonDS); bit 7 is busy. A SPIDATA write
// with the bus enabled and not busy sends one byte: the selected device
// answers at once (the answer reads back from SPIDATA once busy drops; reads
// return 0 while disabled or busy) and busy lasts 64 << baud DS clocks, as
// melonDS's transfer event. Without bit 11 (hold) the device's chip select is
// released after the byte; clearing bit 15 releases it too. The transfer end
// pulses `irq` when bit 14 is set. A 32-bit write writes SPICNT first, then
// SPIDATA under the new SPICNT. One answer register serves all devices, as
// the hardware's shift register (melonDS keeps one per device).
//
// Power manager (device 0): register index byte (bit 7 = read, bits 2:0 =
// register), then every further byte reads or writes that register;
// melonDS's NDS registers: 0 control (7 bits; a write with bit 6 pulses
// pwr_off), 1 battery (0 = good, read-only), 2 amplifier (1 bit), 3 volume
// (2 bits), 4 backlight (0x40 | 4 bits), 5-7 read 0.
//
// Firmware flash (device 1), 256 KiB read from a copy in external memory:
// READ 03h (3 address bytes, then data), FAST READ 0Bh (3 address bytes, one
// dummy byte, then data; GBATEK, melonDS does not implement it), RDSR 05h,
// WREN 06h / WRDI 04h (status bit 1), RDID 9Fh (20h 40h 12h, then 0).
// PW 0Ah answers as melonDS (0 for address bytes, then the written byte) but
// does not change the image in this version: no command writes the flash.
// Others answer FFh. A data byte is fetched from its word when it is asked for,
// no queue: fw_req is held until fw_ack and holds busy (a byte's 64+ DS clocks
// cover the memory port's latency unless the port is badly behind; docs/ds-rules.md);
// fw_addr is the byte address's word, which no byte can move meanwhile; byte 0 is fw_rdata[7:0].
//
// Touchscreen (device 2), TSC2046 as melonDS: a byte with bit 7 set is a
// control byte that starts a conversion of channel bits 6:4 (8-bit mode,
// bit 3, clears the low 4 bits); the next two bytes return the 12-bit result
// (bits 11:5, then 4:0 << 3), later bytes 0. Channel 1 is Y, 5 is X, 6 the
// microphone (silent: 800h), the others FFFh. Pen up reads X 0 and Y FFFh;
// pen down gives raw = t * 16 + 8 from the cursor pixel tx/ty, and the boot
// program writes the matching calibration into the user settings' copy, in
// place of the firmware's (sw/boot/boot7.s, docs/ds-rules.md). The result is
// taken at each answer byte: a cursor moving between a sample's two bytes
// shows at most in one sample's low bits.
module nds_spi (
    input  logic        clk,
    input  logic        rst,
    input  logic        tick,
    input  logic        io_req,
    input  logic        io_we,
    input  logic [3:0]  io_be,
    input  logic [31:0] io_wdata,
    output logic [31:0] io_rdata,
    output logic        irq,
    output logic        pwr_off,
    // firmware image
    output wire         fw_req,
    output wire  [17:2] fw_addr,
    input  logic        fw_ack,
    input  logic [31:0] fw_rdata,
    // touchscreen
    input  logic        pen,
    input  logic [7:0]  tx,
    input  logic [7:0]  ty,
    output logic        pen_down
);
    // ---- SPICNT
    logic       en, ie, hold, m16, busy;
    logic [1:0] dev, baud;
    logic [8:0] tmr;
    logic [7:0] sd;             // answer byte

    wire       wcnt  = io_req && io_we && io_be[1:0] == 2'b11;
    wire       wdat  = io_req && io_we && io_be[2];
    wire       n_en   = wcnt ? io_wdata[15] : en;
    wire       n_hold = wcnt ? io_wdata[11] : hold;
    wire [1:0] n_dev  = wcnt ? io_wdata[9:8] : dev;
    wire [1:0] n_baud = wcnt ? io_wdata[1:0] : baud;
    wire [7:0] v     = io_wdata[23:16];
    wire       go    = wdat && n_en && !busy;
    wire       rel   = (go && !n_hold) || (wcnt && en && !io_wdata[15]);
    wire [1:0] rdev  = go ? n_dev : dev;

    // ---- firmware flash
    logic        f_hold, f_wel, f_wait;
    logic [7:0]  f_cmd;
    logic [2:0]  f_pos;
    logic [17:0] f_ra;          // next byte address
    // the incrementer in a DSP block (nds_dsp_add): the chip is short of LABs
    logic [18:0] f_ra1;
    nds_dsp_add #(.W(18)) u_ra1 (.clk, .a(f_ra), .b(18'd1), .s(f_ra1));
    assign fw_req  = f_wait;
    assign fw_addr = f_ra[17:2];

    wire        f_go    = go && n_dev == 2'd1;
    wire        f_rdc   = f_cmd == 8'h03 || f_cmd == 8'h0B;
    wire [17:0] f_na    = {f_ra[9:0], v};
    wire        f_take  = f_wait && fw_ack;
    logic [7:0] f_byte;
    always_comb case (f_ra[1:0])
        2'd0: f_byte = fw_rdata[7:0];
        2'd1: f_byte = fw_rdata[15:8];
        2'd2: f_byte = fw_rdata[23:16];
        2'd3: f_byte = fw_rdata[31:24];
    endcase

    // ---- power manager
    logic       p_hold, p_rd;
    logic [2:0] p_reg;
    logic [6:0] p_r0;
    logic       p_r2;
    logic [1:0] p_r3;
    logic [3:0] p_r4;
    logic [7:0] p_val;
    always_comb case (p_reg)
        3'd0: p_val = {1'b0, p_r0};
        3'd2: p_val = {7'd0, p_r2};
        3'd3: p_val = {6'd0, p_r3};
        3'd4: p_val = {4'h4, p_r4};
        default: p_val = 8'h00;
    endcase

    // ---- touchscreen
    logic [1:0]  t_pos;         // saturates at 3
    logic [3:0]  t_ctl;         // channel, 8-bit mode
    wire  [11:0] t_raw = {t_ctl[3] ? tx : ty, 4'h8};    // channels 5 (X), 1 (Y)
    logic [11:0] t_res;
    always_comb begin
        case (t_ctl[3:1])
            3'd1:    t_res = pen ? t_raw : 12'hFFF;
            3'd5:    t_res = pen ? t_raw : 12'h000;
            3'd6:    t_res = 12'h800;
            default: t_res = 12'hFFF;
        endcase
        if (t_ctl[0]) t_res[3:0] = 4'h0;
    end
    assign pen_down = pen;

    always_ff @(posedge clk) begin
        if (rst) begin
            en <= 1'b0; ie <= 1'b0; hold <= 1'b0; m16 <= 1'b0; busy <= 1'b0;
            dev <= '0; baud <= '0; tmr <= '0; sd <= '0; irq <= 1'b0; pwr_off <= 1'b0;
            io_rdata <= '0;
            f_hold <= 1'b0; f_wel <= 1'b0; f_wait <= 1'b0;
            f_cmd <= '0; f_pos <= '0; f_ra <= '0;
            p_hold <= 1'b0; p_rd <= 1'b0; p_reg <= '0;
            p_r0 <= '0; p_r2 <= 1'b0; p_r3 <= '0; p_r4 <= '0;
            t_pos <= '0; t_ctl <= '0;
        end else begin
            irq <= 1'b0;
            pwr_off <= 1'b0;
            io_rdata <= {8'd0, en && !busy ? sd : 8'd0,
                         en, ie, 2'd0, hold, m16, dev, busy, 5'd0, baud};

            if (wcnt) begin
                en <= io_wdata[15]; ie <= io_wdata[14]; hold <= io_wdata[11];
                m16 <= io_wdata[10]; dev <= io_wdata[9:8]; baud <= io_wdata[1:0];
            end

            // transfer time; a firmware byte still on its way holds busy
            if (go) begin
                busy <= 1'b1;
                tmr <= (9'd64 << n_baud) - 9'd1;
            end else if (busy && tick) begin
                if (tmr != 9'd0) tmr <= tmr - 9'd1;
                else if (!f_wait) begin busy <= 1'b0; irq <= ie; end
            end

            // power manager
            if (go && n_dev == 2'd0) begin
                if (!p_hold) begin
                    p_hold <= 1'b1; p_rd <= v[7]; p_reg <= v[2:0]; sd <= 8'h00;
                end else if (p_rd) sd <= p_val;
                else case (p_reg)
                    3'd0: begin p_r0 <= v[6:0]; pwr_off <= v[6]; end
                    3'd2: p_r2 <= v[0];
                    3'd3: p_r3 <= v[1:0];
                    3'd4: p_r4 <= v[3:0];
                    default: ;
                endcase
            end

            // touchscreen
            if (go && n_dev == 2'd2) begin
                sd <= t_pos == 2'd1 ? {1'b0, t_res[11:5]} :
                      t_pos == 2'd2 ? {t_res[4:0], 3'd0} : 8'h00;
                if (v[7]) begin t_pos <= 2'd1; t_ctl <= v[6:3]; end
                else if (t_pos != 2'd3) t_pos <= t_pos + 2'd1;
            end

            // firmware flash: commands
            if (f_go) begin
                if (!f_hold) begin
                    f_hold <= 1'b1; f_cmd <= v; f_pos <= 3'd1; sd <= 8'h00;
                    if (v == 8'h04) f_wel <= 1'b0;
                    if (v == 8'h06) f_wel <= 1'b1;
                end else begin
                    if (f_pos != 3'd7) f_pos <= f_pos + 3'd1;
                    case (f_cmd)
                        8'h03, 8'h0B:
                            if (f_pos <= 3'd3) begin f_ra <= f_na; sd <= 8'h00; end
                            else if (f_cmd[3] && f_pos == 3'd4) sd <= 8'h00;
                            else f_wait <= 1'b1;
                        8'h05: sd <= {6'd0, f_wel, 1'b0};
                        8'h0A: sd <= f_pos <= 3'd3 ? 8'h00 : v;
                        8'h9F: sd <= f_pos == 3'd1 ? 8'h20 : f_pos == 3'd2 ? 8'h40 :
                                     f_pos == 3'd3 ? 8'h12 : 8'h00;
                        default: begin f_pos <= f_pos; sd <= 8'hFF; end
                    endcase
                end
            end

            // firmware flash: the byte asked for
            if (f_take) begin
                sd <= f_byte; f_ra <= f_ra1[17:0]; f_wait <= 1'b0;
            end

            // chip select release
            if (rel) case (rdev)
                2'd0: p_hold <= 1'b0;
                2'd1: begin f_hold <= 1'b0; f_pos <= '0; f_cmd <= '0; end
                2'd2: t_pos <= '0;
                default: ;
            endcase
        end
    end
endmodule
