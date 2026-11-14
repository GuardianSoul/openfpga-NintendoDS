#!/usr/bin/env python3
"""Compare outcomes with the sealed prior CPU evidence, without rerunning it."""
import pathlib,json,tarfile,hashlib
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-shared-cpu';P=W/'docs/results/cpu232-service-cpu-gates-20261110'
r=json.loads((P/'result.json').read_text());assert hashlib.sha256((P/'evidence.tar.gz').read_bytes()).hexdigest()==r['archive_sha256']
with tarfile.open(P/'evidence.tar.gz')as t:old=json.load(t.extractfile('execution/result.json'))
new=json.loads((D/'result.json').read_text());out={'prior_archive_sha256':r['archive_sha256'],'not_equivalence':True,'new_failures':[],'retained_failures':[],'previous_failures_now_pass':[],'groups':{},'cases':{}}
for name,row in new['cases'].items():
 if name.startswith('ARM-'):before=old['tb_arm'][name[4:]];group='tb_arm'
 else:group,seed=name.split('-');before=old[group][str(int(seed))]
 out['cases'][name]={'before':before,'after':row}
 if not row['functional']:(out['new_failures']if before['functional']else out['retained_failures']).append(name)
 elif not before['functional']:out['previous_failures_now_pass'].append(name)
 g=out['groups'].setdefault(group,{'count':0,'pass':0,'before_cycles':0,'after_cycles':0});g['count']+=1;g['pass']+=int(row['functional'])
 if before['cycles']and row['cycles']:g['before_cycles']+=int(before['cycles'][0]);g['after_cycles']+=int(row['cycles'][0])
for name,h in new['inputs'].items():assert old['inputs'][pathlib.Path(name).name]==h,('changed input',name)
out['original_input_hashes_match']=True
(D/'comparison.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps({k:v for k,v in out.items()if k!='cases'},indent=2))
