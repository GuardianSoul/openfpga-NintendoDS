`timescale 1ns/1ps
module tb_pipe_restore #(parameter bit CUT=1);
logic clk=0,clk_2x=1,rst=1,ce=1,tick=0;int resume_loads=0,resume_outputs=0,parent_consumers=0;int worker_loads[4],worker_loops[4];always #2 clk=~clk;always #1 clk_2x=~clk_2x;bit go=0;int variant=0;logic[1:0]done=0;logic[7:0]wdone=0;
logic[31:0]cfg[0:127],fifo[0:127],capture[0:7],meta[0:55];logic[159:0]rows[0:31];logic[1:0]tags[0:127];
 generate begin:refside
 old_sound #(
`ifdef OLD_PIPE_REFERENCE
 .WORKER_PIPE(1),
`endif
.EVENT_MODE(1),.EVENT_FAST(1),.EVENT_WORKERS(4),.MEM_QUAD(1),.TIMER_DIV(4)) dut(.clk,
`ifdef OLD_PIPE_REFERENCE
 .clk_2x,
`endif
.rst,.ce,.tick,.power(1'b1),.reg_req(1'b0),.reg_we(1'b0),.reg_size(2'd2),.reg_addr(9'd0),.reg_wdata(32'd0),.mem_ack(1'b0),.mem_rvalid(1'b0),.mem_rdata(32'd0),.worker_kick(1'b0),.worker_due_mask(18'd0),.worker_refresh_mask(18'd0));
 `define RUNTIME_SOUND $root.tb_pipe_restore.refside.dut
 `include "runtime_import_sound_storage.svh"
 `include "runtime_import_sound_parent_banks.svh"
 `undef RUNTIME_SOUND
 initial forever begin @(posedge go);import_sound_storage(cfg,rows,fifo,tags,capture,meta);import_sound_parent_banks(cfg,rows);done[0]=1;end
 end endgenerate
 generate begin:newside
 sound #(.WORKER_PIPE(1),.WORKER_CAPTURE_CUT(CUT),.EVENT_MODE(1),.EVENT_FAST(1),.EVENT_WORKERS(4),.MEM_QUAD(1),.TIMER_DIV(4)) dut(.clk,.clk_2x,.rst,.ce,.tick,.power(1'b1),.reg_req(1'b0),.reg_we(1'b0),.reg_size(2'd2),.reg_addr(9'd0),.reg_wdata(32'd0),.mem_ack(1'b0),.mem_rvalid(1'b0),.mem_rdata(32'd0),.worker_kick(1'b0),.worker_due_mask(18'd0),.worker_refresh_mask(18'd0));
 `define RUNTIME_SOUND $root.tb_pipe_restore.newside.dut
 `include "runtime_import_sound_storage.svh"
 `include "runtime_import_sound_parent_banks.svh"
 `undef RUNTIME_SOUND
 initial forever begin @(posedge go);import_sound_storage(cfg,rows,fifo,tags,capture,meta);
 import_sound_parent_banks(cfg,rows);
 done[1]=1;end
 end endgenerate
always @(posedge clk)if(ce && !rst && newside.dut.st==newside.dut.S_MIX)parent_consumers++;
wire warm_quiet=newside.dut.st==newside.dut.S_IDLE && newside.dut.workers_idle &&
    newside.dut.event_count==0 && !newside.dut.event_head_valid && !newside.dut.reg_req &&
    !newside.dut.event_write_queued && !newside.dut.event_write_due && newside.dut.event_outputs_pending==0 &&
    newside.dut.q_cnt==0 && newside.dut.fs==newside.dut.F_IDLE && !newside.dut.win && !newside.dut.lsv_q &&
    newside.dut.g_workers.response_count==0 && !newside.dut.g_workers.hold_valid;
genvar owner;
generate for(owner=0;owner<4;owner++)begin:owners
 begin:refside
 `define RUNTIME_SOUND $root.tb_pipe_restore.refside.dut.g_workers.lane[owner].engine
 `include "runtime_import_sound_storage.svh"
 `include "old_runtime_import_sound_owned.svh"
 `undef RUNTIME_SOUND
 initial forever begin @(posedge go);import_sound_storage(cfg,rows,fifo,tags,capture,meta);import_sound_owned_shadows(cfg,rows,meta);
 wdone[owner]=1;end
 end
 begin:newside
 `define RUNTIME_SOUND $root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine
 `include "runtime_import_sound_storage.svh"
 `ifdef STALE_HELPER
 `include "old_runtime_import_sound_owned.svh"
 `else
 `include "runtime_import_sound_owned.svh"
 `endif
 `undef RUNTIME_SOUND
 initial forever begin @(posedge go);import_sound_storage(cfg,rows,fifo,tags,capture,meta);
 if(owner==0 && (variant==2 || variant==3))begin
  wait((&done) && (&wdone[3:0]) && (&wdone[7:5]));
  if(variant==2)ce=1;
  if(variant==3)$root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.event_count=1;
 end
 import_sound_owned_shadows(cfg,rows,meta);
 if(variant==1 && owner==0)$root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[1].g_byte[0].u_bank.mem[2]^=8'h01;
 if(variant==4 && owner==0)$root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.loop_state[2][0]^=1'b1;
 wdone[4+owner]=1;end
 end
 initial begin
 wait(&wdone);#0.2;
 for(int slot=0;slot<4;slot++)begin
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[0].g_byte[0].u_bank.mem[slot]===cfg[0*32+4*slot+owner][0+:8])else $fatal(1,"worker config import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[0].g_byte[1].u_bank.mem[slot]===cfg[0*32+4*slot+owner][8+:8])else $fatal(1,"worker config import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[0].g_byte[2].u_bank.mem[slot]===cfg[0*32+4*slot+owner][16+:8])else $fatal(1,"worker config import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[0].g_byte[3].u_bank.mem[slot]===cfg[0*32+4*slot+owner][24+:8])else $fatal(1,"worker config import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[1].g_byte[0].u_bank.mem[slot]===cfg[1*32+4*slot+owner][0+:8])else $fatal(1,"worker config import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[1].g_byte[1].u_bank.mem[slot]===cfg[1*32+4*slot+owner][8+:8])else $fatal(1,"worker config import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[1].g_byte[2].u_bank.mem[slot]===cfg[1*32+4*slot+owner][16+:8])else $fatal(1,"worker config import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[1].g_byte[3].u_bank.mem[slot]===cfg[1*32+4*slot+owner][24+:8])else $fatal(1,"worker config import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[2].g_byte[0].u_bank.mem[slot]===cfg[2*32+4*slot+owner][0+:8])else $fatal(1,"worker config import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[2].g_byte[1].u_bank.mem[slot]===cfg[2*32+4*slot+owner][8+:8])else $fatal(1,"worker config import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[2].g_byte[2].u_bank.mem[slot]===cfg[2*32+4*slot+owner][16+:8])else $fatal(1,"worker config import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[2].g_byte[3].u_bank.mem[slot]===cfg[2*32+4*slot+owner][24+:8])else $fatal(1,"worker config import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[3].g_byte[0].u_bank.mem[slot]===cfg[3*32+4*slot+owner][0+:8])else $fatal(1,"worker config import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[3].g_byte[1].u_bank.mem[slot]===cfg[3*32+4*slot+owner][8+:8])else $fatal(1,"worker config import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[3].g_byte[2].u_bank.mem[slot]===cfg[3*32+4*slot+owner][16+:8])else $fatal(1,"worker config import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_config.g_word[3].g_byte[3].u_bank.mem[slot]===cfg[3*32+4*slot+owner][24+:8])else $fatal(1,"worker config import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[0].g_body.u_bank.mem[slot]===rows[4*slot+owner][0+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[1].g_body.u_bank.mem[slot]===rows[4*slot+owner][8+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[2].g_body.u_bank.mem[slot]===rows[4*slot+owner][16+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[3].g_body.u_bank.mem[slot]===rows[4*slot+owner][24+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[5].g_body.u_bank.mem[slot]===rows[4*slot+owner][40+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[6].g_body.u_bank.mem[slot]===rows[4*slot+owner][48+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[7].g_body.u_bank.mem[slot]===rows[4*slot+owner][56+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[8].g_body.u_bank.mem[slot]===rows[4*slot+owner][64+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[9].g_body.u_bank.mem[slot]===rows[4*slot+owner][72+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[10].g_body.u_bank.mem[slot]===rows[4*slot+owner][80+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[11].g_body.u_bank.mem[slot]===rows[4*slot+owner][88+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[12].g_body.u_bank.mem[slot]===rows[4*slot+owner][96+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[13].g_body.u_bank.mem[slot]===rows[4*slot+owner][104+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[14].g_body.u_bank.mem[slot]===rows[4*slot+owner][112+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[15].g_body.u_bank.mem[slot]===rows[4*slot+owner][120+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[16].g_body.u_bank.mem[slot]===rows[4*slot+owner][128+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.g_byte[17].g_body.u_bank.mem[slot]===rows[4*slot+owner][136+:8])else $fatal(1,"worker body import byte mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.g_owned_runtime.loop_state[slot]==={rows[4*slot+owner][159:144],rows[4*slot+owner][39:32]})else $fatal(1,"worker loop import mismatch");
  assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.event_left[slot]===28'(meta[8+4*slot+owner])&&$root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.event_right[slot]===28'(meta[24+4*slot+owner]))else $fatal(1,"composed worker contribution restore mismatch");
 end
 for(int a=0;a<128;a++)assert(32'($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.u_cpu.mem[a])===cfg[a])else $fatal(1,"composed worker full CPU mirror mismatch");
 assert($root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.worker_left===$root.tb_pipe_restore.refside.dut.g_workers.lane[owner].engine.worker_left&&$root.tb_pipe_restore.newside.dut.g_workers.lane[owner].engine.worker_right===$root.tb_pipe_restore.refside.dut.g_workers.lane[owner].engine.worker_right)else $fatal(1,"composed worker old/new sums mismatch");
 end
end endgenerate
always @(negedge clk)if((&done)&&(&wdone))begin
 assert({newside.dut.out_valid,newside.dut.out_l,newside.dut.out_r,newside.dut.dac_l,newside.dut.dac_r,newside.dut.st,newside.dut.ent,newside.dut.mem_req}===
        {refside.dut.out_valid,refside.dut.out_l,refside.dut.out_r,refside.dut.dac_l,refside.dut.dac_r,refside.dut.st,refside.dut.ent,refside.dut.mem_req})else $fatal(1,"restore resume output/control mismatch");
 if(ce && newside.dut.out_valid)resume_outputs++;
 if(ce && newside.dut.st==newside.dut.S_LOAD)begin
  resume_loads++;
  for(int w=0;w<4;w++)assert(newside.dut.config_row[w]===refside.dut.config_row[w])else $fatal(1,"restored load config mismatch");
  assert(newside.dut.runtime_row===refside.dut.runtime_row)else $fatal(1,"restored load runtime mismatch");
 end
end
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_config.g_word[0].g_byte[0].u_bank.mem[slot]===refside.dut.g_parent_config.g_word[0].g_byte[0].u_bank.mem[slot])else $fatal(1,"restored bank byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_config.g_word[0].g_byte[1].u_bank.mem[slot]===refside.dut.g_parent_config.g_word[0].g_byte[1].u_bank.mem[slot])else $fatal(1,"restored bank byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_config.g_word[0].g_byte[2].u_bank.mem[slot]===refside.dut.g_parent_config.g_word[0].g_byte[2].u_bank.mem[slot])else $fatal(1,"restored bank byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_config.g_word[0].g_byte[3].u_bank.mem[slot]===refside.dut.g_parent_config.g_word[0].g_byte[3].u_bank.mem[slot])else $fatal(1,"restored bank byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_config.g_word[1].g_byte[0].u_bank.mem[slot]===refside.dut.g_parent_config.g_word[1].g_byte[0].u_bank.mem[slot])else $fatal(1,"restored bank byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_config.g_word[1].g_byte[1].u_bank.mem[slot]===refside.dut.g_parent_config.g_word[1].g_byte[1].u_bank.mem[slot])else $fatal(1,"restored bank byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_config.g_word[1].g_byte[2].u_bank.mem[slot]===refside.dut.g_parent_config.g_word[1].g_byte[2].u_bank.mem[slot])else $fatal(1,"restored bank byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_config.g_word[1].g_byte[3].u_bank.mem[slot]===refside.dut.g_parent_config.g_word[1].g_byte[3].u_bank.mem[slot])else $fatal(1,"restored bank byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_config.g_word[2].g_byte[0].u_bank.mem[slot]===refside.dut.g_parent_config.g_word[2].g_byte[0].u_bank.mem[slot])else $fatal(1,"restored bank byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_config.g_word[2].g_byte[1].u_bank.mem[slot]===refside.dut.g_parent_config.g_word[2].g_byte[1].u_bank.mem[slot])else $fatal(1,"restored bank byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_config.g_word[2].g_byte[2].u_bank.mem[slot]===refside.dut.g_parent_config.g_word[2].g_byte[2].u_bank.mem[slot])else $fatal(1,"restored bank byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_config.g_word[2].g_byte[3].u_bank.mem[slot]===refside.dut.g_parent_config.g_word[2].g_byte[3].u_bank.mem[slot])else $fatal(1,"restored bank byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_config.g_word[3].g_byte[0].u_bank.mem[slot]===refside.dut.g_parent_config.g_word[3].g_byte[0].u_bank.mem[slot])else $fatal(1,"restored bank byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_config.g_word[3].g_byte[1].u_bank.mem[slot]===refside.dut.g_parent_config.g_word[3].g_byte[1].u_bank.mem[slot])else $fatal(1,"restored bank byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_config.g_word[3].g_byte[2].u_bank.mem[slot]===refside.dut.g_parent_config.g_word[3].g_byte[2].u_bank.mem[slot])else $fatal(1,"restored bank byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_config.g_word[3].g_byte[3].u_bank.mem[slot]===refside.dut.g_parent_config.g_word[3].g_byte[3].u_bank.mem[slot])else $fatal(1,"restored bank byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[0].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[0].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[1].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[1].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[2].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[2].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[3].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[3].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[4].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[4].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[5].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[5].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[6].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[6].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[7].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[7].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[8].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[8].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[9].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[9].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[10].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[10].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[11].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[11].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[12].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[12].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[13].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[13].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[14].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[14].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[15].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[15].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[16].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[16].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[17].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[17].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[18].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[18].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");
always @(negedge clk)if(&done)for(int slot=0;slot<4;slot++)assert(newside.dut.g_parent_runtime.g_byte[19].u_bank.mem[slot]===refside.dut.g_parent_runtime.g_byte[19].u_bank.mem[slot])else $fatal(1,"restored runtime byte mismatch");

 genvar k; generate for(k=0;k<4;k++)begin:resume_worker
 always @(negedge clk)if((&done)&&(&wdone))begin
  assert({$root.tb_pipe_restore.newside.dut.g_workers.lane[k].engine.st,$root.tb_pipe_restore.newside.dut.g_workers.lane[k].engine.ent,$root.tb_pipe_restore.newside.dut.g_workers.lane[k].engine.cnt,$root.tb_pipe_restore.newside.dut.g_workers.lane[k].engine.event_pop,$root.tb_pipe_restore.newside.dut.g_workers.lane[k].engine.event_count,$root.tb_pipe_restore.newside.dut.g_workers.lane[k].engine.q_cnt,$root.tb_pipe_restore.newside.dut.g_workers.lane[k].engine.fs,$root.tb_pipe_restore.newside.dut.g_workers.lane[k].engine.worker_left,$root.tb_pipe_restore.newside.dut.g_workers.lane[k].engine.worker_right,$root.tb_pipe_restore.newside.dut.g_workers.lane[k].engine.worker_sample1,$root.tb_pipe_restore.newside.dut.g_workers.lane[k].engine.worker_sample3} ===
         {$root.tb_pipe_restore.refside.dut.g_workers.lane[k].engine.st,$root.tb_pipe_restore.refside.dut.g_workers.lane[k].engine.ent,$root.tb_pipe_restore.refside.dut.g_workers.lane[k].engine.cnt,$root.tb_pipe_restore.refside.dut.g_workers.lane[k].engine.event_pop,$root.tb_pipe_restore.refside.dut.g_workers.lane[k].engine.event_count,$root.tb_pipe_restore.refside.dut.g_workers.lane[k].engine.q_cnt,$root.tb_pipe_restore.refside.dut.g_workers.lane[k].engine.fs,$root.tb_pipe_restore.refside.dut.g_workers.lane[k].engine.worker_left,$root.tb_pipe_restore.refside.dut.g_workers.lane[k].engine.worker_right,$root.tb_pipe_restore.refside.dut.g_workers.lane[k].engine.worker_sample1,$root.tb_pipe_restore.refside.dut.g_workers.lane[k].engine.worker_sample3})else $fatal(1,"worker restore resume edge/output mismatch");
  if(ce && $root.tb_pipe_restore.newside.dut.g_workers.lane[k].engine.st==$root.tb_pipe_restore.newside.dut.g_workers.lane[k].engine.S_LOAD)begin
   worker_loads[k]++;
   for(int w=0;w<4;w++)assert($root.tb_pipe_restore.newside.dut.g_workers.lane[k].engine.config_row[w]===$root.tb_pipe_restore.refside.dut.g_workers.lane[k].engine.config_row[w])else $fatal(1,"worker restored load config mismatch");
   assert($root.tb_pipe_restore.newside.dut.g_workers.lane[k].engine.runtime_row===$root.tb_pipe_restore.refside.dut.g_workers.lane[k].engine.runtime_row)else $fatal(1,"worker restored load runtime mismatch");
  end
 end
 final $display("WORKER_RESTORE_LOADS owner%0d loads=%0d",k,worker_loads[k]);
end endgenerate
initial begin
 void'($value$plusargs("variant=%d",variant));
 for(int i=0;i<128;i++)begin cfg[i]=32'(i)*32'hfedcba9;fifo[i]=32'(i*29);tags[i]=2'(i);end
 for(int i=0;i<32;i++)rows[i]=160'(i)*160'h123456789abcdef;
 for(int i=0;i<8;i++)capture[i]=32'(i*31);
 for(int i=0;i<56;i++)meta[i]=32'(i)*32'hfedcba9;meta[0]=16'h8d7f;meta[2]=0;meta[3]=0;meta[4]=16'hff00;meta[5]=0;
 for(int ch=8;ch<16;ch++)begin cfg[ch]=32'he8000008 | 32'(ch*8<<16);cfg[64+ch]=32'h0001fff0;end
 repeat(4)@(negedge clk);rst=0;repeat(40)@(negedge clk);ce=0;
 if(variant==8)newside.dut.g_workers.lane[0].engine.event_output=1;
 if(variant==9)newside.dut.g_workers.lane[2].engine.st=newside.dut.g_workers.lane[2].engine.S_CAP;
 if(variant==10)begin newside.dut.g_workers.lane[3].engine.q_cnt=1;newside.dut.g_workers.lane[3].engine.fs=newside.dut.g_workers.lane[3].engine.F_HEAD;end
 if(variant==11)newside.dut.g_workers.lane[1].engine.event_mask=18'h10000;
 if(variant==5)newside.dut.selpass=1;
 if(variant==6)newside.dut.st=newside.dut.S_ITA;
 if(variant==7)begin newside.dut.q_cnt=1;newside.dut.fs=newside.dut.F_HEAD;end
 assert(!newside.dut.g_workers.g_pipe.group.pipe.d0 && !newside.dut.g_workers.g_pipe.group.pipe.d1 &&
        !newside.dut.g_workers.g_pipe.group.pipe.w0 && !newside.dut.g_workers.g_pipe.group.pipe.w1)
     else $fatal(1,"private pipeline not empty before paused import");
 go=1;wait((&done) && (&wdone));#0.1;
 for(int ch=8;ch<16;ch++)begin
  refside.dut.g_event_timers.bank.reload[ch]=16'hfff0;refside.dut.g_event_timers.bank.timer[ch]=16'hfff0;
  newside.dut.g_event_timers.bank.reload[ch]=16'hfff0;newside.dut.g_event_timers.bank.timer[ch]=16'hfff0;
 end
 for(int a=0;a<128;a++)assert(32'($root.tb_pipe_restore.newside.dut.u_cpu.mem[a])===cfg[a]&&32'($root.tb_pipe_restore.refside.dut.u_cpu.mem[a])===cfg[a])else $fatal(1,"parent full CPU bank mismatch");
 for(int a=0;a<32;a++)assert(160'($root.tb_pipe_restore.newside.dut.u_run.mem[a])===rows[a]&&160'($root.tb_pipe_restore.refside.dut.u_run.mem[a])===rows[a])else $fatal(1,"parent full runtime bank mismatch");
 assert({newside.dut.runtime_sample1,newside.dut.runtime_sample3}==={refside.dut.runtime_sample1,refside.dut.runtime_sample3})else $fatal(1,"restored fixed tap mismatch");
 #0.2;
 // Resume from imported state without a priming clock. Normal lead reads only.
 @(negedge clk);ce=1;
 repeat(20000)begin @(negedge clk);tick=($time%8192)==0;end
 for(int j=0;j<4;j++)assert(worker_loads[j]>0)else $fatal(1,"worker restore load coverage missing");
 assert(resume_loads>0 && resume_outputs>0)else $fatal(1,"restore resume coverage missing");
 $display("RESTORE_RESUME_COUNTS loads=%0d outputs=%0d",resume_loads,resume_outputs);
 $display("WORKER_BANK_RESTORE_PASS layout1_all4_bodybanks_liveFF_stopped_mirrors_resume20000");
 // Reimport after real traffic with stale private return caches present.
 // The existing quiescent caller contract is the only gate. No cache state
 // is reset/deposited, and there is no enabled priming edge after import.
 begin : warm_reimport
  int polls=0;
  while(!warm_quiet && polls<4096)begin @(negedge clk);polls++;end
  assert(warm_quiet)else $fatal(1,"warm import never reached original quiescent contract");
  ce=0;
  assert(newside.dut.g_workers.g_pipe.group.wb_valid[4] && parent_consumers>0)
      else $fatal(1,"warm test missed actual parent fifth-client cached result");
  assert(!newside.dut.g_workers.g_pipe.group.pipe.d0 && !newside.dut.g_workers.g_pipe.group.pipe.d1 &&
         !newside.dut.g_workers.g_pipe.group.pipe.w0 && !newside.dut.g_workers.g_pipe.group.pipe.w1)
      else $fatal(1,"logical quiescence left live private job");
  go=0;done=0;wdone=0;
  for(int ch=0;ch<16;ch++)begin
   cfg[ch]^=32'h00010009;rows[ch][31:16]^=16'h2222;rows[ch][135:120]^=16'h1357;
  end
  for(int n=0;n<128;n++)begin fifo[n]^=32'hdeadbeef;tags[n]^=2'b11;end
  #0.1;go=1;wait((&done) && (&wdone));#0.1;
  @(negedge clk);ce=1;
  repeat(20000)begin @(negedge clk);tick=($time%8192)==0;end
  $display("PIPE_WARM_REIMPORT_PASS no_private_reset_no_priming changed_data_and_tags parent_consumers=%0d",parent_consumers);
 end

 // A joint reset while an actual weighted job is in flight must not leak a
 // pre-reset context into the retained logical public owners.
 while(!((newside.dut.g_workers.g_pipe.group.pipe.w0 && newside.dut.g_workers.g_pipe.group.pipe.wt0[23:21]==3'd4) ||
         (newside.dut.g_workers.g_pipe.group.pipe.w1 && newside.dut.g_workers.g_pipe.group.pipe.wt1[23:21]==3'd4)))begin
  @(negedge clk);tick=($time%8192)==0;
 end
 $display("PARENT_PIPE_INFLIGHT_RESET_ARMED w0=%0d w1=%0d",newside.dut.g_workers.g_pipe.group.pipe.w0,newside.dut.g_workers.g_pipe.group.pipe.w1);
 rst=1;repeat(4)@(negedge clk);rst=0;
 repeat(2048)begin @(negedge clk);tick=($time%8192)==0;end
 $display("PARENT_PIPE_RESTORE_INFLIGHT_RESET_PASS");$finish;
end
initial begin #250000;$fatal(1,"timeout");end
endmodule
