// EXPERIMENT: complete fixed-slot shared ARM9/ARM7 execution replacement.
// Original arm_core is the full execution/control donor. Production is unchanged.
// Related clocks: clk2 has exactly two positive edges per clk_sys period.
// This prototype measures replay/bridge behavior; no native timing acceptance.
module arm_dual_shared #(parameter bit FAULT_OWNER=0) (
 input logic clk2,clk_sys,rst,
 input logic[1:0] run,hivecs,irq,fiq,halt_req,wake,native_wait,
 input logic[31:0] reset_pc0,reset_pc1,
 output logic[1:0] ni_req,ni_priv,
 output logic[31:0] ni_addr[0:1],
 input logic[31:0] ni_data[0:1],
 input logic[1:0] ni_ok,ni_abort,
 output logic[1:0] nd_req,nd_we,nd_priv,nc_req,nc_we,
 output logic[1:0] nd_size[0:1],
 output logic[3:0] nd_be[0:1],
 output logic[31:0] nd_addr[0:1],nd_data[0:1],
 output logic[15:0] nc_op[0:1],
 input logic[31:0] nd_rdata[0:1],
 input logic[1:0] nd_ok,nd_abort,
 output logic dbg_wen,dbg_retire,dbg_tid,
 output logic[5:0] dbg_wa,
 output logic[31:0] dbg_wd,dbg_pc,dbg_cpsr,
 output logic[1:0] dbg_halt
);
 logic ci_req,ci_tid,ci_priv,ci_ok,ci_abort;
 logic[31:0] ci_addr,ci_data;
 logic cd_req,cd_tid,cd_priv,cd_we,cd_ok,cd_abort,cd_kill;
 logic[1:0] cd_size;
 logic[3:0] cd_be;
 logic[31:0] cd_addr,cd_wdata,cd_rdata;
 logic cc_req,cc_we;
 logic[15:0] cc_op;
 logic[31:0] cc_data;
 typedef struct packed {
  logic mem,cp,cp_we,we,priv;
  logic[1:0] size;
  logic[3:0] be;
  logic[31:0] addr,data;
  logic[15:0] op;
 } dpacket_t;
 dpacket_t dq[0:1],current_d;
 logic[32:0] iq[0:1],last_i[0:1];
 logic[31:0] ir[0:1],dr[0:1];
 logic[1:0] it,ia,idone,last_iv,dt,da,ddone,last_dv,ir_abort,dr_abort;
 wire[1:0] ibusy=it^ia,dbusy=dt^da;
 wire answer_context=~ci_tid;
 assign current_d={cd_req,cc_req,cc_we,cd_we,cd_priv,cd_size,cd_be,cd_addr,cc_req?cc_data:cd_wdata,cc_op};
 // Fixed context scheduling: no solo mode, no replacement of any data bank.
 arm_shared_core #(.V5(2'b01),.RF_STYLE("MLAB"),.A9_SOLO(0),.SOLO_ONLY(0),.A9_OPT(1711268835),.SLOW(0)) engine (
  .clk(clk2),.rst(rst),.fetch_hold(ibusy),.run(run),.reset_pc0(reset_pc0),.reset_pc1(reset_pc1),
  .hivecs(hivecs),.irq(irq),.fiq(fiq),.halt_req(halt_req),.wake(wake),
  .i_req(ci_req),.i_tid(ci_tid),.i_priv(ci_priv),.i_addr(ci_addr),.i_rdata(ci_data),.i_ok(ci_ok),.i_abort(ci_abort),
  .d_req(cd_req),.d_tid(cd_tid),.d_priv(cd_priv),.d_we(cd_we),.d_size(cd_size),.d_be(cd_be),.d_addr(cd_addr),.d_wdata(cd_wdata),
  .d_rdata(cd_rdata),.d_ok(cd_ok),.d_abort(cd_abort),.d_wait(native_wait),.d_kill(cd_kill),
  .cp_req(cc_req),.cp_we(cc_we),.cp_op(cc_op),.cp_wdata(cc_data),
  .dbg_wen(dbg_wen),.dbg_wa(dbg_wa),.dbg_wd(dbg_wd),.dbg_retire(dbg_retire),.dbg_tid(dbg_tid),.dbg_pc(dbg_pc),.dbg_cpsr(dbg_cpsr),.dbg_halt(dbg_halt)
 );
 // These interfaces are held packets; four independent native ports remain.
 genvar g;
 generate for(g=0;g<2;g=g+1)begin:lane
  assign ni_req[g]=ibusy[g]&&!rst;
  assign ni_addr[g]=iq[g][31:0];assign ni_priv[g]=iq[g][32];
  assign nd_req[g]=dbusy[g]&&dq[g].mem&&!rst;
  assign nc_req[g]=dbusy[g]&&dq[g].cp&&!rst;
  assign nd_addr[g]=dq[g].addr;assign nd_data[g]=dq[g].data;
  assign nd_be[g]=dq[g].be;assign nd_size[g]=dq[g].size;
  assign nd_we[g]=dq[g].we;assign nd_priv[g]=dq[g].priv;
  assign nc_we[g]=dq[g].cp_we;assign nc_op[g]=dq[g].op;
 end endgenerate
 always_comb begin
  ci_ok=!last_iv[answer_context]||(!ibusy[answer_context]&&!idone[answer_context]&&iq[answer_context]==last_i[answer_context]);
  ci_data=ir[answer_context];ci_abort=ci_ok&&last_iv[answer_context]&&ir_abort[answer_context];
  cd_ok=!last_dv[answer_context]||(!dbusy[answer_context]&&!ddone[answer_context]);
  cd_rdata=dr[answer_context ^ FAULT_OWNER];cd_abort=cd_ok&&last_dv[answer_context]&&dr_abort[answer_context];
 end
 // Native completion ownership and response storage; one writer in SYS.
 always_ff @(posedge clk_sys)begin
  if(rst)begin ia<=0;da<=0;ir_abort<=0;dr_abort<=0;end
  else for(int c=0;c<2;c=c+1)begin
   if(ibusy[c]&&ni_ok[c])begin ia[c]<=it[c];ir[c]<=ni_data[c];ir_abort[c]<=ni_abort[c];end
   if(dbusy[c]&&nd_ok[c])begin da[c]<=dt[c];dr[c]<=nd_rdata[c];dr_abort[c]<=nd_abort[c];end
  end
 end
 // Core-side packet capture and replay consumption; one writer in clk2.
 always_ff @(posedge clk2)begin
  if(rst)begin it<=0;dt<=0;idone<=2'b11;ddone<=2'b11;last_iv<=0;last_dv<=0;end
  else begin
   last_iv[ci_tid]<=ci_req;
   if(ci_req)begin
    last_i[ci_tid]<={ci_priv,ci_addr};
    if(!ibusy[ci_tid]&&(idone[ci_tid]||iq[ci_tid]!={ci_priv,ci_addr}))begin
     iq[ci_tid]<={ci_priv,ci_addr};it[ci_tid]<=~it[ci_tid];idone[ci_tid]<=0;
    end
   end
   if(last_iv[answer_context]&&ci_ok)idone[answer_context]<=1;
   last_dv[cd_tid]<=(cd_req||cc_req)&&!cd_kill;
   if((cd_req||cc_req)&&!cd_kill&&!dbusy[cd_tid]&&ddone[cd_tid])begin
    dq[cd_tid]<=current_d;dt[cd_tid]<=~dt[cd_tid];ddone[cd_tid]<=0;
   end
   if(last_dv[answer_context]&&cd_ok)ddone[answer_context]<=1;
  end
 end
`ifndef SYNTHESIS
`ifndef ALTERA_RESERVED_QIS
 // Compare every meaningful replay field. Load write-data and inactive CP15
 // fields are unspecified pipeline values; they need not match a held packet.
 always_ff @(posedge clk2)if(!rst&&(cd_req||cc_req)&&!cd_kill&&!ddone[cd_tid])begin
  if(current_d.mem!==dq[cd_tid].mem || current_d.cp!==dq[cd_tid].cp ||
     (current_d.mem && ({current_d.we,current_d.priv,current_d.size,current_d.be,current_d.addr} !==
                       {dq[cd_tid].we,dq[cd_tid].priv,dq[cd_tid].size,dq[cd_tid].be,dq[cd_tid].addr} ||
                       (current_d.we && current_d.data!==dq[cd_tid].data))) ||
     (current_d.cp && ({current_d.cp_we,current_d.op} !== {dq[cd_tid].cp_we,dq[cd_tid].op} ||
                      (current_d.cp_we && current_d.data!==dq[cd_tid].data))))
   $fatal(1,"shared_exec: live data request changed while unanswered ctx=%0d current=%h queued=%h pc=%h busy=%b",cd_tid,current_d,dq[cd_tid],dbg_pc,dbusy);
 end
`endif
`endif
endmodule
