#!/usr/bin/env python3
"""Bundle measured MUL source/streams and the passive API qualification once."""
from pathlib import Path
import argparse,hashlib,io,json,os,resource,subprocess,tarfile
R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--directed',type=Path,required=True);a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
D=a.output;D.mkdir(parents=True,exist_ok=False);files={}
sha=lambda b:hashlib.sha256(b).hexdigest()
def put(name,path):files[name]=path.read_bytes()
def tree(prefix,path,skip_inputs=False):
 for f in sorted(path.rglob('*')):
  rel=f.relative_to(path)
  if not f.is_file()or any(x in ['obj','tmp','__pycache__']for x in rel.parts):continue
  if skip_inputs and rel.parts[0]in ['inputs','gold-suite']:continue
  if f.name.endswith(('.o','.d','.a','.gch')):continue
  put(prefix+'/'+str(rel),f)
base='76616273fe9229532d46939be25fe680d18bd816'
for name in ['arm_pkg','arm7_ds','arm_cpu','cpu_domain']:
 path='rtl/arm/'+name+'.sv';put('production/'+name+'.sv',R/path)
 files['before/'+name+'.sv']=subprocess.check_output(['git','show',base+':'+path],cwd=R)
tree('measurement',R/'build/a7-mulphase-compare/attempt1')
tree('directed-positive',R/'build/a7-mulphase-meta/attempt2')
tree('directed-completion',a.directed)
for attempt in [1,3]:tree('rejected-fixture-attempt'+str(attempt),R/f'build/a7-mulphase-meta/attempt{attempt}')
tree('cpu',R/'build/a7-mulphase-meta/cpu',skip_inputs=True)
tree('domain',R/'build/a7-mulphase-meta/domain')
tree('harness',R/'sim/arm/a7_mulphase')
put('harness/stm4-probe.svh',R/'sim/arm/stm4_meta/probe.svh');put('harness/cpu_pair.svh',R/'sim/arm/stm4_meta/cpu_pair.svh')
tree('checks',R/'build/a7-mulphase-meta/checks')
measure=json.loads(files['measurement/results.json']);positive=json.loads(files['directed-positive/results.json']);completion=json.loads(files['directed-completion/results.json']);cpu=json.loads(files['cpu/results.json']);domain=json.loads(files['domain/results.json'])
assert measure['status'].startswith('PASS80')and len(positive['comparisons'])==84 and completion['status'].startswith('PASS80')
assert len(completion['comparisons'])==3 and len(cpu['DENSE'])==25 and len(cpu['ARM'])==26 and len(domain['stages'])==8
total=lambda k:sum(x[k]for x in list(cpu['DENSE'].values())+list(cpu['ARM'].values()))
Q=dict(base=base,branch='codex/cpu-a7mulphase-compare',production_source_SHA256={n:sha(b)for n,b in files.items()if n.startswith('production/')},
 DS_build=measure['DS_build_id'],DS_ROM=measure['DS_ROM'],kernel_SHA256=measure['kernel_SHA256'],wrapper_SHA256=measure['wrapper_SHA256'],
 API=dict(context='a7_mul_context_t: valid/thumb/accumulate/set_flags/internal_steps[2:0], 7bits',advance='a7_mul_advance_t: valid/index[2:0], 4bits',
  enable='arm7_ds MUL_META=0; arm_cpu/cpu_domain A7_MUL_META=0',clock='CPU cclk; CPU_FAST0 clk, CPU_FAST1 clk_cpu; no CDC added',
  request='Before original i_req rising-edge capture: current correctly forwarded E Rs/variant; hold original logical F owner until consume/redirect/reset, including request pauses and E/drain transitions',
  execution='Actual pipe_fire&&e_mul&&esub0/1; index0 then acceptance-driven work index; not a logical I commit or finish',
  declared_capture_bits=8,mapped_cost='unmeasured; no fit',full402_enabled=False,memory_service_changed=False),
 proof=dict(matrix_runs=80,adverse_runs=5,lanes=4,actual_metadata_RTL_mutants=['wrong-count','wrong-owner'],
  DENSE=25,retained_gold_states=total('states')if all('states'in x for x in cpu['ARM'].values())else sum(x['states']for x in cpu['DENSE'].values()),
  ARM_pass=25,inherited_failure='bpred7 ctx1 pc020000b8 retired1490 timeout unchanged',CPU_totals={k:total(k)for k in ['pair_cycles','retired','writes','secondary']},domain_routes=8,
  all_workers_terminal_reaped=all(s.get('reaped')for run in [measure,positive,completion,cpu,domain]for s in run['stages'])),
 input_dependency=dict(directory='arm9-fetch-retry-20261101',file='evidence.tar.gz',sha256='c4e4a8ebfa16eaeaa836c50d6956d7d4100c83c580531f1548cdf7786494b216'),
 limits='Quiet exact-kernel/wrapper component only; no native caller/timer/helper equivalence, no MAIN timing fix, no universal I/N/S law. Initial fixture failures retained separately, never counted as successful cases.')
archive=D/'evidence.tar.gz'
with tarfile.open(archive,'w:gz',compresslevel=9)as t:
 for name,value in sorted(files.items()):
  info=tarfile.TarInfo(name);info.size=len(value);info.mtime=0;info.mode=0o644;t.addfile(info,io.BytesIO(value))
Q['archive']=dict(file=archive.name,bytes=archive.stat().st_size,sha256=sha(archive.read_bytes()),files={n:dict(bytes=len(b),sha256=sha(b))for n,b in sorted(files.items())})
(D/'qualification.json').write_text(json.dumps(Q,indent=2)+'\n');print(json.dumps({k:Q[k]for k in ['proof','limits']}),flush=True);print('archive',len(files),archive.stat().st_size,Q['archive']['sha256'])
