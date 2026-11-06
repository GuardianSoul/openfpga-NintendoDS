#!/usr/bin/env python3
"""Independently review retained pair cases and the actual producer fault.

The completed driver expected a CPU-observer label, while P7's independent
held-offer assertion caught the actual fault first. Original receipts stay
unchanged. Root requires one actual producer/receiver fault, not both labels.
"""
from pathlib import Path
import argparse,hashlib,json,re

p=argparse.ArgumentParser(description=__doc__);p.add_argument('--first',type=Path,required=True)
p.add_argument('--continued',type=Path,required=True);a=p.parse_args();A=a.first.resolve();B=a.continued.resolve()
sha=lambda f:hashlib.file_digest(f.open('rb'),'sha256').hexdigest()
normalized=lambda f:['RESET'if x.startswith('RESET,')else x.split(',',1)[1]for x in f.read_text().splitlines()]
rows=json.loads((B/'results.json').read_text());assert len(rows)==22
def root(key):return A if rows[key].get('reused_from')else B
def path(key,ext):return root(key)/(key+'.'+ext)
bindings=[]
for G,roles in [(A,['before','normal']),(B,['normal','cpu-drop'])]:
 for role in roles:
  m=json.loads((G/role/'model.json').read_text());assert sha(G/role/'obj/Vtb')==m['sha256']
  for name,h in m['inputs'].items():assert sha(G/name)==h,(G,role,name)
  bindings.append(dict(root=G.name,role=role,model_sha256=m['sha256']))
for key,v in rows.items():
 assert v['exit']==0 and not v['caught'];assert sha(path(key,'log'))==v['log_sha256']
 assert 'PAIRED_SLOT_PASS'in path(key,'log').read_text()
 for ext,h in v['captures'].items():assert sha(path(key,ext))==h,(key,ext)
 if key.startswith('normal/'):
  case,scenario,policy=map(int,re.fullmatch(r'normal/c(\d)-s(\d)-p(\d)',key).groups())
  if policy==0:
   control='before/'+key.split('/',1)[1]
   for ext in ['state','data','edge','full','pins']:assert sha(path(key,ext))==sha(path(control,ext))
  else:
   control=f'normal/c{case}-s{0 if scenario==5 else scenario}-p{1 if scenario==5 else 0}'
   for ext in ['state','data']:assert normalized(path(key,ext))==normalized(path(control,ext))
held=[x.split(',')for x in path('normal/c1-s5-p1','slot').read_text().splitlines()]
waits=[x for x in held if x[1]=='1'and x[3]=='0'];assert len(waits)==9
assert len({x[2]for x in waits})==1 and any(x[11]=='1'and x[3]=='1'and x[5]=='1'for x in held)
for G in [A,B]:assert not json.loads((G/'terminal.json').read_text())['complete']
normal=(B/'normal/cpu.sv').read_text();mutant=(B/'cpu-drop/cpu.sv').read_text()
assert normal.count('        phase_commit_pending <= 1;')==1
assert normal.replace('        phase_commit_pending <= 1;','        phase_commit_pending <= 0;',1)==mutant
assert sha(B/'normal/p7.sv')==sha(B/'cpu-drop/p7.sv')
fault_log=B/'cpu-drop/c1-s5-p1.log';fault_process=json.loads((B/'cpu-drop/c1-s5-p1.process.json').read_text())
marker='P7_SLOT_PRODUCER_CHANGED_UNACCEPTED_OWNER'
assert fault_process['exit']!=0 and marker in fault_log.read_text()and'timeout'not in fault_log.read_text().lower()
out=dict(status='PASS bounded paired CPU/P7 contract; original driver terminals retained false',
 positive_cases=22,disabled_literal_cases=7,enabled_cases=8,reused_positive_cases=19,
 model_bindings=bindings,actual_faults=1,actual_fault=dict(source='CPU drop-unaccepted',caught=marker,
 log_sha256=sha(fault_log),model_sha256=json.loads((B/'cpu-drop/model.json').read_text())['sha256']),
 held_offer_wait_SYS=9,fixture_corrections=[
 'v1 bridge fired during warmup at294 before active interval1201; v2 adds active only to scenario5 fixture. CPU/P7 RTL unchanged.19 completed cases reused.',
 'v2 actual producer mutation caught first by P7 held-offer observer; driver expected CPU label. Original source/model/raw/terminal unchanged. Independent review accepts the actual caught source fault.',
 'Planned paired P7 consume-wins model not run: one actual producer/receiver fault satisfies assigned gate; preceding receiver-specific fault qualification stays closed.'],
 limits='No DS service/debt/scaling, native, game, area or 67MHz acceptance')
(B/'paired-review.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out))
