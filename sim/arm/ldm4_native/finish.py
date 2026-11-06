#!/usr/bin/env python3
"""Source/input post-bindings and unadjusted numeric report for the pinned gate."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,os
os.setpriority(os.PRIO_PROCESS,0,10)
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path);a=p.parse_args();D=a.directory.resolve();plan=json.loads((D/'plan.json').read_text());result=json.loads((D/'results.json').read_text())
assert result['state'].startswith('COMPLETE '),result['state']
frozen=json.loads((D/'frozen.json').read_text());assert H(D/'plan.json')==result['plan_SHA256']==frozen['plan_SHA256']
spec=importlib.util.spec_from_file_location('scorecard_ref',D/'ACK1/source/tools/scorecard/scorecard.py');sc=importlib.util.module_from_spec(spec);spec.loader.exec_module(sc)
rows=[];bindings=0;state=[]
for name,v in plan['variants'].items():
 V=D/name
 for rel,h in v['production_SHA256'].items():assert H(V/'source'/rel)==h,(name,rel);bindings+=1
 for rel,h in v['host_SHA256'].items():assert H(V/rel)==h,(name,rel);bindings+=1
 assert H(V/'source-profile.json')==frozen['source_profile_SHA256'][name]
 assert H(V/'model/Vtb_ds_pocket')==result['models'][name]['SHA256']
 audit=json.loads((V/'compile-input-binding.json').read_text())
 for rel,record in audit['source_files'].items():assert H(V/'source'/rel)==record['SHA256'],(name,rel);bindings+=1
 for path,h in audit['explicit_compiler_files'].items():assert H(Path(path))==h,path;bindings+=1
for rel,h in plan['input_SHA256'].items():assert H(D/'common'/rel)==h,rel;bindings+=1
for guest in plan['guests']:
 checks={name:json.loads((D/name/'runs'/guest/'checked.json').read_text())for name in plan['variants']}
 if guest=='ds30':
  for slot,entry in enumerate(checks['before']['guards']['rows']):
   ds=entry['DS_x100'];vals={name:c['values'][slot]for name,c in checks.items()};rows.append({'guest':guest,'slot':slot,'name':entry['kernel'],'arg':entry['arg'],'DS_x100':ds,**vals,'before_over_DS':vals['before']/ds,'ACK1_over_DS':vals['ACK1']/ds})
 else:
  for slot,entry in enumerate(sc.ROWS[guest]):
   ds=entry[2];vals={name:c['values'][slot]for name,c in checks.items()};rows.append({'guest':guest,'slot':slot,'name':entry[0],'DS_x100':ds,**vals,'before_over_DS':vals['before']/ds if ds else None,'ACK1_over_DS':vals['ACK1']/ds if ds else None})
 state.append({'guest':guest,'activity':{n:c['activity']for n,c in checks.items()},'ACK1_state':checks['ACK1'].get('state_differences')})
assert all(x['before']==x['ACK0']for x in rows)
post={'status':'POST source/profile/input/model integrity PASS; numeric differences unadjusted','source':plan['reference_source'],'checked_bindings':bindings,'models':result['models'],'stages_reaped':len(result['stages']),'rows':rows,'ownership_state':state,'limits':plan['open_gates']}
(D/'report.json').write_text(json.dumps(post,indent=2)+'\n');print(json.dumps({'bindings':bindings,'rows':len(rows),'LDM4':[x for x in rows if x['name']in['LDM4MAIN','ldm4_main']]}))
