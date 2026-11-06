// PROPOSAL ONLY. No caller in the frozen host. Default enable remains0.
package hg193_bootstrap_reads;
 localparam bit PROPOSAL_DEFAULT_ENABLE=1'b0;
 typedef struct packed {
  logic valid,known,arm9,write;
  logic [1:0] physical_class; //1=PSRAM instruction,2=KEYINPUT IO
  logic [31:0] address,data;
  logic [15:0] owner_tag;
 } descriptor_t;
 typedef struct packed {
  logic held,phase_original,stub_bytes_match,owner_snapshot_complete;
  logic [31:0] ctrl,fetch_pc;
  logic i_req,f_req,d_req,d_we,w_req,w_we,cp_req,w_cp;
  logic [31:0] i_addr,f_addr,d_addr,w_addr;
  logic dp_v,dp_read,ip_v,b_req,b_we,ibuf_v,rbuf_v;
  logic [31:0] dp_a,ip_a,b_addr,ibuf_a,rbuf_a;
  logic [3:0] state; // original arm9_mem:0IDLE,2RD1,3IRD1
  logic pending_write_or_maintenance; //OR all preserved write/prefetch/CMO owners
  descriptor_t accepted,completed;
 } view_t;
 function automatic bit stub_word(input logic [31:0] address);
  return (address[1:0]===2'b00) &&
      (address>=32'h02309000) && (address<32'h02309224);
 endfunction
 function automatic bit descriptor_safe(input descriptor_t d);
  if(d.valid===1'b0)return 1;
  return (d.valid===1'b1) && (d.known===1'b1) && (d.arm9===1'b1) && (d.write===1'b0) &&
      (((d.physical_class===2'd1) && stub_word(d.address)) ||
       ((d.physical_class===2'd2) && (d.address===32'h04000130)));
 endfunction
 function automatic bit permit(input bit original_strict,input bit proposal_enable,input view_t v);
  // Preserve EVERY originally accepted state, including inert stale values.
  if(original_strict)return 1;
  if(!proposal_enable)return 0;
  return (v.held===1'b1) && (v.phase_original===1'b1) &&
   (v.stub_bytes_match===1'b1) && (v.owner_snapshot_complete===1'b1) &&
   ((v.ctrl & 32'h00001005)===32'd0) && stub_word(v.fetch_pc) &&
   (v.cp_req===1'b0) && (v.w_cp===1'b0) && (v.pending_write_or_maintenance===1'b0) &&
   ((v.i_req===1'b0) || ((v.i_req===1'b1) && stub_word(v.i_addr))) &&
   ((v.f_req===1'b0) || ((v.f_req===1'b1) && stub_word(v.f_addr))) &&
   ((v.d_req===1'b0) || ((v.d_req===1'b1) && (v.d_we===1'b0) && (v.d_addr===32'h04000130))) &&
   ((v.w_req===1'b0) || ((v.w_req===1'b1) && (v.w_we===1'b0) && (v.w_addr===32'h04000130))) &&
   ((v.dp_v===1'b0) || ((v.dp_v===1'b1) && (v.dp_read===1'b1) && (v.dp_a===32'h04000130))) &&
   ((v.ip_v===1'b0) || ((v.ip_v===1'b1) && stub_word(v.ip_a))) &&
   ((v.b_req===1'b0) || ((v.b_req===1'b1) && (v.b_we===1'b0) &&
     (((v.state===4'd3) && stub_word(v.b_addr) && (v.b_addr===v.ip_a)) ||
      ((v.state===4'd2) && (v.b_addr===32'h04000130) && (v.b_addr===v.dp_a))))) &&
   ((v.state===4'd0) || (v.state===4'd2) || (v.state===4'd3)) &&
   ((v.ibuf_v===1'b0) || ((v.ibuf_v===1'b1) && stub_word(v.ibuf_a))) &&
   ((v.rbuf_v===1'b0) || ((v.rbuf_v===1'b1) && (v.rbuf_a===32'h04000130))) &&
   descriptor_safe(v.accepted) && descriptor_safe(v.completed) &&
   ((v.accepted.valid===1'b0) ||
       ((v.b_req===1'b1) && (v.accepted.address===v.b_addr)));
 endfunction
endpackage
