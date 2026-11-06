#!/usr/bin/env python3
"""Complete 33-input-bit equivalence of the actual old/new anz expression."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--out', type=Path, required=True)
p.add_argument('--before', default='55a7cbf8c7c916d3207a84b44822a2a11387deb3')
a = p.parse_args()
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=True)
os.setpriority(os.PRIO_PROCESS,0,10)
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
pid = os.getpid()
started = Path('/proc/self/stat').read_text().rsplit(')',1)[1].split()[19]
status = Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json')


def phase(value,active=1):
    d = json.loads(status.read_text())
    d.update(phase=value,worker=dict(host='Desktop',controller_pid=pid,starttime=started,active=active,nice=10,jobs=1,threads=1),
             updated_at=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
    s = json.dumps(d,indent=2)+'\n'
    assert len(s.encode())<2048
    tmp = status.with_suffix('.tmp')
    tmp.write_text(s)
    tmp.replace(status)


def capacity():
    rows = [s.split(None,3) for s in subprocess.check_output(['ps','-eo','pid,ppid,ni,comm'],text=True).splitlines()[1:]]
    parents = {int(p):int(pp) for p,pp,_,_ in rows}
    def ancestors(n):
        seen = set()
        while n in parents and n not in seen:
            seen.add(n)
            n=parents[n]
        return seen
    heavy = {int(p) for p,_,_,c in rows if c.startswith(('V','verilator_bin','clang','census','yosys','z3','boolector')) or c in ('cc1plus','cc1','lto1')}
    leaves = {n for n in heavy if not any(n in ancestors(o)-{o} for o in heavy)}
    foreign = [n for n in leaves if pid not in ancestors(n)]
    with (out/'capacity.jsonl').open('a') as f:
        f.write(json.dumps(dict(time=time.time(),foreign=foreign,max_foreign=2,load=os.getloadavg()))+'\n')
    return len(foreign)<=2


phase('anz58 complete operand proof preparing')
print(f'controller_pid={pid} starttime={started} NI10/j1/t1 out={out}',flush=True)
path = 'rtl/gpu3d/gpu3d_gxvfin.sv'
old = subprocess.check_output(['git','show',a.before+':'+path],cwd=ROOT,text=True)
new = (ROOT/path).read_text()
oldexpr = re.findall(r'anz <= (.*);',old)
newexpr = re.findall(r'anz <= (.*);',new)
assert len(oldexpr)==len(newexpr)==1 and newexpr==['z_scaled']
lines = [line for line in new.splitlines() if re.match(r'    (?:wire signed \[32:0\] p2_signed, z_signed;|wire \[63:0\] z_scaled;|assign (?:p2_signed|z_signed|z_scaled) =)',line)]
assert len(lines)==5
candidate = '\n'.join(lines)
variants = {'positive-sign0':(candidate,0),'positive-sign1':(candidate,1),
            'min-fault':(candidate.replace('azn ? -p2_signed : p2_signed',"azn ? 33'($signed(32'(-p2_signed))) : p2_signed"),1),
            'sign-fault':(candidate.replace('azn ? -p2_signed : p2_signed','azn ? p2_signed : -p2_signed'),0)}
assert len(set(w for w,s in variants.values()))==3
yosys = 'build/tools/oss-cad-suite/bin/yosys'
cases=[]
for name,(wires,sign) in variants.items():
    while not capacity():
        print('WAIT global<=3',flush=True)
        time.sleep(5)
    phase('anz58 complete operand proof '+name)
    folder=out/name
    folder.mkdir(exist_ok=True)
    text='''module local_anz(input [31:0] p2,
output [63:0] expected,actual,output equal);
'''+f"wire azn=1'b{sign};\n"+wires+'\nassign expected='+oldexpr[0]+';\nassign actual='+newexpr[0]+';\nassign equal=expected==actual;\nendmodule\n'
    (folder/'actual.sv').write_text(text)
    # Both constant-sign partitions have all2^32 p2 values free. The
    # actual truncation fault is constrained only to its INT_MIN witness;
    # the sign fault uses +1 so the incorrect sign is explicit.
    positive=name.startswith('positive')
    settings='' if positive else '-set p2 32\'h80000000 ' if name=='min-fault' else '-set p2 1 '
    verdict='-verify' if positive else '-falsify'
    script=f'read_verilog -sv {folder/"actual.sv"}; prep -top local_anz; flatten; techmap; opt; sat {verdict} -prove equal 1 {settings}-show p2,azn,expected,actual -dump_json {folder/"witness.json"}'
    (folder/'proof.ys').write_text(script+'\n')
    cmd=[yosys,'-Q','-T','-s',str(folder/'proof.ys')]
    env=dict(os.environ,OMP_NUM_THREADS='1')
    with (folder/'proof.log').open('w') as log:
        process=subprocess.Popen(cmd,cwd=folder,stdout=log,stderr=subprocess.STDOUT,env=env)
        (folder/'worker.json').write_text(json.dumps(dict(pid=process.pid,controller=pid,starttime=Path('/proc'/Path(str(process.pid))/'stat').read_text().rsplit(')',1)[1].split()[19]))+'\n')
        try:
            rc=process.wait(timeout=60)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            phase('anz58 local proof timeout '+name,0)
            raise
    log=(folder/'proof.log').read_text()
    assert rc==0,(name,rc)
    assert ('SUCCESS!' if positive else 'FAIL!') in log,name
    if name=='min-fault':
        assert '80000000' in log and '  1 ' in log
    cases.append(dict(name=name,sign=sign,command=cmd,exit=rc,verdict='UNSAT complete equivalence' if positive else 'SAT actual fault caught',
                      source_sha256=hashlib.sha256(text.encode()).hexdigest(),script_sha256=hashlib.sha256(script.encode()).hexdigest()))
    print(name+': '+cases[-1]['verdict'],flush=True)
r=dict(before=a.before,old_full_source_sha256=hashlib.sha256(old.encode()).hexdigest(),new_full_source_sha256=hashlib.sha256(new.encode()).hexdigest(),
       input_bits=33,operand_patterns=8589934592,independent_sign=True,output_bits=64,cases=cases,
       controller=pid,starttime=started,nice=10,jobs=1,threads=1)
(out/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
phase('anz58 complete2^33 operand proof+both actual faults PASS',0)
