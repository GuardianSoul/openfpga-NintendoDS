#!/usr/bin/env python3
"""Offline immutable source/packet/result capsule verification."""
from pathlib import Path
import hashlib,json,tarfile
with tarfile.open(Path(__file__).with_name('evidence.tar.gz')) as t:
 data={m.name:t.extractfile(m).read() for m in t.getmembers() if m.isfile()}
manifest=json.loads(data['manifest.json'])
for f,h in manifest.items():assert hashlib.sha256(data[f]).hexdigest()==h,f
for label,status in [('positive','PASS_FULL_RF_CONTEXT_WRAPPER_CAPTURE_FIRST_USE'),('mutant','CAUGHT_ACTUAL_FINALIZE_IMPORT_MUTANT')]:
 inp=json.loads(data[label+'/input.json']);r=json.loads(data[label+'/receipt.json'])
 for f,h in inp['sha256'].items():assert hashlib.sha256(data[label+'/inputs/'+f]).hexdigest()==h,(label,f)
 assert r['status']==status and all(s['reaped'] for s in r['stages'])
 assert r['peak_scratch']<inp['disk_cap_bytes']
log=data['positive/run.log'].decode();assert 'PASS_FULL_CONTEXT_CAPTURE_IMPORT_FIRST_USE cycles10843 clips2 clipwrites119 RF294 polys4' in log
assert 'QUALIFIED_DEFAULT_FIRST16_LAZY_READS_PASS' in log and '%Fatal' not in log
assert 'FINALIZE_GROUP_READBACK oldport2 addr0' in data['mutant/run.log'].decode()
b=json.loads(data['binding.json']);assert b['sidecar_words']==170 and hashlib.sha256(data['positive/captured-sidecar.hex']).hexdigest()==b['sidecar_sha256']
print('PASS',len(manifest),'hashed members; complete source/packet binding, full wrapper/public first use, actual mutation caught')
