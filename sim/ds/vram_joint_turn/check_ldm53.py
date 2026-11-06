#!/usr/bin/env python3
"""Check all original53 loaded code/context/functional outputs, not DS timing."""
from pathlib import Path
import argparse
import json
import sys

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--prepared',type=Path,required=True)
p.add_argument('--main',type=Path,required=True)
p.add_argument('--out',type=Path,required=True)
a=p.parse_args()
sys.path.insert(0,str(a.prepared/'tools/scorecard/ldm53'))
from check import check_native_main
decoded=a.out.parent/'decoded';decoded.mkdir(exist_ok=True)
r=check_native_main(a.main.read_bytes(),a.prepared/'normal',decoded)
assert r['groups']==53 and r['independent_signatures']==106 and r['functional_register_values']==848
assert r['raw_times']==636 and r['exact_context_words']==64
assert r['active_ITCM']['present']and r['active_ITCM']['sections']==106
r['scope']='Actual timed ITCM106 sections and14templates/helper160 checked; DS timing separate, legacy live_ITCM_scope text superseded by active_ITCM.'
a.out.write_text(json.dumps(r,indent=2)+'\n')
print('LDM53_FUNCTIONAL_PASS 53/106/848/636 and64context, actual ITCM/helper exact')
