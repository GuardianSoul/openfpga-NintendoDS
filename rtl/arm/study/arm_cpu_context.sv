// EXPERIMENT: native-ready complete dual-CPU replacement. One shared execution
// pipeline at clk2, unchanged ARM9 memory/controller at clk_sys. No old CPU
// engines are instantiated. Debug write/retire stream belongs to clk2.
module arm_cpu_context #(parameter STORE_STYLE="MLAB",parameter bit STORE_SYNC=0,parameter bit FAULT_CONTEXT=0,parameter bit FAULT_OWNER=0,parameter bit FAULT_LAUNCH=0,parameter bit FAULT_DUP_STORE=0)(
 input logic clk_sys,clk2,rst,
 input logic[1:0]run,irq,fiq,
 input logic[31:0]reset_pc0,reset_pc1,
 input logic hivecs7,wake7,
 output logic b9_n8,b9_req,b9_we,
 output logic[31:0]b9_addr,b9_wdata,
 output logic[3:0]b9_be,b9_tmr,
 input logic b9_wnext,b9_ack,
 input logic[31:0]b9_rdata,
 output logic a7_i_req,
 output logic[31:0]a7_i_addr,
 input logic[31:0]a7_i_rdata,
 input logic a7_i_ok,
 output logic a7_d_req,a7_d_we,
 output logic[31:0]a7_d_addr,a7_d_wdata,
 output logic[3:0]a7_d_be,
 input logic[31:0]a7_d_rdata,
 input logic a7_d_ok,
 output logic dbg_wen,dbg_retire,dbg_tid,
 output logic[5:0]dbg_wa,
 output logic[31:0]dbg_wd,dbg_pc,dbg_cpsr,
 output logic[1:0]dbg_halt,dg_fill
);
 logic[1:0]ni_req,ni_priv,ni_ok,ni_abort;
 logic[31:0]ni_addr[0:1],ni_data[0:1];
 logic[1:0]nd_req,nd_we,nd_priv,nc_req,nc_we,nd_ok,nd_abort;
 logic[1:0]nd_size[0:1];logic[3:0]nd_be[0:1];
 logic[31:0]nd_addr[0:1],nd_data[0:1],nd_rdata[0:1];logic[15:0]nc_op[0:1];
 logic m_i_ok,m_i_abort,m_d_ok,m_d_abort,m_d_wait,m_hivecs;
 logic[31:0]m_i_data,m_d_data;
 logic i_launched,d_launched,i7_launched,d7_launched;
 logic m_i_req,m_d_req,m_c_req;
 logic halt7;
 // A7 HALTCNT is observed at the accepted native store, as in arm_cpu.
 // The asserted phase contract places the A7 execution slot at each SYS edge.
 assign halt7=nd_req[1]&&nd_ok[1]&&a7_d_we&&a7_d_addr[31:2]==30'h010000c0&&a7_d_be[1]&&a7_d_wdata[15:8]==8'h80;
 arm_dual_context #(.STORE_STYLE(STORE_STYLE),.STORE_SYNC(STORE_SYNC),.FAULT_CONTEXT(FAULT_CONTEXT),.FAULT_OWNER(FAULT_OWNER)) shared(
  .clk2,.clk_sys,.rst,.run,.hivecs({hivecs7,m_hivecs}),.irq,.fiq,
  .halt_req({halt7,1'b0}),.wake({wake7,irq[0]}),.native_wait({1'b0,m_d_wait}),.reset_pc0,.reset_pc1,
  .ni_req,.ni_priv,.ni_addr,.ni_data,.ni_ok,.ni_abort,
  .nd_req,.nd_we,.nd_priv,.nc_req,.nc_we,.nd_size,.nd_be,.nd_addr,.nd_data,.nc_op,.nd_rdata,.nd_ok,.nd_abort,
  .dbg_wen,.dbg_retire,.dbg_tid,.dbg_wa,.dbg_wd,.dbg_pc,.dbg_cpsr,.dbg_halt
 );
 // arm9_mem is a registered request/answer pipeline, not a generic ACK port.
 // Qualify its answer only after launch; suppress the next registered copy
 // when the current answer commits, preventing repeated stores/CP15 writes.
 assign ni_ok[0]=ni_req[0]&&i_launched&&m_i_ok;
 assign nd_ok[0]=(nd_req[0]||nc_req[0])&&(d_launched||FAULT_LAUNCH)&&m_d_ok;
 assign m_i_req=ni_req[0]&&!ni_ok[0];
 assign m_d_req=nd_req[0]&&!nd_ok[0];
 assign m_c_req=nc_req[0]&&!nd_ok[0];
 assign ni_data[0]=m_i_data;assign ni_abort[0]=m_i_abort;
 assign nd_rdata[0]=m_d_data;assign nd_abort[0]=m_d_abort;
 always_ff @(posedge clk_sys)begin
  if(rst)begin i_launched<=0;d_launched<=0;i7_launched<=0;d7_launched<=0;end
  else begin
   if(ni_ok[1]||!ni_req[1])i7_launched<=0;else if(a7_i_req)i7_launched<=1;
   if(nd_ok[1]||!nd_req[1])d7_launched<=0;else if(a7_d_req)d7_launched<=1;
   if(ni_ok[0]||!ni_req[0])i_launched<=0;else if(m_i_req)i_launched<=1;
   if(nd_ok[0]||!(nd_req[0]||nc_req[0]))d_launched<=0;else if(m_d_req||m_c_req)d_launched<=1;
  end
 end
 arm9_mem #(.WAYS(2),.BURST(1),.SLOW(1),.EVB(1),.EVBW(0),.EARLYD(1),.XD(2),.XI(1),.OPT(1711268835)) u_mem9(
  .clk(clk_sys),.rst,
  .i_req(m_i_req),.i_priv(ni_priv[0]),.i_addr(ni_addr[0]),.i_rdata(m_i_data),.i_half(),.i_half_hi(1'b0),.i_ok(m_i_ok),.i_abort(m_i_abort),
  .d_req(m_d_req),.d_kill(1'b0),.d_we(nd_we[0]),.d_priv(nd_priv[0]),.d_be(nd_be[0]),.d_addr(nd_addr[0]),.d_wdata(nd_data[0]),
  .cp_req(m_c_req),.cp_we(nc_we[0]),.cp_op(nc_op[0]),.cp_wdata(nd_data[0]),
  .d_rdata_f(m_d_data),.d_ok(m_d_ok),.d_abort(m_d_abort),.d_wait(m_d_wait),.hivecs(m_hivecs),
  .b_n8(b9_n8),.b_wnext(b9_wnext),.dg_fill,.b_req(b9_req),.b_we(b9_we),.b_addr(b9_addr),.b_wdata(b9_wdata),.b_be(b9_be),.b_tmr(b9_tmr),.b_ack(b9_ack),.b_rdata(b9_rdata)
 );
 // ARM7 also answers a registered request on the following SYS cycle.
 // Do not issue another copy on the edge consuming that answer.
 assign a7_i_req=ni_req[1]&&!ni_ok[1];assign a7_i_addr=ni_addr[1];
 assign ni_ok[1]=ni_req[1]&&i7_launched&&a7_i_ok;assign ni_data[1]=a7_i_rdata;assign ni_abort[1]=0;
 assign a7_d_req=nd_req[1]&&(!nd_ok[1]||FAULT_DUP_STORE);assign a7_d_we=nd_we[1];assign a7_d_be=nd_be[1];assign a7_d_addr=nd_addr[1];assign a7_d_wdata=nd_data[1];
 assign nd_ok[1]=nd_req[1]&&d7_launched&&a7_d_ok;assign nd_rdata[1]=a7_d_rdata;assign nd_abort[1]=0;
`ifndef SYNTHESIS
`ifndef ALTERA_RESERVED_QIS
 // Reset is released by SYS. With phase-zero clk2, reset tid0 then the first
 // half-slot is A9; the following SYS edge is A7. No phase-tolerance waiver.
 always_ff @(posedge clk_sys)if(!rst)begin
  if(shared.ci_tid!==1'b1)$fatal(1,"shared_exec: SYS/A7 slot reset phase mismatch");
  if(nc_req[1])$fatal(1,"shared_exec: ARM7 issued CP15");
 end
`endif
`endif
endmodule
