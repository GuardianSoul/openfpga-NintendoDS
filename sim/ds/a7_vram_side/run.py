#!/usr/bin/env python3
"""One allocated worker for actual ARM7/P7 and CAP_CHAIN1 endpoint proof."""
from pathlib import Path
import os,sys,json,hashlib,subprocess,resource,time,re
R=Path(__file__).resolve().parents[3];G=R/'build/a7-vram-side-v6';G.mkdir(parents=True,exist_ok=True);os.chdir(R);assert'--allocated'in sys.argv
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));sys.path.insert(0,str(R/'sim/arm/ncnb_store'));from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(R/'sim/arm/ncnb_store/sim_ownership.py')=='64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003'
def save(p,d):p.write_text(json.dumps(d,indent=2)+'\n')
(G/'release').unlink(missing_ok=True);save(G/'controller.json',dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,0)));print('GATED',(G/'controller.json').read_text(),flush=True)
while'--await-release'in sys.argv and not(G/'release').exists():time.sleep(.2)
def call(cmd,log,allowed=False):
 guard();cmd=list(map(str,cmd))
 with log.open('w')as out:
  p=subprocess.Popen(cmd,stdout=out,stderr=subprocess.STDOUT)
  with(G/'processes.jsonl').open('a')as f:f.write(json.dumps(dict(pid=p.pid,starttime=Path('/proc',str(p.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,p.pid),cmd=cmd,log=str(log)))+'\n')
  rc=wait_owned(p)
 if not allowed:assert rc==0,(str(log),rc,log.read_text()[-3000:])
 return rc
BASE='0c5cec2a'
FILES=['rtl/arm/arm_pkg.sv','rtl/gpu2d/gpu2d_pkg.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/ds/nds_ram.sv','rtl/sys/sys_ram.sv','rtl/ds/nds_lcache.sv','rtl/arm/arm_thumb.sv','rtl/arm/arm_mul.sv','rtl/arm/arm7_ds.sv','rtl/ds/nds_arm7_port.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_vram.sv','rtl/pocket/nds_x2b.sv','rtl/pocket/nds_cdc.sv','rtl/pocket/nds_sdram_bus.sv','sim/phase1/sim_prims.sv']
def build(n):
 d=G/n;d.mkdir(exist_ok=True);inputs=[]
 for rel in FILES:
  b=subprocess.check_output(['git','show',BASE+':'+rel])if n=='before'else(R/rel).read_bytes()
  if n=='wrong-owner'and rel=='rtl/ds/nds_fabric.sv':
   a=b'assign a9_ack = ls_end_ack ||';assert b.count(a)==1;b=b.replace(a,b'assign a9_ack = v7_end || ls_end_ack ||')
  if n=='duplicate'and rel=='rtl/ds/nds_fabric.sv':
   a=b'else if (v7_end) v7_live <= 1\'b0;';assert b.count(a)==1;b=b.replace(a,b'else if (v7_end) v7_live <= 1\'b1;')
  p=d/rel;p.parent.mkdir(parents=True,exist_ok=True)
  if p.exists():assert p.read_bytes()==b
  else:p.write_bytes(b)
  inputs.append(p)
 p=d/'tb.sv';b=(R/'sim/ds/a7_vram_side/tb.sv').read_bytes()
 if p.exists():assert p.read_bytes()==b
 else:p.write_bytes(b)
 inputs.append(p);m=d/'Vtb_side'
 if not m.exists():
  cmd=['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb_side','--Mdir',d]
  if n!='before':cmd+=['+define+NEW_SIDE','-GSIDE='+str(int(n!='off'))]
  call(cmd+inputs,d/'build.log');save(d/'model.json',dict(sha256=sha(m),inputs={str(p):sha(p)for p in inputs}))
  for p in d.iterdir():
   if p.is_file()and p.suffix!='.sv'and p.name not in ['Vtb_side','model.json','build.log']:p.unlink()
 return m
program=G/'program';call(['clang','--target=arm-none-eabi','-march=armv4t','-fuse-ld=lld','-nostdlib','-Wl,-Ttext=0x03808000','-Wl,--entry=_start',R/'sim/ds/a7_vram_side/program.s','-o',program.with_suffix('.elf')],G/'program-build.log')
call(['llvm-objcopy','-O','binary',program.with_suffix('.elf'),program.with_suffix('.bin')],G/'program-objcopy.log');b=program.with_suffix('.bin').read_bytes();assert len(b)%4==0;program.with_suffix('.hex').write_text(''.join(f'{int.from_bytes(b[i:i+4],"little"):08x}\n'for i in range(0,len(b),4)))
symbols={l.split()[-1]:l.split()[0]for l in subprocess.check_output(['llvm-nm',program.with_suffix('.elf')],text=True).splitlines()if len(l.split())==3}
def run(n,pressure,late,owner,phase,**options):
 m=build(n);tag=f'{n}-p{pressure}-late{late}-owner{owner}-phase{phase}'+''.join(f'-{k}{v}'for k,v in sorted(options.items()));p=G/tag
 baseline_stress=(pressure,late,owner,phase)==(1,1,1,64)and not options
 if '--resume'in sys.argv and p.with_suffix('.log').exists():
  s=p.with_suffix('.log').read_text();assert 'PASS_'in s or '%Fatal:'in s;rc=int('%Fatal:'in s)
 else:
  rc=call([m,'+img='+str(program.with_suffix('.hex')),'+out='+str(p),'+begin='+symbols['body_begin'],'+done='+symbols['done'],'+fail='+symbols['fail'],f'+pressure={pressure}',f'+late={late}',f'+owner={owner}',f'+phase={phase}',*[f'+{k}={v}'for k,v in options.items()]],p.with_suffix('.log'),n in ['wrong-owner','duplicate']or baseline_stress);s=p.with_suffix('.log').read_text()
 if n in ['wrong-owner','duplicate']:return rc,s,p
 if baseline_stress and rc:
  assert '2D outstanding fixed197 deadline'in s and'timeout'not in s.lower();return dict(status='baseline-stress-deadline-failed',reason='2D outstanding fixed197 deadline'),p
 if options.get('resetmode'):
  assert'PASS_RESET'in s and'timeout'not in s.lower(),(tag,s[-2000:]);return dict(reset=options['resetmode'],summary=re.findall(r'^PASS_RESET .*$',s,re.M)),p
 assert'PASS_SIDE'in s and'timeout'not in s.lower(),(tag,s[-2000:]);x=re.search(r'PASS_SIDE CPUend(\d+) states(\d+) writes(\d+) physical(\d+) capture(\d+) Gpairs(\d+) Gmax(\d+) MAINanswers(\d+) side(\d+)/(\d+) outlives(\d+)',s);assert x
 return dict(zip(['CPUend','states','writes','physical','capture','Gpairs','Gmax','MAINanswers','side_start','side_end','outlives'],map(int,x.groups()))),p
results={}
cases=[((0,0,1,1),{})]+[((1,0,o,p),{})for o in [1,3]for p in [1,17,64,133,196]]+[((1,1,1,p),{})for p in [0,64]]
cases += [((1,0,1,1),dict(hostwrite=1)),((1,1,1,0),dict(nextwrite=1)),((1,1,1,0),dict(snwrite=1)),((1,1,1,0),dict(dma=1)),((1,0,1,1),dict(resetmode=1)),((1,1,1,0),dict(resetmode=2))]
for args,options in cases:
 a,pa=run('before',*args,**options);d,pd=run('off',*args,**options);b,pb=run('on',*args,**options)
 assert a==d,('default summaries',args,options)
 for suffix in ['state','data','edge','mon','physical']:assert pa.with_suffix('.'+suffix).read_bytes()==pd.with_suffix('.'+suffix).read_bytes(),('default exact',args,options,suffix)
 if a.get('status'):
  save(G/'baseline-failures.json',dict(input=dict(args=args,options=options),before=a,off=d,on=b,qualified=False));print('BASELINE_STRESS_UNQUALIFIED',args,a,b,flush=True);continue
 if not options.get('resetmode'):
  assert pa.with_suffix('.state').read_bytes()==pb.with_suffix('.state').read_bytes(),('CPUstate',args,options)
  assert pa.with_suffix('.data').read_bytes()==pb.with_suffix('.data').read_bytes(),('CPUdata',args,options)
  for master in ['0 ','1 ','2 ','3 ']:
   lines=lambda p:[l for l in p.with_suffix('.mon').read_text().splitlines()if l.startswith(master)]
   assert lines(pa)==lines(pb),('per-owner writeorder',args,options,master)
  if not args[0]or options.get('hostwrite'):assert a==b and pa.with_suffix('.edge').read_bytes()==pb.with_suffix('.edge').read_bytes()
  else:assert b['side_start']>0 and b['side_start']==b['side_end']
 results[pa.stem.removeprefix('before-')]=dict(input=dict(args=args,options=options),before=a,off=d,on=b)
 save(G/'qualification.json',dict(source=sha(R/'rtl/ds/nds_fabric.sv'),cases=results));print('SIDE_CHECK',args,options,a,b,flush=True)
faults={}
for n in ['wrong-owner','duplicate']:
 rc,s,p=run(n,1,0,1,1);assert rc!=0 and'timeout'not in s.lower()
 errors=[l for l in s.splitlines()if'%Fatal:'in l or'%Error:'in l];assert errors,(n,s[-2000:])
 faults[n]=dict(returncode=rc,errors=errors,log_sha256=sha(p.with_suffix('.log')));save(G/'faults.json',faults);print('SIDE_FAULT_CAUGHT',n,errors,flush=True)
save(G/'complete.json',dict(source=sha(R/'rtl/ds/nds_fabric.sv'),cases=len(results),faults=faults));print('SIDE_QUALIFICATION_COMPLETE',flush=True)
