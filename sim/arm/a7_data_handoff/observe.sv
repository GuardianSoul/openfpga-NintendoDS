`timescale 1ns/1ps
// Passive pre-edge witness: no DUT assignment, force, delay or termination.
module a7_data_owner_observer(
 input logic clk,rst,d_req,d_ok,d_we,da_v,da_ok,da_w,wb_v,busy,busy_w,rp_v,rp_i,rb_v,
 input logic[31:0]d_addr,d_wdata,d_rdata,wb_a,rp_a,rb_a,f_addr,f_wdata,f_rdata,
 input logic[3:0]d_be,rp_be,f_be,
 input logic f_req,f_we,f_ack,matched,return_now,held_now
);
 string path;integer fd=0;longint unsigned cycle=0;
 initial if($value$plusargs("a7data_witness=%s",path))begin
  fd=$fopen($sformatf("%s-%m.csv",path),"w");
  $fdisplay(fd,"cycle,rst,d_req,d_ok,d_we,d_addr,d_be,d_wdata,d_rdata,da_v,da_ok,da_w,wb_v,wb_a,busy,busy_w,rp_v,rp_i,rp_a,rp_be,rb_v,rb_a,f_req,f_we,f_addr,f_be,f_wdata,f_ack,f_rdata,matched,return_now,held_now");
 end
 always @(posedge clk)begin
  if(fd)$fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",cycle,rst,d_req,d_ok,d_we,d_addr,d_be,d_wdata,d_rdata,da_v,da_ok,da_w,wb_v,wb_a,busy,busy_w,rp_v,rp_i,rp_a,rp_be,rb_v,rb_a,f_req,f_we,f_addr,f_be,f_wdata,f_ack,f_rdata,matched,return_now,held_now);
  cycle++;
 end
 final if(fd)$fclose(fd);
endmodule
bind nds_arm7_port a7_data_owner_observer u_data_observer(.*, .matched(da_owned),.return_now(data_return),.held_now(data_held));
bind old_nds_arm7_port a7_data_owner_observer u_data_observer(.*, .matched(1'b0),.return_now(1'b0),.held_now(1'b0));
