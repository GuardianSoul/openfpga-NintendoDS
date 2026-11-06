// A request held until done, carried from clock m (master) to clock s
// (slave): the master side of this bridge looks like the slave, and the
// other way round. Toggle handshake with two-flop synchronisers; the
// payload is captured in m when the request is taken and held until the
// answer, so it is stable for the s side long before s sees the toggle (the
// SDC bounds the payload's skew; see docs/arm-pipeline.md "CPU_FAST").
//   m side: m_req held until m_done (one cycle), m_q valid with m_done
//   s side: s_req held until s_done (one cycle), s_q valid with s_done
// A new request is taken the cycle after m_done at the earliest, and its
// payload one cycle after the request is seen: the ARM7 port's SRAM request
// (its store FIFO is an MLAB with a registered read) has its address and data
// a cycle after x_req, which its own consumer, nds_fr_arb, allows for.
module cdc_req #(
  parameter int PW = 32,                // request payload
  parameter int QW = 32                 // answer payload
) (
  input  logic          m_clk,
  input  logic          m_rst,
  input  logic          m_req,
  input  logic [PW-1:0] m_p,
  output logic          m_done,
  output logic [QW-1:0] m_q,
  input  logic          s_clk,
  input  logic          s_rst,
  output logic          s_req,
  output logic [PW-1:0] s_p,
  input  logic          s_done,
  input  logic [QW-1:0] s_q
);
  // m side
  logic          m_busy, m_arm, m_t, m_ack0, m_ack1, m_ack2;
  logic [PW-1:0] p_hold;
  // s side
  logic          s_t0, s_t1, s_seen, s_ack_t;
  logic [QW-1:0] q_hold;

  always_ff @(posedge m_clk) begin
    m_ack0 <= s_ack_t; m_ack1 <= m_ack0; m_ack2 <= m_ack1;
    m_done <= 1'b0;
    m_arm <= 1'b0;
    if (m_rst) begin
      m_busy <= 1'b0; m_t <= 1'b0;
    end else if (!m_busy) begin
      if (m_arm) begin                     // the payload, a cycle after the request
        m_busy <= 1'b1; p_hold <= m_p; m_t <= !m_t;
      end else if (m_req && !m_done) m_arm <= 1'b1;   // (not the request just answered)
    end else if (m_ack1 != m_ack2) begin   // the answer came back
      m_busy <= 1'b0; m_done <= 1'b1; m_q <= q_hold;
    end
  end

  always_ff @(posedge s_clk) begin
    s_t0 <= m_t; s_t1 <= s_t0;
    if (s_rst) begin
      s_seen <= 1'b0; s_req <= 1'b0; s_ack_t <= 1'b0;
    end else if (!s_req) begin
      if (s_t1 != s_seen) begin s_req <= 1'b1; s_p <= p_hold; end
    end else if (s_done) begin
      s_req <= 1'b0; s_seen <= s_t1; q_hold <= s_q; s_ack_t <= !s_ack_t;
    end
  end
endmodule
