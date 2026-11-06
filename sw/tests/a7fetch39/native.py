#!/usr/bin/env python3
"""One NI10/t1 native run using the coordinator's already-built exact model."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--binding',type=Path,required=True)
    p.add_argument('--dump-pc',help='diagnostic observer override; no timing acceptance')
    p.add_argument('--trace',action='store_true',help='bounded ARM9 observer trace for startup diagnostics')
    p.add_argument('--frames',type=int,default=240);a=p.parse_args()
    os.setpriority(os.PRIO_PROCESS,0,10)
    out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
    build=json.loads((out.parent/'build.json').read_text())
    binding=json.loads(a.binding.read_text());model=Path(binding['argv'][0])
    assert binding['source']==build['base'] and sha(model)==binding['sha256']
    # Fixed copy of the project-aware guard, staged with this run.
    for name,digest in {'sim_ownership.py':'64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003',
                        'worker_guard.py':'ebfc29078ba2ed49c2ec9c75c2c2aa9ae220ff4b016f64acebac2dc606fa5e25'}.items():
        source=ROOT/'sim/arm/read_ack'/name
        assert sha(source)==digest,('guard changed',name)
        destination=out.parent/name
        if not destination.exists():shutil.copyfile(source,destination)
        assert sha(destination)==digest
    sys.path.insert(0,str(out.parent));from worker_guard import census,guard,heavy,wait_owned
    guard();busy=heavy(census())
    rom=out.parent/'a7fetch39.nds';assert sha(rom)==build['rom_sha256']
    runtime=out.parent/'runtime'
    def hexfile(name,data):
        data+=bytes((-len(data))%4)
        (out/name).write_text(''.join(f'{int.from_bytes(data[i:i+4],"little"):08x}\n' for i in range(0,len(data),4)))
    hexfile('rom.hex',rom.read_bytes())
    for name in ('bios7','bios9','firmware'):hexfile(name+'.hex',(runtime/(name+'.bin')).read_bytes())
    boot=(ROOT/'sw/boot/bootrom.bin').read_bytes();scpu=(ROOT/'sw/scpu/cache.bin').read_bytes()
    assert len(boot)<=8192 and len(scpu)<=4096
    hexfile('boot.hex',boot+bytes(8192-len(boot))+scpu+bytes(4096-len(scpu)))
    shutil.copyfile(runtime/'bootrom.mif',out/'bootrom.mif');shutil.copyfile(ROOT/'sw/scpu/mbox.hex',out/'mbox.hex')
    args=[str(model),f'+rom={out/"rom.hex"}',f'+romsize={rom.stat().st_size}',f'+bios9={out/"bios9.hex"}',f'+bios7={out/"bios7.hex"}',
          f'+fw={out/"firmware.hex"}',f'+fwsize={(runtime/"firmware.bin").stat().st_size}',f'+boot={out/"boot.hex"}',
          f'+frames={a.frames}','+vmcheck','+progress','+stop_done=1',f'+dump_pc={a.dump_pc or build["dump_pc"]}',f'+dump_file={out/"main.bin"}']
    args += ['+wwatch=02230000']  # passive per-group completion counters
    if a.trace:args += [f'+pctrace={out/"arm9.pcs"}','+pctrace_n=10000000']
    manifest={'source':binding['source'],'model_sha256':sha(model),'rom_sha256':sha(rom),'argv':args,'host':socket.gethostname(),
              'NI':os.getpriority(os.PRIO_PROCESS,0),'capacity_before':busy,'uptime':subprocess.check_output(['uptime'],text=True).strip(),
              'inputs':{p.name:sha(p) for p in out.glob('*.hex')},'build_sha256':sha(out.parent/'build.json'),'diagnostic_only':bool(a.dump_pc)}
    start=time.monotonic()
    with (out/'run.log').open('w') as log:
        child=subprocess.Popen(args,cwd=out,stdout=log,stderr=subprocess.STDOUT)
        manifest['pid']=child.pid;(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        print('native PID',child.pid,'NI10/t1',flush=True)
        try:rc=wait_owned(child)
        except BaseException:
            child.terminate();child.wait();raise
    manifest.update(exit=rc,reaped=True,seconds=round(time.monotonic()-start,3),log_sha256=sha(out/'run.log'))
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('native complete',rc,'RAM dump', (out/'main.bin').exists(),flush=True)
    sys.exit(rc)

if __name__=='__main__':main()
