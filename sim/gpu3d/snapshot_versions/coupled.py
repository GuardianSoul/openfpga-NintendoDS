#!/usr/bin/env python3
"""Paired actual complete GX boundary; no CPU/native/emulator baseline."""
import argparse,hashlib,json,os,resource,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',required=True,type=Path);a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
print(f'worker_pid={os.getpid()} starttime={Path("/proc/self/stat").read_text().split()[21]} nice=10 jobs=1 threads=1',flush=True)
oldfiles=[]
for leaf in ['gxeng','geom','gxvfin']:
 path=f'rtl/gpu3d/gpu3d_{leaf}.sv';s=subprocess.check_output(['git','show','1effca28:'+path],cwd=ROOT,text=True)
 if leaf=='gxvfin':s=s[s.index('module gpu3d_gxfin\n'):]
 for n in ['gpu3d_gxeng','gpu3d_geom','gpu3d_gxfin','gpu3d_gxclip']:s=s.replace(n,n+'_before')
 f=out/f'before_{leaf}.sv';f.write_text(s);oldfiles.append(f)
outputs={'io_rdata':32,'io_ack':1,'io_wait':1,'irq_gxfifo':1,'dma_gx_low':1,'gx_stall':1,'ovf_set':1,'po_valid':1,'po_type':1,'po_data':128,'po_index':11,'po_wv':1,'po_wk':2,'po_wd':32,'so_we':1,'so_pos':11,'so_idx':11,'so_done':1,'so_count':12,'dbg_stall':1,'dbg_apply':1,'dbg_upc':11,'dbg_flush':1,'dbg_idle':1,'dbg_gxstat':32,'dbg_npoly':12,'dbg_nvert':13,'diag_ev':3,'diag_used':13,'dbg_eq_bad':1}
ins='clk,clk_2x,rst,tick,vblank,io_req,io_we,io_addr,io_wdata,po_ready'.split(',')
top=['''module tb_coupled_pump(input logic clk,clk_2x,rst,tick,vblank,io_req,io_we,po_ready,input logic [7:0] io_addr,input logic [31:0] io_wdata,
output logic io_wait,io_ack,dbg_flush,dbg_idle,po_valid,po_type,output logic [31:0] io_rdata,
output logic [31:0] outcomes,late_clocks,clip_starts,fin_starts,rf_writes,headers,vertices,irq_clocks,dma_clocks,held_beats);
''']
for suffix,module in [('a','gpu3d_geom_before'),('b','gpu3d_geom')]:
 for n,w in outputs.items():top.append(f'wire [{w-1}:0] {n}_{suffix};')
 params=".FF(1'b1),.LUNIT(1'b1),.VFIN(2),.USORT(1'b1),.GX_DSX(1'b1),.GX_SWAP_OVERLAP(1'b1),.GX_L44_READ(1'b1)"
 params+=",.GX_DIV_P2X(1'b1)"
 con=[f'.{n}({n})' for n in ins]+[f'.{n}({n}_{suffix})' for n in outputs]+[".geom_en(1'b1)",".io_be(4'hF)",".io_wpre(21'd0)",".s_draw(1'b0)",".sp_wack(1'b0)",".sp_wdrained(1'b1)",".sp_rack(1'b0)",".sp_rvalid(1'b0)",".sp_rdata(32'd0)"]
 top.append(f'{module} #({params}) {suffix}('+','.join(con)+');')
for n in ['io_wait','io_ack','dbg_flush','dbg_idle','po_valid','po_type','io_rdata']:top.append(f'assign {n}={n}_a;')
top.append('always @(negedge clk) if(!rst) begin')
for n in outputs:
 gate='1'
 if n=='io_rdata':gate='io_ack_a && !io_we'
 if n in ['po_type','po_data','po_index']:gate='po_valid_a'
 if n in ['po_wk','po_wd']:gate='po_wv_a'
 if n in ['so_pos','so_idx']:gate='so_we_a'
 if n=='so_count':gate='so_done_a'
 top.append(f'if({gate} && {n}_a!=={n}_b) $fatal(1,"coupled {n} mismatch");')
for n in ['oc_valid','engine_ovf','load44_tail']:
 top.append(f'if(a.{n}!==b.{n}) $fatal(1,"coupled {n} mismatch");')
for n in ['oc_rej','oc_quad','oc_side','oc_nv','oc_ncl']:
 top.append(f'if(a.oc_valid && a.{n}!==b.{n}) $fatal(1,"coupled outcome {n} mismatch");')
top.append('''if(a.u_front.stand!==b.u_front.stand) $fatal(1,"coupled physical late outcome mismatch");
if(a.u_eng.rf_we!==b.u_eng.rf_we || a.u_eng.rf_we && (a.u_eng.rf_wa!==b.u_eng.rf_wa || a.u_eng.rf_wd!==b.u_eng.rf_wd)) $fatal(1,"coupled RF state/order mismatch");
end
always @(posedge clk) if(rst) begin
outcomes<=0;late_clocks<=0;clip_starts<=0;fin_starts<=0;rf_writes<=0;headers<=0;vertices<=0;irq_clocks<=0;dma_clocks<=0;held_beats<=0;
end else begin
outcomes<=outcomes+32'(a.oc_valid);late_clocks<=late_clocks+32'(a.u_front.stand);
clip_starts<=clip_starts+32'(a.u_eng.g_cl.u_clip.dgo);
fin_starts<=fin_starts+32'(a.u_eng.g_fu.u_fin.dstart);
rf_writes<=rf_writes+32'(a.u_eng.rf_we);
headers<=headers+32'(po_valid_a&&po_ready&&!po_type_a);vertices<=vertices+32'(po_valid_a&&po_ready&&po_type_a);
irq_clocks<=irq_clocks+32'(irq_gxfifo_a);dma_clocks<=dma_clocks+32'(dma_gx_low_a);held_beats<=held_beats+32'(po_valid_a&&!po_ready);
end
endmodule
''')
(out/'wrapper.sv').write_text('\n'.join(top))
files=[ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv',ROOT/'rtl/gpu3d/gpu3d_ram.sv']+sorted((ROOT/'rtl/gpu3d').glob('gpu3d_gxrom*.sv'))+[ROOT/f'rtl/gpu3d/gpu3d_{n}.sv' for n in ['gxlight','gxvfin','gxdiv','gxfront','gxeng','gxsort','geom']]
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_coupled_pump','--Mdir',str(out/'obj'),'-CFLAGS','-std=c++20 -O1']+list(map(str,files+oldfiles+[out/'wrapper.sv',ROOT/'sim/gpu3d/snapshot_versions/coupled.cpp']))
with (out/'build.log').open('w') as log:r=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
if r.returncode:raise SystemExit(f'build failed:{r.returncode}')
print('COUPLED_BUILD_PASS',flush=True)
with (out/'run.log').open('w') as log:r=subprocess.run([str(out/'obj/Vtb_coupled_pump')],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
print((out/'run.log').read_text(),flush=True)
rec={'before':'1effca28','exit':r.returncode,'pid':os.getpid(),'nice':os.getpriority(os.PRIO_PROCESS,0),'jobs':1,'threads':1,'command':cmd,'hashes':{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}}
(out/'receipt.json').write_text(json.dumps(rec,indent=2)+'\n')
raise SystemExit(r.returncode)
