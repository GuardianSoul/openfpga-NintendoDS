#!/usr/bin/env python3
"""One gated native60 compiler; runtime is a separate recorded chain."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import resource
import subprocess
import sys
import time

R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--prepared',type=Path,required=True)
p.add_argument('--allocated',action='store_true',required=True)
p.add_argument('--await-release',action='store_true')
a=p.parse_args();G=a.prepared.resolve()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));sys.dont_write_bytecode=True
sys.path.insert(0,str(R/'sim/arm/ncnb_store'));from worker_guard import guard,wait_owned
sha=lambda path:hashlib.sha256(Path(path).read_bytes()).hexdigest()
def save(name,value):
 path=G/name;temp=path.with_suffix(path.suffix+'.tmp');temp.write_text(json.dumps(value,indent=2)+'\n');temp.replace(path)
assert sha(R/'sim/arm/ncnb_store/sim_ownership.py')=='64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003'
assert not(G/'compile-controller.json').exists()
save('compile-controller.json',dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=10))
print('GATED',json.loads((G/'compile-controller.json').read_text()),flush=True)
while a.await_release and not(G/'compile-release.json').exists():time.sleep(.2)
release=json.loads((G/'compile-release.json').read_text());source=json.loads((G/'source-manifest.json').read_text())
assert source['source']=='aeaa0cb386d2fbd6f8d2505f8033015956da54b5'
for name,h in source['files'].items():assert sha(G/'source'/name)==h,name
for name,h in release['host_sha256'].items():assert sha(G/name)==h,name
assert sha(G/'build-command.json')==release['build_command_sha256']
build=json.loads((G/'build-command.json').read_text());cmd=build['argv'];assert build['source']==source['source']
assert len(build['profile'])==60 and build['profile']['VRAM_CUT_WRITE_TURN']==1
assert cmd[cmd.index('-j')+1]==cmd[cmd.index('--threads')+1]=='1'
assert str(G/'source/rtl/gpu3d/gpu3d_gxrom_adict.sv')in cmd
assert str(G/'host-observer/sim/pocket_ds/ldm53_observer.sv')in cmd
assert sha(G/'host-observer/sim/pocket_ds/ldm53_observer.sv')=='49355f602164b535a9ab4bedfcf20df14c64aaf8b2cd5b9ae8eedf213f7b6391'
(G/'tmp').mkdir(exist_ok=True);os.environ['TMPDIR']=str(G/'tmp')
guard();start=time.monotonic()
with(G/'build.log').open('w')as output:
 child=subprocess.Popen(cmd,cwd=G/'source',stdout=output,stderr=subprocess.STDOUT)
 row=dict(pid=child.pid,starttime=Path('/proc',str(child.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,child.pid),argv=cmd,cwd=str(G/'source'))
 save('build.active.json',row);print('BUILD',child.pid,row['starttime'],flush=True)
 rc=wait_owned(child)
row.update(exit=rc,reaped=True,wall_seconds=time.monotonic()-start);save('build.process.json',row)
assert rc==0,(G/'build.log').read_text()[-4000:]
model=G/'model/Vtb_ds_pocket'
save('model.json',dict(source=source['source'],sha256=sha(model),profile=build['profile'],host_sha256=release['host_sha256'],build_command_sha256=release['build_command_sha256']))
for name,h in source['files'].items():assert sha(G/'source'/name)==h,name
print('NATIVE60_MODEL_BUILT',sha(model),flush=True)
