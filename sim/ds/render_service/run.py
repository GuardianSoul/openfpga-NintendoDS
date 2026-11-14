#!/usr/bin/env python3
"""One NI10/t1, admitted component worker; no game, fit or control rerun."""
from pathlib import Path
import argparse,json,re,sys
R=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(R/'sim/ds/ring_deadline'));import retained_trace_run as shared
run=shared.runner;run.admission=shared.admission
V='build/tools/oss-cad-suite/bin/verilator'
def main():
 ap=argparse.ArgumentParser();ap.add_argument('action',choices=['lint','build','positive','measure','native-owner','block-owner','deadline','phase2487','pressure','producer-hurry','head-off','head-on','head-owner','joint-on','joint-off','joint-mask']);ap.add_argument('--out',type=Path,required=True);a=ap.parse_args();B=a.out.resolve()
 snap=json.loads((B/'source.json').read_text())
 for p,h in snap['files'].items():assert run.sha(B/p)==h,p
 files=[B/'gpu2d_pkg.sv',B/'gpu3d_pkg.sv']+[p for p in sorted(B.glob('*.sv'))if p.name not in ['gpu2d_pkg.sv','gpu3d_pkg.sv']]
 if a.action in ['lint','build']:
  cmd=[V,'--lint-only'if a.action=='lint'else'--binary','--timing','--assert','--threads','1','-DG3D_RING_DEADLINE_OBSERVE','-Wno-fatal','-Wno-TIMESCALEMOD','-Wno-PINMISSING','-Wno-MULTIDRIVEN','-I'+str(B),'--top-module','render_service_tb','--Mdir',B/'obj']
  if a.action=='build':cmd+=['-j','1','-O1','--compiler','clang','-CFLAGS','-std=c++20 -O0','-MAKEFLAGS','CXX=clang++ VM_PARALLEL_BUILDS=1']
  cmd+=files;run.put(B/(a.action+'.command.json'),list(map(str,cmd)))
  component_prototype = 'head_admission_prototype' in snap or snap.get('profile') == 'joint capture runtime off by default'
  rc,t=run.worker(B,a.action,cmd,build=a.action=='build',growth=(64 if component_prototype else 256)<<20,seconds=600)
  if rc!=0:print(t[-7000:]);raise SystemExit(rc)
  if a.action=='build':run.put(B/'model.json',dict(source_sha256=run.sha(B/'source.json'),binary_sha256=run.sha(B/'obj/Vrender_service_tb')))
  print(a.action,'PASS');return
 assert run.sha(B/'obj/Vrender_service_tb')==json.loads((B/'model.json').read_text())['binary_sha256']
 faults={'native-owner':('+fault_native_owner','NATIVE_RETURN_OWNER_OR_VALUE'),'block-owner':('+fault_block_owner','nds_gpu3d: a block beat with no block in flight'),'deadline':('+fault_deadline','DELIVERY_DEADLINE')}
 flags=[];needle=None
 if a.action in faults:
  flag,needle=faults[a.action];flags=[flag]
 if a.action in ['measure','deadline','phase2487','pressure','producer-hurry']:flags+=['+measure_traffic_deadlines']
 if a.action.startswith('head-'):
  assert 'head_admission_prototype'in snap
  flags+=['+measure_traffic_deadlines']
  if a.action!='head-off':flags+=['+head_admit']
  if a.action=='head-owner':flags+=['+fault_borrow_owner'];needle='BLOCK_RETURN_OWNER_OR_VALUE'
 if a.action=='producer-hurry':flags+=['+producer_hurry']
 if a.action.startswith('joint-'):
  assert snap.get('profile') == 'joint capture runtime off by default'
  flags+=['+measure_traffic_deadlines']
  if a.action!='joint-off':flags+=['+joint_capture']
  if a.action=='joint-mask':
   flags+=['+fault_joint_capture_mask'];needle='JOINT_CAPTURE_MASK_OR_ADDRESS'
 if a.action=='phase2487':flags+=['+phase_ps=2487']
 cmd=[B/'obj/Vrender_service_tb','+trace='+str(B/(a.action+'.csv')),*flags]
 growth={'head-on':128,'head-off':48,'head-owner':48,'pressure':192,'producer-hurry':192,'joint-on':128,'joint-off':48}.get(a.action,64)
 rc,t=run.worker(B,a.action,cmd,growth=growth<<20,seconds=300)
 ok=rc!=0 and needle in t if needle else rc==0 and 'COMPLETE_CONE_PASS'in t
 m=re.search(r'TRAFFIC_DEADLINES mode=\d+ violations=(\d+),(\d+),(\d+),(\d+)',t)
 violations=list(map(int,m.groups()))if m else None
 measured='+measure_traffic_deadlines'in flags and needle is None
 deadline_pass=violations is not None and sum(violations)==0
 run.put(B/(a.action+'.result.json'),dict(PASS=ok and (deadline_pass if measured else True),measurement_complete=ok,
 data_owner_readiness_PASS=ok if needle is None else None,traffic_deadline_PASS=deadline_pass if measured else None,
 traffic_deadline_violations=violations,action=a.action,returncode=rc,fault=needle,scope='owner/data/3D-readiness only; every traffic deadline failure retained; no deadline acceptance'if measured else'unchanged-policy strict component',source_sha256=run.sha(B/'source.json'),model_sha256=run.sha(B/'obj/Vrender_service_tb'),log_sha256=run.sha(B/(a.action+'.log')),trace_sha256=run.sha(B/(a.action+'.csv'))))
 if measured:print('MEASUREMENT: data_owner_readiness',ok,'traffic_deadline_PASS',deadline_pass,'violations',violations)
 print(t[-2500:]);assert ok
if __name__=='__main__':main()
