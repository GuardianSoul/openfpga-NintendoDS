`include "predicate.svh"
module tb_predicate;
 import hg193_bootstrap_reads::*;
 view_t observed_shape,v,saved;
 int tests=0,forbidden=0;
 task automatic reject(input view_t bad);
  assert(!permit(0,1,bad))else $fatal(1,"forbidden actual predicate input accepted");
  assert(!permit(0,0,bad));tests++;forbidden++;
 endtask
 initial begin
  assert(!PROPOSAL_DEFAULT_ENABLE);
  observed_shape='0;
  observed_shape.held=1;observed_shape.phase_original=1;
  observed_shape.stub_bytes_match=1;observed_shape.owner_snapshot_complete=1;
  observed_shape.ctrl='h56078;observed_shape.fetch_pc='h023091c0;
  observed_shape.i_req=1;observed_shape.i_addr='h023091c0;
  observed_shape.w_req=1;observed_shape.w_addr='h04000130;
  observed_shape.dp_v=1;observed_shape.dp_read=1;observed_shape.dp_a='h04000130;
  observed_shape.ip_v=1;observed_shape.ip_a='h023091c0;
  observed_shape.b_req=1;observed_shape.b_addr='h023091c0;observed_shape.state=3;
  observed_shape.ibuf_v=1;observed_shape.ibuf_a='h023091bc;
  // Owner witnesses below are fixture inputs, NOT values captured in HG.
  observed_shape.accepted='{valid:1,known:1,arm9:1,write:0,
      physical_class:1,address:32'h023091c0,data:0,owner_tag:16'h52a7};
  observed_shape.completed='{valid:1,known:1,arm9:1,write:0,
      physical_class:2,address:32'h04000130,data:32'h3ff,owner_tag:16'h519c};
  for(int i=0;i<256;i++)begin
   v=observed_shape;v.accepted.owner_tag=16'(i);v.completed.owner_tag=16'(~i);
   v.completed.data=32'(i*32'h01010101);saved=v;
   assert(permit(0,1,v));assert(!permit(0,0,v));assert(v===saved);tests++;
   // Boolean refinement property: the original strict result is authoritative
   // for every view. This does not claim this active view was old-accepted.
   assert(permit(1,0,v)&&permit(1,1,v));tests++;
  end
  v=observed_shape;v.owner_snapshot_complete=0;reject(v);
  v=observed_shape;v.stub_bytes_match=0;reject(v);
  v=observed_shape;v.phase_original=0;reject(v);
  v=observed_shape;v.held=0;reject(v);
  v=observed_shape;v.ctrl|=32'h1005;reject(v);
  v=observed_shape;v.i_addr='h02000000;reject(v);
  v=observed_shape;v.fetch_pc='h02309224;reject(v);
  v=observed_shape;v.w_we=1;reject(v);
  v=observed_shape;v.d_req=1;v.d_addr='h04000130;v.d_we=1;reject(v);
  v=observed_shape;v.dp_read=0;reject(v);
  v=observed_shape;v.dp_a='h04000600;reject(v); //GX MMIO
  v=observed_shape;v.w_addr='h04000132;reject(v); //alias/other register
  v=observed_shape;v.b_we=1;reject(v);
  v=observed_shape;v.b_addr='h00680000;reject(v); //record/foreign namespace
  v=observed_shape;v.state=7;reject(v); //cache fill
  v=observed_shape;v.pending_write_or_maintenance=1;reject(v);
  v=observed_shape;v.accepted.known=0;reject(v);
  v=observed_shape;v.accepted.arm9=0;reject(v);
  v=observed_shape;v.accepted.write=1;reject(v);
  v=observed_shape;v.accepted.address^=4;reject(v);
  v=observed_shape;v.completed.address='h04000600;reject(v);
  v=observed_shape;v.completed.physical_class=3;reject(v);
  v=observed_shape;v.completed.known=0;reject(v);
  v=observed_shape;v.completed.arm9=0;reject(v);
  v=observed_shape;v.completed.write=1;reject(v);
  // A response sampled before release retains3ff after release. A later
  // separately accepted sample can contain0. Predicate never rewrites data.
  v=observed_shape;saved=v;assert(permit(0,1,v)&&v.completed.data=='h3ff);
  assert(v===saved);v.completed.data=0;assert(permit(0,1,v)&&v.completed.data==0);tests+=2;
  $display("BOOTSTRAP_READ_PREDICATE_PASS tests%0d forbidden%0d proposal_default_off old_strict_preserved",tests,forbidden);
  $finish;
 end
endmodule
