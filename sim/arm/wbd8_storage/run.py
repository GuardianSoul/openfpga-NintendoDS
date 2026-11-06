#!/usr/bin/env python3
"""One leased serial NI10 worker: actual before/current ARM9 memory miter."""
from pathlib import Path
import argparse,hashlib,json,os,re,resource,subprocess,sys,time
R=Path(__file__).resolve().parents[3];os.chdir(R)
p=argparse.ArgumentParser();p.add_argument('--allocated',action='store_true',required=True);p.add_argument('--await-release',action='store_true');p.add_argument('--out',type=Path,default=R/'build/wbd8-storage/leaf-v1');a=p.parse_args();G=a.out.resolve();G.mkdir(parents=True,exist_ok=False)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));sys.dont_write_bytecode=True
sys.path.insert(0,str(R/'sim/arm/ncnb_store'));from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
assert sha(R/'sim/arm/ncnb_store/sim_ownership.py')=='64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003'
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n')
save(G/'controller.json',dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,0)));print('GATED', (G/'controller.json').read_text(),flush=True)
while a.await_release and not(G/'release').exists():time.sleep(.2)
BASE='385039386d7d5d5a97f7c4ed4e6aaf96e6a553bf';V='build/tools/oss-cad-suite/bin/verilator'
source_sha=sha(R/'rtl/arm/arm9_mem.sv');save(G/'source.json',dict(base=BASE,candidate_sha256=source_sha,head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()))
(G/'tmp').mkdir();os.environ['TMPDIR']=str(G/'tmp')
def call(argv,tag,allowed=False):
 guard();argv=list(map(str,argv));log=G/(tag+'.log');t=time.monotonic()
 with log.open('w')as f:
  q=subprocess.Popen(argv,stdout=f,stderr=subprocess.STDOUT)
  row=dict(pid=q.pid,starttime=Path('/proc',str(q.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,q.pid),cmd=argv,log=str(log));
  with(G/'processes.jsonl').open('a')as f:f.write(json.dumps(row)+'\n')
  print('STAGE',tag,'PID',q.pid,flush=True);rc=wait_owned(q)
 row.update(exit=rc,reaped=True,wall_seconds=round(time.monotonic()-t,3));save(G/(tag+'.process.json'),row)
 if not allowed:assert rc==0,(tag,rc,log.read_text()[-2500:])
 return rc
results={}
for name,mem1,nb,mutant in [('mem1-nb1',1,1,False),('mem1-nb0',1,0,False),('legacy-wbd1',0,1,False),('wrongslot',1,1,True)]:
 d=G/name;d.mkdir();files=[]
 for f in ['arm_pkg','arm9_ram']:
  out=d/(f+'.sv');out.write_bytes((R/'rtl/arm'/(f+'.sv')).read_bytes());files.append(out)
 b=subprocess.check_output(['git','show',BASE+':rtl/arm/arm9_mem.sv']);assert b.count(b'module arm9_mem import')==1;b=b.replace(b'module arm9_mem import',b'module arm9_mem_before import');out=d/'arm9_mem_before.sv';out.write_bytes(b);files.append(out)
 assert sha(R/'rtl/arm/arm9_mem.sv')==source_sha
 b=(R/'rtl/arm/arm9_mem.sv').read_bytes()
 if mutant:
  old=b'wb_head <= tail[rp];';assert b.count(old)==1;b=b.replace(old,b"wb_head <= tail[rp ^ 3'd1];")
 out=d/'arm9_mem.sv';out.write_bytes(b);files.append(out)
 out=d/'tb.sv';out.write_bytes((R/'sim/arm/wbd8_storage/tb.sv').read_bytes());files.append(out)
 cmd=[V,'--binary','--timing','--assert','--threads','1','-j','1','-O1','-Wno-fatal','--top-module','tb','-GMEM1='+str(mem1),'-GNB='+str(nb),'--Mdir',d/'obj',*files]
 call(cmd,name+'-build');model=d/'obj/Vtb';save(d/'model.json',dict(sha256=sha(model),inputs={str(f):sha(f)for f in files},cmd=list(map(str,cmd))))
 if name=='mem1-nb1':
  call(['python3','tools/ds/qlint.py','rtl/arm/arm9_mem.sv'],'qlint');save(G/'build-ready.json',dict(source_sha256=source_sha,build_PASS=True,qlint_PASS=True,proof='IN PROGRESS'));print('BUILD_QLINT_PASS_SOURCE_READY',source_sha,flush=True)
 rc=call([model],name+'-run',mutant);text=(G/(name+'-run.log')).read_text()
 if mutant:assert rc!=0 and any(x in text for x in ['queue head mismatch','physical packet mismatch','write payload mismatch'])and'bounded leaf timeout'not in text
 else:assert 'WBD_EQ_PASS'in text
 results[name]=dict(exit=rc,summary=re.findall(r'^WBD_EQ_PASS.*$',text,re.M),actual_fault_caught=mutant,model=sha(model));save(G/'results.json',results);print('RESULT',name,results[name],flush=True)
print('WBD_LEAF_COMPLETE',flush=True)
