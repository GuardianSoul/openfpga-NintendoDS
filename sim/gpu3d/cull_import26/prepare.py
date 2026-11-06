#!/usr/bin/env python3
"""Prepare only the cull25 changed-cache import regression on current RTL."""
import ast, hashlib, json, re, shutil, subprocess, tarfile
from pathlib import Path
R=Path(__file__).resolve().parents[3];D=R/'build/cull-import26';D.mkdir(parents=True,exist_ok=True)
old=R/'sim/gpu3d/clip_import/context/prepare.py'
tree=ast.parse(old.read_text())
outputs=next(ast.literal_eval(n.value)for n in tree.body if isinstance(n,ast.Assign)and any(isinstance(t,ast.Name)and t.id=='outputs'for t in n.targets))
params=re.search(r"^params='(.*)'$",old.read_text(),re.M).group(1)+',.GX_CLIP_STORE_PUMP(1)'
files=['rtl/gpu3d/gpu3d_gxu_pkg.sv','rtl/gpu3d/gpu3d_ram.sv']+[str(p.relative_to(R))for p in sorted((R/'rtl/gpu3d').glob('gpu3d_gxrom*.sv'))]+['rtl/gpu3d/gpu3d_'+n+'.sv'for n in ['gxlight','gxdiv','gxfront','gxeng','gxsort','geom','gxvfin']]
for f in files:shutil.copyfile(R/f,D/Path(f).name)
for p in (R/'sim/pocket_ds').glob('runtime_import_*.svh'):shutil.copyfile(p,D/p.name)
Q=R/'docs/results/clean-runtime-snapshot-adapt-20261101';manifest=json.loads((Q/'manifest.json').read_text())
assert hashlib.sha256((Q/'context.hex').read_bytes()).hexdigest()==manifest['context.hex']
shutil.copyfile(Q/'context.hex',D/'context.hex')
with tarfile.open(R/'sim/gpu3d/clip_import/context/evidence.tar.gz')as t:
 witness=t.extractfile('positive/captured-sidecar.hex').read()
(D/'sidecar.hex').write_bytes(witness)
s='''`timescale 1ns/1ps
module tb_cull_import;
logic clk=0,clk2=0,rst=1,tick_bit=0,req=0,we=0,ready=1;
logic[7:0]addr=0;logic[31:0]wd=0;
logic[31:0]context_data[0:2631],captured[0:11],sidecar[0:169];
logic[31:0]words[0:4][0:31],oq[0:4],iq[0:4];
bit checking=0,repaired=0,first_op=0,first_outcome=0,op_diff=0,outcome_diff=0;
integer cycles=0,mode=0,n,j,k;logic[100:0]saved;time at_import;
logic[31:0]bad_x;
'''
for tag,cull in [('a',0),('b',1)]:
 for name,width in outputs.items():s+=f'wire[{width-1}:0]{name}_{tag};\n'
 c=['.clk','.clk_2x(clk2)','.rst','.tick(tick_bit)',".geom_en(1'b1)",".vblank(1'b0)",'.io_req(req)','.io_we(we)',".io_be(4'hf)",'.io_addr(addr)','.io_wdata(wd)',".io_wpre(21'd0)",'.po_ready(ready)',".s_draw(1'b0)",".sp_wack(1'b0)",".sp_wdrained(1'b1)",".sp_rack(1'b0)",".sp_rvalid(1'b0)",".sp_rdata(32'd0)"]+[f'.{name}({name}_{tag})'for name in outputs]
 s+=f'gpu3d_geom #({params},.GX_CULL_MLAB({cull})) {tag}('+','.join(c)+');\n'
s+='''`define RUNTIME_FINALIZE_GROUP_PUMP
`define RUNTIME_CLIP_STORE_ENABLED
generate begin:source_bridge
 `define RUNTIME_GEOMETRY $root.tb_cull_import.a
 `include "runtime_import_gx_context.svh"
 `undef RUNTIME_GEOMETRY
end endgenerate
generate begin:target_bridge
 `define RUNTIME_CULL_MLAB_ENABLED
 `define RUNTIME_GEOMETRY $root.tb_cull_import.b
 `include "runtime_import_gx_context.svh"
 `undef RUNTIME_GEOMETRY
end endgenerate
`undef RUNTIME_CULL_MLAB_ENABLED
`undef RUNTIME_CLIP_STORE_ENABLED
`undef RUNTIME_FINALIZE_GROUP_PUMP
`define A a.u_eng.g_pu
`define B b.u_eng.g_pu
`define C `B.g_cull_mlab.u_cache

task automatic compare_public;
'''
for name in outputs:
 gate='1'
 if name=='io_rdata':gate='io_ack_a&&!we'
 if name in ['po_type','po_data','po_index']:gate='po_valid_a'
 if name in ['po_wk','po_wd']:gate='po_wv_a'
 if name in ['so_pos','so_idx']:gate='so_we_a'
 if name=='so_count':gate='so_done_a'
 s+=f'if({gate} && {name}_a!=={name}_b)$fatal(1,"CULL_IMPORT_PUBLIC_{name} cycle%0d",cycles);\n'
s+='''endtask

task automatic repair_cache;
 // Actual old-cache capture at a naturally reached first-cull boundary.
 // No cull state/group/operand/pipeline control is forced.
 for(int g=0;g<4;g++)begin
  captured[0+g]=`A.cpw[g];captured[4+g]=`A.cpx[g];captured[8+g]=`A.cpy[g];
 end
 assert(`A.c_st==3 && `B.c_st==3 && clk==0 && clk2==0)
  else $fatal(1,"CULL_IMPORT_CAPTURE_BOUNDARY");
 assert(`A.c_g0==`B.c_g0 && `A.c_g1==`B.c_g1 && `A.c_g2==`B.c_g2)
  else $fatal(1,"CULL_IMPORT_GROUP_DATE");
 bad_x=2*captured[4+int'(`A.c_g1)]-captured[4+int'(`A.c_g2)];
 assert(bad_x!==captured[4+int'(`A.c_g2)])else $fatal(1,"CULL_IMPORT_FAULT_NOT_DISTINCT");
 if(mode==3||mode==4)assert(`C.mid && `C.snap_hold && `C.group_hold==`A.c_g2)
  else $fatal(1,"CULL_IMPORT_PENDING_COVERAGE");
 saved=target_bridge.cull_import_metadata();at_import=$time;
'''
# Poison arbitrary target backing before the stopped import: this makes a
# missing replica write observable, even though the caller had run equally.
for c in range(3):
 for r in range(3):s+=f" for(int g=0;g<32;g++)`C.g_coordinate[{c}].g_reader[{r}].u_mem.mem[g]=32'hfeed0000+32'(g);\n"
s+=''' if(mode==4)begin
  `C.data_hold[0]=bad_x;
  $display("ACTUAL_PENDING_CONFLICT_BEFORE_PREFLIGHT cycle%0d",cycles);
 end
 target_bridge.cull_import_preflight(captured,1);
 target_bridge.cull_import_words(captured,1);
 target_bridge.cull_verify_words(captured);
 assert(saved===target_bridge.cull_import_metadata() && at_import==$time)
  else $fatal(1,"CULL_IMPORT_PHASE_TIME_CHANGED");
'''
for c in range(3):
 for r in range(3):s+=f" for(int g=4;g<32;g++)assert(`C.g_coordinate[{c}].g_reader[{r}].u_mem.mem[g]==32'hfeed0000+32'(g))else $fatal(1,\"CULL_IMPORT_UNUSED_SLOT_CHANGED\");\n"
s+=''' if(mode==2)begin
  `C.g_coordinate[0].g_reader[2].u_mem.mem[`A.c_g2]=bad_x;
  $display("ACTUAL_WRONG_COPY c0r2 group%0d",`A.c_g2);
 end
 if(mode==3)begin
  `C.data_hold[0]=bad_x;
  $display("ACTUAL_PENDING_M_FAULT group%0d",`C.group_hold);
 end
 repaired=1;
 $display("REPAIRED cycle%0d phase%0d mid%0d pending%0d metadata%026h no_ticks",cycles,mode,`C.mid,`C.snap_hold,saved);
endtask

task automatic qualified;
 if(repaired && !first_op && `A.c_st==3)begin
  assert(`B.c_st==3)else $fatal(1,"CULL_IMPORT_FIRST_OPERAND_DATE");
  $write("FIRST_OP cycle%0d groups%0d,%0d,%0d",cycles,`A.c_g0,`A.c_g1,`A.c_g2);
  for(int r=0;r<3;r++)for(int c=0;c<3;c++)begin
   $write(" %08x/%08x",a.u_eng.g_pu.cull_operand[r][c],b.u_eng.g_pu.cull_operand[r][c]);
   if(a.u_eng.g_pu.cull_operand[r][c]!==b.u_eng.g_pu.cull_operand[r][c])op_diff=1;
  end
  $write(" diff%0d\\n",op_diff);first_op=1;
 end
 if(repaired && !first_outcome && `A.c_st==8)begin
  assert(`B.c_st==8 && first_op)else $fatal(1,"CULL_IMPORT_FIRST_OUTCOME_DATE");
  outcome_diff={`A.c_face,`A.c_rej}!=={`B.c_face,`B.c_rej};first_outcome=1;
  $display("FIRST_OUTCOME cycle%0d face%0d/%0d reject%0d/%0d diff%0d",cycles,`A.c_face,`B.c_face,`A.c_rej,`B.c_rej,outcome_diff);
  if(mode<2)begin
   assert(!op_diff && !outcome_diff)else $fatal(1,"CULL_IMPORT_FIRST_USE_MISMATCH");
   $display("PASS_CULL_IMPORT_FIRST_USE mode%0d",mode);
  end else begin
   assert(op_diff && outcome_diff)else $fatal(1,"CULL_IMPORT_MUTATION_NOT_SENSITIVE");
   $display("CAUGHT_ACTUAL_CULL_IMPORT_FAULT mode%0d",mode);
  end
  $finish;
 end
endtask

task automatic m_edge;
 #1;clk2=1;#1;clk2=0;#1;tick_bit=~tick_bit;
endtask

task automatic step;
 #2;
 if(checking)begin
  qualified();
  if(mode<2)compare_public();
 end
 clk=1;clk2=1;#1;clk=0;clk2=0;cycles++;
 // c_st3 is created by the natural final-vertex snapshot on this E.
 if(checking && !repaired && `A.c_st==3)begin
  if(mode==0||mode==2)begin m_edge();repair_cache();end
  else begin repair_cache();m_edge();end
 end else m_edge();
 if(checking && mode<2)compare_public();
endtask

task automatic command(input logic[7:0]op,input logic[31:0]value);
 integer timeout;
 begin req=1;we=1;addr=op;wd=value;timeout=0;
 do begin step();timeout++;if(timeout>20000)$fatal(1,"CULL_IMPORT_WRITE_TIMEOUT");end while(io_wait_a);
 req=0;we=0;step();end
endtask
initial begin
 if(!$value$plusargs("mode=%d",mode))mode=0;
 $readmemh("context.hex",context_data);$readmemh("sidecar.hex",sidecar);
 for(j=0;j<5;j++)begin
  for(k=0;k<32;k++)words[j][k]=sidecar[j*32+k];
  oq[j]=sidecar[160+j];iq[j]=sidecar[165+j];
 end
 repeat(8)step();rst=0;repeat(10000)step();
 // Reuse accepted full-context/clip witness contract, only changing cull ABI.
 source_bridge.import_gx_context_with_clip_witness(context_data,words,oq,iq,32'hffffffff,5'b11111,1,1,1);
 target_bridge.import_gx_context_with_clip_witness(context_data,words,oq,iq,32'hffffffff,5'b11111,1,1,1);
 $display("FULL_CONTEXT_CULL_ABI_PASS words2632 cache36 schema_unchanged cycle%0d",cycles);
 checking=1;
 // Ordinary identity setup then one triangle. This constructs the active
 // stopped cache boundary naturally; full-context scope stays quiescent.
 command(8'h10,0);command(8'h15,0);command(8'h10,2);command(8'h15,0);
 command(8'h29,32'h001f0080);command(8'h40,0);
 for(j=0;j<3;j++)begin
  command(8'h20,32'h1234);command(8'h22,0);
  command(8'h23,{16'(j==0?-4096:4096),16'(j<2?-4096:4096)});command(8'h23,32'd1024);
 end
 command(8'h41,0);
 repeat(10000)step();$fatal(1,"CULL_IMPORT_FIRST_USE_TIMEOUT");
end
endmodule
'''
(D/'tb_cull_import.sv').write_text(s)
rec={'source':subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),'source_files':files,'profile':params,'context_sha256':manifest['context.hex'],'clip_witness_sha256':hashlib.sha256(witness).hexdigest(),'scope':'Only changed cull-cache import; existing quiescent context and clip witness contract retained, natural paused first-cull tests use narrow helper only. No games/old baseline/area campaign.','sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in D.iterdir()if p.is_file()and p.suffix in ['.sv','.svh','.hex']}}
(D/'input.json').write_text(json.dumps(rec,indent=2)+'\n');print(D)
