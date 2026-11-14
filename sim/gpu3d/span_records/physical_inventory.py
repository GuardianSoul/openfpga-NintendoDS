#!/usr/bin/env python3
"""Read a combined fit's storage evidence; never infer success from RTL attributes."""
from pathlib import Path
import argparse,json,re,hashlib
ap=argparse.ArgumentParser();ap.add_argument('--map',type=Path,required=True);ap.add_argument('--fit',type=Path,required=True);a=ap.parse_args();m=a.map.read_text(errors='replace');f=a.fit.read_text(errors='replace')
views={}
for name in ['u_early','u_late','u_tail']:
 key='|gpu3d_span_view:'+name+'|';rows=[]
 for line in f.splitlines():
  p=[x.strip()for x in line.split(';')]
  if len(p)>14 and p[1]==key:
   rows.append({'node':p[1],'needed_ALM':p[2],'memory_ALM':p[6],'logic_registers':p[8],'RAM_bits':p[10]})
 explicit=key+'altdpram:u_ram' in m
 mem=any(float(re.match(r'[0-9.]+',x['memory_ALM'])[0])>0 for x in rows)
 views[name]={'explicit_altdpram_present':explicit,'memory_ALM_nonzero':mem,'rows':rows,'PASS':explicit and mem}
roots=[]
for line in f.splitlines():
 p=[x.strip()for x in line.split(';')]
 if len(p)>14 and p[1]=='|gpu3d_span_records:g_span_records.u_records|':roots.append({'needed_ALM':p[2],'memory_ALM':p[6],'logic_registers':p[8],'RAM_bits':p[10]})
r={'mapping_PASS':all(v['PASS']for v in views.values()),'scope':'Current TXD5 three-view combined native storage presence only; Root must bind source/profile and assess total area/placement/STA/game gates separately. No saving inferred.','views':views,'record_entity':roots,'report_sha256':{'map':hashlib.file_digest(a.map.open('rb'),'sha256').hexdigest(),'fit':hashlib.file_digest(a.fit.open('rb'),'sha256').hexdigest()}}
print(json.dumps(r,indent=2))
