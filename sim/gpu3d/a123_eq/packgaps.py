#!/usr/bin/env python3
"""a2's stream: packed GXFIFO words with zero bytes between, before and after their commands (games pad with zeros;
the synthetic streams pack commands back to back), as a tb_geom --rwlog file ("GW off data").
    sim/gpu3d/a123_eq/packgaps.py OUT [SEED] [WORDS]"""
import random, sys
out = sys.argv[1]; rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 1)
n = int(sys.argv[3]) if len(sys.argv) > 3 else 20000
NP = {0x10: 1, 0x11: 0, 0x12: 1, 0x15: 0, 0x1B: 3, 0x1C: 3, 0x20: 1, 0x21: 1, 0x22: 1, 0x23: 2, 0x24: 1, 0x25: 1,
      0x29: 1, 0x2A: 1, 0x40: 1, 0x41: 0, 0x70: 3, 0x71: 2, 0x72: 1}
def param(c, k):
    if c == 0x10: return rng.choice([1, 2])                 # position or position+vector
    if c == 0x12: return 1
    if c in (0x1B, 0x1C): return rng.randrange(-0x2000, 0x2000) & 0xFFFFFFFF
    if c == 0x40: return rng.randrange(4)
    if c == 0x29: return 0x001F00C0
    if c == 0x23: return (rng.randrange(-0x800, 0x800) & 0xFFFF) | ((rng.randrange(-0x800, 0x800) & 0xFFFF) << 16) if k == 0 else rng.randrange(-0x800, 0x800) & 0xFFFF
    if c == 0x70: return rng.randrange(-0x400, 0x400) & 0xFFFF | ((rng.randrange(-0x400, 0x400) & 0xFFFF) << 16)
    return rng.randrange(1 << 30)
with open(out, 'w') as f:
    f.write("GW 040 00000000\nGW 040 00000003\n")              # MTX_MODE 0 (via 0x440), then 3
    f.write("GW 054 00000000\nGW 040 00000002\nGW 054 00000000\n")   # identities
    for i in range(n):
        if i % 2000 == 1999:                                    # a frame: SWAP_BUFFERS through the port
            f.write("GW 140 00000000\n"); continue
        slots = [rng.choice(list(NP)) if rng.random() < 0.55 else 0 for _ in range(4)]
        if rng.random() < 0.02: slots = [0, 0, 0, 0]
        word = sum(c << (8 * k) for k, c in enumerate(slots))
        f.write("GW 000 %08x\n" % word)
        for c in slots:
            for k in range(NP.get(c, 0)): f.write("GW 000 %08x\n" % param(c, k))
print(out)
