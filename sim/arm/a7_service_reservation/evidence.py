#!/usr/bin/env python3
"""Retain the complete rejected reservation experiment and its control."""
from pathlib import Path
import argparse,hashlib,io,json,tarfile

p=argparse.ArgumentParser(description=__doc__);p.add_argument('--gate',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
R=Path(__file__).resolve().parents[3];G=a.gate.resolve();D=a.output.resolve();D.mkdir(parents=True,exist_ok=True)
assert json.loads((G/'terminal.json').read_text())['complete']
assert json.loads((G/'decision.json').read_text())['disposition']=='REJECT_DS_ANCHOR_CONTRADICTION'
sha=lambda f:hashlib.file_digest(f.open('rb'),'sha256').hexdigest();files={}
for f in sorted(G.rglob('*')):
 if not f.is_file()or'__pycache__'in f.parts:continue
 if 'obj'in f.parts and f.name not in ['Vtb','Vtb__verFiles.dat']:continue
 files['gate/'+str(f.relative_to(G))]=f
files['reference/paired.tar.gz']=R/'docs/results/a7-logical-slot-pair-20261102/evidence.tar.gz'
files['reference/DS-mixed.tar.gz']=R/'docs/results/a7mulmix-dslite-20261102/evidence.tar.gz'
assert sha(files['reference/paired.tar.gz'])=='a71be71df38a59a84a0aac768c18a98cc18840e19c2aee47535d16454ade6457'
manifest=dict(disposition='REJECT_DS_ANCHOR_CONTRADICTION',qualified='98373e35',paths={n:dict(sha256=sha(f),bytes=f.stat().st_size)for n,f in files.items()})
with tarfile.open(D/'evidence.tar.gz','w:gz',compresslevel=6)as t:
 b=(json.dumps(manifest,indent=2)+'\n').encode();i=tarfile.TarInfo('manifest.json');i.size=len(b);t.addfile(i,io.BytesIO(b))
 for n,f in files.items():t.add(f,arcname=n,recursive=False)
r=dict(sha256=sha(D/'evidence.tar.gz'),bytes=(D/'evidence.tar.gz').stat().st_size,files=len(files),decision=json.loads((G/'decision.json').read_text()),scope='Test-only rejected policy; production P7d087 remains separate HOLD; no source price retune')
(D/'inputs.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps({k:v for k,v in r.items()if k!='decision'}))
