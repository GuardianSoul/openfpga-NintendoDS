#!/usr/bin/env python3
"""Freeze/reuse a proven native model; preparation never compiles or runs it."""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess

import gx_packed as gx
from stage_gx_packed import elf_symbol

SOURCE = '12e1c03280fe1129fa342e924dc67b6b8a7911e6'
PROFILE = dict(A9_WAYS=4, A9_XD=0, A9_XI=0, A9_OPT=58713059, DMA_RA=2)
MODEL = '4f96d11ab3230cfd0dbfeb7970b44097ab4a69c7d9d5ec860b852f0f69d3397a'
ROM = '22a7821b7b80e97fbcf4944d47133aa5c3548cd0acbffd72199fea1710e105aa'
SAMPLER = '78c88bb1ff90bb8cd165c13bf1e3e743d43727772c23963650c1a2f90b42ffa3'
PINS = {
    'source-manifest.json': 'be84352d69960320d38b3317d4b5fc233127532b91e8c2cd3043f1facd9d828a',
    'host-instrumentation.json': 'c50d310be773893f4b4581b285ab191d8b4746b9947e803929a0652997f6e436',
    'inputs.json': '28aea855772ca774640d3ecc4809fffe72acd22bd51aa8a9076180825f33bff7',
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')


def hex_image(data):
    data += b'\0' * (-len(data) % 4)
    return ''.join(f'{int.from_bytes(data[i:i + 4], "little"):08x}\n'
                   for i in range(0, len(data), 4))


def check_log(text, exit_code, cache_banner='DS_CACHE_ROUTE_OK: ways4 D4KiB I8KiB opt58713059 sound/wifi/3D on'):
    require(exit_code == 0, 'native exit must be zero')
    require(not re.search(r'\b(?:ERROR|FAIL|TIMEOUT|Assertion failed)\b|%Error', text),
            'native error/failure/timeout')
    require(text.count('Verilog $finish') == 1 and re.findall(r'^PASS$', text, re.M) == ['PASS'],
            'one canonical PASS and native finish required')
    require(text.count('clean-boot: DS main RAM and VRAM zeroed; boot clear skipped') == 1,
            'clean boot required')
    require(text.count(cache_banner) == 1,
            'actual DS cache/feature route required')
    verdict = re.findall(r'^result: magic (\w+) checks (\d+) mask (\w+) done (\d+)$', text, re.M)
    require(len(verdict) == 1 and tuple(int(v, b) for v, b in zip(verdict[0], (16, 10, 16, 10)))
            == (0x52545344, 2, 3, 1), 'canonical 2/2 result required')
    values = re.findall(r'^value (\d+) (\d+)$', text, re.M)
    require(values == [('0', '18'), ('1', '0')], 'canonical values must be 18 rows / 0 failures')
    video = re.findall(r'^video: (\d+) frames, (\d+) errors; DS frames (\d+), retired 9:(\d+) 7:(\d+); underruns (\d+)$', text, re.M)
    require(len(video) == 1 and int(video[0][0]) > 0 and int(video[0][1]) == 0 and int(video[0][5]) == 0,
            'clean video/underrun summary required')
    models = re.findall(r'^models: sdram errors (\d+), cram errors (\d+)/(\d+); cart words (\d+), (\d+) on clk_bus edges$', text, re.M)
    require(len(models) == 1 and models[0][:3] == ('0', '0', '0') and
            int(models[0][3]) > 0 and models[0][4] == '0', 'clean models and real cartridge reads required')
    vm = re.findall(r'^vmcheck: (\d+) words read, (\d+) CPU reads from the block buffer, (\d+) mismatches$', text, re.M)
    require(len(vm) == 1 and int(vm[0][0]) > 0 and vm[0][2] == '0', 'nonempty clean vmcheck required')
    rows = gx.validate(gx.decode_log(text))
    return dict(rows=rows, checks=2, failures=0, video_frames=int(video[0][0]),
                cart_words=int(models[0][3]), vm_words=int(vm[0][0]), vm_cpu_reads=int(vm[0][1]),
                ds_timing_status='pending matched real-DS capture; no ratio accepted',
                scope='packed inputs / DMA-finish and GX-idle / outcome; no game or save equivalence')


def prepare(snapshot, protocol, roms, out):
    for name, digest in PINS.items():
        require(sha(snapshot / name) == digest, f'frozen snapshot manifest changed: {name}')
    source = snapshot / 'source'
    manifest = json.loads((snapshot / 'source-manifest.json').read_text())
    require(manifest['sha'] == SOURCE, 'wrong source commit')
    for name, digest in manifest['files'].items():
        require(sha(source / name) == digest, f'frozen source changed: {name}')
    inputs = json.loads((snapshot / 'inputs.json').read_text())
    require(inputs['profile'] == PROFILE, 'wrong DS profile')
    host = json.loads((snapshot / 'host-instrumentation.json').read_text())
    for entry in host['files']:
        require(sha(source / entry['file']) == entry['instrumented_sha256'], 'instrumentation changed')
    harness = source / 'build/cpu-scorecard/tb_canonical.sv'
    require(sha(harness) == sha(source / 'sim/pocket_ds/tb_ds_pocket.sv'), 'unexpected canonical harness')
    # Reproduce the verified runner's content-addressed identity without
    # executing or writing into the donor source tree.
    tree = ast.parse((source / 'sim/pocket_ds/run.py').read_text())
    sim = next(ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign)
               and any(isinstance(t, ast.Name) and t.id == 'SIM' for t in n.targets))
    cmd = ['build/tools/oss-cad-suite/bin/verilator',
           '--binary', '--timing', '-O3', '-j', '8', '-Wno-fatal', '-Wno-WIDTHEXPAND',
           '-Wno-WIDTHTRUNC', '-Wno-UNUSEDSIGNAL', '--timescale', '1ns/1ps', '--top-module',
           'tb_ds_pocket', '+define+NODEBUG', '+define+CLEAN_BOOT',
           '+define+TB_CORE_PARAMS=' + ''.join(f', .{k}({v})' for k, v in PROFILE.items()),
           '-GROM_AW=24', '--threads', '1', '-MAKEFLAGS', 'OPT_FAST=-O2', '-CFLAGS',
           '-march=native', '-I' + str(source / 'rtl/pocket')]
    files = [p for p in (source / 'rtl').rglob('*') if p.is_file() and
             p.suffix in ('.sv', '.svh', '.v', '.vh', '.mif', '.hex')]
    files += [harness if p == 'sim/pocket_ds/tb_ds_pocket.sv' else source / p for p in sim]
    cache_hash = hashlib.sha256()
    for arg in cmd:
        cache_hash.update(arg.replace(str(source / 'rtl'), '<rtl>').encode() + b'\0')
    for path in sorted(set(files)):
        cache_hash.update(path.name.encode() + b'\0' + path.read_bytes())
    key = cache_hash.hexdigest()[:20]
    require(key == '7383f6ccbf9d73c4ea65', 'source/flags do not reproduce model cache identity')
    model = snapshot / 'model-cache-arch' / key / 'Vtb_ds_pocket'
    marker = model.parent / '.ok'
    require(marker.read_text() == ' '.join(cmd) + '\n', 'model build marker differs')
    require(sha(model) == MODEL, 'actual model executable differs')
    observed = json.loads((snapshot / 'results/unitgx/model.json').read_text())
    require(observed['sha256'] == MODEL and observed['host'] == socket.gethostname(),
            'native model has no matching same-host execution provenance')
    require(Path(observed['argv'][0]) == model, 'observed model path differs')
    rom = protocol / 'packed.nds'
    require(sha(rom) == ROM, 'frozen counterpart ROM changed')
    contract = json.loads((protocol / 'manifest.json').read_text())
    require(contract['expected_rows'] == 18 and contract['rom_sha256'] == ROM, 'wrong protocol count/ROM')
    sampler = elf_symbol(protocol / 'packed.elf', 'gxlat_dma')
    require(sampler['address'] == 0x01ff8020 and sampler['size'] == 320 and
            hashlib.sha256(sampler['body']).hexdigest() == SAMPLER and
            rom.read_bytes().count(sampler['body']) == 1, 'exact sampler proof failed')
    require(sha(protocol / 'packed.elf') == contract['elf_sha256'], 'sampler ELF changed')
    out.mkdir(parents=True, exist_ok=False)
    shutil.copy2(model, out / 'Vtb_ds_pocket')
    shutil.copy2(rom, out / 'packed.nds')
    runtime = out / 'runtime'
    runtime.mkdir()
    (runtime / 'rom.hex').write_text(hex_image(rom.read_bytes()))
    binary_inputs = {}
    for name in ('bios9', 'bios7', 'firmware'):
        binary = roms / (name + '.bin')
        binary_inputs[str(binary)] = sha(binary)
        (runtime / (name + '.hex')).write_text(hex_image(binary.read_bytes()))
    boot, scpu = (source / 'sw/boot/bootrom.bin').read_bytes(), (source / 'sw/scpu/cache.bin').read_bytes()
    (runtime / 'boot.hex').write_text(hex_image(boot + bytes(8192 - len(boot)) + scpu + bytes(4096 - len(scpu))))
    shutil.copy2(source / 'sw/scpu/mbox.hex', runtime / 'mbox.hex')
    shutil.copy2(source / 'build/boot/bootrom.hex', runtime / 'bootrom.mif')
    # Donor runtime files can be retired by its owner after completion. Pin
    # our generated inputs to its launch while the files remain available.
    for name in ('bios9.hex', 'bios7.hex', 'firmware.hex', 'boot.hex', 'mbox.hex', 'bootrom.mif'):
        require(sha(runtime / name) == sha(snapshot / 'results/unitgx/run' / name),
                f'runtime differs from observed model launch: {name}')
    argv = [str(out / 'Vtb_ds_pocket'), f'+rom={runtime / "rom.hex"}', f'+romsize={rom.stat().st_size}',
            f'+bios9={runtime / "bios9.hex"}', f'+bios7={runtime / "bios7.hex"}',
            f'+fw={runtime / "firmware.hex"}', f'+boot={runtime / "boot.hex"}',
            f'+fwsize={(roms / "firmware.bin").stat().st_size}', '+frames=64', '+vmcheck',
            '+progress', '+stop_done=1', '+wwatch=23f0100']
    pinned = {str(p.relative_to(out)): sha(p) for p in out.rglob('*') if p.is_file()}
    plan = dict(source=SOURCE, profile=PROFILE, cache_key=key, host=socket.gethostname(),
                donor=str(snapshot), donor_model=observed, build_command=cmd,
                snapshot_pins=PINS, source_files=manifest['files'],
                harness_sha256=sha(harness), cache_inputs_sha256={str(p): sha(p) for p in files},
                protocol_manifest_sha256=sha(protocol / 'manifest.json'), sampler_sha256=SAMPLER,
                expected_rows=18, canonical_checks=2, frozen_files=pinned, binary_inputs=binary_inputs,
                reporting_tools={str(Path(__file__).resolve()): sha(Path(__file__)),
                                 str(Path(gx.__file__).resolve()): sha(Path(gx.__file__))},
                argv=argv, cwd=str(runtime), prepared_only=True,
                qualification='not executed; real-DS comparison pending')
    save(out / 'plan.json', plan)
    return plan


def run(out, allocation):
    plan_path = out / 'plan.json'
    plan = json.loads(plan_path.read_text())
    require(allocation.strip(), 'explicit coordinator allocation reference required')
    require(plan['host'] == socket.gethostname(), 'host differs from native build')
    for name, digest in plan.get('reporting_tools', {}).items():
        require(sha(Path(name)) == digest, f'reporting tool changed: {name}')
    for name, digest in plan['frozen_files'].items():
        require(sha(out / name) == digest, f'prepared file changed: {name}')
    require(sha(out / 'Vtb_ds_pocket') == MODEL and sha(out / 'packed.nds') == ROM,
            'model/ROM changed')
    require(not (out / 'execution.json').exists(), 'run already attempted; keep evidence immutable')
    evidence = dict(plan_sha256=sha(plan_path), allocation=allocation, launcher_pid=os.getpid(),
                    host=socket.gethostname(), argv=plan['argv'], cwd=plan['cwd'], exit=None,
                    actual_model_sha256=sha(out / 'Vtb_ds_pocket'))
    save(out / 'execution.json', evidence)
    with (out / 'native.log').open('x') as log:
        child = subprocess.Popen(['nice', '-n', '10', *plan['argv']], cwd=plan['cwd'],
                                 stdout=log, stderr=subprocess.STDOUT)
        evidence['model_pid'] = child.pid
        save(out / 'execution.json', evidence)
        print(f'native model PID {child.pid}', flush=True)
        evidence['exit'] = child.wait()
    evidence['log_sha256'] = sha(out / 'native.log')
    evidence['frozen_files_unchanged'] = all(sha(out / n) == h for n, h in plan['frozen_files'].items())
    save(out / 'execution.json', evidence)
    require(evidence['frozen_files_unchanged'] and sha(plan_path) == evidence['plan_sha256'],
            'native inputs/plan changed during execution')
    result = check_log((out / 'native.log').read_text(), evidence['exit'])
    result['execution_sha256'] = sha(out / 'execution.json')
    save(out / 'endpoints.json', result)
    print('native endpoints accepted; DS timing comparison pending', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    prep = sub.add_parser('prepare')
    for name in ('snapshot', 'protocol', 'roms', 'out'):
        prep.add_argument('--' + name, type=Path, required=True)
    launch = sub.add_parser('run')
    launch.add_argument('--out', type=Path, required=True)
    launch.add_argument('--allocation', required=True, help='existing coordinator worker allocation reference')
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args.snapshot.resolve(), args.protocol.resolve(), args.roms.resolve(), args.out.resolve())
        print('prepared without compiling or executing a native model')
    else:
        run(args.out.resolve(), args.allocation)


if __name__ == '__main__':
    main()
