#!/usr/bin/env python3
"""Leased serial actual-ARM7/CAP_CHAIN/physical SDRAM+PSRAM qualification."""
from pathlib import Path
import argparse,hashlib,json,os,re,resource,subprocess,sys,time
R=Path(__file__).resolve().parents[3];os.chdir(R);p=argparse.ArgumentParser();p.add_argument('--allocated',action='store_true',required=True);p.add_argument('--await-release',action='store_true');p.add_argument('--out',type=Path,required=True);p.add_argument('--pilot',action='store_true');p.add_argument('--before-only',action='store_true');p.add_argument('--reuse-before',type=Path);p.add_argument('--reuse-models',type=Path);p.add_argument('--only-extra',action='store_true');p.add_argument('--only-vram-conflict',action='store_true');p.add_argument('--program',type=Path,default=R/'sim/ds/a7_vram_read/program.s');p.add_argument('--no-faults',action='store_true');a=p.parse_args();G=a.out.resolve();G.mkdir(parents=True,exist_ok=False)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));sys.dont_write_bytecode=True;sys.path.insert(0,str(R/'sim/arm/ncnb_store'));from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
assert sha(R/'sim/arm/ncnb_store/sim_ownership.py')=='64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003'
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n')
save(G/'controller.json',dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,0)));print('GATED',(G/'controller.json').read_text(),flush=True)
while a.await_release and not(G/'release').exists():time.sleep(.2)
(G/'tmp').mkdir();os.environ['TMPDIR']=str(G/'tmp')
BASE='2246c468c0d9bbd968ccdff7823f32df1c8d8f5f';V='build/tools/oss-cad-suite/bin/verilator'
FILES=['rtl/arm/arm_pkg.sv','rtl/gpu2d/gpu2d_pkg.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/ds/nds_ram.sv','rtl/sys/sys_ram.sv','rtl/ds/nds_lcache.sv','rtl/arm/arm_thumb.sv','rtl/arm/arm_mul.sv','rtl/arm/arm7_ds.sv','rtl/ds/nds_arm7_port.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_vram.sv','rtl/pocket/nds_x2b.sv','rtl/pocket/nds_cdc.sv','rtl/pocket/nds_sdram_bus.sv','rtl/pocket/nds_sdram_mc.sv','rtl/pocket/nds_psram.sv','rtl/mem/psx_pq_psram.sv','sim/phase1/sim_prims.sv','sim/phase1/sdram_chip_model.sv']
source=sha(R/'rtl/ds/nds_fabric.sv');save(G/'source.json',dict(BASE=BASE,candidate=source,head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()))
def call(argv,tag,allow=False):
 guard();argv=list(map(str,argv));t=time.monotonic()
 with(G/(tag+'.log')).open('w')as f:
  q=subprocess.Popen(argv,stdout=f,stderr=subprocess.STDOUT);row=dict(pid=q.pid,starttime=Path('/proc',str(q.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,q.pid),cmd=argv,log=str(G/(tag+'.log')))
  with(G/'processes.jsonl').open('a')as f:f.write(json.dumps(row)+'\n')
  print('STAGE',tag,'PID',q.pid,flush=True);rc=wait_owned(q)
 row.update(exit=rc,reaped=True,wall_seconds=round(time.monotonic()-t,3));save(G/(tag+'.process.json'),row)
 if not allow:assert rc==0,(tag,rc,(G/(tag+'.log')).read_text()[-2200:])
 return rc
models={}
def build(name):
 if name in models:return models[name]
 if a.reuse_models:
  old=a.reuse_models.resolve();receipt=json.loads((old/name/'model.json').read_text());binary=old/name/'obj/Vtb_side';assert sha(binary)==receipt['sha256']
  for rel in FILES:
   original=old/name/rel;b=subprocess.check_output(['git','show',BASE+':'+rel])if name=='before'else(R/rel).read_bytes();assert hashlib.sha256(b).hexdigest()==sha(original)==receipt['inputs'][str(original)]
  for f in ['tb.sv','pin_memory.sv','cram_model.sv']:assert(old/name/f).read_bytes()==(R/'sim/ds/a7_vram_read'/f).read_bytes()
  save(G/('reused-'+name+'-model.json'),dict(original_root=str(old),model_sha256=sha(binary),source_receipt=receipt));models[name]=binary;return binary
 if name=='before'and a.reuse_before:
  old=a.reuse_before.resolve();receipt=json.loads((old/'before/model.json').read_text());binary=old/'before/obj/Vtb_side';assert sha(binary)==receipt['sha256']
  for rel in FILES:
   original=old/'before'/rel;assert sha(original)==hashlib.sha256(subprocess.check_output(['git','show',BASE+':'+rel])).hexdigest();assert receipt['inputs'][str(original)]==sha(original)
  for f in ['tb.sv','pin_memory.sv','cram_model.sv']:assert(old/'before'/f).read_bytes()==(R/'sim/ds/a7_vram_read'/f).read_bytes()
  save(G/'reused-before-model.json',dict(original_root=str(old),model_sha256=sha(binary),source_receipt=receipt,scope='Exactbefore model reused, no unchangedcontrolbuild'))
  models[name]=binary;return binary
 d=G/name;d.mkdir();files=[]
 for rel in FILES:
  b=subprocess.check_output(['git','show',BASE+':'+rel])if name=='before'else(R/rel).read_bytes()
  if name=='wrongdata'and rel=='rtl/ds/nds_fabric.sv':
   old=b'v7_ack && v7_read ? vr_rdata :';assert b.count(old)==1;b=b.replace(old,b"v7_ack && v7_read ? (vr_rdata ^ 32'd1) :")
  if name=='earlyack'and rel=='rtl/ds/nds_fabric.sv':
   old=b'wire v7_ack = v7_end &&';assert b.count(old)==1;b=b.replace(old,b'wire v7_ack = (v7_end || (v7_live && v7_read)) &&')
  out=d/rel;out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(b);files.append(out)
 for f in ['tb.sv','pin_memory.sv','cram_model.sv']:
  out=d/f;out.write_bytes((R/'sim/ds/a7_vram_read'/f).read_bytes());files.append(out)
 cmd=[V,'--binary','--timing','--assert','--threads','1','-j','1','-O1','-Wno-fatal','--timescale','1ns/1ps','--top-module','tb_side','--Mdir',d/'obj']
 if name!='before':cmd+=['+define+NEW_READ_SIDE','-GREAD_SIDE='+str(int(name!='off'))]
 call(cmd+files,name+'-build');model=d/'obj/Vtb_side';save(d/'model.json',dict(sha256=sha(model),inputs={str(f):sha(f)for f in files}));models[name]=model;assert sha(R/'rtl/ds/nds_fabric.sv')==source;return model
call(['clang','--target=arm-none-eabi','-march=armv4t','-fuse-ld=lld','-nostdlib','-Wl,-Ttext=0x03808000','-Wl,--entry=_start',a.program,'-o',G/'program.elf'],'program-build');call(['llvm-objcopy','-O','binary',G/'program.elf',G/'program.bin'],'program-objcopy');b=(G/'program.bin').read_bytes();assert len(b)%4==0;(G/'program.hex').write_text(''.join(f'{int.from_bytes(b[i:i+4],"little"):08x}\n'for i in range(0,len(b),4)));symbols={l.split()[-1]:l.split()[0]for l in subprocess.check_output(['llvm-nm',G/'program.elf'],text=True).splitlines()if len(l.split())==3}
def run(n,pressure,owner,phase,**opts):
 tag=f'{n}-p{pressure}-o{owner}-phase{phase}'+''.join(f'-{k}{v}'for k,v in sorted(opts.items()));out=G/tag
 if n=='before'and a.reuse_before and(a.reuse_before/(tag+'-run.log')).exists():
  build(n);old=a.reuse_before.resolve();assert(old/'program.hex').read_bytes()==(G/'program.hex').read_bytes();text=(old/(tag+'-run.log')).read_text();assert'PASS_SIDE'in text
  copied={}
  for ext in ['state','data','edge','mon','physical','causal']:
   src=(old/tag).with_suffix('.'+ext);dst=out.with_suffix('.'+ext);dst.write_bytes(src.read_bytes());copied[str(dst)]=sha(dst)
  (G/(tag+'-run.log')).write_bytes((old/(tag+'-run.log')).read_bytes());save(G/(tag+'-reused.json'),dict(original_process=json.loads((old/(tag+'-run.process.json')).read_text()),copied=copied));rc=0
 else:rc=call([build(n),'+img='+str(G/'program.hex'),'+out='+str(out),'+begin='+symbols['body_begin'],'+done='+symbols['done'],'+fail='+symbols['fail'],f'+pressure={pressure}',f'+owner={owner}',f'+phase={phase}',*[f'+{k}={v}'for k,v in opts.items()]],tag+'-run',n in ['wrongdata','earlyack']);text=(G/(tag+'-run.log')).read_text()
 if n in ['wrongdata','earlyack']:assert rc!=0 and'timeout'not in text.lower();return dict(exit=rc,errors=[l for l in text.splitlines()if'%Fatal:'in l or'%Error:'in l]),out
 if opts.get('resetmode'):
  assert'PASS_RESET'in text and'PIN_MEMORY errors0/0/0'in text,(tag,text[-2000:]);assert 'ownercleared1'in text
  return dict(reset=opts['resetmode'],summary=re.findall(r'^PASS_RESET.*$',text,re.M)),out
 assert'PASS_SIDE'in text and'PIN_MEMORY errors0/0/0'in text,(tag,text[-2000:]);m=re.search(r'PASS_SIDE CPUend(\d+) states(\d+) writes(\d+) physical(\d+) capture(\d+) Gpairs(\d+) Gmax(\d+) MAINanswers(\d+) side(\d+)/(\d+) outlives(\d+) reads(\d+)/(\d+)',text);assert m
 return dict(zip(['CPUend','states','writes','physical','capture','Gpairs','Gmax','MAINanswers','side_start','side_end','outlives','read_start','read_end'],map(int,m.groups()))),out
cases=[((0,1,1),{}),((1,1,1),{}),((1,3,1),{})]
if not a.pilot:cases+=[((1,o,phase),{})for o in [1,3]for phase in [17,64,133,196]]+[((1,1,1),dict(hostwrite=1)),((1,1,1),dict(nextwrite=1)),((1,1,1),dict(snwrite=1)),((1,1,1),dict(dma=1))]
if a.only_extra:cases=[((1,1,1),dict(hostwrite=1)),((1,1,1),dict(nextwrite=1)),((1,1,1),dict(snwrite=1)),((1,1,1),dict(dma=1)),((1,1,1),dict(resetmode=1)),((1,1,1),dict(resetmode=2))]
if a.only_vram_conflict:cases=[((1,1,1),dict(late=1))]
result={}
for args,opts in cases:
 data={};paths={}
 for n in ['before']if a.before_only else['before','off','on']:data[n],paths[n]=run(n,*args,**opts)
 if opts.get('resetmode'):
  assert data['before']['summary']==data['off']['summary'];result[str((args,opts))]=data;save(G/'results.json',result);print('READ_RESET_CASE',args,opts,data,flush=True);continue
 if not a.before_only:
  assert data['before']==data['off']
  for ext in ['state','data','edge','mon','physical']:assert paths['before'].with_suffix('.'+ext).read_bytes()==paths['off'].with_suffix('.'+ext).read_bytes(),('default',args,opts,ext)
  for ext in ['state','data']:assert paths['before'].with_suffix('.'+ext).read_bytes()==paths['on'].with_suffix('.'+ext).read_bytes(),('architectural',args,opts,ext)
  for master in ['0 ','1 ','2 ','3 ']:
   get=lambda p:[l for l in p.with_suffix('.mon').read_text().splitlines()if l.startswith(master)];assert get(paths['before'])==get(paths['on']),('writeorder',args,opts,master)
  if not args[0]or opts.get('hostwrite'):assert data['before']==data['on']and paths['before'].with_suffix('.edge').read_bytes()==paths['on'].with_suffix('.edge').read_bytes()
  else:assert data['on']['read_start']>0 and data['on']['read_start']==data['on']['read_end'],('inactive/new read owner',args,opts)
 result[str((args,opts))]=data;save(G/'results.json',result);print('READ_SIDE_CASE',args,opts,data,flush=True)
if not a.pilot and not a.before_only and not a.no_faults:
 faults={}
 for n in ['wrongdata','earlyack']:faults[n],_=run(n,1,1,1)
 save(G/'faults.json',faults)
print('READ_SIDE_COMPLETE',flush=True)
