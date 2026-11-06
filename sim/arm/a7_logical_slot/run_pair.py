#!/usr/bin/env python3
"""One allocated serial CPU/P7 gate; no native or DS wait-price claim."""
from pathlib import Path
import argparse,hashlib,json,os,resource,subprocess,sys

p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
p.add_argument('--reuse-prefix',type=Path);a=p.parse_args()
D=a.output.resolve();S=D/'source';I=D/'inputs';sha=lambda f:hashlib.file_digest(f.open('rb'),'sha256').hexdigest()
def save(name,x):(D/name).write_text(json.dumps(x,indent=2)+'\n')
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
assert sha(D/'helpers/sim_ownership.py')=='64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003'
sys.path.insert(0,str(D/'helpers'));from worker_guard import guard,wait_owned
start=lambda pid:Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()[19]
assert not(D/'controller.json').exists()
for name,h in json.loads((D/'inputs.json').read_text())['source_sha256'].items():assert sha(D/name)==h,name
controller=dict(pid=os.getpid(),starttime=start(os.getpid()),host=os.uname().nodename,NI=10,jobs=1,threads=1);save('controller.json',controller)
def call(cmd,stem,fault=None):
 guard();cmd=list(map(str,cmd));log=D/(stem+'.log');log.parent.mkdir(parents=True,exist_ok=True)
 with log.open('w')as f:
  child=subprocess.Popen(cmd,cwd=D,stdout=f,stderr=subprocess.STDOUT)
  r=dict(pid=child.pid,starttime=start(child.pid),command=cmd,log=str(log),NI=os.getpriority(os.PRIO_PROCESS,child.pid));save('active.json',r)
  print('START',stem,child.pid,flush=True);rc=wait_owned(child)
 r.update(exit=rc,reaped=True);save(stem+'.process.json',r);text=log.read_text()
 if fault:assert rc!=0 and any(x in text for x in fault.split('|'))and'timeout'not in text.lower(),(stem,rc,text[-3000:])
 else:assert rc==0,(stem,rc,text[-3000:])
 return dict(exit=rc,log_sha256=sha(log),caught=next((x for x in fault.split('|')if x in text),None)if fault else None)
base=json.loads((D/'run-inputs.json').read_text());results={};reuse={}
if a.reuse_prefix:
 B=a.reuse_prefix.resolve();reuse=json.loads((B/'results.json').read_text())
 old=(B/'source/tb.sv').read_text();new=(S/'tb.sv').read_text()
 assert old.replace('scenario==5&&policy!=0&&!intervention','scenario==5&&policy!=0&&active&&!intervention',1)==new
 for role in ['before','normal','cpu-drop']:
  for leaf in ['cpu.sv','p7.sv']:assert sha(B/role/leaf)==sha(D/role/leaf)
 save('reused-prefix.json',dict(source=str(B),cases=list(reuse),correction='Require active timed body for scenario5 bridge; prior real9edge stall was in warmup at294, active starts1201. Actual CPU/P7 RTL unchanged; original terminal false retained.'))
def stored(stem,ext):
 return (B if results.get(stem,{}).get('reused_from')else D)/(stem+'.'+ext)
def normalized(path):return ['RESET'if x.startswith('RESET,')else x.split(',',1)[1]for x in path.read_text().splitlines()]
try:
 for role in ['before','normal','cpu-drop']:
  Q=D/role; sources=[*sorted(S.glob('*.sv'),key=lambda f:f.name!='arm_pkg.sv'),Q/'cpu.sv',Q/'p7.sv']
  controls=[(1,s,0)for s in range(5)]+[(c,0,0)for c in [0,2]]
  cases=controls if role=='before'else controls+[(1,s,1)for s in range(6)]+[(c,0,1)for c in [0,2]]if role=='normal'else[(1,5 if role=='cpu-drop'else 0,1)]
  needs_build=any(f'{role}/c{c}-s{s}-p{p}'not in reuse for c,s,p in cases)
  if needs_build:
   call(['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb','--Mdir',Q/'obj',*sources],role+'/build')
   model=Q/'obj/Vtb';save(role+'/model.json',dict(sha256=sha(model),inputs={str(f.relative_to(D)):sha(f)for f in sources}))
  for case,scenario,policy in cases:
   key=f'c{case}-s{scenario}-p{policy}';stem=role+'/'+key
   if stem in reuse:
    r=dict(reuse[stem]);assert r['exit']==0 and not r['caught']
    assert sha(B/(stem+'.log'))==r['log_sha256']
    for ext,h in r['captures'].items():assert sha(B/(stem+'.'+ext))==h
    r['reused_from']=str(B);r['model_sha256']=json.loads((B/role/'model.json').read_text())['sha256']
    results[stem]=r;save('results.json',results);continue
   args={v.split('=',1)[0]:v.split('=',1)[1]for v in base['template'][1:]}
   rs,rs6=[(127,127),(2147483647,2147483647),(127,2147483647)][case]
   args.update({'+out':str(D/stem),'+case':str(case),'+scenario':str(scenario),'+policy':str(policy),'+loops':'4','+rs':format(rs,'x'),'+rs6':format(rs6,'x'),'+detail':'1'})
   for name in ['kernel','wrapper','boot']:args['+'+name]=str(I/Path(args['+'+name]).name)
   if scenario==3:
    args['+boot']=str(I/'irq-boot.hex')
    for n,sym in [('call','timed_call'),('done','timed_done'),('sym_rs','rs_literal'),('sym_rs6','rs6_literal'),('sym_loops','loops_literal'),('sym_entry','entry_literal')]:args['+'+n]=format(base['IRQ_symbols'][sym],'x')
   fault={'cpu-drop':'CPU_SLOT_UNACCEPTED_OFFER_CHANGED|P7_SLOT_PRODUCER_CHANGED_UNACCEPTED_OWNER'}.get(role)
   r=call([model,*[k+'='+v for k,v in args.items()]],stem,fault)
   if not fault:
    text=(D/(stem+'.log')).read_text();assert 'PAIRED_SLOT_PASS'in text and'PHASE_FUNCTION_PASS'in text and'ADVERSE_PASS'in text
    r['captures']={ext:sha(D/(stem+'.'+ext))for ext in ['state','data','edge','full','pins','slot']}
    if role=='normal'and policy==0:
     for ext in ['state','data','edge','full','pins']:assert r['captures'][ext]==results['before/'+key]['captures'][ext],('disabled literal mismatch',key,ext)
    if role=='normal'and policy==1:
     control=f'normal/c{case}-s{0 if scenario==5 else scenario}-p{1 if scenario==5 else 0}'
     for ext in ['state','data']:assert normalized(D/(stem+'.'+ext))==normalized(stored(control,ext)),('architectural sequence mismatch',key,ext)
   results[stem]=r;save('results.json',results)
 save('complete.json',dict(status='PASS bounded paired CPU/P7 handshake, not DS service progression',positive_cases=22,actual_faults=1,controller=controller));print('PAIRED_SLOT_COMPLETE',flush=True)
finally:
 removed=[]
 for role in ['before','normal','cpu-drop','p7-consume']:
  Q=D/role
  if not(Q/'model.json').exists():continue
  assert sha(Q/'obj/Vtb')==json.loads((Q/'model.json').read_text())['sha256']
  for f in(Q/'obj').iterdir():
   if f.is_file()and f.name not in ['Vtb','Vtb__verFiles.dat']:
    removed.append(dict(path=str(f.relative_to(D)),bytes=f.stat().st_size));f.unlink()
 save('compiler-cleanup.json',dict(files=len(removed),bytes=sum(x['bytes']for x in removed)))
 save('terminal.json',dict(controller=controller,complete=(D/'complete.json').exists()))
