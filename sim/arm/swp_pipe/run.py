#!/usr/bin/env python3
"""One NI10/j1/t1 real-P7 before/off/on SWP worker; immutable local sources."""
from pathlib import Path
import argparse, datetime, hashlib, json, os, re, resource, shutil, subprocess, time
R = Path(__file__).resolve().parents[3]
P = argparse.ArgumentParser(description=__doc__)
P.add_argument('--output', type=Path, default=R/'build/swp-pipe/unit')
P.add_argument('--verilator', default='build/tools/oss-cad-suite/bin/verilator')
P.add_argument('--status', type=Path)
P.add_argument('--variant', choices=['candidate', 'data-mutant', 'owner-mutant'], default='candidate')
a=P.parse_args();D=a.output.resolve();D.mkdir(parents=True,exist_ok=False)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
(D/'tmp').mkdir();os.environ['TMPDIR']=str(D/'tmp')
sha=lambda b:hashlib.sha256(b).hexdigest()
q=dict(base='4f022c633ee35d63308d84c09f35312650506460',variant=a.variant,controller=os.getpid(),stages=[],cases={})
def save():(D/'results.json').write_text(json.dumps(q,indent=2)+'\n')
def status(phase,p=None):
 if not a.status:return
 s=json.loads(a.status.read_text());s.update(phase='SWP '+phase,updated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),worker=dict(host='Desktop',controller=os.getpid()if p else None,PID=p.pid if p else None,jobs=1 if p else 0,threads=1 if p else 0,NI=10))
 t=a.status.with_suffix('.tmp.'+str(os.getpid()));t.write_text(json.dumps(s,indent=2)+'\n');t.replace(a.status)
def call(cmd,tag,seconds=240):
 cmd=list(map(str,cmd));start=time.monotonic()
 with(D/(tag+'.log')).open('w')as f:
  p=subprocess.Popen(cmd,cwd=R,stdout=f,stderr=subprocess.STDOUT);row=dict(tag=tag,PID=p.pid,starttime=Path('/proc',str(p.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,p.pid),cmd=cmd);q['stages'].append(row);save();status(tag,p);print(tag,p.pid,flush=True)
  try:row['exit']=p.wait(timeout=seconds)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=10);row.update(exit=p.returncode,timeout=True)
 row.update(reaped=True,seconds=round(time.monotonic()-start,3));save();status(tag+' terminal');return row['exit']

S=D/'source';S.mkdir();files=[]
for rel in ['rtl/arm/arm_pkg.sv','rtl/arm/arm_thumb.sv','rtl/arm/arm7_ds.sv','rtl/ds/nds_arm7_port.sv','rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','sim/phase1/sim_prims.sv','sim/arm/swp_pipe/tb.sv']:
 b=(R/rel).read_bytes()
 if rel.endswith('/arm7_ds.sv'):
  old=b"2'd1: if (dm_rq && d_ok) begin ldw <= d_rdata; esub <= 2'd2; end"
  assert b.count(old)==1
  if a.variant=='data-mutant':b=b.replace(old,b"2'd1: if (dm_rq && d_ok) begin ldw <= d_rdata ^ 32'd1; esub <= 2'd2; end")
  if a.variant=='owner-mutant':b=b.replace(old,b"2'd1: if (dm_rq) begin ldw <= d_rdata; esub <= 2'd2; end")
 p=S/Path(rel).name;p.write_bytes(b);files.append(p)
old=subprocess.check_output(['git','show',q['base']+':rtl/arm/arm7_ds.sv'],cwd=R).replace(b'module arm7_ds import',b'module arm7_ds_before import')
p=S/'arm7_ds_before.sv';p.write_bytes(old);files.append(p)
q['sources']={p.name:sha(p.read_bytes())for p in files};save()
assert call([a.verilator,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb','--Mdir',D/'obj',*files],'build')==0,(D/'build.log').read_text()[-2200:]
model=D/'obj/Vtb';q['model_SHA256']=sha(model.read_bytes());save()
clang=shutil.which('clang');linker=shutil.which('ld.lld');objcopy=shutil.which('llvm-objcopy');nm=shutil.which('llvm-nm');assert all([clang,linker,objcopy,nm])
extras='''
 mov r2,#0x55
 str r2,[r4]
 swp r3,r2,[r4]
'''+''.join(f' add r5,r4,#{n}\n swpb r3,r2,[r5]\n'for n in range(4))+'''
 str r4,[r4]
 swp r4,r2,[r4]
 swp r2,r2,[r4]
 swp r3,r4,[r4]
 swp r4,r4,[r4]
 cmp r1,#0
 swpne r3,r2,[r4]
 swpeq r3,r2,[r4]
 ldr r5,ptr
 swp r3,r2,[r5]
 add r7,r3,#1
 ldr r6,mainptr
 swp r3,r2,[r6]
 add r6,r6,#3
 swpb r3,r2,[r6]
 .word 0xe104309f
 .word 0xe104f092
 .word 0xe10f3092
 b skip_pc_data
 .word 0xaabbccdd
skip_pc_data:
'''
def program(loops,full):
 return '.syntax unified\n.arm\n.text\n.global _start,body_begin,body_end,finished,irq_handler\n_start:\n'+''.join(f' mov r{r},#0\n'for r in range(13))+f'''
 ldr sp,stack
 mrs r0,cpsr
 bic r0,r0,#0x80
 msr cpsr_c,r0
 ldr r4,ptr
 mov r0,#0
 mov r10,#{loops}
body_begin:
 mov r11,#0
loop:
'''+(' swp r0,r1,[r4]\n'*64)+'''
 subs r10,r10,#1
 bne loop
body_end:
 mov r11,#1
'''+(extras if full else '')+'''
finished:
 mov r8,#0x66
 b finished
.balign 4
ptr:.word 0x037ff000
mainptr:.word 0x02010000
stack:.word 0x0380f000
irq_handler:
 add r12,r12,#1
 subs pc,lr,#4
'''
cases=[('quiet4',4,False,0),('quiet16',16,False,0),('forms',1,True,0),('retry',1,True,1),('irq',1,True,2),('reset-read',1,True,3),('reset-write',1,True,4)]
if a.variant!='candidate':cases=[('retry',1,True,1)]
for tag,loops,full,scenario in cases:
 folder=D/tag;folder.mkdir();asm=folder/'program.s';asm.write_text(program(loops,full));elf=folder/'program.elf';binary=folder/'program.bin'
 assert call([clang,'--target=armv4t-none-eabi','-mcpu=arm7tdmi','-marm','-nostdlib','-c',asm,'-o',folder/'program.o'],tag+'-asm')==0
 assert call([linker,'-Ttext=0x03808000','--entry=_start',folder/'program.o','-o',elf],tag+'-link')==0
 assert call([objcopy,'-O','binary',elf,binary],tag+'-binary')==0
 names={}
 for line in subprocess.check_output([nm,'-n',elf],text=True).splitlines():
  words=line.split()
  if len(words)==3:names[words[2]]=int(words[0],16)
 b=binary.read_bytes();assert len(b)%4==0
 image=folder/'program.hex';image.write_text(''.join(f'{int.from_bytes(b[n:n+4],"little"):08x}\n'for n in range(0,len(b),4)))
 rc=call([model,'+img='+str(image),'+out='+str(folder/'trace'),'+scenario='+str(scenario),'+begin='+hex(names['body_begin'])[2:],'+end='+hex(names['body_end'])[2:],'+done='+hex(names['finished'])[2:],'+handler='+hex(names['irq_handler'])[2:]],tag)
 log=(D/(tag+'.log')).read_text();row=dict(exit=rc,scenario=scenario,loops=loops,program_SHA256=sha(b),symbols=names)
 q['cases'][tag]=row;save()
 if a.variant=='owner-mutant':
  assert rc!=0 and 'SWP_WRITE_WITHOUT_OWNED_READ'in log,log[-1600:]
  q['caught']='actual premature read completion: write without owned read';save();break
 assert rc==0 and 'SWP_ALL_PASS'in log,log[-2200:]
 matches=re.findall(r'SWP_PASS mode(\d+) scenario\d+ cycles(\d+) body(-?\d+) states(\d+) reads(\d+) writes(\d+)',log)
 assert len(matches)==3
 row['modes']={m:dict(zip(['cycles','body','states','reads','writes'],map(int,v)))for m,*v in matches}
 def trace(mode,kind):return(folder/f'trace-m{mode}.{kind}').read_text().split('RESET\n')[-1]
 for kind in ['state','data','take','mem']:
  assert trace(0,kind)==trace(1,kind),(tag,'default off',kind)
  if a.variant=='data-mutant'and kind=='state':
   assert trace(0,kind)!=trace(2,kind)
   q['caught']='actual captured read payload corruption changes architectural state';save();break
  assert trace(0,kind)==trace(2,kind),(tag,'enabled',kind)
 if a.variant=='data-mutant':break
 assert(folder/'trace-m0.edge').read_bytes()==(folder/'trace-m1.edge').read_bytes(),(tag,'default cycle')
 row['exact']='full32RF/PC/CPSR retirement; data order; actual direct-WRAM takes; complete backing memory; default cycle';save()
if a.variant=='candidate':
 slopes={m:(q['cases']['quiet16']['modes'][m]['body']-q['cases']['quiet4']['modes'][m]['body'])/(12*64*2)for m in ['0','1','2']}
 q['quiet_A7_slopes']=slopes;save();assert slopes=={'0':8.0625,'1':8.0625,'2':4.0625},slopes
q['status']='PASS';save();status(a.variant+' PASS');print(json.dumps({k:v for k,v in q.items()if k not in ['stages','sources','cases']},indent=2),flush=True)
