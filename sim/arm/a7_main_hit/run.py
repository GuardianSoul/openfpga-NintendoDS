#!/usr/bin/env python3
"""One allocated NI10/j1/t1 worker for actual ARM7 MAIN hit service."""
from pathlib import Path
import hashlib,json,os,re,resource,subprocess,sys,time
R=Path(__file__).resolve().parents[3];G=R/'build/a7-main-hit-v2';G.mkdir(parents=True,exist_ok=True);os.chdir(R)
assert '--allocated'in sys.argv;os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
sys.path.insert(0,str(R/'sim/arm/ncnb_store'));from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(R/'sim/arm/ncnb_store/sim_ownership.py')=='64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003'
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
controller=G/('controller-baseline.json'if'--baseline-only'in sys.argv else'controller-final.json')
(G/'release').unlink(missing_ok=True);save(controller,dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,0)));print('GATED',controller.read_text(),flush=True)
while '--await-release'in sys.argv and not(G/'release').exists():time.sleep(.2)
def call(cmd,log,allowed=False):
 guard();cmd=list(map(str,cmd))
 with log.open('w')as out:
  p=subprocess.Popen(cmd,stdout=out,stderr=subprocess.STDOUT)
  with(G/'processes.jsonl').open('a')as f:f.write(json.dumps(dict(pid=p.pid,starttime=Path('/proc',str(p.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,p.pid),cmd=cmd,log=str(log)))+'\n')
  rc=wait_owned(p)
 if not allowed:assert rc==0,(str(log),rc,log.read_text()[-2500:])
 return rc
BASE='fde39b6c'
FILES=['rtl/arm/arm_pkg.sv','rtl/arm/arm_thumb.sv','rtl/arm/arm_mul.sv','rtl/arm/arm7_ds.sv','rtl/ds/nds_arm7_port.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_mr_arb.sv','rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/mem/psx_pq_psram.sv','rtl/pocket/nds_psram.sv','sim/phase1/cram_model.sv','sim/phase1/sim_prims.sv']
def build(n):
 d=G/n;d.mkdir(exist_ok=True);inputs=[]
 for rel in FILES+['sim/arm/a7_main_hit/transport.sv','sim/arm/a7_main_hit/tb.sv']:
  b=subprocess.check_output(['git','show',BASE+':'+rel])if n=='before'and rel in FILES else(R/rel).read_bytes()
  if n=='payload-fault'and rel=='rtl/ds/nds_fabric.sv':
   a=b'answer = a7_hit_done ? lb_q :';assert b.count(a)==1;b=b.replace(a,b"answer = a7_hit_done ? (lb_q ^ 32'd1) :")
  if n=='miss-fault'and rel=='rtl/ds/nds_fabric.sv':
   a=b'&& !sd_busy && be == 4\'hF && addr[1:0] == 2\'d0 && lb_hit_raw;';assert b.count(a)==1;b=b.replace(a,b"&& !sd_busy && be == 4'hF && addr[1:0] == 2'd0;")
  p=d/rel;p.parent.mkdir(parents=True,exist_ok=True)
  if p.exists():assert p.read_bytes()==b,p
  else:p.write_bytes(b)
  inputs.append(p)
 m=d/'Vtb_main'
 if not m.exists():
  cmd=['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb_main','--Mdir',d]
  if n!='before':cmd+=['+define+NEW_HIT','-GHIT='+str(int(n!='off'))]
  call(cmd+inputs,d/'build.log');save(d/'model.json',dict(sha256=sha(m),inputs={str(p):sha(p)for p in inputs}))
  for p in d.iterdir():
   if p.is_file()and p.suffix!='.sv'and p.name not in ['Vtb_main','model.json','build.log']:p.unlink()
 return m
def program(code,count,offset):
 stem=G/f'program-{code:x}';elf=stem.with_suffix('.elf');binary=stem.with_suffix('.bin')
 if not elf.exists():
  call(['clang','--target=arm-none-eabi','-march=armv4t','-fuse-ld=lld','-nostdlib','-Wl,-Ttext='+hex(code),'-Wl,--entry=_start',R/'sim/arm/a7_main_hit/program.s','-o',elf],G/f'program-{code:x}-build.log')
  call(['llvm-objcopy','-O','binary',elf,binary],G/f'program-{code:x}-objcopy.log')
 syms={l.split()[-1]:int(l.split()[0],16)for l in subprocess.check_output(['llvm-nm',elf],text=True).splitlines()if len(l.split())==3}
 b=bytearray(binary.read_bytes());assert len(b)%4==0
 def patch(name,v):p=syms[name]-code;b[p:p+4]=v.to_bytes(4,'little')
 patch('loop_count',0xe3a0a000|count);patch('data_address',0x02010000+offset)
 image=G/f'code{code:x}-n{count}-o{offset}.hex';image.write_text(''.join(f'{int.from_bytes(b[i:i+4],"little"):08x}\n'for i in range(0,len(b),4)))
 return image,syms
def run(n,code,count,offset,pressure,phase,resetmode=0):
 m=build(n);image,s=program(code,count,offset);stem=G/(f'{n}-code{code:x}-n{count}-o{offset}-p{pressure}-phase{phase}'+(f'-reset{resetmode}'if resetmode else''))
 if '--resume'in sys.argv and stem.with_suffix('.log').exists():rc=0
 else:rc=call([m,'+img='+str(image),'+out='+str(stem),'+start='+hex(s['_start'])[2:],'+begin='+hex(s['body_begin'])[2:],'+end='+hex(s['body_end'])[2:],'+done='+hex(s['done'])[2:],'+fail='+hex(s['fail'])[2:],f'+pressure={pressure}',f'+phase={phase}',f'+resetmode={resetmode}'],stem.with_suffix('.log'),n.endswith('fault'))
 t=stem.with_suffix('.log').read_text()
 if n.endswith('fault'):return rc,t,stem
 if resetmode:
  assert'MAIN_RESET_PASS'in t;return dict(reset=resetmode,summary=re.findall(r'^MAIN_RESET_PASS .*$',t,re.M)),stem
 x=re.search(r'MAIN_HIT_PASS cycles(\d+) body(\d+) states(\d+) data(\d+) hit(\d+) miss(\d+) blocked(\d+) reads(\d+) words(\d+) writes(\d+) early(\d+)',t);assert x,(n,t[-2000:])
 return dict(zip('cycles body states data hit miss blocked reads words writes early'.split(),map(int,x.groups()))),stem
if '--baseline-only'in sys.argv:
 results={}
 for count in [4,16]:
  a,p=run('before',0x03808000,count,0,0,0);results[str(count)]=a;print('HELD_BASELINE',count,a,flush=True)
 save(G/'held-baseline.json',results);print('HELD_BASELINE_COMPLETE',flush=True);sys.exit(0)
results={}
cases=[(0x03808000,c,o,p,phase)for c in [4,16]for o in [0,4,8,12]for p,phase in [(0,0),(1,1),(1,17)]]+[(0x02080000,c,o,0,0)for c in [4,16]for o in [0,12]]+[(0x03808000,4,0,0,0,r)for r in [1,2]]
for args in cases:
 a,pa=run('before',*args);d,pd=run('off',*args);b,pb=run('on',*args)
 assert a==d
 for ext in ['state','data','edge','owner','physical']:assert pa.with_suffix('.'+ext).read_bytes()==pd.with_suffix('.'+ext).read_bytes(),('default',args,ext)
 if len(args)<6:
  for ext in ['state','data','physical']:assert pa.with_suffix('.'+ext).read_bytes()==pb.with_suffix('.'+ext).read_bytes(),('paired',args,ext)
  assert b['body']<=a['body'] and b['miss']==a['miss'] and b['reads']==a['reads'] and b['words']==a['words'] and b['early']>0
 else:assert a==b
 results[pa.stem.removeprefix('before-')]=dict(input=args,before=a,off=d,on=b);save(G/'qualification.json',dict(source=sha(R/'rtl/ds/nds_fabric.sv'),cases=results));print('MAIN_HIT_CHECK',args,a,b,flush=True)
faults={}
for n in ['payload-fault','miss-fault']:
 rc,t,p=run(n,0x03808000,4,0,0,0);assert rc!=0 and 'timeout'not in t.lower() and ('actual CPU MAIN payload'if n=='payload-fault'else'early ACK without coherent held hit')in t
 faults[n]=dict(returncode=rc,errors=[l for l in t.splitlines()if'%Fatal:'in l],log_sha256=sha(p.with_suffix('.log')));save(G/'faults.json',faults);print('MAIN_HIT_FAULT_CAUGHT',n,faults[n],flush=True)
save(G/'complete.json',dict(source=sha(R/'rtl/ds/nds_fabric.sv'),cases=len(results),faults=faults));print('MAIN_HIT_COMPLETE',flush=True)
