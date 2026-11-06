#!/usr/bin/env python3
"""Sequential Desktop1 gates; freeze old production and every actual mutant."""
from pathlib import Path
import datetime, hashlib, json, os, re, resource, shutil, struct, subprocess, sys, tarfile, time

ROOT = Path(__file__).resolve().parents[3]
BASE = '96f2bcd6'
OUT = ROOT / 'build/a7-main-store-turn'
V = 'build/tools/oss-cad-suite/bin/verilator'
os.chdir(ROOT)
os.setpriority(os.PRIO_PROCESS, 0, 10)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
OUT.mkdir(exist_ok=True)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()


def status(phase, pid=None):
    def start(p):
        try:
            return int(Path(f'/proc/{p}/stat').read_text().rsplit(')', 1)[1].split()[19])
        except FileNotFoundError:
            return None
    worker = dict(host='Desktop', controller=os.getpid(), PID=pid,
                  starttime=dict(controller=start(os.getpid()), PID=start(pid) if pid else None),
                  NI=10, jobs=1, threads=1)
    (OUT / 'worker.json').write_text(json.dumps(dict(phase=phase, **worker), indent=2)+'\n')
    p = Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json')
    d = json.loads(p.read_text())
    d.update(phase=phase, worker=worker, updated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
             lease='Desktop1 NI10/j1/t1 active; one owned worker', evidence=str(OUT),
             next_action='Complete bounded MAIN_STORE_TURN ACK/state/order/fault gates; no private Thumb redo')
    s = json.dumps(d, indent=2)+'\n'
    assert len(s.encode()) <= 2048
    q = p.with_name('CPU.json.tmp-'+str(os.getpid())); q.write_text(s); q.replace(p)


def call(cmd, directory, label, fault=None):
    cmd = list(map(str, cmd)); log = directory / (label+'.log')
    with log.open('w') as f:
        p = subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT)
        with (OUT / 'processes.jsonl').open('a') as g:
            g.write(json.dumps(dict(controller=os.getpid(), PID=p.pid, argv=cmd, log=str(log),
                                    starttime=Path(f'/proc/{p.pid}/stat').read_text().rsplit(')',1)[1].split()[19],
                                    NI=os.getpriority(os.PRIO_PROCESS,p.pid), time=time.time()))+'\n')
        status(directory.name+'/'+label, p.pid)
        print(label, directory.name, 'PID', p.pid, flush=True)
        rc = p.wait()
    data = log.read_text()
    if fault:
        assert rc != 0 and fault in data and 'timeout' not in data.lower(), (directory.name, data[-2000:])
    else:
        assert rc == 0, (directory.name, data[-2400:])
    return data


def prune(obj):
    for p in obj.iterdir():
        if p.is_file() and (p.suffix in ['.o','.a','.d','.gch'] or
                           (p.name.startswith('Vtb') and p.suffix in ['.cpp','.h','.mk','.dat'])):
            p.unlink()


def leaf():
    libs = ['rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu2d/gpu2d_ram.sv',
            'rtl/gpu3d/gpu3d_ram.sv','sim/phase1/sim_prims.sv']
    new = (ROOT/'rtl/ds/nds_arm7_port.sv').read_text()
    old = subprocess.check_output(['git','show',BASE+':rtl/ds/nds_arm7_port.sv'],text=True)
    variants = [
        ('before', old, ['+define+BEFORE'], None),
        ('default', new, ['+define+TURN=0'], None),
        ('enabled', new, ['+define+TURN=1'], None),
        ('fault-premature', new.replace('&& busy && busy_w && f_ack;', '&& busy && busy_w;'),
         ['+define+TURN=1'], 'premature store turnover without ACK'),
        ('fault-payload', new.replace('wb_d <= d_wdata;', "wb_d <= d_wdata ^ 32'd1;"),
         ['+define+TURN=1'], 'ordered physical write mismatch'),
        ('fault-duplicate', new.replace("d_addr[31:2] == wb_a[31:2] + 30'd1", "1'b1"),
         ['+define+TURN=1'], 'duplicate held store accepted on ACK'),
        ('fault-coherence', new.replace('(!wb_v || main_store_turn) && d_addr[31:24]', '!wb_v && d_addr[31:24]'),
         ['+define+TURN=1'], 'stale fetched code after accepted turnover'),
    ]
    result = {}
    for name, source, defines, fault in variants:
        if fault: assert source != new, name
        d = OUT/name; d.mkdir(exist_ok=True)
        (d/'nds_arm7_port.sv').write_text(source)
        for rel in libs: shutil.copyfile(ROOT/rel,d/Path(rel).name)
        shutil.copyfile(ROOT/'sim/arm/a7_main_store_turn/tb_leaf.sv',d/'tb_leaf.sv')
        files = sorted(d.glob('*.sv'))
        (d/'inputs.json').write_text(json.dumps({p.name:sha(p) for p in files},indent=2)+'\n')
        model = d/'obj/Vtb_leaf'
        call([V,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal',
              '--top-module','tb_leaf','--Mdir',model.parent,*defines,*files],d,'build')
        prune(model.parent)
        text = call([model],d,'run',fault)
        if not fault: assert 'STORE_LEAF_PASS' in text
        result[name] = dict(model_sha256=sha(model), verdict=fault or 'PASS', log_sha256=sha(d/'run.log'))
        print('DONE',name,result[name]['verdict'],flush=True)
    (OUT/'leaf.json').write_text(json.dumps(result,indent=2)+'\n')
    check_leaf()


def check_leaf():
    # Verilator's finish filename, elapsed wall time and speed are metadata.
    # Keep raw logs; compare every observed edge, value and fixture timestamp.
    observable = lambda name: [s for s in (OUT/name/'run.log').read_text().splitlines()
                               if s.startswith(('EDGE ','WRITE_TIME ','STORE_LEAF_PASS '))]
    assert observable('before') == observable('default')
    expected = {'before':None, 'default':None, 'enabled':None,
                'fault-premature':'premature store turnover without ACK',
                'fault-payload':'ordered physical write mismatch',
                'fault-duplicate':'duplicate held store accepted on ACK',
                'fault-coherence':'stale fetched code after accepted turnover'}
    result = {}
    for n, fault in expected.items():
        d=OUT/n; text=(d/'run.log').read_text()
        assert fault in text if fault else 'STORE_LEAF_PASS' in text
        result[n]=dict(model_sha256=sha(d/'obj/Vtb_leaf'),log_sha256=sha(d/'run.log'),verdict=fault or 'PASS')
    (OUT/'leaf.json').write_text(json.dumps(result,indent=2)+'\n')
    print('LEAF_CHECK_PASS old/default all edges exact; pending-read/ACK/width/reset/SMC; four real faults',flush=True)


def coupled():
    d=OUT/'coupled';d.mkdir(exist_ok=True)
    packet=ROOT/'docs/results/arm7-data-ack-20261101/proof.tar.gz'
    assert sha(packet)=='0707d7ca3a716f90dbe0eea6ad968398cd806c22289c77c46a9cd7e794027734'
    with tarfile.open(packet)as t:
        source=t.extractfile('cpu36/tb.sv').read().decode().split('module cpu_before ')[0]
    source=source.replace('module physical_before ', 'module physical_transport ')
    source=source.replace('input logic a7_req,a7_we,a7_n4,a7_ifseq,', 'input logic[3:0]a7_be,input logic a7_req,a7_we,a7_n4,a7_ifseq,')
    source=source.replace(".a7_be(4'hf)", '.a7_be(a7_be)').replace('old_nds_psram #','nds_psram #')
    (d/'physical.sv').write_text(source)
    rels=['rtl/arm/arm_pkg.sv','rtl/arm/arm_thumb.sv','rtl/arm/arm7_ds.sv','rtl/ds/nds_arm7_port.sv',
          'rtl/ds/nds_fabric.sv','rtl/ds/nds_mr_arb.sv','rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv',
          'rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/mem/psx_pq_psram.sv',
          'rtl/pocket/nds_psram.sv','sim/phase1/cram_model.sv','sim/phase1/sim_prims.sv']
    for rel in rels:shutil.copyfile(ROOT/rel,d/Path(rel).name)
    for rel in rels:
        if rel!='rtl/ds/nds_arm7_port.sv':
            assert (d/Path(rel).name).read_bytes()==subprocess.check_output(['git','show',BASE+':'+rel]),rel
    old=subprocess.check_output(['git','show',BASE+':rtl/ds/nds_arm7_port.sv'])
    (d/'old_nds_arm7_port.sv').write_bytes(old.replace(b'module nds_arm7_port #',b'module old_nds_arm7_port #',1))
    shutil.copyfile(ROOT/'sim/arm/a7_main_store_turn/tb_cpu.sv',d/'tb_cpu.sv')
    shutil.copyfile(ROOT/'sim/arm/a7_main_store_turn/main.s',d/'main.s')
    (d/'main.ld').write_text('ENTRY(_start)\nSECTIONS { . = 0x03808000; .text : { *(.text*) } }\n')
    call(['clang','--target=arm-none-eabi','-mcpu=arm7tdmi','-nostdlib','-fuse-ld=lld',
          '-Wl,-T,'+str(d/'main.ld'),d/'main.s','-o',d/'main.elf'],d,'assemble')
    call(['llvm-objcopy','-O','binary',d/'main.elf',d/'main.bin'],d,'objcopy')
    symbols={name:int(a,16)for a,kind,name in (s.split()for s in subprocess.check_output(['llvm-nm',d/'main.elf'],text=True).splitlines()if len(s.split())==3)}
    (d/'symbols.json').write_text(json.dumps(symbols,indent=2)+'\n')
    files=[d/'arm_pkg.sv']+[p for p in sorted(d.glob('*.sv'))if p.name!='arm_pkg.sv']
    (d/'inputs.json').write_text(json.dumps({p.name:sha(p)for p in files},indent=2)+'\n')
    model=d/'obj/Vtb_cpu'
    call([V,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal',
          '--top-module','tb_cpu','--Mdir',model.parent,*files],d,'build')
    prune(model.parent)
    rows=[]
    for loops,irq in [(4,0),(16,0),(4,1)]:
        data=bytearray((d/'main.bin').read_bytes());offset=symbols['loop_count']-0x03808000
        assert struct.unpack_from('<I',data,offset)[0]==0xe3a0a004
        struct.pack_into('<I',data,offset,0xe3a0a000|loops)
        image=d/f'n{loops}.hex';image.write_text(''.join(f'{v:08x}\n'for v in struct.unpack('<4096I',data+bytes(16384-len(data)))))
        prefix=d/f'n{loops}-irq{irq}'
        text=call([model,f'+img={image}',f'+loops={loops}',f'+irq={irq}',f'+out={prefix}',
                   f'+done={symbols["finished"]:x}',f'+fail={symbols["failed"]:x}',f'+handler={symbols["irq_handler"]:x}'],d,prefix.name)
        assert 'CPU_STORE_ALL_PASS'in text
        counts={int(m[0]):dict(zip(['cycles','states','data','writes'],map(int,m[1:])))for m in re.findall(r'CPU_STORE_PASS mode(\d+) cycles(\d+) states(\d+) data(\d+) writes(\d+)',text)}
        assert len(counts)==3
        for suffix in ['state','data','mem']:
            before=Path(str(prefix)+'-m0.'+suffix).read_bytes()
            for mode in [1,2]:assert before==Path(str(prefix)+f'-m{mode}.'+suffix).read_bytes(),(prefix.name,mode,suffix)
        assert counts[0]==counts[1]
        assert Path(str(prefix)+'-m0.edge').read_bytes()==Path(str(prefix)+'-m1.edge').read_bytes()
        rows.append(dict(loops=loops,irq=irq,counts=counts));print('COUPLED_PASS',rows[-1],flush=True)
    (OUT/'coupled.json').write_text(json.dumps(dict(rows=rows,model_sha256=sha(model)),indent=2)+'\n')


if __name__ == '__main__':
    status('Starting MAIN_STORE_TURN '+sys.argv[1])
    if sys.argv[1] == 'leaf': leaf()
    elif sys.argv[1] == 'check-leaf': check_leaf()
    elif sys.argv[1] == 'coupled': coupled()
    else: raise SystemExit('unknown gate')
    status('Terminal PASS '+sys.argv[1])
