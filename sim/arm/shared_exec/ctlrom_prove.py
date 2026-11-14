#!/usr/bin/env python3
"""Bounded symbolic gate for exact original D decoder and raw reconstruction."""
import os,pathlib,subprocess,json,hashlib,resource,fcntl,shutil,time,sys
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-ctlrom';S=D/'source';STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json');H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
ACTUAL='--actual'in sys.argv
TAG='actual-'if ACTUAL else''
TOP='ctlrom_actual_miter'if ACTUAL else'ctlrom_miter'
r={'status':'SYMBOLIC_PREPARING','PID':os.getpid(),'sources':{p.name:H(p)for p in S.glob('*.sv')},'stages':[]}
def save():(D/(TAG+'proof.json')).write_text(json.dumps(r,indent=2)+'\n')
def status(tag,p=None):
 s=json.loads(STATUS.read_text());s.update(phase=tag,source='ONEdefaultoffarm9_core_ctlrom prototype: pure originalD/tags/reconstruction symbolicgate beforeclockedRTL;774rejectedcost remainsclosed.',receipt=str(D/'proof.json'),required_disposition='Prototypeinprogress. No retained593cellencoder/capacityassumption; prove raw reconstruction andlatephase ownership before3cases/fault/80. No ownfit/game.',next_action='Symbolicfull301bitDpacket equality; then24bitroutingcatalogues<=512 and directsemanticIDgeneration; auditneggD->SYSElateIRQ/abort/hivec/MCR/stallinputs.',workers=[{'host':'Desktop','PID':os.getpid(),'NI':10,'peak_new_bytes':4294967296,'job':'ctlrom-symbolic'}]+([]if p is None else[{'host':'Desktop','PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'job':tag}]),updated_at=time.time());v=json.dumps(s,separators=(',',':'));assert len(v)<2048;t=STATUS.with_suffix('.tmp');t.write_text(v+'\n');os.replace(t,STATUS)
lock=open(pathlib.Path.home()/'.cache/nds-sim-build.lock','a');status('CTLROM_WAIT_MUTEX');fcntl.flock(lock,fcntl.LOCK_EX)
policy=json.loads(pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/host-disk-admission.json').read_text());other=0;seen=set()
for f in STATUS.parent.glob('*.json'):
 try:
  for q in json.loads(f.read_text()).get('workers',[]):
   if not isinstance(q,dict)or q.get('host')not in ['Desktop','desktop']:continue
   pid=q.get('PID',q.get('pid'))
   if not isinstance(pid,int)or pid in seen or pid==os.getpid()or not pathlib.Path('/proc',str(pid)).exists():continue
   seen.add(pid);other+=int(q.get('peak_new_bytes',q.get('disk_budget_bytes',0)))
 except(ValueError,TypeError,OSError):continue
mi=dict(x.split(':',1)for x in pathlib.Path('/proc/meminfo').read_text().splitlines());r['guard']={'NI':os.getpriority(os.PRIO_PROCESS,0),'RAM':int(mi['MemAvailable'].split()[0])*1024,'disk':shutil.disk_usage(W).free,'other_growth':other,'mutex':True};save();assert r['guard']['RAM']>=12*(1<<30)and r['guard']['disk']-policy['default_build_peak_new_bytes']-other>=policy['floor_bytes']
Y=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin/yosys';files=[S/(n+'.sv')for n in ['arm_pkg','ctlrom_decode_before','ctlrom_decode','ctlrom_reconstruct','ctlrom_miter']]
if ACTUAL:files=[S/(n+'.sv')for n in ['arm_pkg','ctlrom_decode_before','ctlrom_reconstruct','ctlrom_address','ctlrom_lut_comb','ctlrom_actual_miter']]
script='read_slang --allow-use-before-declare --top '+TOP+' '+' '.join(map(str,files))+f'; proc; opt; opt_clean; scc; write_json {D}/{TAG}miter-synthesis.json; sat -prove bad 0 -show-inputs -show bad -show oldp -show newp -show route -dump_json {D}/{TAG}counterexample.json'
with(D/(TAG+'reconstruction-miter.log')).open('w')as log:
 p=subprocess.Popen([Y,'-Q','-T','-m','slang','-p',script],stdout=log,stderr=subprocess.STDOUT);status('CTLROM_RECONSTRUCTION_MITER',p)
 try:rc=p.wait(timeout=120)
 except subprocess.TimeoutExpired:p.terminate();rc=p.wait(timeout=10)
text=(D/(TAG+'reconstruction-miter.log')).read_text();r['stages'].append({'PID':p.pid,'exit':rc,'script':script});r['status']='RECONSTRUCTION_MITER_PASS'if rc==0 and'no model found: SUCCESS'in text else'RECONSTRUCTION_MITER_FAIL';save();status(r['status']);s=json.loads(STATUS.read_text());s['workers']=[];t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');os.replace(t,STATUS);print(r['status'],flush=True)
