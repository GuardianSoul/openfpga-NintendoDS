#!/usr/bin/env python3
"""The DS's 3D render budget per line for a bench scene, against the core's measured time (docs/ds-rules.md, the
3D line budget row; hwref run 24).

    sim/gpu3d/ds_budget.py SCENE.scn [BENCH_OUT.txt]

DS cost of line y: for every polygon covering it, 8.0 system ticks + 0.99 per pixel of its span on that line, a span
under 4 px costing as 4 (run 24's thin quads); x2 for core clocks (67.03 MHz against 33.51). A span's pixels are those
its edges cross within the line (from the leftmost x of its left edge over the line to the rightmost of its right
edge): a sloped edge adds a partly covered pixel (run 44's parallelograms: 4 px quads cost as 5). Textures cost
nothing, whatever the texel pattern (run 44), and a triangle costs as a quad. With BENCH_OUT (the
bench's --line-profile output for the same scene), each 8-line group's core cycles (stream + edge + span + pixel +
final) beside the DS's, and the running margin of each against its own lead (DS 42.6 lines, the core 48: line 215).
"""
import struct, sys
LINE = 4260                     # core clocks a line
def load(path):
    b = open(path, 'rb').read()
    assert b[:8] == b'G3DSCN01'
    o = 8 + 24 + 64 + 16 + 32 + 512 * 1024 + 128 * 1024
    n, = struct.unpack_from('<I', b, o); o += 4
    polys = []
    for _ in range(n):
        nv, attr, tp, tpal, fac, wb = struct.unpack_from('<IIIIBB', b, o); o += 18
        vs = []
        for _ in range(nv):
            x, y, z, w, r, g, bl, s, t = struct.unpack_from('<iiIIiiihh', b, o); o += 32
            vs.append((x, y))
        polys.append(vs)
    return polys
def spans(vs):
    import math
    ys = [v[1] for v in vs]; y0, y1 = min(ys), max(ys)
    out = {}
    def xs_at(yc):
        xs = []
        for i in range(len(vs)):
            (xa, ya), (xb, yb) = vs[i], vs[(i + 1) % len(vs)]
            if (ya <= yc <= yb) or (yb <= yc <= ya):
                xs.append(xa if ya == yb else xa + (yc - ya) * (xb - xa) / (yb - ya))
        return xs
    for y in range(max(y0, 0), min(max(y1, y0 + 1), 192)):
        xs = xs_at(min(max(y, y0), y1)) + xs_at(min(max(y + 1, y0), y1))     # the edges over the line
        if len(xs) >= 2:
            l, r = max(math.floor(min(xs) + 1e-9), 0), min(math.ceil(max(xs) - 1e-9), 256)
            out[y] = max(r - l, 0)
        elif y0 == y1:
            out[y] = max(v[0] for v in vs) - min(v[0] for v in vs)
    return out
polys = load(sys.argv[1])
ds = [0.0] * 192; npl = [0] * 192; px = [0.0] * 192
for vs in polys:
    for y, w in spans(vs).items():
        ds[y] += 2 * (8.0 + 0.99 * max(w, 4)); npl[y] += 1; px[y] += w
core = None
if len(sys.argv) > 2:
    core = {}
    for l in open(sys.argv[2]):
        if l.strip().startswith('lines') and 'per line' in l:
            f = l.replace('-', ' ').split()
            y0 = int(f[1]); v = [int(f[i]) for i in (4, 6, 8, 10, 11)]
            core[y0] = sum(v) * 8            # the profile prints per-line means of each 8-line group
print(f"{sys.argv[1].split('/')[-1]}: {len(polys)} polygons; DS frame {sum(ds)/1000:.0f}K clk"
      + (f", core {sum(core.values())/1000:.0f}K clk" if core else ''))
mds, mco, cds, cco = 42.6 * LINE, 48 * LINE, 0.0, 0.0
worst_ds, worst_co = 1e18, 1e18
for g in range(0, 192, 8):
    d = sum(ds[g:g + 8]); cds += d
    s = f"lines {g:3d}-{g+7:3d}: polys/line {sum(npl[g:g+8])/8:6.1f} px/line {sum(px[g:g+8])/8:6.0f}  DS {d/8:6.0f}/line"
    mds = 42.6 * LINE + (g + 8) * LINE - cds; worst_ds = min(worst_ds, mds)
    if core:
        c = core.get(g, 0); cco += c
        mco = 48 * LINE + (g + 8) * LINE - cco; worst_co = min(worst_co, mco)
        s += f"  core {c/8:6.0f}/line ({c/max(d,1):4.2f}x)  margin DS {mds/LINE:6.1f} core {mco/LINE:6.1f} lines"
    print(s)
print(f"worst margin: DS {worst_ds/LINE:.1f} lines" + (f", core {worst_co/LINE:.1f} lines" if core else '')
      + "  (negative: late lines; the DS's is its own underflow)")
