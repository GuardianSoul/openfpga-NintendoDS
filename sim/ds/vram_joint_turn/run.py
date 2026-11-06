#!/usr/bin/env python3
"""One gated current-source read-side/write-turn component qualification."""
from pathlib import Path
import argparse
import ast
import hashlib
import json
import os
import re
import resource
import subprocess
import sys
import time

R = Path(__file__).resolve().parents[3]
BASE = 'c445c240e4138f347ea256d98f9f20e3eca68e50'
TRANSPORT = '91e199821ba08799b8b1f6eb398ed62d3830aaef2e8463412ac6723d4b9e6df2'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--allocated', required=True, action='store_true')
p.add_argument('--await-release', action='store_true')
p.add_argument('--out', required=True, type=Path)
a = p.parse_args()
G = a.out.resolve()
G.mkdir(parents=True, exist_ok=False)
os.chdir(R)
os.setpriority(os.PRIO_PROCESS, 0, 10)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
sys.dont_write_bytecode = True
sys.path.insert(0, str(R / 'sim/arm/ncnb_store'))
from worker_guard import guard, wait_owned
sha = lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest()

def save(name, value):
    path = G / name
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)

assert sha(R / 'sim/arm/ncnb_store/sim_ownership.py') == '64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003'
save('controller.json', dict(pid=os.getpid(), starttime=Path('/proc/self/stat').read_text().split()[21], NI=10))
print('GATED', json.loads((G / 'controller.json').read_text()), flush=True)
while a.await_release and not (G / 'release').exists():
    time.sleep(.2)
(G / 'tmp').mkdir()
os.environ['TMPDIR'] = str(G / 'tmp')
assert sha(R / 'rtl/pocket/nds_sdram_bus.sv') == TRANSPORT
prior = json.loads((R / 'docs/results/dma-cut-turn-20261101/qualification.json').read_text())
assert prior['production']['rtl/pocket/nds_sdram_bus.sv'] == TRANSPORT
assert prior['triples'] == 27
assert sha(R / 'docs/results/dma-cut-turn-20261101/evidence.tar.gz') == prior['artifact']['sha256']
save('prior-proof.json', prior)
FILES = ['rtl/arm/arm_pkg.sv','rtl/gpu2d/gpu2d_pkg.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv',
 'rtl/ds/nds_ram.sv','rtl/sys/sys_ram.sv','rtl/ds/nds_lcache.sv','rtl/arm/arm_thumb.sv','rtl/arm/arm_mul.sv','rtl/arm/arm7_ds.sv',
 'rtl/ds/nds_arm7_port.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_vram.sv','rtl/pocket/nds_x2b.sv','rtl/pocket/nds_cdc.sv',
 'rtl/pocket/nds_sdram_bus.sv','rtl/pocket/nds_sdram_mc.sv','rtl/pocket/nds_psram.sv','rtl/mem/psx_pq_psram.sv',
 'rtl/ds/nds_io.sv','rtl/sys/nds_sys.sv','rtl/sys/sys_timers.sv','rtl/sys/sys_math.sv','rtl/sys/sys_irq.sv','rtl/sys/sys_ipc.sv','rtl/sys/sys_dma.sv','rtl/ds/nds_dsp_add.sv',
 'sim/phase1/sim_prims.sv','sim/phase1/sdram_chip_model.sv','sim/ds/a7_vram_read/cram_model.sv','sim/ds/a7_vram_read/pin_memory.sv']

def call(argv, tag, expect_failure=False):
    guard()
    argv = list(map(str, argv))
    with (G / (tag + '.log')).open('w') as f:
        child = subprocess.Popen(argv, stdout=f, stderr=subprocess.STDOUT)
        record = dict(pid=child.pid, starttime=Path('/proc', str(child.pid), 'stat').read_text().split()[21],
                      NI=os.getpriority(os.PRIO_PROCESS, child.pid), argv=argv, log=str(G / (tag + '.log')))
        with (G / 'processes.jsonl').open('a') as output:
            output.write(json.dumps(record) + '\n')
        save('active.json', record)
        print('STAGE', tag, child.pid, record['starttime'], flush=True)
        rc = wait_owned(child)
    record.update(exit=rc, reaped=True)
    save(tag + '.process.json', record)
    assert (rc != 0) if expect_failure else (rc == 0), (tag, rc, (G / (tag + '.log')).read_text()[-2500:])
    return (G / (tag + '.log')).read_text()

models = {}

def model(role):
    if role in models:
        return models[role]
    D = G / role
    D.mkdir()
    inputs = {}
    for name in FILES:
        b = subprocess.check_output(['git', 'show', BASE + ':' + name])
        assert b == (R / name).read_bytes(), name
        if role == 'payload-mutant' and name == 'rtl/pocket/nds_sdram_bus.sv':
            needle = b'b_we <= s_we; b_quad <= s_quad; b_addr <= s_addr; b_wdata <= s_wdata; b_be <= s_be;'
            assert b.count(needle) == 1
            b = b.replace(needle, b"b_we <= s_we; b_quad <= s_quad; b_addr <= s_addr; b_wdata <= cut_turn ? (s_wdata ^ 32'd1) : s_wdata; b_be <= s_be;")
        target = D / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b)
        inputs[str(target)] = sha(target)
    for name in ['tb.sv', 'io_service.svh']:
        target = D / name
        target.write_bytes((R / 'sim/ds/vram_joint_turn' / name).read_bytes())
        inputs[str(target)] = sha(target)
    command = ['build/tools/oss-cad-suite/bin/verilator', '--binary', '--timing', '--assert',
        '--threads', '1', '-j', '1', '-O1', '-Wno-fatal', '--timescale', '1ns/1ps', '--top-module', 'tb_side',
        '+define+NEW_READ_SIDE', '+define+NEW_VRAM_ACK', '+define+NEW_VRAM_IO_SIDE', '-GIO_SIDE=1', '-GIO_EARLY=1',
        '-I' + str(D), '--Mdir', D / 'obj']
    if role != 'before':
        command += ['+define+EXPLICIT_WRITE_TURN', '-GTURN=' + str(int(role != 'off'))]
    command += [D / n for n in FILES] + [D / 'tb.sv']
    call(command, role + '-build')
    binary = D / 'obj/Vtb_side'
    save(role + '/model.json', dict(source=BASE, binary_sha256=sha(binary), inputs=inputs,
        read_side=1, IO_read_side=1, VRAM_owned_ACK=1, turn='omitted/default0' if role == 'before' else int(role != 'off')))
    models[role] = binary
    return binary

images = {}

def image(case):
    kind = case.get('kind', 'data')
    loops = case.get('loops', 4)
    pattern = case.get('pattern', 0)
    key = f'{kind}-{loops}-{pattern}'
    if key in images:
        return images[key]
    src = R / ('sim/ds/a7_vram_return/program_fetch.s' if kind == 'fetch' else 'sim/ds/vram_joint_turn/program.S')
    stem = G / key
    stem.with_suffix('.S').write_bytes(src.read_bytes())
    options = ['-DLOOPS=4'] if kind == 'fetch' else ['-DLOOPS=4', f'-DSTORE_LOOPS={loops}']
    if pattern:
        options += ['-DSTORE_PATTERN=1']
    call(['clang', '--target=arm-none-eabi', '-march=armv4t', '-fuse-ld=lld', '-nostdlib', '-x', 'assembler-with-cpp',
          *options, '-Wl,-Ttext=0x03808000', '-Wl,--entry=_start', stem.with_suffix('.S'), '-o', stem.with_suffix('.elf')], key + '-asm')
    call(['llvm-objcopy', '-O', 'binary', stem.with_suffix('.elf'), stem.with_suffix('.bin')], key + '-binary')
    b = stem.with_suffix('.bin').read_bytes()
    b += bytes(-len(b) % 4)
    stem.with_suffix('.hex').write_text(''.join(f'{int.from_bytes(b[i:i+4], "little"):08x}\n' for i in range(0, len(b), 4)))
    symbols = {l.split()[-1]: l.split()[0] for l in subprocess.check_output(['llvm-nm', stem.with_suffix('.elf')], text=True).splitlines() if len(l.split()) == 3}
    images[key] = stem.with_suffix('.hex'), symbols
    return images[key]

def run(role, case, index):
    binary = model(role)
    guest, symbols = image(case)
    tag = f'{index:02d}-{role}'
    opts = dict(pressure=0, main=0, owner=3, phase=0, io=1, storeio=1, irq=0, target=0,
                store_extra=0 if case.get('kind') == 'fetch' else 64 * case.get('loops', 4),
                store_pattern=case.get('pattern', 0), store_pressure=0, stress_phase=1)
    opts.update({k: v for k, v in case.items() if k not in ['kind', 'loops', 'pattern']})
    command = [binary, '+img=' + str(guest), '+out=' + str(G / tag), '+begin=' + symbols['body_begin'],
               '+done=' + symbols['done'], '+fail=' + symbols['fail'], '+handler=' + symbols.get('irq_handler', symbols['fail']),
               '+first=' + symbols.get('repeat_begin', symbols['body_begin']), '+storebegin=' + symbols.get('store_begin', symbols['fail'])]
    command += [f'+{k}={v}' for k, v in opts.items()]
    log = call(command, tag, role == 'payload-mutant')
    if role == 'payload-mutant':
        assert 'physical CPU descriptor data/order changed' in log or 'ARM7 program self-check failed' in log, log[-2000:]
        return dict(caught=True, log_sha256=sha(G / (tag + '.log')))
    assert ('PASS_RESET' if case.get('resetmode') else 'PASS_SIDE') in log
    assert 'PIN_MEMORY errors0/0/0' in log
    m = re.search(r'JOINT_TURN pending(\d+) performed(\d+) captured(\d+) physical(\d+) remaining(\d+)', log)
    assert m
    counts = list(map(int, m.groups()))
    assert counts[2] == counts[3] and counts[4] == 0, (tag, counts)
    if role != 'on':
        assert counts[1] == 0
    return dict(out=str(G / tag), turn=counts, log_sha256=sha(G / (tag + '.log')))

cases = [dict(), dict(loops=16),
    *[dict(pressure=1, store_pressure=1, stress_phase=k) for k in [1, 64, 196]],
    dict(pressure=1, main=1, owner=3, store_pressure=1, stress_phase=64),
    dict(pressure=1, irq=1, store_pressure=1, stress_phase=64),
    dict(pressure=1, target=1, store_pressure=1, stress_phase=64),
    dict(pressure=1, pattern=1, store_pressure=1, stress_phase=64),
    dict(kind='fetch', fetchio=1, storeio=0), dict(resetmode=3), dict(resetmode=5)]
results = {}
for index, case in enumerate(cases):
    got = {role: run(role, case, index) for role in ['before', 'off', 'on']}
    for ext in ['state', 'data', 'edge', 'mon', 'physical', 'stage', 'ret', 'memstage', 'io', 'causal', 'turn']:
        assert Path(got['before']['out']).with_suffix('.' + ext).read_bytes() == Path(got['off']['out']).with_suffix('.' + ext).read_bytes(), ('default cycles', index, ext)
    if not case.get('resetmode'):
        for ext in ['state', 'data']:
            assert Path(got['before']['out']).with_suffix('.' + ext).read_bytes() == Path(got['on']['out']).with_suffix('.' + ext).read_bytes(), ('CPU architecture/data', index, ext)
        for ext, prefixes in [('mon', ['0 ', '1 ', '2 ', '3 ']), ('physical', ['CAP ', 'VRAM ', 'MAIN '])]:
            for prefix in prefixes:
                rows = lambda role: [l for l in Path(got[role]['out']).with_suffix('.' + ext).read_text().splitlines() if l.startswith(prefix)]
                assert rows('before') == rows('on'), ('physical/master order', index, ext, prefix)
        returned = lambda role: re.findall(r'^\d+ ([0-9a-f]+) ([0-9a-f]) ack1 .*data([0-9a-f]+)$', Path(got[role]['out']).with_suffix('.causal').read_text(), re.M)
        assert returned('before') == returned('on'), ('read data/order', index)
    results[str(index)] = dict(case=case, result=got)
    save('results.json', results)
    print('JOINT_CASE', index, {n: x['turn'] for n, x in got.items()}, flush=True)
assert sum(x['result']['on']['turn'][1] for x in results.values()) > 0, 'joint turnover never exercised'
fault = run('payload-mutant', cases[8], 99)
save('fault.json', fault)
save('complete.json', dict(source=BASE, transport=TRANSPORT, triples=len(results), prior27=prior['artifact'], fault=fault))
print('JOINT_COMPLETE', flush=True)
