#!/usr/bin/env python3
"""Optional GX pair: UNQUALIFIED; last executed wiring timed out with no outcomes.

The corrected wiring below has NOT been rerun. Use composition.py for the
qualified source/phase gate; never interpret the retained actor run as PASS.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import time

ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--before',default='a9465f58a8a6a633655434b5285b60fb1fbf7095');a=p.parse_args()
os.nice(10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
pid=os.getpid();print('ROM_COUPLED_PID',pid,'NI10/j1/t1',flush=True)
status=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json')
def phase(s,active=1):
    r=json.loads(status.read_text());r.update(phase=s,lease='D3 soleNI10/j1/t1 ROM prototype worker',worker=dict(host='Desktop',active=active,controller_pid=pid,starttime=Path('/proc/self/stat').read_text().rsplit(')',1)[1].split()[19],nice=10,jobs=1,threads=1),updated_at=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()));b=(json.dumps(r,indent=2)+'\n').encode();assert len(b)<2048;q=status.with_suffix('.tmp.geometry');q.write_bytes(b);q.replace(status)
oldfiles=[];old_hashes={}
for leaf in ['gxeng','geom']:
    path=f'rtl/gpu3d/gpu3d_{leaf}.sv';b=subprocess.check_output(['git','show',a.before+':'+path],cwd=ROOT);old_hashes[path]=hashlib.sha256(b).hexdigest();s=b.decode()
    if leaf=='gxeng':
        tail=s.split('endmodule',1)[1];assert tail==(ROOT/path).read_text().split('endmodule',1)[1]
        s=s.split('endmodule',1)[0]+'endmodule\n'
    for n in ['gpu3d_gxeng','gpu3d_geom']:s=s.replace(n,n+'_before')
    f=out/f'before_{leaf}.sv';f.write_text(s);oldfiles.append(f)
outputs={'io_rdata':32,'io_ack':1,'io_wait':1,'irq_gxfifo':1,'dma_gx_low':1,'gx_stall':1,'ovf_set':1,'po_valid':1,'po_type':1,'po_data':128,'po_index':11,'po_wv':1,'po_wk':2,'po_wd':32,'so_we':1,'so_pos':11,'so_idx':11,'so_done':1,'so_count':12,'dbg_stall':1,'dbg_apply':1,'dbg_upc':11,'dbg_flush':1,'dbg_idle':1,'dbg_gxstat':32,'dbg_npoly':12,'dbg_nvert':13,'diag_ev':3,'diag_used':13,'dbg_eq_bad':1}
ins='clk,clk_2x,rst,tick,vblank,io_req,io_we,io_addr,io_wdata,po_ready,s_draw'.split(',')
top=['''module tb_coupled_pump(input logic clk,clk_2x,rst,tick,vblank,io_req,io_we,po_ready,s_draw,input logic [7:0] io_addr,input logic [31:0] io_wdata,
output logic io_wait,io_ack,dbg_flush,dbg_idle,po_valid,po_type,output logic [31:0] io_rdata,
output logic [31:0] outcomes,late_clocks,clip_starts,fin_starts,rf_writes,headers,vertices,irq_clocks,dma_clocks,held_beats,
output logic [10:0] diag_pc, output logic [31:0] diag_status, output logic [12:0] diag_occ, output logic [18:0] diag_head);
''']
top.append('wire [20:0] io_pre; gpu3d_gxpre u_pre(.d(io_wdata),.pre(io_pre));')
params=".FF(1'b1),.LUNIT(1'b1),.VFIN(2),.USORT(1'b1),.GX_DSX(1'b1),.GX_SWAP_OVERLAP(1'b1),.GX_L44_READ(1'b1),.GX_DIV_P2X(1'b1),.GX_MAT_PAR(1'b1),.GX_PRE(1'b1),.DIV_P2X(1'b0),.SPILL(1'b1),.GATH16(1'b1),.SP_ON(4096),.SP_AW(18),.SP_SIM(1'b1)"
for tag,module in [('a','gpu3d_geom_before'),('b','gpu3d_geom')]:
    for n,w in outputs.items():top.append(f'wire [{w-1}:0] {n}_{tag};')
    con=[f'.{n}({n})'for n in ins]+[f'.{n}({n}_{tag})'for n in outputs]+[".geom_en(1'b1)",".io_be(4'hF)",".io_wpre(io_pre)",".sp_wack(1'b0)",".sp_wdrained(1'b1)",".sp_rack(1'b0)",".sp_rvalid(1'b0)",".sp_rdata(32'd0)"]
    bound_params=params if tag=='a' else params+",.GX_ROM_DICT(1'b1)"
    top.append(f'{module} #({bound_params}) {tag}('+','.join(con)+');')
for n in ['io_wait','io_ack','dbg_flush','dbg_idle','po_valid','po_type','io_rdata']:top.append(f'assign {n}={n}_a;')
top.append('assign diag_pc=dbg_upc_a;assign diag_status=dbg_gxstat_a;assign diag_occ=diag_used_a;assign diag_head={a.e_avail,a.dp,a.mx};')
top.append('always @(negedge clk) if(!rst) begin')
for n in outputs:
    gate='1'
    if n=='io_rdata':gate='io_ack_a && !io_we'
    if n in ['po_type','po_data','po_index']:gate='po_valid_a'
    if n in ['po_wk','po_wd']:gate='po_wv_a'
    if n in ['so_pos','so_idx']:gate='so_we_a'
    if n=='so_count':gate='so_done_a'
    top.append(f'if({gate} && {n}_a!=={n}_b) $fatal(1,"coupled {n} mismatch");')
for n in ['oc_valid','engine_ovf','load44_tail']:top.append(f'if(a.{n}!==b.{n}) $fatal(1,"coupled {n} mismatch");')
for n in ['oc_rej','oc_quad','oc_side','oc_nv','oc_ncl']:top.append(f'if(a.oc_valid&&a.{n}!==b.{n}) $fatal(1,"coupled outcome {n} mismatch");')
top.append('''if(a.u_front.stand!==b.u_front.stand) $fatal(1,"coupled physical late outcome mismatch");
if(a.u_eng.rf_we!==b.u_eng.rf_we || a.u_eng.rf_we && (a.u_eng.rf_wa!==b.u_eng.rf_wa || a.u_eng.rf_wd!==b.u_eng.rf_wd)) $fatal(1,"coupled RF state/order mismatch");
end
logic valid=0; logic [10:0] pc_M;
always @(posedge clk_2x) if(!clk) pc_M<=a.u_eng.upc_n;
always @(posedge clk) begin valid<=1; if(!rst && pc_M!==a.u_eng.upc_n) $fatal(1,"actual nextPC changed M-to-E"); end
always @(negedge clk_2x) if(valid && a.u_eng.ua!==b.u_eng.ua) $fatal(1,"coupled full A-word edge/hold/reset mismatch");
always @(posedge clk) if(rst) begin
outcomes<=0;late_clocks<=0;clip_starts<=0;fin_starts<=0;rf_writes<=0;headers<=0;vertices<=0;irq_clocks<=0;dma_clocks<=0;held_beats<=0;
end else begin
outcomes<=outcomes+32'(a.oc_valid);late_clocks<=late_clocks+32'(a.u_front.stand);
clip_starts<=clip_starts+32'(a.u_eng.g_cl.u_clip.dgo);fin_starts<=fin_starts+32'(a.u_eng.g_fu.u_fin.dstart);
rf_writes<=rf_writes+32'(a.u_eng.rf_we);headers<=headers+32'(po_valid_a&&po_ready&&!po_type_a);vertices<=vertices+32'(po_valid_a&&po_ready&&po_type_a);
irq_clocks<=irq_clocks+32'(irq_gxfifo_a);dma_clocks<=dma_clocks+32'(dma_gx_low_a);held_beats<=held_beats+32'(po_valid_a&&!po_ready);
end
endmodule
''')
w=out/'wrapper.sv';w.write_text('\n'.join(top)+'\n')
files=[ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv',ROOT/'rtl/gpu3d/gpu3d_ram.sv']+sorted((ROOT/'rtl/gpu3d').glob('gpu3d_gxrom*.sv'))+[ROOT/f'rtl/gpu3d/gpu3d_{n}.sv'for n in ['gxlight','gxvfin','gxdiv','gxfront','gxeng','gxsort','geom']]
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_coupled_pump','--Mdir',str(out/'obj'),'-MAKEFLAGS','VM_PARALLEL_BUILDS=0','-CFLAGS','-std=c++20 -O1']+list(map(str,files+oldfiles+[w,ROOT/'sim/gpu3d/rom_dictionary/coupled.cpp']))
phase('ROM65 actual combined GX before/after Verilator build')
with(out/'build.log').open('w')as log:r=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
assert r.returncode==0,'coupled build failed'
print('COUPLED_BUILD_PASS',flush=True);phase('ROM65 actual combined GX cycle/state/order equivalence')
with(out/'run.log').open('w')as log:r=subprocess.run([str(out/'obj/Vtb_coupled_pump')],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
log=(out/'run.log').read_text();print(log,flush=True)
rec=dict(before=a.before,exit=r.returncode,command=cmd,old_source_hashes=old_hashes,source_hashes={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in files},output=log,scope='All public qualified outputs/IRQ/DMA/GXSTAT/stalls, outcome payloads/physical lateness, RF writes/order and everyA-word E/M edge; actual livePC hold guard; full4096-entry cache and existing SP_SIM variable-latency SDRAM test fixture on both sides, not a native model')
(out/'receipt.json').write_text(json.dumps(rec,indent=2)+'\n');phase('ROM65 coupled terminal rc='+str(r.returncode),0)
raise SystemExit(r.returncode)
