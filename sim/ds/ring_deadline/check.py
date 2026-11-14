#!/usr/bin/env python3
"""One bounded worker, immutable unit sources, actual RTL mutations."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import resource
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
STATUS = Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Raster.json')
BIN = Path('build/tools/oss-cad-suite/bin')
FAULTS = {
    'word': ('assign rg_wdata = {9\'d0,stage_q};', "assign rg_wdata = {9'd0,stage_q ^ 23'd1};"),
    'slot': ("!(consumer_valid && consumer == 2'(i)) &&", "1'b1 &&"),
    'ticket': ('wire ticket_done = ticket_rem == 0 || ticket_rem[6:5] == 2\'b11;', "wire ticket_done = 1'b1;"),
    'return': ('skid_pop ? {r_slot,r_block,r_written[2:0]}', "skid_pop ? {r_slot ^ 2'd1,r_block,r_written[2:0]}"),
    'capture': ('if (l3d_done) consumer_valid <= 0;', "if (l3d_raddr == 255) consumer_valid <= 0;"),
    'full': ('if (r_block == 31) state[r_slot] <= FULL;', 'if (r_block == 0) state[r_slot] <= FULL;'),
    'skid': ('if (skid_push) begin skid[skid_wp] <= rg_rdata[22:0];', 'if (skid_push && r_in != 0) begin skid[skid_wp] <= rg_rdata[22:0];'),
}


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def status(worker=None):
    d = json.loads(STATUS.read_text())
    d.update(workers=[] if worker is None else [worker],
             disk_growth_bound_bytes=0 if worker is None else 256 << 20,
             updated_at=time.time())
    s = json.dumps(d, separators=(',', ':')) + '\n'
    assert len(s.encode()) <= 2048
    q = STATUS.with_suffix('.tmp.RasterWorker')
    q.write_text(s)
    q.replace(STATUS)


def admission():
    mem = int(next(l.split()[1] for l in Path('/proc/meminfo').read_text().splitlines()
                   if l.startswith('MemAvailable:'))) * 1024
    assert mem >= 12 << 30, ('RAM', mem)
    reserved = 0
    for p in STATUS.parent.glob('*.json'):
        if p == STATUS:
            continue
        d = json.loads(p.read_text())
        if d.get('workers'):
            reserved += d.get('disk_growth_bound_bytes', 0)
    free = shutil.disk_usage(ROOT).free
    assert free - reserved - (256 << 20) >= 10 << 30, ('disk', free, reserved)
    return {'MemAvailable': mem, 'disk_free': free, 'other_reservations': reserved,
            'growth_bound': 256 << 20, 'floor': 10 << 30}


def run(cmd, log, build=False):
    def start():
        with log.open('w') as f:
            p = subprocess.Popen([str(c) for c in cmd], cwd=ROOT, stdout=f, stderr=subprocess.STDOUT,
                                 preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE,(0,0)))
            status({'host': socket.gethostname(), 'PID': p.pid, 'parent_PID': os.getpid(),
                    'phase': 'unit-build' if build else 'unit-run', 'log': str(log), 'nice': 10, 'threads': 1})
            try:
                return p.wait(timeout=120)
            except subprocess.TimeoutExpired:
                p.terminate()
                p.wait(timeout=10)
                raise
    if build:
        with (Path.home()/'.cache/nds-sim-build.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            admission()
            return start()
    return start()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--fault', choices=FAULTS)
    args = ap.parse_args()
    os.nice(10)
    B = args.out.resolve()
    assert not B.exists(), B
    B.mkdir(parents=True)
    admit = admission()
    paths = ['rtl/gpu3d/gpu3d_ram.sv', 'rtl/ds/nds_g3d_ring_deadline.sv', 'sim/ds/ring_deadline/bench.sv']
    manifest = {p: sha(ROOT/p) for p in paths}
    for p in paths:
        shutil.copyfile(ROOT/p, B/Path(p).name)
    if args.fault:
        p = B/'nds_g3d_ring_deadline.sv'
        a, b = FAULTS[args.fault]
        s = p.read_text()
        assert a in s, (args.fault, a)
        p.write_text(s.replace(a, b))
    (B/'source.json').write_text(json.dumps({'files': manifest, 'fault': args.fault,
        'actual_model_sources': {p.name: sha(p) for p in B.glob('*.sv')}, 'admission': admit}, indent=2)+'\n')
    try:
        rc = run([BIN/'iverilog', '-g2012', '-s', 'ring_deadline_tb', '-o', B/'model.vvp',
                  B/'gpu3d_ram.sv', B/'nds_g3d_ring_deadline.sv', B/'bench.sv'], B/'build.log', True)
        assert rc == 0, (rc, (B/'build.log').read_text()[-2500:])
        rc = run([BIN/'vvp', B/'model.vvp'], B/'run.log')
        log = (B/'run.log').read_text()
        ok = rc != 0 and ('FATAL:' in log or 'ERROR:' in log) if args.fault else rc == 0 and 'RING_DEADLINE_PASS' in log and 'ERROR:' not in log
        (B/'result.json').write_text(json.dumps({'returncode': rc, 'fault': args.fault, 'PASS': ok,
            'log_sha256': sha(B/'run.log'), 'model_sha256': sha(B/'model.vvp')}, indent=2)+'\n')
        print(log[-2500:], flush=True)
        assert ok, B
    finally:
        status()


if __name__ == '__main__':
    main()
