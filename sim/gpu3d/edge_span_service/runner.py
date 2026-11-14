"""One-owner bounded worker with Root's declared-growth disk admission."""
from pathlib import Path
import fcntl,hashlib,json,os,resource,shutil,subprocess,time
R=Path(__file__).resolve().parents[3];MAIN=Path('/home/user/Git/NDS_Pocket');STATUS=MAIN/'build/coordinator/units/Raster.json';POLICY=MAIN/'build/coordinator/host-disk-admission.json'
DEFAULT_GROWTH=256*1024**2

def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def put(p,d):
 t=p.with_suffix(p.suffix+'.tmp');t.write_text(json.dumps(d,indent=2)+'\n');t.replace(p)
def status(**v):
 d=json.loads(STATUS.read_text());d.update(updated_at=time.time(),**v);s=json.dumps(d,separators=(',',':'))+'\n';assert len(s.encode())<=2048;t=STATUS.with_suffix('.Raster.tmp');t.write_text(s);t.replace(STATUS)
def admission(out,growth=DEFAULT_GROWTH):
 policy=json.loads(POLICY.read_text());others=0;reservations=[]
 for p in(MAIN/'build/coordinator/units').glob('*.json'):
  if p==STATUS:continue
  try:d=json.loads(p.read_text())
  except(ValueError,OSError):continue
  workers=d.get('workers',[])
  # New reservations are authoritative; legacy active build workers get
  # the declared default so they cannot silently consume another job's floor.
  if workers and isinstance(workers,list)and any(w.get('host','').startswith('Desktop')for w in workers if isinstance(w,dict)):
   n=d.get('disk_growth_bound_bytes')
   if n is None:n=policy['default_build_peak_new_bytes']if'BUILD'in d.get('phase','').upper()else policy['simulation_output_cap_bytes']
   others+=int(n);reservations.append(dict(owner=p.stem,bytes=n))
 free=shutil.disk_usage(R).free;mem=int(next(x.split()[1]for x in Path('/proc/meminfo').read_text().splitlines()if x.startswith('MemAvailable:')))*1024
 receipt=dict(at=time.time(),policy_sha256=sha(POLICY),free_bytes=free,mem_available_bytes=mem,other_reservations=reservations,declared_growth_bound_bytes=growth,floor_bytes=policy['floor_bytes'],admitted=free-others-growth>=policy['floor_bytes']and mem>=12*1024**3)
 put(out,receipt)
 if not receipt['admitted']:
  status(phase='EDGE_SPAN_RESOURCE_BLOCKED',workers=[],resource_blocker=f'diskfree{free}/other{others}/growth{growth}/floor{policy["floor_bytes"]};RAM{mem}')
  raise RuntimeError('declared-growth admission failed')
 return receipt

def worker(out,tag,cmd,build=False,growth=DEFAULT_GROWTH,seconds=600):
 os.setpriority(os.PRIO_PROCESS,0,max(10,os.getpriority(os.PRIO_PROCESS,0)));resource.setrlimit(resource.RLIMIT_CORE,(0,0))
 mutex=None
 if build:
  mutex=(Path.home()/'.cache/nds-sim-build.lock').open('a');status(phase='EDGE_SPAN_BUILD_MUTEX_WAIT',workers=[]);fcntl.flock(mutex,fcntl.LOCK_EX)
 admission(out/(tag+'.admission.json'),growth)
 log=out/(tag+'.log');assert not log.exists();initial=sum(p.stat().st_size for p in out.rglob('*')if p.is_file());start=time.time()
 with log.open('x')as f:
  p=subprocess.Popen(list(map(str,cmd)),cwd=R,stdout=f,stderr=subprocess.STDOUT,start_new_session=True);ni=os.getpriority(os.PRIO_PROCESS,p.pid);assert ni==10
  record=dict(pid=p.pid,parent=os.getpid(),host='Desktop',ni=ni,threads=1,command=list(map(str,cmd)),start=start,growth_bound_bytes=growth)
  put(out/(tag+'.process.json'),record);status(phase='EDGE_SPAN_'+tag.upper(),workers=[{k:record[k]for k in ['pid','parent','host','ni','threads']}],disk_growth_bound_bytes=growth,resource_blocker=None)
  while p.poll()is None:
   size=sum(q.stat().st_size for q in out.rglob('*')if q.is_file())-initial
   if time.time()-start>seconds or size>growth or log.stat().st_size>16*1024**2:
    os.killpg(p.pid,15);p.wait(timeout=10);raise RuntimeError('own worker time/output/growth bound')
   time.sleep(.1)
 if mutex:mutex.close()
 record.update(returncode=p.returncode,seconds=time.time()-start,log_sha256=sha(log));put(out/(tag+'.receipt.json'),record);status(phase='EDGE_SPAN_WORKER_REAPED',workers=[],disk_growth_bound_bytes=0);return p.returncode,log.read_text()
