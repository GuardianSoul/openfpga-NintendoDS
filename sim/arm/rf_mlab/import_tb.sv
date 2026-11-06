`timescale 1ns/1ps
module import_tb;
  logic clk=0,rst=1,ce=1;
  always #5 clk=~clk;
  arm_core #(.A9_SOLO(1),.SOLO_ONLY(1),.SLOW(1),.A9_OPT(461366243)) core(
    .clk,.rst,.ce,.run(2'b00),.reset_pc0(32'h02000000),.reset_pc1(32'd0),
    .hivecs(2'b0),.irq(2'b0),.fiq(2'b0),.halt_req(2'b0),.wake(2'b0),
    .i_rdata(32'd0),.i_ok(1'b1),.i_abort(1'b0),.d_rdata(32'd0),
    .d_ok(1'b1),.d_abort(1'b0),.io_replay_owned(1'b0),.d_wait(2'b0));
  `define RUNTIME_CORE core
  `include "sim/pocket_ds/runtime_import_cpu9_dual.svh"
  `undef RUNTIME_CORE
  logic [31:0] imported[0:31],psrs[0:7];
  initial begin
    repeat(8)@(negedge clk);ce=0;rst=0;
    for(int i=0;i<32;i++)imported[i]=32'hc90a0000+32'(i);
    psrs[0]=32'h02001000;psrs[1]=32'h200000d3;psrs[2]=0;
    for(int i=3;i<8;i++)psrs[i]=32'h80000013+32'(i);
    import_cpu9_dual(imported,psrs);#1;
    for(int i=0;i<31;i++)if(i!=15)begin
      assert(core.u_rf.g_dual.regs[i]==imported[i])else $fatal(1,"RF_HELPER_LOGICAL_IMPORT");
      assert(core.u_rf.g_dual.b0[i]==imported[i]&&core.u_rf.g_dual.b1[i]==imported[i]&&core.u_rf.g_dual.b2[i]==imported[i]&&
             core.u_rf.g_dual.c0[i]==imported[i]&&core.u_rf.g_dual.c1[i]==imported[i]&&core.u_rf.g_dual.c2[i]==imported[i])
        else $fatal(1,"RF_HELPER_REPLICA_IMPORT");
    end
    assert(core.fetch_pc[0]==psrs[0]&&core.fetch_pc[1]==psrs[0])else $fatal(1,"RF_HELPER_PC_IMPORT");
    assert(core.u_rf.g_dual.regs[15]==0&&core.u_rf.g_dual.regs[31]==0)else $fatal(1,"RF_HELPER_EXCLUDED_REGS");
    $display("RF_HELPER_IMPORT_PASS logical30 replicas180 stopped/drained CPU; read-only observer ABI preserved");$finish;
  end
endmodule
