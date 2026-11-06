#!/usr/bin/env python3
"""Retain both immutable attempts and the independent paired verdict."""
from pathlib import Path
import argparse,hashlib,io,json,tarfile

p=argparse.ArgumentParser(description=__doc__);p.add_argument('--first',type=Path,required=True)
p.add_argument('--continued',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();A=a.first.resolve();B=a.continued.resolve();D=a.output.resolve();D.mkdir(parents=True,exist_ok=True)
sha=lambda f:hashlib.file_digest(f.open('rb'),'sha256').hexdigest()
review=json.loads((B/'paired-review.json').read_text());assert review['positive_cases']==22 and review['actual_faults']==1
files={}
for G in [A,B]:
 for f in sorted(G.rglob('*')):
  if not f.is_file()or'__pycache__'in f.parts:continue
  if 'obj'in f.parts and f.name not in ['Vtb','Vtb__verFiles.dat']:continue
  files[G.name+'/'+str(f.relative_to(G))]=f
files['review_pair.py']=Path(__file__).with_name('review_pair.py')
manifest=dict(status=review['status'],CPU='d006ad38',P7='087e3a66/174d268d',
              paths={n:dict(sha256=sha(f),bytes=f.stat().st_size)for n,f in files.items()})
with tarfile.open(D/'evidence.tar.gz','w:gz',compresslevel=6)as t:
 b=(json.dumps(manifest,indent=2)+'\n').encode();i=tarfile.TarInfo('manifest.json');i.size=len(b);t.addfile(i,io.BytesIO(b))
 for n,f in files.items():t.add(f,arcname=n,recursive=False)
receipt=dict(sha256=sha(D/'evidence.tar.gz'),bytes=(D/'evidence.tar.gz').stat().st_size,
             files=len(files),review=review,scope='Bounded paired contract only; no DS debt/scaling/native/fit acceptance')
(D/'inputs.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({k:v for k,v in receipt.items()if k!='review'}))
