#!/usr/bin/env python3
"""Finds where the DS's vertex/polygon counts leave melonDS's in a replay3d
probe pass (docs/hw-reference.md "replay3d method").

  vtxbisect.py FILE.gxb DS_counts.bin MEL_counts.bin [--context N]

The counts files (replay3d_<name>_counts.bin) hold, for every BEGIN, END
and vertex command of the target flush, the entry's byte offset in the
.gxb and RAM_COUNT after it. Prints each place where the DS-melonDS
vertex/polygon delta changes, and the commands from the BEGIN before
the first one, with the last POLYGON_ATTR, TEXIMAGE_PARAM, MTX_MODE and
VIEWPORT before it.
"""
import argparse
import struct
import sys

NAMES = {0x10: "MTX_MODE", 0x11: "MTX_PUSH", 0x12: "MTX_POP", 0x13: "MTX_STORE", 0x14: "MTX_RESTORE",
         0x15: "MTX_IDENTITY", 0x16: "MTX_LOAD_4x4", 0x17: "MTX_LOAD_4x3", 0x18: "MTX_MULT_4x4",
         0x19: "MTX_MULT_4x3", 0x1A: "MTX_MULT_3x3", 0x1B: "MTX_SCALE", 0x1C: "MTX_TRANS", 0x20: "COLOR",
         0x21: "NORMAL", 0x22: "TEXCOORD", 0x23: "VTX_16", 0x24: "VTX_10", 0x25: "VTX_XY", 0x26: "VTX_XZ",
         0x27: "VTX_YZ", 0x28: "VTX_DIFF", 0x29: "POLYGON_ATTR", 0x2A: "TEXIMAGE_PARAM", 0x2B: "PLTT_BASE",
         0x30: "DIF_AMB", 0x31: "SPE_EMI", 0x32: "LIGHT_VECTOR", 0x33: "LIGHT_COLOR", 0x34: "SHININESS",
         0x40: "BEGIN_VTXS", 0x41: "END_VTXS", 0x50: "SWAP_BUFFERS", 0x60: "VIEWPORT", 0x70: "BOX_TEST",
         0x71: "POS_TEST", 0x72: "VEC_TEST"}


def counts(p):
    d = open(p, "rb").read()
    return [struct.unpack_from("<II", d, i) for i in range(0, len(d) - 7, 8)]


def entries(d):
    """(offset, cmd, param) for every 'C' record."""
    out, i = [], 8
    vlen = 13 + 4 * 0x20000 + 0x10000 + 2 * 0x4000 + 0x8000 + 0x4000
    while i < len(d):
        t = d[i]
        if t == 0x43:
            out.append((i, d[i + 1], struct.unpack_from("<I", d, i + 2)[0]))
            i += 6
        elif t == 0x46:
            i += 150
        elif t == 0x56:
            i += 1 + vlen
        else:
            sys.exit(f"bad record at {i}")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("gxb")
    ap.add_argument("ds")
    ap.add_argument("mel")
    ap.add_argument("--context", type=int, default=40)
    ap.add_argument("--all", action="store_true", help="the commands of every change, not just the first")
    o = ap.parse_args()
    a, b = counts(o.ds), counts(o.mel)
    if [x[0] for x in a] != [x[0] for x in b]:
        print(f"checkpoint offsets differ ({len(a)} vs {len(b)}); comparing the common prefix")
    prev, first = (0, 0), None
    print("offset    DS polys/verts   melonDS polys/verts   delta")
    for (off, ra), (_, rb) in zip(a, b):
        dp, dv = (ra & 0xFFF) - (rb & 0xFFF), ((ra >> 16) & 0x1FFF) - ((rb >> 16) & 0x1FFF)
        if (dp, dv) != prev:
            print(f"{off:8d}  {ra & 0xFFF:5d}/{(ra >> 16) & 0x1FFF:5d}      {rb & 0xFFF:5d}/{(rb >> 16) & 0x1FFF:5d}"
                  f"          {dp:+d}/{dv:+d}")
            if first is None:
                first = off
            prev = (dp, dv)
    print(f"final delta {prev[0]:+d} polys / {prev[1]:+d} verts over {len(a)} checkpoints")
    if first is None:
        return 0
    if o.all:
        es = entries(open(o.gxb, "rb").read())
        idx = {e[0]: n for n, e in enumerate(es)}
        prev = (0, 0)
        for (off, ra), (_, rb) in zip(a, b):
            dd = ((ra & 0xFFF) - (rb & 0xFFF), ((ra >> 16) & 0x1FFF) - ((rb >> 16) & 0x1FFF))
            if dd == prev:
                continue
            prev = dd
            k = idx[off]
            begin = max(n for n in range(k + 1) if es[n][1] == 0x40)
            attr = next((p for _, c, p in reversed(es[:begin]) if c == 0x29), None)
            print(f"\n-- delta now {dd[0]:+d}/{dd[1]:+d} at {off}; POLYGON_ATTR {attr:08x}" if attr is not None else f"\n-- delta now {dd[0]:+d}/{dd[1]:+d} at {off}")
            for eo, c, p in es[begin:k + 2]:
                print(f"  {eo:8d}  {c:02x} {NAMES.get(c, '?'):14s} {p:08x}{'  <--' if eo == off else ''}")
        return 0
    d = open(o.gxb, "rb").read()
    es = entries(d)
    k = next(n for n, e in enumerate(es) if e[0] == first)
    begin = max(n for n in range(k + 1) if es[n][1] == 0x40)
    state = {}
    for off, c, p in es[:begin]:
        if c in (0x10, 0x29, 0x2A, 0x60):
            state[c] = p
    print(f"\nfirst change at offset {first}; state before its BEGIN:")
    for c, p in state.items():
        print(f"  {NAMES[c]:14s} {p:08x}")
    print("commands:")
    for off, c, p in es[begin:min(len(es), k + o.context)]:
        mark = "  <-- first change" if off == first else ""
        print(f"  {off:8d}  {c:02x} {NAMES.get(c, '?'):14s} {p:08x}{mark}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
