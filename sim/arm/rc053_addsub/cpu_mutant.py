"""Build a real arm9_core carry mutant and require its address assertion to fire."""
from pathlib import Path
import os,json,subprocess,hashlib,datetime
R=Path(__file__).resolve().parents[3];os.chdir(R);O=R/'build/rc053-cpu/checks';os.setpriority(os.PRIO_PROCESS,0,10)
assert json.loads((R/'build/rc053-cpu/lease.json').read_text())['authorized']
assert json.loads((O/'result.json').read_text())['PASS']
assert int(next(l.split()[1]for l in Path('/proc/meminfo').read_text().splitlines()if l.startswith('MemAvailable:')))>=12*1024*1024
src=R/'build/rc053-cpu/formal/actual-wrongcarry-source.sv';cmd=json.loads((O/'candidate-cmd.json').read_text());cmd[cmd.index('--Mdir')+1]=str(O/'obj-wrongcarry');cmd=[str(src)if x==str(O/'candidate.sv')else x for x in cmd]
def run(cmd,log,phase):
 with log.open('w')as f:
  p=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT);s=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json');d=json.loads(s.read_text());d.update(updated=datetime.datetime.now(datetime.timezone.utc).isoformat(),phase=phase,workers=[dict(host='Desktop',controller=os.getpid(),child=p.pid,NI=10,jobs=4,threads=1)]);t=s.with_suffix('.tmp');t.write_text(json.dumps(d));t.replace(s);return p.wait()
assert run(cmd,O/'wrongcarry-build.log','CPU actual carry-mutant build')==0
cmd=[str(O/'obj-wrongcarry/Vtb_arm'),'+img0=/home/user/Git/NDS_Pocket-codex-rc7-rf-m10k/build/rf-m10k-cpu/rnd-1-01.hex','+pc0=02000000','+run=1','+maxcycles=2000000'];rc=run(cmd,O/'wrongcarry-run.log','CPU actual carry-mutant simulation');text=(O/'wrongcarry-run.log').read_text();assert rc!=0 and 'arm9_core: address adder' in text and 'TEST PASSED'not in text,text[-1500:]
result=dict(caught=True,source_SHA256=hashlib.sha256(src.read_bytes()).hexdigest(),rc=rc,reason='actual negative-offset address differs from unchanged ALU; core assertion fires',cmd=cmd);(O/'cpu-mutant-result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result))
