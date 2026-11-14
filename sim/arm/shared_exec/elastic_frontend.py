#!/usr/bin/env python3
"""Registered ARM7 port regression: corrected link versus previous actual RTL."""
import pathlib,subprocess,os,json,hashlib,fcntl,resource,time,shutil,re
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-shared-elastic-frontend';D.mkdir(exist_ok=True);S=D/'source';S.mkdir(exist_ok=True)
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
for n in ['arm_shared_elastic','arm_dual_elastic','arm_cpu_elastic']:
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
script='read_slang --allow-use-before-declare --top arm_cpu_elastic '+' '.join(map(str,files))+'; proc; opt; opt_clean; scc; stat; write_json '+str(D/'full-cone.json')+'; memory_map arm_cpu_elastic/shared.engine.*_ctx; opt; opt_clean; scc; stat; write_json '+str(D/'bank-mapped.json')
rc,log=call([Y,'-Q','-T','-m','slang','-p',script],'frontend',180);assert rc==0,log[-2200:];assert 'Found 0 SCCs.' in log
m=json.loads((D/'full-cone.json').read_text())['modules']['arm_cpu_elastic'];counts=collections.Counter(c['type']for c in m['cells'].values());regs=[]
for n,c in m['cells'].items():
 if 'dff' in c['type']:
  width=c['parameters'].get('WIDTH','0');width=int(width,2)if isinstance(width,str)else width
  regs.append({'name':n,'bits':width,'clock':c['connections'].get('CLK',[])})
assert not any('g_a9c' in n or 'g_a7ds' in n for n in m['netnames'])
mem=m.get('memories',{});old=json.loads((W/'build/cpu232-shared-native/frontend-result.json').read_text())['replacement']
mapped=json.loads((D/'bank-mapped.json').read_text())['modules']['arm_cpu_elastic'];mapped_ff=sum(int(c['parameters']['WIDTH'],2)for c in mapped['cells'].values()if 'dff' in c['type']);assert not any('_ctx' in n for n in mapped.get('memories',{}))
r['bank_mapped']={'cells':len(mapped['cells']),'FF_bits':mapped_ff,'memory_objects':len(mapped.get('memories',{})),'logical_memory_bits':sum(x['width']*x['size'] for x in mapped.get('memories',{}).values()),'not_native_ALM':True}
r.update(status='COMPLETE_ONE_ENGINE_FRONTEND_PASS_NOT_NATIVE_PRICE',RTL_sha256={p.name:H(p.read_bytes())for p in files},unmapped_cells=len(m['cells']),FF_bits=sum(x['bits']for x in regs),clocked_registers=regs,cell_types=dict(counts),memories=mem,SCC=0,retained_shared_reference={'cells':old['unmapped_cells'],'FF_bits':old['FF_bits'],'memory_objects':len(old['memories']),'note':'retained frontend predates registered A7 launch flags; not native 2183 cost'},duplicate_original_controllers=False)
save();print({k:r[k]for k in ['status','unmapped_cells','FF_bits','SCC']},flush=True)
fcntl.flock(lock,fcntl.LOCK_UN);status(r['status']);q=json.loads(STATUS.read_text());q['workers']=[];t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(q,separators=(',',':'))+'\n');os.replace(t,STATUS)
