#!/usr/bin/env python3
"""Unadjusted amended native report; omitted enabled rows remain explicit nulls."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,os
os.setpriority(os.PRIO_PROCESS,0,10)
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path);a=p.parse_args();D=a.directory.resolve();plan=json.loads((D/'plan.json').read_text());result=json.loads((D/'results.json').read_text())
assert result['state'].startswith('COMPLETE amended'),result['state']
assert H(D/'plan.json')==result['plan_SHA256']and H(D/'amendment.json')==result['amendment_SHA256']
proof=json.loads((D/'ACK0-reused-control.json').read_text());assert proof['profile_normalized_equal']
spec=importlib.util.spec_from_file_location('ref_scorecard',D/'ACK1/source/tools/scorecard/scorecard.py');sc=importlib.util.module_from_spec(spec);spec.loader.exec_module(sc)
bindings=0
for name in ['before','ACK1']:
 V=D/name;v=plan['variants'][name]
 for rel,h in v['production_SHA256'].items():assert H(V/'source'/rel)==h,(name,rel);bindings+=1
 for rel,h in v['host_SHA256'].items():assert H(V/rel)==h,(name,rel);bindings+=1
 audit=json.loads((V/('compile-input-binding-amended.json'if name=='ACK1'else'compile-input-binding.json')).read_text())
 for rel,rec in audit['source_files'].items():assert H(V/'source'/rel)==rec['SHA256'],(name,rel);bindings+=1
 for path,h in audit['explicit_compiler_files'].items():assert H(Path(path))==h,path;bindings+=1
 assert H(V/'model/Vtb_ds_pocket')==result['models'][name]['SHA256']
for rel,h in plan['input_SHA256'].items():assert H(D/'common'/rel)==h,rel;bindings+=1
rows=[];state=[]
for guest in plan['guests']:
 old=json.loads((D/'before/runs'/guest/'checked.json').read_text());new=json.loads((D/'ACK1/runs'/guest/'checked.json').read_text())
 if guest=='ds30':assert len(old['values'])==31 and len(new['values'])==19 and new['guards']['prehistory_exact_to_LDM_call']
 for slot,value in enumerate(old['values']):
  entry=old['guards']['rows'][slot]if guest=='ds30'else None;name=entry['kernel']if entry else sc.ROWS[guest][slot][0];ds=entry['DS_x100']if entry else sc.ROWS[guest][slot][2]
  after=new['values'][slot]if slot<len(new['values'])else None
  rows.append({'guest':guest,'slot':slot,'name':name,'arg':entry.get('arg')if entry else None,'DS_x100':ds,'before_observed':value,'ACK0_reused_exact_erasure':value,'ACK1_observed':after,'before_over_DS':value/ds if ds else None,'ACK1_over_DS':after/ds if ds and after is not None else None,'omission':'Later quiet row outside bounded affected-LDM gate; enabled behavior unproven'if after is None else None})
 state.append({'guest':guest,'before':old['activity'],'ACK1':new['activity'],'ACK1_state_differences':new.get('state_differences')})
assert len(rows)==85 and sum(x['ACK1_observed']is not None for x in rows)==73
report={'status':'POST source/model/input integrity PASS; unadjusted timing and state differences retained','reference_source':plan['reference_source'],'before_source':plan['before_source'],'models':result['models'],'ACK0_model':'No duplicate model built; exact-erased before control reused with its actual9fca source/model/profile labels.','checked_bindings':bindings,'rows':rows,'ownership_state':state,'response_boundary':json.loads((D/'response-boundary-correction.json').read_text()),'scope':'ACK1 canonical22 + originalquietprefix19/50bodies/20calls/exactprehistory + memory32.12laterquietrows not accepted; no scene/audio/deadline/area/STA claim.'}
(D/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'bindings':bindings,'rows':85,'ACK1_rows':73,'LDM4':[x for x in rows if x['name']in['LDM4MAIN','ldm4_main']]}))
