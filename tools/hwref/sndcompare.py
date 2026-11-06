#!/usr/bin/env python3
"""Compare two sndcap result folders (docs/hw-reference.md "sndcap").

    tools/hwref/sndcompare.py A B [--out DIR] [--names ds,melonds] [--maxlag 64] [--png] [--a-only]

A and B are /hwref/ folders (real DS, melonDS, the core) holding
sndcap_<segment>_{L,R}.bin: raw little-endian s16 captures of the left and
right mixer. sndcap v2 packs its new segments into sndcap_v2_{L,R}.bin; their
place comes from sndcap_index.csv (offset and samples columns). --a-only
compares A's segments only and ignores B's extra ones (A = a v1 run, B = a
v2 run); a segment of A missing in B still counts as a difference. The start phase can differ by a few samples between machines, so
each segment is aligned by the integer lag (B shifted against A, the same lag
for L and R) within +-maxlag that gives the smallest mean absolute
difference; ties go to the smallest |lag|. The statistics cover the
overlapping samples only.

Per segment it reports the lag, the max absolute difference (L/R), the RMS
difference and the share of identical samples. With --out it writes
DIR/report.md, and with --png also DIR/png/<segment>.png for each differing
segment: per channel, A (blue) and B (orange) overlaid, and the difference
(red, scaled to its own maximum), 1024 samples from just before the first
difference. Exits 1 when any segment differs or is missing, 0 otherwise.
Needs numpy.
"""
import argparse
import csv
import os
import re
import struct
import sys
import zlib

import numpy as np


def png(path, rgb, w, h):
    raw = b"".join(b"\0" + bytes(rgb[y * w * 3:(y + 1) * w * 3]) for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def index(folder):
    """segment -> [(file, offset, samples) for L, R], or None without a v2 index."""
    p = os.path.join(folder, "sndcap_index.csv")
    if not os.path.exists(p):
        return None
    with open(p) as f:
        rows = list(csv.DictReader(f))
    if not rows or "offset" not in rows[0]:
        return None
    idx = {}
    for r in rows:
        side = 1 if r["file"].endswith("R.bin") else 0
        idx.setdefault(r["segment"], [None, None])[side] = (r["file"], int(r["offset"]), int(r["samples"]))
    return idx


def segments(folder):
    idx = index(folder)
    if idx is not None:
        return set(idx)
    segs = set()
    for f in os.listdir(folder):
        m = re.fullmatch(r"sndcap_(.+)_[LR]\.bin", f)
        if m:
            segs.add(m.group(1))
    return segs


def load(folder, seg):
    idx = index(folder)
    out = []
    for c in "LR":
        if idx is not None:
            ent = idx.get(seg, [None, None])["LR".index(c)]
            if ent is None:
                return None
            p, off, n = os.path.join(folder, ent[0]), ent[1], ent[2]
        else:
            p, off, n = os.path.join(folder, f"sndcap_{seg}_{c}.bin"), 0, -1
        if not os.path.exists(p):
            return None
        out.append(np.fromfile(p, dtype="<i2", count=n, offset=off * 2).astype(np.int64))
    return out


def overlap(x, y, k):
    """x[i] against y[i + k] over the indices where both exist."""
    n = min(len(x), len(y) - k) if k >= 0 else min(len(x) + k, len(y))
    if k >= 0:
        return x[:n], y[k:k + n]
    return x[-k:-k + n], y[:n]


def best_lag(a, b, maxlag):
    best = None
    for k in sorted(range(-maxlag, maxlag + 1), key=lambda k: (abs(k), k)):
        tot = cnt = 0
        for x, y in zip(a, b):
            xa, yb = overlap(x, y, k)
            tot += int(np.abs(xa - yb).sum())
            cnt += len(xa)
        if cnt == 0:
            continue
        m = tot / cnt
        if best is None or m < best[1]:
            best = (k, m)
            if m == 0:
                break
    return best[0]


def plot(path, a, b, k):
    W, BAND, DBAND = 1024, 128, 64
    pairs = [overlap(x, y, k) for x, y in zip(a, b)]
    first = min((int(np.argmax(xa != yb)) for xa, yb in pairs if (xa != yb).any()), default=0)
    s0 = max(0, first - 64)
    H = 2 * (BAND + DBAND + 4)
    img = bytearray(b"\xff" * (W * H * 3))

    def put(x, y, col):
        if 0 <= x < W and 0 <= y < H:
            img[(y * W + x) * 3:(y * W + x) * 3 + 3] = col

    def trace(seq, top, height, scale, col):
        prev = None
        for x, v in enumerate(seq):
            y = top + height // 2 - int(round(v * (height // 2 - 1) / scale))
            lo, hi = (y, y) if prev is None else (min(prev, y), max(prev, y))
            for yy in range(lo, hi + 1):
                put(x, yy, col)
            prev = y
    for c, (xa, yb) in enumerate(pairs):
        top = c * (BAND + DBAND + 4)
        for x in range(W):
            put(x, top + BAND // 2, (220, 220, 220))
            put(x, top + BAND + DBAND // 2, (220, 220, 220))
            put(x, top + BAND + DBAND + 1, (0, 0, 0))
        sa, sb = xa[s0:s0 + W], yb[s0:s0 + W]
        trace(sa, top, BAND, 32768, (40, 90, 220))
        trace(sb, top, BAND, 32768, (240, 140, 20))
        d = sb - sa
        dm = max(1, int(np.abs(d).max()) if len(d) else 1)
        trace(d, top + BAND, DBAND, dm, (220, 20, 20))
    png(path, img, W, H)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--out")
    ap.add_argument("--names", default="A,B")
    ap.add_argument("--maxlag", type=int, default=64)
    ap.add_argument("--png", action="store_true")
    ap.add_argument("--a-only", action="store_true", help="only A's segments (B may have more)")
    args = ap.parse_args()
    names = args.names.split(",")
    sa, sb = segments(args.a), segments(args.b)
    if not sa and not sb:
        print("no sndcap_*.bin files", file=sys.stderr)
        return 1
    if args.a_only:
        sb &= sa
    rep = [f"# sndcap: {names[0]} ({args.a}) vs {names[1]} ({args.b})\n",
           f"Lag: {names[1]} sample i+lag against {names[0]} sample i, best within ±{args.maxlag}.\n",
           "| segment | lag | max abs diff L / R | RMS diff | identical | samples | peak A L / R |",
           "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    bad = 0
    if args.out and args.png:
        os.makedirs(os.path.join(args.out, "png"), exist_ok=True)
    for seg in sorted(sa | sb):
        a, b = load(args.a, seg), load(args.b, seg)
        if a is None or b is None:
            rep.append(f"| {seg} | missing in {names[0] if a is None else names[1]} | | | | | |")
            bad += 1
            continue
        k = best_lag(a, b, args.maxlag)
        mx, sq, same, n = [], 0, 0, 0
        for x, y in zip(a, b):
            xa, yb = overlap(x, y, k)
            d = yb - xa
            mx.append(int(np.abs(d).max()) if len(d) else 0)
            sq += int((d * d).sum())
            same += int((d == 0).sum())
            n += len(d)
        rms = (sq / n) ** 0.5 if n else 0.0
        diff = same != n or len(a[0]) != len(b[0]) or len(a[1]) != len(b[1])
        bad += diff
        pk = [int(np.abs(x).max()) if len(x) else 0 for x in a]
        lens = f"{len(a[0])}" if len(a[0]) == len(b[0]) else f"{len(a[0])}/{len(b[0])}"
        rep.append(f"| {seg}{' !' if diff else ''} | {k} | {mx[0]} / {mx[1]} | {rms:.2f} | "
                   f"{100.0 * same / n if n else 0:.2f}% | {lens} | {pk[0]} / {pk[1]} |")
        if diff and args.out and args.png:
            plot(os.path.join(args.out, "png", f"{seg}.png"), a, b, k)
    rep.append(f"\n**{'IDENTICAL' if not bad else f'{bad} segment(s) differ'}** "
               f"({len(sa | sb)} segments).")
    text = "\n".join(rep) + "\n"
    print(text, end="")
    if args.out:
        os.makedirs(args.out, exist_ok=True)
        with open(os.path.join(args.out, "report.md"), "w") as f:
            f.write(text)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
