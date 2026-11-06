#!/usr/bin/env python3
"""Extend the already-qualified C19 frontend with one bounded host observer."""
from pathlib import Path
import hashlib,json,shutil,sys
sha=lambda p:hashlib.file_digest(Path(p).open('rb'),'sha256').hexdigest()
def prepare(job):
 old=Path('/home/user/Git/NDS_Pocket-sound-epoch-c19');job=Path(job)
 for n,h in json.loads((old/'source-manifest.json').read_text()).items():assert sha(old/n)==h,n
 assert not job.exists();job.mkdir()
 for n in ['frontend','core-headers','generated-headers','aux-headers','link','inputs','seed','original-entry']:shutil.copytree(old/n,job/n)
 for n in ['plan.json','original-reference.json','original-qualification.json','sim_ownership.py','fat_time_fixture.cpp','check.py']:shutil.copy2(old/n,job/n)
 shutil.copy2(old/'pinned-results/normal/entries/c7684/epoch.json',job/'accepted-epoch.json')
 assert sha(job/'accepted-epoch.json')=='1f2a29842d8d704aba5f09b16f9221746ce633381c0eedbc32c973b50c8c4923'
 def patch(name,before,after):
  p=job/'frontend'/name;s=p.read_text();assert s.count(before)==1,(name,before);p.write_text(s.replace(before,after))
 patch('census.cpp','#include "sound_epoch.inc"','#include "sound_epoch.inc"\n#include "sound_window.inc"')
 patch('census.cpp','static void OnMemAccess(int cpu, u32 kind, u32 addr, u32 size)\n{','static void OnMemAccess(int cpu, u32 kind, u32 addr, u32 size)\n{\n    SoundWindowMem(cpu,kind,addr,size);')
 patch('census.cpp','    SoundEpochObserveMix(s);','    SoundEpochObserveMix(s);\n    SoundWindowMix();')
 patch('census.cpp','static void OnSPUWrite(u32 size, u32 addr, u32 val) {','static void OnSPUWrite(u32 size, u32 addr, u32 val) { SoundWindowSPUWrite(size,addr,val);')
 patch('census.cpp','    SoundV2Retire(cpu,pc);','    SoundV2Retire(cpu,pc);\n    SoundWindowRetire(cpu,pc,r,cpsr);')
 patch('census.cpp','    SoundV2Write(cpu,src,addr,val,bytes);','    SoundV2Write(cpu,src,addr,val,bytes);\n    SoundWindowWrite(cpu,src,addr,val,bytes);')
 patch('sound_v2_entry.inc','    SoundEpochFinish(dir,command,retiredPC);','    SoundEpochFinish(dir,command,retiredPC);\n    SoundWindowBegin(dir,command,retiredPC);')
 here=Path(__file__).parent
 for a,b in [('window.inc','frontend/sound_window.inc'),('run_window.py','run_window.py'),('check_window.py','check_window.py')]:shutil.copy2(here/a,job/b)
 manifest={str(p.relative_to(job)):sha(p)for p in job.rglob('*')if p.is_file()};(job/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
if __name__=='__main__':prepare(Path(sys.argv[1]).resolve())
