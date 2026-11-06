#!/usr/bin/env python3
"""Thin, source-bound full Geometry/RF/context proof bundle; no execution."""
from pathlib import Path
import json,hashlib,shutil,subprocess
R=Path(__file__).resolve().parents[4];D=Path('/home/user/Git/NDS_Pocket/build/clip16-context-l2');D.mkdir(parents=True,exist_ok=True)
Q=R/'docs/results/clean-runtime-snapshot-adapt-20261101';manifest=json.loads((Q/'manifest.json').read_text())
for f in ['context.hex','expected-clip.hex','context-seed.json','runtime-atomic.json','qualification.json']:
 assert hashlib.sha256((Q/f).read_bytes()).hexdigest()==manifest[f],f;shutil.copyfile(Q/f,D/f)
files=['rtl/gpu3d/gpu3d_gxu_pkg.sv','rtl/gpu3d/gpu3d_ram.sv']+[str(p.relative_to(R))for p in sorted((R/'rtl/gpu3d').glob('gpu3d_gxrom*.sv'))]+['rtl/gpu3d/gpu3d_'+n+'.sv'for n in ['gxlight','gxdiv','gxfront','gxeng','gxsort','geom','gxvfin']]
for f in files:shutil.copyfile(R/f,D/Path(f).name)
for f in ['runtime_import_finalize_snapshots.svh','runtime_import_finalize_groups.svh','runtime_import_clip_store.svh','runtime_import_cull_cache.svh','runtime_import_gx_context.svh']:shutil.copyfile(R/'sim/pocket_ds'/f,D/f)
outputs={'io_rdata':32,'io_ack':1,'io_wait':1,'irq_gxfifo':1,'dma_gx_low':1,'gx_stall':1,'ovf_set':1,'po_valid':1,'po_type':1,'po_data':128,'po_index':11,'po_wv':1,'po_wk':2,'po_wd':32,'so_we':1,'so_pos':11,'so_idx':11,'so_done':1,'so_count':12,'dbg_stall':1,'dbg_apply':1,'dbg_upc':11,'dbg_flush':1,'dbg_idle':1,'dbg_gxstat':32,'dbg_npoly':12,'dbg_nvert':13,'diag_ev':3,'diag_used':13,'dbg_eq_bad':1}
s='''`timescale 1ns/1ps
module tb_context;
logic clk=0,clk2=0,rst=1,tick_bit=0,req=0,we=0,ready=1;
logic[7:0]addr=0;logic[31:0]wd=0;
logic[31:0]context_data[0:2631],expected[0:15];
logic[31:0]words[0:4][0:31],oq[0:4],iq[0:4],sidecar[0:169];
bit checking=0,last_e_we=1;integer cycles=0,clips=0,rfwrites=0,clipwrites=0,polys=0;integer j,k,n;
logic[85:0]saved_metadata;time deposit_time;
'''
params='.FF(1),.LUNIT(1),.VFIN(2),.USORT(1),.GX_DSX(1),.GX_SWAP_OVERLAP(1),.GX_L44_READ(1),.GX_MAT_PAR(1),.GX_DIV_P2X(1),.GX_SCALAR_DIV_P2X(1),.GX_ROM_DICT(1),.ENG_M10K(0),.SPILL(1),.SP_SIM(1),.SP_ON(4096),.SP_AW(18),.GATH16(1)'
for tag,pump in [('a',0),('b',1)]:
 for name,width in outputs.items():s+=f'wire[{width-1}:0]{name}_{tag};\n'
 c=['.clk','.clk_2x(clk2)','.rst','.tick(tick_bit)',".geom_en(1'b1)",".vblank(1'b0)",'.io_req(req)','.io_we(we)',".io_be(4'hf)",'.io_addr(addr)','.io_wdata(wd)',".io_wpre(21'd0)",'.po_ready(ready)',".s_draw(1'b0)",".sp_wack(1'b0)",".sp_wdrained(1'b1)",".sp_rack(1'b0)",".sp_rvalid(1'b0)",".sp_rdata(32'd0)"]+[f'.{name}({name}_{tag})'for name in outputs]
 s+=f'gpu3d_geom #({params},.GX_CLIP_STORE_PUMP({pump})) {tag}('+','.join(c)+');\n'
s+='''`define RUNTIME_FINALIZE_GROUP_PUMP
`undef RUNTIME_CLIP_STORE_ENABLED
generate begin:source_bridge
 `define RUNTIME_GEOMETRY $root.tb_context.a
 `include "runtime_import_gx_context.svh"
 `undef RUNTIME_GEOMETRY
end endgenerate
generate begin:target_bridge
 `define RUNTIME_GEOMETRY $root.tb_context.b
 `define RUNTIME_CLIP_STORE_ENABLED
 `include "runtime_import_gx_context.svh"
 `undef RUNTIME_CLIP_STORE_ENABLED
 `undef RUNTIME_GEOMETRY
end endgenerate

task automatic compare_public;
'''
for name in outputs:
 gate='1'
 if name=='io_rdata':gate='io_ack_a&&!we'
 if name in ['po_type','po_data','po_index']:gate='po_valid_a'
 if name in ['po_wk','po_wd']:gate='po_wv_a'
 if name in ['so_pos','so_idx']:gate='so_we_a'
 if name=='so_count':gate='so_done_a'
 s+=f'if({gate} && {name}_a!=={name}_b)$fatal(1,"CONTEXT_PUBLIC_{name}_MISMATCH cycle%0d",cycles);\n'
s+='''if(a.u_eng.rf_we!==b.u_eng.rf_we)$fatal(1,"CONTEXT_RF_ORDER_MISMATCH");
if(a.u_eng.rf_we && {a.u_eng.rf_wa,a.u_eng.rf_wd}!=={b.u_eng.rf_wa,b.u_eng.rf_wd})$fatal(1,"CONTEXT_RF_DATA_MISMATCH");
if(a.u_eng.g_cl.u_clip.cw && {a.u_eng.g_cl.u_clip.cwa,a.u_eng.g_cl.u_clip.cwd}!=={b.u_eng.g_cl.u_clip.cwa,b.u_eng.g_cl.u_clip.cwd})$fatal(1,"CONTEXT_CLIP_PUBLIC_MISMATCH");
endtask
task automatic step;
begin
 #2;
 if(checking)begin
  compare_public();
  if(a.u_eng.rf_we)rfwrites++;
  if(a.u_eng.g_cl.u_clip.run&&a.u_eng.g_cl.u_clip.can&&!a.u_eng.g_cl.u_clip.busy)clips++;
  if(a.u_eng.g_cl.u_clip.cw&&a.u_eng.g_cl.u_clip.wfree)clipwrites++;
  if(po_valid_a&&po_type_a)polys++;
 end
 last_e_we=a.u_eng.rf_we||b.u_eng.rf_we;clk=1;clk2=1;#1;
 if(checking)compare_public();
 clk=0;clk2=0;#2;clk2=1;#1;clk2=0;#1;
 if(checking)compare_public();tick_bit=~tick_bit;cycles++;
end endtask

task automatic read_io(input logic[7:0]port,input logic[31:0]want,input bit check_value);
 integer timeout;
 begin req=1;we=0;addr=port;timeout=0;
 do begin step();timeout++;if(timeout>20000)$fatal(1,"CONTEXT_READ_TIMEOUT");end while(!io_ack_a);
 if(check_value && io_rdata_a!==want)$fatal(1,"QUALIFIED_DEFAULT_LAZY_MATRIX_MISMATCH word%0d got%h want%h",port-8'h90,io_rdata_a,want);
 req=0;step();end
endtask
task automatic command(input logic[7:0]op,input logic[31:0]value);
 integer timeout;
 begin req=1;we=1;addr=op;wd=value;timeout=0;
 do begin step();timeout++;if(timeout>20000)$fatal(1,"CONTEXT_WRITE_TIMEOUT");end while(io_wait_a);
 req=0;we=0;step();end
endtask

initial begin : test_main
 $readmemh("context.hex",context_data);$readmemh("expected-clip.hex",expected);
 repeat(8)step();rst=0;
 // Same pre-publication cold boot recipe as qualified context fixture.
 repeat(10000)step();
 for(n=0;n<20000;n++)begin
  if(dbg_idle_a&&dbg_idle_b&&!last_e_we&&!a.u_eng.g_cl.u_clip.busy&&!b.u_eng.g_cl.u_clip.busy&&!b.u_eng.g_cl.u_clip.g_store_pump.u_store.pending_we)break;
  step();
 end
 assert(n<20000 && clk==0 && clk2==0)else $fatal(1,"CONTEXT_FREEZE_BARRIER");
 $display("FROZEN_POST_M cycle%0d lastEwrite%0d",cycles,last_e_we);
 source_bridge.import_gx_context(context_data,1);
 source_bridge.verify_gx_context(context_data);
 source_bridge.capture_gx_context_clip_witness(words,oq,iq,1,1,!last_e_we,1);
 for(j=0;j<5;j++)begin
  for(k=0;k<32;k++)sidecar[j*32+k]=words[j][k];
  sidecar[160+j]=oq[j];sidecar[165+j]=iq[j];
 end
 $writememh("captured-sidecar.hex",sidecar);
 saved_metadata=target_bridge.clip_import_metadata();deposit_time=$time;
 target_bridge.import_gx_context_with_clip_witness(context_data,words,oq,iq,32'hffffffff,5'b11111,1,1,1);
 assert(saved_metadata===target_bridge.clip_import_metadata()&&deposit_time==$time)else $fatal(1,"CONTEXT_PHASE_TIME_CHANGED");
 // Full RF/context proof, including actual retained unmapped source words.
 for(j=0;j<2048;j++)assert(a.u_eng.u_rfa.mem[j]===b.u_eng.u_rfa.mem[j]&&a.u_eng.u_rfb.mem[j]===b.u_eng.u_rfb.mem[j])else $fatal(1,"CONTEXT_FULL_RF_MISMATCH word%0d",j);
 $display("FULL_RF_CONTEXT_READBACK_PASS RF2048x2 context2632 actualsidecar170 no_ticks");
 checking=1;
 // First normal work; retain the independent accepted matrix expectations.
 for(j=0;j<16;j++)read_io(8'h90+8'(j),expected[j],1);
 $display("QUALIFIED_DEFAULT_FIRST16_LAZY_READS_PASS");
 // Real future GX commands from the retained complete-caller recipe.
 // Captured dirty matrix was already observed by all16 MMIO reads above.
 command(8'h10,0);command(8'h15,0);command(8'h10,2);command(8'h15,0);
 command(8'h29,32'h001f00c0);command(8'h40,1);
 for(j=0;j<4;j++)begin
  command(8'h20,32'(16'h1234+j*13));command(8'h22,32'h81230000+32'(j*17));
  command(8'h23,{16'(j==0||j==3?-8192:8192),16'(j<2?-8192:8192)});command(8'h23,32'd1024);
 end
 command(8'h41,0);
 for(n=0;n<100000;n++)begin
  step();if(dbg_idle_a&&dbg_idle_b&&clips>0&&clipwrites>0)break;
 end
 if(n==100000||clips==0||clipwrites==0||rfwrites==0)$fatal(1,"CONTEXT_FIRST_CLIP_COVERAGE clips%0d writes%0d RF%0d",clips,clipwrites,rfwrites);
 $display("PASS_FULL_CONTEXT_CAPTURE_IMPORT_FIRST_USE cycles%0d clips%0d clipwrites%0d RF%0d polys%0d",cycles,clips,clipwrites,rfwrites,polys);
 $finish;
end
endmodule
'''
(D/'tb_context.sv').write_text(s)
shutil.copyfile(R/'sim/gpu3d/clip_import/context/worker.py',D/'worker.py')
seed=json.loads((D/'context-seed.json').read_text())
r={'source':subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),'source_files':files,'parent_atomic_sha256':seed['source_atomic_sha256'],'packet':'clean-runtime-snapshot-adapt-20261101 unchanged','profile':params,'control_clip_store':0,'target_clip_store':1,'disk_cap_bytes':512*1024*1024,'minimum_free_bytes':1024*1024*1024,'sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in D.iterdir()if p.is_file()and (p.suffix in ['.sv','.svh','.py']or p.name in ['context.hex','expected-clip.hex','context-seed.json','runtime-atomic.json','qualification.json'])}}
(D/'input.json').write_text(json.dumps(r,indent=2)+'\n');print('PREPARED',D,sum(p.stat().st_size for p in D.iterdir()if p.is_file()),'bytes')
