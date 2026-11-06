#!/usr/bin/env python3
"""Actual previous/current complete 2D engines, shared VRAM/capture traffic."""
import argparse,hashlib,json,os,resource,re,subprocess,tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
print(f'worker_pid={os.getpid()} starttime={Path("/proc/self/stat").read_text().split()[21]} nice=10 jobs=1 threads=1',flush=True)
names=['gpu2d','gpu2d_bg','gpu2d_obj','gpu2d_cache','gpu2d_cgen','gpu2d_ram','gpu2d_ram_be','gpu2d_mlab_od','gpu2d_mlab','gpu2d_mlab_be','gpu2d_m10k']
pat=r'\b('+ '|'.join(names)+r')\b';oldfiles=[]
for name in ['gpu2d_ram','gpu2d_cache','gpu2d_bg','gpu2d_obj','gpu2d']:
 s=subprocess.check_output(['git','show',f'23cae397:rtl/gpu2d/{name}.sv'],cwd=ROOT,text=True)
 s=re.sub(pat,lambda m:m[0]+'_before',s);f=out/f'before_{name}.sv';f.write_text(s);oldfiles.append(f)
s=(ROOT/'rtl/gpu2d/gpu2d.sv').read_text();ports=s.split(') (\n',1)[1].split('\n);',1)[0]
meta=re.findall(r'^\s*(input|output)\s+(logic|blk_t)\s*(\[[^]]+\])?\s*(\w+)',ports,re.M)
assert len(meta)==len(re.findall(r'^\s*(?:input|output)\b',ports,re.M))
inputs=[n for d,t,w,n in meta if d=='input'];outputs={n:(w or '') if t=='logic' else t for d,t,w,n in meta if d=='output'}
extra='output logic [31:0] fwd_mc=0,fwd_bt=0,fwd_ot=0,fwd_pf=0,pf_full=0,pf_replace=0,held=0,scrub_writes=0,olb_writes=0'
top=['module tb_od_2d import gpu2d_pkg::*; (\n'+ports+',\n'+extra+');']
params='.PERSIST(1),.OAM_CPU(1),.WST_RF(1),.MOSAIC(1),.TAG_MLAB(0),.TEX_IDXW(6)'
for suffix,mod in [('a','gpu2d_before'),('b','gpu2d')]:
 for n,w in outputs.items():top.append(f'wire {w} {n}_{suffix};')
 con=[f'.{n}({n})' for n in inputs]+[f'.{n}({n}_{suffix})' for n in outputs]
 top.append(f'{mod} #({params}) {suffix}('+','.join(con)+');')
for n in outputs:top.append(f'assign {n}={n}_a;')
top.append('always @(negedge clk) if(!rst) begin')
for n in outputs:
 gate='1'
 if n=='vr_blk':gate='vr_req_a'
 if n in ['cap_addr','cap_data']:gate='cap_we_a'
 if n in ['out_eng','out_x','out_rgb']:gate='out_valid_a'
 if n in ['l3d_raddr','fifo_raddr']:gate='bg_busy_a'
 top.append(f'if({gate}&&{n}_a!=={n}_b)$fatal(1,"coupled2D {n} mismatch");')
top.append('''if(a.o_olb_we!==b.o_olb_we || a.o_olb_we && (a.o_olb_wa!==b.o_olb_wa || a.o_olb_wd!==b.o_olb_wd))$fatal(1,"OBJ linebuffer state/order mismatch");
if(a.b_olb_we!==b.b_olb_we || a.b_olb_we && a.b_olb_wa!==b.b_olb_wa)$fatal(1,"BG linebuffer clear/order mismatch");
if(a.u_obj.pf_n!==b.u_obj.pf_n || a.u_obj.pf_wp!==b.u_obj.pf_wp || a.u_obj.pf_rp!==b.u_obj.pf_rp || a.u_obj.pfr_v!==b.u_obj.pfr_v)$fatal(1,"OBJ PFQ control mismatch");
''')
for owner in ['u_bg.u_mc','u_bg.u_tc','u_obj.u_tc']:
 top.append(f'''for(int k=0;k<64;k++) if(a.{owner}.g_tt.g_tr.u_tag.mem[k] !==
 ((b.{owner}.g_tt.g_tm.u_tag.pending_we&&b.{owner}.g_tt.g_tm.u_tag.pending_address==6'(k))?b.{owner}.g_tt.g_tm.u_tag.pending_data:b.{owner}.g_tt.g_tm.u_tag.mem[k]))$fatal(1,"coupled2D {owner} logical state mismatch");''')
top.append('''for(int k=0;k<64;k++) if(a.u_obj.u_pfq.mem[k] !== ((b.u_obj.u_pfq.pending_we&&b.u_obj.u_pfq.pending_address==6'(k))?b.u_obj.u_pfq.pending_data:b.u_obj.u_pfq.mem[k]))$fatal(1,"coupled2D PFQ logical state mismatch");
end
always @(posedge clk) if(rst) begin
fwd_mc<=0;fwd_bt<=0;fwd_ot<=0;fwd_pf<=0;pf_full<=0;pf_replace<=0;held<=0;scrub_writes<=0;olb_writes<=0;
end else begin
''')
for counter,path in [('fwd_mc','u_bg.u_mc.g_tt.g_tm.u_tag'),('fwd_bt','u_bg.u_tc.g_tt.g_tm.u_tag'),('fwd_ot','u_obj.u_tc.g_tt.g_tm.u_tag'),('fwd_pf','u_obj.u_pfq')]:
 top.append(f'{counter}<={counter}+32\'(b.{path}.pending_we&&b.{path}.pending_address==b.{path}.raddr);')
top.append('''pf_full<=pf_full+32'(a.u_obj.pf_n==64);
pf_replace<=pf_replace+32'(a.u_obj.pf_push&&a.u_obj.pf_n==1&&a.u_obj.pf_pop);
held<=held+32'(stat_bg_stall_a||stat_obj_stall_a);
scrub_writes<=scrub_writes+32'(a.u_bg.u_mc.g_tt.tag_we&&!a.u_bg.u_mc.fill_we);
olb_writes<=olb_writes+32'(a.o_olb_we);
end
endmodule
''')
(out/'wrapper.sv').write_text('\n'.join(top));(out/'driver.cpp').write_bytes((ROOT/'sim/gpu2d/olddata_mlab/coupled.cpp').read_bytes())
files=[ROOT/'rtl/gpu2d/gpu2d_pkg.sv',ROOT/'rtl/ds/nds_ram.sv']+[ROOT/f'rtl/gpu2d/gpu2d_{n}.sv' for n in ['ram','cache','bg','obj']]+[ROOT/'rtl/gpu2d/gpu2d.sv']
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_od_2d','--Mdir',str(out/'obj'),'-CFLAGS',f'-std=c++20 -O1 -I{ROOT}/sim/gpu2d']+list(map(str,files+oldfiles+[out/'wrapper.sv',out/'driver.cpp']))
with (out/'build.log').open('w') as log:r=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
if r.returncode:raise SystemExit(f'BUILD_FAIL:{r.returncode}')
print('COUPLED_BUILD_PASS',flush=True)
with (out/'run.log').open('w') as log:r=subprocess.run([str(out/'obj/Vtb_od_2d')],cwd=out,stdout=log,stderr=subprocess.STDOUT)
print((out/'run.log').read_text(),flush=True)
rec={'before':'23cae397','exit':r.returncode,'pid':os.getpid(),'starttime':Path('/proc/self/stat').read_text().split()[21],'nice':os.getpriority(os.PRIO_PROCESS,0),'jobs':1,'threads':1,'command':cmd,'source_hashes':{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files},'fixture_hashes':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in oldfiles+[out/'wrapper.sv',out/'driver.cpp']}}
(out/'receipt.json').write_text(json.dumps(rec,indent=2)+'\n')
with tarfile.open(out/'evidence.tar.gz','w:gz') as tar:
 for f in sorted(out.iterdir()):
  if f.is_file() and f.name!='evidence.tar.gz':tar.add(f,arcname=f.name)
raise SystemExit(r.returncode)
