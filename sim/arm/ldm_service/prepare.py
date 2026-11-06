#!/usr/bin/env python3
"""Restore exact measured test inputs; no external worktree or network needed."""
from pathlib import Path
import json,hashlib,tarfile
R=Path(__file__).resolve().parents[3];P=R/'docs/results/ldm-service-20261101';G=R/'build/ldm-service';G.mkdir(parents=True,exist_ok=True)
results=json.loads((P/'results.json').read_text());records=json.loads((P/'records.json').read_text());assert hashlib.sha256((P/'runs.tar.gz').read_bytes()).hexdigest()==results['archive']['sha256']
with tarfile.open(P/'runs.tar.gz')as tar:
 for name,receipt in records.items():
  p=Path(name)
  if p.is_absolute()or'..'in p.parts:raise ValueError(name)
  selected=(len(p.parts)==1 and (p.suffix in ['.s','.elf','.bin','.hex']or p.name in ['forms.json','native-vs-DS.json','captured-adapter-manifest.json','hwref-followup.json']))or p.parts[0]=='test-images'
  if not selected:continue
  b=tar.extractfile('objects/'+receipt['sha256']).read();assert hashlib.sha256(b).hexdigest()==receipt['sha256']
  out=G/p;out.parent.mkdir(parents=True,exist_ok=True)
  if out.exists():assert out.read_bytes()==b,('input changed',out)
  else:out.write_bytes(b)
print('Exact measured53 bodies, CPU suite and associated inputs restored; simulation still needs one allocated worker.')
