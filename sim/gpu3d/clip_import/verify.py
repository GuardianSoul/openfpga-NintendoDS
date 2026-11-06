from pathlib import Path
import tarfile,json,hashlib
D=Path(__file__).parent
with tarfile.open(D/'proof.tar.gz')as t:f={m.name:t.extractfile(m).read()for m in t.getmembers()if m.isfile()}
m=json.loads(f['manifest.json'])
for name,h in m['sha256'].items():assert hashlib.sha256(f[name]).hexdigest()==h,name
r=json.loads(f['local-proof-summary.json']);assert r['status']=='PASS_LOCAL_BRIDGE_AND_FAITHFUL_CAPTURE_ROOT_BINDING_OPEN'
for mode,row in r['modes'].items():
 assert all(x['reaped']for x in row['stages']);assert hashlib.sha256(f[mode+'/run.log']).hexdigest()==row['log_sha256']
 receipt=json.loads(f[mode+'/receipt.json'])
 for name,h in receipt['sha256'].items():
  if name.endswith(('.sv','.svh')):assert hashlib.sha256(f[mode+'/'+name]).hexdigest()==h,(mode,name)
assert b'cycles214 writes71 neighbours4' in f['healthy/run.log'] and b'%Fatal'not in f['healthy/run.log']
assert b'IMPORT_PUBLIC_CWD_MISMATCH cycle55' in f['wrong-field/run.log']
assert b'IMPORT_PHASE_GUARD_MUTANT_ESCAPED_REJECTION'in f['phase-guard-mutant/run.log']
assert b'PASS_HELD_LIVENESS firstlate54'in f['poison-held/run.log']
assert b'CLIP_CAPTURE_REPLICA_CONFLICT'in f['capture-conflict/run.log']
b=json.loads(f['binding-audit.json']);assert b['status']=='ROOT_REVIEW_OPEN_NO_HASH_REBIND' and b['production_delta']=='NONE'
print('PASS local bridge/capture/mutants/rejections; full-context binding/game/STA remain OPEN')
