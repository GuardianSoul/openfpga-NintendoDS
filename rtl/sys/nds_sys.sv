// NDS system blocks (docs/system-blocks.md): DMA, timers, IRQ controllers,
// IPC and the ARM9 divider/square root, for both CPUs, behind one register
// port. Runs at 67.03 MHz; `tick` is high in every second cycle, the one that
// ends a 33.51 MHz system cycle (timers and DIV/SQRT busy times count those).
//
// Register port: one access per cycle from either CPU, the shape of the ARM
// pipeline's data port (docs/arm-pipeline.md): request with byte enables and
// the word address within 0x04000000..0x041FFFFF, read data and a hit flag
// the next cycle. Reads with side effects (IPCFIFORECV) act on the request.
// The integration also sends DMA accesses to this IO space here (fill words,
// other registers) and stalls a CPU while `dma_busy` has its bit set.
//
//   0x0B0..0x0DF DMA0-3 SAD/DAD/CNT   0x0E0..0x0EF DMA fill (ARM9)
//   0x100..0x10F timers               0x180/0x184/0x188 IPCSYNC/FIFOCNT/SEND
//   0x208/0x210/0x214 IME/IE/IF       0x280..0x2BF DIV/SQRT (ARM9)
//   0x4100000 IPCFIFORECV
module nds_sys #(
    parameter bit DMA_FAST = 0,         // sys_dma FAST: combined main-RAM units (m_unit, m_dst)
    parameter bit PUMP     = 0          // sys_math's u_res written on clk2 (sys_ram64w, 2 -> 1 M10K) and its sqrt on clk2
) (
    input  logic        clk,
    input  logic        clk2,           // PUMP: 2 x clk, phase 0 (else unused)
    input  logic        rst,
    input  logic        tick,
    // register port
    input  logic        io_req,
    input  logic        io_pre,     // io_req without the GX hold, which never holds a timer access: the timers' visit, off g_busy's path
    // timer writes as nds_fabric decodes them on its grant edge, a register
    // in the request's cycle: bit {cpu, index} (= io_req && io_we && d_tmr
    // and the CPU and index this decode gives; timing: #470, #519)
    input  logic [7:0]  tmr_oh,
    input  logic        io_cpu,     // 0 ARM9, 1 ARM7
    input  logic        io_we,
    input  logic [3:0]  io_be,
    input  logic [20:2] io_addr,
    input  logic [31:0] io_wdata,
    output logic [31:0] io_rdata,
    output logic        io_hit,
    // DMA events
    input  logic [7:1]  dma_trig9,
    input  logic        dma_gx_low,
    input  logic [7:1]  dma_stop9,
    input  logic [3:1]  dma_trig7,
    // DMA memory port
    output logic        m_req,
    output logic        m_we,
    output logic        m_cpu,
    output logic        m_size32,
    output logic [31:0] m_addr,
    output logic        m_unit,
    output logic [31:0] m_dst,
    output logic        m_more,
    output logic [31:0] m_wdata,
    input  logic        m_ack,
    input  logic [31:0] m_rdata,
    output logic [1:0]  dma_busy,
    // interrupts: external sources as pulses (VBlank, HBlank, VCount, RTC,
    // keypad, card, GX FIFO, SPI, ...), the CPUs' IRQ lines out
    input  logic [31:0] irq_ext9,
    input  logic [31:0] irq_ext7,
    output logic        f1024,          // the timers' F/1024 tick (sound's output step)
    output logic        irq9,
    output logic        irq7,
    output logic        wake7,          // IE & IF of the ARM7, not gated by IME (a HALTCNT halt ends)
    output logic        math_late,  // simulation check
    output logic [7:0]  dbg_dma_run, // test bench
    output logic        dma_lat_lost // simulation check
);
    // ---- decode
    wire [9:0] w   = io_addr[11:2];
    wire       low = io_addr[20:12] == 9'd0;
    wire       a9  = !io_cpu;

    logic       d_dma, d_tmr, d_sync, d_cnt, d_send, d_recv, d_irq, d_math;
    logic [1:0] dch, dsel, isel;
    always_comb begin
        d_dma = 1'b0; dch = '0; dsel = '0;
        if (low && w >= 10'h2C && w <= 10'h37) begin
            d_dma = 1'b1;
            unique case (w[3:0])        // (w - 0x2C) / 3 and % 3
                4'hC: begin dch = 2'd0; dsel = 2'd0; end
                4'hD: begin dch = 2'd0; dsel = 2'd1; end
                4'hE: begin dch = 2'd0; dsel = 2'd2; end
                4'hF: begin dch = 2'd1; dsel = 2'd0; end
                4'h0: begin dch = 2'd1; dsel = 2'd1; end
                4'h1: begin dch = 2'd1; dsel = 2'd2; end
                4'h2: begin dch = 2'd2; dsel = 2'd0; end
                4'h3: begin dch = 2'd2; dsel = 2'd1; end
                4'h4: begin dch = 2'd2; dsel = 2'd2; end
                4'h5: begin dch = 2'd3; dsel = 2'd0; end
                4'h6: begin dch = 2'd3; dsel = 2'd1; end
                default: begin dch = 2'd3; dsel = 2'd2; end
            endcase
        end else if (low && a9 && w[9:2] == 8'h0E) begin
            d_dma = 1'b1; dch = w[1:0]; dsel = 2'd3;
        end
        d_tmr  = low && w[9:2] == 8'h10;
        d_sync = low && w == 10'h060;
        d_cnt  = low && w == 10'h061;
        d_send = low && w == 10'h062;
        d_recv = io_addr[20] && io_addr[19:2] == 18'd0;
        d_irq  = low && (w == 10'h082 || w == 10'h084 || w == 10'h085);
        isel   = w == 10'h082 ? 2'd0 : w == 10'h084 ? 2'd1 : 2'd2;
        d_math = low && a9 && w[9:4] == 6'h0A;
    end
    wire rd = io_req && !io_we;
    wire wr = io_req &&  io_we;

    // ---- the register RAM: everything the CPU writes and the hardware does
    // not change, as a write-through copy read back from M10K, so the flop
    // read mux carries only timer counts, IF, IPC status, the DIV/SQRT busy,
    // divide-by-zero and mode bits, and the results. The DMA engine reads
    // CNT and SAD/DAD from it too. Word {cpu, idx}, two 32-bit lanes:
    //   0-3 {DAD, SAD} ch   4-7 {FILL, CNT} ch   8 {IE, IME}
    //   9 {TM1, TM0}  10 {TM3, TM2} (control halves)
    //   11 {NUMER_H, _L}  12 {DENOM_H, _L}  13 {PARAM_H, _L}  14 {SQRTCNT, DIVCNT}
    // Write sizes follow melonDS (TMCNT_H: the DS, above): CNT, timer, DIVCNT/SQRTCNT 16/32-bit; the
    // DIV/SQRT operands 32-bit only; the rest merge bytes.
    wire cnt_ok = io_be == 4'b0011 || io_be == 4'b1100 || io_be == 4'b1111;
    logic       rg_hit, rg_lane;
    logic [3:0] rg_idx, rg_be;
    logic [2:0] rg_kind;            // read: 1 lane, 3 IME, 4 timer, 5 DIVCNT, 6 SQRTCNT, 7 DMA CNT
    always_comb begin
        rg_hit = 1'b1; rg_lane = 1'b0; rg_idx = '0; rg_be = io_be; rg_kind = 3'd1;
        if (d_dma) begin
            rg_idx = {1'b0, dsel[1], dch}; rg_lane = dsel[0];
            if (dsel == 2'd2) begin rg_be = cnt_ok ? io_be : 4'h0; rg_kind = 3'd7; end
        end else if (d_irq && isel != 2'd2) begin
            rg_idx = 4'd8; rg_lane = isel[0]; rg_kind = isel[0] ? 3'd1 : 3'd3;
        end else if (d_tmr) begin
            // TMCNT_H (DS_RULE_TMRCNT, hwref run 34): a write that reaches
            // its low byte takes effect, and bits 3-5 and 8-15 read 0
            rg_idx = 4'd9 + 4'(w[1]); rg_lane = w[0]; rg_kind = 3'd4;
            rg_be = io_be[2] ? 4'b1100 : 4'h0;
        end else if (d_math && (w[3:2] == 2'b01 || w[3:1] == 3'b111)) begin
            rg_idx = w[3] ? 4'd13 : 4'd11 + 4'(w[1]); rg_lane = w[0];
            rg_be = io_be == 4'hF ? 4'hF : 4'h0;
        end else if (d_math && (w[3:0] == 4'd0 || w[3:0] == 4'd12)) begin
            rg_idx = 4'd14; rg_lane = w[3]; rg_kind = w[3] ? 3'd6 : 3'd5;
            rg_be = io_be[1:0] == 2'b11 ? 4'b0011 : 4'h0;
        end else rg_hit = 1'b0;
    end
    logic [4:0]  dma_raddr;
    logic [63:0] reg_rd;
    wire         cpu_rg = rd && rg_hit;
    // (not double-pumped: the DMA reads both halves in one clock and the CPU
    // read takes its lane straight into the fabric's read mux, so a pumped
    // block's half-cycle output failed timing, #1050/#1051 -1.1..-1.8 ns)
    sys_ram64be #(.AW(5)) u_regs (.clk, .we(wr && rg_hit), .waddr({io_cpu, rg_idx}),
        .be(rg_lane ? {rg_be, 4'h0} : {4'h0, rg_be}), .wdata({2{d_tmr ? io_wdata & 32'h00C7_FFFF : io_wdata}}),
        .raddr(cpu_rg ? {io_cpu, rg_idx} : dma_raddr), .rdata(reg_rd));

    // ---- blocks
    logic [7:0]  dma_en;
    logic [3:0]  dirq9, dirq7;
    sys_dma #(.FAST(DMA_FAST)) u_dma (
        .clk, .rst, .cnt_we(wr && d_dma && dsel == 2'd2 && cnt_ok), .cpu(io_cpu), .ch(dch),
        .be(io_be), .wdata(io_wdata), .en_q(dma_en),
        .reg_gnt(!cpu_rg), .reg_raddr(dma_raddr), .reg_rd,
        .trig9(dma_trig9), .gx_low(dma_gx_low), .stop9(dma_stop9), .trig7(dma_trig7),
        .m_req, .m_we, .m_cpu, .m_size32, .m_addr, .m_unit, .m_dst, .m_more, .m_wdata, .m_ack, .m_rdata,
        .busy(dma_busy), .irq9(dirq9), .irq7(dirq7), .dbg_run(dbg_dma_run), .lat_lost(dma_lat_lost));

    logic [31:0] t9_rd, t7_rd;
    logic [3:0]  tirq9, tirq7;
    // synthesis translate_off
    always @(posedge clk) if (!rst && tmr_oh !== ((wr && d_tmr) ? 8'd1 << {!a9, w[1:0]} : 8'd0))
        $display("nds_sys: ERROR: the fabric's timer decode (%b) is not this one's", tmr_oh);
    // synthesis translate_on
    // The ARM9's timers 0-1 increment in DSP blocks (2), with the fabric's
    // one-hot write select straight in and atmax off the DSP's output; its
    // timers 2-3 and all the ARM7's on carry chains (#731, #733-#737; #842:
    // be -> u_tmr7 ctr[1] -0.316 ns through the DSP; system-blocks.md, "Timers")
    // the timers' free-running prescaler, from power-on: reset doesn't touch it
    logic [9:0] tmr_dv = '0;
    always_ff @(posedge clk) if (tick) tmr_dv <= tmr_dv + 10'd1;
    wire [3:0] tmr_tap = {&tmr_dv[9:0], &tmr_dv[7:0], &tmr_dv[5:0], 1'b1} & {4{tick}};
    assign f1024 = tmr_tap[3];
    logic [31:0] t_rd;
    logic [7:0]  tirq /*verilator public_flat_rd*/;
    sys_timers u_tmr (.clk, .rst, .tick, .dv(tmr_dv), .acc(io_pre && d_tmr), .acc_i({!a9, w[1:0]}), .we(wr), .be(io_be),
        .wdata(io_wdata), .rdata(t_rd), .irq(tirq));
    assign t9_rd = t_rd; assign t7_rd = t_rd;
    assign tirq9 = tirq[3:0]; assign tirq7 = tirq[7:4];

    logic [15:0] sync_rd, cnt_rd;
    logic [31:0] recv_rd;
    logic [2:0]  pirq9, pirq7;
    sys_ipc u_ipc (.clk, .rst, .cpu(io_cpu), .sync_we(wr && d_sync), .cnt_we(wr && d_cnt),
        .send_we(wr && d_send), .recv_re(rd && d_recv), .be(io_be), .wdata(io_wdata),
        .rd_sync(sync_rd), .rd_cnt(cnt_rd), .rd_recv(recv_rd), .irq9(pirq9), .irq7(pirq7));

    logic [31:0] math_rd, math_res;
    sys_math #(.PUMP(PUMP)) u_math (.clk, .clk2, .rst, .tick, .we(wr && d_math), .be(io_be), .wa(w[3:0]),
        .wdata(io_wdata), .ra(w[3:0]), .rdata(math_rd), .res_q(math_res), .late(math_late));
    wire d_res = d_math && (w[3:2] == 2'b10 || w[3:0] == 4'd13);   // results, from sys_math's RAM
    // synthesis translate_off
    // +mathmon: every ARM9 access to DIVCNT..SQRT_PARAM with each unit's state
    // (D/S: busy, with the system cycles left), for timing-dependent readers
    logic [63:0] mm_cyc = 0;
    bit          mm_on;
    initial mm_on = $test$plusargs("mathmon");
    always @(posedge clk) begin
        mm_cyc <= mm_cyc + 64'd1;
        if (mm_on && io_req && d_math)
            $display("mathmon %0d %s %03x %08x be %x div %s%0d sqrt %s%0d", mm_cyc, io_we ? "W" : "R",
                     12'h280 + {w[3:0], 2'b00}, io_we ? io_wdata : math_rd, io_be,
                     u_math.dst == 2'd0 ? "idle" : "busy", u_math.dcnt, u_math.sst == 2'd0 ? "idle" : "busy", u_math.scnt);
    end
    // synthesis translate_on

    logic [31:0] i9_ime, i9_ie, i9_if, i7_ime, i7_ie, i7_if;
    sys_irq u_irq9 (.clk, .rst, .we(wr && d_irq && a9), .be(io_be), .sel(isel), .wdata(io_wdata),
        .src(irq_ext9 | {13'd0, pirq9, 4'd0, dirq9, 1'b0, tirq9, 3'd0}),
        .rd_ime(i9_ime), .rd_ie(i9_ie), .rd_if(i9_if), .irq(irq9));
    sys_irq u_irq7 (.clk, .rst, .we(wr && d_irq && !a9), .be(io_be), .sel(isel), .wdata(io_wdata),
        .src(irq_ext7 | {13'd0, pirq7, 4'd0, dirq7, 1'b0, tirq7, 3'd0}),
        .rd_ime(i7_ime), .rd_ie(i7_ie), .rd_if(i7_if), .irq(irq7));
    assign wake7 = |(i7_ie & i7_if);

    // ---- read data: flops muxed in the request cycle, RAMs the next
    logic [31:0] ff_rd;
    logic [3:0]  src_q;             // 0 flops, 2 FIFO, 8 DIV/SQRT results, else rg_kind
    logic        lane_q, en_q;
    always_ff @(posedge clk) begin
        ff_rd <= d_tmr  ? {16'd0, a9 ? t9_rd[15:0] : t7_rd[15:0]} :
                 d_sync ? {16'd0, sync_rd} :
                 d_cnt  ? {16'd0, cnt_rd} :
                 d_irq  ? (a9 ? i9_if : i7_if) :
                 d_math ? math_rd : 32'd0;
        src_q  <= d_recv ? 4'd2 : d_res ? 4'd8 : rg_hit ? {1'b0, rg_kind} : 4'd0;
        lane_q <= rg_lane;
        en_q   <= dma_en[{io_cpu, dch}];
        io_hit <= io_req && (d_dma || d_tmr || d_sync || d_cnt || d_send || d_recv || d_irq || d_math);
    end
    wire [31:0] rw = lane_q ? reg_rd[63:32] : reg_rd[31:0];
    always_comb begin
        unique case (src_q)
            4'd1: io_rdata = rw;
            4'd2: io_rdata = recv_rd;
            4'd3: io_rdata = {31'd0, rw[0]};
            4'd4: io_rdata = {rw[31:16], ff_rd[15:0]};
            4'd5: io_rdata = {16'd0, ff_rd[15:14], rw[13:2], ff_rd[1:0]};
            4'd6: io_rdata = {16'd0, ff_rd[15], rw[14:1], ff_rd[0]};
            4'd7: io_rdata = {en_q, rw[30:0]};
            4'd8: io_rdata = math_res;
            default: io_rdata = ff_rd;   // 0
        endcase
    end
endmodule
