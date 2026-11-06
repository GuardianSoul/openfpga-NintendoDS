// I/O hub of the integrated DS system (docs/phase2-integration.md, "I/O").
// The fabric sends one I/O access at a time (io_req for one cycle); every
// register answers the next cycle (io_ack with io_rdata). Blocks outside
// (nds_sys, nds_disp, nds_cart, nds_spi, nds_rtc) get a select strobe and
// return their data the cycle after it; the small registers live here:
//   both     0x130 KEYINPUT/KEYCNT        ARM9  0x204 EXMEMCNT
//   ARM9     0x240-0x249 VRAMCNT, WRAMCNT  ARM9  0x300 POSTFLG, 0x304 POWCNT1
//   ARM7     0x134 RCNT, 0x136 EXTKEYIN    ARM7  0x204 EXMEMSTAT, 0x240 VRAMSTAT/WRAMSTAT
//   ARM7     0x300 POSTFLG/HALTCNT, 0x304 POWCNT2, 0x308 BIOSPROT
//   ARM9     3D: DISP3DCNT (0x060) here; 0x320-0x7FF go to nds_gpu3d
//            (gx_real) like sound, or else a stub, so games don't hang: the
//            GX FIFO is always empty and the engine idle
//   ARM7     sound 0x400-0x51F: a register stub (writes kept, channel busy
//            bits read 0) for builds without rtl/sound
//   both     0xF00-0xF27 core registers for the boot program (BOOTCTL, a
//            scratch word, touch calibration, ROM size, core ID, memory
//            state, save types, the APF's date and time)
module nds_io (
    input  logic        clk,
    input  logic        rst,
    // from the fabric
    input  logic        io_req,
    input  logic        io_cpu,
    input  logic        io_we,
    input  logic [3:0]  io_be,
    input  logic [23:2] io_addr,
    input  logic [31:0] io_wdata,
    output logic        io_ack,
    output logic [31:0] io_rdata,
    // blocks outside: select strobes (address/data are the fabric's)
    output logic        sys_req,
    input  logic [31:0] sys_rdata,
    output logic        disp_req,
    input  logic [31:0] disp_rdata,
    output logic        cart_req,
    output logic [2:0]  cart_reg,
    input  logic [31:0] cart_rdata,
    output logic        spi_req,
    input  logic [31:0] spi_rdata,
    output logic        rtc_req,
    input  logic [31:0] rtc_rdata,
    output logic        snd_req,        // real sound engine (SOUND=1); else the stub answers
    input  logic        snd_ack,
    input  logic [31:0] snd_rdata,
    input  logic        snd_real,
    output logic        gx_req,         // nds_gpu3d (GPU3D=1): 0x320-0x7FF
    input  logic        gx_ack,
    input  logic [31:0] gx_rdata,
    input  logic        gx_real,
    input  logic        gx_ovf,         // DISP3DCNT bit 13: polygon/vertex RAM overflow
    output logic        wf_req,         // the WiFi block (ARM7 0x04800000+): answered with wf_ack
    input  logic        wf_ack,
    input  logic [31:0] wf_rdata,
    output logic [15:0] disp3dcnt_o,
    // inputs
    input  logic [11:0] keys,           // DS order: A B Sel Start Right Left Up Down R L X Y (1 = pressed)
    input  logic        pen_down,
    input  logic        lid_closed,
    input  logic [31:0] rom_size,
    input  logic        mem_dirty,      // main RAM / VRAM power up random (the boot program clears them)
    input  logic [7:0]  save_info,      // from the shell, static: {tables valid, type, .sav size valid, type}
    input  logic        rtc_valid,      // the APF's date and time (BCD 0xYYYYMMDD, 0x00HHMMSS), static once valid:
    input  logic [31:0] rtc_date,       // read by the boot program, which sets the RTC from them (nds_rtc)
    input  logic [31:0] rtc_time,
    input  logic [1:0]  vramstat,
    // register outputs
    output logic [15:0] powcnt1,
    output logic [1:0]  powcnt2,
    output wire         exmem_o,        // EXMEMCNT bit 11: the ARM7 has the card slot
    output logic [1:0]  wramcnt,
    output logic [71:0] vramcnt,
    output logic        vramcnt_chg,    // a clock with vramcnt just changed
    output logic [31:0] bootctl,
    output logic        halt7,          // pulse: HALTCNT written (halt not modelled)
    output logic        irq_key9,
    output logic        irq_key7,
    output logic        gx_irq          // GX FIFO IRQ condition (level)
);
    wire [21:0] wa = io_addr[23:2];
    wire        a9 = !io_cpu;
    wire        wr = io_req && io_we;

    // ---------------------------------------------------------------- decode
    typedef enum logic [3:0] { D_NONE, D_SYS, D_DISP, D_CART, D_SPI, D_RTC, D_MISC, D_SND, D_GX, D_WIFI } dev_t;
    dev_t        dev;
    logic [2:0]  creg;
    always_comb begin
        dev = D_NONE;
        creg = 3'd0;
        if (!a9 && wa[21]) dev = D_WIFI;                                    // ARM7 0x4800000-0x4FFFFFF: the WiFi block
        else if (wa == 22'h04_0000) dev = D_SYS;                            // 0x4100000 IPCFIFORECV
        else if (wa == 22'h04_0004) begin dev = D_CART; creg = 3'd4; end    // 0x4100010 card data
        else if (wa[21:12] == 10'd0) begin
            // 0x04000000-0x04003FFF
            if (a9 && (wa[11:0] <= 12'h017 || wa[11:0] == 12'h019 || wa[11:0] == 12'h01B ||
                      (wa[11:0] >= 12'h400 && wa[11:0] <= 12'h417) || wa[11:0] == 12'h41B)) dev = D_DISP;
            else if (!a9 && wa[11:0] == 12'h001) dev = D_DISP;
            else if ((wa[11:0] >= 12'h02C && wa[11:0] <= 12'h03B) || (wa[11:0] >= 12'h040 && wa[11:0] <= 12'h043) ||
                     (wa[11:0] >= 12'h060 && wa[11:0] <= 12'h062) || wa[11:0] == 12'h082 || wa[11:0] == 12'h084 ||
                     wa[11:0] == 12'h085 || (a9 && wa[11:0] >= 12'h0A0 && wa[11:0] <= 12'h0AF)) dev = D_SYS;
            else if (wa[11:0] >= 12'h068 && wa[11:0] <= 12'h06E) begin dev = D_CART; creg = wa[2:0] == 3'd0 ? 3'd0 : wa[2:0] == 3'd1 ? 3'd1 : wa[2:0] == 3'd2 ? 3'd2 : wa[2:0] == 3'd3 ? 3'd3 : 3'd5; end
            else if (!a9 && wa[11:0] == 12'h070) dev = D_SPI;
            else if (!a9 && wa[11:0] == 12'h04E) dev = D_RTC;
            else if (!a9 && wa[11:0] >= 12'h100 && wa[11:0] <= 12'h147) dev = snd_real ? D_SND : D_MISC;
            else if (a9 && gx_real && wa[11:0] >= 12'h0C8 && wa[11:0] <= 12'h1FF) dev = D_GX;
            else dev = D_MISC;
        end
    end
    assign sys_req  = io_req && dev == D_SYS;
    assign disp_req = io_req && dev == D_DISP;
    assign cart_req = io_req && dev == D_CART;
    assign cart_reg = creg;
    assign spi_req  = io_req && dev == D_SPI;
    assign rtc_req  = io_req && dev == D_RTC;

    // ---------------------------------------------------------------- misc registers
    logic [15:0] keycnt9, keycnt7;
    logic [1:0]  postflg9;
    logic        postflg7;
    logic [7:0]  vcnt [9];
    logic [31:0] disp3dcnt;
    logic [1:0]  gx_irqmode;
    logic        exmem_o7;
    assign exmem_o = exmem_o7;
    logic [31:0] snd_q;
    // (declared genvar and explicit generate: Quartus Standard rejects inline genvars)
    genvar gb;
    generate for (gb = 0; gb < 9; gb = gb + 1) begin : g_vc
        assign vramcnt[gb*8 +: 8] = vcnt[gb];
    end endgenerate
    function automatic logic [7:0] vmask(input int b);
        case (b)
            0, 1: return 8'h9B;
            2, 3, 5, 6: return 8'h9F;
            4: return 8'h87;
            default: return 8'h83;
        endcase
    endfunction

    // sound register stub: 72 words, for builds without rtl/sound only. With
    // the engine (snd_real), the ARM7's 0x520-0x7FF are unused I/O and read
    // 0, as on a DS and in melonDS (ARM7IORead32's default); the stub RAM
    // then has no writes or reads and drops out
    logic [6:0]  snd_a;
    logic [3:0]  snd_we;
    assign snd_a  = wa[6:0] - 7'h00;            // word 0x100.. -> 0..71 (wa[8] set)
    assign snd_we = (wr && dev == D_MISC && !a9 && wa[11:8] == 4'h1 && !snd_real) ? io_be : 4'd0;
    nds_sdp_ram #(.AW(7)) u_snd (.clk, .we(snd_we), .waddr(wa[6:0]), .wdata(io_wdata),
        .raddr(wa[6:0]), .rdata(snd_q));
    logic snd_stub_q, snd_cnt_q;
    assign snd_req = io_req && dev == D_SND;
    assign gx_req  = io_req && dev == D_GX;
    assign wf_req  = io_req && dev == D_WIFI;

    // keys
    wire [9:0] keyin  = ~keys[9:0];
    wire [7:0] extkey = {lid_closed, !pen_down, 3'b111, 1'b1, ~keys[11], ~keys[10]};
    function automatic logic key_irq(input logic [15:0] kc);
        logic [9:0] sel;
        sel = kc[9:0] & keys[9:0];
        if (!kc[14]) return 1'b0;
        return kc[15] ? (sel == kc[9:0] && kc[9:0] != 10'd0) : (sel != 10'd0);
    endfunction
    logic kirq9_q, kirq7_q;

    always_ff @(posedge clk) begin
        halt7 <= 1'b0;
        vramcnt_chg <= 1'b0;
        if (rst) begin
            keycnt9 <= 16'd0; keycnt7 <= 16'd0;
            postflg9 <= 2'd0; postflg7 <= 1'b0;
            powcnt1 <= 16'd0; powcnt2 <= 2'd0; exmem_o7 <= 1'b0; wramcnt <= 2'd0;
            bootctl <= 32'd0;
            disp3dcnt <= 32'd0; gx_irqmode <= 2'd0;
            for (int b = 0; b < 9; b++) vcnt[b] <= 8'd0;
            kirq9_q <= 1'b0; kirq7_q <= 1'b0;
        end else begin
            kirq9_q <= key_irq(keycnt9);
            kirq7_q <= key_irq(keycnt7);
            if (gx_ovf) disp3dcnt[13] <= 1'b1;
            if (wr && dev == D_MISC) begin
                if (wa[11:0] == 12'h04C) begin                    // 0x130 KEYCNT (high half)
                    if (a9) begin
                        if (io_be[2]) keycnt9[7:0]  <= io_wdata[23:16];
                        if (io_be[3]) keycnt9[15:8] <= io_wdata[31:24] & 8'hC3;
                    end else begin
                        if (io_be[2]) keycnt7[7:0]  <= io_wdata[23:16];
                        if (io_be[3]) keycnt7[15:8] <= io_wdata[31:24] & 8'hC3;
                    end
                end
                // (0x134 RCNT and 0xF04 scratch: only read back, the mirror holds them)
                // 0x204 EXMEMCNT: bit 11 here, the rest only reads back (the mirror holds the ARM9's; the ARM7
                // reads them too, its own GBA-slot timing bits are not kept)
                if (a9 && wa[11:0] == 12'h081 && io_be[1]) exmem_o7 <= io_wdata[11];
                if (a9 && wa[11:0] == 12'h090)                    // 0x240 VRAMCNT_A-D
                    for (int b = 0; b < 4; b++) if (io_be[b]) begin
                        vcnt[b] <= io_wdata[b*8 +: 8] & vmask(b);
                        if ((io_wdata[b*8 +: 8] & vmask(b)) != vcnt[b]) vramcnt_chg <= 1'b1;
                    end
                if (a9 && wa[11:0] == 12'h091) begin              // 0x244 VRAMCNT_E-G, WRAMCNT
                    for (int b = 0; b < 3; b++) if (io_be[b]) begin
                        vcnt[4+b] <= io_wdata[b*8 +: 8] & vmask(4+b);
                        if ((io_wdata[b*8 +: 8] & vmask(4+b)) != vcnt[4+b]) vramcnt_chg <= 1'b1;
                    end
                    if (io_be[3]) wramcnt <= io_wdata[25:24];
                end
                if (a9 && wa[11:0] == 12'h092) begin              // 0x248 VRAMCNT_H, I
                    if (io_be[0]) begin vcnt[7] <= io_wdata[7:0] & 8'h83; if ((io_wdata[7:0] & 8'h83) != vcnt[7]) vramcnt_chg <= 1'b1; end
                    if (io_be[1]) begin vcnt[8] <= io_wdata[15:8] & 8'h83; if ((io_wdata[15:8] & 8'h83) != vcnt[8]) vramcnt_chg <= 1'b1; end
                end
                if (wa[11:0] == 12'h0C0) begin                    // 0x300 POSTFLG (+ HALTCNT on the ARM7)
                    if (a9) begin
                        if (io_be[0]) postflg9 <= {io_wdata[1], postflg9[0] | io_wdata[0]};
                    end else begin
                        if (io_be[0] && io_wdata[0]) postflg7 <= 1'b1;
                        if (io_be[1]) halt7 <= 1'b1;
                    end
                end
                if (wa[11:0] == 12'h0C1) begin                    // 0x304 POWCNT
                    if (a9) begin
                        if (io_be[0]) powcnt1[7:0]  <= io_wdata[7:0] & 8'h0F;
                        if (io_be[1]) powcnt1[15:8] <= io_wdata[15:8] & 8'h82;
                    end else if (io_be[0]) powcnt2 <= io_wdata[1:0];
                end
                if (a9 && wa[11:0] == 12'h018) begin              // 0x060 DISP3DCNT (melonDS GPU3D::Write)
                    if (io_be[0]) disp3dcnt[7:0] <= io_wdata[7:0];
                    if (io_be[1]) begin
                        disp3dcnt[11:8] <= io_wdata[11:8];
                        disp3dcnt[14] <= io_wdata[14];
                        if (io_wdata[12]) disp3dcnt[12] <= 1'b0;   // acknowledged by writing 1
                        if (io_wdata[13]) disp3dcnt[13] <= 1'b0;
                    end
                end
                if (a9 && wa[11:0] == 12'h180 && io_be[3])        // 0x600 GXSTAT: IRQ mode
                    gx_irqmode <= io_wdata[31:30];
                // core registers 0xF00-0xF1F
                if (wa[11:0] == 12'h3C0) for (int b = 0; b < 4; b++) if (io_be[b]) bootctl[b*8 +: 8] <= io_wdata[b*8 +: 8];
            end
        end
    end
    assign irq_key9 = key_irq(keycnt9) && !kirq9_q;
    assign irq_key7 = key_irq(keycnt7) && !kirq7_q;
    assign gx_irq   = gx_irqmode == 2'd1 || gx_irqmode == 2'd2;
    assign disp3dcnt_o = disp3dcnt[15:0];

    // misc read data. The registers only the CPU writes are read back from
    // a mirror (one M10K, mr_*): written with the same masks and byte rules
    // as the registers above in the write's cycle, read at the request like
    // misc_q; the live bits (KEYINPUT, EXTKEYIN) are taken at the request
    // too and ORed in. Words {index}: 0/1 KEYCNT ARM9/ARM7 (high half),
    // 2-4 VRAMCNT A-D, E-G + WRAMCNT, H-I, 5 POWCNT1, 6 RCNT, 7 POWCNT2,
    // 8 BIOSPROT (only reads back), 9 BOOTCTL, 10 scratch, 11 EXMEMCNT.
    logic [3:0]  mr_i;
    logic        mr_hit;
    always_comb begin
        mr_hit = 1'b1; mr_i = 4'd0;
        if (wa[11:0] == 12'h04C) mr_i = a9 ? 4'd0 : 4'd1;
        else if (a9 && wa[11:0] == 12'h090) mr_i = 4'd2;
        else if (a9 && wa[11:0] == 12'h091) mr_i = 4'd3;
        else if (a9 && wa[11:0] == 12'h092) mr_i = 4'd4;
        else if (a9 && wa[11:0] == 12'h0C1) mr_i = 4'd5;
        else if (!a9 && wa[11:0] == 12'h04D) mr_i = 4'd6;
        else if (!a9 && wa[11:0] == 12'h0C1) mr_i = 4'd7;
        else if (!a9 && wa[11:0] == 12'h0C2) mr_i = 4'd8;
        else if (wa[11:0] == 12'h3C0) mr_i = 4'd9;
        else if (wa[11:0] == 12'h3C1) mr_i = 4'd10;
        else if (wa[11:0] == 12'h081) mr_i = 4'd11;
        else mr_hit = 1'b0;
    end
    // the write: bytes and masks as the registers take them
    logic [3:0]  mr_be;
    logic [31:0] mr_m;
    always_comb begin
        mr_be = io_be; mr_m = 32'hFFFF_FFFF;
        case (mr_i)
            4'd0, 4'd1: begin mr_be = io_be & 4'b1100; mr_m = 32'hC3FF_0000; end
            4'd2:  mr_m = 32'h9F9F_9B9B;
            4'd3:  mr_m = 32'h039F_9F87;
            4'd4:  begin mr_be = io_be & 4'b0011; mr_m = 32'h0000_8383; end
            4'd5:  begin mr_be = io_be & 4'b0011; mr_m = 32'h0000_820F; end
            4'd6:  mr_be = io_be & 4'b0011;
            4'd7:  begin mr_be = io_be & 4'b0001; mr_m = 32'h0000_0003; end
            4'd8:  begin mr_be = io_be[1:0] == 2'b11 ? 4'b0011 : 4'b0000; mr_m = 32'h0000_FFFE; end
            4'd11: mr_be = a9 ? io_be & 4'b0011 : 4'b0000;
            default: ;
        endcase
    end
    wire         mr_we = wr && dev == D_MISC && mr_hit;
    (* ramstyle = "M10K" *) logic [3:0][7:0] mr [0:15];
    initial for (int i = 0; i < 16; i++) mr[i] = 32'd0;
    logic [31:0] mr_q;
    wire  [31:0] mr_wd = io_wdata & mr_m;
    always_ff @(posedge clk) begin
        if (mr_we) begin
            if (mr_be[0]) mr[mr_i][0] <= mr_wd[7:0];
            if (mr_be[1]) mr[mr_i][1] <= mr_wd[15:8];
            if (mr_be[2]) mr[mr_i][2] <= mr_wd[23:16];
            if (mr_be[3]) mr[mr_i][3] <= mr_wd[31:24];
        end
        if (io_req) mr_q <= mr[mr_i];
    end
    // the rest
    logic [31:0] misc_r;
    always_comb begin
        misc_r = 32'd0;
        if (wa[11:0] == 12'h04C) misc_r = {16'd0, 6'd0, keyin};
        else if (!a9 && wa[11:0] == 12'h04D) misc_r = {8'd0, extkey, 16'd0};
        else if (!a9 && wa[11:0] == 12'h090) misc_r = {16'd0, 6'd0, wramcnt, 6'd0, vramstat};
        else if (wa[11:0] == 12'h0C0) misc_r = a9 ? {30'd0, postflg9} : {31'd0, postflg7};
        else if (a9 && wa[11:0] == 12'h018) misc_r = disp3dcnt;
        // GXSTAT: FIFO empty and under half, engine idle, stack levels 0
        else if (a9 && wa[11:0] == 12'h180) misc_r = {gx_irqmode, 3'd0, 1'b1, 1'b1, 25'd0};
        else if (wa[11:0] == 12'h3C4) misc_r = rom_size;
        else if (wa[11:0] == 12'h3C5) misc_r = 32'h5053_444E;     // "NDSP"
        else if (wa[11:0] == 12'h3C6) misc_r = {31'd0, mem_dirty};  // 0xF18
        else if (wa[11:0] == 12'h3C7) misc_r = {24'd0, save_info};  // 0xF1C (docs/saves.md)
        else if (wa[11:0] == 12'h3C8) misc_r = rtc_date;            // 0xF20
        else if (wa[11:0] == 12'h3C9) misc_r = {rtc_valid, 7'd0, rtc_time[23:0]};   // 0xF24
    end

    // ---------------------------------------------------------------- answer
    dev_t        dev_q;
    logic [31:0] misc_q;
    logic        mr_hq;                 // the request read the mirror
    logic        snd_wait;
    logic        snd_stub, snd_cnt;
    always_ff @(posedge clk) begin
        io_ack <= 1'b0;
        if (rst) begin dev_q <= D_NONE; snd_wait <= 1'b0; end
        else begin
            if (io_req) begin
                dev_q <= dev;
                misc_q <= misc_r;
                mr_hq <= mr_hit;
                snd_stub <= dev == D_MISC && !a9 && wa[11:8] == 4'h1 && !snd_real;
                snd_cnt  <= wa[1:0] == 2'd0;               // SOUNDxCNT word (channel stride 16 bytes)
                if (dev == D_SND || dev == D_GX || dev == D_WIFI) snd_wait <= 1'b1;
                else io_ack <= 1'b1;
            end
            if (snd_wait && (dev_q == D_GX ? gx_ack : dev_q == D_WIFI ? wf_ack : snd_ack)) begin snd_wait <= 1'b0; io_ack <= 1'b1; end
        end
    end
    always_comb begin
        unique case (dev_q)
            D_SYS:  io_rdata = sys_rdata;
            D_DISP: io_rdata = disp_rdata;
            D_CART: io_rdata = cart_rdata;
            D_SPI:  io_rdata = spi_rdata;
            D_RTC:  io_rdata = rtc_rdata;
            D_SND:  io_rdata = snd_rdata;
            D_GX:   io_rdata = gx_rdata;
            D_WIFI: io_rdata = wf_rdata;
            D_MISC: io_rdata = snd_stub ? (snd_cnt ? {1'b0, snd_q[30:0]} : snd_q) : misc_q | (mr_hq ? mr_q : 32'd0);
            default: io_rdata = 32'd0;
        endcase
    end
endmodule
