#!/usr/bin/env python3
"""Collect only this new scalar-context qualification and source binding."""
import hashlib
import json
from pathlib import Path

R=Path(__file__).resolve().parents[3];B=R/'build/geometry-scalar-div14'
checks={}
for name in ['unit/receipt.json','caller/receipt.json','mutant/receipt.json','build/receipt.json','composition.json']:
    p=B/name;d=json.loads(p.read_text())
    checks[name]={'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'result':d}
    if name.endswith('receipt.json'):
        assert d['compile_exit']==0,(name,d['compile_exit'])
        if name=='mutant/receipt.json':
            assert d['run_exit'] and 'actual scalar caller selected XS_Q mismatch'in d['output']
        elif name!='build/receipt.json':assert d['run_exit']==0,name
        else:
            archive=Path(d['archive']['path'])
            assert hashlib.sha256(archive.read_bytes()).hexdigest()==d['archive']['sha256']
        for path,expected in d['source_hashes'].items():
            assert hashlib.sha256((R/path).read_bytes()).hexdigest()==expected,(name,path)
assert 'scalar starts=784 selectedXS_Q=784'in checks['caller/receipt.json']['result']['output']
record={'before':checks['composition.json']['result']['before'],
        'scope':'Only default-off scalar K4/P2X context with retained SYS quotient. New before/caller relation and actual retention-phase fault; accepted scopes unchanged. No new area saving/native placement/STA or DS/game acceptance.',
        'checks':checks,'price_gate':'Root must explicitly select GX_SCALAR_DIV_P2X=1 through its main public price adapter. No default-off or subset fit qualifies the candidate. New SYS-q32bit retention and complete native half-cycle timing remain unpriced.'}
(B/'proof-summary.json').write_text(json.dumps(record,indent=2)+'\n')
print('PASS scalar14 combined receipt; all executed source hashes current')
