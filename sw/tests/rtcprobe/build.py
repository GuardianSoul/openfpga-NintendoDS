#!/usr/bin/env python3
"""Build the public RTC probe and its host/RTL checks. Never execute hardware."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--out',type=Path,default=Path('build/rtcprobe-artifacts'))
p.add_argument('--verilator',default='verilator')
a=p.parse_args()
root=Path(__file__).resolve().parents[3]; here=root/'sw/tests/rtcprobe'
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
commands=[]
def run(cmd,log):
    cmd=[str(x) for x in cmd];commands.append(cmd)
    with (out/log).open('w') as f:
        subprocess.run(cmd,cwd=root,stdout=f,stderr=subprocess.STDOUT,check=True)
run(['make','-B','build/ds-tests/rtcprobe.nds','DT_ROMS=rtcprobe','DT_CODE_rtcprobe=TSRT'],'build.log')
run(['clang','-DRTC_PROBE_HOST','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-g',here/'probe.c',here/'host_test.c','-o',out/'host-test'],'host-build.log')
run([out/'host-test'],'host-test.log')
run(['clang','-DRTC_PROBE_HOST','-std=c11','-O2','-c',here/'probe.c','-o',out/'probe.o'],'rtl-c-build.log')
run([a.verilator,'--cc','--exe','--build','-j','4','-O2','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC','--top-module','nds_rtc','-GSEC_TICKS=32728','--Mdir',out/'rtl-obj',root/'rtl/ds/nds_rtc.sv',here/'rtl_test.cpp','-LDFLAGS',str(out/'probe.o')],'rtl-build.log')
run([out/'rtl-obj/Vnds_rtc'],'rtl-test.log')
for name in ['arm7.elf','arm9.elf','arm7.bin','arm9.bin']:
    shutil.copy2(root/'build/ds-tests/rtcprobe'/name,out/name)
shutil.copy2(root/'build/ds-tests/rtcprobe.nds',out/'rtcprobe.nds')
inputs=[f for f in here.iterdir() if f.is_file()]
inputs += [root/n for n in ['sw/tests/tests.mk','sw/tests/common/ds.h','sw/tests/common/con.h','sw/tests/common/con.c','sw/tests/common/results.h','sw/tests/common/results.c','sw/tests/common/crt0.s','sw/tests/common/ds.ld','sw/tests/common/ipc.h','tools/ds-tests/mknds.py','tools/ds-tests/mkfont.py','rtl/ds/nds_rtc.sv']]
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
manifest={'source_revision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
          'commands':commands,'source_sha256':{str(f.relative_to(root)):sha(f) for f in inputs},
          'artifact_sha256':{n:sha(out/n) for n in ['rtcprobe.nds','arm7.elf','arm9.elf','arm7.bin','arm9.bin','host-test','rtl-obj/Vnds_rtc']},
          'tools':{n:subprocess.check_output([n,'--version'],text=True).splitlines()[0] for n in ['clang','ld.lld','llvm-objcopy',a.verilator]},
          'native_execution':False,'limits':['Host serial model and accelerated RTL only; ARM7/ARM9 ROM execution not performed','Read-to-clear status flags cannot be restored','Restore precision bounded by logged edge bracket, serial write duration and timer error','No alarm/reset command writes; nonzero status2 skips clock tests']}
(out/'build.json').write_text(json.dumps(manifest,indent=2)+'\n')
print((out/'host-test.log').read_text().strip())
print((out/'rtl-test.log').read_text().strip())
print('ROM SHA256 '+manifest['artifact_sha256']['rtcprobe.nds'])
