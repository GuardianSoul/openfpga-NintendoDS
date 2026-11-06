#!/usr/bin/env python3
"""Bounded exact DS41 helper/CPU/fabric/SYS trial, one allocated worker."""
from pathlib import Path
import os,sys,json,hashlib,subprocess,resource,time,re,importlib.util,shutil
R=Path(__file__).resolve().parents[3];G=R/'build/io-replay-main40';os.chdir(R);assert'--allocated'in sys.argv
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));sys.path.insert(0,str(R/'sim/arm/ncnb_store'));from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
assert sha(R/'sim/arm/ncnb_store/sim_ownership.py')=='64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003'
def save(p,d):p.write_text(json.dumps(d,indent=2)+'\n')
(G/'release').unlink(missing_ok=True);save(G/'controller.json',dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,0)));print('GATED', (G/'controller.json').read_text(),flush=True)
while'--await-release'in sys.argv and not(G/'release').exists():time.sleep(.2)
def call(cmd,log,allowed=False):
 guard();cmd=list(map(str,cmd))
 with log.open('w')as out:
  p=subprocess.Popen(cmd,stdout=out,stderr=subprocess.STDOUT)
  with(G/'processes.jsonl').open('a')as f:f.write(json.dumps(dict(pid=p.pid,starttime=Path('/proc',str(p.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,p.pid),cmd=cmd))+'\n')
  rc=wait_owned(p)
 if not allowed:assert rc==0,(str(log),rc,log.read_text()[-2000:])
 return rc
FILES=['rtl/arm/'+x+'.sv'for x in 'arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm_cpu'.split()]+['rtl/gpu2d/gpu2d_ram.sv','rtl/ds/nds_ram.sv','rtl/ds/nds_dsp_add.sv']+['rtl/sys/'+x+'.sv'for x in 'sys_ram sys_irq sys_timers sys_ipc sys_math sys_dma nds_sys'.split()]+['rtl/ds/nds_fabric.sv','rtl/ds/nds_io.sv']
BASE='27340ba41414cba3e53c8eab962b733b8a0b2df2'
models={}
names=['timed-off','timed-on']
for n in names:
 d=G/n;d.mkdir(exist_ok=True);inputs=[]
 for f in FILES:
  b=subprocess.check_output(['git','show',BASE+':'+f])if n in ['before','window','stages','mutant','detail']else(R/f).read_bytes()
  if n=='window'and f=='rtl/arm/arm9_mem.sv':b=(G/'window/rtl/arm/arm9_mem.sv').read_bytes()
  if n=='window'and f=='rtl/arm/arm_cpu.sv':
   a=b'arm9_mem #(';assert b.count(a)==1;b=b.replace(a,b"arm9_mem #(.IO_RETRY_WINDOW(1'b1),")
  if n=='mutant'and f=='rtl/arm/arm9_mem.sv':
   a=b'rbuf_d <= b_rdata;';assert b.count(a)==1;b=b.replace(a,b"rbuf_d <= b_rdata ^ ((dp_a[31:24]==8'h04)?32'd1:32'd0);")
  p=d/f;p.parent.mkdir(parents=True,exist_ok=True)
  if p.exists():assert p.read_bytes()==b
  else:p.write_bytes(b)
  inputs.append(p)
 p=d/'tb.sv';tb=(R/'sim/arm/io_retry_window/compose_timed.sv').read_bytes().replace(b'parameter bit REPLAY=0',b'parameter bit REPLAY='+str(int(n=='timed-on')).encode())
 if p.exists():assert p.read_bytes()==tb
 else:p.write_bytes(tb)
 inputs.append(p);model=d/'Vtb_arm'
 if not model.exists():
  call(['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--timescale','1ns/1ps','--top-module','tb_arm','-GARM9_WAYS=4','-GSLOW=1','-GA9_SOLO=1','-GA9_OPT=461366243','-GEVB=1','-GA9_XD=0','-GA9_XI=0','--Mdir',d,*inputs],d/'build.log');save(d/'model.json',dict(sha256=sha(model),inputs={str(p):sha(p)for p in inputs}))
  for p in d.iterdir():
   if p.is_file()and p.suffix!='.sv'and p.name not in ['Vtb_arm','build.log','model.json']:p.unlink()
 receipt=json.loads((d/'model.json').read_text());assert sha(model)==receipt['sha256']
 for p,h in receipt['inputs'].items():assert sha(G/p.split('/build/io-replay-main40/',1)[1])==h
 models[n]=model
results={}
for case in ([0]if ('--stages'in sys.argv or '--detail'in sys.argv)else range(4)):
 stem=G/f'case{case}-program';img=stem.with_suffix('.hex');call(['clang','--target=arm-none-eabi','-march=armv5te','-fuse-ld=lld','-nostdlib','-Wl,-Ttext=0x02000000','-Wl,--entry=_start',G/f'case{case}.s','-o',stem.with_suffix('.elf')],stem.with_suffix('.build.log'));call(['llvm-objcopy','-O','binary',stem.with_suffix('.elf'),stem.with_suffix('.bin')],stem.with_suffix('.objcopy.log'));call(['python3','sim/arm/tools/mkhex.py',img,str(stem.with_suffix('.bin'))+'@0x02000000'],stem.with_suffix('.hex.log'));obs=next(x.split()[0]for x in subprocess.check_output(['llvm-nm',stem.with_suffix('.elf')],text=True).splitlines()if x.endswith(' observed'))
 for n,m in models.items():
  for phase in ([0]if ('--stages'in sys.argv or '--detail'in sys.argv)else [0,1]):
   tag=f'{n}-case{case}-phase{phase}';out=G/tag;call([m,'+img0='+str(img),'+pc0=02000000','+run=1','+blat=2','+maxcycles=200000',f'+phase={phase}','+observed='+obs,'+trace0='+str(out)+'.csv'],out.with_suffix('.log'));t=out.with_suffix('.log').read_text();assert'TEST PASSED'in t,(tag,t[-2000:])
   rows=re.findall(r'^RESULT (\d+) c(\d+) r0(\w+) r1(\w+) r2(\w+) r3(\w+) cpsr(\w+)',t,re.M);assert len(rows)==16,(tag,len(rows))
   raw=[[int(v,16)for v in x[2:6]]for x in rows];pairs=[[(v[1]-v[0])&65535,(v[2]-v[1])&65535]for v in raw];assert all(v[2]==v[3]for v in raw)
   acks=re.findall(r'^IO_ACK (\d+) addr(\w+) data(\w+) WB(\d) pc(\w+) ready(\d)',t,re.M);assert len(acks)==80,(tag,len(acks))
   results[tag]=dict(raw=raw,pairs=pairs,DS_matches=sum(v==[4,5]for v in pairs),ACKs=len(acks),live_WB_at_ACK=sum(int(x[3])for x in acks));save(G/'timed-results.json',dict(source=sha(R/'rtl/arm/arm9_mem.sv'),cases=results))
   print('IO_WINDOW',tag,dict(pairs=sorted(set(map(tuple,pairs))),DS_matches=results[tag]['DS_matches'],ACKs=len(acks),live_WB_at_ACK=results[tag]['live_WB_at_ACK']),flush=True)
print('IO_WINDOW_COMPLETE',flush=True)
