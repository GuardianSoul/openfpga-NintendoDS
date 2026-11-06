#!/usr/bin/env python3
"""Replay the sealed STM4 proof without compiling RTL or running models."""
from pathlib import Path
import ast, hashlib, io, json, re, struct, tarfile
import argparse
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('packet',type=Path)
a=p.parse_args();R=a.packet.resolve()
sha=lambda b:hashlib.sha256(b).hexdigest()
def unpack(b):
 with tarfile.open(fileobj=io.BytesIO(b))as t:
  return {m.name:t.extractfile(m).read()for m in t if m.isfile()}
Q=json.loads((R/'qualification.json').read_text())
b=(R/Q['archive']['file']).read_bytes()
assert len(b)==Q['archive']['bytes'] and sha(b)==Q['archive']['sha256']
F=unpack(b);assert set(F)==set(Q['archive']['files'])
for n,v in Q['archive']['files'].items():
 assert len(F[n])==v['bytes'] and sha(F[n])==v['sha256'],n
txt=lambda n:F[n].decode()
js=lambda n:json.loads(F[n])

# Remove only additive metadata logic. Original CPU behavior must be exact.
s=txt('production/arm7_ds.sv')
s=s.replace('  parameter bit EXEC_META = 0,    // passive execution/DATA observations only\n  parameter bit STM4_META = 0     // narrow request/owned-accept metadata only\n','  parameter bit EXEC_META = 0     // passive execution/DATA observations only\n')
s=s.replace('  output a7_stm4_meta_t stm4_request,\n  output logic         stm4_accept,\n','')
s=s[:s.index('  generate if (STM4_META)')]+s[s.index('  generate if (EXEC_META)'):]
assert s==txt('before/arm7_ds.sv')
s=txt('production/arm_cpu.sv')
for line in ["  parameter bit          A7_STM4_META = 1'b0,\n",
 '  output a7_stm4_meta_t a7_stm4_request,\n','  output logic         a7_stm4_accept,\n',
 '      .stm4_request(a7_stm4_request), .stm4_accept(a7_stm4_accept),\n',
 "    assign a7_stm4_request = '0;\n","    assign a7_stm4_accept = 1'b0;\n"]:
 assert s.count(line)==1;s=s.replace(line,'')
s=s.replace(', .STM4_META(A7_STM4_META)','');assert s==txt('before/arm_cpu.sv')
s=txt('production/arm_pkg.sv')
s=s[:s.index('  // Request-time semantic tag')]+s[s.index('  // temp_addr update'):]
assert s==txt('before/arm_pkg.sv')

d=js('directed/results.json');assert len(d['cases'])==8 and d['status'].startswith('PASS')
assert d['base']==Q['base'] and d['source']==Q['production_commit']
for variant,model in d['models'].items():
 for name,digest in model['source_SHA256'].items():assert sha(F[f'directed/{variant}/source/{name}'])==digest
 if variant=='candidate':continue
 for name in d['models']['candidate']['source_SHA256']:
  expected=F['directed/candidate/source/'+name]
  if variant=='wrongbeat' and name=='arm7_ds.sv':
   expected=expected.replace(b"stm4_request.beat = 2'(5'd4 - left);",b"stm4_request.beat = 2'(5'd4 - left) ^ 2'b01;")
  if variant=='wrongowner' and name=='arm7_stm4_owner.sv':
   expected=expected.replace(b"physical_ack ? posted_owner : '0;",b"physical_ack ? answer_owner : '0;")
  assert F[f'directed/{variant}/source/{name}']==expected,(variant,name)
for name in ['arm7_ds.sv','arm_cpu.sv','arm_pkg.sv','arm7_stm4_owner.sv']:
 assert F['production/'+name]==F['directed/candidate/source/'+name]
program=F['directed/program.bin']
assert sha(program)==d['program']['binary_sha256']
for name in d['program']['eligible']:
 pc=d['program']['symbols'][name];ins=struct.unpack_from('<I',program,pc-0x03808000)[0]
 mask=ins&65535;rn=(ins>>16)&15
 assert ins>>28==14 and (ins>>25)&7==4 and (ins>>20)&31==8
 assert mask.bit_count()==4 and not mask&32768 and rn!=15 and not(mask&(1<<rn))
lane_re=r'STM_LANE_PASS mode(\d+) scenario(\d+) cycles(\d+) states(\d+) accepts(\d+) requests(\d+) admits(\d+) drains(\d+) turns(\d+) retries(\d+) faults(\d+)'
summary=[]
for case,row in d['cases'].items():
 log=txt('directed/'+case+'.log');assert sha(log.encode())==row['log_sha256']
 assert 'STM_BEHAVIOR_ALL_PASS' in log and row['full_behavior_exact']
 lanes=[list(map(int,x))for x in re.findall(lane_re,log)]
 assert len(lanes)==8 and lanes==row['lanes']
 for first in [0,4]:
  for kind in ['state','data','edge','mem','take']:
   values=[F[f'directed/{case}-m{m}.{kind}']for m in range(first,first+4)]
   assert all(values)and all(x==values[0]for x in values),(case,first,kind)
   if kind=='mem':assert all(len(x)==(65536+256)*9 for x in values)
 faults=[]
 for lane in [3,7]:
  events=[x.split(',')for x in txt(f'directed/{case}-m{lane}.meta').splitlines()]
  assert events and any(x[0]=='ADMIT' and int(x[4],16)&4 for x in events)
  faults+= [(x[0],x[1])for x in events if x[4]!=x[5]]
  assert all(x[0]in ['ADMIT','ACK']and len(x)==6 for x in events)
 if case.startswith('candidate'):
  assert row['exit']==0 and not faults and 'STM_METADATA_ALL_PASS'in log
  assert all(x[-1]==0 for x in lanes)
 else:
  assert row['exit']!=0 and faults and 'STM_METADATA_MUTATION_CAUGHT'in log
  assert all(x[-1]>0 for x in lanes if x[0]in [3,7])
  assert 'STM_METADATA_FAULT'in log
 summary.append(dict(case=case,enabled=[x for x in lanes if x[0]in [3,7]],event_faults=len(faults)))

c=js('cpu/results.json');assert c['base']==Q['base']
assert len(c['DENSE'])==25 and len(c['ARM'])==26 and c['status'].startswith('PASS')
for n,h in c['source_SHA256'].items():assert sha(F['cpu/source/'+n])==h
for name in ['arm7_ds.sv','arm_cpu.sv','arm_pkg.sv']:
 assert F['cpu/source/'+name]==F['production/'+name]
dep=R.parent/Q['input_dependency']['directory']
b=(dep/Q['input_dependency']['file']).read_bytes();assert sha(b)==Q['input_dependency']['sha256']
G=unpack(b);cuts=json.loads(G['gates/compare-cuts.json'])
for seed,row in c['DENSE'].items():
 cut=cuts[seed]
 def prefix(lines):return lines[:next(i for i,line in enumerate(lines)if line.startswith(cut+','))]
 actual=prefix(txt('cpu/seed'+seed+'.csv').splitlines())
 gold=prefix(G['gates/inputs/cpu-final-seed'+seed+'.csv'].decode().splitlines())
 assert actual==gold and len(actual)==row['states']and row['functional']and row['retained_gold_state_exact']
for case,row in c['ARM'].items():
 log=txt('cpu/ARM-'+case+'.log');assert row['exit']==0 and 'SWP_CPU_PAIR_PASS'in log
 if not row['functional']:
  old=G['gates/gold-suite/cpu-final-'+case+'.log'].decode()
  known='ctx1: timeout at pc=020000b8 retired=1490\nTEST FAILED (timeout)'
  assert case=='bpred7'and known in old and known in log
for result in [d,c]:
 for stage in result['stages']:
  expected=1 if stage['tag']in ['wrongbeat-s0','wrongowner-s0']else 0
  assert stage['exit']==expected and stage['reaped']and stage['NI']==10 and not stage.get('timeout')
domain=js('domain/results.json');assert len(domain['stages'])==8 and domain['erased_original_exact']
for name,h in domain['source_SHA256'].items():assert sha(F['domain/source/'+name])==h
assert F['domain/production.sv']==F['production/cpu_domain.sv']==F['domain/source/cpu_domain.sv']
assert F['domain/before.sv']==F['before/cpu_domain.sv']
nodes=ast.parse(txt('harness/check_domain.py')).body
additions=ast.literal_eval(next(n.value for n in nodes if isinstance(n,ast.Assign)and any(isinstance(t,ast.Name)and t.id=='additions'for t in n.targets)))
def erased(s):
 for v in additions:
  if s.count(v)!=1:return None
  s=s.replace(v,'')
 return s
assert erased(txt('domain/production.sv'))==txt('domain/before.sv')
for fault in domain['actual_source_faults_caught']:
 assert erased(txt('domain/'+fault+'.sv'))!=txt('domain/before.sv')
for stage in domain['stages']:assert stage['exit']==0 and stage['reaped']and stage['NI']==10
for row in js('checks/checks.json'):assert row['exit']==0
totals={k:sum(x[k]for x in list(c['DENSE'].values())+list(c['ARM'].values()))for k in ['pair_cycles','retired','writes','secondary']}
print(json.dumps(dict(status='PASS bounded STM4 metadata; original behavior exact',directed_cases=summary,
 DENSE=25,ARM_pass=25,inherited_failure='bpred7',CPU_totals=totals,domain_routes=8,DS_timing='no new claim'),indent=2))
