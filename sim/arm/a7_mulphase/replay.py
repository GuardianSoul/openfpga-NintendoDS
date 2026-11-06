#!/usr/bin/env python3
"""Offline integrity, exact behavior and fault-control replay; no simulator."""
from pathlib import Path
import argparse,ast,hashlib,io,json,os,re,resource,tarfile,tempfile
p=argparse.ArgumentParser(description=__doc__);p.add_argument('packet',type=Path);a=p.parse_args();D=a.packet.resolve()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CPU,(60,60));resource.setrlimit(resource.RLIMIT_AS,(1536*1024**2,1536*1024**2))
sha=lambda b:hashlib.sha256(b).hexdigest()
def unpack(b):
 with tarfile.open(fileobj=io.BytesIO(b))as t:return{m.name:t.extractfile(m).read()for m in t if m.isfile()}
Q=json.loads((D/'qualification.json').read_text());b=(D/Q['archive']['file']).read_bytes();assert len(b)==Q['archive']['bytes']and sha(b)==Q['archive']['sha256'];F=unpack(b)
assert set(F)==set(Q['archive']['files'])
for n,v in Q['archive']['files'].items():assert len(F[n])==v['bytes']and sha(F[n])==v['sha256'],n
txt=lambda n:F[n].decode();js=lambda n:json.loads(F[n])
# Passive additions must erase to the literal previous source, including
# the shared expression aliases used by the pre-existing full observer.
s=txt('production/arm7_ds.sv')
s=s.replace('  parameter bit STM4_META = 0,    // narrow request/owned-accept metadata only\n  parameter bit MUL_META = 0      // passive request-time MUL context / advances\n','  parameter bit STM4_META = 0     // narrow request/owned-accept metadata only\n')
s=s.replace('  output a7_mul_context_t mul_request,\n  output a7_mul_advance_t mul_advance,\n','')
s=s[:s.index('  wire [2:0] mul_work_steps')]+s[s.index('  generate if (STM4_META)'):]
s=s.replace('wire mul_advance = mul_exec_step;','wire mul_advance = pipe_fire && e_mul && (esub == 2\'d0 || esub == 2\'d1);')
s=s.replace('exec_meta.steps = e_mul ? mul_work_steps :','exec_meta.steps = e_mul ? mterm + {2\'d0, ins[21]} :')
assert s==txt('before/arm7_ds.sv')
s=txt('production/arm_cpu.sv')
for line in ["  parameter bit          A7_MUL_META = 1'b0,\n",'  output a7_mul_context_t a7_mul_request,\n','  output a7_mul_advance_t a7_mul_advance,\n','      .mul_request(a7_mul_request), .mul_advance(a7_mul_advance),\n',"    assign a7_mul_request = '0;\n","    assign a7_mul_advance = '0;\n"]:
 assert s.count(line)==1;s=s.replace(line,'')
s=s.replace(', .MUL_META(A7_MUL_META)','');assert s==txt('before/arm_cpu.sv')
s=txt('production/arm_pkg.sv');s=s[:s.index('  // Causal execution context')]+s[s.index('  // temp_addr update'):];assert s==txt('before/arm_pkg.sv')
nodes=ast.parse(txt('harness/check_domain.py')).body;additions=ast.literal_eval(next(n.value for n in nodes if isinstance(n,ast.Assign)and any(isinstance(t,ast.Name)and t.id=='additions'for t in n.targets)))
def erased(s):
 for line in additions:
  if s.count(line)!=1:return None
  s=s.replace(line,'')
 return s
assert erased(txt('production/cpu_domain.sv'))==txt('before/cpu_domain.sv')
measurement=js('measurement/results.json');assert len(measurement['cases'])==8
assert sha(F['measurement/inputs/kernel.bin'])==Q['kernel_SHA256']and sha(F['measurement/inputs/wrapper.bin'])==Q['wrapper_SHA256']
for key,row in measurement['cases'].items():
 case,region=map(int,key.split('-'));expect=([2.0625,3.0625,4.0625,5.0625]if not region else[9.234375]*3+[10.234375])[case]
 assert row['DS_A7_slope']==expect
 minimum={n:min(x['elapsed']for x in row['samples'][str(n)])for n in [4,16]}
 assert(minimum[16]-minimum[4])/1536==row['core_A7_slope']
 for n in [4,16]:
  for rep,sample in enumerate(row['samples'][str(n)]):
   log=txt(f'measurement/c{case}-r{region}-p{rep}-n{n}.log')
   assert f'elapsed{sample["elapsed"]}'in log and'MUL_PHASE_PASS'in log
assert'MUL_INPUT_MAPPING'in txt('measurement/wrong-operand.log')
positive=js('directed-positive/results.json');completion=js('directed-completion/results.json')
assert len(positive['comparisons'])==84 and len(completion['comparisons'])==3
assert completion['completed_positive']['results_SHA256']==sha(F['directed-positive/results.json'])
mutants=[]
for prefix,run in [('directed-positive',positive),('directed-completion',completion)]:
 for row in run['comparisons']:
  tag=row['tag'];log=txt(prefix+'/'+tag+'.log');assert'MUL_FOUR_LANE_BEHAVIOR_PASS'in log
  for suffix,v in row['byte_equal'].items():
   before=F[f'{prefix}/{tag}-m0.{suffix}'];assert sha(before)==v['SHA256']and len(before)==v['bytes']
   for mode in [1,2,3]:assert F[f'{prefix}/{tag}-m{mode}.{suffix}']==before
  counts=[list(map(int,x))for x in re.findall(r'MUL_META_COVER mode(\d+) faults(\d+) held_drain(\d+) failed(\d+) forwarded(\d+) discards(\d+) intervention(\d+)',log)]
  assert len(counts)==4
  if row['mutation']:
   assert row['exit']!=0 and'MUL_METADATA_MUTATION_CAUGHT'in log
   assert next(x[1]for x in counts if x[0]==3)>0 and all(x[1]==0 for x in counts if x[0]!=3);mutants.append(dict(tag=tag,counts=counts))
  else:assert row['exit']==0 and all(x[1]==0 for x in counts)and'MUL_FOUR_LANE_METADATA_PASS'in log
  if tag.startswith('variants')or tag in ['pause','CPUreset-packet-live','IRQ-discard']:
   assert all(x[2]>0 and x[3]>0 and x[4]>0 for x in counts)
  if tag=='IRQ-discard':assert all(x[5]>0 and x[6]for x in counts)
for kind,target,replacement in [('wrong-count','current_context.internal_steps = mul_work_steps;',"current_context.internal_steps = mul_work_steps + 3'd1;"),('wrong-owner','offer_owned ? held_context : current_context','current_context')]:
 before=txt('production/arm7_ds.sv');assert before.count(target)==1
 assert txt('directed-completion/'+kind+'/arm7_ds.sv')==before.replace(target,replacement)
for prefix in ['directed-positive','directed-completion']:
 assert F[prefix+'/production/arm7_ds.sv']==F['production/arm7_ds.sv']
c=js('cpu/results.json');assert len(c['DENSE'])==25 and len(c['ARM'])==26 and c['status'].startswith('PASS')
dep=Q['input_dependency'];b=(D.parent/dep['directory']/dep['file']).read_bytes();assert sha(b)==dep['sha256'];G=unpack(b);cuts=json.loads(G['gates/compare-cuts.json'])
for seed,row in c['DENSE'].items():
 cut=cuts[seed]
 def prefix(lines):return lines[:next(i for i,l in enumerate(lines)if l.startswith(cut+','))]
 current=prefix(txt('cpu/seed'+seed+'.csv').splitlines());gold=prefix(G['gates/inputs/cpu-final-seed'+seed+'.csv'].decode().splitlines())
 assert current==gold and len(current)==row['states']and row['functional']
for case,row in c['ARM'].items():
 log=txt('cpu/ARM-'+case+'.log');assert row['exit']==0 and'SWP_CPU_PAIR_PASS'in log
 if not row['functional']:
  known='ctx1: timeout at pc=020000b8 retired=1490\nTEST FAILED (timeout)'
  assert case=='bpred7'and known in log and known in G['gates/gold-suite/cpu-final-'+case+'.log'].decode()
for name,digest in c['source_SHA256'].items():assert sha(F['cpu/source/'+name])==digest
for name in ['arm7_ds.sv','arm_cpu.sv','arm_pkg.sv']:assert F['cpu/source/'+name]==F['production/'+name]
domain=js('domain/results.json');assert len(domain['stages'])==8 and domain['erased_original_exact']
for name in domain['actual_source_faults_caught']:assert erased(txt('domain/'+name+'.sv'))!=txt('before/cpu_domain.sv')
assert F['domain/source/cpu_domain.sv']==F['production/cpu_domain.sv']
for run in [measurement,positive,completion,c,domain]:
 for stage in run['stages']:assert stage.get('reaped')and stage['NI']==10
for run in [c,domain]:
 for stage in run['stages']:assert stage['exit']==0 and not stage.get('timeout')
assert all(x['exit']==0 for x in js('checks/checks.json'))
totals={k:sum(x[k]for x in list(c['DENSE'].values())+list(c['ARM'].values()))for k in ['pair_cycles','retired','writes','secondary']}
assert totals==Q['proof']['CPU_totals']
print(json.dumps(dict(status='PASS exact behavior and passive request ownership',matrix=80,adverses=5,actual_RTL_faults=mutants,DENSE=25,ARM_pass=25,inherited_failure='bpred7',CPU_totals=totals,domain_routes=8,DS_timing='MAIN remains open'),indent=2))
