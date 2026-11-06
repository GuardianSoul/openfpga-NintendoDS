#!/usr/bin/env python3
"""Serial full64 product/CPU/producer equivalence against c25c2ed3."""
from pathlib import Path
import argparse, hashlib, json, os, resource, shutil, struct, subprocess, time

R = Path(__file__).resolve().parents[3]
P = argparse.ArgumentParser(description=__doc__)
P.add_argument('--output', type=Path, required=True)
P.add_argument('--variant', choices=['candidate', 'sign-mutant'], default='candidate')
P.add_argument('--verilator', default='build/tools/oss-cad-suite/bin/verilator')
a = P.parse_args(); D = a.output.resolve(); D.mkdir(parents=True, exist_ok=False)
os.setpriority(os.PRIO_PROCESS, 0, 10); resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
(D/'tmp').mkdir(); os.environ['TMPDIR'] = str(D/'tmp')
sha = lambda b: hashlib.sha256(b).hexdigest()
q = dict(base='c25c2ed3', variant=a.variant, controller=os.getpid(), stages=[], cases={})
def save(): (D/'results.json').write_text(json.dumps(q, indent=2)+'\n')
def call(cmd, tag, limit=300):
    cmd = list(map(str, cmd)); start = time.monotonic()
    with (D/(tag+'.log')).open('w') as f:
        p = subprocess.Popen(cmd, cwd=R, stdout=f, stderr=subprocess.STDOUT)
        row = dict(tag=tag, PID=p.pid, NI=os.getpriority(os.PRIO_PROCESS, p.pid), cmd=cmd,
                   starttime=Path('/proc', str(p.pid), 'stat').read_text().split()[21])
        q['stages'].append(row); save(); print(tag, p.pid, flush=True)
        try: row['exit'] = p.wait(timeout=limit)
        except subprocess.TimeoutExpired:
            p.terminate(); p.wait(timeout=10); row.update(exit=p.returncode, timeout=True)
    row.update(reaped=True, seconds=round(time.monotonic()-start, 3)); save()
    return row['exit']

S = D/'source'; S.mkdir(); files = []
rels = ['rtl/arm/arm_pkg.sv', 'rtl/arm/arm_thumb.sv', 'rtl/arm/arm7_ds.sv',
        'rtl/ds/nds_arm7_port.sv', 'rtl/ds/nds_lcache.sv', 'rtl/ds/nds_ram.sv',
        'rtl/gpu2d/gpu2d_ram.sv', 'rtl/gpu3d/gpu3d_ram.sv', 'sim/phase1/sim_prims.sv',
        'sim/arm/mul_share/tb.sv']
for rel in rels:
    b = (R/rel).read_bytes()
    if rel.endswith('/arm7_ds.sv') and a.variant == 'sign-mutant':
        old = b"ma = $signed({signed_long && opa[31], opa});"
        assert b.count(old) == 1
        b = b.replace(old, b"ma = $signed({1'b0, opa});")
    if rel.endswith('/tb.sv') and a.variant == 'sign-mutant':
        # Let the wrong product reach a physical RF write. The first fault
        # run's stronger internal comparison also caught it; this control
        # must be rejected by architectural RF, not just prod_q/opd.
        b = b'\n'.join(line for line in b.split(b'\n') if b'META_BEHAVIOR_STATE' not in line)
    p = S/Path(rel).name; p.write_bytes(b); files.append(p)
b = subprocess.check_output(['git', 'show', q['base']+':rtl/arm/arm7_ds.sv'], cwd=R)
p = S/'arm7_ds_before.sv'; p.write_bytes(b.replace(b'module arm7_ds import', b'module arm7_ds_before import')); files.append(p)
q['sources'] = {p.name: sha(p.read_bytes()) for p in files}; save()
assert call([a.verilator, '--binary', '--timing', '--assert', '--threads', '1', '-j', '1', '-O2',
             '-Wno-fatal', '--top-module', 'tb', '--Mdir', D/'obj', *files], 'build') == 0, (D/'build.log').read_text()[-3000:]
model = D/'obj/Vtb'; q['model_SHA256'] = sha(model.read_bytes()); save()

asm = ['.syntax unified', '.arm', '.text', '.global _start,body_begin,body_end,finished,irq_handler', '_start:']
asm += [f'mov r{i},#0' for i in range(13)]
asm += ['ldr sp,stack', 'mrs r0,cpsr', 'bic r0,r0,#0x80', 'msr cpsr_c,r0',
        'ldr r4,ptr', 'mov r0,#0', 'body_begin:', 'swp r0,r1,[r4]', 'body_end:']
internal = {}; forbidden = []; lists = {}
for i, value in enumerate([0x7f, 0x7fff, 0x7fffff, 0x7fffffff]):
    asm += [f'ldr r2,rs{i}', 'mov r1,#3', f'mul_{i}:', 'mul r3,r1,r2', f'mla_{i}:', 'mla r3,r1,r2,r0']
    internal[f'mul_{i}'] = i+1; internal[f'mla_{i}'] = i+2
asm += ['mov r2,#3', 'mov r1,#1', 'shift_0:', 'mov r3,r2,lsl r1', 'cmp r1,#1',
        'never_shift:', 'movne r3,r2,lsl r1', 'never_mul:', 'mulne r3,r1,r2',
        'never_store:', 'strne r3,[r4]', 'mov r10,#2', 'same_pc:', 'mul r3,r1,r2',
        'subs r10,r10,#1', 'bne same_pc']
internal['shift_0'] = 1; internal['same_pc'] = 1
forbidden += ['never_shift', 'never_mul', 'never_store']
asm += ['mov r0,#0x55', 'str r0,[r4]', 'ldr r3,[r4]', 'strb r0,[r4,#1]',
        'ldrb r3,[r4,#1]', 'strh r0,[r4,#2]', 'ldrh r3,[r4,#2]', 'ldrsh r3,[r4,#3]',
        'ldrsb r3,[r4,#1]', 'ldr r3,[r4,#1]']
for form, pu in [('ia', 1), ('ib', 3), ('da', 0), ('db', 2)]:
    for op in ['stm', 'ldm']:
        name = op+'_'+form
        asm += ['ldr r4,ptr', name+':', f'{op}{form} r4!,{{r0-r3}}']
        lists[name] = dict(mask=15, form=pu, bank=0x13, wb=1, user=0)
asm += ['ldr r4,ptr', 'stm_user:', 'stmia r4,{r0,r1}^', 'ldm_user:', 'ldmia r4,{r0,r1}^',
        'stm_base:', 'stmia r4!,{r4,r5}', 'ldr r4,ptr', 'stm_empty:', '.word 0xe8a40000',
        'ldr r4,ptr', 'ldr r5,pc_target', 'str r5,[r4]', 'ldm_pc:', 'ldmia r4!,{pc}',
        'pc_after:', 'ldr r4,ptr']
lists.update(stm_user=dict(mask=3,form=1,bank=0x10,wb=0,user=1),
             ldm_user=dict(mask=3,form=1,bank=0x10,wb=0,user=1),
             stm_base=dict(mask=48,form=1,bank=0x13,wb=1,user=0),
             stm_empty=dict(mask=0,form=1,bank=0x13,wb=1,user=0),
             ldm_pc=dict(mask=32768,form=1,bank=0x13,wb=1,user=0))
for n in range(4): asm += [f'add r5,r4,#{n}', f'swpb r3,r0,[r5]']
asm += ['swp r0,r0,[r4]', 'swp r4,r0,[r4]', 'ldr r4,ptr',
        'ldr r6,mainptr', 'swp r3,r0,[r6]', 'str pc,[r4,#4]',
        'adr r7,thumb_entry+1', 'bx r7', '.thumb', '.balign 2', 'thumb_entry:',
        'movs r0,#3', 'str r0,[r4,#0]', 'ldr r1,[r4,#0]', 'stmia r4!,{r0,r1}',
        'ldmia r4!,{r0,r1}', 'ldr r7,arm_return_ptr', 'bx r7', '.balign 4',
        'arm_return_ptr:', '.word arm_return', '.arm', 'arm_return:',
        'finished:', 'mov r8,#0x66', 'b finished', '.balign 4',
        'ptr:.word 0x037ff040', 'mainptr:.word 0x02010000', 'stack:.word 0x0380f000',
        'pc_target:.word pc_after', *[f'rs{i}:.word {v}' for i,v in enumerate([0x7f,0x7fff,0x7fffff,0x7fffffff])],
        'irq_handler:', 'add r12,r12,#1', 'subs pc,lr,#4']
full_products={}
asm[asm.index('arm_return:')+1:asm.index('arm_return:')+1]=['b matrix_start','matrix_return:']
asm+=['matrix_start:']
pairs=[(0,0),(1,1),(0xffffffff,0xffffffff),(0x80000000,0xffffffff),(0x80000000,2),(0x7fffffff,0xffffffff),(0x87654321,0x12345678),(0x10000,0x10000),(0xffffffff,0x12345678),(0x7fffffff,0x80000000),(0x80000000,0x80000000),(0x55555555,0xaaaaaaaa)]
for vector,(va,vb,addend) in enumerate((va,vb,c)for va,vb in pairs for c in [0,0xffffffffffffffff,0xffffffff,0x8000000000000000]):
    head='v'+str(vector)
    asm += ['ldr r1,'+head+'_a','ldr r2,'+head+'_b']
    for op in ['umull','smull','umlal','smlal']:
        label=head+'_'+op
        asm += ['ldr r6,'+head+'_lo','ldr r7,'+head+'_hi',label+':',op+'s r6,r7,r1,r2']
        aa=va-(1<<32)if op.startswith('s')and va&(1<<31)else va
        bb=vb-(1<<32)if op.startswith('s')and vb&(1<<31)else vb
        full_products[label]=(aa*bb+(addend if op.endswith('lal')else 0))&((1<<64)-1)
    asm += ['b '+head+'_next','.balign 4',head+'_a:.word '+str(va),head+'_b:.word '+str(vb),head+'_lo:.word '+str(addend&0xffffffff),head+'_hi:.word '+str(addend>>32),head+'_next:']
asm+=['b matrix_return']
(D/'program.s').write_text('\n'.join(asm)+'\n')
for cmd, tag in [([shutil.which('clang'), '--target=armv4t-none-eabi', '-mcpu=arm7tdmi', '-marm', '-nostdlib', '-c', D/'program.s', '-o', D/'program.o'], 'assemble'),
                 ([shutil.which('ld.lld'), '-Ttext=0x03808000', '--entry=_start', D/'program.o', '-o', D/'program.elf'], 'link'),
                 ([shutil.which('llvm-objcopy'), '-O', 'binary', D/'program.elf', D/'program.bin'], 'binary')]:
    assert call(cmd, tag) == 0, (D/(tag+'.log')).read_text()
names = {w[2]: int(w[0], 16) for line in subprocess.check_output([shutil.which('llvm-nm'), '-n', D/'program.elf'], text=True).splitlines() if len(w:=line.split()) == 3}
b = (D/'program.bin').read_bytes(); (D/'program.hex').write_text(''.join(f'{int.from_bytes(b[i:i+4],"little"):08x}\n' for i in range(0,len(b),4)))
q['program_SHA256'] = sha(b); q['symbols'] = names; q['full_products']=full_products; save()
cases=[('normal',0),('retry',1),('irq',2),('reset-read',3),('reset-write',4),('pause',5)]
for tag, scenario in cases:
    C = D/tag; C.mkdir()
    rc=call([model, '+img='+str(D/'program.hex'), '+out='+str(C/'trace'), '+scenario='+str(scenario),
                 *['+'+k+'='+hex(names[n])[2:] for k,n in [('begin','body_begin'),('end','body_end'),('done','finished'),('handler','irq_handler')]]], tag)
    if a.variant=='sign-mutant':
        log=(D/(tag+'.log')).read_text()
        assert rc!=0 and 'META_BEHAVIOR_RF' in log,log[-2000:]
        q['caught']='actual sign extension loss changes architectural RF'
        q['status']='PASS actual RTL fault caught';save();print(q['caught'],flush=True);break
    assert rc==0,(D/(tag+'.log')).read_text()[-3000:]
    assert 'META_ALL_PASS' in (D/(tag+'.log')).read_text()
    for old, off, on in [(0,1,2),(3,4,5)]:
        for ext in ['state','data','take','edge','mem']:
            assert (C/f'trace-m{old}.{ext}').read_bytes() == (C/f'trace-m{off}.{ext}').read_bytes() == (C/f'trace-m{on}.{ext}').read_bytes(), (tag, old, ext)
    observations = {}
    for lane in [0,1,2,3,4,5]:
        states=[line.split(',') for line in (C/f'trace-m{lane}.state').read_text().split('RESET\n')[-1].splitlines()]
        for name,value in full_products.items():
            matching=[r for r in states if int(r[0],16)==names[name]]
            assert len(matching)==1,('full product missing',name)
            r=matching[0];actual=int(r[8],16)|(int(r[9],16)<<32)
            assert actual==value,('full64 product arithmetic',name,hex(actual),hex(value))
            psr=int(r[1],16);assert ((psr>>31)&1)==(value>>63)and((psr>>30)&1)==int(value==0),('long N/Z flags',name)

    for lane in [2,5]:
        rows = [line.split(',') for line in (C/f'trace-m{lane}.meta').read_text().split('RESET\n')[-1].splitlines()]
        igroups = {}; dgroups = {}; epochs = []
        for r in rows:
            if r[0] == 'R':
                assert int(r[3]) == int(r[2])+1; epochs.append(int(r[2])); continue
            pc = int(r[4],16); owner = (int(r[2]),int(r[3]),pc)
            assert pc not in [names[n] for n in forbidden], ('condition failed metadata', r)
            if r[0] == 'I': igroups.setdefault(owner,[]).append(r)
            else: dgroups.setdefault(owner,[]).append(r)
        for name, count in internal.items():
            groups = [g for (_,_,pc),g in igroups.items() if pc == names[name]]
            assert len(groups) == (2 if name=='same_pc' else 1), (tag,lane,name,groups)
            if name=='same_pc': assert len({g[0][3] for g in groups})==2, 'dynamic ordinal repeated'
            for group in groups:
                assert [int(r[9]) for r in group] == list(range(count)) and all(int(r[10]) == count for r in group), ('internal step count/order',name,group)
                assert all((r[7],r[8]) == (('1','0') if name=='shift_0' else ('0','1')) for r in group)
        list_beats = 0; swp_beats = 0; thumb_beats = 0
        for (_,_,pc), group in dgroups.items():
            for r in group:
                assert int(r[5]) in [0,1]
                thumb_beats += int(r[5])
                if r[15] == '1': swp_beats += 1
            match = next((v for n,v in lists.items() if names[n] == pc),None)
            if match:
                mask=match['mask']; effective=mask or 32768; regs=[i for i in range(16) if effective&(1<<i)]; n=len(regs)
                assert len(group)==n, ('list beat count',pc,len(group),n)
                for i,r in enumerate(group):
                    assert r[14]=='1' and int(r[21],16)==mask and int(r[22],16)==effective, ('list mask',r)
                    assert [int(r[k]) for k in [16,17,18,19,20]] == [int(i==0),int(i==n-1),i,n,mask.bit_count() if mask else 16], ('list first/last/count metadata',r)
                    assert [int(r[23],16),int(r[24]),int(r[25],16),int(r[28])] == [match['form'],match['user'],match['bank'],match['wb']], ('list form/bank',r)
                    assert int(r[26])==int(bool(effective&32768)) and int(r[27])==int(regs[i]==15) and int(r[30],16)==regs[i], ('list PC/register',r)
                    list_beats += 1
            elif group[0][15]=='1':
                assert len(group)==2 and [(r[7],r[16],r[17],r[18],r[19]) for r in group]==[('0','1','0','0','2'),('1','0','1','1','2')], ('SWP owned pair',group)
        assert list_beats==40 and swp_beats>=16 and thumb_beats>=6, (list_beats,swp_beats,thumb_beats)
        actual_data=[line.split(',') for line in (C/f'trace-m{lane}.data').read_text().split('RESET\n')[-1].splitlines()]
        metadata_data=[r for r in rows if r[0]=='D']
        assert len(actual_data)==len(metadata_data), 'accepted DATA cardinality'
        for observed, recorded in zip(actual_data,metadata_data):
            expected=[int(recorded[k],16) for k in [10,7,13,11 if recorded[7]=='1' else 12]]
            assert list(map(lambda x:int(x,16),observed))==expected, ('request/accepted DATA descriptor or payload',observed,recorded)
        observations[lane]=dict(internal_groups=len(igroups),internal_steps=sum(map(len,igroups.values())),data_beats=sum(map(len,dgroups.values())),list_beats=list_beats,swp_beats=swp_beats,thumb_beats=thumb_beats,redirects=len(epochs))
    q['cases'][tag]=dict(status='PASS exact before/off/on CPU state/cycles/outputs/P7 takes/backing',observations=observations);save()
q['status']='PASS';save();print(json.dumps(q['cases'],indent=2),flush=True)
