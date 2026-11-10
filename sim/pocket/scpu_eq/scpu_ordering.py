#!/usr/bin/env python3
"""Check the cache's held-request contract with real RTL and SERV firmware."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
CASES = {
    'ordinary': (-1, 0, 0, 0),
    'same_lastword_ack': (0, 0, 0, 0),
    'early_1': (1, 0, 0, 0),
    'early_2': (2, 0, 0, 0),
    'early_4': (4, 0, 0, 0),
    'early_8': (8, 0, 0, 0),
    'early_16': (16, 0, 0, 0),
    'premature_address_mutant': (-1, 1, 0, 3),
    'returned_data_mutant': (4, 0, 1, 1),
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log, cwd, env, timeout):
    start = time.monotonic()
    with log.open('w') as output:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            rc = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            rc = 124
    return dict(command=command, exit_code=rc, seconds=time.monotonic()-start,
                log=str(log), log_sha256=sha(log))


def expected_result(name, rc, text, reads):
    """A nonzero process status alone never counts as a caught mutation."""
    expected = CASES[name][3]
    complete = re.search(r'bad words (\d+)/(\d+); reads (\d+)/(\d+),', text)
    counts = re.search(r'ORDERING_COUNTS .*violations=(\d+)/(\d+)', text)
    if rc != expected:
        return False
    if expected == 3:
        failures = [line for line in text.splitlines() if line.startswith('CONTRACT_FAIL ')]
        address = re.search(r'addr=([0-9a-f]+)/([0-9a-f]+)', failures[0]) if len(failures) == 1 else None
        return (len(failures) == 1 and 'CONTRACT_FAIL new ' in failures[0]
                and 'injected=1' in failures[0]
                and address is not None and address[1] != address[2]
                and 'ORDERING_FAIL delay=-1' in text and 'mutated=1' in text)
    if not complete or tuple(map(int, complete.groups()[2:])) != (reads, reads):
        return False
    if not counts or counts.groups() != ('0', '0'):
        return False
    if expected == 0:
        return complete.groups()[:2] == ('0', '0') and bool(re.search(r'^PASS: race ', text, re.M))
    witness = re.search(r'new cycle \d+: read [0-9a-f]+ word \d+ = ([0-9a-f]+), ROM ([0-9a-f]+)', text)
    return (complete.groups()[:2] == ('1', '0') and 'DATA_MUTANT ' in text
            and witness is not None and witness[1] != witness[2]
            and bool(re.search(r'^FAIL: race ', text, re.M)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl', type=Path, default=ROOT/'rtl/pocket/nds_cart_scpu.sv',
                        help='isolated candidate RTL; default: working tree')
    parser.add_argument('--firmware', type=Path, default=ROOT/'sw/scpu/cache.bin')
    parser.add_argument('--out', type=Path, default=ROOT/'build/scpu_ordering')
    parser.add_argument('--tools', type=Path,
                        help='directory containing verilator (otherwise TOOLS or PATH)')
    parser.add_argument('--case', action='append', choices=CASES,
                        help='run selected case(s); default: all nine')
    parser.add_argument('--seed', type=int, default=1)
    parser.add_argument('--reads', type=int, default=32)
    parser.add_argument('--timeout', type=int, default=60, help='seconds per simulation')
    args = parser.parse_args()
    if args.reads < 2 or args.seed < 1 or args.timeout < 1:
        parser.error('reads >=2, seed >=1 and timeout >=1 required')
    tool = args.tools or (Path(os.environ['TOOLS']) if os.environ.get('TOOLS') else None)
    if tool is None:
        found = shutil.which('verilator')
        if not found:
            parser.error('verilator not found; use --tools /path/to/bin')
        tool = Path(found).parent
    tool = tool.resolve()
    if not (tool/'verilator').is_file():
        parser.error('tools directory has no verilator')
    rtl, firmware = args.rtl.resolve(), args.firmware.resolve()
    reference = ROOT/'rtl/pocket/nds_cart_scpu.sv'
    paths = [rtl, reference, firmware, HERE/'scpu_ordering.cpp', HERE/'tb_scpu_ordering.sv',
             Path(__file__).resolve(), ROOT/'tools/verilator-locked', *sorted((ROOT/'rtl/serv').glob('*.v'))]
    # Hash and compile the same captured bytes even if a source changes during copying.
    captured = {str(p): p.read_bytes() for p in paths}
    manifest = {name: hashlib.sha256(data).hexdigest() for name, data in captured.items()}
    args.out.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='run-', dir=args.out.resolve()))
    src = out/'source'
    src.mkdir()
    (out/'inputs.json').write_text(json.dumps(manifest, indent=2)+'\n')
    (src/'new.sv').write_bytes(captured[str(rtl)])
    ref = captured[str(reference)].decode()
    anchor = 'module nds_cart_scpu #'
    if ref.count(anchor) != 1:
        raise ValueError('reference module rename anchor mismatch')
    (src/'ref.sv').write_text(ref.replace(anchor, 'module nds_cart_scpu_ref #'))
    (src/'cache.bin').write_bytes(captured[str(firmware)])
    for name in ['scpu_ordering.cpp', 'tb_scpu_ordering.sv']:
        (src/name).write_bytes(captured[str(HERE/name)])
    serv = src/'serv'
    serv.mkdir()
    for p in sorted((ROOT/'rtl/serv').glob('*.v')):
        (serv/p.name).write_bytes(captured[str(p)])
    copied = {str(p.relative_to(src)): sha(p) for p in src.rglob('*') if p.is_file()}
    (out/'copied-inputs.json').write_text(json.dumps(copied, indent=2)+'\n')
    env = os.environ.copy()
    env['TOOLS'] = str(tool)
    command = [str(ROOT/'tools/verilator-locked'), '--cc', '--exe', '--build', '-j', '2', '-O2',
               '-Wno-fatal', '-Wno-WIDTHEXPAND', '-Wno-WIDTHTRUNC', '-Wno-UNUSEDSIGNAL',
               '-Wno-PINMISSING', '-GSLOTS=24', '-GCTL=0', '--top-module', 'tb_scpu_ordering',
               '--Mdir', str(out/'obj'), str(src/'new.sv'), str(src/'ref.sv'),
               *map(str, sorted(serv.glob('*.v'))), str(src/'tb_scpu_ordering.sv'), str(src/'scpu_ordering.cpp')]
    print('Artifacts:', out, flush=True)
    build = run(command, out/'build.log', ROOT, env, 300)
    (out/'build.json').write_text(json.dumps(build, indent=2)+'\n')
    rows = []
    exe = out/'obj/Vtb_scpu_ordering'
    cases = list(dict.fromkeys(args.case or CASES))
    if build['exit_code'] == 0 and exe.is_file():
        for name in cases:
            delay, mutate, corrupt, expected = CASES[name]
            command = [str(exe), '--seed', str(args.seed), '--reads', str(args.reads), '--strict', '0',
                       '--ref', str(src/'cache.bin'), '--new', str(src/'cache.bin'),
                       '--ordering', str(delay), '--mutate', str(mutate), '--corrupt', str(corrupt)]
            row = run(command, out/(name+'.log'), ROOT, env, args.timeout)
            row.update(name=name, expected_exit_code=expected,
                       pass_=expected_result(name, row['exit_code'], (out/(name+'.log')).read_text(), args.reads))
            rows.append(row)
            print(name, 'PASS' if row['pass_'] else 'FAIL', 'rc', row['exit_code'], flush=True)
    unchanged = all(sha(Path(p)) == h for p, h in manifest.items())
    unchanged &= all(sha(src/p) == h for p, h in copied.items())
    summary = dict(pass_=build['exit_code'] == 0 and len(rows) == len(cases)
                   and all(row['pass_'] for row in rows) and unchanged,
                   build=build, requested_cases=cases, cases=rows, source_unchanged=unchanged,
                   rtl_sha256=manifest[str(rtl)], reference_rtl_sha256=manifest[str(reference)],
                   firmware_sha256=manifest[str(firmware)],
                   executable_sha256=sha(exe) if exe.is_file() else None,
                   input_manifest_sha256=sha(out/'inputs.json'),
                   copied_input_manifest_sha256=sha(out/'copied-inputs.json'),
                   scope='Small cache/SERV ordering regression; not board timing, full APF or native hardware qualification.')
    (out/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print('PASS' if summary['pass_'] else 'FAIL', out/'summary.json', flush=True)
    return 0 if summary['pass_'] else 1


if __name__ == '__main__':
    sys.exit(main())
