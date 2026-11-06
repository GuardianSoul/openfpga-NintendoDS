#!/usr/bin/env python3
"""One NI10/j1/t1 current-source coupled fixture for the new DS MUL matrix."""
from pathlib import Path
import argparse,datetime,hashlib,importlib.util,json,os,re,resource,shutil,struct,subprocess,tarfile,time
R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
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
 limits='Exact kernel/wrapper/addresses and warm1/4-16/min5; quiet component BL-retire brackets, no DS timer/helper/native equivalence claim. No RTL/price/owner changes.',caps=dict(NI=10,jobs=1,threads=1,CPU_seconds_per_process=240,AS_bytes=4*1024**3,build_file_bytes=512*1024**2,model_file_bytes=64*1024**2,build_wall_seconds=180,model_wall_seconds=20))
def save():(D/'results.json').write_text(json.dumps(result,indent=2)+'\n')
status_path=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json')
def status(phase,proc=None):
 q=json.loads(status_path.read_text());q['phase']=phase;q['current_action']='Exact8case MUL coupled fixture; frozen currentCPU/P7/fabric/arb/PHY; record request/internal/consume overlap; no RTL/native baseline';q['worker']=dict(host='Desktop',active=bool(proc),controller=os.getpid(),PID=proc.pid if proc else None,starttime=starttime(proc.pid)if proc else None,NI=10,jobs=1 if proc else 0,threads=1 if proc else 0);q['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();temp=status_path.with_name('CPU.json.tmp.'+str(os.getpid()));temp.write_text(json.dumps(q,indent=2)+'\n');temp.replace(status_path)
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
.global _start,timed_call,timed_done,rs_literal,loops_literal,entry_literal
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
 mov r8,#0x66
 b timed_done
.balign 4
stack_literal:.word 0x0380e000
warm_literal:.word 0x03802000
timed_literal:.word 0x03802080
entry_literal:.word 0
loops_literal:.word 0
rs_literal:.word 0
'''
(I/'boot.s').write_text(boot)
call([shutil.which('clang'),'--target=armv4t-none-eabi','-mcpu=arm7tdmi','-marm','-nostdlib','-c',I/'boot.s','-o',I/'boot.o'],'assemble',30)
call([shutil.which('ld.lld'),'-Ttext=0x03808000','--entry=_start','--defsym=mp_invoke=0x03800750',I/'boot.o','-o',I/'boot.elf'],'link',30)
call([shutil.which('llvm-objcopy'),'-O','binary',I/'boot.elf',I/'boot.bin'],'binary',30)
symbols={w[2]:int(w[0],16)for l in subprocess.check_output([shutil.which('llvm-nm'),'-n',I/'boot.elf'],text=True).splitlines()if len(w:=l.split())==3};result['symbols']=symbols
b=(I/'boot.bin').read_bytes();assert len(b)%4==0;(I/'boot.hex').write_text(''.join(f'{x:08x}\n'for x in struct.unpack('<'+'I'*(len(b)//4),b)))
rels=['rtl/arm/arm_pkg.sv','rtl/arm/arm7_ds.sv','rtl/arm/arm_thumb.sv','rtl/ds/nds_arm7_port.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_mr_arb.sv','rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/mem/psx_pq_psram.sv','rtl/pocket/nds_psram.sv','sim/phase1/cram_model.sv','sim/phase1/sim_prims.sv']
sources=[]
for n in rels:
 p=S/Path(n).name;p.write_bytes((R/n).read_bytes());sources.append(p);result['source_SHA256'][n]=sha(p.read_bytes())
donor=R/'docs/results/arm7-data-ack-20261101/proof.tar.gz';assert sha(donor.read_bytes())=='0707d7ca3a716f90dbe0eea6ad968398cd806c22289c77c46a9cd7e794027734'
with tarfile.open(donor)as t:transport=t.extractfile('cpu36/tb.sv').read().decode().split('module cpu_before ')[0]
transport=transport.replace('old_nds_psram #(','nds_psram #(');(S/'transport.sv').write_text(transport);sources.append(S/'transport.sv')
(S/'tb.sv').write_bytes((R/'sim/arm/a7_mulphase/tb.sv').read_bytes());sources.append(S/'tb.sv');result['fixture_SHA256']={p.name:sha(p.read_bytes())for p in sources};save()
call([a.verilator,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb','--Mdir',D/'obj',*sources],'build',180)
model=D/'obj/Vtb';result['model_SHA256']=sha(model.read_bytes());save()
base=[model,'+kernel='+str(I/'kernel.hex'),'+wrapper='+str(I/'wrapper.hex'),'+boot='+str(I/'boot.hex'),
 '+call='+format(symbols['timed_call'],'x'),'+done='+format(symbols['timed_done'],'x'),'+sym_rs='+format(symbols['rs_literal'],'x'),'+sym_loops='+format(symbols['loops_literal'],'x'),'+sym_entry='+format(symbols['entry_literal'],'x')]
for case,rs in enumerate([0x7f,0x7fff,0x7fffff,0x7fffffff]):
 for region in [0,1]:
  samples={4:[],16:[]}
  for rep in range(5):
   for loops in [4,16]:
    tag=f'c{case}-r{region}-p{rep}-n{loops}';detail=int(rep==0 and loops==16)
    call([*base,'+case='+str(case),'+rs='+format(rs,'x'),'+region='+str(region),'+loops='+str(loops),'+detail='+str(detail),'+out='+str(D/tag)],tag,20)
    log=(D/(tag+'.log')).read_text();matches=re.findall(r'MUL_PHASE_PASS case(\d+) region(\d+) loops(\d+) elapsed(\d+) mul_steps(\d+) retires(\d+) i_internal(\d+) fetches(\d+) logical_packets(\d+) physical(\d+)',log);assert len(matches)==1,tag
    row=dict(zip(['case','region','loops','elapsed','mul_steps','retires','i_internal','fetches','logical_packets','physical'],map(int,matches[0])));assert(row['case'],row['region'],row['loops'])==(case,region,loops);samples[loops].append(row)
  minimum={n:min(x['elapsed']for x in rows)for n,rows in samples.items()};slope=(minimum[16]-minimum[4])/1536;ds=next(x for x in DS['MUL_summary']if x['case_id']==case and x['region']==('MAIN'if region else'private_WRAM'))['slope']
  result['cases'][f'{case}-{region}']=dict(rs=rs,samples=samples,minimum_SYS=minimum,core_A7_slope=slope,DS_A7_slope=ds,core_DS=slope/ds);save();print('ROW',case,region,slope,'DS',ds,flush=True)
rc=call([*base,'+case=3','+rs=7fffffff','+region=1','+loops=4','+out='+str(D/'wrong-operand'),'+wrong_operand=1'],'wrong-operand',20,expected=None)
assert rc!=0 and'MUL_INPUT_MAPPING'in(D/'wrong-operand.log').read_text();result['input_fault_control']='Actual boot Rs literal mutation caught; no RTL mutation claimed'
result['status']='PASS80 exact-kernel/wrapper/operand/state runs; overlap measured; CPU/Memory timing remains open';save();status(result['status']);print(result['status'],flush=True)
