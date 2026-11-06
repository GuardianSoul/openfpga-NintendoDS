// Isolated component fixture. All nds_gpu3d parameters are extracted from
// successful elaboration of the actual frozen core_top/profile58 testbench.
// Full actual hierarchy resolution is qualified separately, without a ROM.
`timescale 1ns/1ps
module hg193_component_top #(
 `include "component_profile_parameters.svh"
)(input logic clk_sys,clk_2x,rst,tick,
 input logic[15:0]disp3dcnt,input logic io_req,io_we,
 input logic[11:2]io_addr,input logic[31:0]io_wdata,output logic io_ack,
 output logic rg_wreq,rg_rreq);
 wire line_start=1'b1;
 wire[8:0]vcount=9'd193;
 generate if(1)begin:ds
  if(1)begin:g_3d
   nds_gpu3d #(
    `include "component_gpu_parameters.svh"
   )u_gpu3d(.clk(clk_sys),.clk_2x,.rst,.tick,.geom_en(1'b1),.rend_en(1'b1),
    .vblank(1'b0),.line215(1'b0),.disp3dcnt,.io_req,.io_we,.io_be(4'hf),
    .io_addr,.io_wdata,.io_ack,.dx_valid(1'b0),.p_ack(1'b0),.p_rvalid(1'b0),.p_rdata(32'd0),
    .vram_wr(1'b0),.t_ack(1'b0),.t_rvalid(1'b0),.t_rdata(64'd0),
    .l3d_go(1'b0),.l3d_line(8'd0),.l3d_raddr(8'd0),
    .rg_wreq,.rg_wack(1'b1),.rg_rreq,.rg_rack(1'b0),.rg_rvalid(1'b0),
    .rg_rdata(32'd0),.rg_ready(1'b1),.rg_wdrained(1'b1));
  end
 end endgenerate
endmodule

module tb_ds_pocket;
 logic clk_sys=0,clk_2x=1,rst=1,run_clocks=1;
 always #10 if(run_clocks)clk_sys=~clk_sys;
 always #5 if(run_clocks)clk_2x=~clk_2x;
 logic[15:0]disp3dcnt=0;
 logic io_req=0,io_we=0,io_ack,rg_wreq,rg_rreq;
 logic[11:2]io_addr=0;
 logic[31:0]io_wdata=0;
 hg193_component_top dut(.*,.tick(1'b1));
 logic[31:0]backing[int];
 task automatic sd_poke32(input logic[23:0]address,input logic[31:0]data);
  assert(!run_clocks && !clk_sys && !clk_2x)else $fatal(1,"fixture backing write with running clock");
  backing[int'(address)]=data;
 endtask
 function automatic logic[31:0]sd_peek32(input logic[23:0]address);
  return backing.exists(int'(address))?backing[int'(address)]:32'hBAD0BAD0;
 endfunction
 `include "hg193_sd_pair.svh"
 `define C_GPU dut.ds.g_3d.u_gpu3d
 `define C_FIN `C_GPU.u_geom.u_eng.g_fu.u_fin
 `include "component_snapshot_fixture.svh"
 task automatic ordinary_io_write(input logic[11:0]address,input logic[31:0]data);
  @(negedge clk_sys);io_req=1;io_we=1;io_addr=address[11:2];io_wdata=data;
  @(negedge clk_sys);assert(io_ack)else $fatal(1,"ordinary GPU IO replay not acknowledged");
  io_req=0;io_we=0;
 endtask
 logic[63:0]signature;
 task automatic mix(input logic[63:0]word_value);
  signature=(signature^word_value)*64'h100000001b3;
 endtask
 task automatic fingerprint;
  signature=64'hcbf29ce484222325;
  `include "component_before_fingerprint.svh"
  $display("HG193_DEFAULT_BEFORE signature=%016x",signature);
 endtask
 string directory,kind="valid";
 logic[31:0]current[0:5];
 logic[31:0]saved_inactive[0:95];
 int saved_backing_size;
 initial begin
  assert($value$plusargs("payload=%s",directory))else $fatal(1,"missing prepared payload");
  if($value$plusargs("case=%s",kind))begin end
  $readmemh({directory,"/current_regs.hex"},current);
  repeat(20)@(negedge clk_sys);rst=0;
  repeat(3500)@(negedge clk_sys);
  disp3dcnt=16'(current[0]);
  ordinary_io_write('h340,current[1]);ordinary_io_write('h350,current[2]);
  ordinary_io_write('h354,current[3]);ordinary_io_write('h358,current[4]);
  ordinary_io_write('h35c,current[5]);
  repeat(20)@(negedge clk_sys);
  // The empty dispatcher alternates DISP and its NOENT/MREQ loop. Hold a
  // real idle phase; a fixed arbitrary cycle is not a drained boundary.
  @(negedge clk_2x);
  while(clk_sys || !`C_GPU.u_geom.u_eng.idle || `C_GPU.u_geom.u_eng.rf_we)
   @(negedge clk_2x);
  run_clocks=0;
  #1;assert(!clk_sys && !clk_2x && !run_clocks && !io_req && !rg_wreq && !rg_rreq)
   else $fatal(1,"fixture did not hold/drain all connected external ports");
  initialize_snapshot_fixture();
  // Component input fixture: the accepted boundary has an empty current
  // writer sort epoch. Cold physical RAM alone has no invalid-tag promise.
  // Use distinct invalid entries and verify that publication preserves them.
  for(int i=0;i<512;i++)begin
   `C_GPU.u_geom.u_eng.g_sort.u_bl.mem[i]={!`C_GPU.u_geom.u_eng.g_sort.stag,11'(i^'h2a5)};
   `C_GPU.u_geom.u_eng.g_sort.u_ct.mem[i]={!`C_GPU.u_geom.u_eng.g_sort.stag,12'(i^'h5a5)};
  end
  save_inactive_snapshot_fixture(saved_inactive);
  saved_backing_size=backing.num();
  fingerprint();
  if(kind=="default")begin
   #100;fingerprint();
   assert(backing.num()==saved_backing_size)else $fatal(1,"default import backing changed");
   $display("HG193_DEFAULT_NO_IMPORT_PASS");$finish;
  end else begin
`ifdef HG193_SD_PAIR_OPT_IN
  if(kind=="owner")`C_GPU.g_ext.g_pair.u_store.u_journal.sealed=2'b01;
  hg193_publish(directory,kind!="held" && !run_clocks,
                !io_req && !rg_wreq && !rg_rreq);
  assert(kind=="valid")else $fatal(1,"negative publication control survived");
  verify_inactive_snapshot_fixture(saved_inactive);
  assert(hg193_applied && !run_clocks && !clk_sys && !clk_2x && backing.num()==131072)
   else $fatal(1,"publication incomplete or clocks advanced");
  #100;hg193_verify_publication();verify_inactive_snapshot_fixture(saved_inactive);
  $display("HG193_PUBLICATION_HELD_DRAINED_PASS words131072 context3712 preserved32plus64");
  $finish;
`else
  $fatal(1,"fixture has no adapter enabled");
`endif
  end
 end
 initial begin #1000000;$fatal(1,"publication component timeout");end
endmodule
