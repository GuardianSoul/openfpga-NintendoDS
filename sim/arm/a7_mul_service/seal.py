#!/usr/bin/env python3
"""Seal one rejected component result and its exact-image native continuation."""
from pathlib import Path
import argparse, hashlib, io, json, os, tarfile

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--component', type=Path, required=True)
p.add_argument('--native', type=Path, required=True)
p.add_argument('--runtime', type=Path)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
os.setpriority(os.PRIO_PROCESS, 0, 10)
a.output.mkdir(parents=True, exist_ok=False)
files = {}
def add(path, name): files[name] = path.read_bytes()
for path in sorted(a.component.rglob('*')):
    if not path.is_file() or 'obj' in path.parts or 'tmp' in path.parts: continue
    rel = path.relative_to(a.component)
    # The replay joins candidate16-loop edges and all twelve state/data lanes.
    if path.suffix == '.edge' and not ('p1-n16' in path.name): continue
    add(path, 'component/'+str(rel))
add(a.component.parent/'analysis.json', 'component/analysis.json')
for path in sorted(a.native.rglob('*')):
    if path.is_file() and '__pycache__' not in path.parts:
        add(path, 'native/'+str(path.relative_to(a.native)))
for path in sorted((ROOT/'build/a7-mul-native/attempt1').glob('*')):
    if path.name == 'build.json' or path.suffix == '.log': add(path, 'failed-build/'+path.name)
if a.runtime:
    for path in sorted(a.runtime.iterdir()):
        if path.is_file(): add(path, 'runtime/'+path.name)
for folder in ['sim/arm/a7_mul_service', 'sim/arm/a7_mul_native']:
    for path in sorted((ROOT/folder).iterdir()):
        if path.is_file(): add(path, 'src/'+folder+'/'+path.name)
for rel in ['sw/hwref/a7mulmix/check.py', 'sw/hwref/arm7fetch/sdk-check.py', 'sw/hwref/arm7fetch/check.py']:
    add(ROOT/rel, 'src/'+rel)
failure = ROOT/'build/a7-mul-local/replay-failure-v1.json'
if failure.exists(): add(failure, 'replay-failure-v1.json')
manifest = dict(files={k:hashlib.sha256(v).hexdigest() for k,v in files.items()},
                source='60552bccfb2808ae357e21a59c9221e80156a0e6',
                disposition='Rejected counter witness; native continuation has its own immutable source/profile/runtime scope')
files['manifest.json'] = (json.dumps(manifest, indent=2)+'\n').encode()
packet = a.output/'proof.tar.gz'
with tarfile.open(packet, 'w:gz') as t:
    for name, data in sorted(files.items()):
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mode = 0o644
        info.mtime = 0
        t.addfile(info, io.BytesIO(data))
receipt = dict(members=len(files), expanded_bytes=sum(map(len, files.values())),
               SHA256=hashlib.sha256(packet.read_bytes()).hexdigest(),
               private_runtime='BIOS/firmware expanded inputs are hash-bound in runtime.json, never included',
               contents='Frozen component actual inputs/source/results, native guest/oracle/build receipts, optional new native runtime; no model rebuild or accepted-scope repeat')
(a.output/'seal.json').write_text(json.dumps(receipt, indent=2)+'\n')
print(json.dumps(receipt))
