#!/usr/bin/env python3
"""nds_cart AUX SPI equivalence (docs/ndsplay16.md): tb_cart_spi_eq runs a
reference nds_cart (REF, a git revision; module renamed nds_cart_ref) and this
tree's side by side on random SPI save scripts for every save type, IR on and
off. Each must print RESULT SAME.

    sim/ds/cart_spi_eq/run.py [--ref REV] [--seeds N] [--mutant FILE]
"""
import argparse, os, random, subprocess, sys
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
ap = argparse.ArgumentParser()
ap.add_argument('--ref', default='HEAD')
ap.add_argument('--seeds', type=int, default=4)
ap.add_argument('--mutant', help='an nds_cart.sv to test instead of rtl/ds/nds_cart.sv')
ap.add_argument('--only', help='SEED,TYPE,IR: one run, its whole output (with --trace: every save access)')
ap.add_argument('--trace', action='store_true')
ap.add_argument('--out', default=str(ROOT / 'build/cart_spi_eq'))
a = ap.parse_args()
out = Path(a.out).resolve(); out.mkdir(parents=True, exist_ok=True)
ref = subprocess.run(['git', '-C', str(ROOT), 'show', f'{a.ref}:rtl/ds/nds_cart.sv'], capture_output=True, text=True, check=True).stdout
(out / 'nds_cart_ref.sv').write_text(ref.replace('module nds_cart (', 'module nds_cart_ref (', 1))
dut = Path(a.mutant) if a.mutant else ROOT / 'rtl/ds/nds_cart.sv'
vl = os.environ.get('VERILATOR', str(ROOT / 'tools/verilator-locked'))
r = subprocess.run([vl, '--binary', '-j', '8', '-Wno-fatal', '-Wno-lint', '-Wno-style', '--top-module', 'tb_cart_spi_eq',
                    '--Mdir', str(out / 'obj'), str(HERE / 'tb_cart_spi_eq.sv'), str(out / 'nds_cart_ref.sv'), str(dut),
                    str(ROOT / 'rtl/ds/nds_dsp_add.sv')], capture_output=True, text=True)
if r.returncode:
    sys.exit(r.stdout[-3000:] + r.stderr[-3000:])

def script(rng, kind, ir):
    ops = []
    def cnt(hold): ops.append(0x1000 | (hold << 2) | rng.randrange(4) | (rng.randrange(2) << 3))
    def byte(b, last):
        if rng.random() < 0.3:
            ops.append(0x3000 | b | ((0 if last else 1) << 10) | (rng.randrange(4) << 8) | (rng.randrange(2) << 11))
        else:
            cnt(0 if last else 1); ops.append(0x2000 | b)
    def tx(bs):
        if ir and rng.random() < 0.8: bs = [0x00] + bs   # the IR byte: 0x00 passes the rest through
        for i, b in enumerate(bs): byte(b, i == len(bs) - 1)
        if rng.random() < 0.2: ops.append(0x4000 | rng.randrange(1, 64))
    ab = {1: 1, 2: 2, 3: 3}[kind]   # (EEPROM 128 KiB has 3: a third byte only reads past the chip)
    def addr(): return [rng.randrange(256) for _ in range(ab)]
    ops += [0x5000, 0x1004, 0x7000 | ir]   # the chip's blank (a new save type) ends first
    for _ in range(rng.randrange(60, 120)):
        c = rng.random()
        if c < 0.15: tx([0x06])
        elif c < 0.20: tx([0x04])
        elif c < 0.28: tx([0x05] + [0] * rng.randrange(1, 3))
        elif c < 0.31: tx([0x01, rng.randrange(256)])
        elif c < 0.48: tx([rng.choice([0x03, 0x0B]) if kind != 2 else 0x03] + addr() + [0] * rng.randrange(1, 12))
        elif c < 0.70: tx([rng.choice([0x02, 0x0A])] + addr() + [rng.randrange(256) for _ in range(rng.randrange(1, 12))])
        elif c < 0.74 and kind == 3:
            tx([0x06]); tx([rng.choice([0xDB, 0xDB, 0xD8])] + addr())
            ops += [0x5000, 0x1004, 0x7000 | ir]   # as games: poll the status until the erase ends (docs/ndsplay16.md)
        elif c < 0.78: tx([0x9F, 0, 0, 0])
        elif c < 0.84: tx([rng.randrange(256) for _ in range(rng.randrange(1, 6))])
        elif c < 0.88: ops.append(0x5000)
        elif c < 0.92: ops.append(0x6000 | rng.randrange(256))
        elif c < 0.95: ops.append(0x2000 | rng.randrange(256))   # a byte without a CNT write first
        else: ops.append(0x4000 | rng.randrange(1, 256))
    return ops

kinds = {1: 1, 2: 2, 3: 2, 4: 2, 5: 3, 6: 3, 7: 3}
bad = 0
for seed in range(a.seeds):
    for st in range(1, 8):
        for ir in (0, 1):
            if a.only and [seed, st, ir] != [int(x) for x in a.only.split(',')]: continue
            rng = random.Random(seed * 100 + st * 2 + ir)
            ops = script(rng, kinds[st], ir)
            loaded = rng.choice([0, 4 * rng.randrange(1, 4096), 512, 8192])
            (out / 'cfg.hex').write_text(f'{st:x}\n{ir:x}\n{loaded:x}\n{rng.randrange(1, 65536):x}\n')
            (out / 'script.hex').write_text(''.join(f'{o:04x}\n' for o in ops))
            r = subprocess.run([str(out / 'obj/Vtb_cart_spi_eq'), f'+nops={len(ops)}'] + (['+trace'] if a.trace else []), cwd=out, capture_output=True, text=True)
            res = [l for l in r.stdout.splitlines() if l.startswith('RESULT') or 'ref' in l]
            if a.only: print(r.stdout)
            ok = any(l.split()[:2] == ['RESULT', 'SAME:'] for l in res)
            bad += not ok
            print(f'seed {seed} type {st} ir {ir}: {len(ops)} ops: ' + ' | '.join(res[-3:]))
print('ALL SAME' if bad == 0 else f'{bad} runs DIFFER')
sys.exit(1 if bad else 0)
