#!/usr/bin/env python3
"""Retain one portable production transplant result and immutable control."""
from pathlib import Path
import argparse,gzip,hashlib,io,json,subprocess,tarfile

R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--build',type=Path,required=True)
p.add_argument('--output',type=Path,required=True);a=p.parse_args();B=a.build.resolve();O=a.output.resolve();O.mkdir(parents=True,exist_ok=True)
files={};sha=lambda b:hashlib.sha256(b).hexdigest()
for kind in ['cpu','pair','domain']:
    for f in sorted((B/kind).rglob('*')):
        if not f.is_file() or '__pycache__' in f.parts or 'tmp' in f.relative_to(B).parts:continue
        if 'obj' in f.parts and f.name not in ['Vtb_arm','Vtb','Vtb_arm__verFiles.dat','Vtb__verFiles.dat']:continue
        files[kind+'/'+str(f.relative_to(B/kind))]=f.read_bytes()
for n in ['arm7_ds','arm_cpu','cpu_domain']:
    path='rtl/arm/'+n+'.sv';files['production/'+path]=(R/path).read_bytes()
    files['before/'+path]=subprocess.check_output(['git','show','de6039a5:'+path],cwd=R)
files['production/rtl/ds/nds_arm7_port.sv']=(R/'rtl/ds/nds_arm7_port.sv').read_bytes()
for n in ['cpu_ledger.svh','p7_ledger.svh']:
    files['tools/'+n]=(R/'sim/arm/a7_logical_slot'/n).read_bytes()
for f in Path(__file__).parent.glob('*.py'):files['tools/'+f.name]=f.read_bytes()
for n in ['evidence.tar.gz','inputs.json']:
    files['qualified-pair/'+n]=(R/'docs/results/a7-logical-slot-pair-20261102'/n).read_bytes()
files['verify.py']=(O/'verify.py').read_bytes()
c=json.loads(files['cpu/results.json']);q=json.loads(files['pair/results.json']);d=json.loads(files['domain/results.json'])
assert len(c['DENSE'])==25 and len(c['ARM'])==26 and c['status'].startswith('PASS')
assert len(q['cases'])==15 and q['actual_fault'] and q['status'].startswith('PASS')
assert len(d['stages'])==9 and d['status'].startswith('PASS')
summary=dict(status='PASS bounded production default-off CPU commit transplant; DS timing law remains OPEN',
    ARM_before='de6039a5',P7_dependency='d087bb7f',qualified_pair='98373e35',DENSE=25,ARM=26,
    inherited_failure='bpred7:ctx1 timeout020000b8/1490retired, unchanged',
    CPU_totals={k:sum(x[k] for x in [*c['DENSE'].values(),*c['ARM'].values()]) for k in ['pair_cycles','retired','writes','secondary']},
    production_pair_cases=15,pair_actual_fault=q['actual_fault'],domain_elaborations=9,
    production_SHA256={n:sha(b) for n,b in files.items() if n.startswith('production/')},
    resource='One LaptopL3NI10/j1/t1,80children reaped, lease released; no fit or enabled-area measurement',
    limits='ARM32 plain MUL/register-shift phase scope unchanged. No DS service/scaling/native/game/audio/67MHz acceptance. Root owns public top join. No wait-price/countdown changes.')
files['summary.json']=(json.dumps(summary,indent=2)+'\n').encode()
files['manifest.json']=(json.dumps({n:sha(b) for n,b in sorted(files.items())},indent=2)+'\n').encode()
with (O/'proof.tar.gz').open('wb') as raw:
    with gzip.GzipFile(fileobj=raw,mode='wb',mtime=0) as gz:
        with tarfile.open(fileobj=gz,mode='w') as tar:
            for n,b in sorted(files.items()):
                info=tarfile.TarInfo(n);info.size=len(b);info.mtime=0;info.mode=0o644;tar.addfile(info,io.BytesIO(b))
seal=dict(members=len(files),expanded_bytes=sum(map(len,files.values())),SHA256=sha((O/'proof.tar.gz').read_bytes()),summary=summary)
(O/'seal.json').write_text(json.dumps(seal,indent=2)+'\n')
print(json.dumps({k:v for k,v in seal.items() if k!='summary'}))
