#!/usr/bin/env python3
"""Archive the completed receiver-only gate, excluding compiler scratch."""
from pathlib import Path
import argparse, hashlib, io, json, tarfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--gate',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();G=a.gate.resolve();D=a.output.resolve();D.mkdir(parents=True,exist_ok=True)
assert json.loads((G/'terminal.json').read_text())['complete']
sha=lambda p:hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
files={}
for f in sorted(G.rglob('*')):
    if not f.is_file() or '__pycache__'in f.parts:continue
    if 'obj'in f.parts and f.name not in ['Vslot_tb','Vslot_tb__verFiles.dat']:continue
    files[str(f.relative_to(G))]=dict(sha256=sha(f),bytes=f.stat().st_size)
manifest=dict(status='PASS receiver-only; CPU pairing/DS timing OPEN',source='b449d998',
              paths=files,complete=json.loads((G/'complete.json').read_text()))
with tarfile.open(D/'evidence.tar.gz','w:gz',compresslevel=6)as t:
    data=(json.dumps(manifest,indent=2)+'\n').encode();i=tarfile.TarInfo('manifest.json');i.size=len(data)
    t.addfile(i,io.BytesIO(data))
    for name in files:t.add(G/name,arcname='gate/'+name,recursive=False)
receipt=dict(sha256=sha(D/'evidence.tar.gz'),bytes=(D/'evidence.tar.gz').stat().st_size,
             files=len(files),P7_input_sha256=sha(G/'p7-before.sv'),
             actual_gate='build/a7-logical-slot-receiver-v2',scope=manifest['status'])
(D/'inputs.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt))
