#!/usr/bin/env python3
"""Serial pinned reference before/ACK0/ACK1 native gate, explicit execute only."""
from pathlib import Path
import argparse,datetime,hashlib,importlib.util,json,os,re,resource,shutil,signal,subprocess,sys,time
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--plan',type=Path,required=True);p.add_argument('--execute',action='store_true');a=p.parse_args()
D=a.plan.resolve().parent;plan=json.loads(a.plan.read_text());P=D/'common';U=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json')
frozen=json.loads((D/'frozen.json').read_text());assert H(a.plan)==frozen['plan_SHA256']and H(Path(__file__))==frozen['runner_SHA256']
if not a.execute:print(json.dumps({'state':'PINNED NOT LAUNCHED','plan_SHA256':frozen['plan_SHA256'],'bounds':plan['bounds']},indent=2));sys.exit(0)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
def ident(pid):return Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()[19]
result={'plan_SHA256':frozen['plan_SHA256'],'controller':os.getpid(),'controller_starttime':ident(os.getpid()),'stages':[],'models':{},'runs':{},'state':'STARTING'}
def save(path,d):
 q=path.with_suffix('.tmp.'+str(os.getpid()));q.write_text(json.dumps(d,indent=2)+'\n');q.replace(path)
def status(phase,child=None):
 result['state']=phase;save(D/'results.json',result)
 d=json.loads(U.read_text());d.update(updated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),phase='LDM4 reference native: '+phase)
 d['worker']={'active':bool(child),'PID':child.pid if child else None,'starttime':ident(child.pid)if child else None,'controller':os.getpid(),'host':'DesktopD2','NI':10,'jobs':1,'threads':1,'lease':'Root authorized changedACK native gate','receipt':str(D/'results.json')}
 text=json.dumps(d,separators=(',',':'))+'\n';assert len(text.encode())<=2048;q=U.with_suffix('.tmp.'+str(os.getpid()));q.write_text(text);q.replace(U)
def call(cmd,cwd,out,tag,wall):
 cmd=list(map(str,cmd));begin=time.monotonic();out.parent.mkdir(parents=True,exist_ok=True)
 with out.open('w')as log:
  child=subprocess.Popen(cmd,cwd=cwd,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  row={'tag':tag,'cmd':cmd,'cwd':str(cwd),'PID':child.pid,'starttime':ident(child.pid),'PGID':child.pid,'NI':os.getpriority(os.PRIO_PROCESS,child.pid),'wall_limit':wall,'uptime':subprocess.check_output(['uptime'],text=True).strip()};result['stages'].append(row);status(tag,child);print(tag,'PID',child.pid,flush=True)
  try:row['exit']=child.wait(timeout=wall)
  except BaseException as exc:
   row['interrupted']=repr(exc)
   if child.poll()is None:
    os.killpg(child.pid,signal.SIGTERM)
    try:child.wait(timeout=10)
    except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
   row['exit']=child.returncode
   raise
  finally:
   row.update(reaped=True,wall_seconds=round(time.monotonic()-begin,3),log_SHA256=H(out));status(tag+' reaped')
 assert row['exit']==0,(tag,out.read_text()[-3000:])
 return row
def module(name,path):
 spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
def words(path):return path.read_text().splitlines()
def analyze(name,guest,B):
 manifest=json.loads((B/'manifest.json').read_text());text=(B/'run.log').read_text();assert text.count('LDM4_NATIVE_ROUTE_PASS')==1
 activity=re.search(r'LDM4_NATIVE_ACTIVITY words(\d+) lists(\d+) admissions(\d+) physicalACKs(\d+) returns(\d+) heldedges(\d+) legacyhitoffers(\d+) pending([01]) listlive([01]) physical([01])',text);assert activity,(name,guest,'missing terminal owner receipt')
 stats=dict(zip(['words','lists','admissions','physical_ACKs','returns','held_edges','legacy_hit_offers','pending','list_live','physical_live'],map(int,activity.groups())))
 assert stats['words']==4*stats['lists']and not any(stats[k]for k in ['pending','list_live','physical_live'])and stats['admissions']==stats['physical_ACKs'],stats
 if guest!='unitmem':assert stats['words']>0,stats
 if guest=='ds30':
  sys.path.insert(0,str(B/'prepared'));checker=module('ds30_'+name,B/'prepared/check_observer.py');checked=checker.validate(B/'ldm4-ds30',B/'prepared',B/'manifest.json',B/'run.log');values=[int(x['arm7_cycles_per_op_x100'])for x in checked['rows']]
 else:
  checked=module('guard_'+name+guest,P/'native_guard.py').validate(text,22 if guest=='unita7' else 32,guest);assert checked['accepted'],checked;values=[checked['values'][i]for i in range(len(checked['values']))]
 wc=words(B/'ldm4.words');sc=words(B/'ldm4.state');assert len(wc)==stats['words']and len(sc)==stats['lists']
 record={'guards':checked,'values':values,'activity':stats,'words_SHA256':H(B/'ldm4.words'),'state_SHA256':H(B/'ldm4.state'),'edges_SHA256':H(B/'ldm4.edges')}
 if name!='before':
  control=D/'before/runs'/guest;old=json.loads((control/'checked.json').read_text())
  if name=='ACK0':
   assert values==old['values'],(guest,'ACK0 values changed')
   for suffix in ['words','state','edges']:assert(B/('ldm4.'+suffix)).read_bytes()==(control/('ldm4.'+suffix)).read_bytes(),(guest,'ACK0 '+suffix)
   record['before_exact']=True
  else:
   assert wc==words(control/'ldm4.words'),(guest,'ACK1 payload/PC/beat/address/order/CPSR changed')
   before_state=[x.split(',')for x in words(control/'ldm4.state')];after_state=[x.split(',')for x in sc];assert len(before_state)==len(after_state)
   differences={};examples=[]
   for row,(oldrow,newrow)in enumerate(zip(before_state,after_state)):
    assert len(oldrow)==len(newrow)==73
    for i,(x,y)in enumerate(zip(oldrow,newrow)):
     if x!=y:
      assert i not in list(range(4))+list(range(6,10))+list(range(38,42))+list(range(68,73)),(guest,row,i,'essential LDM state changed',x,y)
      differences[str(i)]=differences.get(str(i),0)+1
      if len(examples)<24:examples.append({'row':row,'field':i,'before':x,'after':y,'pc':oldrow[1]})
   record['state_differences']={'field_counts':differences,'first_examples':examples,'interpretation':'All full RF/RFB/SPSR samples retained. Unexplained differences keep full-state acceptance open; no blanket timing-state mask.'}
   record['timing_changes']=[{'slot':i,'before':x,'ACK1':y}for i,(x,y)in enumerate(zip(old['values'],values))if x!=y]
   if not stats['words']:assert values==old['values'],(guest,'unexercised option changed values')
 save(B/'checked.json',record);return record
try:
 for rel,sha in plan['input_SHA256'].items():assert H(P/rel)==sha,rel
 for name,v in plan['variants'].items():
  V=D/name;S=V/'source';assert H(V/'source-profile.json')==frozen['source_profile_SHA256'][name]
  for rel,sha in v['production_SHA256'].items():assert H(S/rel)==sha,(name,rel)
  for rel,sha in v['host_SHA256'].items():assert H(V/rel)==sha,(name,rel)
  call(v['build_command'],S,V/'build.log','build-'+name,v['build_wall_seconds'])
  model=V/'model/Vtb_ds_pocket';model_receipt={'source':v['source'],'profile':v['profile'],'SHA256':H(model),'inputs_receipt_SHA256':H(V/'source-profile.json'),'path':str(model)};result['models'][name]=model_receipt;save(V/'model.json',model_receipt);status(name+' built')
  for guest,g in plan['guests'].items():
   B=V/'runs'/guest;W=B/'run';W.mkdir(parents=True);shutil.copytree(P/'runtime',W,dirs_exist_ok=True)
   rom=(P/'roms'/(guest+'.nds')).read_bytes();assert hashlib.sha256(rom).hexdigest()==g['ROM_SHA256'];rom+=bytes(-len(rom)%4)
   (W/'rom.hex').write_text(''.join('%08x\n'%int.from_bytes(rom[i:i+4],'little')for i in range(0,len(rom),4)))
   cmd=[model,f'+rom={W}/rom.hex',f'+romsize={(P/"roms"/(guest+".nds")).stat().st_size}',f'+bios9={W}/bios9.hex',f'+bios7={W}/bios7.hex',f'+fw={W}/firmware.hex',f'+boot={W}/boot.hex','+fwsize=262144','+frames='+str(g['frames']),'+timeout_ms='+str(g['simulated_ms']),'+vmcheck','+g3dperf','+progress',f'+ldm4_observe={B}/ldm4']
   if guest=='ds30':
    shutil.copytree(P/'ds30',B/'prepared');hook=B/'prepared/hook-manifest.json';m=json.loads(hook.read_text());m['source']=v['source'];save(hook,m)
    cmd += [f'+ds30_observe={B}/ldm4-ds30',f'+ds30_expected={P}/ds30/run-assets/ds30_expected.hex']
   else:cmd+=['+stop_done=1']
   manifest={'source':v['source'],'profile':v['profile'],'model_sha256':model_receipt['SHA256'],'ROM_sha256':g['ROM_SHA256'],'expanded_sha256':{x.name:H(x)for x in W.iterdir()if x.is_file()},'argv':list(map(str,cmd)),'cwd':str(W)};save(B/'manifest.json',manifest)
   call(cmd,W,B/'run.log',name+'-'+guest,g['wall_seconds']);assert H(model)==model_receipt['SHA256']
   checked=analyze(name,guest,B);result['runs'][name+'/'+guest]={'checked_SHA256':H(B/'checked.json'),'activity':checked['activity'],'values':checked['values']};status(name+' '+guest+' checked');print('CHECKED',name,guest,checked['activity'],flush=True)
 result['state']='COMPLETE affected reference native; timing/state differences retained, no automatic DS qualification';save(D/'results.json',result);status(result['state']);print(result['state'],flush=True)
except BaseException as exc:
 result['failure']=repr(exc);status('STOPPED first failure; inspect retained receipts');raise
