#!/usr/bin/env python3
"""Original/current complete raster miter with real scene and stalled service traffic."""
from pathlib import Path
import hashlib,json,os,re,resource,subprocess,time
ROOT=Path(__file__).resolve().parents[3];OUT=ROOT/'build/pump72/composed';OUT.mkdir(parents=True,exist_ok=True)
BASE='48282914ebac963e518c9432779b658a92bc4372'
OWNER=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Raster.json')
VER='build/tools/oss-cad-suite/bin/verilator'

def status(phase,p=None):
 v=json.loads(OWNER.read_text());v.update(phase=phase,worker=[],updated_at=time.time())
 if p:v['worker']=[dict(host='D1',pid=p.pid,start=Path(f'/proc/{p.pid}/stat').read_text().split()[21],nice=10,jobs=1,threads=1)]
 t=OWNER.with_suffix('.tmp');t.write_text(json.dumps(v,separators=(',',':'))+'\n');assert t.stat().st_size<=2048;t.replace(OWNER)
def run(cmd,label):
 def limit():os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
 with (OUT/(label+'.log')).open('w')as f:
  p=subprocess.Popen(list(map(str,cmd)),cwd=ROOT,stdout=f,stderr=subprocess.STDOUT,preexec_fn=limit);status('PUMP72_'+label,p);rc=p.wait();status('PUMP72_'+label+'_DONE')
 if rc:raise RuntimeError(f'{label} exit{rc}: '+(OUT/(label+'.log')).read_text()[-3000:])
for name in ['front','raster']:
 s=subprocess.check_output(['git','show',BASE+':rtl/gpu3d/gpu3d_'+name+'.sv'],cwd=ROOT,text=True)
 s=s.replace('module gpu3d_'+name+' #(','module '+name+'_before #(',1)
 if name=='raster':s=s.replace('gpu3d_front #(','front_before #(')
 (OUT/(name+'_before.sv')).write_text(s)
after=(ROOT/'rtl/gpu3d/gpu3d_raster.sv').read_text();header=after[:after.index('\n);')+3];clean=re.sub(r'//[^\n]*','',header)
params=re.findall(r'parameter\s+(?:bit|int)\s+(\w+)\s*=',clean)
ports=re.findall(r'\b(input|output)\s+logic\s*(\[[^\]]+\])?\s*(\w+)',clean)
assert len(ports)>35
body=[]
for direction,width,name in ports:
 if direction=='output':body.append(f'wire {width} before_{name};')
for kind in ['before','after']:
 param=', '.join(f'.{n}({n if n!="DIV_PAIR2X"else"1"})'for n in params if kind=='after'or n!='DIV_PAIR2X')
 connect=', '.join(f'.{n}({"before_"if d=="output"and kind=="before"else""}{n})'for d,w,n in ports if kind=='after'or n!='clk2')
 body.append(f'{"raster_before"if kind=="before"else"gpu3d_raster"} #({param}) u_{kind} ({connect});')
body.append('logic armed=0;\nalways @(negedge clk2) begin\n if(rst) armed<=1;\n if(armed) begin')
for d,w,n in ports:
 if d=='output':body.append(f' if({n} !== before_{n}) $fatal(1,"COMPOSED_MISMATCH {n}");')
body+=[' if(u_before.u_front.st !== u_after.u_front.st || u_before.u_front.ss !== u_after.u_front.ss) $fatal(1,"COMPOSED_MISMATCH front FSM");',' end\nend\nendmodule']
(OUT/'equiv.sv').write_text(header.replace('module gpu3d_raster #(','module raster_equiv #(',1)+'\n'+'\n'.join(body)+'\n')
driver=(ROOT/'sim/gpu3d/tb_gpu3d.cpp').read_text().split('int main(')[0]
driver=driver.replace('#include "Vgpu3d_raster.h"','#include "Vraster_equiv.h"').replace('using Top = Vgpu3d_raster;','using Top = Vraster_equiv;')
for n in ['0','1']:
 old=f'm->clk = {n}; m->eval();';new=f'm->clk = {n}; m->clk2 = 1; m->eval(); m->clk2 = 0; m->eval();';assert old in driver;driver=driver.replace(old,new)
driver+='''
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv); auto scenes=builtin_scenes();
 for(unsigned i=0;i<24;i++)scenes.push_back(random_mix_scene(0x72c01000u+i));
 uint64_t cycles=0,pixels=0,spans=0;
 for(size_t i=0;i<scenes.size();i++){
  auto r=render_rtl(scenes[i],(i%2)?23:0,false,0x72u+i);
  if(r.timeout)return 2;cycles+=r.cycles;pixels+=r.pixels;spans+=r.spans;
  printf("PASS %s cycles=%llu pixels=%llu spans=%llu\\n",scenes[i].name.c_str(),(unsigned long long)r.cycles,(unsigned long long)r.pixels,(unsigned long long)r.spans);fflush(stdout);
 }
 printf("PASS_COMPOSED scenes=%zu clocks=%llu pixels=%llu spans=%llu\\n",scenes.size(),(unsigned long long)cycles,(unsigned long long)pixels,(unsigned long long)spans);return 0;
}
'''
(OUT/'driver.cpp').write_text(driver)
g=(ROOT/'sim/gpu3d/golden.cpp').read_text();derive=g[g.index('PolyDerived derive('):g.index('\n}\nnamespace melonDS')];(OUT/'derive.cpp').write_text('#include "scene.h"\nnamespace g3d {\n'+derive+'\n}\n')
profile=dict(TXD=9,PXD=9,VREG=1,LOV=1,EDIV4=1,SPO=1,EDGE2=1,EP2=1,FPSKIP=1,TRU=1,TRUL=1,FPCLR=1,LLR=1)
cmd=[VER,'--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','raster_equiv','--Mdir',OUT/'obj','-CFLAGS','-std=c++20 -O1 -I'+str(ROOT/'sim/gpu3d')]
cmd+=['-G'+k+'='+str(v)for k,v in profile.items()]
cmd+=[ROOT/'rtl/gpu3d'/n for n in ['gpu3d_pkg.sv','gpu3d_div4.sv','gpu3d_ram.sv','gpu3d_edge.sv','gpu3d_front.sv','gpu3d_fpass.sv','gpu3d_raster.sv']]
cmd+=[OUT/n for n in ['front_before.sv','raster_before.sv','equiv.sv','driver.cpp','derive.cpp']]+[ROOT/'sim/gpu3d/scenes.cpp']
(OUT/'input.json').write_text(json.dumps(dict(base=BASE,profile=profile,command=list(map(str,cmd)),source={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in ROOT.glob('rtl/gpu3d/*.sv')}),indent=2)+'\n')
run(cmd,'COMPOSED_BUILD');run([OUT/'obj/Vraster_equiv'],'COMPOSED_MITER')
(OUT/'result.json').write_text(json.dumps(dict(status='PASS',base=BASE,model_sha256=hashlib.sha256((OUT/'obj/Vraster_equiv').read_bytes()).hexdigest(),summary=(OUT/'COMPOSED_MITER.log').read_text().splitlines()[-1]),indent=2)+'\n')
print((OUT/'result.json').read_text())
