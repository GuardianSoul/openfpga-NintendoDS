#!/usr/bin/env python3
"""Geometry-engine cost per command body on the RTL (docs/unit-scorecard.md).

    tools/scorecard/gxbodies.py TB OUTDIR

TB is tb_geom (sim/gpu3d/geom.mk) built with the core's engine parameters.
For each of unitgx's bodies (sw/tests/unitgx: gxtime's, DS values in hwref
run 8) it writes two GX traces (NDSGX001: gxtime's reset state, the test's
setup, n bodies, END, SWAP, one frame record) with n1 and n2 bodies, runs TB
--prof on each and prints the engine's busy clocks per body:
(busy(n2) - busy(n1)) / (n2 - n1), in clk_sys (67 MHz; a DS system cycle is
2). The core's CPU-visible GX timing is a model (GX_CHEAP) and its store
spills to SDRAM, so only the engine's own cycles show its speed.
"""
import re
import struct
import subprocess
import sys
from pathlib import Path

E = None
def XY(x, y): return (x & 0xFFFF) | ((y & 0xFFFF) << 16)
def P10(x, y, z): return (x & 0x3FF) | ((y & 0x3FF) << 10) | ((z & 0x3FF) << 20)
Q = 0x400
ID44 = [0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0, 0x1000]
def V16(x, y, z): return [(0x23, [XY(x, y), z & 0xFFFFFFFF])]
TRI = V16(0, 0, 0) + V16(Q, 0, 0) + V16(0, Q, 0)
NRM = [(0x21, [P10(0, 0, -511)])]
S0 = [(0x41, []), (0x10, [0]), (0x15, []), (0x10, [3]), (0x15, []), (0x10, [2]), (0x15, []),
      (0x60, [0 | (0 << 8) | (255 << 16) | (191 << 24)]),
      (0x29, [0x001F00C0]), (0x2A, [0]), (0x2B, [0]), (0x20, [0x7FFF]),
      (0x30, [0x7FFF | (0x2108 << 16)]), (0x31, [0]),
      (0x32, [P10(0, 0, -511) | (0 << 30)]), (0x32, [P10(0, -511, 0) | (1 << 30)]),
      (0x32, [P10(-511, 0, 0) | (2 << 30)]), (0x32, [P10(300, 300, -300) | (3 << 30)]),
      (0x33, [0x7FFF | (0 << 30)]), (0x33, [0x001F | (1 << 30)]),
      (0x33, [0x03E0 | (2 << 30)]), (0x33, [0x7C00 | (3 << 30)])]
BEGIN = [(0x40, [0])]
# name, setup, prefix, body (as unitgx v3)
TESTS = [
    ('MULT44M2', [], [], [(0x18, ID44)]),
    ('LOAD44', [], [], [(0x16, ID44)]),
    ('TRIV16', [], BEGIN, TRI),
    ('TRIOFF', [], BEGIN, V16(0x2000, 0, 0) + V16(0x2400, 0, 0) + V16(0x2000, Q, 0)),
    ('TRIXCLIP', [], BEGIN, V16(0xE00, 0, 0) + V16(0x1400, 0, 0) + V16(0xE00, Q, 0)),
    ('TRINRML4', [(0x29, [0x001F00CF])], BEGIN, NRM + V16(0, 0, 0) + NRM + V16(Q, 0, 0) + NRM + V16(0, Q, 0)),
    ('NORMALL0', [], BEGIN, NRM),
    ('NORMALL1', [(0x29, [0x001F00C1])], BEGIN, NRM),
    ('NORMALL4', [(0x29, [0x001F00CF])], BEGIN, NRM),
    ('TEXCOORD', [], [], [(0x22, [0])]),
    ('COLOR', [], [], [(0x20, [0x1234])]),
    ('BEGINEND', [], [], [(0x40, [0]), (0x41, [])]),
]


def entries(cmds):
    out = []
    for c, ps in cmds:
        out += [(c, p) for p in ps] if ps else [(c, 0)]
    return out


def trace(path, setup, prefix, body, n):
    cmds = S0 + setup + prefix + body * n + [(0x41, []), (0x50, [0])]
    b = bytearray(b'NDSGX001')
    for c, p in entries(cmds):
        b += b'C' + struct.pack('<BI', c, p)
    b += b'F' + struct.pack('<5I', 1, 0, 0, 0, 0) + bytes(1 + 64 + 16 + 4 + 4 + 32 + 4 + 4)
    Path(path).write_bytes(b)


def busy(tb, path):
    r = subprocess.run([tb, '--trace', str(path), '--prof'], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(f"{path}: tb_geom failed ({r.returncode}): {r.stderr[-1000:]}")
    tot = 0.0
    found = False
    for l in r.stdout.splitlines():
        m = re.match(r'\s+cmd ([0-9A-F]{2})\s+(\d+) x\s+([\d.]+) cycles', l)
        if m:
            found = True
            tot += int(m.group(2)) * float(m.group(3))
    if not found or tot <= 0:
        raise RuntimeError(f"{path}: missing positive command profile")
    return tot, r


def main():
    tb, out = sys.argv[1], Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    for name, setup, prefix, body in TESTS:
        e = len(entries(body))
        n1, n2 = max(1, 300 // e), max(2, 900 // e)
        if prefix == BEGIN and len(body) >= 3:   # triangles: stay under 2,048 polygons
            n1, n2 = 100, 300
        t = []
        for n in (n1, n2):
            p = out / f'{name}_{n}.gx'
            trace(p, setup, prefix, body, n)
            v, r = busy(tb, p)
            (out / f'{name}_{n}.log').write_text(r.stdout + r.stderr)
            t.append(v)
        if t[1] <= t[0]:
            raise RuntimeError(f'{name}: nonpositive differential busy clocks: {t}')
        print(f'{name} {(t[1] - t[0]) / (n2 - n1):.2f} clk per body ({n1}/{n2} bodies)')


if __name__ == '__main__':
    main()
