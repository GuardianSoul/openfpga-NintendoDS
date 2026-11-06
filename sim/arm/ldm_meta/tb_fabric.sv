`timescale 1ns/1ps
module tb_meta_fabric;
 logic clk=0,rst=1;always #5 clk=!clk;
 logic a9_ldm=1;logic[6:0]a9_ldm_meta=0;
    // ARM9 and ARM7 ports
    logic        a9_req = 0, a9_we = 0, a9_n8 = 0;
    logic [31:0] a9_addr = 0, a9_wdata = 0;
    logic [3:0]  a9_be = 0;
    logic        a9_ack, a9_rvalid, a9_wnext;
    logic [31:0] a9_rdata;
    logic        a7_req = 0, a7_we = 0;
    logic [31:0] a7_addr = 0, a7_wdata = 0;
    logic [3:0]  a7_be = 0;
    logic        a7_ack;
    logic [31:0] a7_rdata;
    // main RAM
    logic        fm_req, fm_we, fm_ack, fm_rvalid, fm_n8, fm_wnext;
    logic [21:2] fm_addr;
    logic [3:0]  fm_be;
    logic [31:0] fm_wdata;
    logic        mr_req, mr_we, mr_n8;
    logic [22:2] mr_addr;
    logic [3:0]  mr_be;
    logic [31:0] mr_wdata, mr_rdata;
    logic        mr_ack = 0, mr_rvalid = 0, mr_wnext = 0;
    logic        mon_we;
    logic [31:0] mon_addr, mon_wdata;
    logic [3:0]  mon_be;
`ifndef A7F
`define A7F 1
`endif
    nds_fabric #(.MR_BLOCK(1), .LDM_HIT_EARLY(1), .LDM_STREAM4(1), .A7_FIRST(`A7F)) u_fab (.clk, .rst, .dm_unit(1'b0), .dm_more(1'b0), .dm_dst(32'd0), .dx_valid(), .dx_ready(1'b1), .dx_idle(1'b1), .wramcnt(2'd3), .exmemcnt9(8'd0), .pb_busy(1'b0),
        .dm_req(1'b0), .dm_we(1'b0), .dm_cpu(1'b0), .dm_size32(1'b1), .dm_addr(32'd0), .dm_wdata(32'd0), .dm_ack(), .dm_rdata(),
        .a9_ldm,.a9_ldm_meta,.a9_req, .a9_we, .a9_addr, .a9_be, .a9_wdata, .a9_ack, .a9_rdata, .a9_n8, .a9_rvalid, .a9_wnext,
        .a7_req, .a7_we, .a7_addr, .a7_be, .a7_wdata, .a7_ack, .a7_rdata,
        .sn_req(1'b0), .sn_we(1'b0), .sn_addr(32'd0), .sn_wdata(32'd0), .sn_ack(), .sn_rdata(),
        .mr_req(fm_req), .mr_we(fm_we), .mr_addr(fm_addr), .mr_be(fm_be), .mr_wdata(fm_wdata),
        .mr_ack(fm_ack), .mr_rvalid(fm_rvalid), .mr_rdata, .mr_n8(fm_n8), .mr_wnext(fm_wnext),
        .fx_req(), .fx_we(), .fx_addr(), .fx_be(), .fx_wdata(), .fx_done(1'b0), .fx_rdata(32'd0),
        .boot_addr(), .boot_q(32'd0), .ram_wdata(),
        .io_req(), .io_cpu(), .io_we(), .io_be(), .io_addr(), .io_wdata(), .io_ack(1'b0), .io_rdata(32'd0),
        .vr_req(), .vr_cpu(), .vr_we(), .vr_addr(), .vr_be(), .vr_wdata(), .vr_ack(1'b0), .vr_rdata(32'd0),
        .pal_cq(32'd0), .pal_we(), .oam_we(), .po_waddr(), .po_wdata(), .po_be(),
        .mon_we, .mon_master(), .mon_cpu(), .mon_addr, .mon_be, .mon_wdata);

 int state=0,k=0,timer=0,physical=0,logical=0,inside_fill=0,heads=0;
 logic[21:2]held;
 function automatic logic[31:0]data(input logic[31:0]a);return ((a & 32'h003fffff)>>2)^32'h13240000;endfunction
 always @(posedge clk)begin
  fm_ack<=0;fm_rvalid<=0;
  case(state)
   0:if(fm_req&&!fm_ack)begin held<={fm_addr[21:4],2'd0};timer<=3;state<=1;end
   1:if(timer!=0)timer<=timer-1;else begin fm_ack<=1;timer<=3;state<=2;k<=0;physical++;end
   2:if(timer!=0)timer<=timer-1;else begin fm_rvalid<=1;mr_rdata<=data({10'd0,held+20'(k),2'd0});k<=k+1;if(k==3)state<=3;end
   3:state<=0;
  endcase
  if(!rst && a9_req && a9_ack && a9_ldm)begin
   if(u_fab.ldm_answer_meta!==a9_ldm_meta)$fatal(1,"logical ACK descriptor mismatch %h/%h",u_fab.ldm_answer_meta,a9_ldm_meta);
   if(a9_rdata!==data(a9_addr))$fatal(1,"logical data order mismatch");
   logical++;$display("LOGICAL addr%h meta%h state%0d",a9_addr,u_fab.ldm_answer_meta,u_fab.st);
  end
  if(!rst && u_fab.ld4_take)inside_fill++;
  if(!rst && u_fab.st==0 && u_fab.grant[1])heads++;
 end
 task automatic word(input int a,input logic[6:0]meta,input bit tag=1);
  @(negedge clk);a9_req=1;a9_we=0;a9_n8=0;a9_be=15;a9_addr=a;a9_ldm=tag;a9_ldm_meta=meta;
  do @(posedge clk);while(!a9_ack);
 endtask
 initial begin
  fm_ack=0;fm_rvalid=0;mr_rdata=0;a7_be=15;
  repeat(8)@(negedge clk);rst=0;
  word(32'h02410000,7'h47);
  word(32'h02410004,7'h07);
  word(32'h02410008,7'h07);
  word(32'h0241000c,7'h27);
  // A new instruction starts in the existing physical line; original count2.
  word(32'h02410000,7'h43);
  word(32'h02410004,7'h23);
  // Repeated singleton at the same address, no low-request gap.
  word(32'h02410000,7'h61);word(32'h02410000,7'h61);
  // Pending physical head then tail under an opposing owner request.
  word(32'h02410010,7'h43);
  fork
   word(32'h02410014,7'h23);
   begin
    @(negedge clk);a7_req=1;a7_we=0;a7_addr=32'h02411000;
    do @(posedge clk);while(!a7_ack);
    if(a7_rdata!==data(a7_addr))$fatal(1,"other owner data");
    @(negedge clk);a7_req=0;
   end
  join
  @(negedge clk);a9_req=0;
  repeat(40)@(negedge clk);
  if(logical!=10||inside_fill<3||heads<2)$fatal(1,"admission coverage %0d/%0d/%0d",logical,inside_fill,heads);
  $display("FAB_META_PASS logical%0d normal%0d under_fill%0d physical%0d",logical,heads,inside_fill,physical);$finish;
 end
 initial begin #200000;$fatal(1,"timeout");end
endmodule
