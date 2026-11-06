#!/usr/bin/env python3
"""Compare the carry-chain companion against its pinned pre-change DSP RTL."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', default='b19b8fef')
    parser.add_argument('--out', type=Path, default=ROOT/'build/dsp-legality')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    proc = {'PID': os.getpid(), 'starttime': Path('/proc/self/stat').read_text().split()[21],
            'NI': os.getpriority(os.PRIO_PROCESS, 0), 'jobs': 1, 'threads': 1}
    (args.out/'process.json').write_text(json.dumps(proc, indent=2)+'\n')
    prior = subprocess.check_output(['git', 'show', args.before+':rtl/ds/nds_dsp_add.sv'], cwd=ROOT)
    source = (ROOT/'rtl/ds/nds_dsp_add.sv').read_bytes()
    (args.out/'before.sv').write_bytes(prior.replace(b'module nds_dsp_add #(', b'module nds_dsp_add_before #('))
    fault = source.replace(b"assign s = {1'b0, a} + {1'b0, b};", b"assign s = {1'b0, W'(a+b)};")
    assert fault != source
    (args.out/'wrong-carry.sv').write_bytes(fault)
    tools = Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin'
    results = {}
    for name, rtl in [('equivalent', ROOT/'rtl/ds/nds_dsp_add.sv'),
                      ('wrong-carry', args.out/'wrong-carry.sv')]:
        command = [str(tools/'iverilog'), '-g2012', '-s', 'tb_dsp_add_equiv',
                   '-o', str(args.out/(name+'.vvp')), str(args.out/'before.sv'),
                   str(rtl), str(ROOT/'sim/ds/tb_dsp_add_equiv.sv')]
        with (args.out/(name+'.compile.log')).open('w') as log:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
        run = subprocess.run([str(tools/'vvp'), str(args.out/(name+'.vvp'))], capture_output=True, text=True)
        (args.out/(name+'.run.log')).write_text(run.stdout+run.stderr)
        if name == 'equivalent':
            assert run.returncode == 0 and 'PASS ADD_EQ' in run.stdout, run.stdout
        else:
            assert run.returncode != 0 and 'ADD_EQ W=' in run.stdout, run.stdout
        results[name] = {'compile_exit': 0, 'run_exit': run.returncode, 'output': run.stdout.strip()}
    receipt = {'status': 'PASS equivalent / caught compiled actual wrong-carry mutant',
               'before': args.before, 'before_sha256': hashlib.sha256(prior).hexdigest(),
               'after_sha256': hashlib.sha256(source).hexdigest(),
               'fixture_sha256': hashlib.sha256((ROOT/'sim/ds/tb_dsp_add_equiv.sv').read_bytes()).hexdigest(),
               'results': results, 'limits': 'No area, DSP mapping, placement or STA measurement; private companion for a major cut.'}
    (args.out/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
