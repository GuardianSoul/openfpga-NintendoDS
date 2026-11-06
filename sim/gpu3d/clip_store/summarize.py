#!/usr/bin/env python3
"""Bind the new thirteen-RAM target's actual evidence; no fit/saving claim."""
import hashlib
import json
from pathlib import Path

R=Path(__file__).resolve().parents[3];B=R/'build/geometry-clip-pump16'
checks={}
names=['native/receipt.json','native-mutant/receipt.json','clip-red1/receipt.json','clip-red0/receipt.json','clip-mutant/receipt.json','caller/receipt.json','build/receipt.json','composition.json']
for name in names:
 p=B/name;d=json.loads(p.read_text());checks[name]={'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'result':d}
 if name.startswith('native'):
  assert d['helper_sha256']==json.loads((B/'composition.json').read_text())['helper_sha256']
  if 'mutant'in name:assert d['exit'] and 'ACTUAL_STORE_STALE_FORWARD_REACHED_SEGMENT'in d['output']
  else:assert d['exit']==0
 elif name.endswith('receipt.json'):
  assert d['compile_exit']==0
  if 'mutant'in name:assert d['exit'] and 'CLIP_PUBLIC_CWD_MISMATCH'in d['output']
  elif name!='build/receipt.json':assert d['exit']==0
  else:
   a=Path(d['archive']['path']);assert hashlib.sha256(a.read_bytes()).hexdigest()==d['archive']['sha256']
  for path,expected in d['source_hashes'].items():assert hashlib.sha256((R/path).read_bytes()).hexdigest()==expected,(name,path)
record={'before':'97698ee421304616961056481a9353b9a9a10538','scope':'NewfiveRGB/UVfieldstore only, criticalXYZ/W unchanged,246logicalbits. NativeOLD_DATA+actualstale consumedfault, completeclipRED0/1/state/order/service+actualMholdfault reachespublicCWD, joinedcurrentGeometryand enabledbuild PASS. Acceptedscalar14/math/front/capacity scopes not reopened.', 'checks':checks,'open_gates':'Root explicit public enable and approvedqueue native13RAM/ALM/FASTfeasibility/STA; original10lateRAMcopies musttrim. Enabled canonical/pending/phase/heldread import bridge remains Rootpromotion gate. No savingbooked, no compact350RAM credit.'}
(B/'proof-summary.json').write_text(json.dumps(record,indent=2)+'\n')
print('PASS clipstore16 combined receipt; all executed source hashes current; mapping/STA/import gates open')
