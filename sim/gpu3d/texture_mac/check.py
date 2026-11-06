#!/usr/bin/env python3
"""New owner arbitration + literal g_ff consumer, not an old geometry rerun."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser()
p.add_argument('--out',type=Path,required=True)
p.add_argument('--before',default='66eda3b6')
p.add_argument('--mutant',action='store_true')
p.add_argument('--consumer-fault-only',action='store_true')
p.add_argument('--verilator',default='build/tools/oss-cad-suite/bin/verilator')
a=p.parse_args();os.setpriority(os.PRIO_PROCESS,0,10)
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
starttime=Path('/proc/self/stat').read_text().rsplit(')',1)[1].split()[19]
status=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json')
def phase(value):
 d=json.loads(status.read_text());d.update(phase=value,worker={'host':'Desktop','controller_pid':os.getpid(),'starttime':starttime,'active':1,'nice':10,'jobs':1,'threads':1},updated_at=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
 s=json.dumps(d,indent=2)+'\n';assert len(s.encode())<=2048;t=status.with_suffix('.tmp');t.write_text(s);os.replace(t,status)
phase('newtex/cull owner relation starting, mutant='+str(a.mutant));print(f'controller_pid={os.getpid()} starttime={starttime} NI10/j1/t1',flush=True)
path='rtl/gpu3d/gpu3d_gxeng.sv';old=subprocess.check_output(['git','show',a.before+':'+path],cwd=ROOT).decode();new=(ROOT/path).read_text()
if a.mutant:
 needle=': tex_matrix[c][2];';assert new.count(needle)==1
 new=new.replace(needle,': tex_matrix[c][1]; // actual final-phase matrix-row fault')
def bank(src,name):return src[src.index('module gpu3d_gxcull_products ('):].split('endmodule',1)[0].replace('module gpu3d_gxcull_products (','module '+name+' (',1)+'endmodule\n'
ports='''input logic clk,clk2,rst,ff_col,ff_tex,ff_vtx,ff_hw,collect,rf_we,lu_cv,mat_m,
input logic [5:0] e_hidx,pi,input logic [39:0] e_data,input logic [31:0] P,rf_wd,mat_word_m,pu_q,
input logic [10:0] rf_wa,input logic [14:0] lu_cvd,input logic [1:0] mat_kind_m,
input logic [2:0] b_xsh,input logic signed [48:0] tex3_sum[2],
output logic [15:0] ffv_d[3],at_v[3],tex3_vertex[3],output logic signed[31:0] tex3_matrix[2][3],
output logic [31:0] at_q,ffd_m,output logic [1:0] at_m,output logic ffw_m,fft_m,ffv_m'''
def ff(src,name,before):
 block=src[src.index('    generate if (FF) begin : g_ff'):src.index('    gpu3d_ram #(.W(32), .AW(11)) u_rfa')]
 return f'''module {name}({ports});
import gpu3d_gxu_pkg::*;
localparam bit FF=1,PU=1,MAT_PAR=1,USORT=1,LUNIT=1;
localparam int VFIN=2;
{block}
''' + ("always_comb begin for(int k=0;k<3;k++)tex3_vertex[k]='0;for(int c=0;c<2;c++)for(int k=0;k<3;k++)tex3_matrix[c][k]='0;end\n" if before else '')+'endmodule\n'
(out/'before.sv').write_text(ff(old,'ff_before',True)+bank(old,'bank_before'))
(out/'after.sv').write_text(ff(new,'ff_after',False)+bank(new,'bank_after'))
top=['''module tb_texture_mac(
input logic clk,clk2,rst,ff_col,ff_tex,ff_vtx,ff_hw,collect,rf_we,lu_cv,mat_m,
input logic[5:0]e_hidx,pi,input logic[39:0]e_data,input logic[31:0]P,rf_wd,mat_word_m,pu_q,
input logic[10:0]rf_wa,input logic[14:0]lu_cvd,input logic[1:0]mat_kind_m,input logic[2:0]b_xsh,
input logic cross_edge,dot_edge,check_cross,check_dot,
input logic[31:0]d0x,d0y,d0w,d2x,d2y,d2w,v1x,v1y,v1w,cn2[3],
output wire[31:0]at_q,output wire[15:0]gen_t[2],ffv_d[3],
output wire signed[48:0]tex_sum[2],output wire[2:0]mode);
import gpu3d_gxu_pkg::*;
wire signed[48:0]ignored[2];
wire signed[63:0]cp_a[6],cp_b[6],cd_a[3],cd_b[3];
''']
outs={'ffv_d':'[15:0] ffv_d_{s}[3]','at_v':'[15:0] at_v_{s}[3]', 'tex3_vertex':'[15:0] tv_{s}[3]','tex3_matrix':'signed[31:0] tm_{s}[2][3]', 'at_q':'[31:0] aq_{s}','ffd_m':'[31:0] fd_{s}','at_m':'[1:0] am_{s}','ffw_m':'fw_{s}','fft_m':'ft_{s}','ffv_m':'fv_{s}'}
targets={'ffv_d':'ffv_d','at_v':'at_v','tex3_vertex':'tv','tex3_matrix':'tm','at_q':'aq','ffd_m':'fd','at_m':'am','ffw_m':'fw','fft_m':'ft','ffv_m':'fv'}
ins='clk clk2 rst ff_col ff_tex ff_vtx ff_hw collect rf_we lu_cv mat_m e_hidx pi e_data P rf_wd mat_word_m pu_q rf_wa lu_cvd mat_kind_m b_xsh'.split()
for s,mod in [('a','ff_before'),('b','ff_after')]:
 for pattern in outs.values():top.append('wire '+pattern.format(s=s)+';')
 top.append(f'{mod} {s}('+','.join([f'.{n}({n})'for n in ins]+['.tex3_sum(tex_sum)']+[f'.{n}({targets[n]}_{s})'for n in outs])+');')
bankins='clk clk2 rst cross_edge dot_edge d0x d0y d0w d2x d2y d2w v1x v1y v1w cn2'.split()
top.append('bank_before oldbank('+','.join(f'.{n}({n})'for n in bankins)+',.cp(cp_a),.cd(cd_a));')
top.append('bank_after newbank('+','.join(f'.{n}({n})'for n in bankins)+''',.cp(cp_b),.cd(cd_b),
.tex_start(ff_vtx),.tex_vertex(tv_b),.tex_matrix(tm_b),.tex_sum,
.tex_write(rf_we&&rf_wa[10:4]==FF_A_TEX[10:4]&&!rf_wa[1]),.tex_col(rf_wa[0]),.tex_row(rf_wa[3:2]),.tex_word(rf_wd));
assign mode=newbank.mode;assign at_q=aq_b;
genvar k;generate for(k=0;k<2;k++)begin:g_out assign gen_t[k]=b.g_ff.gen_t[k];end
for(k=0;k<3;k++)begin:g_v assign ffv_d[k]=ffv_d_b[k];end endgenerate
logic gen_valid=0;
always @(posedge clk) if(rst)gen_valid<=0;else if(b.g_ff.ffv_w)gen_valid<=1;
always @(negedge clk) if(!rst)begin
 if({aq_a,am_a,fd_a,fw_a,ft_a,fv_a}!=={aq_b,am_b,fd_b,fw_b,ft_b,fv_b} && (gen_valid||b_xsh!=5&&b_xsh!=6))$fatal(1,"texture actual attribute/output mismatch");
 for(int k=0;k<3;k++)if(ffv_d_a[k]!==ffv_d_b[k]||at_v_a[k]!==at_v_b[k])$fatal(1,"actual vertex decode/latch mismatch");
 for(int c=0;c<2;c++)begin
  if(gen_valid&&a.g_ff.gen_t[c]!==b.g_ff.gen_t[c])$fatal(1,"texture actual E1 gen_t mismatch coord=%0d old=%04x new=%04x",c,a.g_ff.gen_t[c],b.g_ff.gen_t[c]);
  if(a.g_ff.raw_t[c]!==b.g_ff.raw_t[c]||a.g_ff.at_t[c]!==b.g_ff.at_t[c])$fatal(1,"texture raw/mode1 precedence mismatch");
  for(int k=0;k<4;k++)if(a.g_ff.tcm[c][k]!==b.g_ff.tcm[c][k])$fatal(1,"matrix snoop mismatch");
 end
 if(check_cross)for(int k=0;k<6;k++)if(cp_a[k]!==cp_b[k])$fatal(1,"new owner consumed full64 cross mismatch");
 if(check_dot)for(int k=0;k<3;k++)if(cd_a[k]!==cd_b[k])$fatal(1,"new owner consumed full64 dot mismatch");
end
endmodule
''')
(out/'wrapper.sv').write_text('\n'.join(top))
driver=(ROOT/'sim/gpu3d/texture_mac/main.cpp').read_text()
if a.consumer_fault_only:
 assert a.mutant
 needle='throw std::runtime_error("independent exact49 fullsum mismatch");';assert driver.count(needle)==1
 driver=driver.replace(needle,'(void)0; // retain the actual E1 consumer assertion for this same fault')
(out/'main.cpp').write_text(driver)
pkg=(ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv').read_text();constants={n:int(v,16)for n,v in re.findall(r"localparam logic \[10:0\] (\w+) = 11'h([0-9a-fA-F]+)",pkg)}
constants.update({n:int(v)for n,v in re.findall(r"localparam logic \[5:0\] (\w+) = 6'd(\d+)",pkg)})
(out/'addresses.h').write_text('\n'.join(f'constexpr unsigned {n}={v};'for n,v in constants.items())+'\n')
cmd=[a.verilator,'--cc','--exe','--build','-j','1','--threads','1','--assert','-DSYNTHESIS','-Wno-fatal','--top-module','tb_texture_mac','--Mdir',str(out/'obj'),'-CFLAGS',f'-std=c++20 -O1 -I{out}',str(ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv'),str(out/'before.sv'),str(out/'after.sv'),str(out/'wrapper.sv'),str(out/'main.cpp')]
def capacity():
 rows=[s.split(None,3)for s in subprocess.check_output(['ps','-eo','pid,ppid,ni,comm'],text=True).splitlines()[1:]]
 parent={int(p):int(pp)for p,pp,_,_ in rows}
 def ancestors(pid):
  seen=set()
  while pid in parent and pid not in seen:seen.add(pid);pid=parent[pid]
  return seen
 heavy={int(p)for p,_,_,c in rows if c.startswith(('V','verilator_bin','clang','census'))or c in('cc1plus','cc1','lto1')}
 leaves={pid for pid in heavy if not any(pid in ancestors(other)-{other}for other in heavy)}
 foreign=[pid for pid in leaves if os.getpid()not in ancestors(pid)]
 with(out/'capacity.jsonl').open('a')as f:f.write(json.dumps({'time':time.time(),'foreign':foreign,'max_foreign':2})+'\n')
 return len(foreign)<=2
while not capacity():print('WAIT global<=3',flush=True);time.sleep(5)
with(out/'build.log').open('w')as log:rc=subprocess.run(cmd,cwd=out,stdout=log,stderr=subprocess.STDOUT).returncode
if rc:raise SystemExit('build failed '+str(rc))
print('BUILD_PASS',flush=True);phase('new texture-owner actualFF relation BUILD_PASS/running, mutant='+str(a.mutant))
while not capacity():print('WAIT global<=3',flush=True);time.sleep(5)
with(out/'run.log').open('w')as log:rc=subprocess.run([str(out/'obj/Vtb_texture_mac')],cwd=out,stdout=log,stderr=subprocess.STDOUT).returncode
receipt={'before':a.before,'before_sha256':hashlib.sha256(old.encode()).hexdigest(),'candidate_sha256':hashlib.sha256(new.encode()).hexdigest(),'command':cmd,'mutant':a.mutant,'consumer_fault_only':a.consumer_fault_only,'exit':rc,'controller':os.getpid(),'starttime':starttime,'nice':10,'jobs':1,'threads':1,'scope':'new owner/cancel interference, actualg_ff E1 consumers and full64 consumed cull products; no old baseline rerun'}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');log=(out/'run.log').read_text();print(log,flush=True)
if(rc==0)==a.mutant:raise SystemExit('unexpected verdict')
if a.mutant and not any(g in log for g in ('texture actual E1 gen_t mismatch','independent exact49 fullsum mismatch')):raise SystemExit('wrong fault gate')
phase('new texture-owner component terminal, mutant='+str(a.mutant))
