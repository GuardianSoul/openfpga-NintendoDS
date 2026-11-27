// Formal check (SymbiYosys): arm9_core never sends a load right behind a store that is performed, so arm9_mem's
// SLOW store-to-load merge (MEM1: `same` with pw_v, d_rdata_f) has nothing to merge on a9c.
// arm9_mem performs a WB access only when it is not killed (wq_e = w_req && !d_kill, d_kill in the answer cycle),
// and its WB is the cycle after the request: pw_v at cycle n+1 means a store requested at n-1, not killed at n.
// The merge needs a load requested at n (in WB at n+1, with pw_v). Every input of the core is free (arm9_mem,
// interrupts, run): a superset of what the chip gives it, so a proof here holds on the chip.
module fv_a9_stld import arm_pkg::*; (
  input  logic        clk,
  input  logic [1:0]  run, hivecs, irq, fiq, halt_req, wake,
  input  logic [31:0] reset_pc0, reset_pc1,
  input  logic [31:0] i_rdata,
  input  logic [15:0] i_rhw,
  input  logic [4:0]  i_rcls,
  input  logic [6:0]  i_rtop,
  input  logic        i_ok, i_abort,
  input  logic [31:0] d_rdata,
  input  logic        d_ok, d_abort,
  input  logic [1:0]  d_wait
);
  logic [3:0] rcnt = 4'd0;
  wire rst = rcnt != 4'd15;
  always_ff @(posedge clk) if (rst) rcnt <= rcnt + 4'd1;
  logic d_req, d_we, d_kill, cp_req;
  arm9_core #(.RF_STYLE("MLAB")) dut (.clk, .rst, .run, .reset_pc0, .reset_pc1, .hivecs, .irq, .fiq, .halt_req, .wake,
    .i_req(), .i_tid(), .i_priv(), .i_addr(), .i_addr_s(), .i_addr_r(), .i_rdr(), .i_rdata, .i_hsel(), .i_rhw, .i_rcls, .i_rtop,
    .i_ok, .i_abort,
    .d_req, .d_tid(), .d_priv(), .d_we, .d_size(), .d_be(), .d_addr(), .d_wdata(), .d_rdata, .d_lw_it(d_rdata), .d_lw_dt(d_rdata), .d_lw_rs(d_rdata), .d_ls_it(1'b0), .d_ls_dt(1'b0), .d_ok, .d_abort, .d_wait,
    .d_kill, .cp_req, .cp_we(), .cp_op(), .cp_wdata(),
    .dbg_wen(), .dbg_wa(), .dbg_wd(), .dbg_retire(), .dbg_tid(), .dbg_pc(), .dbg_cpsr(), .dbg_halt());
  logic st_q = 1'b0;                 // a store was requested last cycle
  always_ff @(posedge clk) st_q <= !rst && d_req && d_we;
  // st_q && !d_kill: that store is performed in WB this cycle (pw_v next cycle); a load requested now is in WB then
  always_comb if (!rst) assert (!(st_q && !d_kill && d_req && !d_we));
`ifdef FV_COVER
  logic st2_q = 1'b0;                // a store two cycles ago
  always_ff @(posedge clk) st2_q <= st_q;
  always_comb if (!rst) begin
    cover (d_req && d_we);
    cover (d_req && !d_we);
    cover (st2_q && d_req && !d_we && !d_kill);   // a load two cycles behind a store: the closest the interlock allows
  end
`endif
endmodule
