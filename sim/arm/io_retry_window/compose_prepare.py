#!/usr/bin/env python3
"""Restore sealed current-main composition inputs; starts no worker."""
from pathlib import Path
import hashlib,json,tarfile
R=Path(__file__).resolve().parents[3];D=R/'docs/results/io-replay-main40-20261101';q=json.loads((D/'qualification.json').read_text());a=D/'evidence.tar.gz';assert hashlib.sha256(a.read_bytes()).hexdigest()==q['artifact']['sha256'];B=R/'build/io-replay-main40';B.mkdir(exist_ok=True)
with tarfile.open(a)as t:t.extractall(B,filter='data')
for p,h in json.loads((B/'manifest.json').read_text()).items():assert hashlib.sha256((B/p).read_bytes()).hexdigest()==h,p
print('Restored frozen current-main controls, exact inputs and receipts; allocated worker still required.')
