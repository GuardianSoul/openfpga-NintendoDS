// The ARM7 against an earlier revision (arm7_ref, sim/arm/tools/a7arch_test.sh) instruction by instruction, not clock by
// clock: each core has its own memory on the same hashed code and data (biased to the rare instruction groups, as
// tb_a7lock), its own random waits, and the three streams must match: retired PC and CPSR, register writes in order,
// memory accesses in order. Episodes: reset, same register file, hold IRQ or FIQ up in some (so an interrupt is taken where
// the program unmasks it, which both see at the same instruction).
`timescale 1ns/1ps
module tb_a7arch;
  logic clk = 0; always #1 clk = !clk;
  logic rst = 1, irq = 0, fiq = 0;
  int unsigned seed = 1, epi = 0, ep_len = 6000;
  longint episodes = 200, n = 0, ep_n = 0;
  logic [31:0] reset_pc = 0;

  typedef struct packed {
    logic i_req; logic [31:0] i_addr; logic d_req; logic d_we; logic [3:0] d_be; logic [31:0] d_addr, d_wdata;
    logic wen; logic [4:0] wa; logic [31:0] wd; logic ret; logic [31:0] pc, cpsr; logic halted;
  } out_t;
  out_t o [2];
  logic [1:0] i_ok = 0, d_ok = 0;
  logic [31:0] i_rd [2], d_rd [2];
  arm7_ref u_ref (.clk, .rst, .run(1'b1), .reset_pc, .hivecs(1'b0), .irq, .fiq, .wake(1'b0),
    .i_req(o[0].i_req), .i_addr(o[0].i_addr), .i_rdata(i_rd[0]), .i_ok(i_ok[0]), .d_req(o[0].d_req), .d_we(o[0].d_we), .d_be(o[0].d_be), .d_addr(o[0].d_addr),
    .d_wdata(o[0].d_wdata), .d_rdata(d_rd[0]), .d_ok(d_ok[0]), .dbg_wen(o[0].wen), .dbg_wa(o[0].wa), .dbg_wd(o[0].wd), .dbg_retire(o[0].ret),
    .dbg_pc(o[0].pc), .dbg_cpsr(o[0].cpsr), .dbg_halted(o[0].halted));
  arm7_ds u_new (.clk, .rst, .run(1'b1), .reset_pc, .hivecs(1'b0), .irq, .fiq, .wake(1'b0),
    .i_req(o[1].i_req), .i_addr(o[1].i_addr), .i_rdata(i_rd[1]), .i_ok(i_ok[1]), .d_req(o[1].d_req), .d_we(o[1].d_we), .d_be(o[1].d_be), .d_addr(o[1].d_addr),
    .d_wdata(o[1].d_wdata), .d_rdata(d_rd[1]), .d_ok(d_ok[1]), .dbg_wen(o[1].wen), .dbg_wa(o[1].wa), .dbg_wd(o[1].wd), .dbg_retire(o[1].ret),
    .dbg_pc(o[1].pc), .dbg_cpsr(o[1].cpsr), .dbg_halted(o[1].halted));

  function automatic logic [31:0] mix(input logic [31:0] x);
    logic [31:0] h;
    h = (x ^ (seed * 32'd2654435761) ^ (epi * 32'd40503)) * 32'h9E3779B1; h ^= h >> 15; h *= 32'h85EBCA77; h ^= h >> 13; h *= 32'hC2B2AE3D; h ^= h >> 16;
    return h;
  endfunction
  // one instruction per word address; r15 comes up as any 4-bit register field does, more often for Rd/Rn
  function automatic logic [31:0] code(input logic [31:0] addr);
    logic [31:0] h, r, w;
    logic [3:0] c;
    h = mix({addr[31:2], 2'b00}); r = mix(h);
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
    return defined(w);
  endfunction
  // no encodings the architecture leaves UNPREDICTABLE: r15 where it may not be, a long multiply's RdHi = RdLo
  function automatic logic [31:0] defined(input logic [31:0] i);
    logic [31:0] w;
    w = i;
    if (w[27:26] == 2'b01) begin                                 // LDR/STR
      if (w[19:16] == 4'hF) begin w[21] = 1'b0; w[24] = 1'b1; end
      if (w[25] && w[3:0] == 4'hF) w[3:0] = 4'hE;
      if (w[22] && w[15:12] == 4'hF) w[15:12] = 4'hE;
    end else if (w[27:25] == 3'b100) begin                       // LDM/STM
      if (w[19:16] == 4'hF) w[19:16] = 4'hE;
      if (w[22]) w[21] = 1'b0;
    end else if (w[27:25] == 3'b000 && w[7] && w[4]) begin
      if (w[6:5] == 2'b00) begin                                 // multiplies, SWP
        if (w[19:16] == 4'hF) w[19:16] = 4'hE;
        if (w[15:12] == 4'hF) w[15:12] = 4'hD;
        if (w[11:8] == 4'hF) w[11:8] = 4'hC;
        if (w[3:0] == 4'hF) w[3:0] = 4'hB;
        if (w[24:23] == 2'b01 && w[19:16] == w[15:12]) w[15:12] = w[15:12] == 4'hE ? 4'hD : w[15:12] ^ 4'h1;
      end else begin                                             // LDRH etc.
        if (w[19:16] == 4'hF) begin w[21] = 1'b0; w[24] = 1'b1; end
        if (!w[22] && w[3:0] == 4'hF) w[3:0] = 4'hE;
        if (w[15:12] == 4'hF) w[15:12] = 4'hE;
      end
    end else if (w[27:25] == 3'b000 && w[24:23] == 2'b10 && !w[20]) begin   // MRS, MSR
      if (w[3:0] == 4'hF) w[3:0] = 4'hE;
      if (!w[21] && w[15:12] == 4'hF) w[15:12] = 4'hE;
    end else if (w[27:25] == 3'b000 && w[4] && !w[7]) begin      // register shift
      if (w[11:8] == 4'hF) w[11:8] = 4'hE;
    end
    return w;
  endfunction

  // data memory per core: 4,096 words written over the hash
  logic [31:0] dm [2][0:4095]; logic dv [2][0:4095];
  // the streams
  typedef struct packed { logic [1:0] kind; logic [31:0] a, b, c; logic [3:0] be; logic w; } ev_t;   // 0 retire, 1 register, 2 memory
  ev_t q [2][3][$];
  logic [31:0] pq_a [2]; logic [3:0] pq_be [2]; logic [31:0] pq_d [2]; logic pq_v [2], pq_w [2];
  longint errs = 0, rets [2], cyc_ep = 0, cmp = 0, wrs = 0, dreq = 0;
  int unsigned sc = 0; bit trace = 0; int only = -1;
  initial begin
    trace = $test$plusargs("trace"); void'($value$plusargs("only=%d", only));
    void'($value$plusargs("seed=%d", seed)); void'($value$plusargs("episodes=%d", episodes)); void'($value$plusargs("len=%d", ep_len));
    rets[0] = 0; rets[1] = 0; pq_v[0] = 0; pq_v[1] = 0;
  end

  always @(posedge clk) begin
    int unsigned rw;
    n <= n + 1; ep_n <= ep_n + 1;
    if (ep_n == ep_len) begin
      // a new episode, the same state in both
      for (int s = 0; s < 3; s++) begin q[0][s].delete(); q[1][s].delete(); end
      epi <= epi + 1; ep_n <= 0; rst <= 1;
      for (int c = 0; c < 2; c++) begin pq_v[c] <= 0; for (int i = 0; i < 4096; i++) dv[c][i] <= 1'b0; end
      if (longint'(epi) + 1 >= episodes) begin
        $display("%0d episodes, %0d clocks; retired ref %0d new %0d (%0.3f); %0d compared, %0d data requests, %0d differences", epi + 1, n, rets[0], rets[1], real'(rets[1]) / real'(rets[0]), cmp, dreq, errs);
        if (errs != 0) $display("TEST FAILED"); else $display("TEST PASSED");
        $finish;
      end
    end else if (ep_n == 8) begin
      rst <= 0;
      for (int s = 0; s < 3; s++) begin q[0][s].delete(); q[1][s].delete(); end
      irq <= mix(32'h100)[2:0] == 3'd0; fiq <= mix(32'h100)[5:3] == 3'd0;
    end
    if (ep_n == 2) begin
      reset_pc <= mix(32'h200)[0] ? 32'h0 : {8'h02, 22'(mix(32'h300) >> 2), 2'b00};
      for (int i = 0; i < 32; i++) begin
        automatic logic [31:0] v = mix(32'h1000 + i);
        if (i[1:0] == 2'd1) v = {8'h02, 2'b00, v[21:0]};      // some registers look like addresses
        u_ref.rf[i] = v; u_ref.rfb[i] = v; u_new.rf[i] = v;
      end
      for (int i = 0; i < 5; i++) begin u_ref.spsr[i] = 13'h1D3; u_new.spsr[i] = 13'h1D3; end
    end
    for (int c = 0; c < 2; c++) begin
      automatic logic [31:0] ad = o[c].d_addr;
      rw = $urandom;
      i_ok[c] <= o[c].i_req && rw[1:0] != 2'd0;
      i_rd[c] <= code(o[c].i_addr);
      d_ok[c] <= o[c].d_req && rw[3:2] != 2'd0;
      d_rd[c] <= dv[c][ad[13:2]] ? dm[c][ad[13:2]] : mix(ad[31:2] ^ 32'h5A5A5A5A);
      if (o[c].d_req && !rst && ep_n < ep_len && rw[3:2] != 2'd0) begin
        automatic ev_t e = '0;
        e.kind = 2'd2; e.a = ad; e.w = o[c].d_we; e.be = o[c].d_we ? o[c].d_be : 4'h0; e.b = o[c].d_we ? o[c].d_wdata : 32'h0;
        q[c][2].push_back(e);
        if (c == 1) dreq <= dreq + 1;
        if (o[c].d_we) begin
          automatic logic [31:0] w = dv[c][ad[13:2]] ? dm[c][ad[13:2]] : mix(ad[31:2] ^ 32'h5A5A5A5A);
          for (int i = 0; i < 4; i++) if (o[c].d_be[i]) w[i*8 +: 8] = o[c].d_wdata[i*8 +: 8];
          dm[c][ad[13:2]] <= w; dv[c][ad[13:2]] <= 1'b1;
        end
      end
      if (!rst && ep_n > 9 && ep_n < ep_len) begin
        // (Z lands a clock after the other flags: the conditions and MRS check it)
        if (o[c].ret) begin automatic ev_t e = '0; e.kind = 2'd0; e.a = o[c].pc; e.b = o[c].cpsr & ~32'h4000_0000; q[c][0].push_back(e); rets[c] <= rets[c] + 1; end
        if (o[c].wen && o[c].wa != 5'd15) begin automatic ev_t e = '0; e.kind = 2'd1; e.a = 32'(o[c].wa); e.b = o[c].wd; q[c][1].push_back(e); end
        if (trace && (only < 0 || only == int'(epi))) begin
          if (o[c].ret) $display("%0d %s ret pc %h cpsr %h", ep_n, c ? "new" : "ref", o[c].pc, o[c].cpsr);
          if (o[c].wen) $display("%0d %s wr %0d %h", ep_n, c ? "new" : "ref", o[c].wa, o[c].wd);
          if (o[c].d_req && rw[3:2] != 2'd0) $display("%0d %s mem %h we %b be %h d %h", ep_n, c ? "new" : "ref", o[c].d_addr, o[c].d_we, o[c].d_be, o[c].d_wdata);
          if (c == 1 && u_new.adv && u_new.e_v) $display("%0d new E ins %h k %0d sho %h opc %h shc %b prod %h", ep_n, u_new.ins, u_new.k, u_new.sho, u_new.opc, u_new.shc, u_new.prod_q);
          if (c == 0 && o[0].ret) $display("%0d ref was ins %h k %0d", ep_n, u_ref.ins, u_ref.k);
        end
      end
    end
    // compare what both have produced
    if (ep_n < ep_len) for (int s = 0; s < 3; s++)
      while (q[0][s].size() > 0 && q[1][s].size() > 0) begin
        automatic ev_t x = q[0][s].pop_front(), y = q[1][s].pop_front();
        cmp <= cmp + 1;
        if (x !== y) begin
          errs <= errs + 1;
          if (errs < 6) $display("DIFF stream %0d episode %0d clk %0d: ref a %h b %h w %b be %h | new a %h b %h w %b be %h  (ref ins %h new ins %h pc %h)",
                                  s, epi, ep_n, x.a, x.b, x.w, x.be, y.a, y.b, y.w, y.be, u_ref.ins, u_new.ins, o[0].pc);
          // the two have parted: on to the next episode
          ep_n <= ep_len;
          break;
        end
      end
    if (errs > 40) begin $display("TEST FAILED (stopped)"); $finish; end
  end
endmodule
