#!/usr/bin/env python3
"""Seal original d1df frontend publication oracle and actual pair/item faults.
No architecture change or game/native baseline is executed here.
"""
from pathlib import Path
import fcntl,hashlib,importlib.util,json,os,re,resource,shutil,subprocess,time
R=Path(__file__).resolve().parents[3];B=R/'build/raster-symptoms/edge-span-original-v4';REF='d1df8af11bd158735eac8ea04f963e23fc26431b'
spec=importlib.util.spec_from_file_location('poolcheck',R/'sim/gpu3d/cache_pool/check.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c);c.B=B
os.setpriority(os.PRIO_PROCESS,0,max(10,os.getpriority(os.PRIO_PROCESS,0)));resource.setrlimit(resource.RLIMIT_CORE,(0,0));assert not B.exists();B.mkdir()
def mod(s,n):
 a=s.index('module '+n+' #(');return s[a:s.index('endmodule',a)+9]+'\n'
libs=['gpu3d_pkg.sv','gpu3d_div4.sv','gpu3d_ram.sv','gpu3d_edge.sv','gpu3d_front.sv','gpu3d_fpass.sv','gpu3d_raster.sv','gpu3d_factor_pump.sv','gpu3d_line_pool.sv','gpu3d_tpf.sv'];src={}
for n in libs:
 data=subprocess.check_output(['git','show',REF+':rtl/gpu3d/'+n],cwd=R);(B/n).write_bytes(data);src[n]=data.decode()
edge=mod(src['gpu3d_edge.sv'],'gpu3d_edge');needle='assign it_k  = pk;';fault='assign it_k  = pk ^ 4\'(STAGE == 2 && $test$plusargs("wrong_item_owner"));';assert edge.count(needle)==1;ep=edge.replace(needle,fault);assert ep.replace(fault,needle)==edge;(B/'edge_probe.sv').write_text(ep.replace('module gpu3d_edge #(','module edge_probe #(',1))
front=mod(src['gpu3d_front.sv'],'gpu3d_front');needle="ar_data = {(a < b) ? a[15:0] : b[15:0], 17'((a < b) ? b - a : a - b)};";fault=needle+'\n        ar_data[0] = ar_data[0] ^ $test$plusargs("wrong_pair_value");';assert front.count(needle)==1;fp=front.replace(needle,fault);assert fp.replace(fault,needle)==front;(B/'front_probe.sv').write_text(fp.replace('module gpu3d_front #(','module front_probe #(',1).replace('gpu3d_edge #(','edge_probe #('))
raster=mod(src['gpu3d_raster.sv'],'gpu3d_raster');rp=raster.replace('module gpu3d_raster #(','module raster_probe #(',1).replace('gpu3d_front #(','front_probe #(');(B/'raster_probe.sv').write_text(rp)
header=raster[:raster.index('\n);')+3];clean=re.sub(r'//[^\n]*','',header);params=re.findall(r'parameter\s+(?:bit|int)\s+(\w+)\s*=',clean);ports=re.findall(r'\b(input|output)\s+logic\s*(\[[^\]]+\])?\s*(\w+)',clean);assert len(ports)>35
body=[f'wire {w} gold_{n};'for d,w,n in ports if d=='output'];par=','.join(f'.{n}({n})'for n in params)
for label,module in [('gold','gpu3d_raster'),('probe','raster_probe')]:
 con=','.join(f'.{n}({"gold_"if d=="output"and label=="gold"else""}{n})'for d,w,n in ports);body.append(f'{module} #({par})u_{label}({con});')
body.append('''
longint checks=0,items=0,pairs=0,spans=0,three_active=0,two_issue=0,vertex_writes_while_s2=0;
longint raw_sys=0,raw_fast=0;
always @(posedge clk)raw_sys++;always @(posedge clk_2x)raw_fast++;
always @(negedge clk_2x)if(raw_fast!=2*raw_sys+(clk?0:1))$fatal(1,"ORIGINAL_PUBLICATION_CLOCK_RATIO");
always @(posedge clk)if(!rst)begin
 checks++;
 if(u_gold.u_front.b_it_we!==u_probe.u_front.b_it_we)$fatal(1,"ORIGINAL_PUBLICATION_FAIL item_date");
 if(u_gold.u_front.b_it_we)begin
  items++;
  if({u_gold.u_front.b_it_k,u_gold.u_front.b_it_v}!=={u_probe.u_front.b_it_k,u_probe.u_front.b_it_v})$fatal(1,"ORIGINAL_PUBLICATION_FAIL item_owner_or_value");
 end
 if(u_gold.ar_we!==u_probe.ar_we)$fatal(1,"ORIGINAL_PUBLICATION_FAIL pair_date");
 if(u_gold.ar_we)begin
  pairs++;
  if({u_gold.ar_wk,u_gold.ar_data,u_gold.ar_left}!=={u_probe.ar_wk,u_probe.ar_data,u_probe.ar_left})$fatal(1,"ORIGINAL_PUBLICATION_FAIL pair_value");
 end
 if(u_gold.fe_wr!==u_probe.fe_wr)$fatal(1,"ORIGINAL_PUBLICATION_FAIL span_date");
 if(u_gold.fe_wr)begin spans++;if(u_gold.fe_desc!==u_probe.fe_desc)$fatal(1,"ORIGINAL_PUBLICATION_FAIL span_value");end
 if(u_gold.u_front.eu_b&&u_gold.u_front.eu_bb&&u_gold.u_front.ss!=u_gold.u_front.SS_IDLE)three_active++;
 if(u_gold.u_front.g_ep2.u_edgeb.xs==u_gold.u_front.g_ep2.u_edgeb.X_IP&&u_gold.u_front.g_ep2.u_edgeb.k<=5&&u_gold.u_front.ss==u_gold.u_front.SS_ATTR&&u_gold.u_front.at_k<5)two_issue++;
 if(u_gold.u_front.vm_we&&u_gold.u_front.eu_bb)vertex_writes_while_s2++;
end
final $display("ORIGINAL_PUBLICATION_COUNTS SYS%0d items%0d pairs%0d spans%0d threeActive%0d simultaneousItems%0d vertexWritesWhileS2%0d",checks,items,pairs,spans,three_active,two_issue,vertex_writes_while_s2);
''')
for d,w,n in ports:
 if d=='output':
  gate={'px_x':'px_valid','px_y':'px_valid','px_color':'px_valid','tex_addr':'tex_req','pal_addr':'pal_req','pf_a':'pf_v','ll_q':'ll_ack','ps_line_y':'ps_line_req'}.get(n,'1');body.append(f'always @(negedge clk)if(!rst&&({gate})&&{n}!==gold_{n})$fatal(1,"ORIGINAL_PUBLICATION_FAIL public_{n}");')
(B/'tb.sv').write_text(header.replace('module gpu3d_raster #(','module publication_tb #(',1)+'\n'+'\n'.join(body)+'\nendmodule\n')
driver=(R/'sim/gpu3d/tb_gpu3d.cpp').read_text().split('int main(')[0];driver=driver.replace('#include "Vgpu3d_raster.h"','#include "Vpublication_tb.h"').replace('using Top = Vgpu3d_raster;','using Top = Vpublication_tb;')
for n in ['0','1']:
 old=f'm->clk = {n}; m->eval();';assert old in driver;new=f'm->clk={n};m->clk_2x=1;m->eval();m->clk_2x=0;m->eval();';driver=driver.replace(old,new)
driver=driver.replace('    tick(); tick();','    m->clk=0;m->clk_2x=0;m->eval();\n    tick(); tick();',1)
driver+='''
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);auto s=builtin_scenes();
for(unsigned i=0;i<8;i++)s.push_back(random_mix_scene(0x5eab1000u+i));
uint64_t clocks=0,spans=0;for(auto&x:s){auto z=render_rtl(x,23,false,0x315u);if(z.timeout)return 2;clocks+=z.cycles;spans+=z.spans;}
printf("PASS_ORIGINAL_PUBLICATION scenes=%zu clocks=%llu spans=%llu\\n",s.size(),(unsigned long long)clocks,(unsigned long long)spans);return 0;}
''';(B/'main.cpp').write_text(driver)
g=(R/'sim/gpu3d/golden.cpp').read_text();derive=g[g.index('PolyDerived derive('):g.index('\n}\nnamespace melonDS')];(B/'derive.cpp').write_text('#include "scene.h"\nnamespace g3d {\n'+derive+'\n}\n');shutil.copyfile(R/'sim/gpu3d/scenes.cpp',B/'scenes.cpp');shutil.copyfile(R/'sim/gpu3d/scene.h',B/'scene.h')
files=[B/n for n in libs]+[B/n for n in ['edge_probe.sv','front_probe.sv','raster_probe.sv','tb.sv','main.cpp','derive.cpp','scenes.cpp']]
profile=dict(LINE_POOL=1,Q0_PUMP=1,ATTR_RAM=1,TXD=5,PXD=5,VREG=1,LOV=1,EDIV4=1,EP2=1,FDB=1,SPO=0,FPSKIP=1,TRU=1,TRUL=1,FPCLR=1,LLR=1)
snapshot=dict(source=REF,profile=profile,probe_inverse_exact=True,frozen_unix=time.time(),inputs={p.name:c.H(p)for p in files+[B/'scene.h']});c.put(B/'snapshot.json',snapshot)
for p in files+[B/'scene.h']:p.chmod(0o444)
cmd=[c.V,'--cc','--exe','--build','--no-timing','--assert','-j','1','--threads','1','-Wno-fatal','--compiler','clang','-CFLAGS','-std=c++20 -O1 -I'+str(B),'-MAKEFLAGS','CXX=clang++ VM_PARALLEL_BUILDS=1','--top-module','publication_tb','--Mdir',B/'obj',*['-G'+k+'='+str(v)for k,v in profile.items()],*files]
with(Path.home()/'.cache/nds-sim-build.lock').open('a')as f:
 c.status(phase='EDGE_SPAN_ORIGINAL_BUILD_MUTEX_WAIT',workers=[]);fcntl.flock(f,fcntl.LOCK_EX);c.guard();rc,t=c.worker('build',cmd);assert rc==0,t[-4500:]
c.put(B/'model.json',dict(sha256=c.H(B/'obj/Vpublication_tb'),snapshot_sha256=c.H(B/'snapshot.json')))
cache=[]
for p in(B/'obj').iterdir():
 if p.suffix in ['.o','.a','.gch']:
  cache.append(dict(path=str(p),bytes=p.stat().st_size,sha256=c.H(p)));p.unlink()
c.put(B/'compiler-cache-cleanup.json',dict(entries=cache,reason='Own finished compiler intermediates only; model and frozen inputs retained'))
r={}
for tag,args,marker in [('positive',[],None),('pair-fault',['+wrong_pair_value'],'ORIGINAL_PUBLICATION_FAIL pair_value'),('item-fault',['+wrong_item_owner'],'ORIGINAL_PUBLICATION_FAIL item_owner_or_value')]:
 rc,t=c.worker(tag,[B/'obj/Vpublication_tb',*args]);ok=(rc!=0 and marker in t)if marker else(rc==0 and'PASS_ORIGINAL_PUBLICATION'in t);r[tag]=dict(passed=ok,exit=rc,tail=t.splitlines()[-4:]);c.put(B/'result.json',dict(result='IN_PROGRESS',cases=r));assert ok,t[-4500:]
c.put(B/'result.json',dict(result='PASS_ORIGINAL_PUBLICATION_AND_TWO_ACTUAL_FAULTS',cases=r,scope='Original fixed source oracle only; new compute architecture not yet implemented/qualified.'));print('PASS_ORIGINAL_PUBLICATION_AND_TWO_ACTUAL_FAULTS')
