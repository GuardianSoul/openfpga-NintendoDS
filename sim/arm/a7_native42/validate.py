#!/usr/bin/env python3
"""Keep the generic controller failure and qualify only the measured probe scope."""
from pathlib import Path
import hashlib,json,re
from check import check
ROOT=Path(__file__).resolve().parents[3];B=ROOT/'build/a7-native42/thumb';O=B/'results/arm7thumb42'
m=json.loads((O/'manifest.json').read_text());log=(O/'run.log').read_text()
assert m['exit']==0 and m['wrapper_reaped']and m['PASS']and m['native_finish']and m['models_clean']and m['video']and m['no_errors']
assert not m['accepted']and not m['VM']and m['vm_counts']==[0,0,0]
assert 'vmcheck: 0 words read, 0 CPU reads from the block buffer, 0 mismatches'in log
assert 'A7_NATIVE39_ROUTE_OK'in log and all(v for k,v in m.items()if k.endswith('_ROUTE'))
assert re.search(r'video: 24 frames, 0 errors;',log)
r=check(B,O/'main.bin');assert r['all_paired_slopes_exact']
differences=[a-b for row in r['rows']for a,b in zip(row['native_ticks'],row['DS_ticks'])];assert set(differences)=={67}
result=dict(source=m['source'],profile=m['profile'],probe_function_context_PASS=True,probe_paired_slopes_PASS=True,generic_controller_original_exit=1,generic_controller_original_accepted=False,generic_failure='requires positive VRAM read coverage; the forced-blank Thumb probe deliberately performs no VRAM reads',VRAM=dict(reads=0,mismatches=0,scope='no VRAM coverage claimed; not a VRAM acceptance waiver'),absolute_window_difference_ticks=67,absolute_timing_scope='native invoke/timestamp/boot wrapper replaces SDK; raw values retained, no67 subtraction or epoch alignment; original SDK absolute-window timing not qualified',comparison=r,model=m['model'],log_SHA256=hashlib.sha256((O/'run.log').read_bytes()).hexdigest())
(B/'scoped-validation.json').write_text(json.dumps(result,indent=2)+'\n');print('PASS scoped DS42 native9; original zero-VRAM controller failure retained; absolute windows+67ticks retained')
