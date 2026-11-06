#!/usr/bin/env python3
"""Exact old/current Pocket interpolation outputs and a visible RTL fault."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT/'build/audio-accumulator')
    args = parser.parse_args()
    os.setpriority(os.PRIO_PROCESS, 0, 10)
    args.out.mkdir(parents=True, exist_ok=False)
    def save(name, value):
        (args.out/name).write_text(json.dumps(value, indent=2)+'\n')
    def start(pid):
        return Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()[19]
    save('controller.json', dict(PID=os.getpid(), starttime=start(os.getpid()), NI=10, jobs=1, threads=1))
    before = subprocess.check_output(['git', 'show', 'bef2b6e0:rtl/pocket/nds_audio_interp.sv'], cwd=ROOT)
    helper = subprocess.check_output(['git', 'show', 'bef2b6e0:rtl/ds/nds_dsp_add.sv'], cwd=ROOT)
    source = (ROOT/'rtl/pocket/nds_audio_interp.sv').read_bytes()
    fixture = ROOT/'sim/pocket_ds/tb_audio_interp_equiv.sv'
    (args.out/'before.sv').write_bytes(before.replace(b'module nds_audio_interp (', b'module nds_audio_interp_before (').replace(b'nds_dsp_add #(', b'nds_dsp_add_before #('))
    (args.out/'helper-before.sv').write_bytes(helper.replace(b'module nds_dsp_add #(', b'module nds_dsp_add_before #('))
    needle = b'{{10{delta_l[16]}}, delta_l}'
    assert source.count(needle) == 1
    fault = source.replace(needle, b"{10'd0, delta_l}")
    (args.out/'zero-extend-mutant.sv').write_bytes(fault)
    tools = Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin'
    processes = []
    def call(command, tag):
        command = list(map(str, command))
        with (args.out/(tag+'.log')).open('w') as log:
            begin = time.monotonic()
            proc = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, cwd=ROOT)
            row = dict(PID=proc.pid, starttime=start(proc.pid), NI=os.getpriority(os.PRIO_PROCESS, proc.pid), argv=command)
            save('active.json', row)
            rc = proc.wait(timeout=60)
        row.update(exit=rc, reaped=True, wall_seconds=time.monotonic()-begin)
        processes.append(row); save('processes.json', processes)
        return rc, (args.out/(tag+'.log')).read_text()
    results = {}
    for name, rtl in [('equivalent', ROOT/'rtl/pocket/nds_audio_interp.sv'), ('zero-extend-mutant', args.out/'zero-extend-mutant.sv')]:
        model = args.out/(name+'.vvp')
        rc, log = call([tools/'iverilog', '-g2012', '-s', 'tb_audio_interp_equiv', '-o', model,
                       args.out/'before.sv', args.out/'helper-before.sv', rtl, fixture], name+'.compile')
        assert rc == 0, log[-2000:]
        rc, log = call([tools/'vvp', model]+(['+expect_mutant'] if name != 'equivalent' else []), name+'.run')
        if name == 'equivalent':
            assert rc == 0 and 'PASS AUDIO_EQ' in log, log[-2000:]
        else:
            assert rc != 0 and 'AUDIO_EQ_OUTPUT' in log, log[-2000:]
        results[name] = dict(exit=rc, output=log.strip())
    sha = lambda v: hashlib.sha256(v).hexdigest()
    save('receipt.json', dict(status='PASS every output cycle/invariant; compiled actual sign-extension fault changes visible output and is caught',
         before='bef2b6e0', before_sha256=sha(before), after_sha256=sha(source), fixture_sha256=sha(fixture.read_bytes()), results=results,
         limits='No new mapped area/DSP/STA or DS sound timing/cadence acceptance. Outer interpolation only.'))
    print((args.out/'receipt.json').read_text(), flush=True)


if __name__ == '__main__':
    main()
