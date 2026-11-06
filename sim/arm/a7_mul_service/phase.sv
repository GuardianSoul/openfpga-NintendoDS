// Experimental owner-bound logical merge policy. Not a universal bus law.
// P7 and all physical descriptors remain unchanged; only logical eligibility
// of the original measured-class F word is controlled here.
module a7_mul_phase import arm_pkg::*; #(parameter bit ENABLE=0)(
 input logic clk,rst_cpu,i_req,i_arm,i_redirect,i_consume,
 input logic[31:0]i_addr,
 input a7_mul_context_t request_meta,
 input a7_mul_advance_t actual_advance,
 input logic payload_ok,
 output logic result_ok,
 output logic pending,
 output logic[4:0]remaining,
 output logic spill
);
 generate if(ENABLE)begin:g_enabled
  logic owned,spill_tail;
  logic[31:2]owner_addr;
  logic[4:0]left;
  wire eligible=request_meta.valid&&!request_meta.thumb&&
    !request_meta.accumulate&&!request_meta.set_flags&&
    request_meta.internal_steps>=1&&request_meta.internal_steps<=4&&
    i_arm&&i_addr[31:24]==8'h02;
  // The selected finite candidate overlaps the first three actual internal
  // advances with one existing nine-A7-cycle MAIN service window. A later
  // accepted internal advance occupies a separate two-SYS interval. Never
  // infer execution from e_busy or reprice an already-admitted packet.
  wire owner_live=owned&&owner_addr==i_addr[31:2];
  wire internal_spill=owner_live&&actual_advance.valid&&actual_advance.index>=3;
  assign result_ok=payload_ok&&(!owned||(owner_live&&left==0&&!spill_tail));
  assign pending=owned;
  assign remaining=left;
  assign spill=internal_spill;
  always_ff @(posedge clk)begin
   if(rst_cpu||i_redirect||i_consume)begin
    owned<=0;owner_addr<='0;left<=0;spill_tail<=0;
   end else begin
    spill_tail<=internal_spill;
    if(owned)begin
     if(left!=0&&!internal_spill&&!spill_tail)left<=left-5'd1;
    end else if(i_req&&eligible)begin
     owned<=1;owner_addr<=i_addr[31:2];left<=5'd16;spill_tail<=0;
    end
   end
  end
 end else begin:g_disabled
  assign result_ok=payload_ok;
  assign pending=0;assign remaining=0;assign spill=0;
 end endgenerate
endmodule
