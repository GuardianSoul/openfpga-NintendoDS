// The two DS CPUs: the shared pipeline (arm_core) with the ARM9's memory
// system (arm9_mem: CP15, MPU, TCMs, caches) on context 0. The ARM7's
// fetch and data ports (context 1) are passed through with the core's
// timing: request in F / E3, answer (data, ready) in F2 / WB.
module arm_cpu import arm_pkg::*; #(
  parameter logic [31:0] RESET_CTRL9 = 32'h0000_0078,
  parameter              RF_STYLE    = "M10K",
  // ARM9 cache ways (arm9_mem WAYS): 2, the cheaper caches the DS build uses
  // for the fit (2026-10-24); 4 is the ARM946E-S and stays tested
  parameter int          ARM9_WAYS   = 2,
  parameter bit          ARM9_EVB    = 1'b0,   // arm9_mem EVB: the eviction buffer
  parameter bit          ARM9_EARLYD = 1'b0,   // arm9_mem EARLYD
  parameter int          A9_XD       = 0,      // arm9_mem XD / XI: extra set bits of the D / I cache
  parameter int          A9_XI       = 0,
  parameter int          A9_OPT      = 0,      // ARM9 speed options (arm_core / arm9_mem bitmask)
  parameter bit          ARM9_EVBW   = 1'b0,   // arm9_mem EVBW: ... drained as one block write (b9_n8 + b9_we, b9_wnext)
  parameter bit          ARM9_BURST  = 1'b0,   // arm9_mem BURST: line fills as one request (b9_n8)
  parameter bit          A9_ONLY     = 1'b0,   // tb: the shared pipeline is the ARM9's alone (the ARM7 elsewhere)
  parameter bit          A7_DS       = 1'b0,   // the ARM7 is rtl/arm/arm7_ds.sv (DS-timed), the shared pipeline is the ARM9's alone
  parameter bit          A9_SOLO     = 1'b0,   // arm_core A9_SOLO: the ARM9 alone while the ARM7 is halted
  parameter bit          SLOW        = 1'b0    // the CPUs at clk_sys (67 MHz): smaller forms (arm_core/arm9_mem SLOW)
) (
  input  logic        clk,
  input  logic        rst,
  input  logic [1:0]  run,
  input  logic [31:0] reset_pc0,
  input  logic [31:0] reset_pc1,
  input  logic        hivecs7,
  input  logic [1:0]  irq,
  input  logic [1:0]  fiq,
  // ARM7 halt (melonDS NDS::HaltInterrupted): the ARM7's store of 0x80 to
  // HALTCNT (0x04000301) stops it issuing until IE & IF is nonzero (wake7),
  // whatever IME says. The halt is taken from the ARM7's own data port, in
  // the store's answer cycle, so it lands at that point of the instruction
  // stream: from the I/O register it came cycles later, after an IRQ handler
  // could already have cleared IF, and the ARM7 then slept a timer period
  // too long (irq.nds A7TIMER). The ARM9's CP15 wait-for-interrupt ends on
  // its IRQ line (IME-gated).
  input  logic        wake7,

  // ARM9 bus (from arm9_mem)
  output logic        b9_n8,
  input  logic        b9_wnext,
  output logic        b9_req,
  output logic        b9_we,
  output logic [31:0] b9_addr,
  output logic [31:0] b9_wdata,
  output logic [3:0]  b9_be,
  output logic [3:0]  b9_tmr,     // arm9_mem b_tmr
  input  logic        b9_ack,
  input  logic [31:0] b9_rdata,

  // ARM7 ports
  output logic        a7_i_req,
  output logic [31:0] a7_i_addr,
  input  logic [31:0] a7_i_rdata,
  input  logic        a7_i_ok,
  output logic        a7_d_req,
  output logic        a7_d_we,
  output logic [3:0]  a7_d_be,
  output logic [31:0] a7_d_addr,
  output logic [31:0] a7_d_wdata,
  input  logic [31:0] a7_d_rdata,
  input  logic        a7_d_ok,

  // trace
  output logic        dbg_wen,
  output logic [5:0]  dbg_wa,
  output logic [31:0] dbg_wd,
  output logic        dbg_retire,
  output logic        dbg_tid,
  output logic [31:0] dbg_pc,
  output logic [31:0] dbg_cpsr,
  output logic [1:0]  dbg_halt,             // {ARM7, ARM9} halted (diagnostics)
  output logic [1:0]  dg_fill               // ARM9 {I, D} line fill starts (diagnostics)
);
  logic        i_req, i_tid, i_priv, i_ok, i_abort;
  logic [31:0] i_addr, i_rdata;
  logic        d_req, d_tid, d_priv, d_we, d_ok, d_abort, m9_kill;
  logic [1:0]  d_size;
  logic [3:0]  d_be;
  logic [31:0] d_addr, d_wdata, d_rdata;
  logic        cp_req, cp_we;
  logic [15:0] cp_op;
  logic [31:0] cp_wdata;
  logic        m_i_ok, m_i_abort, m_d_ok, m_d_abort, m_d_wait, m_hivecs;
  logic [31:0] m_i_rdata, m_d_rdata;
  logic        f2_tid, wb_tid;              // which context the answer is for
  logic        haltst, halt7;               // the ARM7's HALTCNT store / accepted

  logic        c_dbg_wen, c_dbg_retire, c_dbg_tid;
  logic [5:0]  c_dbg_wa;
  logic [31:0] c_dbg_wd, c_dbg_pc, c_dbg_cpsr;
  logic [1:0]  c_dbg_halt;
  arm_core #(.V5(2'b01), .RF_STYLE(RF_STYLE), .A9_SOLO(A9_SOLO), .SOLO_ONLY(A7_DS || A9_ONLY), .A9_OPT(A9_OPT), .SLOW(SLOW)) u_core (
    .clk(clk), .rst(rst), .run((A7_DS || A9_ONLY) ? {1'b0, run[0]} : run), .reset_pc0(reset_pc0), .reset_pc1(reset_pc1),
    .hivecs({hivecs7, m_hivecs}), .irq(irq), .fiq(fiq),
    .halt_req({halt7, 1'b0}), .wake({wake7, irq[0]}),
    .i_req(i_req), .i_tid(i_tid), .i_priv(i_priv), .i_addr(i_addr), .i_rdata(i_rdata),
    .i_ok(i_ok), .i_abort(i_abort),
    .d_req(d_req), .d_tid(d_tid), .d_priv(d_priv), .d_we(d_we), .d_size(d_size), .d_be(d_be),
    .d_addr(d_addr), .d_wdata(d_wdata), .d_rdata(d_rdata), .d_ok(d_ok), .d_abort(d_abort),
    .d_wait({1'b0, m_d_wait}), .d_kill(m9_kill),
    .cp_req(cp_req), .cp_we(cp_we), .cp_op(cp_op), .cp_wdata(cp_wdata),
    .dbg_wen(c_dbg_wen), .dbg_wa(c_dbg_wa), .dbg_wd(c_dbg_wd), .dbg_retire(c_dbg_retire),
    .dbg_tid(c_dbg_tid), .dbg_pc(c_dbg_pc), .dbg_cpsr(c_dbg_cpsr), .dbg_halt(c_dbg_halt));

  logic m9_ireq, m9_dreq, m9_cpreq;
  assign m9_ireq  = i_req && !i_tid;
  assign m9_dreq  = d_req && !d_tid;
  assign m9_cpreq = cp_req && !d_tid;

  arm9_mem #(.RESET_CTRL(RESET_CTRL9), .WAYS(ARM9_WAYS), .BURST(ARM9_BURST), .SLOW(SLOW), .EVB(ARM9_EVB), .EVBW(ARM9_EVBW), .EARLYD(ARM9_EARLYD), .OPT(A9_OPT), .XD(A9_XD), .XI(A9_XI)) u_mem9 (
    .clk(clk), .rst(rst),
    .i_req(m9_ireq), .i_priv(i_priv), .i_addr(i_addr),
    .i_rdata(m_i_rdata), .i_ok(m_i_ok), .i_abort(m_i_abort),
    .d_req(m9_dreq), .d_kill(m9_kill), .d_we(d_we), .d_priv(d_priv), .d_be(d_be), .d_addr(d_addr),
    .d_wdata(d_wdata), .cp_req(m9_cpreq), .cp_we(cp_we), .cp_op(cp_op), .cp_wdata(cp_wdata),
    .d_rdata_f(m_d_rdata), .d_ok(m_d_ok), .d_abort(m_d_abort), .d_wait(m_d_wait),
    .hivecs(m_hivecs),
    .b_n8(b9_n8), .b_wnext(b9_wnext), .dg_fill(dg_fill), .b_req(b9_req), .b_we(b9_we), .b_addr(b9_addr), .b_wdata(b9_wdata), .b_be(b9_be), .b_tmr(b9_tmr),
    .b_ack(b9_ack), .b_rdata(b9_rdata));

  generate if (A7_DS) begin : g_a7ds
    logic        l_wen, l_ret, l_halted;
    logic [4:0]  l_wa;
    logic [31:0] l_wd, l_pc, l_cpsr;
    arm7_ds u_a7 (
      .clk(clk), .rst(rst), .run(run[1]), .reset_pc(reset_pc1), .hivecs(hivecs7), .irq(irq[1]), .fiq(fiq[1]),
      .wake(wake7),
      .i_req(a7_i_req), .i_addr(a7_i_addr), .i_rdata(a7_i_rdata), .i_ok(a7_i_ok),
      .d_req(a7_d_req), .d_we(a7_d_we), .d_be(a7_d_be), .d_addr(a7_d_addr), .d_wdata(a7_d_wdata),
      .d_rdata(a7_d_rdata), .d_ok(a7_d_ok),
      .dbg_wen(l_wen), .dbg_wa(l_wa), .dbg_wd(l_wd), .dbg_retire(l_ret), .dbg_pc(l_pc), .dbg_cpsr(l_cpsr),
      .dbg_halted(l_halted));
    assign dbg_wen    = l_wen || c_dbg_wen;
    assign dbg_wa     = l_wen ? {1'b1, l_wa} : c_dbg_wa;
    assign dbg_wd     = l_wen ? l_wd : c_dbg_wd;
    assign dbg_retire = l_ret || c_dbg_retire;
    assign dbg_tid    = l_ret ? 1'b1 : c_dbg_tid;
    assign dbg_pc     = l_ret ? l_pc : c_dbg_pc;
    assign dbg_cpsr   = l_ret ? l_cpsr : c_dbg_cpsr;
    assign dbg_halt   = {l_halted, c_dbg_halt[0]};
    assign halt7      = 1'b0;
  end else begin : g_a7core
    assign a7_i_req   = i_req && i_tid;
    assign a7_i_addr  = i_addr;
    assign a7_d_req   = d_req && d_tid;
    assign a7_d_we    = d_we;
    assign a7_d_be    = d_be;
    assign a7_d_addr  = d_addr;
    assign a7_d_wdata = d_wdata;
    assign dbg_wen = c_dbg_wen; assign dbg_wa = c_dbg_wa; assign dbg_wd = c_dbg_wd; assign dbg_retire = c_dbg_retire;
    assign dbg_tid = c_dbg_tid; assign dbg_pc = c_dbg_pc; assign dbg_cpsr = c_dbg_cpsr; assign dbg_halt = c_dbg_halt;
    // (an accepted store: a refused one is replayed and counts then)
    assign halt7 = haltst && wb_tid && a7_d_ok;
  end endgenerate

  always_ff @(posedge clk) begin
    f2_tid <= i_tid;
    wb_tid <= d_tid;
    haltst <= a7_d_req && a7_d_we && a7_d_addr[31:2] == 30'h010000C0 && a7_d_be[1] &&
              a7_d_wdata[15:8] == 8'h80;
  end

  assign i_rdata = f2_tid ? a7_i_rdata : m_i_rdata;
  assign i_ok    = f2_tid ? a7_i_ok : m_i_ok;
  assign i_abort = f2_tid ? 1'b0 : m_i_abort;
  assign d_rdata = wb_tid ? a7_d_rdata : m_d_rdata;
  assign d_ok    = wb_tid ? a7_d_ok : m_d_ok;
  assign d_abort = wb_tid ? 1'b0 : m_d_abort;
endmodule
