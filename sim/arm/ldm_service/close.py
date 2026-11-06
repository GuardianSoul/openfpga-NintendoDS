#!/usr/bin/env python3
"""Complete the final-source receipt, reusing already finished final CPU gates."""
from pathlib import Path
exec(compile(Path(__file__).with_name('run.py').read_text().split("names=")[0],str(Path(__file__).with_name('run.py')),'exec'))
import importlib.util
if not (G/'final53.json').exists():
 d=json.loads((G/'results-final.json').read_text());assert len(d['forms'])==53
 record(G/'final53.json',dict(forms={k:v['bf3']for k,v in d['forms'].items()},source={p:sha(R/p)for p in ['rtl/arm/arm_core.sv','rtl/arm/arm_cpu.sv','rtl/arm/cpu_domain.sv','rtl/ds/nds_top.sv','rtl/ds/nds_fabric.sv']}))
source=json.loads((G/'final53.json').read_text())['source']
cpu_prefix='cpu-final' if (G/'cpu-final/model.json').exists() else 'cpu-on'
for f,h in source.items():assert sha(R/f)==h
DENSE={}
for seed in range(1301,1326):
 stem='seed'+str(seed);a=G/('cpu-before-'+stem);b=G/(cpu_prefix+'-'+stem);assert'TEST PASSED'in b.with_suffix('.log').read_text();assert a.with_suffix('.csv').read_bytes()==b.with_suffix('.csv').read_bytes();assert re.findall(r'^PACKET.*$',a.with_suffix('.log').read_text(),re.M)==re.findall(r'^PACKET.*$',b.with_suffix('.log').read_text(),re.M);DENSE[stem]=True
spec=importlib.util.spec_from_file_location('suite',R/'sim/arm/tools/run_tests.py');suite=importlib.util.module_from_spec(spec);spec.loader.exec_module(suite);ARM={}
for test,args,desc in suite.tests(str(G/'test-images'),'unused'):
 t=(G/(cpu_prefix+'-'+test+'.log')).read_text();ARM[test]=dict(verdict='PASS'if'TEST PASSED'in t else'FAIL',cycles=re.findall(r'cycles=(\d+)',t))
assert[k for k,v in ARM.items()if v['verdict']=='FAIL']==['bpred7']and len(ARM)==26
spec=importlib.util.spec_from_file_location('cpucheck',R/'rnd/check_cpu.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c);prep=0
def small(cmd,**kw):
 global prep;prep+=1;assert not kw;call(cmd,G/('prepare-close-'+str(prep)+'.log'))
c.run=small
image=c.assemble('''.syntax unified
.arm
.global _start
_start:
 ldr r12,=0x03001000
 mov r0,#42
 str r0,[r12]
 // Existing bench control schedules wake relative to this actual write.
 ldr r0,=0x0f00000c
 ldr r1,=0x80001388
 str r1,[r0]
 ldr r0,=0x04000301
 mov r1,#128
 strb r1,[r0]
 ldr r0,[r12]
 cmp r0,#42
 bne fail
 ldr r0,=0x0f00000c
 mov r1,#0
 str r1,[r0]
 ldr r6,=200
1: ldr r0,[r12]
 add r1,r12,#0
 mov r3,r12
 subs r6,r6,#1
 bne 1b
 ldr r0,=0x0f00000c
 ldr r1,=0x800007d0
 str r1,[r0]
 ldr r0,=0x04000301
 mov r1,#128
 strb r1,[r0]
 ldr r0,=0x0f00000c
 mov r1,#0
 str r1,[r0]
wake_compare_end:
 ldr r0,=0x0f000000
 mov r1,#0
 str r1,[r0]
 b .
fail:
 ldr r0,=0x0f000000
 mov r1,#1
 str r1,[r0]
 b .
''',G/'wake-a7-real')
wake={};model=build('bf3')
a9_end=next(x.split()[0]for x in subprocess.check_output(['llvm-nm',G/'ldm2-0.elf'],text=True).splitlines()if x.endswith(' compare_end'))
a7_end=next(x.split()[0]for x in subprocess.check_output(['llvm-nm',G/'wake-a7-real.elf'],text=True).splitlines()if x.endswith(' wake_compare_end'))
for n,m in [('before',build('before')),('final',model)]:
 out=G/(n+'-wake-real');call([m,'+img0='+str(G/'ldm2-0.hex'),'+img1='+str(image),'+pc0=02000000','+pc1=02000000','+run=3','+blat=9','+maxcycles=300000','+trace0='+str(out)+'.csv','+trace1='+str(out)+'.a7.csv','+ops0='+str(out)+'.ops','+ops1='+str(out)+'.a7.ops'],out.with_suffix('.log'));assert'TEST PASSED'in out.with_suffix('.log').read_text(),out.with_suffix('.log').read_text()[-1500:];rows9=out.with_suffix('.csv').read_text().splitlines();rows7=out.with_suffix('.a7.csv').read_text().splitlines()
 wake[n]=dict(a9='\n'.join(rows9[:next(i for i,x in enumerate(rows9)if x.startswith(a9_end+','))]),a7='\n'.join(rows7[:next(i for i,x in enumerate(rows7)if x.startswith(a7_end+','))]))
 times=[int(x.split()[3])for x in out.with_suffix('.a7.ops').read_text().splitlines()];gaps=[(a,b)for a,b in zip(times,times[1:])if b-a>1800];assert len(gaps)>=2,(n,gaps)
 words=[int(x)for x in re.findall(r'^LDMWORD c(\d+)',out.with_suffix('.log').read_text(),re.M)];assert all(any(a<c<b for c in words)for a,b in gaps[:2]),(n,gaps)
 record(G/(n+'-wake-gaps.json'),dict(gaps=gaps,ldm_active_in_both_halts=True,cut9=a9_end,cut7=a7_end))
assert wake['before']==wake['final'],('solo/barrel transition state mismatch')
print('REAL_CONTROL_ARM7_WAKE_BOTH_CONTEXTS_EXACT',flush=True)
# Actual final-source mutation builds, not merely the previous guarded model.
m=build('mf3');log=G/'final-mutant-data.log';rc=call([m,'+img0='+str(G/'fixed2-0.hex'),'+pc0=02000000','+run=1','+blat=9','+maxcycles=300000'],log,True);assert rc!=0 and'physical DATA mismatch'in log.read_text()and'timeout'not in log.read_text().lower()
m=build('cf3');r,p,state=actual('cf3',m,'ldm2-0');assert state!=(G/'before-ldm2-0.csv').read_bytes();print('FINAL_SOURCE_TWO_MUTANTS_CAUGHT',flush=True)
# Exact-source default-off trace proof.
off=build('off3');defaults={}
for tag,v in json.loads((G/'results-bf.json').read_text())['forms'].items():
 row,p,state=actual('off3',off,tag);assert row==v['before']and state==(G/('before-'+tag+'.csv')).read_bytes();assert (G/('off3-'+tag+'.ops')).read_bytes()==(G/('before-'+tag+'.ops')).read_bytes();defaults[tag]=True
print('FINAL_DEFAULT53_EXACT',flush=True)
# Original semantic/abort suite on the final source and physical transport.
for n,m in [('before',build('before')),('final',model)]:
 out=G/(n+'-final-directed');call([m,'+img0='+str(G/'directed.hex'),'+pc0=02000000','+run=1','+blat=9','+maxcycles=300000','+trace0='+str(out)+'.csv','+dbg=1'],out.with_suffix('.log'));assert'TEST PASSED'in out.with_suffix('.log').read_text()
assert (G/'before-final-directed.csv').read_bytes()==(G/'final-final-directed.csv').read_bytes()
pattern=r'^LDMWORD c\d+ a([0-9a-f]+) meta([0-9a-f]+) d([0-9a-f]+)$'
a=re.findall(pattern,(G/'before-final-directed.log').read_text(),re.M);b=re.findall(pattern,(G/'final-final-directed.log').read_text(),re.M);assert a==b and len(b)==97
V='build/tools/oss-cad-suite/bin/verilator'
arm=[R/'rtl/arm'/(f+'.sv')for f in 'arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm_cpu arm7_ds cpu_domain cdc_req cdc_fifo cdc_a7'.split()]+[R/p for p in ['rtl/ds/nds_ram.sv','rtl/ds/nds_arm7_port.sv','rtl/ds/nds_lcache.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/gpu2d/gpu2d_ram.sv']]
for fast in [0,1]:
 for solo in [1,3,5]:call([V,'--lint-only','--timing','--assert','-Wno-fatal','--top-module','cpu_domain','-GA9_LDM_BASE_FORWARD=1',f'-GCPU_FAST={fast}',f'-GA9_SOLO={solo}',*arm],G/f'final-route-fast{fast}-solo{solo}.log')
for f,h in source.items():assert sha(R/f)==h
record(G/'final-qualified.json',dict(source=source,default53=defaults,final53_profile_exact=True,DENSE=DENSE,ARM=ARM,wake=dict(ARM9_states=len(wake['final']['a9'].splitlines()),ARM7_states=len(wake['final']['a7'].splitlines()),both_exact=True,scope='existing bench control:5000/2000clocks, two observed sleep gaps with active LDM; compare both architectural streams through explicit completion PCs, excluding post-completion idle iterations'),pin_semantic97=True,mutations=dict(final_capture=True,forwarded_base=True,coherence=json.loads((G/'ownership.json').read_text())['results']['stale-mutant']),ownership=json.loads((G/'ownership.json').read_text()),routes=6))
print('FINAL_SOURCE_SERVICE_QUALIFIED',flush=True)
