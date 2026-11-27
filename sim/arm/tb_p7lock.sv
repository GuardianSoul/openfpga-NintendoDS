// nds_arm7_port in lockstep with an earlier revision (nds_arm7_port_ref, sim/arm/tools/p7lock_test.sh), and a data
// scoreboard. One CPU-like request stream (fetch and data requests replayed until answered, sometimes dropped, random
// idle clocks; addresses with locality over ARM7 WRAM, shared WRAM, BIOS7, the boot ROM and the fabric), an SRAM with
// random latency, a fabric with random latency, and writes by others into SRAM words the port caches (inv).
//   LOCK = 1: both ports get the same inputs (answered to the reference's requests); every output must be the same
//             every clock (the default IW = DW = 1 against the revision before).
//   always:   every answered fetch and load of the new port must return the word the CPU should see (its own stores
//             at their acceptance, others' writes; a word others wrote in the last 16 clocks may still show its old
//             value). Others write only a band the CPU does not store to, so no ordering between the two is needed.
`timescale 1ns/1ps
module tb_p7lock;
  parameter int IL = 5, DL = 4, TPUMP = 0, LOCK = 1;
  logic clk = 0; always #1 clk = !clk;
  // clk2: 2 x clk, rising with every clk edge (nds_lcache PUMP's phase 0)
  logic clk2 = 1; always #0.5 clk2 = !clk2;
  logic rst = 1;
  int unsigned seed = 1;
  longint cycles = 2000000, n = 0, errors = 0, fetch_chk = 0, load_chk = 0, diffs = 0;
  logic [1:0] wramcnt = 2'd3;

  function automatic logic [31:0] mix(input logic [31:0] x);
    logic [31:0] h;
    h = (x ^ seed) * 32'h9E3779B1; h ^= h >> 15; h *= 32'h85EBCA77; h ^= h >> 13; h *= 32'hC2B2AE3D; h ^= h >> 16;
    return h;
  endfunction
  logic [31:0] rnd;
  always_ff @(posedge clk) rnd <= mix(32'(n) ^ 32'h5bd1e995);
  function automatic logic [31:0] r(input int k); return mix(rnd ^ (32'(k) * 32'h27d4eb2f)); endfunction

  // ---- the SRAM (18-bit byte addresses as the port's x side) and the CPU's view of it
  logic [31:0] sram [0:65535];      // what the SRAM chip holds
  logic [31:0] view [0:65535];      // what the CPU must read: its stores at acceptance, others' writes
  logic [31:0] prev [0:65535];      // the word before others' last write
  longint      wat  [0:65535];      // the clock of others' last write
  initial for (int i = 0; i < 65536; i++) begin sram[i] = mix(32'(i) * 32'h01000193); view[i] = sram[i]; prev[i] = sram[i]; wat[i] = -100; end
  function automatic logic [17:0] xa_of(input logic [31:0] a, input logic [1:0] wc);   // as the port's
    if (a[31:24] != 8'h03) return {4'b0110, a[13:0]};
    if (a[23] || wc == 2'd0) return {2'b00, a[15:0]};
    case (wc)
      2'd1: return {3'b010, 1'b0, a[13:0]};
      2'd2: return {3'b010, 1'b1, a[13:0]};
      default: return {3'b010, a[14:0]};
    endcase
  endfunction
  function automatic logic [31:0] fab(input logic [31:0] a); return mix({a[31:2], 2'b00} ^ 32'hA5A5_0000); endfunction
  function automatic logic [31:0] rom(input logic [10:0] a); return mix({21'h1F00, a} ); endfunction

  // ---- port outputs
  typedef struct packed {
    logic [31:0] i_rdata; logic i_ok; logic [31:0] d_rdata; logic d_ok;
    logic [10:0] ib_addr, db_addr; logic d_boot;
    logic x_req, x_we; logic [17:2] x_addr; logic [3:0] x_be; logic [31:0] x_wdata; logic x_stores;
    logic f_req, f_we; logic [31:0] f_addr; logic [3:0] f_be; logic [31:0] f_wdata;
  } out_t;
  out_t a, b;
  // ---- inputs (one set for both)
  logic        i_req = 0, d_req = 0, d_we = 0;
  logic [31:0] i_addr = 0, d_addr = 0, d_wdata = 0;
  logic [3:0]  d_be = 0;
  logic [31:0] i_boot_q = 0, d_boot_q = 0, x_rdata = 0, f_rdata = 0;
  logic        x_done = 0, f_ack = 0, inv = 0;
  logic [17:2] inv_addr = 0;
  out_t m;                           // the outputs the environment answers (the reference's in LOCK, else the new port's)
  assign m = LOCK ? a : b;

  generate if (LOCK) begin : g_ref
    nds_arm7_port_ref #(.IL(IL), .DL(DL)) u_ref (.clk, .rst, .wramcnt,
      .i_req, .i_addr, .i_rdata(a.i_rdata), .i_ok(a.i_ok), .d_req, .d_we, .d_be, .d_addr, .d_wdata, .d_rdata(a.d_rdata), .d_ok(a.d_ok),
      .ib_addr(a.ib_addr), .i_boot_q, .db_addr(a.db_addr), .d_boot(a.d_boot), .d_boot_q,
      .x_req(a.x_req), .x_we(a.x_we), .x_addr(a.x_addr), .x_be(a.x_be), .x_wdata(a.x_wdata), .x_stores(a.x_stores), .x_done, .x_rdata,
      .inv, .inv_addr, .f_req(a.f_req), .f_we(a.f_we), .f_addr(a.f_addr), .f_be(a.f_be), .f_wdata(a.f_wdata), .f_ack, .f_rdata,
      .wr_mon(1'b0), .wr_addr(32'd0));
  end else begin : g_noref
    assign a = '0;
  end endgenerate
  nds_arm7_port #(.IL(IL), .DL(DL), .TPUMP(TPUMP)) u_new (.clk, .clk2, .rst, .wramcnt,
    .i_req, .i_addr, .i_rdata(b.i_rdata), .i_ok(b.i_ok), .d_req, .d_we, .d_be, .d_addr, .d_wdata, .d_rdata(b.d_rdata), .d_ok(b.d_ok),
    .ib_addr(b.ib_addr), .i_boot_q, .db_addr(b.db_addr), .d_boot(b.d_boot), .d_boot_q,
    .x_req(b.x_req), .x_we(b.x_we), .x_addr(b.x_addr), .x_be(b.x_be), .x_wdata(b.x_wdata), .x_stores(b.x_stores), .x_done, .x_rdata,
    .inv, .inv_addr, .f_req(b.f_req), .f_we(b.f_we), .f_addr(b.f_addr), .f_be(b.f_be), .f_wdata(b.f_wdata), .f_ack, .f_rdata,
    .wr_mon(1'b0), .wr_addr(32'd0));

  // ---- address streams: a hot set of lines that drifts, plus far jumps
  // regions: 0 ARM7 WRAM 0x0380xxxx, 1 the shared window 0x0300xxxx (mirrors per WRAMCNT), 2 BIOS7 (fetch only),
  // 3 boot ROM 0x8000-0x9FFF, 4 main RAM (fabric), 5 I/O (fabric)
  function automatic logic [31:0] place(input logic [31:0] h, input bit fetch);
    logic [2:0] k;
    logic [15:0] off;
    k = h[31:29];
    off = {h[15:6], 6'd0} & 16'hFFFC;
    if (k <= 3'd3) return {16'h0380, 1'b0, h[14:13] == 2'd0 ? {2'b00, off[12:2]} : {h[14:13], h[12:2]}, 2'b00} & 32'hFFFF_FFFC;   // WRAM, mostly the low 8 KiB
    if (k == 3'd4) return {16'h0300, 1'b0, h[14:2], 2'b00};
    if (k == 3'd5) return fetch ? {18'd0, h[13:2], 2'b00} : {16'h0380, 1'b0, h[14:2], 2'b00};
    if (k == 3'd6) return fetch ? {19'h4, h[12:2], 2'b00} : {16'h0200, h[15:2], 2'b00};
    return fetch ? {16'h0200, h[15:2], 2'b00} : {24'h040001, h[7:2], 2'b00};
  endfunction
  logic [31:0] ipc = 32'h0380_0000;
  logic        i_out = 0, d_out = 0;             // a request went out in the last ph 0 clock
  logic        ph = 0;
  logic [31:0] d_hot = 32'h0380_1000;
  // others write only WRAM 0x0380_C000-0x0380_FFFF (the CPU never stores there)
  function automatic bit others_band(input logic [17:2] w); return w[17:16] == 2'b00 && w[15:14] == 2'b11; endfunction

  // the environment's state
  int          xl = 0, fl = 0;                    // clocks left for the SRAM / fabric answer
  logic        xbusy = 0, fbusy = 0;
  always_ff @(posedge clk) begin
    n <= n + 1;
    if (n == 8) rst <= 1'b0;
    // boot ROM: answered the next clock
    i_boot_q <= rom(m.ib_addr); d_boot_q <= rom(m.db_addr);
    // SRAM: x_req held until x_done (a pulse), random latency
    x_done <= 1'b0;
    if (m.x_req && !xbusy && !x_done) begin xbusy <= 1'b1; xl <= 1 + int'(r(1) % 7); end
    else if (xbusy) begin
      if (xl > 1) xl <= xl - 1;
      else begin
        xbusy <= 1'b0; x_done <= 1'b1;
        if (m.x_we) begin
          for (int k = 0; k < 4; k++) if (m.x_be[k]) sram[m.x_addr][k*8 +: 8] = m.x_wdata[k*8 +: 8];
        end else x_rdata <= sram[m.x_addr];
      end
    end
    // others' writes: only while the port is off the SRAM (the arbiter's single port)
    inv <= 1'b0;
    if (!rst && !m.x_req && !xbusy && r(2)[7:0] < 8'd6) begin
      logic [17:2] w; logic [31:0] v;
      w = {2'b00, 2'b11, r(3)[11:0]};
      if (r(4)[0]) w[11:4] = d_hot[11:4];         // often a line the CPU uses
      v = r(5);
      prev[w] = view[w]; wat[w] = n; sram[w] = v; view[w] = v;
      inv <= 1'b1; inv_addr <= w;
    end
    // fabric: f_req held until f_ack (a pulse), random latency
    f_ack <= 1'b0;
    if (m.f_req && !fbusy && !f_ack) begin fbusy <= 1'b1; fl <= 1 + int'(r(6) % 11); end
    else if (fbusy) begin
      if (fl > 1) fl <= fl - 1;
      else begin fbusy <= 1'b0; f_ack <= 1'b1; f_rdata <= fab(m.f_addr); end
    end
    // ---- the CPU (arm7_ds): requests only in an ARM7 cycle's first clock (ph 0), answered in its second
    ph <= !ph;
    if (rst) begin i_req <= 1'b0; d_req <= 1'b0; i_out <= 1'b0; d_out <= 1'b0; ph <= 1'b0; end
    else if (!ph) begin
      i_out <= i_req; d_out <= d_req; i_req <= 1'b0; d_req <= 1'b0;
    end else begin
      // fetch: m.i_ok answers the request of the ph 0 clock that just passed
      if (i_out && !m.i_ok && r(7)[9:0] != 0) i_req <= 1'b1;                 // replayed
      else if (r(8)[3:0] == 0) i_req <= 1'b0;                               // an idle cycle
      else begin
        logic [31:0] h; h = r(9);
        if (i_out && m.i_ok) ipc = (h[4:0] == 0) ? place(r(10), 1'b1) : (h[4:0] < 3 ? {ipc[31:6] ^ {16'd0, h[15:6]}, 6'd0} : ipc + 4);
        i_req <= 1'b1; i_addr <= ipc;
      end
      // data
      if (d_out && !m.d_ok && r(11)[9:0] != 0) d_req <= 1'b1;               // replayed
      else if (r(12)[2:0] != 0) d_req <= 1'b0;
      else begin
        logic [31:0] h, ad; h = r(13);
        if (h[3:0] == 0) d_hot = place(r(14), 1'b0);
        ad = h[4] ? d_hot + {h[9:5], 2'b00} : place(r(15), 1'b0);
        if (ad[31:24] == 8'h03 && others_band(xa_of(ad, wramcnt)[17:2]) && h[20]) ad[15:14] = 2'b00;
        d_req <= 1'b1; d_addr <= ad;
        // stores only to SRAM words others never write (the fabric's words stay the hash the checks expect)
        d_we <= h[21:20] == 2'b11 && ad[31:24] == 8'h03 && !others_band(xa_of(ad, wramcnt)[17:2]);
        d_be <= h[23:22] == 0 ? 4'hF : h[23:22] == 1 ? (4'b0011 << {h[24], 1'b0}) : (4'b0001 << h[25:24]);
        d_wdata <= r(16);
      end
      // WRAMCNT changes now and then (no request in flight to the window then: none is checked across it)
      if (r(17)[15:0] == 0 && !i_req && !d_req && !i_out && !d_out) wramcnt <= r(18)[1:0];
    end
  end

  // ---- checks: the answer of last clock's request (registered copies of the request)
  logic        i_q = 0, d_q = 0, dw_q = 0;
  logic [31:0] ia_q, da_q;
  logic [3:0]  db_q;
  logic [1:0]  wc_q;
  always_ff @(posedge clk) begin
    i_q <= i_req && !rst; ia_q <= i_addr; d_q <= d_req && !rst; da_q <= d_addr; dw_q <= d_we; db_q <= d_be; wc_q <= wramcnt;
    if (!rst && LOCK && a != b) begin
      diffs++;
      if (diffs <= 8) $display("DIFF at %0d: ref %h\n                 new %h", n, a, b);
    end
    // the new port's answers against what the CPU must see
    if (!rst && i_q && b.i_ok) begin
      logic [31:0] e; bit sr;
      sr = ia_q[31:14] == 18'd0 || ia_q[31:24] == 8'h03;
      if (ia_q[31:13] == 19'h4) e = rom(ia_q[12:2]);
      else if (sr) e = view[xa_of(ia_q, wc_q)[17:2]];
      else e = fab(ia_q);
      if (b.i_rdata !== e && !(sr && b.i_rdata === prev[xa_of(ia_q, wc_q)[17:2]] && n - wat[xa_of(ia_q, wc_q)[17:2]] < 16)) begin
        errors++; if (errors <= 8) $display("ERROR at %0d: fetch %h gave %h, expected %h", n, ia_q, b.i_rdata, e);
      end
      fetch_chk++;
    end
    if (!rst && d_q && b.d_ok) begin
      if (dw_q) begin
        if (da_q[31:24] == 8'h03) for (int k = 0; k < 4; k++) if (db_q[k]) view[xa_of(da_q, wc_q)[17:2]][k*8 +: 8] = d_wdata_q[k*8 +: 8];
      end else if (da_q[31:24] == 8'h03 || (da_q[31:13] == 19'h4)) begin
        logic [31:0] e;
        e = da_q[31:24] == 8'h03 ? view[xa_of(da_q, wc_q)[17:2]] : rom(da_q[12:2]);
        if (b.d_rdata !== e && !(b.d_rdata === prev[xa_of(da_q, wc_q)[17:2]] && n - wat[xa_of(da_q, wc_q)[17:2]] < 16)) begin
          errors++; if (errors <= 8) $display("ERROR at %0d: load %h gave %h, expected %h", n, da_q, b.d_rdata, e);
        end
        load_chk++;
      end
    end
  end
  logic [31:0] d_wdata_q;
  always_ff @(posedge clk) d_wdata_q <= d_wdata;

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("cycles=%d", cycles));
    wait (n == cycles);
    $display("p7lock seed %0d IL %0d DL %0d TPUMP %0d LOCK %0d: %0d cycles, %0d fetches and %0d loads checked, %0d errors, %0d lockstep differences",
             seed, IL, DL, TPUMP, LOCK, cycles, fetch_chk, load_chk, errors, diffs);
    if (errors == 0 && diffs == 0 && fetch_chk > 1000 && load_chk > 1000) $display("TEST PASSED");
    else $display("TEST FAILED");
    $finish;
  end
endmodule
