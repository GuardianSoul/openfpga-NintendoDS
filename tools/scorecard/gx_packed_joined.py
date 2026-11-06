#!/usr/bin/env python3
"""Exact18 run38 replay on the pinned a3 Laptop cache; never builds a model."""
import argparse
import ast
import csv
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time

import gx_packed_native as gate
from compare_gx_packed import ds_rows, protocol_log, summarize

SOURCE = 'a3a29d4be93fcb847bf934e02493e81ecaa0b516'
KEY = 'b875e80a51ceec4d80a2'
MODEL = '257c3920cc84de2a6d710a9b7086fa74a7f54e59d89686ecc2dda7f15d17fc09'
PROFILE = dict(A9_WAYS=4, A9_XD=0, A9_XI=0, A9_OPT=461366243, DMA_RA=2,
               DX_SKID=1, GX_DSX=1, GX_L44_READ=1, G3D_FULL_POOL=1,
               VRAM_WRITE_CUT=3, LDM_HIT_EARLY=1, G3D_FULL_WQ=1, SOUND_EVENT=0)
PINS = {'source-manifest.json': '63e07ef533380c98cd8c14b54025d5dc6470ebaee5daddf959dafc01d4a0ac43',
        'inputs.json': '1b8bf2457bdb1bdb7e62c87c696b44fb7b6a1d8c7dece4aa78a6d50ffb8764a1',
        'host-instrumentation.json': '36520492988f755043b1fcc981f00b3e131d999c4afac300dba58330378a6926'}
BANNERS = ('DS_CACHE_ROUTE_OK: ways4 D4KiB I8KiB opt461366243 RA2 DX1 Shell2 independent ARM7 all7features sound/wifi/3D on',
           'DS_GX_ROUTE_OK: DSX1 CHEAP0 AHEAD1',
           'JOINED_ROUTES_OK: L44READ1 FULLPOOL11/13 A7EARLY1 VRAMCUT3 LDMHIT1 FULLWQ14 EVENT0')
ASSERTIONS = ('u_mem9.WAYS != 4', 'u_mem9.DSB != 5', 'u_mem9.ISB != 6',
              'dut.A9_OPT != 461366243', 'dut.DX_SKID != 1', 'dut.DMA_RA != 2',
              'dut.SOUND != 1', 'dut.WIFI != 1', 'dut.GPU3D != 1',
              'dut.SHELL_CPU != 2', 'dut.A9_SOLO != 5', 'dut.CPU_FAST != 0',
              'u_geom.GX_DSX != 1', 'u_front.DSX != 1', 'u_front.CHEAP != 0', 'u_eng.AHEAD != 1',
              'dut.GX_L44_READ != 1', 'dut.G3D_FULL_POOL != 1', 'dut.VRAM_WRITE_CUT != 3',
              'u_geom.GX_L44_READ != 1', 'u_front.READ_LOAD44 != 1', 'u_eng.READ_LOAD44 != 1',
              'u_store.SL != 11', 'u_store.CL != 13', 'u_p7.MAIN_IF_EARLY != 1',
              'u_fab.VRAM_WRITE_CUT != 3', 'dut.LDM_HIT_EARLY != 1', 'u_fab.LDM_HIT_EARLY != 1',
              'dut.G3D_FULL_WQ != 1', 'u_store.FULL_WQ != 1', 'u_store.QAW != 14',
              'dut.SOUND_EVENT != 0', 'u_snd.EVENT_MODE != 0', 'dut.x_vram.CUT_TAG != 1', 'dut.sdram.CUT != 1') + tuple(
                  'dut.G3D_' + name + ' != 1' for name in ('AA', 'TOON', 'FOG', 'ATEST', 'EDGE', 'SHADOW', 'LOWER'))


def routes(text):
    for banner in BANNERS:
        gate.require(text.splitlines().count(banner) == 1, 'actual route missing: ' + banner)


def prepare(donor, protocol, roms, capture, marker, out):
    sha, require = gate.sha, gate.require
    for name, digest in PINS.items():
        require(sha(donor / name) == digest, 'donor changed: ' + name)
    record = json.loads((donor / 'source-manifest.json').read_text())
    require(record['sha'] == SOURCE and json.loads((donor / 'inputs.json').read_text())['profile'] == PROFILE,
            'wrong source/thirteen-parameter profile')
    overrides = {r['file']: r for r in json.loads((donor / 'host-instrumentation.json').read_text())['files']}
    source = donor / 'source'
    for name, digest in record['files'].items():
        if name in overrides:
            require(digest == overrides[name]['original_sha256'], 'unrecorded instrumentation')
            digest = overrides[name]['instrumented_sha256']
        require(sha(source / name) == digest, 'source changed: ' + name)
    canonical = source / 'build/cpu-scorecard/tb_canonical.sv'
    text = canonical.read_text()
    require(sha(canonical) == overrides['sim/pocket_ds/tb_ds_pocket.sv']['instrumented_sha256'], 'harness differs')
    require(all(s in text for s in ASSERTIONS + BANNERS), 'compiled actual child-route assertion missing')
    tree = ast.parse((source / 'sim/pocket_ds/run.py').read_text())
    sim = next(ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign)
               and any(isinstance(t, ast.Name) and t.id == 'SIM' for t in n.targets))
    command = ['build/tools/oss-cad-suite/bin/verilator', '--binary', '--timing',
               '-O3', '-j', '8', '-Wno-fatal', '-Wno-WIDTHEXPAND', '-Wno-WIDTHTRUNC', '-Wno-UNUSEDSIGNAL',
               '--timescale', '1ns/1ps', '--top-module', 'tb_ds_pocket', '+define+NODEBUG', '+define+CLEAN_BOOT',
               '+define+TB_CORE_PARAMS=' + ''.join(f', .{k}({v})' for k, v in PROFILE.items()), '-GROM_AW=24',
               '--threads', '1', '-MAKEFLAGS', 'OPT_FAST=-O2', '-CFLAGS', '-march=native', '-I' + str(source / 'rtl/pocket')]
    require(marker.read_text() == ' '.join(command) + '\n', 'cache compile marker differs')
    files = [p for p in (source / 'rtl').rglob('*') if p.is_file() and p.suffix in ('.sv', '.svh', '.v', '.vh', '.mif', '.hex')]
    files += [canonical if p == 'sim/pocket_ds/tb_ds_pocket.sv' else source / p for p in sim]
    cache = hashlib.sha256()
    for arg in command:
        cache.update(arg.replace(str(source / 'rtl'), '<rtl>').encode() + b'\0')
    for p in sorted(set(files)):
        cache.update(p.name.encode() + b'\0' + p.read_bytes())
    require(cache.hexdigest()[:20] == KEY, 'compile inputs do not reproduce pinned LP cache key')
    model = donor / 'model-cache-zero-laptop' / KEY / 'Vtb_ds_pocket'
    qualified = donor / 'results/itcm-control'
    observed = json.loads((qualified / 'model.json').read_text())
    qualification = json.loads((qualified / 'manifest.json').read_text())
    require(observed['sha256'] == MODEL and observed['host'] == 'zero-laptop' and Path(observed['argv'][0]) == model,
            'wrong model/host provenance')
    require(qualification['exit'] == 0 and qualification['expected_checks'] == 7 and qualification['canonical'] and
            qualification['joined_routes'] and qualification['native_finish'] and qualification['models_clean'], 'donor qualification failed')
    require(sha(qualified / 'run.log') == qualification['log_sha256'], 'qualified log changed')
    routes((qualified / 'run.log').read_text())
    contract = json.loads((protocol / 'manifest.json').read_text())
    require(sha(protocol / 'packed.nds') == gate.ROM == contract['rom_sha256'] and contract['expected_rows'] == 18, 'wrong full18 ROM')
    sampler = gate.elf_symbol(protocol / 'packed.elf', 'gxlat_dma')
    require(sha(protocol / 'packed.elf') == contract['elf_sha256'] and sampler['address'] == 0x01ff8020 and
            sampler['size'] == 320 and hashlib.sha256(sampler['body']).hexdigest() == gate.SAMPLER and
            (protocol / 'packed.nds').read_bytes().count(sampler['body']) == 1, 'frozen sampler differs')
    captured = json.loads(capture.read_text())
    raw = capture.parent / 'trip20261031/gxlatency_v4_packed.csv'
    require(sha(raw) == captured['files'][raw.name], 'DS raw CSV differs')
    out.mkdir(parents=True, exist_ok=False)
    proof = out / 'proof'
    proof.mkdir()
    for name in PINS:
        shutil.copy2(donor / name, proof / name)
    for name, path in {'harness.sv': canonical, 'build-marker.txt': marker, 'donor-model.json': qualified / 'model.json',
                       'donor-qualification.json': qualified / 'manifest.json', 'donor.log': qualified / 'run.log',
                       'capture-manifest.json': capture, 'ds.csv': raw, 'protocol-manifest.json': protocol / 'manifest.json',
                       'packed.elf': protocol / 'packed.elf'}.items():
        shutil.copy2(path, proof / name)
    shutil.copy2(protocol / 'packed.nds', out / 'packed.nds')
    runtime = out / 'runtime'
    runtime.mkdir()
    (runtime / 'rom.hex').write_text(gate.hex_image((out / 'packed.nds').read_bytes()))
    for name in ('bios9', 'bios7', 'firmware'):
        (runtime / (name + '.hex')).write_text(gate.hex_image((roms / (name + '.bin')).read_bytes()))
    boot, scpu = (source / 'sw/boot/bootrom.bin').read_bytes(), (source / 'sw/scpu/cache.bin').read_bytes()
    (runtime / 'boot.hex').write_text(gate.hex_image(boot + bytes(8192 - len(boot)) + scpu + bytes(4096 - len(scpu))))
    shutil.copy2(source / 'sw/scpu/mbox.hex', runtime / 'mbox.hex')
    shutil.copy2(qualified / 'run/bootrom.mif', runtime / 'bootrom.mif')
    for name in ('bios9.hex', 'bios7.hex', 'firmware.hex', 'boot.hex', 'mbox.hex'):
        require(sha(runtime / name) == qualification['expanded_inputs_sha256'][name], 'runtime input differs: ' + name)
    argv = [str(model), f'+rom={runtime / "rom.hex"}', f'+romsize={(out / "packed.nds").stat().st_size}',
            f'+bios9={runtime / "bios9.hex"}', f'+bios7={runtime / "bios7.hex"}', f'+fw={runtime / "firmware.hex"}',
            f'+boot={runtime / "boot.hex"}', f'+fwsize={(roms / "firmware.bin").stat().st_size}',
            '+frames=128', '+vmcheck', '+progress', '+stop_done=1', '+wwatch=23f0100']
    plan = dict(source=SOURCE, profile=PROFILE, host='zero-laptop', model=str(model), model_sha256=MODEL, cache_key=KEY,
                argv=argv, cwd=str(runtime), expected_rows=18, canonical_checks=2, threads=1, compile_jobs=0,
                full_protocol_initial_context=True, source_cache_key_reproduced=True, actual_assertions=ASSERTIONS,
                route_banners=BANNERS, donor=str(donor), donor_pins=PINS, sampler_sha256=gate.SAMPLER,
                cache_inputs_sha256={str(p): sha(p) for p in sorted(set(files))},
                reporting_tools={str(p): sha(p) for p in Path(__file__).resolve().parent.glob('*.py')},
                frozen_files={str(p.relative_to(out)): sha(p) for p in out.rglob('*') if p.is_file()})
    gate.save(out / 'plan.json', plan)


def verify(out):
    plan = json.loads((out / 'plan.json').read_text())
    gate.require(plan['source'] == SOURCE and plan['profile'] == PROFILE and plan['model_sha256'] == MODEL and
                 plan['cache_key'] == KEY and plan['full_protocol_initial_context'] and plan['expected_rows'] == 18, 'wrong replay plan')
    for name, digest in plan['frozen_files'].items():
        gate.require(gate.sha(out / name) == digest, 'prepared file changed: ' + name)
    for name, digest in plan['reporting_tools'].items():
        gate.require(gate.sha(Path(name)) == digest, 'reporting tool changed: ' + name)
    gate.require(gate.sha(out / 'packed.nds') == gate.ROM, 'actual full18 ROM changed')
    return plan


def capacity():
    load = os.getloadavg()
    rows = subprocess.check_output(['ps', '-eo', 'pid,ppid,ni,etimes,pcpu,comm'], text=True).splitlines()
    busy = [r for r in rows[1:] if (r.split()[-1].startswith('V') or r.split()[-1] in
                                   ('census', 'cc1plus', 'clang++', 'verilator_bin'))]
    gate.require(load[0] <= 24 and len(busy) < 3, 'allocated LP slot has no capacity')
    return dict(load_average=load, other_workers=busy, max_workers=3, max_load=24)


def run(out, allocation):
    gate.require(allocation.strip() and socket.gethostname() == 'zero-laptop', 'allocated Laptop run required')
    plan = verify(out)
    model = Path(plan['model'])
    gate.require(gate.sha(model) == MODEL and (model.parent / '.ok').read_bytes() == (out / 'proof/build-marker.txt').read_bytes(),
                 'actual LP cached model/marker changed')
    for path, digest in plan['cache_inputs_sha256'].items():
        gate.require(gate.sha(Path(path)) == digest, 'LP source input changed: ' + path)
    gate.require(not (out / 'execution.json').exists(), 'keep previous attempt; fresh output required')
    os.setpriority(os.PRIO_PROCESS, 0, 10)
    evidence = dict(source=SOURCE, profile=PROFILE, allocation=allocation, host=socket.gethostname(),
                    launcher_pid=os.getpid(), model_sha256=gate.sha(model), plan_sha256=gate.sha(out / 'plan.json'),
                    argv=plan['argv'], cwd=plan['cwd'], capacity=capacity(), nice_absolute=os.getpriority(os.PRIO_PROCESS, 0), exit=None)
    gate.save(out / 'execution.json', evidence)
    start = time.time()
    with (out / 'native.log').open('x') as log:
        child = subprocess.Popen(plan['argv'], cwd=plan['cwd'], stdout=log, stderr=subprocess.STDOUT)
        evidence['model_pid'] = child.pid
        gate.save(out / 'execution.json', evidence)
        print('exact18 a3 native PID', child.pid, flush=True)
        evidence['exit'] = child.wait()
    evidence.update(seconds=time.time() - start, native_log_sha256=gate.sha(out / 'native.log'),
                    frozen_inputs_unchanged=verify(out) == plan, model_reaped=True)
    gate.require(evidence['plan_sha256'] == gate.sha(out / 'plan.json') and gate.sha(model) == MODEL, 'plan/model changed during replay')
    gate.save(out / 'execution.json', evidence)
    projected, scope = protocol_log((out / 'native.log').read_text())
    routes(projected)
    result = gate.check_log(projected, evidence['exit'], cache_banner=BANNERS[0])
    with (out / 'proof/ds.csv').open() as stream:
        reference = ds_rows(list(csv.DictReader(stream)))
    fields = ('body', 'n', 'rep', 'entries', 'words', 'stream_fnv1a32')
    gate.require(len(result['rows']) == len(reference) == 18 and
                 all(all(a[k] == b[k] for k in fields) for a, b in zip(result['rows'], reference)), 'exact18 pairing differs')
    result.update(source=SOURCE, profile=PROFILE, model_sha256=MODEL, cache_key=KEY, actual_routes=BANNERS,
                  execution_sha256=gate.sha(out / 'execution.json'), publication_scope=scope, ds_rows=reference,
                  slopes=dict(pocket=summarize(result['rows']), ds=summarize(reference)),
                  ds_timing_status='full exact18 raw endpoints; no timing-equivalence acceptance')
    gate.save(out / 'comparison.json', result)
    print('18 exact input/outcome packets accepted; canonical2/2 + VM clean', flush=True)
    for p, d in zip(result['slopes']['pocket'], result['slopes']['ds']):
        print(p['body'], 'DMA/idle', p['dma_sys']['median_group_slope'], p['idle_sys']['median_group_slope'],
              'DS', d['dma_sys']['median_group_slope'], d['idle_sys']['median_group_slope'], flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    prep = sub.add_parser('prepare')
    for name in ('donor', 'protocol', 'roms', 'capture', 'marker', 'out'):
        prep.add_argument('--' + name, type=Path, required=True)
    launch = sub.add_parser('run')
    launch.add_argument('--out', type=Path, required=True)
    launch.add_argument('--allocation', required=True)
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(*[getattr(args, k).resolve() for k in ('donor', 'protocol', 'roms', 'capture', 'marker', 'out')])
        print('prepared complete exact18; no compile or model execution')
    else:
        run(args.out.resolve(), args.allocation)


if __name__ == '__main__':
    main()
