"""Compare candidate CPU against immutable RC7 traces; leased serial worker only."""
import hashlib, importlib.util, json, os, re, subprocess, sys, threading
from pathlib import Path

ROOT=Path(__file__).resolve().parents[3]; os.chdir(ROOT)
OUT=ROOT/'build/rc053-mpu-cut/checks'; OUT.mkdir(parents=True,exist_ok=True)
os.setpriority(os.PRIO_PROCESS,0,10)

subprocess.run(['python3','sim/arm/rc053_mpu_cut/prove.py'],check=True)
(OUT/'worker.json').write_text(json.dumps({'PID':os.getpid(),'phase':'checks','NI':10}))
SRC=ROOT/'sim/arm/rc6_checks'
BASE='334c58ee2414e3b859cebd5a2fb508bd564ffd0c'
FILES='arm_pkg arm_regfile arm_mul arm_thumb arm_core arm7_ds arm9_ram arm9_mem arm_cpu'.split()
PARAM=['-GA9_CORE=1','-GA9_RF="MLAB"','-GA7_DS=1','-GSLOW=1','-GA9_SOLO=1','-GA9_OPT=1711268835','-GA9_XD=2','-GA9_XI=1','-GARM9_WAYS=2','-GEVB=1','-GEARLYD=1']
RESULT={'base':BASE,'params':PARAM,'checks':[],'mutants':[],'candidate_source_SHA256':hashlib.sha256((ROOT/'rtl/arm/arm9_core.sv').read_bytes()).hexdigest()}
prior=OUT/'result.json'
if prior.exists():
    saved=json.loads(prior.read_text())
    assert saved['candidate_source_SHA256']==RESULT['candidate_source_SHA256'] and saved['params']==PARAM
    RESULT['checks']=[x for x in saved['checks'] if x['equivalent']]
DONE={x['name']:x for x in RESULT['checks']}
def call(cmd, **kw):
    p=subprocess.Popen(list(map(str,cmd)),**kw)
    state=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json')
    d=json.loads(state.read_text());d.update(phase='RC053 CPU comparison/build',workers=[dict(host='Desktop',controller=os.getpid(),child=p.pid,NI=10,jobs=1,threads=1)])
    t=state.with_suffix('.tmp');t.write_text(json.dumps(d));t.replace(state)
    return subprocess.CompletedProcess(cmd,p.wait())
def build(name, source):
    assert int(next(l.split()[1] for l in Path('/proc/meminfo').read_text().splitlines() if l.startswith('MemAvailable:'))) >= 12*1024*1024, 'need12GiB for CPU build'
    p=OUT/(name+'.sv'); obj=OUT/('obj-'+name)
    if p.exists() and p.read_text()==source and (obj/'Vtb_arm').exists():return obj/'Vtb_arm'
    p.write_text(source)
    cmd=['tools/verilator-locked','--binary','-j','1','-O2','-Wno-fatal','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC','-Wno-UNUSEDSIGNAL','--top-module','tb_arm','--Mdir',obj,*PARAM,*['rtl/arm/'+x+'.sv' for x in FILES],p,'sim/arm/tb_arm.sv']
    (OUT/(name+'-cmd.json')).write_text(json.dumps(list(map(str,cmd))))
    with open(OUT/(name+'-build.log'),'w') as f:r=call(cmd,stdout=f,stderr=subprocess.STDOUT)
    assert r.returncode==0, name+' build'
    return obj/'Vtb_arm'
DONOR=Path('/home/user/Git/NDS_Pocket-codex-rc7-rf-m10k/build/rf-m10k-cpu')
BIND=json.loads((DONOR/'result.json').read_text())
EXPECTED={x['name']:x for x in BIND['checks']}
PARENT_RECEIPT=Path('/home/user/Git/NDS_Pocket-codex-rc7-earlyhalf-on-flat/build/rc053-earlyhalf-flat/checks/result.json')
PREV=json.loads(PARENT_RECEIPT.read_text());assert PREV['PASS'] and len(PREV['checks'])==83
parent_source=subprocess.check_output(['git','show',BASE+':rtl/arm/arm9_core.sv'])
assert hashlib.sha256(parent_source).hexdigest()==PREV['candidate_source_SHA256']
for name in FILES:
    path='rtl/arm/'+name+'.sv'
    if name not in ['arm9_mem','arm_cpu']:
        assert Path(path).read_bytes()==subprocess.check_output(['git','show',BASE+':'+path])
        assert Path(path).read_bytes()==subprocess.check_output(['git','show','286a7190:'+path])
PARENT_CHECKS={x['name']:x for x in PREV['checks']}
RESULT['parent_receipt']=str(PARENT_RECEIPT)
RESULT['parent_receipt_SHA256']=hashlib.sha256(PARENT_RECEIPT.read_bytes()).hexdigest()
RESULT['parent_source_SHA256']=PREV['candidate_source_SHA256']

def digest(path, compressed=False):
    import gzip
    h=hashlib.sha256()
    if not path.exists():return h.hexdigest()
    with (gzip.open(path,'rb') if compressed else path.open('rb')) as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()
def pair(name,args):
    # Use immutable prior-version results; never execute or modify donor files.
    if name in DONE:
        assert DONE[name]['hashes']==PARENT_CHECKS[name]['hashes']
        assert DONE[name]['input_hashes']=={a:digest(Path(a.split('=',1)[1])) for a in args if a.startswith(('+img0=','+img1='))}
        return
    stem=OUT/(name+'-after');cmd=[after,*args]
    streams={};readers=[]
    def consume(path,ext):
        h=hashlib.sha256()
        with path.open('rb',buffering=0) as f:
            for chunk in iter(lambda:f.read(1048576),b''):h.update(chunk)
        streams[ext]=h.hexdigest()
    if '+run=2' not in args:
        for ext in ['0.csv','1.csv','0.ops','1.ops']:
            path=Path(str(stem)+'.'+ext)
            if path.exists():path.unlink()
            os.mkfifo(path)
            t=threading.Thread(target=consume,args=(path,ext),daemon=True);t.start();readers.append(t)
    if '+run=2' not in args:
        cmd += [f'+trace0={stem}.0.csv',f'+trace1={stem}.1.csv',f'+ops0={stem}.0.ops',f'+ops1={stem}.1.ops']
    with stem.with_suffix('.log').open('w') as f:r=call(cmd,stdout=f,stderr=subprocess.STDOUT)
    for t in readers:t.join(timeout=30);assert not t.is_alive(),'FIFO reader stuck'
    text=stem.with_suffix('.log').read_text();exp=EXPECTED[name]
    before=(DONOR/(name+'-before.log')).read_text()
    markers=lambda t:re.findall(r'^.*(?:TEST (?:PASSED|FAILED)|timeout at pc=|%Error:).*$',t,re.M)
    # Fixture emits $finish on success and inherited timeouts; fatal aborts are separate.
    baseline_rc=-6 if 'Aborting...' in before else 0
    hashes={ext:streams.get(ext,hashlib.sha256(b'').hexdigest()) for ext in ['0.csv','1.csv','0.ops','1.ops']}
    expected={ext:digest(DONOR/(name+'-before.'+ext+'.gz'),True) for ext in hashes}
    assert expected==PARENT_CHECKS[name]['hashes']
    passed='TEST PASSED' in text;cycles=re.findall(r'^cycles=(\d+)',text,re.M)
    ok=hashes==expected and passed==exp['pass'] and cycles==exp['cycles'] and r.returncode==baseline_rc and markers(text)==markers(before)
    assert passed==PARENT_CHECKS[name]['passed'] and cycles==PARENT_CHECKS[name]['cycles'] and r.returncode==PARENT_CHECKS[name]['rc'],name+' parent comparison'
    row=dict(name=name,equivalent=ok,passed=passed,cycles=cycles,rc=r.returncode,hashes=hashes)
    row['input_hashes']={a:digest(Path(a.split('=',1)[1])) for a in args if a.startswith(('+img0=','+img1='))};RESULT['checks'].append(row);(OUT/'result.json').write_text(json.dumps(RESULT,indent=2));print(row,flush=True)
    assert ok,name+' differs'
    for ext in hashes:
        p=Path(str(stem)+'.'+ext)
        if p.exists():p.unlink()
candidate=Path('rtl/arm/arm9_core.sv').read_text()
after=build('candidate',candidate)
for name in ['repro','swp','active']:
    pair(name,[f'+img0={DONOR}/{name}.hex','+pc0=02000000','+run=1','+maxcycles=10000'])
assets=Path('/home/user/Git/NDS_Pocket-wt/a9-stall/build/arm')
spec=importlib.util.spec_from_file_location('cpu_tests',ROOT/'sim/arm/tools/run_tests.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
for name,args,_ in mod.tests(str(assets),'unused'):pair('suite-'+name,args)
for dense in [0,1]:
    for seed in range(1,26):
        name=f'rnd-{dense}-{seed:02d}';pair(name,[f'+img0={DONOR}/{name}.hex','+pc0=02000000','+run=1','+maxcycles=2000000'])
RESULT['PASS']=True;RESULT['mutants']=json.loads((ROOT/'build/rc053-mpu-cut/proof/result.json').read_text())['cases'];(OUT/'result.json').write_text(json.dumps(RESULT,indent=2))
