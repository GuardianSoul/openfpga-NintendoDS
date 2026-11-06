#!/usr/bin/env python3
"""Check DS41 adapter dump against all64 records; no trace/functional bypass for timing."""
from pathlib import Path
import argparse,json,struct,hashlib
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--prepared',type=Path,required=True);p.add_argument('--main',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--require-ds',action='store_true');a=p.parse_args();m=json.loads((a.prepared/'input-map.json').read_text());raw=a.main.read_bytes()
assert len(raw)==4*1024*1024,'actual full MAIN dump required'
base=0x023d0000-0x02000000;b=raw[base:base+6976];w=struct.unpack('<1744I',b);assert w[:6]==(0x314f4944,1,64,4,0,1),'incomplete or failed functional/input/context adapter'
for case in range(4):
 for side in range(2):assert list(w[16+(case*2+side)*16:32+(case*2+side)*16])==m['cp15'],'CP15 context mismatch'
rows=[];timing=True
for row in range(64):
 s=w[144+20*row:164+20*row];case=row//16;rep=row%16;assert s[:2]==(case,rep)
 assert s[6]&255==0xdf and s[19]==0,'IRQ/input/context failure'
 expected=m['expected_context_rows'][row]
 for k in range(5):
  if k!=1:assert s[7+k]==expected[5+k] and s[12+k]==expected[10+k],'readable state mismatch'
 assert s[2+2]==s[2+3],'stopped counts disagree'
 assert s[17]==s[18]==m['cases'][case]['fnv'],'active code checksum differs'
 deltas=[(s[3]-s[2])&65535,(s[4]-s[3])&65535];ok=deltas==[4,5];timing=timing and ok
 rows.append(dict(case=case,rep=rep,native_r0_r1_r2_r3=list(s[2:6]),DS_r0_r1_r2_r3=expected[:4],native_delta=deltas,DS_delta=[4,5],exact_interval_match=ok))
for case in range(4):
 start=(144+64*20+case*80)*4;size=m['cases'][case]['bytes'];actual=b[start:start+size]
 assert actual==(a.prepared/f'case{case}.bin').read_bytes(),'actual active instruction snapshot differs'
 assert not any(b[start+size:start+320]),'live-code padding differs'
r=dict(functional_input_context=True,timing_all64_exact=timing,rows=rows,MAIN_sha256=hashlib.sha256(raw).hexdigest(),scope='Full4case16repeat vector; all raw counts retained; no phase/latency offset fitting. Passive witness and native physical guards remain separately required.')
a.out.write_text(json.dumps(r,indent=2)+'\n');print('FUNCTION/INPUT/CONTEXT PASS; TIMING',timing)
if a.require_ds and not timing:raise SystemExit(1)
