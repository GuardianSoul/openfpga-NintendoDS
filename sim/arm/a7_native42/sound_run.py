#!/usr/bin/env python3
from pathlib import Path
import datetime,json,os,resource,sys
ROOT=Path(__file__).resolve().parents[3];J=ROOT/'build/a7-native42';S=J/'sound'
os.setpriority(os.PRIO_PROCESS,0,10);os.environ['MAKEFLAGS']='-j1';resource.setrlimit(resource.RLIMIT_CORE,(0,0));sys.dont_write_bytecode=True
out=S/'result-c7684';os.environ['GATE_OUT']=str(out)
sys.path.insert(0,str(S/'helpers'));from sound_v2_full_run import run
(J/'sound-controller.json').write_text(json.dumps(dict(PID=os.getpid(),NI=10,jobs=1,threads=1,started_at=datetime.datetime.now(datetime.timezone.utc).isoformat()),indent=2)+'\n')
r=run(S/'prepared',S/'inputs/reference',7684,out,21600,S/'inputs/qualification.json',S/'inputs/DS',S/'inputs/perftime.nds',defer_analysis=True)
assert r['complete_packet'];model=json.loads((out/'model.json').read_text());r['compiled_model']=dict(path=model['argv'][0],sha256=model['sha256'])
(S/'execute-result.json').write_text(json.dumps(r,indent=2)+'\n')
sys.path.insert(0,str(S/'reader'));from sound_setup_report import report
w=report(out/'setup.csv');(out/'setup-report.json').write_text(json.dumps(w,indent=2)+'\n');assert w['schema_version']==2 and w['writes']==121 and w['route_verified']==121
print('SOUND_NATIVE39_REPLY_PASS121 routes; DS/PCM analysis follows',flush=True)
