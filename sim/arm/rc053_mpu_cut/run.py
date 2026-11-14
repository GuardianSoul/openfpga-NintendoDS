from pathlib import Path
import os,json,subprocess,datetime
R=Path(__file__).resolve().parents[3];os.chdir(R);os.setpriority(os.PRIO_PROCESS,0,10)
O=R/'build/rc053-mpu-cut';S=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json')
def status(phase,child=None,rc=None):
 d=json.loads(S.read_text());d.update(updated=datetime.datetime.now(datetime.timezone.utc).isoformat(),phase=phase,workers=[] if child is None else [dict(host='Desktop',controller=os.getpid(),child=child,NI=10,jobs=1,threads=1)],rc=rc);t=S.with_suffix('.tmp');t.write_text(json.dumps(d));t.replace(S)
def run(cmd,log,phase):
 with (O/log).open('w') as f:
  p=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT,env={**os.environ,'OMP_NUM_THREADS':'1','OPENBLAS_NUM_THREADS':'1'});status(phase,p.pid);rc=p.wait()
 assert rc==0,(phase,rc)
try:
 assert int(next(l.split()[1] for l in Path('/proc/meminfo').read_text().splitlines() if l.startswith('MemAvailable:')))>=12*1024*1024
 run(json.loads((O/'full-command.json').read_text()),'full-build.log','MPU_CUT_FULL_POCKET_BUILD')
 (O/'preflight-result.json').write_text(json.dumps(dict(full_Pocket_PASS=True,qlint_PASS=True,qlint_apf_PASS=True)))
 run(['python3','sim/arm/rc053_mpu_cut/qualify.py'],'checks-driver.log','MPU_CUT_83_CPU_CHECKS')
 status('MPU_CUT_ALL_CHECKS_COMPLETE',rc=0)
except BaseException:
 status('MPU_CUT_WORKER_FAILED',rc=1);raise
