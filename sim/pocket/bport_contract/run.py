#!/usr/bin/env python3
"""Exercise the actual bport diagnostic; error prints are expected for negative cases."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rtl', type=Path, default=ROOT/'rtl/pocket/nds_sdram_bus.sv')
    p.add_argument('--compare-synth', type=Path, help='require exact ALTERA_RESERVED_QIS preprocessed bytes to match this prior source')
    p.add_argument('--out', type=Path, default=ROOT/'build/bport_contract')
    p.add_argument('--iverilog', default=shutil.which('iverilog') or 'iverilog')
    p.add_argument('--vvp', default=shutil.which('vvp') or 'vvp')
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='run-', dir=args.out.resolve()))
    originals = [args.rtl.resolve(), HERE/'tb_bport_contract.sv', Path(__file__).resolve()]
    if args.compare_synth:
        originals.append(args.compare_synth.resolve())
    captured = {str(x): x.read_bytes() for x in originals}
    inputs = {name: hashlib.sha256(data).hexdigest() for name, data in captured.items()}
    (out/'dut.sv').write_bytes(captured[str(args.rtl.resolve())])
    (out/'tb.sv').write_bytes(captured[str(HERE/'tb_bport_contract.sv')])
    commands = []

    def execute(command, logfile):
        with (out/logfile).open('w') as log:
            try:
                rc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=30).returncode
            except subprocess.TimeoutExpired:
                rc = 124
        commands.append(dict(command=command, exit_code=rc, log=logfile, log_sha256=sha(out/logfile)))
        return rc

    compile_rc = execute([args.iverilog, '-g2012', '-s', 'tb_bport_contract', '-o', str(out/'tb.vvp'),
                          str(out/'dut.sv'), str(out/'tb.sv')], 'compile.log')
    sim_rc = execute([args.vvp, str(out/'tb.vvp')], 'simulation.log') if compile_rc == 0 else None
    expected_cases = []
    for kind in range(16):
        if kind not in (1, 9, 10):
            expected_cases.append((kind, 0, 0, 0))
    for a in range(16):
        for b in range(16):
            expected_cases.extend([(1, a, b, 0), (9, a, b, 0)])
    expected_cases.extend((10, 15, 15, bit) for bit in range(32))
    rows, unexpected = [], []
    current = None
    done = None
    if sim_rc == 0:
        for line in (out/'simulation.log').read_text().splitlines():
            begin = re.fullmatch(r'CASE_BEGIN (\d+) (\d+) (\d+) (\d+) (\d+)', line)
            end = re.fullmatch(r'CASE_END (\d+)', line)
            finish = re.fullmatch(r'TB_DONE (\d+)', line)
            if begin:
                if current is not None:
                    unexpected.append('nested case')
                current = dict(id=int(begin[1]), stimulus=list(map(int, begin.groups()[1:])), diagnostics=[])
            elif 'nds_sdram_bport: ERROR:' in line:
                if current is None:
                    unexpected.append(line)
                else:
                    current['diagnostics'].append(line)
            elif end:
                if current is None or current['id'] != int(end[1]):
                    unexpected.append('mismatched case end')
                else:
                    kind, a, b, bit = current['stimulus']
                    expect = kind in (4, 5, 6, 7, 10, 11, 12, 13, 14, 15) or (kind == 9 and a != b)
                    current['expected_errors'] = int(expect)
                    current['pass_'] = len(current['diagnostics']) == int(expect)
                    rows.append(current)
                current = None
            elif finish:
                done = int(finish[1])
            elif 'ERROR' in line or 'FATAL' in line:
                unexpected.append(line)
    inventory_ok = (len(rows) == len(expected_cases) and done == len(expected_cases)
                    and current is None and [x['id'] for x in rows] == list(range(len(expected_cases)))
                    and [tuple(x['stimulus']) for x in rows] == expected_cases)
    synth = None
    if args.compare_synth:
        (out/'prior.sv').write_bytes(captured[str(args.compare_synth.resolve())])
        a = execute([args.iverilog, '-g2012', '-E', '-DALTERA_RESERVED_QIS', '-o', str(out/'current.pp'), str(out/'dut.sv')], 'current-preprocess.log')
        b = execute([args.iverilog, '-g2012', '-E', '-DALTERA_RESERVED_QIS', '-o', str(out/'prior.pp'), str(out/'prior.sv')], 'prior-preprocess.log')
        synth = dict(pass_=a == b == 0 and (out/'current.pp').read_bytes() == (out/'prior.pp').read_bytes(),
                     current_sha256=sha(out/'current.pp'), prior_sha256=sha(out/'prior.pp')) if a == b == 0 else dict(pass_=False)
    unchanged = all(sha(Path(name)) == h for name, h in inputs.items())
    result = dict(pass_=compile_rc == sim_rc == 0 and inventory_ok and not unexpected
                  and all(row['pass_'] for row in rows) and unchanged and (synth is None or synth['pass_']),
                  inputs=inputs, source_unchanged=unchanged, commands=commands, cases=rows,
                  inventory_ok=inventory_ok, unexpected=unexpected, synth_preprocessing=synth,
                  scope='Actual simulation-only diagnostic controls. Expected error messages are not production pin-run passes.')
    (out/'summary.json').write_text(json.dumps(result, indent=2)+'\n')
    print('PASS' if result['pass_'] else 'FAIL', 'cases', len(rows), 'unexpected outcomes', sum(not x['pass_'] for x in rows), out/'summary.json')
    return 0 if result['pass_'] else 1


if __name__ == '__main__':
    sys.exit(main())
