// Clock-exact lockstep of rtl/arm/arm7_ds.sv against an earlier revision (arm7_ref, sim/arm/tools/a7lock_test.sh).
// Both run from one memory answered to the reference's requests: code is a hash of the address, biased to the
// rare instruction groups (r15 as an operand, LDM/STM forms, long multiplies, SWP, PSR writes, SWI, undefined),
// with random waits, IRQ, FIQ, wake and run. Every clock, every output the core shows outside must be the same.
`timescale 1ns/1ps
module tb_a7lock;
  logic clk = 0; always #1 clk = !clk;
  logic rst = 1, run = 1, irq = 0, fiq = 0, wake = 0, i_ok = 0, d_ok = 0;
  logic [31:0] i_rdata = 0, d_rdata = 0, reset_pc = 0;
  int unsigned seed = 1;
  longint cycles = 2000000, n = 0;

  typedef struct packed {
    logic i_req; logic [31:0] i_addr; logic d_req; logic d_we; logic [3:0] d_be; logic [31:0] d_addr, d_wdata;
    logic wen; logic [4:0] wa; logic [31:0] wd; logic ret; logic [31:0] pc, cpsr; logic halted;
  } out_t;
  out_t a, b;
  arm7_ref u_ref (.clk, .rst, .run, .reset_pc, .hivecs(1'b0), .irq, .fiq, .wake,
    .i_req(a.i_req), .i_addr(a.i_addr), .i_rdata, .i_ok, .d_req(a.d_req), .d_we(a.d_we), .d_be(a.d_be), .d_addr(a.d_addr),
    .d_wdata(a.d_wdata), .d_rdata, .d_ok, .dbg_wen(a.wen), .dbg_wa(a.wa), .dbg_wd(a.wd), .dbg_retire(a.ret),
    .dbg_pc(a.pc), .dbg_cpsr(a.cpsr), .dbg_halted(a.halted));
  arm7_ds u_new (.clk, .rst, .run, .reset_pc, .hivecs(1'b0), .irq, .fiq, .wake,
    .i_req(b.i_req), .i_addr(b.i_addr), .i_rdata, .i_ok, .d_req(b.d_req), .d_we(b.d_we), .d_be(b.d_be), .d_addr(b.d_addr),
    .d_wdata(b.d_wdata), .d_rdata, .d_ok, .dbg_wen(b.wen), .dbg_wa(b.wa), .dbg_wd(b.wd), .dbg_retire(b.ret),
    .dbg_pc(b.pc), .dbg_cpsr(b.cpsr), .dbg_halted(b.halted));

  function automatic logic [31:0] mix(input logic [31:0] x);
    logic [31:0] h;
    h = (x ^ seed) * 32'h9E3779B1; h ^= h >> 15; h *= 32'h85EBCA77; h ^= h >> 13; h *= 32'hC2B2AE3D; h ^= h >> 16;
    return h;
  endfunction
  // one instruction per word address; r15 comes up as any 4-bit register field does, more often for Rd/Rn
  function automatic logic [31:0] code(input logic [31:0] addr);
    logic [31:0] h, r, w;
    logic [3:0] c;
    h = mix({addr[31:2], 2'b00} ^ (32'(n >> 10) * 32'h01000193)); r = mix(h);   // the code changes every 1,024 clocks: no trap in a loop
    c = (h[31:29] == 3'd0) ? h[28:25] : 4'hE;         // mostly unconditional
    if (h[24:22] == 3'd0) begin r[15:12] = 4'hF; end  // Rd = r15
    if (h[21:19] == 3'd0) begin r[19:16] = 4'hF; end  // Rn = r15
    if (h[18:16] == 3'd0) begin r[3:0]   = 4'hF; end  // Rm = r15
    case (h[7:0]) inside
      [8'd0:8'd59]:    w = {c, 3'b001, r[24:0]};                                  // DP immediate
      [8'd60:8'd99]:   w = {c, 3'b000, r[24:5], r[4] & 1'b0, r[3:0]};             // DP immediate shift
      [8'd100:8'd119]: w = {c, 3'b000, r[24:8], 1'b0, r[6:5], 1'b1, r[3:0]};      // DP register shift
      [8'd120:8'd149]: w = {c, 2'b01, r[25:0]} & 32'hFFFF_FFEF;                   // LDR/STR
      [8'd150:8'd164]: w = {c, 3'b000, r[24:20], r[19:12], r[11:8], 1'b1, r[6:5] | 2'b01, 1'b1, r[3:0]};   // LDRH etc.
      [8'd165:8'd194]: w = {c, 3'b100, r[24:0]};                                  // LDM/STM
      [8'd195:8'd204]: w = {c, 6'b000000, r[21:20], r[19:8], 4'b1001, r[3:0]};    // MUL/MLA
      [8'd205:8'd214]: w = {c, 5'b00001, r[22:20], r[19:8], 4'b1001, r[3:0]};     // long multiply
      [8'd215:8'd219]: w = {c, 5'b00010, r[22], 2'b00, r[19:12], 8'h09, r[3:0]};  // SWP
      [8'd220:8'd224]: w = {c, 5'b00010, r[22], 2'b00, 4'hF, r[15:12], 12'h000};  // MRS
      [8'd225:8'd232]: w = {c, 5'b00010, r[22], 2'b10, r[19:16], 4'hF, 8'h00, r[3:0]};  // MSR register
      [8'd233:8'd237]: w = {c, 5'b00110, r[22], 2'b10, r[19:16], 4'hF, r[11:0]};  // MSR immediate
      [8'd238:8'd243]: w = {c, 20'h12FFF, 4'h1, r[3:0]};       // BX
      [8'd244:8'd249]: w = {c, 3'b101, r[24], 16'd0, r[7:0]};                     // B, BL: near
      [8'd250:8'd251]: w = {c, 4'hF, r[23:0]};                                    // SWI
      default:         w = r;                                                     // anything
    endcase
    return w;
  endfunction

  // data memory: 4,096 words written over the hash
  logic [31:0] dm [0:4095]; logic dv [0:4095];
  logic [31:0] ad;
  int unsigned st_cnt [0:31];
  longint errs = 0, rets = 0, reqs = 0, wrs = 0;
  initial begin
    void'($value$plusargs("seed=%d", seed)); void'($value$plusargs("cycles=%d", cycles));
    for (int i = 0; i < 4096; i++) dv[i] = 1'b0;
    for (int i = 0; i < 32; i++) st_cnt[i] = 0;
  end
  always @(posedge clk) begin
    int unsigned rw;
    n <= n + 1;
    rw = $urandom(seed + 32'(n));
    if (n % 300000 < 8) begin rst <= 1; reset_pc <= (rw[0] ? 32'h0 : {8'h02, 22'(mix(32'(n)) >> 2), 2'b00}); end else rst <= 0;
    irq <= rw[9:0] == 10'd1 || (irq && rw[12:10] != 3'd0);
    fiq <= rw[12:0] == 13'd3 || (fiq && rw[15:13] != 3'd0);
    wake <= rw[9:0] == 10'd7;
    run <= run ? rw[13:0] != 14'd9 : rw[3:0] != 4'd2;
    i_ok <= a.i_req && rw[17:16] != 2'd0;
    i_rdata <= code(a.i_addr);
    d_ok <= a.d_req && rw[19:18] != 2'd0;
    ad = a.d_addr;
    d_rdata <= dv[ad[13:2]] ? dm[ad[13:2]] : mix(ad ^ 32'h5A5A5A5A);
    if (a.d_req && a.d_we && rw[19:18] != 2'd0) begin
      logic [31:0] w;
      w = dv[ad[13:2]] ? dm[ad[13:2]] : mix(ad ^ 32'h5A5A5A5A);
      for (int i = 0; i < 4; i++) if (a.d_be[i]) w[i*8 +: 8] = a.d_wdata[i*8 +: 8];
      dm[ad[13:2]] <= w; dv[ad[13:2]] <= 1'b1; wrs <= wrs + 1;
    end
    if (a.ret) rets <= rets + 1;
    if (a.d_req) reqs <= reqs + 1;
    st_cnt[int'(u_ref.st)] <= st_cnt[int'(u_ref.st)] + 1;
    if (n >= cycles) begin
      $write("states:"); for (int i = 0; i < 19; i++) $write(" %0d", st_cnt[i]); $write("\n");
      $display("cycles %0d, %0d retired, %0d data requests, %0d writes, %0d differences", n, rets, reqs, wrs, errs);
      if (errs != 0) $display("TEST FAILED"); else $display("TEST PASSED");
      $finish;
    end
  end
  always @(negedge clk) if (!rst && n > 16) begin
    logic d;
    d = a.i_req !== b.i_req || a.d_req !== b.d_req || a.wen !== b.wen || a.ret !== b.ret || a.halted !== b.halted ||
        (a.i_req && a.i_addr !== b.i_addr) ||
        (a.d_req && (a.d_we !== b.d_we || a.d_addr !== b.d_addr || (a.d_we && (a.d_be !== b.d_be || a.d_wdata !== b.d_wdata)))) ||
        (a.wen && (a.wa !== b.wa || a.wd !== b.wd)) || (a.ret && (a.pc !== b.pc || a.cpsr !== b.cpsr));
    if (d) begin
      errs <= errs + 1;
      if (errs < 3) begin
        $display("DIFF clk %0d: st %0d/%0d ins %h k %0d", n, u_ref.st, u_new.st, u_ref.ins, u_ref.k);
        $display("  ref %h\n  new %h", a, b);
      end
      if (errs > 20) begin $display("TEST FAILED (stopped)"); $finish; end
    end
  end
endmodule
