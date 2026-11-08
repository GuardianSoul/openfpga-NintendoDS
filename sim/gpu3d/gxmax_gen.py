#!/usr/bin/env python3
"""DS-maximum geometry streams as census GX traces (NDSGX001) for tb_geom: each a frame at the DS's vertex limit
(6,144 vertices: 1,536 quads or 2,048 triangles) in one command mix, so --dstime (the DS, melonDS's exact command
timing) and --trace --fstat (our engine) time the same entries.

    sim/gpu3d/gxmax_gen.py OUTDIR
"""
import os, struct, sys
out = sys.argv[1]
def f16(x): return int(round(x * 4096)) & 0xFFFF            # 1.3.12 vertex coordinate
def trace(name, body):
    b = bytearray(b'NDSGX001')
    b += b'V' + struct.pack('<I', 0) + bytes(9)
    for sz in (0x20000, 0x20000, 0x20000, 0x20000, 0x10000, 0x4000, 0x4000, 0x8000, 0x4000): b += bytes(sz)
    def C(c, p=0): b.extend(b'C' + struct.pack('<BI', c, p & 0xFFFFFFFF))
    def F(frame):
        b.extend(b'F' + struct.pack('<IIIII', frame, 0, 0, 0, 0) + b'\0' + bytes(64 + 16) + struct.pack('<II', 0, 0)
                 + bytes(32) + struct.pack('<II', 0x3F000000 | (31 << 16), 0x7FFF))
    for fr in range(3):                          # three frames: the first is the setup, the next two are timed
        C(0x10, 0); C(0x15); C(0x10, 2); C(0x15); C(0x60, 0xBFFF0000)
        body(C)
        C(0x50, 0); F(2 * fr + 1)
    open(os.path.join(out, name + '.gx.bin'), 'wb').write(b)
def quads(n, vtx='16', normal=False, tex=False, mtx=0, clip=False, light=False):
    def body(C):
        if light:
            C(0x32, (0x1FF << 0) | (0x000 << 10) | (0x200 << 20))   # light 0 direction
            C(0x33, 0x7FFF)                                        # light 0 colour
            C(0x30, 0x7FFF | (0x4210 << 16)); C(0x31, 0)
        C(0x29, 0x001F00C0 | (1 if light else 0))
        for i in range(n):
            if mtx and i % mtx == 0:
                if i: C(0x12, 1)                   # pop
                C(0x11)                            # push
                for k in range(12): C(0x19, [0x1000, 0, 0, 0, 0x1000, 0, 0, 0, 0x1000, (i % 7) * 16, 0, 0][k])
            C(0x40, 1)
            C(0x20, (i * 37) & 0x7FFF)
            x0 = -0.9 + (i % 32) * 0.056; y0 = -0.9 + ((i // 32) % 32) * 0.056; d = 0.05
            if clip: x0 += 1.0 if i % 2 else 0.0
            z = -0.5 - (i % 64) * 0.005
            for (x, y, s_, t_) in ((x0, y0, 0, 0), (x0, y0 + d, 0, 0x100), (x0 + d, y0 + d, 0x100, 0x100), (x0 + d, y0, 0x100, 0)):
                if normal: C(0x21, (0x1FF) | (0x1FF << 10) | (0 << 20))
                if tex: C(0x22, s_ | (t_ << 16))
                if vtx == '16':
                    C(0x23, f16(x) | (f16(y) << 16)); C(0x23, f16(z))
                elif vtx == '10':
                    q = lambda v: (int(round(v * 64)) & 0x3FF)
                    C(0x24, q(x) | (q(y) << 10) | (q(z) << 20))
                elif vtx == 'xy':
                    C(0x25, f16(x) | (f16(y) << 16))
            C(0x41)
        if mtx: C(0x12, 1)
    return body
def tris(n):
    def body(C):
        C(0x29, 0x001F00C0); C(0x40, 0)
        for i in range(n):
            C(0x20, (i * 37) & 0x7FFF)
            x0 = -0.9 + (i % 32) * 0.056; y0 = -0.9 + ((i // 32) % 64) * 0.028; d = 0.04; z = -0.5
            for (x, y) in ((x0, y0), (x0, y0 + d), (x0 + d, y0 + d)):
                C(0x23, f16(x) | (f16(y) << 16)); C(0x23, f16(z))
        C(0x41)
    return body
trace('gxmax_quads16', quads(1536))
trace('gxmax_tris16', tris(2048))
trace('gxmax_quads10', quads(1536, vtx='10'))
trace('gxmax_quadsxy', quads(1536, vtx='xy'))
trace('gxmax_tex', quads(1536, tex=True))
trace('gxmax_light', quads(1536, normal=True, light=True))
trace('gxmax_mtx', quads(1536, mtx=4))
trace('gxmax_clip', quads(1536, clip=True))
print('8 traces')
