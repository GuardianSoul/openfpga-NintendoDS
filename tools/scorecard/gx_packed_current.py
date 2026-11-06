#!/usr/bin/env python3
"""Prepare an explicitly pinned replay without compiling or executing a model."""
import argparse
import ast
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tarfile

import gx_packed_native as gate
from compare_gx_packed import ds_rows, protocol_log, summarize

SOURCE = 'f4c87a34d114e67674b52ee28764c1e064fd0b2f'
DONOR = 'b1ec62ea2ffdb6ad968a81fd373f8f7fa24fa2fa'
PROFILE = dict(A9_WAYS=4, A9_XD=0, A9_XI=0, A9_OPT=192930787, DMA_RA=2, DX_SKID=1)
MODEL = 'aca6fb7e507c5bb5070e3fbd07135b3197ce7ec3463bf450fcb6f6779ba1fb0f'
KEY = '1a848adeb6e363ee0548'
PINS = {'source-manifest.json': '95fb60168990f10ddef9615ba49ddb739b5d4e09eed88d30e053ad6111b367ea',
        'inputs.json': '5b284221961782372d4b45fb3b47dfbea5f7e1ec63bd86a3aa41722b2b3a7134',
        'host-instrumentation.json': '8f137ad4a8adacb20dc34e8bb121a8338f47e7d3f0345693f1b88f93dfcda729'}
ROOT = Path(__file__).resolve().parents[2]
CACHE_BANNER = 'DS_CACHE_ROUTE_OK: ways4 D4KiB I8KiB opt58713059 sound/wifi/3D on'
STALE_BANNER_OPT = 58713059
QUALIFICATION = 'unitmem'
QUALIFICATION_CHECKS = 32
EXTRA_ASSERTIONS = ()
ROUTE_GUARDS = ()


def select_revision(revision):
    """Historical profiles stay frozen; new profiles require explicit selection."""
    global SOURCE, DONOR, PROFILE, MODEL, KEY, PINS, CACHE_BANNER, STALE_BANNER_OPT
    global QUALIFICATION, QUALIFICATION_CHECKS, EXTRA_ASSERTIONS, ROUTE_GUARDS
    gate.require(revision in ('921', 'cc00'), 'explicit revision required')
    SOURCE = DONOR = '9210e0aba922e71c28b3f49ea65452667f7c0418'
    PROFILE = dict(A9_WAYS=4, A9_XD=0, A9_XI=0, A9_OPT=461366243, DMA_RA=2, DX_SKID=1)
    MODEL = 'c3b87125b4e5a1ef4446bd28013cfe2dc4ae42033d398b298ef32ce6107007ed'
    KEY = 'c8d59a78bb57049b957d'
    PINS = {'source-manifest.json': 'dd8e76f75465bf9993f824750939ecec378dbd70e832fa870d0d3e1fa9472d9c',
            'inputs.json': 'd4d58ea411aca01c3d1819adb01ecf68745b6a0ed3bf5f750348f18c8c03867b',
            'host-instrumentation.json': '43c951d22eb337498fe9c8cd252dd77740c1a52b3d4d50f07a7a81bcbab86d71'}
    CACHE_BANNER = 'DS_CACHE_ROUTE_OK: ways4 D4KiB I8KiB opt461366243 RA2 DX1 Shell2 independent ARM7 all7features sound/wifi/3D on'
    STALE_BANNER_OPT = None
    QUALIFICATION, QUALIFICATION_CHECKS = 'unitmem', 32
    EXTRA_ASSERTIONS, ROUTE_GUARDS = (), ()
    if revision == 'cc00':
        SOURCE = DONOR = 'cc00aa13144152f7c50f6b0d5ec8035a262353ff'
        PROFILE = dict(PROFILE, GX_DSX=1)
        MODEL = 'ca3bf691abeb98adffe68e67ec3df5dbeeaa156ccd47c38d97f45adc60573efd'
        KEY = 'b578b791d95768b52385'
        PINS = {'source-manifest.json': 'eb74668ebba1385140fc81f2c60f4d8f27dec875dc1429d1fa467c37d4e3995c',
                'inputs.json': '4eaabad18e9dc3858b00b4b003eae840d2a209b900eae23c6ee39830156fadb5',
                'host-instrumentation.json': 'ddda529dc9d12ab931378b7d041f917a2bc45bc1c16da52ca5615674546927cf'}
        QUALIFICATION, QUALIFICATION_CHECKS = 'itcm-control', 7
        EXTRA_ASSERTIONS = ('dut.ds.g_3d.u_gpu3d.u_geom.GX_DSX != 1',
                            'dut.ds.g_3d.u_gpu3d.u_geom.u_front.DSX != 1',
                            'dut.ds.g_3d.u_gpu3d.u_geom.u_front.CHEAP != 0',
                            'dut.ds.g_3d.u_gpu3d.u_geom.u_eng.AHEAD != 1')
        ROUTE_GUARDS = ('DS_GX_ROUTE_OK: DSX1 CHEAP0 AHEAD1',)


def check_route(text):
    for banner in ROUTE_GUARDS:
        gate.require(text.splitlines().count(banner) == 1, 'actual GX DSX/child route missing or wrong')


def prepare(donor, protocol, roms, capture, out):
    require, sha = gate.require, gate.sha
    for name, digest in PINS.items():
        require(sha(donor / name) == digest, f'donor manifest changed: {name}')
    record = json.loads((donor / 'source-manifest.json').read_text())
    inputs = json.loads((donor / 'inputs.json').read_text())
    instrument = json.loads((donor / 'host-instrumentation.json').read_text())
    overrides = {r['file']: r for r in instrument['files']}
    require(record['sha'] == DONOR and inputs['profile'] == PROFILE, 'wrong donor/profile')
    for name, digest in record['files'].items():
        if name in overrides:
            require(digest == overrides[name]['original_sha256'], 'unrecorded source instrumentation')
            digest = overrides[name]['instrumented_sha256']
        require(sha(donor / 'source' / name) == digest, f'donor source changed: {name}')
    # Only read git objects. No checkout/build/model process is started.
    delta = subprocess.check_output(['git', 'diff', '--name-only', DONOR, SOURCE, '--',
                                    'rtl', 'sw/boot', 'sw/scpu', 'sim/pocket_ds', 'sim/probe',
                                    'sim/phase1', 'rnd/pocket_cpu.py'], cwd=ROOT).decode()
    require(not delta.strip(), 'target RTL/firmware/harness differs from donor')
    archive = subprocess.check_output(['git', 'archive', '--format=tar', SOURCE], cwd=ROOT)
    out.mkdir(parents=True, exist_ok=False)
    source = out / 'source'
    source.mkdir()
    with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
        tree.extractall(source, filter='data')
    original = {str(p.relative_to(source)): sha(p) for p in source.rglob('*') if p.is_file()}
    for name, row in overrides.items():
        require(sha(source / name) == row['original_sha256'], 'target host source differs from original donor')
        shutil.copy2(donor / 'source' / name, source / name)
    canonical = source / 'build/cpu-scorecard/tb_canonical.sv'
    canonical.parent.mkdir(parents=True)
    shutil.copy2(donor / 'source/build/cpu-scorecard/tb_canonical.sv', canonical)
    require(sha(canonical) == overrides['sim/pocket_ds/tb_ds_pocket.sv']['instrumented_sha256'], 'canonical harness differs')
    text = canonical.read_text()
    # Compiled fatal assertions and model identity pin actual configuration;
    # the historical f4 donor alone has a stale58713059 banner.
    assertions = ['u_mem9.WAYS != 4', 'u_mem9.DSB != 5', 'u_mem9.ISB != 6',
                  f'dut.A9_OPT != {PROFILE["A9_OPT"]}', 'dut.DX_SKID != 1', 'dut.DMA_RA != 2',
                  'dut.SOUND != 1', 'dut.WIFI != 1', 'dut.GPU3D != 1',
                  'dut.SHELL_CPU != 2', 'dut.A9_SOLO != 5', 'dut.CPU_FAST != 0']
    assertions += ['dut.G3D_' + name + ' != 1' for name in ('AA', 'TOON', 'FOG', 'ATEST', 'EDGE', 'SHADOW', 'LOWER')]
    assertions += list(EXTRA_ASSERTIONS)
    require(all(item in text for item in assertions), 'actual profile assertion missing')
    require(CACHE_BANNER in text, 'compiled route banner differs')
    require(all(banner in text for banner in ROUTE_GUARDS), 'compiled GX route banner differs')
    ast_tree = ast.parse((source / 'sim/pocket_ds/run.py').read_text())
    sim = next(ast.literal_eval(n.value) for n in ast_tree.body if isinstance(n, ast.Assign)
               and any(isinstance(t, ast.Name) and t.id == 'SIM' for t in n.targets))
    command = ['build/tools/oss-cad-suite/bin/verilator', '--binary', '--timing',
               '-O3', '-j', '8', '-Wno-fatal', '-Wno-WIDTHEXPAND', '-Wno-WIDTHTRUNC', '-Wno-UNUSEDSIGNAL',
               '--timescale', '1ns/1ps', '--top-module', 'tb_ds_pocket', '+define+NODEBUG', '+define+CLEAN_BOOT',
               '+define+TB_CORE_PARAMS=' + ''.join(f', .{k}({v})' for k, v in PROFILE.items()), '-GROM_AW=24',
               '--threads', '1', '-MAKEFLAGS', 'OPT_FAST=-O2', '-CFLAGS', '-march=native', '-I' + str(source / 'rtl/pocket')]
    files = [p for p in (source / 'rtl').rglob('*') if p.is_file() and p.suffix in ('.sv', '.svh', '.v', '.vh', '.mif', '.hex')]
    files += [canonical if p == 'sim/pocket_ds/tb_ds_pocket.sv' else source / p for p in sim]
    cache = hashlib.sha256()
    for arg in command:
        cache.update(arg.replace(str(source / 'rtl'), '<rtl>').encode() + b'\0')
    for path in sorted(set(files)):
        cache.update(path.name.encode() + b'\0' + path.read_bytes())
    require(cache.hexdigest()[:20] == KEY, 'target source/flags do not reproduce actual donor model key')
    model = donor / 'model-cache-arch' / KEY / 'Vtb_ds_pocket'
    qualified = donor / 'results' / QUALIFICATION
    observed = json.loads((qualified / 'model.json').read_text())
    qualification = json.loads((qualified / 'manifest.json').read_text())
    require(sha(model) == MODEL == observed['sha256'] and observed['host'] == socket.gethostname(), 'wrong model/host')
    require(qualification['exit'] == 0 and qualification['canonical'] and qualification['ds_cache_route'] and
            qualification['expected_checks'] == QUALIFICATION_CHECKS, 'donor actual runtime profile not qualified')
    donor_log = qualified / 'run.log'
    require(sha(donor_log) == qualification['log_sha256'], 'donor runtime log changed')
    require(f'result: magic 52545344 checks {QUALIFICATION_CHECKS} mask {(1 << QUALIFICATION_CHECKS)-1:08x} done 1' in donor_log.read_text(),
            'actual donor canonical result absent')
    check_route(donor_log.read_text())
    expected_marker = ' '.join(arg.replace(str(source / 'rtl'), str(donor / 'source/rtl')) for arg in command) + '\n'
    require((model.parent / '.ok').read_text() == expected_marker, 'donor compile marker differs')
    require(gate.sha(protocol / 'packed.nds') == gate.ROM, 'frozen ROM changed')
    contract = json.loads((protocol / 'manifest.json').read_text())
    sampler = gate.elf_symbol(protocol / 'packed.elf', 'gxlat_dma')
    require(sha(protocol / 'packed.elf') == contract['elf_sha256'] and sampler['address'] == 0x01ff8020 and
            sampler['size'] == 320 and hashlib.sha256(sampler['body']).hexdigest() == gate.SAMPLER and
            (protocol / 'packed.nds').read_bytes().count(sampler['body']) == 1, 'sampler proof failed')
    shutil.copy2(model, out / 'Vtb_ds_pocket')
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
        require(sha(runtime / name) == qualification['expanded_inputs_sha256'][name], f'support image differs: {name}')
    gate.save(out / 'source-original.json', dict(source=SOURCE, files=original))
    gate.save(out / 'host-instrumentation.json', instrument)
    shutil.copy2(model.parent / '.ok', out / 'donor-build-marker.txt')
    shutil.copy2(qualified / 'model.json', out / 'donor-model-execution.json')
    shutil.copy2(qualified / 'manifest.json', out / 'donor-native-qualification.json')
    argv = [str(out / 'Vtb_ds_pocket'), f'+rom={runtime / "rom.hex"}', f'+romsize={(out / "packed.nds").stat().st_size}',
            f'+bios9={runtime / "bios9.hex"}', f'+bios7={runtime / "bios7.hex"}', f'+fw={runtime / "firmware.hex"}',
            f'+boot={runtime / "boot.hex"}', f'+fwsize={(roms / "firmware.bin").stat().st_size}', '+frames=128',
            '+vmcheck', '+progress', '+stop_done=1', '+wwatch=23f0100']
    plan = dict(source=SOURCE, compiled_donor_source=DONOR, profile=PROFILE, model_sha256=MODEL, cache_key=KEY,
                source_compile_inputs_equal=True, actual_assertions=assertions, stale_banner_opt=STALE_BANNER_OPT,
                actual_asserted_opt=PROFILE['A9_OPT'], cache_banner=CACHE_BANNER,
                route_guards=ROUTE_GUARDS, donor_qualification=QUALIFICATION,
                host=socket.gethostname(), expected_rows=18, canonical_checks=2,
                native_status='HOLD; not run; current endpoint measurements PENDING',
                source_files={str(p.relative_to(source)): sha(p) for p in source.rglob('*') if p.is_file()},
                frozen_files={str(p.relative_to(out)): sha(p) for p in out.rglob('*') if p.is_file() and source not in p.parents},
                reporting_tools={str(Path(p).resolve()): sha(Path(p)) for p in
                                 (__file__, gate.__file__, ROOT / 'tools/scorecard/gx_packed.py', ROOT / 'tools/scorecard/compare_gx_packed.py')},
                capture_manifest=str(capture), capture_manifest_sha256=sha(capture),
                protocol_manifest_sha256=sha(protocol / 'manifest.json'), sampler_sha256=gate.SAMPLER,
                argv=argv, cwd=str(runtime), threads=1, compile_jobs=0, donor_build_jobs=1,
                packet_guard_qualification='gx-packed-12e1-run38-evidence.json: actual missing-write/data/duplicate-commit mutations caught; parser unchanged')
    gate.save(out / 'plan.json', plan)
    return plan


def verify(out):
    plan = json.loads((out / 'plan.json').read_text())
    gate.require(plan['source'] == SOURCE and plan['profile'] == PROFILE and plan['model_sha256'] == MODEL, 'wrong replay plan')
    gate.require(plan.get('route_guards', []) == list(ROUTE_GUARDS), 'wrong GX route contract')
    gate.require(plan['host'] == socket.gethostname(), 'wrong native host')
    for group, base in [('source_files', out / 'source'), ('frozen_files', out)]:
        for name, digest in plan[group].items():
            gate.require(gate.sha(base / name) == digest, f'prepared file changed: {name}')
    for name, digest in plan['reporting_tools'].items():
        gate.require(gate.sha(Path(name)) == digest, f'reporting tool changed: {name}')
    gate.require(gate.sha(out / 'Vtb_ds_pocket') == MODEL and gate.sha(out / 'packed.nds') == gate.ROM, 'actual model/ROM differs')
    gate.require(gate.sha(Path(plan['capture_manifest'])) == plan['capture_manifest_sha256'], 'capture manifest changed')
    return plan


def run(out, allocation):
    gate.require(allocation.strip(), 'existing coordinator allocation reference required; native HOLD otherwise')
    plan = verify(out)
    gate.require(not (out / 'execution.json').exists(), 'replay already attempted')
    evidence = dict(source=SOURCE, compiled_donor_source=DONOR, profile=PROFILE, allocation=allocation,
                    host=socket.gethostname(), launcher_pid=os.getpid(), model_sha256=gate.sha(out / 'Vtb_ds_pocket'),
                    plan_sha256=gate.sha(out / 'plan.json'), argv=plan['argv'], exit=None)
    gate.save(out / 'execution.json', evidence)
    with (out / 'native.log').open('x') as log:
        os.setpriority(os.PRIO_PROCESS, 0, 10)
        child = subprocess.Popen(plan['argv'], cwd=plan['cwd'], stdout=log, stderr=subprocess.STDOUT)
        evidence['model_pid'] = child.pid
        gate.save(out / 'execution.json', evidence)
        print('native replay PID', child.pid, flush=True)
        evidence['exit'] = child.wait()
    evidence['native_log_sha256'] = gate.sha(out / 'native.log')
    evidence['prepared_files_unchanged'] = verify(out) == plan
    gate.save(out / 'execution.json', evidence)
    gate.require(evidence['prepared_files_unchanged'] and gate.sha(out / 'plan.json') == evidence['plan_sha256'], 'replay inputs/plan changed')
    projected, scope = protocol_log((out / 'native.log').read_text())
    check_route(projected)
    result = gate.check_log(projected, evidence['exit'], cache_banner=CACHE_BANNER)
    import csv
    manifest_path = Path(plan['capture_manifest'])
    manifest = json.loads(manifest_path.read_text())
    path = manifest_path.parent / 'trip20261031/gxlatency_v4_packed.csv'
    gate.require(gate.sha(path) == manifest['files'][path.name], 'raw DS packed CSV changed')
    with path.open(newline='') as stream:
        reference = ds_rows(list(csv.DictReader(stream)))
    fields = ('body', 'n', 'rep', 'entries', 'words', 'stream_fnv1a32')
    gate.require(all(all(a[key] == b[key] for key in fields) for a, b in zip(result['rows'], reference)), 'paired inputs differ')
    result.update(source=SOURCE, compiled_donor_source=DONOR, profile=PROFILE, model_sha256=MODEL,
                  execution_sha256=gate.sha(out / 'execution.json'), publication_scope=scope,
                  slopes=dict(pocket=summarize(result['rows']), ds=summarize(reference)), ds_rows=reference,
                  ds_timing_status='raw run38 pairing; no timing equivalence accepted',
                  stale_banner_opt=STALE_BANNER_OPT, actual_asserted_opt=PROFILE['A9_OPT'])
    gate.save(out / 'comparison.json', result)
    print('18 current input/outcome packets accepted; raw timing gaps retained', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', choices=('f4', '921', 'cc00'), default='f4')
    sub = parser.add_subparsers(dest='action', required=True)
    prep = sub.add_parser('prepare')
    for name in ('donor', 'protocol', 'roms', 'capture', 'out'):
        prep.add_argument('--' + name, type=Path, required=True)
    launch = sub.add_parser('run')
    launch.add_argument('--out', type=Path, required=True)
    launch.add_argument('--allocation', required=True)
    args = parser.parse_args()
    if args.revision != 'f4':
        select_revision(args.revision)
    if args.action == 'prepare':
        prepare(*[getattr(args, k).resolve() for k in ('donor', 'protocol', 'roms', 'capture', 'out')])
        print('prepared source/model/runtime only; native HOLD')
    else:
        run(args.out.resolve(), args.allocation)


if __name__ == '__main__':
    main()
