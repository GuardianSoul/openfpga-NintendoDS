// STUDY: one integer resource cone, two fixed halfSYS slots. No memory queue.
module arm_exec_halfslots #(parameter bit FAULT_OWNER=0)(
 input logic clk_sys,clk2,rst,
 input logic[31:0]r9v,a9x,a9y,l9a,l9b,r7v,a7x,a7y,l7a,l7b,
 input logic[4:0]r9n,r7n,
 input logic a9ci,a7ci,
 input logic[3:0]l9op,l7op,
 output logic[31:0]r9r,l9r,r7r,l7r,
 output logic[32:0]a9r,a7r
);
 logic owner; // 0 first half: A9, 1 second half: A7
 logic[31:0]rot_v,rot_r,la,lb,lr;
 logic[4:0]rot_n;logic[3:0]lop;
 logic[31:0]ax,ay;logic ci;logic[32:0]ar;
 logic[31:0]saved_rot9,saved_logic9;logic[32:0]saved_add9;
 wire selected=owner ^ FAULT_OWNER;
 assign rot_v=selected?r7v:r9v;assign rot_n=selected?r7n:r9n;
 assign ax=selected?a7x:a9x;assign ay=selected?a7y:a9y;assign ci=selected?a7ci:a9ci;
 assign la=selected?l7a:l9a;assign lb=selected?l7b:l9b;assign lop=selected?l7op:l9op;
 always_comb begin
  rot_r=rot_v;
  if(rot_n[4])rot_r={rot_r[15:0],rot_r[31:16]};
  if(rot_n[3])rot_r={rot_r[7:0],rot_r[31:8]};
  if(rot_n[2])rot_r={rot_r[3:0],rot_r[31:4]};
  if(rot_n[1])rot_r={rot_r[1:0],rot_r[31:2]};
  if(rot_n[0])rot_r={rot_r[0],rot_r[31:1]};
 end
 assign ar={1'b0,ax}+{1'b0,ay}+{32'b0,ci};
 always_comb case(lop)
  4'h0,4'h8:lr=la&lb;
  4'h1,4'h9:lr=la^lb;
  4'hc:lr=la|lb;
  4'he:lr=la&~lb;
  4'hf:lr=~lb;
  default:lr=lb;
 endcase
 assign r9r=owner?saved_rot9:rot_r;
 assign a9r=owner?saved_add9:ar;
 assign l9r=owner?saved_logic9:lr;
 assign r7r=rot_r;assign a7r=ar;assign l7r=lr;
 always_ff @(posedge clk2)begin
  if(rst)begin owner<=!clk_sys;saved_rot9<=0;saved_add9<=0;saved_logic9<=0;end
  else begin
   if(!owner)begin saved_rot9<=rot_r;saved_add9<=ar;saved_logic9<=lr;end
   owner<=!owner;
  end
 end
`ifndef SYNTHESIS
 always @(posedge clk_sys)if(!rst&&owner!==1'b1)$fatal(1,"shared exec phase mismatch");
`endif
endmodule
