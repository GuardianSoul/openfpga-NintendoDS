"""One global build lock; check memory after acquisition, never nest locks."""
from pathlib import Path
import fcntl,subprocess,os,sys,json,datetime
os.setpriority(os.PRIO_PROCESS,0,10);S=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json')
def status(phase,child):
 d=json.loads(S.read_text());d.update(updated=datetime.datetime.now(datetime.timezone.utc).isoformat(),phase=phase,workers=[dict(host='Desktop',controller=os.getpid(),child=child,NI=10,jobs=1,threads=1)]);t=S.with_name(S.name+'.'+str(os.getpid())+'.tmp');t.write_text(json.dumps(d));t.replace(S)
status('TAGS_CONTROLLER_BUILD_WAIT_GLOBAL_MUTEX',os.getpid())
with (Path.home()/'.cache/nds-sim-build.lock').open('a')as lock:
 fcntl.flock(lock,fcntl.LOCK_EX)
 assert int(next(l.split()[1]for l in Path('/proc/meminfo').read_text().splitlines()if l.startswith('MemAvailable:')))>=12*1024*1024,'need12GiB after mutex'
 c=subprocess.Popen(['build/tools/oss-cad-suite/bin/verilator',*sys.argv[1:]],env={**os.environ,'OMP_NUM_THREADS':'1','OPENBLAS_NUM_THREADS':'1'});status('TAGS_CONTROLLER_ONE_J1_BUILD_ACTIVE',c.pid);sys.exit(c.wait())
