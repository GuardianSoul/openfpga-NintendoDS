#!/usr/bin/env python3
"""Actual changed cull slice; qualified products/state/result edges only."""
import argparse,hashlib,json,os,resource,subprocess,tarfile,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--mutant',action='store_true');a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
print(f'worker_pid={os.getpid()} starttime={Path("/proc/self/stat").read_text().split()[21]} nice=10 jobs=1 threads=1 mutant={a.mutant}',flush=True)
old=subprocess.check_output(['git','show','4153cd6d:rtl/gpu3d/gpu3d_gxeng.sv'],cwd=ROOT,text=True)
new=(ROOT/'rtl/gpu3d/gpu3d_gxeng.sv').read_text();source_hash=hashlib.sha256(new.encode()).hexdigest()
if a.mutant:
    needle='cp[2*k+1] <= product[k];';assert new.count(needle)==1
    new=new.replace(needle,'cp[2*k+1] <= product[(k+1)%3]; // actual wrong E-lane product')
helper=new[new.index('module gpu3d_gxcull_products ('):]
(out/'helper.sv').write_text(helper)
header='''(input logic clk,clk2,rst,rf_we,xsnap,xs_slot,pu_done,pu_step,dc_pend,pu_triv,
input logic [10:0] rf_wa,input logic [31:0] rf_wd,xs_c[4],input logic [1:0] pre[4],xs_g,
output wire pu_cbusy,pu_crej,face,reject,output wire [3:0] stage);
wire clk_2x=clk2;
logic [31:0] cpx[4],cpy[4],cpw[4],ccattr;
'''
for name,s in [('before',old),('after',new)]:
    mark=s.index('        logic [3:0]  c_st;')
    start=s.rfind('        always_ff @(posedge clk) begin',0,mark)
    stop=s.index('        // ---- PK:',mark)
    f=s[s.index('        function automatic [10:0] gb('):].split('endfunction',1)[0]+'endfunction\n'
    unit='module cull_'+name+' import gpu3d_gxu_pkg::*; '+header+f+s[start:stop]+'\nassign stage=c_st;assign face=c_face;assign reject=c_rej;\nendmodule\n'
    (out/(name+'.sv')).write_text(unit)
ins='clk,clk2,rst,rf_we,xsnap,xs_slot,pu_done,pu_step,dc_pend,pu_triv,rf_wa,rf_wd,xs_c,pre,xs_g'.split(',')
ports='''input logic clk,clk2,rst,rf_we,xsnap,xs_slot,pu_done,pu_step,dc_pend,pu_triv,observe,
input logic [10:0] rf_wa,input logic [31:0] rf_wd,xs_c[4],input logic [1:0] pre[4],xs_g,
output wire face,reject,busy,crej,output wire [3:0] stage,
output logic [31:0] cp_checks=0,normal_checks=0,cd_checks=0,result_checks=0,phase_m=0,phase_e=0,dot_m=0'''
top=['module tb_cull_products('+ports+');']
for suffix,mod in [('a','cull_before'),('b','cull_after')]:
    top.append(f'wire face_{suffix},reject_{suffix},busy_{suffix},crej_{suffix};wire [3:0] stage_{suffix};')
    con=[f'.{n}({n})'for n in ins]+[f'.face(face_{suffix})',f'.reject(reject_{suffix})',f'.pu_cbusy(busy_{suffix})',f'.pu_crej(crej_{suffix})',f'.stage(stage_{suffix})']
    top.append(f'{mod} {suffix}('+','.join(con)+');')
top.append('''assign stage=stage_b;assign face=face_b;assign reject=reject_b;assign busy=busy_b;assign crej=crej_b;
always @(negedge clk) if(!rst) begin
 if(stage_a!==stage_b || busy_a!==busy_b || a.c_early!==b.c_early || a.c_g0!==b.c_g0 || a.c_g1!==b.c_g1 || a.c_g2!==b.c_g2)$fatal(1,"cull control/order mismatch");
''')
for n in ['d0x','d0y','d0w','d2x','d2y','d2w','v1x','v1y','v1w','ccattr']:
    top.append(f'if(a.{n}!==b.{n})$fatal(1,"cull coherent input {n} mismatch");')
top.append('''if(observe && stage_a==5) begin
 for(int k=0;k<6;k++)if(a.cp[k]!==b.cp[k])$fatal(1,"cull full64 cross product/phase mismatch");
 cp_checks<=cp_checks+1;
end
if(observe && stage_a==6) begin
 for(int k=0;k<3;k++)if(a.cn2[k]!==b.cn2[k])$fatal(1,"cull normalization mismatch");
 normal_checks<=normal_checks+1;
end
if(observe && stage_a==7) begin
 for(int k=0;k<3;k++)if(a.cd[k]!==b.cd[k])$fatal(1,"cull full64 dot product/phase mismatch");
 cd_checks<=cd_checks+1;
end
if(observe && stage_a==8) begin
 if(face_a!==face_b || reject_a!==reject_b || crej_a!==crej_b)$fatal(1,"cull qualified result mismatch");
 result_checks<=result_checks+1;
end
end
always @(posedge clk2) if(!rst) begin
 if(b.u_cull_products.mode==1)begin
  if(clk)$fatal(1,"cross first phase not M");phase_m<=phase_m+1;
 end
 if(b.u_cull_products.mode==2)begin
  if(!clk)$fatal(1,"cross second phase not E");phase_e<=phase_e+1;
 end
 if(b.u_cull_products.mode==3)begin
  if(clk)$fatal(1,"dot phase not M");dot_m<=dot_m+1;
 end
end
endmodule
''')
pkg=(ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv').read_text();m=re.search(r"LU_A_CATTR = 11'h([0-9A-Fa-f]+)",pkg);assert m
(out/'addresses.h').write_text('constexpr unsigned LU_CATTR=0x'+m[1]+';\n')
(out/'wrapper.sv').write_text('\n'.join(top));(out/'driver.cpp').write_bytes((ROOT/'sim/gpu3d/cull_products/main.cpp').read_bytes())
files=[ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv']+[out/f for f in ['before.sv','after.sv','helper.sv','wrapper.sv','driver.cpp']]
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_cull_products','--Mdir',str(out/'obj'),'-CFLAGS',f'-std=c++20 -O1 -I{out}']+list(map(str,files))
with (out/'build.log').open('w') as log:r=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
if r.returncode:raise SystemExit(f'BUILD_FAIL:{r.returncode}')
with (out/'run.log').open('w') as log:r=subprocess.run([str(out/'obj/Vtb_cull_products')],cwd=out,stdout=log,stderr=subprocess.STDOUT)
log=(out/'run.log').read_text();print(log,flush=True)
rec={'before':'4153cd6d','source_sha256':source_hash,'staged_sha256':hashlib.sha256(new.encode()).hexdigest(),'mutant':a.mutant,'exit':r.returncode,'pid':os.getpid(),'starttime':Path('/proc/self/stat').read_text().split()[21],'nice':10,'jobs':1,'threads':1,'command':cmd,'fixture_hashes':{f.name:hashlib.sha256(f.read_bytes()).hexdigest()for f in files}}
(out/'receipt.json').write_text(json.dumps(rec,indent=2)+'\n')
with tarfile.open(out/'evidence.tar.gz','w:gz') as tar:
 for f in sorted(out.iterdir()):
  if f.is_file()and f.name!='evidence.tar.gz':tar.add(f,arcname=f.name)
if (r.returncode==0)==a.mutant:raise SystemExit('unexpected result')
if a.mutant and 'cull full64 cross product/phase mismatch'not in log:raise SystemExit('actual E-lane fault not caught')
