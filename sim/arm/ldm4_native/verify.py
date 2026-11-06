#!/usr/bin/env python3
"""Replay the rejected native packet without compiling or running a model."""
from pathlib import Path
from collections import Counter
import argparse,hashlib,importlib.util,json,os,re,sys,tarfile,tempfile
os.setpriority(os.PRIO_PROCESS,0,10)
H=lambda b:hashlib.sha256(b).hexdigest()
p=argparse.ArgumentParser(description=__doc__);p.add_argument('packet',type=Path);a=p.parse_args()
with tarfile.open(a.packet)as t:data={m.name:t.extractfile(m).read()for m in t if m.isfile()}
read=lambda n:data[n];j=lambda n:json.loads(read(n))
m=j('manifest.json')
for n,h in m['files'].items():assert H(read(n))==h,n
plan=j('plan.json');r=j('results.json');report=j('report.json');frozen=j('frozen.json')
assert r['enabled_promotion'].startswith('FAIL ')and 'strict_state_failure'in r
assert set(r['models'])=={'before','ACK1'}and len(r['stages'])==8
assert all(x['NI']==10 and x['reaped']and x['exit']==0 for x in r['stages'])
assert H(read('plan.json'))==frozen['plan_SHA256']==r['plan_SHA256']
assert H(read('amendment.json'))==r['amendment_SHA256']
for mode in ['before','ACK1']:
 v=plan['variants'][mode]
 assert H(read(mode+'/model/Vtb_ds_pocket'))==r['models'][mode]['SHA256']
 assert r['models'][mode]['source']==v['source']and r['models'][mode]['profile']==v['profile']
 for rel,h in v['production_SHA256'].items():assert H(read(mode+'/source/'+rel))==h,(mode,rel)
 for rel,h in v['host_SHA256'].items():assert H(read(mode+'/'+rel))==h,(mode,rel)
 audit=j(mode+('/compile-input-binding-amended.json'if mode=='ACK1'else'/compile-input-binding.json'))
 for rel,record in audit['source_files'].items():assert H(read(mode+'/source/'+rel))==record['SHA256']
for rel,h in plan['input_SHA256'].items():
 if not rel.startswith('runtime/')and '__pycache__'not in Path(rel).parts:assert H(read('common/'+rel))==h,rel
assert dict(plan['variants']['before']['profile'],A7_LDM4_ACK=0)==plan['variants']['ACK0']['profile']
assert dict(plan['variants']['ACK0']['profile'],A7_LDM4_ACK=1)==plan['variants']['ACK1']['profile']
for rel,ops in j('join-source-inverse.json').items():
 text=read('ACK1/source/'+rel).decode()
 for x,y in ops:assert text.count(x)==1;(text:=text.replace(x,y))
 assert text.encode()==read('before/source/'+rel),rel
assert j('ACK0-reused-control.json')['profile_normalized_equal']
assert not j('controller-retired.json')['before_run_restarted']and not j('controller-retired.json')['obsolete_children_stopped']
for guest in ['unita7','ds30','unitmem']:
 B='before/runs/'+guest;N='ACK1/runs/'+guest;old=j(B+'/checked.json');new=j(N+'/checked.json')
 assert read(B+'/ldm4.words')==read(N+'/ldm4.words'),guest
 assert H(read(N+'/ldm4.words'))==new['words_SHA256']if 'words_SHA256'in new else True
 if guest=='unitmem':assert old['values']==new['values']and not old['activity']['words']and not new['activity']['words']
 if guest=='unita7':assert old['values'][12]==2892 and new['values'][12]==2130
 if guest=='ds30':assert old['values'][18]==1439 and new['values'][18]==1075 and new['full_state_equivalence']is False
 expected=26880 if guest=='unita7' else 28160 if guest=='ds30' else 0
 for record in [old,new]:assert record['activity']['words']==expected and record['activity']['admissions']==record['activity']['physical_ACKs']==expected
 if guest!='unitmem':
  before=[s.split(',')for s in read(B+'/ldm4.state').decode().splitlines()];after=[s.split(',')for s in read(N+'/ldm4.state').decode().splitlines()];assert len(before)==len(after)==expected//4
  counts=Counter(i for x,y in zip(before,after)for i,(xx,yy)in enumerate(zip(x,y))if xx!=yy)
  if guest=='unita7':assert set(counts)=={10,11,12,13,14,42,43,44,45,46}
  else:
   assert dict(counts)=={15:5632,47:5632,28:2496,60:2496,69:2496}
   assert before[4543][28]==after[4543][28]=='000011c0'
   assert before[4544][28]=='037f9aa0'and after[4544][28]=='000011c0'
   assert before[4544][69]=='041f'and after[4544][69]=='001f'
assert len(report['rows'])==85 and sum(x['ACK1_observed']is not None for x in report['rows'])==73
assert sum(x['omission']is not None for x in report['rows'])==12
# Restore only the small frozen checker inputs/captures for original validators.
with tempfile.TemporaryDirectory(prefix='ldm4-native-replay-')as tmp:
 T=Path(tmp)
 for name,b in data.items():
  keep=name=='common/native_guard.py'or name=='amendment/scoped_check.py'
  keep|=any(name.startswith(mode+'/runs/ds30/')and('/prepared/'in name or name.endswith(('manifest.json','checked.json','run.log','.jsonl','.bodies.bin','.main.bin')))for mode in ['before','ACK1'])
  if keep:q=T/name;q.parent.mkdir(parents=True,exist_ok=True);q.write_bytes(b)
 def module(name,path):
  s=importlib.util.spec_from_file_location(name,path);obj=importlib.util.module_from_spec(s);s.loader.exec_module(obj);return obj
 guard=module('native_original_guard',T/'common/native_guard.py')
 for mode in ['before','ACK1']:
  for guest,count in [('unita7',22),('unitmem',32)]:
   actual=guard.validate(read(mode+'/runs/'+guest+'/run.log').decode(),count,guest);assert actual['accepted']
   assert json.loads(json.dumps(actual))==j(mode+'/runs/'+guest+'/checked.json')['guards']
 B=T/'before/runs/ds30';sys.path.insert(0,str(B/'prepared'));original=module('ds30_original',B/'prepared/check_observer.py');actual=original.validate(B/'ldm4-ds30',B/'prepared',B/'manifest.json',B/'run.log');assert actual==j('before/runs/ds30/checked.json')['guards']
 scoped=module('ds30_scoped',T/'amendment/scoped_check.py');actual=scoped.validate(T/'ACK1/runs/ds30',T);assert actual==j('ACK1/runs/ds30/checked.json')['guards']
# Literal guest mapping places the banked LR at the unlock return instruction.
adapter=j('common/ds30/adapter-manifest.json');bodies=[x for x in adapter['preserved_bodies']if x['cpu']==7 and x['address']>>24==3]
offsets={x['ROM_offset']-(x['address']-0x037f8000)for x in bodies};assert offsets=={0x31264}
rom=read('common/roms/ds30.nds');base=0x31264
assert int.from_bytes(rom[base+0x1a98:base+0x1a9c],'little')==0xe121f003
assert int.from_bytes(rom[base+0x1a9c:base+0x1aa0],'little')==0xe12fff1e
print(f'PASS {len(m["files"])} hashed members;2actual models/6runs,85before+73ACK1values; words/order exact; quiet1075vs1439/DS1504 REJECT; strict IRQbankedstate mismatch preserved; ACK0 reuse/12omissions explicit')
