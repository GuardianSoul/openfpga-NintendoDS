#!/usr/bin/env python3
"""One measured-dependency head-admission prototype; no production-file write."""
from pathlib import Path
import hashlib,json,sys
import prepare_pressure

def main():
 B=Path(sys.argv[1]).resolve();saved=sys.argv;sys.argv=[saved[0],str(B),'--format','compressed4x4'];prepare_pressure.main();sys.argv=saved
 edits=[]
 def edit(name,old,new,count=1):
  p=B/name;s=p.read_text();assert s.count(old)==count,(name,old,s.count(old));p.write_text(s.replace(old,new));edits.append(dict(file=name,before=old,after=new,count=count))
 edit('gpu3d_raster.sv','    output logic         frame_done,','    output logic admission_tex_wait,admission_pal_wait,\n    output logic         frame_done,')
 edit('gpu3d_raster.sv',"    wire wait19   = p19_need && pq_n == '0;","    wire wait19   = p19_need && pq_n == '0;\n    assign admission_tex_wait=wait17;assign admission_pal_wait=wait19;")
 edit('cache.sv','    output logic          b_req,','    output logic b_head,\n    output logic          b_req,')
 edit('cache.sv','    assign b_req = r_v;',"    assign b_head=r_v && n!='0 && r_a==hb;\n    assign b_req = r_v;")
 edit('cone.sv','#(\n    parameter bit FRPOOL','#(\n    parameter bit HEAD_ADMIT=0,\n    parameter bit FRPOOL',2)
 edit('cone.sv',' input logic clk,clk_2x,rst,fg_now,',' input logic head_enable,output logic t_head,\n input logic clk,clk_2x,rst,fg_now,',2)
 edit('cone.sv','    logic frame_go,r_busy;', '    logic r_tex_wait,r_pal_wait;wire tc_head,pc_head;logic[8:0]admission_done;\n    always_ff @(posedge clk)if(rst||frame_go)admission_done<=0;else if(px_valid&&px_x==255)admission_done<={1\'b0,px_y}+9\'d1;\n    wire admission_due=HEAD_ADMIT&&head_enable&&!rst&&!frame_go&&!r_abort&&r_busy&&ring_due_valid&&admission_done<={1\'b0,ring_due_line}&&!(px_valid&&px_x==255&&px_y==ring_due_line);\n    logic frame_go,r_busy;',2)
 edit('cone.sv','.frame_done(frame_done),','.admission_tex_wait(r_tex_wait),.admission_pal_wait(r_pal_wait),.frame_done(frame_done),',2)
 edit('cone.sv',".flush(vram_wr), .pf_v(tpf_v), .pf_a(tpf_a),", ".flush(vram_wr), .pf_v(tpf_v), .pf_a(tpf_a),.b_head(tc_head),")
 edit('cone.sv',".pf_v(1'b0), .pf_a('0),", ".pf_v(1'b0), .pf_a('0),.b_head(pc_head),")
 edit('cone.sv','end else begin : g_c1','end else begin : g_c1\n        assign tc_head=0;assign pc_head=0;')
 edit('cone.sv',"wire  t_pick = tc_req ? 1'b0 : 1'b1;","wire  t_pick = admission_due&&r_pal_wait&&pc_head ? 1'b1 : tc_req ? 1'b0 : 1'b1;\n    assign t_head=admission_due&&t_req&&(t_pick ? r_pal_wait&&pc_head : r_tex_wait&&tc_head);")
 edit('cone.sv','    wire fp_hold=0;','    assign t_head=0;\n    wire fp_hold=0;')
 edit('nds_blk_arb.sv','    import gpu2d_pkg::*;\n(','    import gpu2d_pkg::*;\n#(parameter bit HEAD_ADMIT=0)\n(')
 edit('nds_blk_arb.sv','    input  logic clk,','    input logic head_enable,a_hurry,b_need,\n    input  logic clk,')
 edit('nds_blk_arb.sv','    wire pick_b = !a_req;','    logic credit;\n    wire borrow=HEAD_ADMIT&&head_enable&&a_req&&b_req&&b_need&&!a_hurry&&credit;\n    wire pick_b = !a_req||borrow;\n    always_ff @(posedge clk)if(rst)credit<=1;else if(a_ack)credit<=1;else if(borrow&&b_ack)credit<=0;')
 edit('nds_blk_arb.sv','own[wp] <= pick_b ^ $test$plusargs("fault_block_owner");','own[wp] <= pick_b ^ ($test$plusargs("fault_block_owner") || (borrow && $test$plusargs("fault_borrow_owner")));')
 edit('tb.sv',' wire ps_line_req,',' wire head_enable=$test$plusargs("head_admit");wire t_head;\n wire ps_line_req,')
 edit('tb.sv',' render_cone #(.FRPOOL(1),',' render_cone #(.HEAD_ADMIT(1),.FRPOOL(1),')
 edit('tb.sv','  .clk,.clk_2x,.rst,.fg_now(ref_fg_now),','  .head_enable(1\'b0),.t_head(),.clk,.clk_2x,.rst,.fg_now(ref_fg_now),')
 edit('tb.sv',' nds_blk_arb arb(.clk,.rst,',' nds_blk_arb #(.HEAD_ADMIT(1))arb(.head_enable,.a_hurry(hurry2),.b_need(t_head),.clk,.rst,')
 edit('observe.svh','own=d_req?0:dut.t_pick?2:1;','own=d_ack?0:dut.t_pick?2:1;')
 edit('observe.svh','logic[20:0]pressure_last=', 'bit debt=0;integer borrows=0;\nlogic[20:0]pressure_last=')
 edit('observe.svh',' obs_sys++;',''' obs_sys++;
 // Independent lease check at the original accepted interfaces.
 if(rst)debt=0;
 else begin
  if(head_enable&&d_req&&t_ack)begin
   if(hurry2||debt||!t_head)$fatal(1,"HEAD_LEASE_BOUNDS");
   debt=1;borrows++;
   if(fd)$fdisplay(fd,"HEAD_BORROW,%0d,%0d,%0d,%h",obs_sys,generation,dut.t_pick,t_blk);
  end
  if(d_ack)debt=0;
 end
''')
 snap=json.loads((B/'source.json').read_text());snap['head_admission_prototype']=dict(default_off=True,plan='build/render-admission-e63/controller-plan.json',edits=edits,scope='Copied-DUT actual cache/raster/owner/admission edit only; no production activation/cost. Original native/pin controller unchanged.')
 snap['policy']='Original e63 services with explicitly recorded default-off head admission prototype; no native urgency change.'
 snap['files']={p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in B.iterdir()if p.is_file()and p.name!='source.json'}
 (B/'source.json').write_text(json.dumps(snap,indent=2)+'\n');print('prepared',B,'recorded edits',len(edits))
if __name__=='__main__':main()
