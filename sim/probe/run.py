#!/usr/bin/env python3
"""SD probe simulation (docs/sd-probe.md): Verilator build of tb_sd_probe,
four APF host timings, the decoder run end to end on the saved log against
a pattern ROM (start-up load and every read), then planted faults that the
test must reject.

    sim/probe/run.py [--tools DIR] [--no-mutate]
"""
import argparse
from pathlib import Path
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
B = ROOT / 'build/probe'
ROM_SIZE = 0x100600   # tb_sd_probe ROM_SIZE
SOURCES = ['sim/probe/tb_sd_probe.sv', 'sim/probe/mf_datatable_model.sv', 'rtl/probe/sd_probe.sv',
           'rtl/apf/core_bridge_cmd.v', 'rtl/apf/common.v']
CONFIGS = [
    [],                                                            # lat 40, polled back to back
    ['+lat=0', '+pocketsave'],                                     # log saved as the Pocket does
    ['+lat=20000', '+jitter=5000', '+poll=7', '+gap=3', '+errat=9',  # slow, jittery, one APF error,
     '+lgap=3', '+lstall=5000'],                                   # gappy start-up load with a stall
    ['+lat=3000', '+jitter=30000', '+poll=50', '+gap=5', '+lgap=2000', '+lgapevery=512', '+pocketsave'],  # load gaps over GAP_LONG
]
# (name, original line fragment, planted fault)
MUTATIONS = [
    ('done trusted before it drops', 'if (low_seen && tgt_done) begin', 'if (tgt_done) begin'),
    ('random offsets not aligned', 'wire [31:0] rnd_off = lfsr & mask & align_mask;',
     "wire [31:0] rnd_off = lfsr & mask & ~32'd3;"),
    ('window too wide', 'wire in_window = bridge_addr[31:18] == WINDOW[31:18];',
     'wire in_window = bridge_addr[31:20] == WINDOW[31:20];'),
    ('acknowledge time off by one', 'begin ack_seen <= 1; t_ack <= t; end',
     "begin ack_seen <= 1; t_ack <= t + 1'b1; end"),
    ('sequential read past the end', 'if (seq_off + len > rom_size) begin',
     'if (seq_off > rom_size) begin'),
    ('largest load gap not kept', 'if (gap > l_gap) begin', 'if (gap != l_gap) begin'),
    ('load window takes the log slot', "wire in_load = bridge_addr[31:29] == LOAD_BASE[31:29];",
     "wire in_load = bridge_addr[31] == LOAD_BASE[31];"),
]


def build(tools, out, sources):
    cmd = [str(tools / 'verilator'), '--binary', '--timing', '-O3', '-j', '8', '-Wno-fatal',
           '-Wno-WIDTHEXPAND', '-Wno-WIDTHTRUNC', '-Wno-UNUSEDSIGNAL', '--top-module', 'tb_sd_probe',
           '--Mdir', str(out), *map(str, sources)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout[-3000:] + r.stderr[-3000:])
    return out / 'Vtb_sd_probe'


def run(sim, args):
    r = subprocess.run([str(sim), *args], capture_output=True, text=True)
    out = r.stdout + r.stderr
    return r.returncode == 0 and 'PASS' in out, out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--tools', type=Path, default=Path.cwd() / 'build/tools/oss-cad-suite/bin')
    ap.add_argument('--no-mutate', action='store_true')
    a = ap.parse_args()
    B.mkdir(parents=True, exist_ok=True)
    sim = build(a.tools, B / 'obj', [ROOT / s for s in SOURCES])
    rom = B / 'pattern.rom'
    rom.write_bytes(b''.join(struct.pack('<I', (i * 2654435761 + 12345) & 0xffffffff) for i in range(ROM_SIZE // 4)))
    for i, cfg in enumerate(CONFIGS):
        log = B / f'log{i}.bin'
        ok, out = run(sim, cfg + [f'+log={log}'])
        print(next((l for l in out.splitlines() if l.startswith('PASS')), out[-2000:]))
        if not ok:
            sys.exit(f'FAIL: config {cfg}')
        d = subprocess.run([sys.executable, str(ROOT / 'tools/sd-probe/decode.py'), str(log), '--rom', str(rom)],
                           capture_output=True, text=True)
        check = [l for l in d.stdout.splitlines() if l.startswith('data check')]
        want = f'{28 - (1 if "+errat=9" in cfg else 0)} of {28 - (1 if "+errat=9" in cfg else 0)} reads match'
        lcheck = [l for l in d.stdout.splitlines() if l.startswith('start-up load check')]
        if d.returncode or not check or want not in check[0] or not lcheck or 'sum matches' not in lcheck[0]:
            sys.exit(f'FAIL: decoder on {log}:\n{d.stdout}{d.stderr}')
        if i == 2:
            print(d.stdout)
    print(f'decoder: every read verified against the pattern ROM in all {len(CONFIGS)} logs')
    if a.no_mutate:
        return
    caught = 0
    for name, old, new in MUTATIONS:
        d = B / 'mutant'
        shutil.rmtree(d, ignore_errors=True)
        d.mkdir(parents=True)
        text = (ROOT / 'rtl/probe/sd_probe.sv').read_text()
        if text.count(old) != 1:
            sys.exit(f'mutation anchor not found: {old}')
        (d / 'sd_probe.sv').write_text(text.replace(old, new))
        srcs = [d / 'sd_probe.sv' if s == 'rtl/probe/sd_probe.sv' else ROOT / s for s in SOURCES]
        msim = build(a.tools, d / 'obj', srcs)
        results = [run(msim, cfg)[0] for cfg in CONFIGS]
        rejected = not all(results)
        caught += rejected
        print(f"mutation '{name}': {'caught' if rejected else 'NOT CAUGHT'}")
    if caught != len(MUTATIONS):
        sys.exit(f'FAIL: {len(MUTATIONS) - caught} planted faults passed')
    print(f'all {len(MUTATIONS)} planted faults caught')


if __name__ == '__main__':
    main()
