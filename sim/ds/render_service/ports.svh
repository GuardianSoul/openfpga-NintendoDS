) (
 input logic clk,clk_2x,rst,fg_now,input logic[2:0]generation,
 output logic frame_done,output logic ps_line_req,output logic[7:0]ps_line_y,
 input logic ps_valid,input logic[1:0]ps_type,input logic[127:0]ps_data,output logic ps_ready,
 output logic tex_req,output logic[18:0]tex_addr,output logic pal_req,output logic[16:0]pal_addr,
 output logic px_valid,output logic[7:0]px_x,px_y,output logic[22:0]px_color,
 input logic l3d_go,l3d_done,input logic[7:0]l3d_line,l3d_raddr,
 output logic[22:0]l3d_rdata,output logic l3d_have,output logic[8:0]y_lim_rg,
 output logic t_req,output gpu2d_pkg::blk_t t_blk,input logic t_ack,t_rvalid,input logic[63:0]t_rdata,
 output logic rg_wreq,output logic[23:0]rg_waddr,output logic[31:0]rg_wdata,input logic rg_wack,
 output logic rg_rreq,rg_hurry,output logic[23:0]rg_raddr,input logic rg_rack,rg_rvalid,input logic[31:0]rg_rdata,
 input logic[6:0]rg_wfill,rg_wpcnt,input logic ring_due_valid,input logic[7:0]ring_due_line,input logic[13:0]ring_due_sys
);
