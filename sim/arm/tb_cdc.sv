// Two-clock test of the crossings cpu_domain uses (cdc_req, cdc_fifo).
//   +pm=<ps> +ps=<ps>   master / slave (FIFO: reader / writer) clock periods
//   +seed=<n>
// cdc_req: the master issues random requests (held until done, as the CPU
// ports do; like the ARM7 port's SRAM request, the payload is only valid from
// the cycle after the request rises: the first cycle carries garbage); the
// slave answers each after a random delay with a function of the request,
// which the master checks, in order, for every answer.
// cdc_fifo: the writer pushes a counter at random cycles (at most one per
// cycle, as the snoops come); the reader pops every cycle and checks that
// nothing is lost, repeated or reordered. As in cpu_domain the reader's clock
// is the faster one (the FIFO is only checked when pm <= ps).
`timescale 1ps/1ps
module tb_cdc;
  int pm = 11190, ps = 14920, seed = 1;
  logic mclk = 0, sclk = 0, mrst = 1, srst = 1;
  initial begin
    void'($value$plusargs("pm=%d", pm));
    void'($value$plusargs("ps=%d", ps));
    void'($value$plusargs("seed=%d", seed));
    void'($urandom(seed));
  end
  always #(pm / 2) mclk = !mclk;
  always #(ps / 2) sclk = !sclk;

  // ---- cdc_req
  logic        m_req = 0, m_done, s_req, s_done = 0;
  logic [39:0] m_p = 0, s_p;
  logic [31:0] m_q, s_q = 0;
  cdc_req #(.PW(40), .QW(32)) dut (.m_clk(mclk), .m_rst(mrst), .m_req, .m_p, .m_done, .m_q,
                                   .s_clk(sclk), .s_rst(srst), .s_req, .s_p, .s_done, .s_q);
  function automatic logic [31:0] ans(input logic [39:0] p);
    return p[31:0] ^ {p[39:32], 24'h5A5A5A} ^ 32'hC3C3_0F0F;
  endfunction
  int nreq = 0, ndone = 0, errors = 0;
  logic [39:0] cur;
  always @(posedge mclk) if (!mrst) begin
    if (m_done) begin
      if (!m_req) begin $display("ERROR: done without a request"); errors++; end
      else if (m_q !== ans(cur)) begin
        $display("ERROR: answer %h for request %h, expected %h", m_q, cur, ans(cur)); errors++;
      end
      ndone++;
      m_req <= 0;
    end else if (m_req) begin
      m_p <= cur;                          // valid from the second cycle on
    end else if (($urandom % 4) == 0 && nreq < 3000) begin
      cur = {$urandom, $urandom};
      m_p <= ~cur; m_req <= 1; nreq++;     // (first cycle: garbage)
    end
  end
  int wait_n = 0;
  always @(posedge sclk) if (!srst) begin
    s_done <= 0;
    if (s_req && !s_done) begin
      if (wait_n == 0) wait_n = 1 + $urandom % 6;
      else if (--wait_n == 0) begin s_done <= 1; s_q <= ans(s_p); end
    end
  end

  // ---- cdc_fifo (writer: sclk, reader: mclk)
  logic        w_en = 0, r_v;
  logic [15:0] w_d = 0, r_d;
  cdc_fifo #(.W(16), .AB(3)) fifo (.w_clk(sclk), .w_rst(srst), .w_en, .w_d,
                                   .r_clk(mclk), .r_rst(mrst), .r_v, .r_d, .r_take(1'b1));
  int nw = 0, nr = 0;
  always @(posedge sclk) if (!srst) begin
    w_en <= 0;
    if (($urandom % 2) == 0 && nw < 3000 && pm <= ps) begin w_en <= 1; w_d <= 16'(nw); nw++; end
  end
  always @(posedge mclk) if (!mrst && r_v) begin
    if (r_d !== 16'(nr)) begin $display("ERROR: FIFO gave %0d, expected %0d", r_d, nr); errors++; end
    nr++;
  end

  initial begin
    repeat (5) @(posedge sclk); srst = 0;
    repeat (5) @(posedge mclk); mrst = 0;
    wait (ndone == 3000 && (nr == 3000 || pm > ps) || $time > 64'd2000000000);
    repeat (20) @(posedge mclk);
    if (ndone != 3000 || (nr != 3000 && pm <= ps)) begin
      $display("ERROR: %0d of 3000 answers, %0d of 3000 FIFO entries", ndone, nr); errors++;
    end
    if (errors == 0) $display("TEST PASSED (pm %0d ps %0d)", pm, ps);
    else             $display("TEST FAILED");
    $finish;
  end
endmodule
