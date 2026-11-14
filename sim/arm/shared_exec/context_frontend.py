#!/usr/bin/env python3
"""Registered ARM7 port regression: corrected link versus previous actual RTL."""
import pathlib,subprocess,os,json,hashlib,fcntl,resource,time,shutil,re
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-context-frontend';D.mkdir(exist_ok=True);S=D/'source';S.mkdir(exist_ok=True)
STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json')
H=lambda b:hashlib.sha256(b).hexdigest()
r={'status':'PREPARING_FULL_NATIVE_SHARED_ENGINE','PID':os.getpid(),'sources':{},'stages':[],'not_production':True}
def save():(D/'result.json').write_text(json.dumps(r,indent=2)+'\n')
def status(tag,p=None):
 s=json.loads(STATUS.read_text());s.update(phase=tag,receipt=str(D/'result.json'),workers=[{'host':'Desktop','PID':os.getpid(),'NI':10,'peak_new_bytes':4294967296,'job':'native-shared-engine'}]+([]if p is None else[{'host':'Desktop','PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'job':tag}]),updated_at=time.time());v=json.dumps(s,separators=(',',':'));assert len(v)<2048;t=STATUS.with_suffix('.tmp');t.write_text(v+'\n');os.replace(t,STATUS)
def call(cmd,tag,timeout=180):
 with(D/(tag+'.log')).open('w')as f:
  p=subprocess.Popen(list(map(str,cmd)),cwd=W,stdout=f,stderr=subprocess.STDOUT);z={'tag':tag,'PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'cmd':list(map(str,cmd))};r['stages'].append(z);save();status(tag,p)
  try:z['exit']=p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:p.terminate();z['exit']=p.wait(timeout=10);z['timeout']=True
  save()
 return z['exit'],(D/(tag+'.log')).read_text()
# Require the unchanged original full-CPU oracle and actual caught fault first.
P=W/'docs/results/cpu232-service-cpu-gates-20261110';receipt=json.loads((P/'result.json').read_text());assert H((P/'evidence.tar.gz').read_bytes())==receipt['archive_sha256'];assert receipt['observed_cycles']==42657146 and '862'in receipt['actual_fault'];r['original_oracle_sha256']=receipt['archive_sha256']
import collections
files=[]
for n in ['arm_pkg','arm_regfile','arm_mul','arm_thumb','arm9_ram','arm9_mem']:
 p=S/(n+'.sv');p.write_bytes(subprocess.check_output(['git','show','232c26ac:rtl/arm/'+n+'.sv'],cwd=W));files.append(p)
for n in ['arm_context_bank','arm_shared_context','arm_dual_context','arm_cpu_context']:
 p=S/(n+'.sv');p.write_bytes((W/'rtl/arm/study'/(n+'.sv')).read_bytes());files.append(p)
lock=open(pathlib.Path.home()/'.cache/nds-sim-build.lock','a');status('ELASTIC_FRONTEND_WAIT_MUTEX');fcntl.flock(lock,fcntl.LOCK_EX)
def admission():
 p=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/host-disk-admission.json');policy=json.loads(p.read_text());seen=set();other=0
 for f in STATUS.parent.glob('*.json'):
  try:
   workers=json.loads(f.read_text()).get('workers',[])
   if not isinstance(workers,list):continue
   for q in workers:
    if not isinstance(q,dict)or q.get('host')not in ['Desktop','desktop']:continue
    pid=q.get('PID',q.get('pid'))
    if not isinstance(pid,int)or pid in seen or pid==os.getpid()or not pathlib.Path('/proc',str(pid)).exists():continue
    seen.add(pid);other+=int(q.get('peak_new_bytes',q.get('disk_budget_bytes',0)))
  except (ValueError,TypeError,OSError):continue
 mi=dict(x.split(':',1)for x in pathlib.Path('/proc/meminfo').read_text().splitlines());g={'NI':os.getpriority(os.PRIO_PROCESS,0),'RAM':int(mi['MemAvailable'].split()[0])*1024,'disk':shutil.disk_usage(W).free,'growth':policy['default_build_peak_new_bytes'],'floor':policy['floor_bytes'],'outstanding':other,'mutex':True,'policy_sha256':H(p.read_bytes())};r.setdefault('admissions',[]).append(g);save();assert g['NI']==10 and g['RAM']>=12*(1<<30)and g['disk']-g['growth']-other>=g['floor'],g
admission()
Y=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin/yosys'
profiles=[('mlab-async','MLAB',0),('logic-async','logic',0),('m10k-sync','M10K',1),('mlab-sync','MLAB',1)]
r['profiles']={}
for name,style,sync in profiles:
 header=(S/'arm_cpu_context.sv').read_text().split(' logic[1:0]ni_req,',1)[0].replace('module arm_cpu_context #','module context_top #',1)
 top=S/'context_top.sv';top.write_text(header+' arm_cpu_context #(.STORE_STYLE("'+style+'"),.STORE_SYNC('+str(sync)+')) selected(.*);\nendmodule\n')
 paths=[*files,top]
 script='read_slang --allow-use-before-declare --top context_top '+' '.join(map(str,paths))+'; proc; opt; opt_clean; scc; stat; write_json '+str(D/(name+'.json'))+'; memory_dff; opt; opt_clean; write_json '+str(D/(name+'-readports.json'))+'; memory_map context_top/selected.shared.engine.*_bank.backing; opt; opt_clean; stat; write_json '+str(D/(name+'-logic-fallback.json'))
 rc,log=call([Y,'-Q','-T','-m','slang','-p',script],name,180);assert rc==0,log[-2200:];assert 'Found 0 SCCs.' in log
 m=json.loads((D/(name+'.json')).read_text())['modules']['context_top'];q=json.loads((D/(name+'-readports.json')).read_text())['modules']['context_top']
 ff=lambda x:sum(int(c['parameters']['WIDTH'],2)for c in x['cells'].values()if 'dff' in c['type'])
 banks={n:v for n,v in m.get('memories',{}).items() if '.backing'in n}
 ports=[]
 for n,c in q['cells'].items():
  if c['type'].startswith(('$memrd','$memwr'))and'.backing'in c['parameters'].get('MEMID',''):ports.append({'name':n,'kind':c['type'],'parameters':c['parameters'],'clock':c['connections'].get('CLK',[])})
 fallback=json.loads((D/(name+'-logic-fallback.json')).read_text())['modules']['context_top']
 r['profiles'][name]={'fullcone_cells':len(m['cells']),'FF_before_read_merge':ff(m),'FF_after_read_merge':ff(q),'memory_objects':len(m.get('memories',{})),'total_logical_memory_bits':sum(v['width']*v['size']for v in m.get('memories',{}).values()),'banks':banks,'bank_ports_after_memory_dff':ports,'logic_fallback_cells':len(fallback['cells']),'logic_fallback_FF':ff(fallback),'SCC':0,'RTL_sha256':{p.name:H(p.read_bytes())for p in paths},'not_native_ALMs_RAM_or_STA':True}
 save();print(name,{k:r['profiles'][name][k]for k in ['fullcone_cells','FF_before_read_merge','FF_after_read_merge','memory_objects']},flush=True)
r['status']='FOUR_COMPLETE_FIXED_CONTEXT_PROFILES_FRONTEND_NOT_NATIVE_PRICE';save();fcntl.flock(lock,fcntl.LOCK_UN);status(r['status']);s=json.loads(STATUS.read_text());s['workers']=[];t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');os.replace(t,STATUS)
