#!/usr/bin/env python3
"""Trims a census GX trace to one game frame for replay3d (docs/hw-reference.md
"replay3d").

  mkreplay.py TRACE OUT.gxb --frame F [--warm 4]
  mkreplay.py TRACE --list

The output is itself a census trace (NDSGX001: 'V', 'C', 'F' records,
tools/melonds-census/census.cpp), so the same file goes to the card (replay3d
on the DS and in melonDS) and through gx2scene (`--skip WARM`) to the RTL:
- one 'V' record first: the trace's VRAM for the target flush (the record
  written right after it if there is one, else the latest before it)
- a prologue that sets every matrix to identity and clears the texture
  parameters, so the state at the start is defined by the file itself
- the trace's 'C' and 'F' records for WARM flushes before the target (they
  rebuild the matrices a game reloads every frame) and the target flush.
--list prints every flush: frame, polygons, vertices, VRAM record, and the
texture slots its TEXIMAGE_PARAMs reach.
"""
import argparse
import struct
import sys

BANK = [0x20000] * 4 + [0x10000, 0x4000, 0x4000, 0x8000, 0x4000]
VLEN = 13 + sum(BANK)
FLEN = 149
BPP = [0, 8, 2, 4, 8, 2, 8, 16]


def records(d):
    i = 8
    while i < len(d):
        t = d[i]
        if t == 0x43:
            yield "C", i, i + 6
            i += 6
        elif t == 0x46:
            yield "F", i, i + 1 + FLEN
            i += 1 + FLEN
        elif t == 0x56:
            yield "V", i, i + 1 + VLEN
            i += 1 + VLEN
        else:
            raise ValueError(f"bad record 0x{t:02x} at {i}")


def slots(p):
    f = (p >> 26) & 7
    if not f:
        return set()
    a = (p & 0xFFFF) * 8
    n = (8 << ((p >> 20) & 7)) * (8 << ((p >> 23) & 7)) * BPP[f] // 8
    s = {x & 3 for x in range(a >> 17, ((a + n - 1) >> 17) + 1)}
    return s | ({1} if f == 5 else set())


def scan(d):
    flushes, used, last_v = [], set(), None
    recs = list(records(d))
    for k, (t, a, b) in enumerate(recs):
        if t == "C" and d[a + 1] == 0x2A:
            used |= slots(struct.unpack_from("<I", d, a + 2)[0])
        elif t == "F":
            frame, np_, nv, dc = struct.unpack_from("<IIII", d, a + 1)
            if dc & (1 << 14):
                used |= {2, 3}
            exact = k + 1 < len(recs) and recs[k + 1][0] == "V"
            flushes.append(dict(rec=k, frame=frame, polys=np_, verts=nv, slots=used,
                                vrec=k + 1 if exact else last_v, exact=exact))
            used = set()
        elif t == "V":
            last_v = k
    return recs, flushes




def prologue():
    out = []
    for m in range(4):
        out += [(0x10, m), (0x15, 0)]
    return out + [(0x10, 0), (0x2A, 0), (0x2B, 0)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--frame", type=int)
    ap.add_argument("--warm", type=int, default=4)
    ap.add_argument("--list", action="store_true")
    o = ap.parse_args()
    d = open(o.trace, "rb").read()
    if d[:8] != b"NDSGX001":
        sys.exit(f"{o.trace}: not a census GX trace")
    recs, flushes = scan(d)
    if o.list:
        for n, f in enumerate(flushes):
            print(f"{n:4d} frame {f['frame']:6d} polys {f['polys']:4d} verts {f['verts']:5d} "
                  f"{'V' if f['exact'] else ' '} slots {''.join(map(str, sorted(f['slots'])))}")
        return 0
    k = next((n for n, f in enumerate(flushes) if f["frame"] == o.frame), None)
    if k is None:
        sys.exit(f"no flush at frame {o.frame}")
    if k < o.warm + 1:
        sys.exit(f"flush {k} has fewer than {o.warm} warm-up flushes after the trace's first")
    tgt = flushes[k]
    if tgt["vrec"] is None:
        sys.exit("no VRAM record at or before the target flush")
    first = flushes[k - o.warm - 1]["rec"] + 1
    _, va, vb = recs[tgt["vrec"]]
    out = bytearray(b"NDSGX001") + d[va:vb]
    for c, p in prologue():
        out += struct.pack("<BBI", 0x43, c, p)
    for t, a, b in recs[first:tgt["rec"] + 1]:
        if t != "V":
            out += d[a:b]
    open(o.out, "wb").write(out)
    used = set().union(*(f["slots"] for f in flushes[k - o.warm:k + 1]))
    print(f"{o.out}: frame {tgt['frame']}, {tgt['polys']} polys, {tgt['verts']} verts, "
          f"{'exact' if tgt['exact'] else 'latest'} VRAM, slots {''.join(map(str, sorted(used)))}, {len(out)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
