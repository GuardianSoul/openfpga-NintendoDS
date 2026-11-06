#!/usr/bin/env python3
"""Source/reader controls only; these fixtures are never native evidence."""
from pathlib import Path
import argparse,importlib.util,json,re
from check_observer import body_check,physical
def test(prepared):
 m=json.loads((prepared/'hook-manifest.json').read_text());blob=bytes(int(v,16)for v in (prepared/'run-assets/ds30_expected.hex').read_text().split())
 def rows(wc):return [dict(index=i,cpu=b['cpu'],address=b['address'],bytes=b['bytes'],file_offset=b['file_offset'],physical=physical(b['cpu'],b['address'],wc),wramcnt=wc)for i,b in enumerate(m['bodies'])]
 for wc in range(4):body_check(blob,rows(wc),m,wc)
 faults=[]
 for label,index in [('shared-body-byte',7),('ITCM-body-byte',6)]:
  bad=bytearray(blob);bad[m['bodies'][index]['file_offset']+16]^=1
  try:body_check(bad,rows(3),m,3)
  except AssertionError:faults.append(label)
  else:raise AssertionError('body-byte fault escaped')
 bad=rows(3);bad[7]['physical']^=0x10000
 try:body_check(blob,bad,m,3)
 except AssertionError:faults.append('wrong-shared-private-bank')
 else:raise AssertionError('wrong-bank fault escaped')
 try:body_check(blob,rows(3)[:-1],m,3)
 except AssertionError:faults.append('missing-body25')
 else:raise AssertionError('missing-body fault escaped')
 s=(prepared/'overlay/sim/pocket_ds/ds30_observer.svh').read_text()
 assert not re.search(r'\b(force|release|deposit)\b',s)
 assert not re.search(r'(?m)^\s*(?:dut\.|u_sram\.|`D30(?:CPU|CORE|MEM)\.)[^;]*(?:<=|(?<![=!<>])=(?!=))',s),'DUT assignment in observer'
 assert set(m['overlay_SHA256'])=={'sim/pocket_ds/tb_ds_pocket.sv','sim/pocket_ds/ds30_observer.svh','sim/pocket_ds/ds30_tables.svh'}
 return dict(status='PASS HOST READER/SOURCE CONTROLS ONLY',mapping_modes=4,body_bytes=len(blob),body_count=25,faults_caught=faults,HDL_elaborated=False,native_executed=False)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--prepared',type=Path,required=True);a=p.parse_args();print(json.dumps(test(a.prepared),indent=2))
