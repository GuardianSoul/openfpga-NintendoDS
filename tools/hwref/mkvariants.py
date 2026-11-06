#!/usr/bin/env python3
"""Quad-strip slice variants for replay3d's count mode (docs/hw-reference.md
"replay3d method", geometry session).

  mkvariants.py FILE.gxb DS_counts.bin MEL_counts.bin OUT.var [--places 2]

Takes the first PLACES places where the DS's vertex count leaves melonDS's
(as vtxbisect.py finds them). For each, the slice is the quad strip from
its BEGIN_VTXS up to the vertex where the count changed, then END_VTXS.
The DS replays the frame up to that BEGIN, reads RAM_COUNT, sends one
variant of the slice, and reads it again:

  1 control: the slice as is
  2 both faces: POLYGON_ATTR (the one in effect | bits 6, 7) before BEGIN
  3 no TEXCOORD and no NORMAL commands
  4 every vertex as an absolute VTX_16, other commands kept
  5 the last 6 strip vertices as two separate quads (BEGIN 1), VTX_16 only
  6 the first quad of the strip only, VTX_16 only
  7 the strip with its vertex pairs in reverse order, VTX_16 only
  8 the last 6 strip vertices as a quad strip, VTX_16 only

Variants 5-8 drop the other per-vertex commands. Vertex positions follow
melonDS's CurVertex (s16) updates.

OUT.var: "HWVAR001", u32 records; each record u32 place, u32 variant,
u32 slice_start (byte offset of the BEGIN record), u32 n, then n pairs
(u32 cmd, u32 param).
"""
import argparse
import struct
import sys

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
from vtxbisect import counts, entries  # noqa: E402


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def vtx16(x, y, z):
    return [(0x23, (x & 0xFFFF) | ((y & 0xFFFF) << 16)), (0x23, z & 0xFFFF)]


def strip_vertices(es, start=(0, 0, 0)):
    """[(pos, [entries of this vertex incl. the vertex command(s)], [attribute entries before it])].
    start: CurVertex before the first entry (VTX_XY/XZ/YZ/DIFF keep or move it)."""
    cur = list(start)
    out, pend, i = [], [], 0
    while i < len(es):
        c, p = es[i]
        if c == 0x23:
            p2 = es[i + 1][1]
            cur = [s16(p), s16(p >> 16), s16(p2)]
            out.append((tuple(cur), [es[i], es[i + 1]], pend))
            pend, i = [], i + 2
            continue
        if c == 0x24:
            cur = [s16((p & 0x3FF) << 6), s16((p & 0xFFC00) >> 4), s16((p & 0x3FF00000) >> 14)]
        elif c == 0x25:
            cur[0], cur[1] = s16(p), s16(p >> 16)
        elif c == 0x26:
            cur[0], cur[2] = s16(p), s16(p >> 16)
        elif c == 0x27:
            cur[1], cur[2] = s16(p), s16(p >> 16)
        elif c == 0x28:
            cur = [s16(cur[0] + (s16((p & 0x3FF) << 6) >> 6)), s16(cur[1] + (s16((p & 0xFFC00) >> 4) >> 6)),
                   s16(cur[2] + (s16((p & 0x3FF00000) >> 14) >> 6))]
        else:
            pend.append((c, p))
            i += 1
            continue
        out.append((tuple(cur), [es[i]], pend))
        pend, i = [], i + 1
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("gxb")
    ap.add_argument("ds")
    ap.add_argument("mel")
    ap.add_argument("out")
    ap.add_argument("--places", type=int, default=2)
    o = ap.parse_args()
    a, b = counts(o.ds), counts(o.mel)
    places, prev = [], 0
    for (off, ra), (_, rb) in zip(a, b):
        dv = ((ra >> 16) & 0x1FFF) - ((rb >> 16) & 0x1FFF)
        if dv != prev:
            places.append(off)
            prev = dv
    places = places[:o.places]
    es = entries(open(o.gxb, "rb").read())
    idx = {e[0]: n for n, e in enumerate(es)}
    recs = []
    for pl, off in enumerate(places):
        k = idx[off]
        bi = max(n for n in range(k + 1) if es[n][1] == 0x40)
        if es[bi][2] & 3 != 3:
            print(f"place {off}: BEGIN type {es[bi][2] & 3}, not a quad strip; skipped")
            continue
        attr = next((p for _, c, p in reversed(es[:bi]) if c == 0x29), 0x1F00C0)
        body = [(c, p) for _, c, p in es[bi + 1:k + 1]]
        n23, j = 0, 0   # VTX_16 has two words: complete a vertex cut after its first
        while j < len(body):
            if body[j][0] == 0x23:
                j += 2
                if j > len(body):
                    body.append((es[k + 1][1], es[k + 1][2]))
            else:
                j += 1
        # CurVertex carries over from everything before the slice (run 19:
        # starting at 0 moved the first vertex of slices that begin with a
        # partial vertex command, in variants 4-8)
        prior = strip_vertices([(c, p) for _, c, p in es[:bi] if 0x23 <= c <= 0x28])
        verts = strip_vertices(body, prior[-1][0] if prior else (0, 0, 0))
        pos = [v[0] for v in verts]
        last6 = pos[-6:] if len(pos) >= 6 else pos
        V = []
        V.append((1, [(0x40, 3)] + body + [(0x41, 0)]))
        V.append((2, [(0x29, attr | 0xC0), (0x40, 3)] + body + [(0x41, 0)]))
        V.append((3, [(0x40, 3)] + [e for e in body if e[0] not in (0x21, 0x22)] + [(0x41, 0)]))
        abs_body = [(0x40, 3)]
        for p3, _, pend in verts:
            abs_body += pend + vtx16(*p3)
        V.append((4, abs_body + [(0x41, 0)]))
        if len(last6) == 6:
            q = [(0x40, 1)]
            for i in (0, 1, 3, 2, 2, 3, 5, 4):
                q += vtx16(*last6[i])
            V.append((5, q + [(0x41, 0)]))
            V.append((8, [(0x40, 3)] + sum((vtx16(*p3) for p3 in last6), []) + [(0x41, 0)]))
        V.append((6, [(0x40, 3)] + sum((vtx16(*p3) for p3 in pos[:4]), []) + [(0x41, 0)]))
        rev = []
        for j in range(len(pos) // 2 - 1, -1, -1):
            rev += vtx16(*pos[2 * j]) + vtx16(*pos[2 * j + 1])
        V.append((7, [(0x40, 3)] + rev + [(0x41, 0)]))
        for vid, ents in V:
            recs.append((pl, vid, es[bi][0], ents))
        print(f"place {pl} at {off}: BEGIN at {es[bi][0]}, {len(pos)} strip vertices, attr {attr:08x}")
    with open(o.out, "wb") as f:
        f.write(b"HWVAR001" + struct.pack("<I", len(recs)))
        for pl, vid, start, ents in recs:
            f.write(struct.pack("<IIII", pl, vid, start, len(ents)))
            for c, p in ents:
                f.write(struct.pack("<II", c, p & 0xFFFFFFFF))
    print(f"{o.out}: {len(recs)} variants")
    return 0


if __name__ == "__main__":
    sys.exit(main())
