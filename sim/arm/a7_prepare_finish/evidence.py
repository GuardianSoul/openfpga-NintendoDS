#!/usr/bin/env python3
"""Seal/replay the bounded phase trial without a component or public rebuild."""
from pathlib import Path
from collections import Counter
import argparse, csv, hashlib, io, json, os, resource, tarfile

R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=['seal','replay']);p.add_argument('--output',type=Path,required=True);p.add_argument('--packet',type=Path);a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));resource.setrlimit(resource.RLIMIT_CPU,(30,30));resource.setrlimit(resource.RLIMIT_AS,(512*1024**2,512*1024**2));resource.setrlimit(resource.RLIMIT_FSIZE,(64*1024**2,64*1024**2))
sha=lambda b:hashlib.sha256(b).hexdigest()
def summary(B):
 result=json.loads((B/'attempt1/results.json').read_text());assert len(result['rows'])==6
 assert all(s['exit']==0 and s['reaped']for s in result['stages'])
 for f,digest in result['fixture_SHA256'].items():assert sha((B/'attempt1/source'/f).read_bytes())==digest
 phase=[];before=[]
 for case in range(3):
  owned=None;tokens=[]
  for r in csv.DictReader((B/f'attempt1/c{case}-r1-p0-n16.edge').open()):
   t=int(r['cycle'])
   if owned is None and r['ir']=='1'and r['e_mul']=='1':owned=dict(offer=t,pc=r['pc'],ia=r['ia'],advance=None,ready=None)
   if owned is not None:
    assert(owned['pc'],owned['ia'])==(r['pc'],r['ia'])
    if r['pipe_fire']=='1'and r['esub']=='0'and owned['advance'] is None:
     owned.update(advance=t,raw_ok=int(r['io']),left=int(r['flow_left']))
    if r['ph']=='1'and r['io']=='1'and owned['ready'] is None:owned['ready']=t
    if r['consume']=='1':tokens.append(owned);owned=None
  assert owned is None and len(tokens)==1024 and all(x['raw_ok']==0 and x['left']==2 and x['ready']>x['advance']for x in tokens)
  before.append(dict(case=case,tokens=1024,finish_after_first_advance_SYS=dict(Counter(str(x['ready']-x['advance'])for x in tokens))))
  for region in [0,1]:
   for n in [4,16]:
    for suffix in ['state','data']:
     lanes=[(B/f'attempt1/c{case}-r{region}-p{policy}-n{n}.{suffix}').read_text().splitlines()for policy in[0,1]]
     assert[[l.split(',',1)[1]for l in lane]for lane in lanes][0]==[[l.split(',',1)[1]for l in lane]for lane in lanes][1]
     if region==0:assert lanes[0]==lanes[1]
   edges=list(csv.DictReader((B/f'attempt1/c{case}-r{region}-p1-n16.phase').open()))
   counts={k:sum(int(r[k])for r in edges)for k in ['F_finish','prepare','next_commit']}
   assert all(v==(1024 if region else 0)for v in counts.values())
   finish=None;prepared=None
   for r in edges:
    t=int(r['cycle'])
    if r['F_finish']=='1':assert finish is None;finish=t
    if r['prepare']=='1':assert finish is not None and finish<=t;prepared=int(r['pc'],16)+12
    if r['prepared']=='1':assert int(r['next_address'],16)==prepared
    if r['next_commit']=='1':assert r['consume']=='1'and r['redirect']=='0'
    if r['consume']=='1'or r['redirect']=='1':finish=None;prepared=None
   phase.append(dict(case=case,region=region,counts=counts))
 controls=json.loads((B/'nonmul2/results.json').read_text());assert len(controls['rows'])==36
 assert controls['core_trial_SHA256']==result['fixture_SHA256']['arm7_ds.sv']
 for row in controls['rows']:
  stem=row['case']+'-n'+str(row['loops'])
  assert'NONMUL_PAIR_EXACT_PASS'in(B/'nonmul2'/(stem+'.log')).read_text()
  for suffix in ['csv','data','fcomp']:
   assert(B/'nonmul2'/f'{stem}-m0.{suffix}').read_bytes()==(B/'nonmul2'/f'{stem}-m1.{suffix}').read_bytes()
 for scenario,directory in [(1,'adverses2'),(2,'adverses2'),(3,'adverses3'),(4,'adverses3')]:
  data=json.loads((B/directory/'results.json').read_text());assert data['trial_RTL_SHA256']==result['fixture_SHA256']['arm7_ds.sv']
  for policy in [0,1]:assert'ADVERSE_PASS'in(B/directory/f's{scenario}-p{policy}.log').read_text()
  for suffix in ['state','data']:
   lanes=[(B/directory/f's{scenario}-p{policy}.{suffix}').read_text().splitlines()for policy in[0,1]]
   values=[['RESET'if x.startswith('RESET,')else x.split(',',1)[1]for x in lane]for lane in lanes];assert values[0]==values[1]
 faults={}
 for directory in ['early-internal2','early-commit']:
  data=json.loads((B/directory/'results.json').read_text());assert data['actual_fault_caught']
  log=(B/directory/(data['fault_case']+'.log')).read_text()
  assert'PHASE_FUNCTION_PASS'in log and'PHASE_PROTOCOL_MUTATION_CAUGHT'in log
  faults[directory]=dict(case=data['fault_case'],actual_fault_caught=True)
 return dict(status='PASS bounded phase/architecture/control proof; MAIN timing repair rejected',
             rows=result['rows'],before=before,phase=phase,nonMUL_exact_rows=36,adverses=4,actual_RTL_faults=faults,
             production_enable=False,remaining='Memory logical-slot acceptance/service progression; prepared intent is not accepted P7 access')

D=a.output.resolve();D.mkdir(parents=True,exist_ok=False)
if a.action=='seal':
 B=R/'build/a7-prepare-finish';s=summary(B);files={}
 for directory in ['attempt1','nonmul1','nonmul2','adverses1','adverses2','adverses3','early-internal','early-internal2','early-commit']:
  for f in sorted((B/directory).rglob('*')):
   if not f.is_file()or'obj'in f.parts or'__pycache__'in f.parts:continue
   if f.suffix=='.edge'and not(directory=='attempt1'and f.name in [f'c{i}-r1-p0-n16.edge'for i in range(3)]):continue
   files[str(f.relative_to(B))]=f.read_bytes()
 for f in (R/'sim/arm/a7_prepare_finish').iterdir():
  if f.is_file():files['scripts/'+f.name]=f.read_bytes()
 files['summary.json']=(json.dumps(s,indent=2)+'\n').encode()
 manifest={k:sha(v)for k,v in files.items()};files['manifest.json']=(json.dumps(manifest,indent=2)+'\n').encode()
 target=D/'proof.tar.gz'
 with tarfile.open(target,'w:gz')as t:
  for name,data in sorted(files.items()):
   info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o644;info.mtime=0;t.addfile(info,io.BytesIO(data))
 receipt=dict(members=len(files),expanded_bytes=sum(map(len,files.values())),SHA256=sha(target.read_bytes()),production_enable=False)
 (D/'seal.json').write_text(json.dumps(receipt,indent=2)+'\n');(D/'summary.json').write_text(json.dumps(s,indent=2)+'\n');print(json.dumps(receipt))
else:
 with tarfile.open(a.packet)as t:
  assert all(m.isfile()or m.isdir()for m in t.getmembers());assert sum(m.size for m in t.getmembers())<128*1024**2;t.extractall(D,filter='data')
 manifest=json.loads((D/'manifest.json').read_text())
 for name,digest in manifest.items():assert sha((D/name).read_bytes())==digest,name
 observed=summary(D);assert observed==json.loads((D/'summary.json').read_text())
 print('PASS',len(manifest),'pinned inputs; phase/state/control/fault replay, no model execution')
