#!/usr/bin/env python3
"""Recover only a pre-import wrong-cwd launch, same ELF/argv and original mbox."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time
sys.path.insert(0,str(Path(__file__).resolve().parent.parent/'hg193_combined_hook'))
from verify_game_launch import validate
from build_game import process,write,gate

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--base',type=Path,required=True);p.add_argument('--child',action='store_true');a=p.parse_args();b=a.base.resolve();os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
 cwd=json.loads((b/'diagnostic/cwd-binding.json').read_text());args=json.loads((b/'diagnostic/argv.json').read_text())
 if a.child:
  write(b/'recovery-child.json',process());gate(b/'recovery-native.release');os.chdir(cwd['original_cwd']);os.execv('/usr/bin/stdbuf',['stdbuf','-oL',*args])
 assert not (b/'recovery-controller.json').exists()
 old=(b/'failed-cwd-launch/native.log').read_text();assert '$readmem file not found'in old and 'mbox.hex'in old and 'APF host command 0082 result 434d0082'in old and 'HG193_OWNER'not in old
 assert json.loads((b/'native-complete.json').read_text())['reaped']
 assert args==json.loads((b/'failed-cwd-launch/argv.json').read_text())
 pin=json.loads((b/'model-pin.json').read_text());guard=validate(b,pin,args,'hg-title')
 assert sha(Path(cwd['original_cwd'])/'mbox.hex')==cwd['mbox_sha256']=='16a7d772c34b99b7195a823d31f39f9ea0e98597ee764ee2174e4ae532e85a91'
 for n,h in cwd['original_input_sha256'].items():assert sha(Path(cwd['parent'])/n)==h,n
 assert os.getloadavg()[0]<24
 controller=process();write(b/'recovery-controller.json',dict(controller=controller,source=pin['source'],profile=60,model_sha256=pin['binary_sha256'],launcher_sha256=sha(Path(__file__).resolve()),cwd_binding_sha256=sha(b/'diagnostic/cwd-binding.json'),jobs=1,threads=1));gate(b/'recovery-controller.release')
 write(b/'diagnostic/launch-guard.json',guard)
 with (b/'diagnostic/native.log').open('w')as f:
  child=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'--base',str(b),'--child'],stdout=f,stderr=subprocess.STDOUT)
  while not (b/'recovery-child.json').exists():assert child.poll()is None;time.sleep(.1)
  identity=json.loads((b/'recovery-child.json').read_text());assert identity['nice']==10
  write(b/'recovery-active.json',dict(controller=controller,child=identity,source=pin['source'],profile=60,model_sha256=pin['binary_sha256']))
  try:rc=child.wait(timeout=1500)
  except subprocess.TimeoutExpired:child.terminate();child.wait();raise
 write(b/'recovery-complete.json',dict(exit=rc,child=identity,reaped=True,log_sha256=sha(b/'diagnostic/native.log')))
 text=(b/'diagnostic/native.log').read_text();assert rc!=0 and 'HG193_CALLER'in text and 'HG193_OWNER_RAW'in text
 rows=[s for s in text.splitlines()if s.startswith('HG193_ALL_GUARD')];assert len(rows)==456
 assert 'CAPTURE41_ACCEPTED_SOURCE_FIVE1_METADATA0_PASS'in text and 'STRICT_HG_BOUND_LAUNCH_CONTRACT_PASS'in text
 assert 'HG193 combined drain: cpu_arm9_cache'in text
 write(b/'diagnostic/result.json',dict(state='STRICT_DIAGNOSTIC_CAPTURED_ORIGINAL_FAILURE',source=pin['source'],model_sha256=pin['binary_sha256'],profile=60,all_guard_clauses=len(rows),false_clauses=[s for s in rows if not s.endswith('pass=1')],owners=[s for s in text.splitlines()if s.startswith(('HG193_OWNER','HG193_CALLER'))],history_published=False,proposal_enabled=False,scene_accepted=False,process_reaped=True,compiler_builds=1,native_attempts=2,preimport_wrong_cwd_attempts=1))
 print((b/'diagnostic/result.json').read_text(),flush=True)
if __name__=='__main__':main()
