#!/usr/bin/env python3
"""Pinned, read-only reference plus passive operand/public observer."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

R = Path(__file__).resolve().parents[3]
B = R / 'build/geometry-public-witness18'
PIN = 'f9d7a5fff7e6a3af1cb1c5d8588831160e7dd236'
B.mkdir(parents=True, exist_ok=True)
files = ['gpu3d_gxu_pkg.sv', 'gpu3d_ram.sv']
files += sorted(p.name for p in (R / 'rtl/gpu3d').glob('gpu3d_gxrom*.sv'))
files += [f'gpu3d_{n}.sv' for n in ('gxlight', 'gxdiv', 'gxfront', 'gxeng', 'gxsort', 'geom', 'gxvfin')]
hashes = {}
for name in files:
    data = subprocess.check_output(['git', 'show', f'{PIN}:rtl/gpu3d/{name}'], cwd=R)
    (B / name).write_bytes(data)
    hashes[name] = hashlib.sha256(data).hexdigest()

wrapper = r'''module tb_public_budget(
input logic clk,clk_2x,rst,tick,vblank,io_req,io_we,po_ready,observer_disconnect,
input logic [7:0] io_addr,input logic [31:0] io_wdata,input logic [31:0] case_id,
output wire io_wait,io_ack,dbg_flush,dbg_idle,frame_done,output wire [31:0] io_rdata,gxstat,
output wire [11:0] npoly,output wire [12:0] nvert);
import gpu3d_gxu_pkg::*;
wire irq_gxfifo,dma_gx_low,gx_stall,po_valid,po_type,so_we,so_done;
wire [127:0] po_data;
wire [10:0] po_index,so_pos,so_idx;
wire [12:0] used;
assign frame_done=so_done;
gpu3d_geom #(.FF(1),.LUNIT(1),.VFIN(2),.USORT(1),.GX_CHEAP(0),.GX_DSX(1),
 .GX_SWAP_OVERLAP(1),.GX_L44_READ(1),.GX_MAT_PAR(1),.GX_DIV_P2X(1),
 .GX_SCALAR_DIV_P2X(1),.GX_ROM_DICT(1),.ENG_M10K(0),.SPILL(1),.SP_SIM(1),
 .SP_ON(4096),.SP_AW(18)) dut(
 .clk,.clk_2x,.rst,.tick,.vblank,.io_req,.io_we,.io_addr,.io_wdata,.io_wait,.io_ack,.io_rdata,
 .geom_en(1'b1),.io_be(4'hf),.io_wpre(21'd0),.po_ready,.po_valid,.po_type,.po_data,.po_index,
 .s_draw(1'b0),.so_we,.so_done,.so_pos,.so_idx,.irq_gxfifo,.dma_gx_low,.gx_stall,
 .dbg_flush,.dbg_idle,.dbg_gxstat(gxstat),.dbg_npoly(npoly),.dbg_nvert(nvert),.diag_used(used),
 .sp_wack(1'b0),.sp_wdrained(1'b1),.sp_rack(1'b0),.sp_rvalid(1'b0),.sp_rdata(32'd0));
wire release_hook = observer_disconnect ? 1'b0 : dut.u_eng.g_cl.u_clip.seg_go;
// The hook can actually be disconnected at this binding. Independent raw
// dgo and qualified-consumer events remain connected, forcing a failed join.
geometry_operand_observer obs(.clk,.rst,.release_hook,
 .actual_release(dut.u_eng.g_cl.u_clip.seg_go),.case_id,
 .actual_start(dut.u_eng.g_cl.u_clip.dgo));
endmodule

module geometry_operand_observer(input logic clk,rst,release_hook,actual_release,actual_start,
input logic [31:0] case_id);
// Read-only hierarchical observation of the literal pinned reference.
`define D $root.tb_public_budget.dut
`define C `D.u_eng.g_cl.u_clip
`define F `D.u_front
longint unsigned cy=0,write_seq=0,engine_seq=0,model_seq=0;
integer clip_id=0,segment_id=0,starts=0,releases=0,raw_releases=0;
integer max_fifo=0,max_oq=0,max_used=0,late_clocks=0;
logic clipped=0;
logic [31:0] old_gx=0;logic [24:0] old_counts=0;
logic old_irq=0,old_dma=0,old_stall=0;
always @(posedge clk) begin
 cy=cy+1;
 if(!rst)begin
  if(integer'(`F.f)>max_fifo)max_fifo=integer'(`F.f);
  if(integer'(`F.oq_count)>max_oq)max_oq=integer'(`F.oq_count);
  if(integer'(`D.diag_used)>max_used)max_used=integer'(`D.diag_used);
  if(`F.stand)late_clocks=late_clocks+1;
  if(`D.io_req&&`D.io_we&&!`D.io_wait)begin
   write_seq=write_seq+1;
   $display("OBS,%0d,W,%0d,%0d,%02x,%08x",cy,case_id,write_seq,`D.io_addr,`D.io_wdata);
  end
  if(`D.e_pop)begin
   engine_seq=engine_seq+1;
   $display("OBS,%0d,E,%0d,%0d,%0d,%08x",cy,case_id,engine_seq,`D.u_eng.e_hidx,`D.u_eng.e_data);
  end
  if(`F.do_exec)begin
   model_seq=model_seq+1;
   $display("OBS,%0d,M,%0d,%0d,%0d,%0d,%0d,%0d,%0d",cy,case_id,model_seq,`F.hd.sub,$signed(`F.tm.cyc),`F.oq_count,`F.head_arrival,`F.ds_now);
  end
  if(`C.run&&`C.st==`C.S_IDLE&&!`C.done&&`C.can)begin
   clip_id=clip_id+1;clipped=1;
   $display("OBS,%0d,G,%0d,%0d,%0d,%0d,%0d,%0d,%0d",cy,case_id,clip_id,write_seq,engine_seq,model_seq,`F.f,$signed(`F.engine_lead));
  end
  if(actual_release)raw_releases=raw_releases+1;
  if(release_hook)begin
   segment_id=segment_id+1;releases=releases+1;
   $write("OBS,%0d,REL,%0d,%0d,%0d,%0d,%08x,%0d,%0d,%0d,%0d",cy,case_id,clip_id,segment_id,`C.comp,`C.seg_den,write_seq,engine_seq,model_seq,`F.f);
   for(integer i=0;i<9;i++)$write(",%016x",64'($signed(`C.seg_dv[i])*$signed(`C.seg_m[i])));
   $write("\n");
  end
  if(actual_start)begin
   starts=starts+1;
   $write("OBS,%0d,START,%0d,%0d,%0d,%0d",cy,case_id,clip_id,starts,`C.comp);
   for(integer i=0;i<9;i++)begin
    if(i<6)$write(",%016x",`C.g_input.u_bank.g_cohort.u_div.nfull[i]);
    else $write(",%016x",`C.g_input.u_bank.div_num[i]);
   end
   $write("\n");
  end
  if(`C.st==`C.S_DIV&&!`C.dgo&&!`C.dwait&&`C.dbusy==0&&`C.nk==9)begin
   $write("OBS,%0d,Q,%0d,%0d,%0d",cy,case_id,clip_id,starts);
   for(integer i=0;i<9;i++)$write(",%08x",`C.dq[i]);
   $write("\n");
  end
  if(`C.st==`C.S_FIN&&`C.k==13&&`C.qe)$display("OBS,%0d,CEND,%0d,%0d",cy,case_id,clip_id);
  if(`D.oc_valid)begin
   $display("OBS,%0d,O,%0d,%0d,%0d,%0d,%0d,%0d,%0d",cy,case_id,clipped?clip_id:0,`D.oc_rej,`D.oc_nv,`D.oc_ncl,$signed(`F.tm.cyc),`F.tm.pend);
   clipped=0;
  end
  if(`F.oq_take)$display("OBS,%0d,TAKE,%0d,%03x,%0d,%0d,%0d,%0d",cy,case_id,`F.oq_data,$signed(`F.tm.cyc),`F.f,`F.p,`F.tm.pend);
  if(`D.io_req&&!`D.io_we)$display("OBS,%0d,READ,%0d,%02x,%0d,%0d",cy,case_id,`D.io_addr,`D.model_npoly,`D.model_nvert);
  if(`D.io_ack&&!`D.io_we)$display("OBS,%0d,ACK,%0d,%02x,%08x",cy,case_id,`D.io_addr,`D.io_rdata);
  if(`D.po_valid&&`D.po_ready)$display("OBS,%0d,PO,%0d,%0d,%0d,%032x",cy,case_id,`D.po_index,`D.po_type,`D.po_data);
  if(`D.so_we)$display("OBS,%0d,SORT,%0d,%0d,%0d",cy,case_id,`D.so_pos,`D.so_idx);
  if(`D.so_done)$display("OBS,%0d,FRAME,%0d",cy,case_id);
  if(`D.dbg_gxstat!==old_gx||{`D.model_npoly,`D.model_nvert}!==old_counts||
    `D.irq_gxfifo!=old_irq||`D.dma_gx_low!=old_dma||`D.gx_stall!=old_stall)begin
   $display("OBS,%0d,P,%0d,%08x,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",cy,case_id,`D.dbg_gxstat,`D.model_npoly,`D.model_nvert,`D.irq_gxfifo,`D.dma_gx_low,`D.gx_stall,`D.diag_used,`F.oq_count,$signed(`F.tm.cyc),`F.tm.pend);
   old_gx=`D.dbg_gxstat;old_counts={`D.model_npoly,`D.model_nvert};
   old_irq=`D.irq_gxfifo;old_dma=`D.dma_gx_low;old_stall=`D.gx_stall;
  end
  if(`D.vblank)$display("OBS,%0d,VBLANK,%0d",cy,case_id);
 end
end
final $display("OBSFINAL,starts,%0d,releases,%0d,raw_releases,%0d,max_fifo,%0d,max_oq,%0d,max_used,%0d,late_clocks,%0d",starts,releases,raw_releases,max_fifo,max_oq,max_used,late_clocks);
`undef D
`undef C
`undef F
endmodule
'''
(B / 'observer.sv').write_text(wrapper)
(B / 'prepare.json').write_text(json.dumps({'reference': PIN, 'files': files, 'hashes': hashes,
                                          'explicit_parameters':dict(re.findall(r'\.(\w+)\((\d+)\)',wrapper.split('gpu3d_geom #(')[1].split(') dut(')[0])),
                                          'observer_sha256': hashlib.sha256(wrapper.encode()).hexdigest(),
                                          'production_edits': False}, indent=2) + '\n')
print('Pinned reference/observer prepared; no compiler launched')
