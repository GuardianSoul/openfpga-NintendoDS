// The ARM7 port's crossings under CPU_FAST (rtl/arm/cdc_a7.sv) with the
// parts they meet: the port (PORT 0: nds_arm7_port_min, 1: nds_arm7_port) on
// clk_cpu, and on clk_sys the real SRAM arbiter (nds_fr_arb, whose fabric side
// waits while x7_stores is up) and a fabric model that serves one master at a
// time, the ARM7 or another one (ARM9/DMA) that often reads the SRAM.
// Checks:
//   - no deadlock: the port's accesses keep being answered (a watchdog);
//   - order: an ARM7 fabric store reaches the fabric only after every SRAM
//     store the ARM7 made before it has reached the SRAM (an IPC write after
//     shared-WRAM stores).
//   +pc=<ps> +ps=<ps>  clk_cpu / clk_sys periods   +cycles=N  +seed=S
`timescale 1ps/1ps
module tb_a7cross;
  parameter int PORT = 0;
  int pc = 11190, ps = 14920, seed = 1;
  longint cycles = 400000;
  logic cclk = 0, sclk = 0;
  initial begin
    void'($value$plusargs("pc=%d", pc));
    void'($value$plusargs("ps=%d", ps));
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("cycles=%d", cycles));
    void'($urandom(seed));
  end
  always #(pc / 2) cclk = !cclk;
  always #(ps / 2) sclk = !sclk;
  logic c_rst = 1, s_rst = 1;

  // ---- the port (clk_cpu)
  logic        i_req = 0, d_req = 0, d_we = 0;
  logic [31:0] i_addr = 32'h0380_0000, d_addr = 0, d_wdata = 0;
  logic [3:0]  d_be = 4'hF;
  logic [31:0] i_rdata, d_rdata;
  logic        i_ok, d_ok;
  logic        cx_req, cx_we, cx_stores, cx_done, cf_req, cf_we, cf_ack;
  logic [17:2] cx_addr;
  logic [3:0]  cx_be, cf_be;
  logic [31:0] cx_wdata, cx_rdata, cf_addr, cf_wdata, cf_rdata;
  generate if (PORT == 0) begin : g_min
    nds_arm7_port_min #(.BOOT_FAB(1)) u_p (.clk(cclk), .rst(c_rst), .wramcnt(2'd3),
      .i_req, .i_addr, .i_rdata, .i_ok, .d_req, .d_we, .d_be, .d_addr, .d_wdata, .d_rdata, .d_ok,
      .ib_addr(), .i_boot_q(32'd0), .db_addr(), .d_boot(), .d_boot_q(32'd0),
      .x_req(cx_req), .x_we(cx_we), .x_addr(cx_addr), .x_be(cx_be), .x_wdata(cx_wdata),
      .x_stores(cx_stores), .x_done(cx_done), .x_rdata(cx_rdata), .inv(1'b0), .inv_addr(16'd0),
      .f_req(cf_req), .f_we(cf_we), .f_addr(cf_addr), .f_be(cf_be), .f_wdata(cf_wdata),
      .f_ack(cf_ack), .f_rdata(cf_rdata), .wr_mon(1'b0), .wr_addr(32'd0));
  end else begin : g_c
    nds_arm7_port #(.BOOT_FAB(1)) u_p (.clk(cclk), .rst(c_rst), .wramcnt(2'd3),
      .i_req, .i_addr, .i_rdata, .i_ok, .d_req, .d_we, .d_be, .d_addr, .d_wdata, .d_rdata, .d_ok,
      .ib_addr(), .i_boot_q(32'd0), .db_addr(), .d_boot(), .d_boot_q(32'd0),
      .x_req(cx_req), .x_we(cx_we), .x_addr(cx_addr), .x_be(cx_be), .x_wdata(cx_wdata),
      .x_stores(cx_stores), .x_done(cx_done), .x_rdata(cx_rdata), .inv(1'b0), .inv_addr(16'd0),
      .f_req(cf_req), .f_we(cf_we), .f_addr(cf_addr), .f_be(cf_be), .f_wdata(cf_wdata),
      .f_ack(cf_ack), .f_rdata(cf_rdata), .wr_mon(1'b0), .wr_addr(32'd0));
  end endgenerate

  // ---- the crossings
  logic        x7_req, x7_we, x7_stores, x7_done, f7_req, f7_we, f7_ack;
  logic [17:2] x7_addr;
  logic [3:0]  x7_be, f7_be;
  logic [31:0] x7_wdata, x7_rdata, f7_addr, f7_wdata, f7_rdata;
  cdc_a7 #(.STORE_GATE(PORT)) dut (.clk_cpu(cclk), .c_rst, .clk(sclk), .rst(s_rst),
    .c_x7_req(cx_req), .c_x7_we(cx_we), .c_x7_addr(cx_addr), .c_x7_be(cx_be), .c_x7_wdata(cx_wdata),
    .c_x7_stores(cx_stores), .c_x7_done(cx_done), .c_x7_rdata(cx_rdata),
    .c_f7_req(cf_req), .c_f7_we(cf_we), .c_f7_addr(cf_addr), .c_f7_be(cf_be), .c_f7_wdata(cf_wdata),
    .c_f7_ack(cf_ack), .c_f7_rdata(cf_rdata),
    .x7_req, .x7_we, .x7_addr, .x7_be, .x7_wdata, .x7_stores, .x7_done, .x7_rdata,
    .f7_req, .f7_we, .f7_addr, .f7_be, .f7_wdata, .f7_ack, .f7_rdata);

  // ---- clk_sys: the SRAM arbiter, the SRAM, the fabric
  logic        fs_req, fs_we, fs_done;              // the fabric's SRAM side
  logic [17:2] fs_addr;
  logic        fr_req, fr_we, fr_done = 0;
  logic [17:2] fr_addr;
  logic [3:0]  fr_be;
  logic [31:0] fr_wdata;
  nds_fr_arb u_arb (.clk(sclk), .rst(s_rst), .l_req(1'b0), .l_addr(16'd0), .l_wdata(32'd0), .l_done(),
    .a_req(x7_req), .a_we(x7_we), .a_addr(x7_addr), .a_be(x7_be), .a_wdata(x7_wdata), .a_stores(x7_stores),
    .a_done(x7_done), .f_req(fs_req), .f_we(fs_we), .f_addr(fs_addr), .f_be(4'hF), .f_wdata(32'd0),
    .f_done(fs_done), .inv(), .inv_addr(), .fr_req, .fr_we, .fr_addr, .fr_be, .fr_wdata, .fr_done);
  assign x7_rdata = 32'h5A5A_0000 | 32'(x7_addr);
  // random draws, one register per cycle (Verilator splits always blocks by
  // variable: a $urandom in a shared condition would be drawn per variable)
  logic [31:0] rnd, rnd2;
  always_ff @(posedge sclk) begin rnd <= $urandom; rnd2 <= $urandom; end
  int sr_wait = 0;
  always_ff @(posedge sclk) begin
    fr_done <= 1'b0;
    if (fr_req && !fr_done) begin
      if (sr_wait == 0) begin fr_done <= 1'b1; sr_wait <= int'(rnd2[0]); end
      else sr_wait <= sr_wait - 1;
    end
  end
  // the fabric: one master at a time; the other master's access is an SRAM
  // read (through nds_fr_arb) or something else that takes a few cycles
  typedef enum logic [1:0] { F_IDLE, F_A7, F_OTH_SR, F_OTH } fst_t;
  fst_t fst;
  int   f_cnt;
  logic oth_req;
  assign f7_rdata = 32'hA7A7_0000 | f7_addr[15:0];
  always_ff @(posedge sclk) begin
    f7_ack <= 1'b0;
    if (!oth_req && rnd[1:0] == 2'd0) oth_req <= 1'b1;
    case (fst)
      F_IDLE: if (f7_req && !f7_ack && (!oth_req || rnd[2])) begin fst <= F_A7; f_cnt <= 1 + int'(rnd[6:4]) % 6; end
              else if (oth_req) begin
                oth_req <= 1'b0;
                if (rnd[3]) begin fst <= F_OTH_SR; fs_req <= 1'b1; fs_we <= rnd[9:8] == 2'd0; fs_addr <= rnd[31:16]; end
                else begin fst <= F_OTH; f_cnt <= 1 + int'(rnd[11:10]); end
              end
      F_A7:   if (f_cnt == 1) begin f7_ack <= 1'b1; fst <= F_IDLE; end else f_cnt <= f_cnt - 1;
      F_OTH_SR: if (fs_done) begin fs_req <= 1'b0; fst <= F_IDLE; end
      default: if (f_cnt == 1) fst <= F_IDLE; else f_cnt <= f_cnt - 1;
    endcase
    if (s_rst) begin fst <= F_IDLE; fs_req <= 1'b0; fs_we <= 1'b0; fs_addr <= '0; oth_req <= 1'b0; f_cnt <= 0; end
  end

  // ---- order: SRAM stores accepted / landed; fabric stores and how many
  // SRAM stores came before each
  longint st_acc = 0, f_acc = 0, errs = 0, maxstall = 0;   // (the pipeline's process)
  longint st_land = 0, f_land = 0, oerrs = 0;              // (clk_sys)
  longint st_prior [longint];        // fabric store n: SRAM stores accepted before it
  always_ff @(posedge sclk) if (!s_rst) begin
    if (x7_done && x7_we) st_land <= st_land + 1;
    if (f7_ack && f7_we) begin
      f_land <= f_land + 1;
      if (!st_prior.exists(f_land)) begin oerrs <= oerrs + 1; $display("a fabric store the pipeline did not make"); end
      else if (st_land + (x7_done && x7_we ? 1 : 0) < st_prior[f_land]) begin
        oerrs <= oerrs + 1;
        if (oerrs < 5) $display("order: a fabric store landed with %0d of the %0d SRAM stores before it", st_land, st_prior[f_land]);
      end
    end
  end

  // ---- the pipeline (clk_cpu): fetches from ARM7 WRAM; loads and stores
  // to ARM7/shared WRAM (SRAM) and main RAM/I/O (fabric); replays until
  // answered. Code in ARM7 WRAM or main RAM. A store to the SRAM followed soon by a fabric store is common
  // (the IPC pattern).
  function automatic logic [31:0] daddr();
    int r = $urandom % 8;
    if (r < 3) return 32'h0380_0000 | (32'($urandom % 4096) << 2);
    if (r < 4) return 32'h0300_0000 | (32'($urandom % 2048) << 2);
    if (r < 6) return 32'h0200_0000 | (32'($urandom % 4096) << 2);
    return 32'h0400_0180;
  endfunction
  longint cyc = 0, n_i = 0, n_d = 0, quiet = 0;
  initial begin
    repeat (4) @(posedge sclk);
    s_rst <= 0;
    @(posedge cclk); c_rst <= 0;
    repeat (300) @(posedge cclk);
    while (cyc < cycles) begin
      @(negedge cclk);
      if (i_ok) n_i++;
      if (d_ok) begin
        n_d++;
        if (d_we) begin
          if (d_addr[31:24] == 8'h03) st_acc++;
          else begin st_prior[f_acc] = st_acc; f_acc++; end
        end
      end
      quiet = (i_ok || d_ok) ? 0 : quiet + 1;
      if (quiet > maxstall) maxstall = quiet;
      if (quiet == 20000) begin
        errs++;
        $display("deadlock: nothing answered for 20000 clk_cpu cycles (cycle %0d: x7_req %b stores %b f7_req %b fabric %0d fs_req %b)",
                 cyc, x7_req, x7_stores, f7_req, fst, fs_req);
        break;
      end
      if (!i_req || i_ok || $urandom % 64 == 0) begin
        i_req = $urandom % 4 != 0;
        // code in ARM7 WRAM (SRAM) or main RAM (fabric: a store can then be
        // posted while a fetch is on its way)
        i_addr = i_ok ? i_addr + 4 : ($urandom % 2 ? 32'h0380_0000 : 32'h0238_0000) | (32'($urandom % 16384) << 2);
      end
      if (!d_req || d_ok) begin
        d_req = $urandom % 2 == 0;
        d_we = $urandom % 2 == 0;
        d_addr = daddr();
        d_wdata = $urandom;
      end
      @(posedge cclk);
      cyc++;
    end
    $display("a7cross PORT %0d (clk_cpu %0d ps, clk_sys %0d ps): %0d cycles, %0d fetches and %0d data accesses answered, %0d SRAM / %0d fabric stores, longest wait %0d: %0d errors",
             PORT, pc, ps, cyc, n_i, n_d, st_acc, f_acc, maxstall, errs);
    errs += oerrs;
    if (errs || n_d == 0 || f_acc == 0) begin $display("FAIL"); $fatal(1); end
    $display("PASS");
    $finish;
  end
endmodule
