#!/usr/bin/env python3
"""Run only hazard9 + IO89 in the actual compact dedicated CPU profile."""
from pathlib import Path
import argparse, datetime, hashlib, json, os, resource, subprocess, time

R = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--source', default='faf921a3')
a = p.parse_args()
D = a.output.resolve(); D.mkdir(parents=True, exist_ok=False)
os.setpriority(os.PRIO_PROCESS, 0, 10)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
resource.setrlimit(resource.RLIMIT_CPU, (240, 240))
resource.setrlimit(resource.RLIMIT_AS, (4 * 1024**3, 4 * 1024**3))
resource.setrlimit(resource.RLIMIT_FSIZE, (128 * 1024**2, 128 * 1024**2))
sha = lambda b: hashlib.sha256(b).hexdigest()
start = lambda pid: Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()[19]
result = dict(source=subprocess.check_output(['git','rev-parse',a.source],cwd=R,text=True).strip(),
              fixture_source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),
              controller=os.getpid(), controller_starttime=start(os.getpid()), host=os.uname().nodename,
              scope='One directed ARM9 program, dedicated A7_DS1/SOLO_ONLY1; ARM7 held stopped. No P7/fabric/native/game or DS timing acceptance.',
              caps=dict(NI=10,jobs=1,threads=1,AS_bytes=4*1024**3), stages=[], rows=[])
def save():
    temp=D/'results.json.tmp';temp.write_text(json.dumps(result,indent=2)+'\n');temp.replace(D/'results.json')
def call(cmd,tag,expected=0,timeout=180):
    cmd=list(map(str,cmd));begin=time.monotonic()
    with (D/(tag+'.log')).open('w') as f:
        child=subprocess.Popen(cmd,cwd=R,stdout=f,stderr=subprocess.STDOUT)
        row=dict(tag=tag,command=cmd,PID=child.pid,starttime=start(child.pid));result['stages'].append(row);save()
        print(tag,child.pid,flush=True)
        try:row['exit']=child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            child.terminate();row['exit']=child.wait(timeout=10);row['timeout']=True
    row.update(reaped=True,wall_seconds=round(time.monotonic()-begin,3));save()
    if expected is not None:assert row['exit']==expected,(tag,(D/(tag+'.log')).read_text()[-3000:])
    return row

source=D/'source';source.mkdir()
names='arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm7_ds arm_cpu'.split()
inputs=[]
for name in names:
    b=subprocess.check_output(['git','-c','core.packedGitWindowSize=16m','show',a.source+':rtl/arm/'+name+'.sv'],cwd=R)
    target=source/(name+'.sv');target.write_bytes(b);inputs.append(target)
for name in ['tb.sv','directed.s','cp15.inc']:
    (source/name).write_bytes(Path(__file__).with_name(name).read_bytes())
result['source_SHA256']={x.name:sha(x.read_bytes()) for x in source.iterdir()};save()
call(['clang','--target=arm-none-eabi','-march=armv5te','-fuse-ld=lld','-nostdlib',
      '-I',source,'-Wl,-Ttext=0x02000000','-Wl,--entry=_start',source/'directed.s','-o',D/'guest.elf'],'guest-build')
call(['llvm-objcopy','-O','binary',D/'guest.elf',D/'guest.bin'],'guest-binary')
call(['python3',R/'sim/arm/tools/mkhex.py',D/'guest.hex',str(D/'guest.bin')+'@0x02000000'],'guest-hex')
call(['python3',R/'tools/ds/qlint.py',*inputs],'qlint')
options=['-GARM9_WAYS=4','-GSLOW=1','-GA9_SOLO=1','-GA9_OPT=461366243','-GEVB=1','-GA9_XD=0','-GA9_XI=0']
verilator='build/tools/oss-cad-suite/bin/verilator'
for kind in ['control','io-owner-mutant']:
    build=D/kind;build.mkdir();used=inputs.copy()
    if kind!='control':
        old='          rbuf_d <= b_rdata;'
        raw=(source/'arm9_mem.sv').read_text();assert raw.count(old)==1
        mutant=build/'arm9_mem.sv'
        mutant.write_text(raw.replace(old,"          rbuf_d <= b_rdata ^ ((dp_a[31:24] == 8'h04) ? 32'd1 : 32'd0);"))
        used[used.index(source/'arm9_mem.sv')]=mutant
        result['actual_mutant']=dict(file=str(mutant),SHA256=sha(mutant.read_bytes()),change='Flip bit0 in actual owned low-I/O read response capture')
    call([verilator,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal',
          '--timescale','1ns/1ps','--top-module','tb_arm',*options,'--Mdir',build/'obj',*used,source/'tb.sv'],kind+'-build')
    model=build/'obj/Vtb_arm'
    row=dict(kind=kind,model_SHA256=sha(model.read_bytes()),runs=[])
    for latency in ([2,7] if kind=='control' else [2]):
        tag=kind+'-lat'+str(latency)
        call([model,'+img0='+str(D/'guest.hex'),'+pc0=02000000','+run=1','+blat='+str(latency),
              '+maxcycles=200000','+trace0='+str(D/(tag+'.csv')),'+packets'],tag)
        log=(D/(tag+'.log')).read_text()
        if kind=='control':assert 'TEST PASSED' in log and 'TEST FAILED' not in log,(tag,log[-2000:])
        else:assert 'TEST FAILED' in log and 'result=00000059' in log,(tag,log[-2000:])
        row['runs'].append(dict(latency=latency,verdict='PASS' if kind=='control' else 'caught actual owned-read mutation'))
    result['rows'].append(row);save()
control=[(D/('control-lat'+str(n)+'.csv')).read_bytes() for n in [2,7]]
assert control[0]==control[1],'architectural state/order changes under longer external backpressure'
result['state']='PASS bounded compact dedicated-profile hazard9/IO89; two bus latencies same architectural trace, actual low-I/O owner fault caught'
result['limitations']='Not a full CPU suite, ARM7 execution or real DS timing check; no native/model/game/fit rerun, no production RTL edits.'
save();print(result['state'],flush=True)
