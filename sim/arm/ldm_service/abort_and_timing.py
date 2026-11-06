#!/usr/bin/env python3
"""Final-source first-word MPU abort and independently bounded timing fault."""
from pathlib import Path
exec(compile(Path(__file__).with_name('run.py').read_text().split("names=")[0],str(Path(__file__).with_name('run.py')),'exec'))
import importlib.util
Q=json.loads((G/'final-qualified.json').read_text())
for p,h in Q['source'].items():assert sha(R/p)==h
spec=importlib.util.spec_from_file_location('cpucheck',R/'rnd/check_cpu.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c);prep=0
def small(cmd,**kw):
 global prep;prep+=1;assert not kw;call(cmd,G/('prepare-abort-'+str(prep)+'.log'))
c.run=small
src='''.syntax unified
.arm
.global _start
.include "cp15.inc"
_start:
 CP15_REGIONS
 CP15_ENABLE
 ldr sp,=0x0b003e00
 mov r1,#0x10
 ldr r0,=0xe51ff004
 str r0,[r1]
 ldr r0,=handler
 str r0,[r1,#4]
 ldr r10,=0x0b001000
 mov r0,#0
 str r0,[r10]
 // Region7: one32-byte uncached data region, no read permission.
 ldr r0,=0x02410109
 mcr p15,0,r0,c6,c7,0
 ldr r0,=0x00613333
 mcr p15,0,r0,c5,c0,2
 mov r8,#0
 mov r0,#17
 mov r1,#34
 ldr r12,=0x02410100
 ldmia r12!,{r0,r1}
 // This younger store must be killed by the abort, not see a speculative base.
 str r12,[r10]
after_abort:
 cmp r0,#17
 bne fail
 cmp r1,#34
 bne fail
 cmp r8,#1
 bne fail
 ldr r2,[r10]
 // The store at the sequential return PC is intentionally skipped by handler.
 cmp r2,#0
 bne fail
 cmp r0,r0
 ldmiane r12!,{r0,r1}
 cmp r8,#1
 bne fail
compare_end:
 ldr r0,=0x0f000000
 mov r1,#0
 str r1,[r0]
 b .
fail:
 ldr r0,=0x0f000000
 mov r1,#1
 str r1,[r0]
 b .
handler:
 add r8,r8,#1
 // Abort LR=instruction+8; returning to LR skips the fault and younger store.
 subs pc,lr,#0
'''
image=c.assemble(src,G/'first-abort');proof={}
for n in ['before','bf3']:
 out=G/(n+'-first-abort');call([build(n),'+img0='+str(image),'+pc0=02000000','+run=1','+blat=9','+maxcycles=300000','+trace0='+str(out)+'.csv','+dbg=1'],out.with_suffix('.log'));t=out.with_suffix('.log').read_text();assert'TEST PASSED'in t,(n,t[-2000:]);proof[n]=out.with_suffix('.csv').read_bytes()
assert proof['before']==proof['bf3']
# Zeroing the real instruction service work leaves all data intact, but
# violates the observed lower endpoint of the aligned DS LDM8 envelope.
m=build('tf3');row,p,state=actual('tf3',m,'ldm8_anchor-0')
assert state==(G/'before-ldm8_anchor-0.csv').read_bytes()
DS=next(x['DS_observed_envelope'][0]for x in json.loads((G/'native-vs-DS.json').read_text())['groups']if x['case']=='ldm8_anchor'and x['offset_bytes']==0)
actual_good=json.loads((G/'final53.json').read_text())['forms']['ldm8_anchor-0']['SYS'];assert row['SYS']<DS<=actual_good
record(G/'abort-timing.json',dict(first_word_abort=dict(states=proof['bf3'].count(b'\n'),both_exact=True,result='PASS; destination registers/younger store/failed condition preserved'),timing_fault=dict(caught=True,kind='actual first-admission service-work assignment replaced with zero',architectural_state_exact=True,mutant_SYS=row['SYS'],DS_lower=DS,positive_SYS=actual_good),source=Q['source']))
print('FIRST_ABORT_AND_ACTUAL_TIMING_MUTATION_PASS',flush=True)
