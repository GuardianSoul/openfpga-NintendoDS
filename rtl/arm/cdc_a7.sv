// The ARM7 port's two crossings for cpu_domain's CPU_FAST (docs/arm-pipeline.md
// "Built: CPU_FAST"): its SRAM requests (x7) and its fabric requests (f7), held until
// done (cdc_req), and x7_stores for the SRAM arbiter (nds_fr_arb: others'
// reads wait while it is up).
//   - STORE_GATE (nds_arm7_port, whose store FIFO drains apart from its
//     fabric accesses): a fabric access waits to start while the port has
//     SRAM stores not yet done, so an IPC write cannot overtake its own
//     shared-WRAM stores.
//     nds_arm7_port_min needs no gate (it starts a fabric access only once
//     its one store is done) and must not have one: a store it posts on the
//     edge a fetch starts would hold that fetch back while waiting behind it.
//   - x7_stores is not raised while a fabric access is on its way: a store
//     waiting behind it (nds_arm7_port_min) would hold the SRAM for the
//     fabric's other masters while the fabric waits for that access.
module cdc_a7 #(
  parameter int STORE_GATE = 1
) (
  input  logic        clk_cpu,
  input  logic        c_rst,
  input  logic        clk,              // clk_sys
  input  logic        rst,
  // the port's side (clk_cpu)
  input  logic        c_x7_req,
  input  logic        c_x7_we,
  input  logic [17:2] c_x7_addr,
  input  logic [3:0]  c_x7_be,
  input  logic [31:0] c_x7_wdata,
  input  logic        c_x7_stores,
  output logic        c_x7_done,
  output logic [31:0] c_x7_rdata,
  input  logic        c_f7_req,
  input  logic        c_f7_we,
  input  logic [31:0] c_f7_addr,
  input  logic [3:0]  c_f7_be,
  input  logic [31:0] c_f7_wdata,
  output logic        c_f7_ack,
  output logic [31:0] c_f7_rdata,
  // the system's side (clk)
  output logic        x7_req,
  output logic        x7_we,
  output logic [17:2] x7_addr,
  output logic [3:0]  x7_be,
  output logic [31:0] x7_wdata,
  output logic        x7_stores,
  input  logic        x7_done,
  input  logic [31:0] x7_rdata,
  output logic        f7_req,
  output logic        f7_we,
  output logic [31:0] f7_addr,
  output logic [3:0]  f7_be,
  output logic [31:0] f7_wdata,
  input  logic        f7_ack,
  input  logic [31:0] f7_rdata
);
  cdc_req #(.PW(53), .QW(32)) u_x7 (
    .m_clk(clk_cpu), .m_rst(c_rst), .m_req(c_x7_req),
    .m_p({c_x7_we, c_x7_be, c_x7_addr, c_x7_wdata}), .m_done(c_x7_done), .m_q(c_x7_rdata),
    .s_clk(clk), .s_rst(rst), .s_req(x7_req), .s_p({x7_we, x7_be, x7_addr, x7_wdata}),
    .s_done(x7_done), .s_q(x7_rdata));
  wire  f_go = c_f7_req && (STORE_GATE == 0 || !c_x7_stores);
  cdc_req #(.PW(69), .QW(32)) u_f7 (
    .m_clk(clk_cpu), .m_rst(c_rst), .m_req(f_go),
    .m_p({c_f7_we, c_f7_be, c_f7_addr, c_f7_wdata}), .m_done(c_f7_ack), .m_q(c_f7_rdata),
    .s_clk(clk), .s_rst(rst), .s_req(f7_req), .s_p({f7_we, f7_be, f7_addr, f7_wdata}),
    .s_done(f7_ack), .s_q(f7_rdata));
  logic       st_c;
  logic [1:0] st_s;
  always_ff @(posedge clk_cpu) st_c <= c_x7_stores && !f_go;
  always_ff @(posedge clk) st_s <= {st_s[0], st_c};
  assign x7_stores = st_s[1] || x7_req && x7_we;
endmodule
