#!/usr/bin/env python3
"""RC6 checker-scope regression; serial builds, exact before/after state and cycles.
Run from the worktree root: python3 sim/arm/rc6_checks/check.py
Original assertions must reject the two minimal programs. The diagnostic-only
reference demotes only those two assertions, so its architectural behavior can
be compared. Candidate assertions stay fatal. Fault builds alter real decode
or saved controls; they must be caught, rather than merely changing a verdict.
"""
import hashlib, importlib.util, json, os, re, subprocess, sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[3]; os.chdir(ROOT)
OUT=ROOT/'build/rc6-checks-final'; OUT.mkdir(parents=True,exist_ok=True)
os.setpriority(os.PRIO_PROCESS,0,10)
(OUT/'worker.json').write_text(json.dumps({'PID':os.getpid(),'phase':'checks','NI':10}))
SRC=ROOT/'sim/arm/rc6_checks'
BASE='aa93e2327553fda30c7d715af1209d8c033139cf'
FILES='arm_pkg arm_regfile arm_mul arm_thumb arm_core arm7_ds arm9_ram arm9_mem arm_cpu'.split()
PARAM=['-GA9_CORE=1','-GA9_RF="MLAB"','-GA7_DS=1','-GSLOW=1','-GA9_SOLO=1','-GA9_OPT=1711268835','-GA9_XD=2','-GA9_XI=1','-GARM9_WAYS=2','-GEVB=1','-GEARLYD=1']
RESULT={'base':BASE,'params':PARAM,'checks':[],'mutants':[]}
def call(cmd, **kw):
    return subprocess.run(list(map(str,cmd)),**kw)
def build(name, source):
    p=OUT/(name+'.sv'); p.write_text(source)
    obj=OUT/('obj-'+name)
    cmd=['tools/verilator-locked','--binary','-j','4','-O2','-Wno-fatal','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC','-Wno-UNUSEDSIGNAL','--top-module','tb_arm','--Mdir',obj,*PARAM,*['rtl/arm/'+x+'.sv' for x in FILES],p,'sim/arm/tb_arm.sv']
    (OUT/(name+'-cmd.json')).write_text(json.dumps(list(map(str,cmd))))
    with open(OUT/(name+'-build.log'),'w') as f:r=call(cmd,stdout=f,stderr=subprocess.STDOUT)
    assert r.returncode==0, name+' build'
    return obj/'Vtb_arm'
def image(name,source):
    stem=OUT/name; stem.with_suffix('.s').write_text(source)
    for cmd in [['clang','--target=armv5te-none-eabi','-c','-Wa,-I,sim/arm/tests',stem.with_suffix('.s'),'-o',stem.with_suffix('.o')],['ld.lld','-Ttext=0x02000000','--oformat=binary',stem.with_suffix('.o'),'-o',stem.with_suffix('.bin')],['python3','sim/arm/tools/mkhex.py',stem.with_suffix('.hex'),str(stem.with_suffix('.bin'))+'@0x02000000']]:
        r=call(cmd,capture_output=True,text=True); assert r.returncode==0,(name,r.stderr)
    return stem.with_suffix('.hex')
def run(sim,name,args):
    stem=OUT/name
    cmd=[sim,*args,f'+trace0={stem}.0.csv',f'+trace1={stem}.1.csv',f'+ops0={stem}.0.ops',f'+ops1={stem}.1.ops']
    if '+run=2' in args:
        cmd=[c for c in cmd if not str(c).startswith(('+trace0=', '+trace1=', '+ops0=', '+ops1='))]
    r=call(cmd,capture_output=True,text=True); text=r.stdout+r.stderr
    stem.with_suffix('.log').write_text(text)
    return {'rc':r.returncode,'pass':'TEST PASSED' in text,'cycles':re.findall(r'^cycles=(\d+)',text,re.M),'rows':[Path(str(stem)+f'.{i}.csv').read_bytes() if Path(str(stem)+f'.{i}.csv').exists() else b'' for i in range(2)],'ops':[Path(str(stem)+f'.{i}.ops').read_bytes() if Path(str(stem)+f'.{i}.ops').exists() else b'' for i in range(2)],'text':text}
def pair(name,args):
    a=run(before,name+'-before',args); b=run(after,name+'-after',args)
    ok=a['pass']==b['pass'] and a['rc']==b['rc'] and a['cycles']==b['cycles'] and a['rows']==b['rows'] and a['ops']==b['ops'] and (sum(map(len,b['rows']))>0 or '+run=2' in args)
    row={'name':name,'equivalent':ok,'pass':b['pass'],'cycles':b['cycles'],'trace_rows':[len(x.splitlines()) for x in b['rows']]}
    RESULT['checks'].append(row); (OUT/'result.json').write_text(json.dumps(RESULT,indent=2))
    print(row,flush=True); assert ok,name+' differs'
    if not b['pass']:RESULT.setdefault('inherited_failures',[]).append(name)
original=call(['git','show',BASE+':rtl/arm/arm9_core.sv'],capture_output=True,text=True).stdout
candidate=Path('rtl/arm/arm9_core.sv').read_text()
# Synthesis preprocessor equality, including the formerly unused read helper.
v=str(Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin/verilator')
clean=[]
for n,s in [('before',original),('after',candidate)]:
    p=OUT/('synth-'+n+'.sv');p.write_text(s)
    r=call([v,'-E','-P','-DSYNTHESIS','rtl/arm/arm_pkg.sv',p],capture_output=True,text=True)
    assert r.returncode==0,r.stderr
    tokens=re.sub(r'\s+','',r.stdout)
    clean.append(tokens);(OUT/('synth-'+n+'.tokens')).write_text(tokens)
assert clean[0]==clean[1],'synthesized input changed'
RESULT['synthesis_tokens_equal']=True;RESULT['synthesis_sha256']=hashlib.sha256(clean[0].encode()).hexdigest()
# Reference diagnostics replace fatal errors only; hardware/other assertions unchanged.
diag=original
for msg in ['arm9_core: shifter controls differ', 'arm9_core: field reads miss']:
    diag=re.sub(r'\$error\("'+re.escape(msg), '$display("'+msg,diag)
before=build('diag-reference',diag);after=build('candidate',candidate)
for name in ['repro','swp','active']:
    im=image(name,(SRC/(name+'.s')).read_text());pair(name,[f'+img0={im}','+pc0=02000000','+run=1','+maxcycles=10000'])
# Existing immutable CPU images are copied, never modified in their donor tree.
assets=Path(os.environ.get('ARM_IMAGES',str(Path.home()/'Git/NDS_Pocket-wt/a9-stall/build/arm')))
spec=importlib.util.spec_from_file_location('cpu_tests',ROOT/'sim/arm/tools/run_tests.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
for name,args,_ in mod.tests(str(assets),'unused'):
    pair('suite-'+name,args)
for dense in [False,True]:
    for seed in range(1,26):
        env=dict(os.environ,DENSE='1' if dense else '0')
        r=call(['python3',SRC/'gen.py',seed,1500,3],env=env,capture_output=True,text=True);assert r.returncode==0
        name=f'rnd-{int(dense)}-{seed:02d}';im=image(name,r.stdout)
        pair(name,[f'+img0={im}','+pc0=02000000','+run=1','+maxcycles=2000000'])
        assert RESULT['checks'][-1]['pass'],name+' failed'
# Actual saved-control corruption remains fatal on an executing register shift.
mut=candidate.replace('t_shc <= shctl(eu.sh_type, e_c[7:0]);','t_shc <= shctl(SH_LSL, e_c[7:0]);')
assert mut!=candidate
bad=build('mutant-shift',mut);r=run(bad,'fault-shift',[f'+img0={OUT}/active.hex','+pc0=02000000','+run=1','+maxcycles=10000'])
assert r['rc']!=0 and 'shifter controls differ' in r['text']
RESULT['mutants'].append({'name':'actual saved shift type forced LSL','caught':True})
# The first SWP microstep really must read Rm; wrong source must still be caught.
needle='u.rc = phys_reg(rm, mode); u.lc = rm;\n          u.c_pc = (rm == 4\'hF);\n          u.st_save = 1\'b1;'
mut=candidate.replace(needle,needle.replace('phys_reg(rm, mode); u.lc = rm','phys_reg(4\'d0, mode); u.lc = 4\'d0'))
assert mut!=candidate
bad=build('mutant-store',mut);r=run(bad,'fault-store',[f'+img0={OUT}/swp.hex','+pc0=02000000','+run=1','+maxcycles=10000'])
assert r['rc']!=0 and 'field reads miss' in r['text']
RESULT['mutants'].append({'name':'actual SWP store capture reads wrong register','caught':True})
RESULT['PASS']=True;(OUT/'result.json').write_text(json.dumps(RESULT,indent=2))
(OUT/'worker.json').write_text(json.dumps({'PID':os.getpid(),'phase':'terminal','PASS':True}))
print('PASS exact synthesis tokens/state/cycles, CPU suite,25 ordinary+25 DENSE seeds and two actual faults',flush=True)
