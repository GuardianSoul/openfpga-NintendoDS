#!/usr/bin/env python3
# load3d_scn.py OUTDIR: hwref load3d v3's loads (docs/hw-reference.md run 24) as G3DSCN01 bench scenes:
# N overlapping quads covering lines 0-191, S px wide, centred, each nearer (w = 1); untextured opaque, and
# textured (64x64 direct colour, repeat, 1:1 along the quad, a different row band per quad)
import struct, sys, os
out = sys.argv[1]
def scene(n, s, tex):
    b = bytearray(b'G3DSCN01')
    dispcnt = 1 if tex else 0                       # texture mapping on
    b += struct.pack('<6I', dispcnt, 0, 0x3F000000 | (31 << 16), 0x7FFF, 0, 0)
    b += bytes(64 + 16 + 32)                        # toon, edge, fog table
    t = bytearray(512 * 1024)
    if tex:                                         # 64x64 RGB555 at VRAM 0, a pattern so texels differ
        for y in range(64):
            for x in range(64):
                c = ((x * 5) & 31) | (((y * 3) & 31) << 5) | ((((x ^ y) * 7) & 31) << 10) | 0x8000
                struct.pack_into('<H', t, (y * 64 + x) * 2, c)
    b += t + bytes(128 * 1024)
    b += struct.pack('<I', n)
    x0, x1 = 128 - s // 2, 128 - s // 2 + s
    for i in range(n):
        z = 0xE00000 - (i * 0x1C00000 // max(n, 1)) // 2      # nearer each time (24-bit)
        attr = (31 << 16) | ((i & 63) << 24)
        texparam = 0
        if tex:   # format 7 (direct), 64x64 (size 3 = 8<<3), repeat s and t, VRAM offset 0
            texparam = (7 << 26) | (3 << 20) | (3 << 23) | (1 << 16) | (1 << 17)
        b += struct.pack('<IIIIBB', 4, attr, texparam, 0, 1, 0)
        t0 = (i * 7 % 64) * 16
        for (x, y, ss, tt) in ((x0, 0, 0, t0), (x0, 192, 0, t0 + 192 * 16), (x1, 192, s * 16, t0 + 192 * 16), (x1, 0, s * 16, t0)):
            b += struct.pack('<iiIIiiihh', x, y, z, 0x1000, 400, 300, 200, ss, tt)
    return b
def scene_b(n, s, texparam, scatter=False):
    # run 24's group B: load3d's texture data (bank A at slot 0: u16 (i * 2654435761) >> 16; bank E at palette
    # slots 0-3: u16 i * 40503), texcoords 0..0x0FFF (255.9 texels) across the quad and down the frame
    b = bytearray(b'G3DSCN01')
    b += struct.pack('<6I', 1, 0, 0x3F000000 | (31 << 16), 0x7FFF, 0, 0)
    b += bytes(64 + 16 + 32)
    t = bytearray(512 * 1024); pl = bytearray(128 * 1024)
    for i in range(0x10000): struct.pack_into('<H', t, 2 * i, ((i * 2654435761) & 0xFFFFFFFF) >> 16)
    for i in range(0x8000): struct.pack_into('<H', pl, 2 * i, (i * 40503) & 0xFFFF)
    b += t + pl
    b += struct.pack('<I', n)
    x0, x1 = (256 - s) // 2, (256 - s) // 2 + s
    for i in range(n):
        z = 0xE00000 - (i * 0x1C00000 // max(n, 1)) // 2
        b += struct.pack('<IIIIBB', 4, (31 << 16) | (3 << 6) | ((i & 63) << 24), texparam, 0, 1, 0)
        so = ((i * 37) & 255) << 4 if scatter else 0          # run 44's group T: quad i samples its own region
        to = ((i * 91) & 255) << 4 if scatter else 0
        for (x, y, ss, tt) in ((x0, 0, so, to), (x0, 192, so, to + 0xFFF), (x1, 192, so + 0xFFF, to + 0xFFF), (x1, 0, so + 0xFFF, to)):
            b += struct.pack('<iiIIiiihh', x, y, z, 0x1000, 400, 300, 200, ss, tt)
    return b
for nm, tp in (('tex7_256', 7 << 26 | 5 << 20 | 5 << 23 | 3 << 16), ('tex3_256', 3 << 26 | 5 << 20 | 5 << 23 | 3 << 16)):
    for n, s in ((192, 4), (96, 16), (32, 48)):
        open(os.path.join(out, f"lt4_{nm}_scatter_n{n:03d}_s{s:03d}.scn"), 'wb').write(scene_b(n, s, tp, True))
for nm, tp in (('tex7_256', 7 << 26 | 5 << 20 | 5 << 23 | 3 << 16), ('tex3_256', 3 << 26 | 5 << 20 | 5 << 23 | 3 << 16),
               ('tex5_256', 5 << 26 | 5 << 20 | 5 << 23 | 3 << 16), ('tex7_8', 7 << 26 | 3 << 16), ('tex3_8', 3 << 26 | 3 << 16)):
    for n, s in ((32, 48), (128, 4)):
        open(os.path.join(out, f"lb_{nm}_n{n:03d}_s{s:03d}.scn"), 'wb').write(scene_b(n, s, tp))
def scene_p(n, s, shape):
    # run 44's group P: parallelograms (top 16 px right of x0, bottom 16 px left) or each quad as two triangles
    b = bytearray(b'G3DSCN01')
    b += struct.pack('<6I', 0, 0, 0x3F000000 | (31 << 16), 0x7FFF, 0, 0)
    b += bytes(64 + 16 + 32) + bytes(512 * 1024) + bytes(128 * 1024)
    x0 = (256 - s) // 2
    polys = []
    for i in range(n):
        z = 0xE00000 - (i * 0x1C00000 // max(n, 1)) // 2
        if shape == 'parallelogram':
            polys.append([(x0 + 16, 0), (x0 - 16, 192), (x0 - 16 + s, 192), (x0 + 16 + s, 0)])
        else:
            polys.append([(x0, 0), (x0, 192), (x0 + s, 192)]); polys.append([(x0, 0), (x0 + s, 192), (x0 + s, 0)])
    b += struct.pack('<I', len(polys))
    for i, vs in enumerate(polys):
        b += struct.pack('<IIIIBB', len(vs), (31 << 16) | (3 << 6) | ((i & 63) << 24), 0, 0, 1, 0)
        for (x, y) in vs:
            b += struct.pack('<iiIIiiihh', x, y, 0xE00000 - i * 0x1000, 0x1000, 400, 300, 200, 0, 0)
    return b
for sh in ('parallelogram', 'triangles'):
    for n, s in ((160, 4), (192, 4), (80, 16), (96, 16), (96, 4), (112, 4)):
        if sh == 'parallelogram' and s == 4 and n < 160: continue
        open(os.path.join(out, f"lp_{sh}_n{n:03d}_s{s:03d}.scn"), 'wb').write(scene_p(n, s, sh))
loads = [(192, 1), (224, 1), (192, 4), (224, 4), (96, 16), (112, 16), (32, 64), (40, 64), (8, 256), (12, 256), (128, 4), (32, 48)]
for n, s in loads:
    for tex in (0, 1):
        open(os.path.join(out, f"l{'t' if tex else 'u'}_n{n:03d}_s{s:03d}.scn"), 'wb').write(scene(n, s, tex))
print(len(loads) * 2, 'scenes')
