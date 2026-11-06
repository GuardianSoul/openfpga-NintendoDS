#!/usr/bin/env python3
"""Qualify passive MUL metadata: exact old/default/off/on coupled lanes and real RTL faults."""
from pathlib import Path
import argparse,datetime,hashlib,importlib.util,json,os,re,resource,shutil,struct,subprocess,tarfile,time
from meta_lane import lanes
R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--completion-of',type=Path)
p.add_argument('--DS',type=Path,default=Path('/home/user/Git/NDS_Pocket-codex-hwref/build/hwref-ds-lite-sound-mul-20261102'))
p.add_argument('--elf',type=Path,default=Path('/home/user/Git/NDS_Pocket-cpu-a7mulphase/build/a7mulphase-v1/a7mulphase7.elf'))
p.add_argument('--verilator',default='build/tools/oss-cad-suite/bin/verilator');a=p.parse_args()
D=a.output.resolve();D.mkdir(parents=True,exist_ok=False);I=D/'inputs';I.mkdir();S=D/'source';S.mkdir();(D/'tmp').mkdir()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));resource.setrlimit(resource.RLIMIT_CPU,(240,240));resource.setrlimit(resource.RLIMIT_AS,(4*1024**3,4*1024**3));resource.setrlimit(resource.RLIMIT_FSIZE,(512*1024**2,512*1024**2));os.environ['TMPDIR']=str(D/'tmp')
sha=lambda b:hashlib.sha256(b).hexdigest();starttime=lambda pid:Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()[19]
layout=json.loads((a.DS/'mul-layout.json').read_text());DS=json.loads((a.DS/'analysis.json').read_text())
assert DS['status']=='REAL_DS_LITE_SOURCE_LIVE_BYTES_COMPLETION_QUALIFIED_FINITE_MEASUREMENTS'
assert layout['build_id']==DS['MUL_source_id']=='527d33a349d27bd7cd36e365d77afe59d177a5a19d9c2fda2e94da9c0c724273'
assert sha(a.elf.read_bytes())==layout['arm7_elf_SHA256']
sp=importlib.util.spec_from_file_location('matched_elf',R/'sw/hwref/arm7fetch/sdk-check.py');elf=importlib.util.module_from_spec(sp);sp.loader.exec_module(elf)
kernel=elf.elf_symbol(a.elf,'mp_mul')['body'];wrapper=elf.elf_symbol(a.elf,'mp_invoke')['body']
assert len(kernel)==272 and sha(kernel)==layout['code_SHA256']and len(wrapper)==96 and sha(wrapper)==layout['wrapper']['SHA256']
assert struct.unpack('<68I',kernel)[1:65]==(0xe0030291,)*64
for name,value in [('kernel',kernel),('wrapper',wrapper)]:
 (I/(name+'.bin')).write_bytes(value);(I/(name+'.hex')).write_text(''.join(f'{x:08x}\n'for x in struct.unpack('<'+'I'*(len(value)//4),value)))
for n in ['mul-layout.json','mul-protocol.json','analysis.json']:(I/n).write_bytes((a.DS/n).read_bytes())
raw=a.DS/'raw/a7mulphase-v1';(I/'DS-raw').mkdir()
for f in raw.iterdir():
 if f.is_file():(I/'DS-raw'/f.name).write_bytes(f.read_bytes())
result=dict(source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),controller=os.getpid(),controller_starttime=starttime(os.getpid()),
 DS_ROM=DS['ROM_sha256']['a7mulphase.nds'],DS_build_id=layout['build_id'],kernel_SHA256=sha(kernel),wrapper_SHA256=sha(wrapper),stages=[],cases={},source_SHA256={},
 limits='Exact kernel/wrapper/addresses and warm1/4-16/min5; quiet component BL-retire brackets, no DS timer/helper/native equivalence claim. Passive request context only; old/default/off/on exact outputs/state/cycles. No memory service change.',caps=dict(NI=10,jobs=1,threads=1,CPU_seconds_per_process=240,AS_bytes=4*1024**3,build_file_bytes=512*1024**2,model_file_bytes=64*1024**2,build_wall_seconds=180,model_wall_seconds=30))
def save():(D/'results.json').write_text(json.dumps(result,indent=2)+'\n')
status_path=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json')
def status(phase,proc=None):
 q=json.loads(status_path.read_text());q['phase']=phase;q['current_action']='Qualify passive MUL context/public CPU: old/default/off/on coupled state/cycles, adverses and actual RTL faults. P7/fabric frozen.';q['worker']=dict(host='Desktop',active=bool(proc),controller=os.getpid(),PID=proc.pid if proc else None,starttime=starttime(proc.pid)if proc else None,NI=10,jobs=1 if proc else 0,threads=1 if proc else 0);q['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();temp=status_path.with_name('CPU.json.tmp.'+str(os.getpid()));temp.write_text(json.dumps(q,indent=2)+'\n');temp.replace(status_path)
def call(cmd,tag,limit,expected=0):
 cmd=list(map(str,cmd));begin=time.monotonic()
 with(D/(tag+'.log')).open('w')as f:
  model_run=cmd[0].endswith('/Vtb')
  def model_cap():resource.setrlimit(resource.RLIMIT_FSIZE,(64*1024**2,64*1024**2))
  proc=subprocess.Popen(cmd,cwd=R,stdout=f,stderr=subprocess.STDOUT,preexec_fn=model_cap if model_run else None);row=dict(tag=tag,PID=proc.pid,starttime=starttime(proc.pid),NI=os.getpriority(os.PRIO_PROCESS,proc.pid),cmd=cmd);result['stages'].append(row);save();status(tag,proc);print(json.dumps({'tag':tag,'PID':proc.pid}),flush=True)
  try:row['exit']=proc.wait(timeout=limit)
  except subprocess.TimeoutExpired:proc.terminate();proc.wait(timeout=10);row.update(exit=proc.returncode,timeout=True)
 row.update(reaped=True,wall_seconds=round(time.monotonic()-begin,3));save();status(tag+' terminal')
 if expected is not None:assert row['exit']==expected,(tag,(D/(tag+'.log')).read_text()[-2200:])
 return row['exit']
boot='''.syntax unified
.arm
.text
.global _start,timed_call,timed_done,rs_literal,loops_literal,entry_literal,finished,irq_enable
.extern mp_invoke
_start:
 ldr sp,stack_literal
 ldr r0,entry_literal
 mov r1,#1
 ldr r2,rs_literal
 ldr r3,warm_literal
 bl mp_invoke
 ldr r0,entry_literal
 ldr r1,loops_literal
 ldr r2,rs_literal
 ldr r3,timed_literal
timed_call:
 bl mp_invoke
timed_done:
 mov r1,#3
 mov r4,#7
 mla r3,r1,r2,r4
 muls r3,r1,r2
 cmp r1,r1
 mulne r3,r1,r2
 ldr r2,new_rs_literal
 mul r3,r1,r2
 mov r2,#0x7f
 mul r2,r1,r2
 umull r6,r7,r1,r2
finished:
 mov r8,#0x77
 b finished
irq_enable:
 mrs r12,cpsr
 bic r12,r12,#0x80
 msr cpsr_c,r12
 ldr sp,stack_literal
 b _start+4
.balign 4
stack_literal:.word 0x0380e000
warm_literal:.word 0x03802000
timed_literal:.word 0x03802080
entry_literal:.word 0
loops_literal:.word 0
rs_literal:.word 0
new_rs_literal:.word 0x7fff
'''
(I/'boot.s').write_text(boot)
call([shutil.which('clang'),'--target=armv4t-none-eabi','-mcpu=arm7tdmi','-marm','-nostdlib','-c',I/'boot.s','-o',I/'boot.o'],'assemble',30)
call([shutil.which('ld.lld'),'-Ttext=0x03808000','--entry=_start','--defsym=mp_invoke=0x03800750',I/'boot.o','-o',I/'boot.elf'],'link',30)
call([shutil.which('llvm-objcopy'),'-O','binary',I/'boot.elf',I/'boot.bin'],'binary',30)
symbols={w[2]:int(w[0],16)for l in subprocess.check_output([shutil.which('llvm-nm'),'-n',I/'boot.elf'],text=True).splitlines()if len(w:=l.split())==3};result['symbols']=symbols
b=(I/'boot.bin').read_bytes();assert len(b)%4==0;(I/'boot.hex').write_text(''.join(f'{x:08x}\n'for x in struct.unpack('<'+'I'*(len(b)//4),b)))
base_sha='76616273fe9229532d46939be25fe680d18bd816'
rels=['rtl/arm/'+n+'.sv'for n in 'arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm_cpu arm7_ds'.split()]
rels+=['rtl/ds/nds_arm7_port.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_mr_arb.sv','rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/mem/psx_pq_psram.sv','rtl/pocket/nds_psram.sv','sim/phase1/cram_model.sv','sim/phase1/sim_prims.sv']
sources=[]
for n in rels:
 p=S/Path(n).name;p.write_bytes((R/n).read_bytes());sources.append(p);result['source_SHA256'][n]=sha(p.read_bytes())
for name in ['arm_cpu','arm7_ds']:
 value=subprocess.check_output(['git','show',base_sha+':rtl/arm/'+name+'.sv'],cwd=R)
 value=value.replace(('module '+name+' import').encode(),('module '+name+'_before import').encode())
 if name=='arm_cpu':value=value.replace(b'arm7_ds #(',b'arm7_ds_before #(')
 target=S/(name+'_before.sv');target.write_bytes(value);sources.append(target)
donor=R/'docs/results/arm7-data-ack-20261101/proof.tar.gz';assert sha(donor.read_bytes())=='0707d7ca3a716f90dbe0eea6ad968398cd806c22289c77c46a9cd7e794027734'
with tarfile.open(donor)as t:transport=t.extractfile('cpu36/tb.sv').read().decode().split('module cpu_before ')[0]
transport=transport.replace('old_nds_psram #(','nds_psram #(');(S/'transport.sv').write_text(transport);sources.append(S/'transport.sv')
(S/'probe.svh').write_text((R/'sim/arm/stm4_meta/probe.svh').read_text().replace('pins=','pinsn='))
(S/'tb.sv').write_text(lanes(R));sources.append(S/'tb.sv')
for name in ['run_meta.py','meta_lane.py','oracle.svh','tb.sv']:(I/name).write_bytes((R/'sim/arm/a7_mulphase'/name).read_bytes())
result.update(base=base_sha,fixture_SHA256={p.name:sha(p.read_bytes())for p in sources},models={},comparisons=[]);save()
def build(kind):
 source=(R/'rtl/arm/arm7_ds.sv').read_text()
 if kind=='wrong-count':
  target='current_context.internal_steps = mul_work_steps;';assert source.count(target)==1
  source=source.replace(target,"current_context.internal_steps = mul_work_steps + 3'd1;")
 if kind=='wrong-owner':
  target='offer_owned ? held_context : current_context';assert source.count(target)==1
  source=source.replace(target,'current_context')
 # Every mutation changes the real producer RTL, while the independent oracle
 # and the three original/default/off functional controls are unchanged.
 stage=D/kind;stage.mkdir();mutant=stage/'arm7_ds.sv';mutant.write_text(source)
 paths=[mutant if x.name=='arm7_ds.sv'else x for x in sources]
 call([a.verilator,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','-I'+str(S),'--top-module','tb','--Mdir',stage/'obj',*paths],'build-'+kind,180)
 model=stage/'obj/Vtb';result['models'][kind]=dict(SHA256=sha(model.read_bytes()),RTL_SHA256=sha(mutant.read_bytes()));save();return model
def run(model,tag,case,region,loops,variant=0,scenario=0,mutation=False,detail=0):
 rs=[0x7f,0x7fff,0x7fffff,0x7fffffff][case]
 argv=[model,'+kernel='+str(I/'kernel.hex'),'+wrapper='+str(I/'wrapper.hex'),'+boot='+str(I/'boot.hex'),
  '+out='+str(D/tag),'+case='+str(case),'+rs='+format(rs,'x'),'+region='+str(region),'+loops='+str(loops),'+variant='+str(variant),'+scenario='+str(scenario),'+detail='+str(detail)]
 for arg,symbol in [('call','timed_call'),('done','timed_done'),('finished','finished'),('irq_enable','irq_enable'),('sym_rs','rs_literal'),('sym_loops','loops_literal'),('sym_entry','entry_literal')]:argv.append('+'+arg+'='+format(symbols[symbol],'x'))
 rc=call(argv,tag,30,expected=None);log=(D/(tag+'.log')).read_text()
 assert 'MUL_FOUR_LANE_BEHAVIOR_PASS'in log,(tag,rc,log[-2800:])
 compared={}
 for suffix in ['state','data','edge']:
  before=(D/(tag+'-m0.'+suffix)).read_bytes()
  assert before or suffix=='edge'and not detail,(tag,suffix,'empty required evidence')
  for mode in [1,2,3]:assert(D/(tag+f'-m{mode}.'+suffix)).read_bytes()==before,(tag,suffix,mode)
  compared[suffix]=dict(bytes=len(before),SHA256=sha(before))
 if mutation:assert rc!=0 and'MUL_METADATA_MUTATION_CAUGHT'in log,(tag,rc,log[-2200:])
 else:assert rc==0 and'MUL_FOUR_LANE_METADATA_PASS'in log,(tag,rc,log[-2200:])
 row=dict(tag=tag,mutation=mutation,exit=rc,byte_equal=compared,coverage=re.findall(r'MUL_META_COVER[^\n]+',log));result['comparisons'].append(row);save();print('FOUR-LANE',tag,'PASS'+(' RTLfault caught'if mutation else''),flush=True)
model=build('production')
if a.completion_of:
 prior=json.loads((a.completion_of/'results.json').read_text());assert len(prior['comparisons'])==84
 assert sha((a.completion_of/'production/arm7_ds.sv').read_bytes())==sha((R/'rtl/arm/arm7_ds.sv').read_bytes())
 result['completed_positive']=dict(directory=str(a.completion_of.resolve()),results_SHA256=sha((a.completion_of/'results.json').read_bytes()),cases=84);save()
for case in ([]if a.completion_of else range(4)):
 for region in [0,1]:
  for rep in range(5):
   for n in [4,16]:run(model,f'c{case}-r{region}-p{rep}-n{n}',case,region,n,detail=int(rep==0 and n==16))
for case,region in ([]if a.completion_of else [(0,0),(3,1)]):run(model,f'variants-c{case}-r{region}',case,region,4,variant=1,detail=1)
for scenario,name in ([(3,'IRQ-discard')]if a.completion_of else [(1,'pause'),(2,'CPUreset-packet-live'),(3,'IRQ-discard')]):run(model,name,3,1,4,variant=1,scenario=scenario,detail=1)
for kind in ['wrong-count','wrong-owner']:
 model=build(kind);run(model,kind,3,1,4,variant=1,mutation=True,detail=1)
result['status']='PASS80 matrix +5 adverses old/default/off/on exact state/data/edge/cycle; independent metadata oracle; two actual metadata RTL faults caught after full functional equality'
save();status(result['status']);print(result['status'],flush=True)
