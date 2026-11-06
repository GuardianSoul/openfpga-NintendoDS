// The eight DS DMA channels (ARM9 0..3, ARM7 0..3) in one engine, after
// melonDS DMA.cpp (WriteCnt, Start, Run9/Run7) and NDS::CheckDMAs/StopDMAs.
//
// The CPU-visible registers (SAD, DAD, CNT, the fill words) live in
// nds_sys's register RAM, which this engine reads through a granted port
// (CPU reads first). The working state lives in a RAM of its own, 8 words:
//   current source | current destination | {chunk[6:0], remaining[20:0]}
// written by the engine only. CNT reads take bit 31 from the enable flop.
// k = cpu*4 + channel. Flops per channel: enable, start mode, the address
// controls latched at the enable edge, and running / in-progress / resume.
//
// The engine loads one channel (CNT with the working word, then SAD/DAD),
// runs read/write units on the memory port, and writes the working word back
// when the channel finishes, ends a 112-word GX FIFO chunk, or is preempted
// at a unit boundary by a higher-priority channel (lower number on the same
// CPU; any ARM9 channel before any ARM7 channel). One unit is a read and a
// write, each held until m_ack: the cycle timing of a transfer is the memory
// port's, which applies the DS wait states (melonDS UnitTimings).
//
// The enable edge latches SAD/DAD into the working word as melonDS does: the
// CNT write's cycle leaves the register RAM's read port free, so SAD/DAD are
// read then and written to the work RAM in the next cycle, ahead of any
// engine save. The CPU never writes the work RAM, so the copy always has its
// slot.
// The engine does not load a channel while a copy is in flight.
//
// One adder steps the addresses: the memory address mux feeds it, and the
// sum goes back to the source after a read and to the destination after a
// write. Addresses are 28 bits (GBATEK's DMAxSAD/DAD; melonDS keeps 32).
//
// CNT takes 16-bit halves and words (melonDS ignores byte writes to CNT; so
// does this); nds_sys applies the same rule to its copy.
module sys_dma #(
    // FAST (docs/phase2-integration.md "DMA_FAST"): an ARM9 32-bit unit from
    // main RAM to I/O (not the timers), palette, VRAM or OAM is one request
    // (m_unit, with m_dst): the fabric reads and writes in one grant and acks
    // once. 0: every unit as a read and a write, as before
    parameter bit FAST = 0
) (
    input  logic        clk,
    input  logic        rst,
    // CNT writes, decoded by nds_sys
    input  logic        cnt_we,     // a 16/32-bit CNT write (melonDS's sizes)
    input  logic        cpu,
    input  logic [1:0]  ch,
    input  logic [3:0]  be,
    input  logic [31:0] wdata,
    output logic [7:0]  en_q,       // enables, for CNT bit 31 on reads
    // nds_sys's register RAM: {cpu, 00, ch} = {DAD, SAD}, {cpu, 01, ch} = {FILL, CNT}
    input  logic        reg_gnt,    // the read port is free this cycle
    output logic [4:0]  reg_raddr,
    input  logic [63:0] reg_rd,     // the cycle after the read
    // start and stop events
    input  logic [7:1]  trig9,      // pulses: 1 VBlank, 2 HBlank, 3 display start,
                                    // 4 main-memory display, 5 DS card, 6 GBA slot
    input  logic        gx_low,     // level: GX FIFO under half full (mode 7)
    input  logic [7:1]  stop9,      // pulses: clear enables in that mode (3, 4)
    input  logic [3:1]  trig7,      // pulses: 1 VBlank, 2 DS card, 3 wifi/GBA slot
    // memory port: request held until ack; 16-bit data in [15:0]
    output logic        m_req,
    output logic        m_we,
    output logic        m_cpu,
    output logic        m_size32,
    output logic [31:0] m_addr,
    output logic        m_unit,     // FAST: m_addr is the source, m_dst the destination, one ack for both
    output logic [31:0] m_dst,
    output logic        m_more,     // FAST: the run reads past this unit's 16-byte quad (the fabric may read ahead)
    output logic [31:0] m_wdata,
    input  logic        m_ack,
    input  logic [31:0] m_rdata,
    output logic [1:0]  busy,       // a channel of that CPU is running: stall it
    output logic [3:0]  irq9,
    output logic [3:0]  irq7,
    output logic [7:0]  dbg_run,    // per-channel running (test bench)
    output logic        lat_lost    // simulation check: an edge copy was dropped
);
    // ---- per-channel flops
    logic [7:0] en, run, inprog, resume;
    logic [2:0] mode [8];
    logic [1:0] sctl [8], dctl [8];

    wire [2:0] k = {cpu, ch};
    logic [2:0] ek;                 // the engine's channel

    // ---- the work RAM
    logic [2:0]  work_wa;
    logic [95:0] work_rd, work_wd;
    logic        work_we;
    logic [11:0] work_be;

    wire rise = cnt_we && be[3] && wdata[31] && !en[k];
    assign en_q = en;
    wire [31:0] cnt_rd = reg_rd[31:0];          // CNT, when an {01,ch} read lands

    sys_ram96 #(.AW(3)) u_work (.clk, .we(work_we), .be(work_be), .waddr(work_wa),
        .wdata(work_wd), .raddr(ek), .rdata(work_rd));

    // the enable edge's SAD/DAD read was issued last cycle
    logic        lr_v;
    logic [2:0]  lr_k;

    // ---- engine
    typedef enum logic [2:0] {E_IDLE, E_RCNT, E_RSD, E_SETUP, E_MRD, E_MWR, E_SAVE} est_t;
    est_t        est;
    logic [31:0] e_cnt, e_src, e_dst, e_data;
    logic [20:0] e_rem;
    logic [6:0]  e_chunk;
    logic        e_res;             // the loaded channel resumes a preempted run
    logic [1:0]  e_why;             // save reason: 0 preempt, 1 GX chunk end, 2 finished
    logic [1:0]  rtag;              // engine read in flight: 1 CNT and work, 3 SAD/DAD

    // priority pick: ARM9 0..3, then ARM7 0..3
    logic [2:0] pick;
    logic       any;
    always_comb begin
        pick = '0; any = 1'b0;
        for (int i = 7; i >= 0; i--) if (run[i]) begin pick = 3'(i); any = 1'b1; end
    end
    // a channel ahead of ek is running
    logic higher;
    always_comb begin
        higher = 1'b0;
        for (int i = 0; i < 8; i++) if (run[i] && 3'(i) < ek) higher = 1'b1;
    end

    // register RAM reads: the enable edge's SAD/DAD read, then the engine
    // (CNT with the work word, then SAD/DAD); nds_sys grants the port when
    // the CPU is not reading it
    wire eng_rgo = (est == E_RCNT || est == E_RSD) && reg_gnt && !rise;
    assign reg_raddr = rise ? {cpu, 2'b00, ch} : {ek[2], est == E_RCNT ? 2'b01 : 2'b00, ek[1:0]};

    // work RAM write port: the edge copy, then the engine's save
    wire save_go = est == E_SAVE && !lr_v;
    assign work_we = lr_v || save_go;
    assign work_wa = lr_v ? lr_k : ek;
    assign work_be = lr_v ? 12'h0FF : 12'hFFF;
    // (the edge copy writes byte lanes 0-7 only: the {chunk, remaining}
    // word needs no mux)
    assign work_wd = {4'd0, e_chunk, e_rem, lr_v ? reg_rd : {e_dst, e_src}};
    assign lat_lost = 1'b0;          // kept for the bench; the copy can no longer be lost


    // setup values (from the CNT RAM as it is read)
    wire        e_cpu   = ek[2];
    wire [20:0] cmask   = !e_cpu ? 21'h1F_FFFF : ek[1:0] == 2'd3 ? 21'h00_FFFF : 21'h00_3FFF;
    // a count of 0 means cmask + 1 units: the remaining count is kept masked
    // and the run ends when its masked decrement reaches 0, so 0 wraps there
    wire [20:0] count   = cnt_rd[20:0] & cmask;
    wire        gx      = !e_cpu && mode[ek] == 3'd7;
    wire        sz32    = e_cnt[26];
    // FAST: the unit as one request (main RAM to I/O but the timers, palette,
    // VRAM or OAM, 32-bit, ARM9)
    wire        u_dst   = e_dst[31:24] == 8'h05 || e_dst[31:24] == 8'h06 || e_dst[31:24] == 8'h07
                       || (e_dst[31:24] == 8'h04 && !(e_dst[23:12] == 12'd0 && e_dst[11:4] == 8'h10));
    // (an incrementing source: the unit steps the destination with the one
    // adder, anext, and the source with a +4 incrementer)
    wire        unit    = FAST && !e_cpu && sz32 && e_src[31:24] == 8'h02 && sctl[ek] == 2'd0 && u_dst;
    wire [1:0]  actl    = est == E_MWR || unit ? dctl[ek] : sctl[ek];
    wire [27:0] astep   = actl == 2'd2 ? 28'd0 : actl == 2'd1 ? (sz32 ? -28'd4 : -28'd2) : (sz32 ? 28'd4 : 28'd2);
    wire [27:0] anext   = (unit ? e_dst[27:0] : m_addr[27:0]) + astep;
    wire [20:0] rem_dec = (e_rem - 21'd1) & cmask;
    wire [6:0]  chk_dec = e_chunk - 7'd1;

    assign m_unit   = est == E_MRD && unit;
    assign m_dst    = e_dst;
    // units left after this one reach the next quad: e_rem > 4 - word (0: a full count)
    assign m_more   = e_rem[2:0] == 3'd0 || e_rem[20:3] != 18'd0 || e_rem[2:0] > 3'd4 - {1'b0, e_src[3:2]};
    assign m_req    = est == E_MRD || est == E_MWR;
    assign m_we     = est == E_MWR;
    assign m_cpu    = e_cpu;
    assign m_size32 = sz32;
    assign m_addr   = est == E_MWR ? e_dst : e_src;
    assign m_wdata  = sz32 ? e_data : {e_data[15:0], e_data[15:0]};

    logic [7:0] fin_irq;
    always_ff @(posedge clk) begin
        fin_irq <= '0;
        if (rst) begin
            en <= '0; run <= '0; inprog <= '0; resume <= '0;
            for (int i = 0; i < 8; i++) begin mode[i] <= '0; sctl[i] <= '0; dctl[i] <= '0; end
            est <= E_IDLE; lr_v <= 1'b0; rtag <= '0;
        end else begin
            // engine reads land the cycle after they are issued, straight into
            // the working registers: first CNT and the work word (Start()'s
            // count rules), then SAD/DAD for the reload address modes
            rtag <= eng_rgo ? (est == E_RCNT ? 2'd1 : 2'd3) : 2'd0;
            case (rtag)
                2'd1: begin
                    e_cnt <= cnt_rd;
                    e_src <= {4'd0, work_rd[27:0]}; e_dst <= {4'd0, work_rd[59:32]};
                    if (e_res) begin
                        e_rem <= work_rd[84:64]; e_chunk <= work_rd[91:85];
                    end else begin
                        logic [20:0] r;
                        r = inprog[ek] ? work_rd[84:64] : count;
                        e_rem   <= r;
                        e_chunk <= (gx && (r > 21'd112 || r == 21'd0)) ? 7'd112 : r[6:0];
                        inprog[ek] <= 1'b1;
                    end
                end
                2'd3: begin
                    if (!e_res && e_cnt[24:23] == 2'd3) e_src <= {4'd0, reg_rd[27:0]};
                    if (!e_res && e_cnt[22:21] == 2'd3) e_dst <= {4'd0, reg_rd[59:32]};
                end
                default: ;
            endcase

            lr_v <= rise; lr_k <= k;

            // starts (a running channel ignores them, as melonDS's Start does);
            // the engine's updates below override them in the cycle it ends a run
            for (int i = 0; i < 8; i++) begin
                logic t;
                if (i < 4) t = mode[i] == 3'd7 ? gx_low : mode[i] != 3'd0 && trig9[mode[i]];
                else       t = mode[i] != 3'd0 && trig7[mode[i][1:0]];
                if (en[i] && t) run[i] <= 1'b1;
                if (i < 4 && mode[i] != 3'd0 && stop9[mode[i]]) en[i] <= 1'b0;
            end

            unique case (est)
                E_IDLE: if (any && !lr_v && !rise) begin ek <= pick; e_res <= resume[pick]; est <= E_RCNT; end
                E_RCNT:  if (eng_rgo) est <= E_RSD;
                E_RSD:   if (eng_rgo) est <= E_SETUP;
                E_SETUP: if (rtag == 2'd0) begin
                    resume[ek] <= 1'b0;
                    est <= E_MRD;
                end
                E_MRD: if (m_ack && unit) begin
                    // FAST: the unit's read and write are both done
                    // (a unit's source is main RAM: its low 22 bits, mirrors beyond)
                    e_src[21:2] <= e_src[21:2] + 20'd1; e_dst <= {4'd0, anext};
                    e_rem <= rem_dec; e_chunk <= chk_dec;
                    if (rem_dec == 21'd0)            begin e_why <= 2'd2; est <= E_SAVE; end
                    else if (gx && chk_dec == 7'd0)  begin e_why <= 2'd1; est <= E_SAVE; end
                    else if (higher)                 begin e_why <= 2'd0; est <= E_SAVE; end
                end else if (m_ack) begin e_data <= m_rdata; e_src <= {4'd0, anext}; est <= E_MWR; end
                E_MWR: if (m_ack) begin
                    e_dst <= {4'd0, anext};
                    e_rem <= rem_dec; e_chunk <= chk_dec;
                    if (rem_dec == 21'd0)            begin e_why <= 2'd2; est <= E_SAVE; end
                    else if (gx && chk_dec == 7'd0)  begin e_why <= 2'd1; est <= E_SAVE; end
                    else if (higher)                 begin e_why <= 2'd0; est <= E_SAVE; end
                    else est <= E_MRD;
                end
                E_SAVE: if (save_go) begin
                    case (e_why)
                        2'd0: resume[ek] <= 1'b1;
                        2'd1: run[ek] <= 1'b0;
                        default: begin
                            run[ek] <= 1'b0; inprog[ek] <= 1'b0;
                            if (!e_cnt[25]) en[ek] <= 1'b0;
                            fin_irq[ek] <= e_cnt[30];
                        end
                    endcase
                    est <= E_IDLE;
                end
                default: est <= E_IDLE;
            endcase

            // CPU CNT writes
            if (cnt_we && be[3]) en[k] <= wdata[31];
            if (rise) begin
                mode[k] <= cpu ? {1'b0, wdata[29:28]} : wdata[29:27];
                dctl[k] <= wdata[22:21];
                sctl[k] <= wdata[24:23];
            end
            if (rise && (cpu ? wdata[29:28] == 2'd0 : wdata[29:27] == 3'd0)) run[k] <= 1'b1;
        end
    end

    assign busy = {|run[7:4], |run[3:0]};
    assign dbg_run = run;
    assign irq9 = fin_irq[3:0];
    assign irq7 = fin_irq[7:4];
endmodule
