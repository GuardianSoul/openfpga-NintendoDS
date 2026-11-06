#!/usr/bin/env python3
"""Read only the recorded controller's descendants; update the CPU owner file."""
from pathlib import Path
import datetime,json,os,subprocess,sys
ROOT=Path(__file__).resolve().parents[3];J=ROOT/'build/a7-native42'
if '--remote'in sys.argv:
 s=J/'sound';c=json.loads((J/'sound-controller.json').read_text());rows={};phase='original SOUND39'
 chain=J/'thumb/results/chain.json'
 if chain.exists():
  native=json.loads(chain.read_text());c={'PID':native['launcher_pid']};phase='DS42 native9'
 for line in subprocess.check_output(['ps','-eo','pid=,ppid=,ni=,comm='],text=True).splitlines():
  p,pp,ni,name=line.split(None,3);rows[int(p)]=(int(pp),int(ni)if ni!='-'else None,name)
 def own(pid):
  seen=set()
  while pid in rows and pid not in seen:
   if pid==c['PID']:return True
   seen.add(pid);pid=rows[pid][0]
  return False
 owned=[(p,*v)for p,v in rows.items()if own(p)];heavy=[r for r in owned if r[3]in['cc1plus','verilator_bin','Vtb_ds_pocket']]
 def start(pid):
  try:return int(Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()[19])
  except FileNotFoundError:return None
 active=heavy[-1][0]if heavy else None
 log=(J/'thumb/results/arm7thumb42/run.log')if chain.exists()else(s/'result-c7684/logs/full-core.log')
 print(json.dumps(dict(phase=phase,controller=c['PID'],PID=active,starttime={'controller':start(c['PID']),'PID':start(active)if active else None},owned=owned,updated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),log=log.read_text()[-1200:]if log.exists()else'pending')))
else:
 r=json.loads(subprocess.check_output(['ssh','zero-laptop','python3','-', '--remote'],input=Path(__file__).read_text().replace("ROOT=Path(__file__).resolve().parents[3]",f'ROOT=Path({str(ROOT)!r})'),text=True))
 (J/'live-worker.json').write_text(json.dumps(r,indent=2)+'\n')
 p=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json');j=json.loads(p.read_text());j.update(phase=r['phase']+' compiler/measurement active; original SOUND39 completed121routes',updated_at=r['updated_at'],next_action='DS42 native9 context/signature/DS comparison; original SOUND39 PCM analysis; no CPU39 repeat')
 j['worker'].update({k:r[k]for k in['controller','PID','starttime']});j['worker'].pop('state',None)
 q=p.with_name('CPU.json.tmp.'+str(os.getpid()));t=json.dumps(j,indent=2)+'\n';assert len(t.encode())<=2048;q.write_text(t);os.replace(q,p)
 print(json.dumps(r))
