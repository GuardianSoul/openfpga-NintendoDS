// The two CPUs with the ARM7's port, optionally on their own clock
// (CPU_FAST; docs/arm-pipeline.md "Built: CPU_FAST"). Its other side has the
// signals nds_top used to connect to arm_cpu and nds_arm7_port directly, all
// on clk (clk_sys).
//
// CPU_FAST = 0: one clock, plain wires: the same design as without this
// wrapper. CPU_FAST = 1: arm_cpu and the ARM7 port run on clk_cpu, and
// everything else crosses:
//   - ARM9 bus (b9), ARM7 fabric (f7), ARM7 SRAM (x7): requests held until
//     done, through cdc_req. A9_BURST: an ARM9 line fill crosses once; its
//     eight words are requested on clk's side and come back through a
//     cdc_fifo (one crossing per line instead of one per word)
//   - write snoops (fr_inv, mon): cdc_fifo, one entry per clk_sys cycle,
//     read every clk_cpu cycle
//   - irq, wake7, run, wramcnt, resets: synchronisers
// Ordering kept across the crossing:
//   - the ARM7's fabric request waits to start while it has SRAM stores not
//     yet done (an IPC write must not overtake its own shared-WRAM stores);
//     cdc_a7 has the details
//   - irq and wake7 take one flop more than the snoop FIFO's pointer and wait
//     while it holds entries (a write's invalidation reaches the ARM7's
//     caches before the interrupt that may announce it)
//   - the ARM7 boot ROM (0x8000-0x9FFF) is read through the fabric
//     (nds_arm7_port BOOT_FAB), so the ROM stays on clk_sys for the fabric
module cpu_domain #(
  parameter int CPU_FAST   = 0,
  parameter int ARM9_WAYS  = 2,
  parameter int ARM7_CACHE = 1,
  parameter int A7_IL      = 7,
  parameter int A7_DL      = 6,
  parameter int A9_EVB     = 0,         // arm9_mem EVB: the eviction buffer
  parameter int A9_EARLYD  = 0,         // arm9_mem EARLYD
  parameter int A7_BOOTF   = 0,         // 1: the ARM7's boot ROM accesses go through the fabric (nds_top BOOT_SRAM)
  parameter int A9_XD      = 0,         // arm9_mem XD / XI: extra set bits of the D / I cache
  parameter int A9_XI      = 0,
  parameter int A9_OPT     = 0,         // ARM9 speed options (arm_core / arm9_mem bitmask)
  parameter int A9_EVBW    = 0,         // EVB drained as a block write (CPU_FAST = 0 only)
  parameter int A9_BURST   = 0,         // arm9_mem BURST (line fills as one request)
  parameter int MR_BLOCK   = 0,         // A9_BURST: the fabric serves a fill as one block (b9_n8, b9_rvalid beats)
  parameter int A9_SOLO    = 0          // arm_core A9_SOLO: the ARM9 issues every cycle while the ARM7 is halted
) (
  input  logic        clk,              // clk_sys
  input  logic        clk_cpu,          // CPU_FAST: the CPUs' clock
  input  logic        rst,              // the ARM7 port's reset
  input  logic        cpu_rst,          // the CPUs' reset
  input  logic [1:0]  run,
  input  logic [1:0]  irq,
  input  logic        wake7,
  input  logic [1:0]  wramcnt,
  // ARM9 bus (MR_BLOCK: b9_n8 asks for the 32-byte line of b9_addr, its words
  // come as 8 b9_rvalid beats with b9_rdata, b9_ack with the last)
  output logic        b9_n8,
  input  logic        b9_rvalid,
  input  logic        b9_wnext,         // A9_EVBW: the fabric takes the block write's word on b9_wdata this clock
  output logic        b9_req,
  output logic        b9_we,
  output logic [31:0] b9_addr,
  output logic [31:0] b9_wdata,
  output logic [3:0]  b9_be,
  output logic [3:0]  b9_tmr,     // the request writes ARM9 timer n (one-hot; nds_fabric's timer decode)
  input  logic        b9_ack,
  input  logic [31:0] b9_rdata,
  // ARM7 port: boot ROM (CPU_FAST = 0 only), SRAM, fabric, snoops
  output logic [10:0] p7_ib,
  input  logic [31:0] boot_qa,
  output logic [10:0] p7_db,
  output logic        p7_dboot,
  input  logic [31:0] boot_qb,
  output logic        x7_req,
  output logic        x7_we,
  output logic [17:2] x7_addr,
  output logic [3:0]  x7_be,
  output logic [31:0] x7_wdata,
  output logic        x7_stores,
  input  logic        x7_done,
  input  logic [31:0] x7_rdata,
  input  logic        fr_inv,
  input  logic [17:2] fr_inv_a,
  output logic        f7_req,
  output logic        f7_we,
  output logic [31:0] f7_addr,
  output logic [3:0]  f7_be,
  output logic [31:0] f7_wdata,
  input  logic        f7_ack,
  input  logic [31:0] f7_rdata,
  input  logic        mon_we,
  input  logic [31:0] mon_addr,
  // trace (on clk_cpu with CPU_FAST)
  output logic        dbg_wen,
  output logic [5:0]  dbg_wa,
  output logic [31:0] dbg_wd,
  output logic        dbg_retire,
  output logic        dbg_tid,
  output logic [31:0] dbg_pc,
  output logic [31:0] dbg_cpsr,
  output logic [1:0]  dbg_halt,             // {ARM7, ARM9} halted (diagnostics; CPU clock)
  output logic [1:0]  dg_fill               // ARM9 {I, D} line fill starts (diagnostics; CPU clock)
);
  localparam bit FAST = (CPU_FAST != 0);
  wire cclk = FAST ? clk_cpu : clk;

  // ---- the CPU side's view of the sys-side signals
  logic        c_rst, c_cpu_rst, c_wake7;
  logic [1:0]  c_run, c_irq, c_wramcnt;
  logic        c_b9_ack, c_x7_done, c_f7_ack, c_inv, c_mon;
  logic [31:0] c_b9_rdata, c_x7_rdata, c_f7_rdata, c_mon_a;
  logic [17:2] c_inv_a;
  // CPU-side requests
  logic        a7_i_req, a7_i_ok, a7_d_req, a7_d_we, a7_d_ok;
  logic [31:0] a7_i_addr, a7_i_rdata, a7_d_addr, a7_d_wdata, a7_d_rdata;
  logic [3:0]  a7_d_be;
  logic        c_b9_req, c_b9_we, c_x7_req, c_x7_we, c_x7_stores, c_f7_req, c_f7_we;
  logic [31:0] c_b9_addr, c_b9_wdata, c_x7_wdata, c_f7_addr, c_f7_wdata;
  logic [3:0]  c_b9_be, c_x7_be, c_f7_be, c_b9_tmr;
  logic [17:2] c_x7_addr;

  logic        c_b9_n8;
  generate if ((A9_SOLO & 2) == 0) begin : g_one
  arm_cpu #(.A7_DS((A9_SOLO & 4) != 0), .ARM9_EVB(A9_EVB != 0), .ARM9_EARLYD(A9_EARLYD != 0), .A9_OPT(A9_OPT), .A9_XD(A9_XD), .A9_XI(A9_XI), .ARM9_EVBW(A9_EVBW != 0 && CPU_FAST == 0), .ARM9_WAYS(ARM9_WAYS), .ARM9_BURST(A9_BURST != 0), .A9_SOLO((A9_SOLO & 1) != 0), .SLOW(CPU_FAST == 0)) u_cpu (
      .clk(cclk), .rst(c_cpu_rst), .run(c_run),
      .reset_pc0(32'hFFFF_8000), .reset_pc1(32'h0000_8004), .hivecs7(1'b0),
      .wake7(c_wake7), .irq(c_irq), .fiq(2'b00),
      .b9_n8(c_b9_n8), .b9_wnext(CPU_FAST == 0 && b9_wnext), .b9_req(c_b9_req), .b9_we(c_b9_we), .b9_addr(c_b9_addr), .b9_wdata(c_b9_wdata), .b9_be(c_b9_be), .b9_tmr(c_b9_tmr),
      .b9_ack(c_b9_ack), .b9_rdata(c_b9_rdata),
      .a7_i_req, .a7_i_addr, .a7_i_rdata, .a7_i_ok,
      .a7_d_req, .a7_d_we, .a7_d_be, .a7_d_addr, .a7_d_wdata, .a7_d_rdata, .a7_d_ok,
      .dbg_wen, .dbg_wa, .dbg_wd, .dbg_retire, .dbg_tid, .dbg_pc, .dbg_cpsr, .dbg_halt, .dg_fill);
  end else begin : g_split
    // A9_SOLO bit 1 (simulation only: what a single-issue ARM9 gains): the ARM9 alone in its own arm_cpu, in
    // permanent solo (its ARM7 context never runs), the ARM7 in a second arm_cpu on the barrel with an idle ARM9
    logic        ra, rb;
    logic        a_wen, a_tid, b_wen, b_tid;
    logic [5:0]  a_wa, b_wa;
    logic [31:0] a_wd, a_pc, a_cpsr, b_wd, b_pc, b_cpsr;
    logic [1:0]  a_halt, b_halt, a_fill, b_fill;
    logic        a_a7_i_req, a_a7_d_req, a_a7_d_we;
    logic [31:0] a_a7_i_addr, a_a7_d_addr, a_a7_d_wdata;
    logic [3:0]  a_a7_d_be;
    logic        b_b9_n8, b_b9_req, b_b9_we;
    logic [31:0] b_b9_addr, b_b9_wdata;
    logic [3:0]  b_b9_be, b_b9_tmr;
    arm_cpu #(.ARM9_EVB(A9_EVB != 0), .ARM9_EARLYD(A9_EARLYD != 0), .A9_OPT(A9_OPT), .A9_XD(A9_XD), .A9_XI(A9_XI), .ARM9_EVBW(A9_EVBW != 0 && CPU_FAST == 0), .ARM9_WAYS(ARM9_WAYS), .ARM9_BURST(A9_BURST != 0), .A9_SOLO(1'b1), .SLOW(CPU_FAST == 0)) u_cpu (
      .clk(cclk), .rst(c_cpu_rst), .run({1'b0, c_run[0]}),
      .reset_pc0(32'hFFFF_8000), .reset_pc1(32'h0000_8004), .hivecs7(1'b0),
      .wake7(1'b0), .irq({1'b0, c_irq[0]}), .fiq(2'b00),
      .b9_n8(c_b9_n8), .b9_wnext(CPU_FAST == 0 && b9_wnext), .b9_req(c_b9_req), .b9_we(c_b9_we), .b9_addr(c_b9_addr), .b9_wdata(c_b9_wdata), .b9_be(c_b9_be), .b9_tmr(c_b9_tmr),
      .b9_ack(c_b9_ack), .b9_rdata(c_b9_rdata),
      .a7_i_req(a_a7_i_req), .a7_i_addr(a_a7_i_addr), .a7_i_rdata(32'h0), .a7_i_ok(1'b0),
      .a7_d_req(a_a7_d_req), .a7_d_we(a_a7_d_we), .a7_d_be(a_a7_d_be), .a7_d_addr(a_a7_d_addr), .a7_d_wdata(a_a7_d_wdata), .a7_d_rdata(32'h0), .a7_d_ok(1'b0),
      .dbg_wen(a_wen), .dbg_wa(a_wa), .dbg_wd(a_wd), .dbg_retire(ra), .dbg_tid(a_tid), .dbg_pc(a_pc), .dbg_cpsr(a_cpsr), .dbg_halt(a_halt), .dg_fill(a_fill));
    arm_cpu #(.ARM9_WAYS(2), .SLOW(CPU_FAST == 0)) u_cpu7 (
      .clk(cclk), .rst(c_cpu_rst), .run({c_run[1], 1'b0}),
      .reset_pc0(32'hFFFF_8000), .reset_pc1(32'h0000_8004), .hivecs7(1'b0),
      .wake7(c_wake7), .irq({c_irq[1], 1'b0}), .fiq(2'b00),
      .b9_n8(b_b9_n8), .b9_wnext(1'b0), .b9_req(b_b9_req), .b9_we(b_b9_we), .b9_addr(b_b9_addr), .b9_wdata(b_b9_wdata), .b9_be(b_b9_be), .b9_tmr(b_b9_tmr),
      .b9_ack(1'b0), .b9_rdata(32'h0),
      .a7_i_req, .a7_i_addr, .a7_i_rdata, .a7_i_ok,
      .a7_d_req, .a7_d_we, .a7_d_be, .a7_d_addr, .a7_d_wdata, .a7_d_rdata, .a7_d_ok,
      .dbg_wen(b_wen), .dbg_wa(b_wa), .dbg_wd(b_wd), .dbg_retire(rb), .dbg_tid(b_tid), .dbg_pc(b_pc), .dbg_cpsr(b_cpsr), .dbg_halt(b_halt), .dg_fill(b_fill));
    assign dbg_wen = a_wen; assign dbg_wa = a_wa; assign dbg_wd = a_wd; assign dbg_cpsr = a_cpsr;
    assign dbg_retire = ra | rb; assign dbg_tid = rb & ~ra; assign dbg_pc = (rb & ~ra) ? b_pc : a_pc;
    assign dbg_halt = {b_halt[1], a_halt[0]}; assign dg_fill = a_fill;
  end endgenerate

  generate if (ARM7_CACHE != 0) begin : g_a7c
    nds_arm7_port #(.IL(A7_IL), .DL(A7_DL), .BOOT_FAB(FAST || A7_BOOTF != 0)) u_p7 (.clk(cclk), .rst(c_rst),
        .wramcnt(c_wramcnt),
        .i_req(a7_i_req), .i_addr(a7_i_addr), .i_rdata(a7_i_rdata), .i_ok(a7_i_ok),
        .d_req(a7_d_req), .d_we(a7_d_we), .d_be(a7_d_be), .d_addr(a7_d_addr), .d_wdata(a7_d_wdata),
        .d_rdata(a7_d_rdata), .d_ok(a7_d_ok),
        .ib_addr(p7_ib), .i_boot_q(boot_qa), .db_addr(p7_db), .d_boot(p7_dboot), .d_boot_q(boot_qb),
        .x_req(c_x7_req), .x_we(c_x7_we), .x_addr(c_x7_addr), .x_be(c_x7_be), .x_wdata(c_x7_wdata),
        .x_stores(c_x7_stores), .x_done(c_x7_done), .x_rdata(c_x7_rdata),
        .inv(c_inv), .inv_addr(c_inv_a),
        .f_req(c_f7_req), .f_we(c_f7_we), .f_addr(c_f7_addr), .f_be(c_f7_be), .f_wdata(c_f7_wdata),
        .f_ack(c_f7_ack), .f_rdata(c_f7_rdata), .wr_mon(c_mon), .wr_addr(c_mon_a));
  end else begin : g_a7m
    nds_arm7_port_min #(.BOOT_FAB(FAST || A7_BOOTF != 0)) u_p7 (.clk(cclk), .rst(c_rst),
        .wramcnt(c_wramcnt),
        .i_req(a7_i_req), .i_addr(a7_i_addr), .i_rdata(a7_i_rdata), .i_ok(a7_i_ok),
        .d_req(a7_d_req), .d_we(a7_d_we), .d_be(a7_d_be), .d_addr(a7_d_addr), .d_wdata(a7_d_wdata),
        .d_rdata(a7_d_rdata), .d_ok(a7_d_ok),
        .ib_addr(p7_ib), .i_boot_q(boot_qa), .db_addr(p7_db), .d_boot(p7_dboot), .d_boot_q(boot_qb),
        .x_req(c_x7_req), .x_we(c_x7_we), .x_addr(c_x7_addr), .x_be(c_x7_be), .x_wdata(c_x7_wdata),
        .x_stores(c_x7_stores), .x_done(c_x7_done), .x_rdata(c_x7_rdata),
        .inv(c_inv), .inv_addr(c_inv_a),
        .f_req(c_f7_req), .f_we(c_f7_we), .f_addr(c_f7_addr), .f_be(c_f7_be), .f_wdata(c_f7_wdata),
        .f_ack(c_f7_ack), .f_rdata(c_f7_rdata), .wr_mon(c_mon), .wr_addr(c_mon_a));
  end endgenerate

  generate if (!FAST) begin : g_same
    // ---- one clock: wires
    assign c_rst = rst; assign c_cpu_rst = cpu_rst;
    assign c_run = run; assign c_irq = irq; assign c_wake7 = wake7;
    assign c_wramcnt = wramcnt;
    assign b9_req = c_b9_req; assign b9_we = c_b9_we; assign b9_addr = c_b9_addr;
    assign b9_wdata = c_b9_wdata; assign b9_be = c_b9_be; assign b9_tmr = c_b9_tmr;
    assign b9_n8 = MR_BLOCK != 0 && c_b9_n8;
    assign c_b9_ack = (b9_n8 && !c_b9_we) ? b9_rvalid : b9_ack; assign c_b9_rdata = b9_rdata;
    assign x7_req = c_x7_req; assign x7_we = c_x7_we; assign x7_addr = c_x7_addr;
    assign x7_be = c_x7_be; assign x7_wdata = c_x7_wdata; assign x7_stores = c_x7_stores;
    assign c_x7_done = x7_done; assign c_x7_rdata = x7_rdata;
    assign f7_req = c_f7_req; assign f7_we = c_f7_we; assign f7_addr = c_f7_addr;
    assign f7_be = c_f7_be; assign f7_wdata = c_f7_wdata;
    assign c_f7_ack = f7_ack; assign c_f7_rdata = f7_rdata;
    assign c_inv = fr_inv; assign c_inv_a = fr_inv_a; assign c_mon = mon_we; assign c_mon_a = mon_addr;
  end else begin : g_fast
    // ---- resets and slow signals into clk_cpu
    logic [1:0]  rs_q, crs_q;
    logic [1:0]  run0, run1, wc0, wc1;
    logic [2:0]  irq9_s, irq7_s, wk_s;
    always_ff @(posedge clk_cpu) begin
      rs_q <= {rs_q[0], rst}; crs_q <= {crs_q[0], cpu_rst};
      run0 <= run; run1 <= run0;
      wc0 <= wramcnt; wc1 <= wc0;
      irq9_s <= {irq9_s[1:0], irq[0]};
      irq7_s <= {irq7_s[1:0], irq[1]};
      wk_s   <= {wk_s[1:0], wake7};
    end
    assign c_rst = rs_q[1]; assign c_cpu_rst = crs_q[1];
    assign c_run = run1; assign c_wramcnt = wc1;

    // ---- write snoops: one FIFO entry per clk_sys cycle that has any
    logic        sn_v;
    logic [49:0] sn_d;
    cdc_fifo #(.W(50), .AB(3)) u_snoop (
      .w_clk(clk), .w_rst(rst), .w_en(fr_inv || mon_we), .w_d({fr_inv, fr_inv_a, mon_we, mon_addr}),
      .r_clk(clk_cpu), .r_rst(c_rst), .r_v(sn_v), .r_d(sn_d), .r_take(1'b1));
    assign c_inv   = sn_v && sn_d[49];
    assign c_inv_a = sn_d[48:33];
    assign c_mon   = sn_v && sn_d[32];
    assign c_mon_a = sn_d[31:0];
    // interrupts after the invalidations that came before them
    assign c_irq   = {irq7_s[2] && !sn_v, irq9_s[2] && !sn_v};
    assign c_wake7 = wk_s[2] && !sn_v;

    // ---- requests held until done
    // A line fill (n8) crosses as one request: clk's side asks for its words
    // one by one (s_k), each answer goes back through u_b9q as one beat, and
    // the crossing's own answer for it is dropped (the fill already ended).
    logic        u_done, s_req9, s_n8, sb_v, m_n8;
    logic [31:0] u_q, s_addr9, sb_d;
    logic [2:0]  s_k;
    cdc_req #(.PW(70), .QW(32)) u_b9 (
      .m_clk(clk_cpu), .m_rst(c_cpu_rst), .m_req(c_b9_req),
      .m_p({c_b9_n8, c_b9_we, c_b9_be, c_b9_addr, c_b9_wdata}), .m_done(u_done), .m_q(u_q),
      .s_clk(clk), .s_rst(cpu_rst), .s_req(s_req9), .s_p({s_n8, b9_we, b9_be, s_addr9, b9_wdata}),
      .s_done(b9_ack && (!s_n8 || MR_BLOCK != 0 || s_k == 3'd7)), .s_q(b9_rdata));
    // without MR_BLOCK the words are asked for one by one (s_k); with it the
    // fabric takes the line as one block and answers with b9_rvalid beats
    wire   s_beat  = MR_BLOCK != 0 ? b9_rvalid : b9_ack;
    assign b9_req  = s_req9;
    assign b9_n8   = MR_BLOCK != 0 && s_n8;
    assign b9_addr = s_n8 && MR_BLOCK == 0 ? {s_addr9[31:5], s_k, 2'b00} : s_addr9;
    // the crossing's fields are registers here: decode them directly
    assign b9_tmr  = b9_we && s_addr9[31:12] == 20'h04000 && s_addr9[11:4] == 8'h10 ? 4'd1 << s_addr9[3:2] : 4'd0;
    always_ff @(posedge clk)
      if (cpu_rst || !s_req9) s_k <= 3'd0;
      else if (b9_ack && s_n8) s_k <= s_k + 3'd1;
    cdc_fifo #(.W(32), .AB(3)) u_b9q (
      .w_clk(clk), .w_rst(cpu_rst), .w_en(s_beat && s_n8), .w_d(b9_rdata),
      .r_clk(clk_cpu), .r_rst(c_cpu_rst), .r_v(sb_v), .r_d(sb_d), .r_take(1'b1));
    // a fill is in flight (set while its request is up, cleared by the
    // crossing's answer, which then belongs to it and is dropped): only a
    // single request's answer ends a transfer
    always_ff @(posedge clk_cpu)
      if (c_cpu_rst)               m_n8 <= 1'b0;
      else if (c_b9_req && c_b9_n8) m_n8 <= 1'b1;
      else if (u_done)             m_n8 <= 1'b0;
    assign c_b9_ack   = A9_BURST != 0 ? (sb_v || (u_done && !m_n8)) : u_done;
    assign c_b9_rdata = A9_BURST != 0 && sb_v ? sb_d : u_q;
    // the ARM7 port's SRAM and fabric requests, and x7_stores (cdc_a7)
    cdc_a7 #(.STORE_GATE(ARM7_CACHE != 0)) u_a7x (.clk_cpu, .c_rst, .clk, .rst,
      .c_x7_req, .c_x7_we, .c_x7_addr, .c_x7_be, .c_x7_wdata, .c_x7_stores, .c_x7_done, .c_x7_rdata,
      .c_f7_req, .c_f7_we, .c_f7_addr, .c_f7_be, .c_f7_wdata, .c_f7_ack, .c_f7_rdata,
      .x7_req, .x7_we, .x7_addr, .x7_be, .x7_wdata, .x7_stores, .x7_done, .x7_rdata,
      .f7_req, .f7_we, .f7_addr, .f7_be, .f7_wdata, .f7_ack, .f7_rdata);
  end endgenerate
endmodule
