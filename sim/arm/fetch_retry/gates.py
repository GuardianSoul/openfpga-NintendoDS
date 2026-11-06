#!/usr/bin/env python3
"""Current CPU on retained25 DENSE inputs and26 qualified tb_arm recipes."""
from pathlib import Path
import argparse,datetime,difflib,hashlib,json,os,re,resource,subprocess,time
from prepare import restore
R=Path(__file__).resolve().parents[3]
P=argparse.ArgumentParser(description=__doc__)
P.add_argument('--output',type=Path,default=R/'build/fetch-retry-gates-replay')
P.add_argument('--verilator',default=os.environ.get('VERILATOR','verilator'))
P.add_argument('--status',type=Path,help='Optional coordinator status file')
a=P.parse_args();G=a.output.resolve();restore(G,broad=True)
I=G/'inputs';D=G/'current';D.mkdir(exist_ok=False)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
(G/'tmp').mkdir(exist_ok=True);os.environ['TMPDIR']=str(G/'tmp')
inputs=json.loads((G/'input-receipt.json').read_text());oldbase='build/ldm-service'
status=a.status
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
result=dict(source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),
 controller=os.getpid(),start_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),stages=[],DENSE={},ARM={},
 scope='Fresh candidate CPU execution against frozen measured inputs/expected state and existing suite recipes; no unchanged baseline run')
def save():
 (D/'results.json').write_text(json.dumps(result,indent=2)+'\n')
def call(argv,tag,seconds=120):
 argv=list(map(str,argv));start=time.monotonic()
 with (D/(tag+'.log')).open('w')as f:
  p=subprocess.Popen(argv,cwd=R,stdout=f,stderr=subprocess.STDOUT);s=dict(tag=tag,PID=p.pid,starttime=Path('/proc',str(p.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,p.pid),argv=argv);result['stages'].append(s);save()
  if status:
   st=json.loads(status.read_text());st['phase']='CPU regression '+tag;st['worker']=dict(host='Desktop',controller=os.getpid(),PID=p.pid,starttime=s['starttime'],jobs=1,threads=1,NI=10);st['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();t=status.with_suffix('.tmp.'+str(os.getpid()));t.write_text(json.dumps(st,indent=2)+'\n');t.replace(status)
  print(json.dumps(dict(stage=tag,PID=p.pid)),flush=True)
  try:s['exit']=p.wait(timeout=seconds)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=10);s['exit']=p.returncode;s['wall_timeout']=True
 s['wall_seconds']=round(time.monotonic()-start,3);s['reaped']=True;save();return s['exit']

cmd=list(inputs['build_recipe'][-1]['cmd']);cmd[cmd.index('--Mdir')+1]=str(D/'obj')
cmd[0]=a.verilator
source={}
for k,a in enumerate(cmd):
 if a.endswith('.sv'):
  name=Path(a).name;p=D/name
  b=(I/'cpu-final/tb.sv').read_bytes()if name=='tb.sv'else(R/'rtl/arm'/name).read_bytes()
  p.write_bytes(b);source[name]=sha(p);cmd[k]=str(p)
result['source_SHA256']=source;result['input_archive_SHA256']=inputs['archive_SHA256'];save()
rc=call(cmd,'build',240)
if rc:
 text=(D/'build.log').read_text();result['infrastructure_failure']=any(s in text for s in ['No space','Disk quota']);save();raise SystemExit(text[-1800:])
model=D/'obj/Vtb_arm';result['model_SHA256']=sha(model);save()
recipes=[json.loads(l)for l in (I/'processes.jsonl').read_text().splitlines()]
packets=lambda text:re.findall(r'^PACKET.*$',text,re.M)
writes=lambda text:[p for p in packets(text)if p.split()[2]=='1']
def prefix(path,cut):
 rows=path.read_text().splitlines();stop=next(i for i,x in enumerate(rows)if x.startswith(cut+','));return rows[:stop]
for seed in range(1301,1326):
 tag='seed'+str(seed);recipe=next(x['cmd']for x in recipes if Path(x['log']).name=='cpu-final-'+tag+'.log')
 argv=[str(model)]+[a.replace(oldbase,str(I))for a in recipe[1:]]
 argv=[('+trace0='+str(D/(tag+'.csv')))if a.startswith('+trace0=')else a for a in argv]
 rc=call(argv,tag);text=(D/(tag+'.log')).read_text();gold=(I/('cpu-final-'+tag+'.log')).read_text()
 nm=subprocess.check_output(['llvm-nm',I/(tag+'.elf')],text=True);cut=next(x.split()[0]for x in nm.splitlines()if x.endswith(' compare_end'))
 current=prefix(D/(tag+'.csv'),cut);control=prefix(I/('cpu-final-'+tag+'.csv'),cut)
 row=dict(exit=rc,functional='TEST PASSED'in text,states=len(current),state_exact=current==control,
  all_bus_packets_exact=packets(text)==packets(gold),writes_exact=writes(text)==writes(gold),
  current_packets=len(packets(text)),control_packets=len(packets(gold)))
 result['DENSE'][str(seed)]=row;save();print('DENSE',seed,json.dumps(row),flush=True)
 assert rc==0 and row['functional']and current and row['state_exact']and row['writes_exact'],('DENSE regression',seed,row)
 deleted=[]
 old_packets,new_packets=packets(gold),packets(text)
 for op,i,j,k,l in difflib.SequenceMatcher(a=old_packets,b=new_packets,autojunk=False).get_opcodes():
  if op!='equal':
   assert op=='delete'and k==l,('unclassified bus change',seed,op)
   deleted.extend(old_packets[i:j])
 assert deleted==['PACKET 02000008 0 f e59f00b4','PACKET 0200000c 0 f ee060f11','PACKET 02000080 0 f e59f0060'],('unclassified reads',seed,deleted)
for case in inputs['ARM_cases']:
 name=Path(case['log']).stem.removeprefix('cpu-final-');argv=[str(model)]+[x.replace(oldbase,str(I))for x in case['cmd'][1:]]
 rc=call(argv,'ARM-'+name);text=(D/('ARM-'+name+'.log')).read_text();ok='TEST PASSED'in text
 row=dict(exit=rc,verdict='PASS'if ok else'FAIL',cycles=re.findall(r'cycles=(\d+)',text),retained_known_failure=name=='bpred7')
 result['ARM'][name]=row;save();print('ARM',name,json.dumps(row),flush=True)
 assert rc==0,('tb_arm process failure',name,rc)
 if not ok:
  baseline=(G/'gold-suite'/('cpu-final-'+name+'.log')).read_text()
  expected='ctx1: timeout at pc=020000b8 retired=1490\nTEST FAILED (timeout)'
  assert name=='bpred7'and expected in text and expected in baseline,('new tb_arm regression',name,text[-1200:])
assert len(result['DENSE'])==25 and len(result['ARM'])==26
result['status']='25DENSE state/write order PASS;26tb_arm completed; all bus packet deltas retained; bpred7 known limit retained';save()
if status:
 st=json.loads(status.read_text());st['phase']=result['status'];st['worker']=dict(host='Desktop',controller=None,PID=None,jobs=0,threads=0);st['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();t=status.with_suffix('.tmp.'+str(os.getpid()));t.write_text(json.dumps(st,indent=2)+'\n');t.replace(status)
print(result['status'],flush=True)
