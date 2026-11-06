#!/usr/bin/env python3
"""Reuse the exact qualified models for a 64-op fixed LDM stream risk check."""
from pathlib import Path
import hashlib,json,os,re,resource,subprocess,sys,time
R=Path(__file__).resolve().parents[3];G=R/'build/a7-main-kernel';M=R/'build/a7-main-hit-v2';G.mkdir(parents=True,exist_ok=True);os.chdir(R)
assert '--allocated'in sys.argv;os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
sys.path.insert(0,str(R/'sim/arm/ncnb_store'));from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
(G/'release').unlink(missing_ok=True);save(G/'controller-finish.json',dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,0)));print('GATED',(G/'controller-finish.json').read_text(),flush=True)
while '--await-release'in sys.argv and not(G/'release').exists():time.sleep(.2)
def call(cmd,log):
 guard();cmd=list(map(str,cmd))
 with log.open('w')as out:
  p=subprocess.Popen(cmd,stdout=out,stderr=subprocess.STDOUT)
  with(G/'processes.jsonl').open('a')as f:f.write(json.dumps(dict(pid=p.pid,starttime=Path('/proc',str(p.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,p.pid),cmd=cmd,log=str(log)))+'\n')
  rc=wait_owned(p)
 assert rc==0,(str(log),rc,log.read_text()[-2000:])
s=(R/'sim/arm/a7_main_hit/program.s').read_text();a=s.index('body_begin:\n');b=s.index('body_end:\n');s=s[:a]+'''body_begin:
 .rept 64
 ldmia r0,{r2-r5}
 .endr
 subs r10,r10,#1
 bne body_begin
'''+s[b:];(G/'kernel.s').write_text(s)
call(['clang','--target=arm-none-eabi','-march=armv4t','-fuse-ld=lld','-nostdlib','-Wl,-Ttext=0x03808000','-Wl,--entry=_start',G/'kernel.s','-o',G/'kernel.elf'],G/'assemble.log')
call(['llvm-objcopy','-O','binary',G/'kernel.elf',G/'kernel.bin'],G/'objcopy.log')
syms={l.split()[-1]:int(l.split()[0],16)for l in subprocess.check_output(['llvm-nm',G/'kernel.elf'],text=True).splitlines()if len(l.split())==3};save(G/'symbols.json',syms)
results={}
for count in [4,8]:
 b=bytearray((G/'kernel.bin').read_bytes());p=syms['loop_count']-0x03808000;b[p:p+4]=(0xe3a0a000|count).to_bytes(4,'little');image=G/f'n{count}.hex';image.write_text(''.join(f'{int.from_bytes(b[i:i+4],"little"):08x}\n'for i in range(0,len(b),4)))
 paths={};rows={}
 for n in ['before','off','on']:
  model=M/n/'Vtb_main';meta=json.loads((M/n/'model.json').read_text());assert sha(model)==meta['sha256']
  stem=G/f'{n}-n{count}'
  if not stem.with_suffix('.log').exists():call([model,'+img='+str(image),'+out='+str(stem),'+start='+hex(syms['_start'])[2:],'+begin='+hex(syms['body_begin'])[2:],'+end='+hex(syms['body_end'])[2:],'+done='+hex(syms['done'])[2:],'+fail='+hex(syms['fail'])[2:]],stem.with_suffix('.log'))
  t=stem.with_suffix('.log').read_text();m=re.search(r'MAIN_HIT_PASS cycles(\d+) body(\d+) states(\d+) data(\d+) hit(\d+) miss(\d+) blocked(\d+) reads(\d+) words(\d+) writes(\d+) early(\d+)',t);assert m
  rows[n]=dict(zip('cycles body states data hit miss blocked reads words writes early'.split(),map(int,m.groups())));paths[n]=stem
 assert rows['before']==rows['off']
 for ext in ['state','data','edge','owner','physical']:assert paths['before'].with_suffix('.'+ext).read_bytes()==paths['off'].with_suffix('.'+ext).read_bytes(),(count,ext,'default')
 for ext in ['state','data','physical']:assert paths['before'].with_suffix('.'+ext).read_bytes()==paths['on'].with_suffix('.'+ext).read_bytes(),(count,ext,'paired')
 results[str(count)]=rows;save(G/'results.json',dict(cases=results,models={n:sha(M/n/'Vtb_main')for n in ['before','off','on']}));print('KERNEL_RISK_ROW',count,rows,flush=True)
slopes={n:(results['8'][n]['body']-results['4'][n]['body'])/(4*64*2)for n in ['before','off','on']}
save(G/'complete.json',dict(cases=results,slopes_A7=slopes,DS30_published_centiA7=1504,risk='Compare only as an uncontented 64-op shaped component stream: actual original compiled register allocation/address/helper/runtime not reproduced. Faster-than-DS risk, not native acceptance.',no_DS_wait_added=True));print('KERNEL_RISK_COMPLETE',slopes,flush=True)
