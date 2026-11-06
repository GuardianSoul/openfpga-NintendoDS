#!/usr/bin/env python3
"""Fit the DS mixer's rounding to sndcap v2's grid segments (docs/hw-reference.md "sndcap").

    tools/hwref/sndfit.py FOLDER [--top 3] [--lag N] [--out report.md]

FOLDER is a /hwref/ result folder of sndcap v2 (real DS or melonDS):
sndcap_index.csv and sndcap_v2_{L,R}.bin. The grid_v<vol7>_d<div>_p<pan>
segments play saw16 (s = -32768 + 64i + ((37i) & 63), 1024 samples, one per
capture sample) on one channel with the raw volume fields, so every captured
sample is a known function of (s, vol7, divider, pan).

Candidate pipelines, in hardware order, with melonDS's 127 -> 128 rule for
the volume and the pan factor (L = 128 - pan, R = pan):

    s -> [divider first?] -> x vol -> drop kv bits -> [divider?] -> x pan factor
      -> drop kp bits (pan) -> drop ks bits (sum) -> drop kc bits (capture) -> clamp

Each drop is floor (>>) or round toward zero (trunc). The divider's ds bits
(/1 /2 /4 /16 = 0 1 2 4) are dropped before the volume multiply, with the
volume drop, as their own stage after it, or with the pan, sum or capture
drop. kv + kp + ks + kc = 14, so full scale matches. Pipelines that are the
same function (adjacent drops of the same mode merge) are counted once.
melonDS (census build, DS rule DS_SPU_CAPTURE) is: divider with the pan drop,
kv 0, kp 6 floor, kc 8 trunc.

The capture lag (samples before the channel's first sample appears, 1 or 2
in melonDS, depending on the start phase) is fitted per segment against the
unrounded value; samples before it are skipped. Per group (divider x pan: 11 volumes, L and R) it
reports how many pipelines are exact, the simplest exact ones, and the
melonDS pipeline's miss count; then the pipelines exact on every group.
Exits 0 when some pipeline is exact on every group. Needs numpy.
"""
import argparse
import csv
import itertools
import os
import re
import sys
import time

import numpy as np

MODES = ("floor", "trunc")
DIVSHIFT = {1: 0, 2: 1, 4: 2, 16: 4}
GRID_RE = re.compile(r"grid_v(\d+)_d(\d+)_p(\d+)")


def saw16():
    i = np.arange(1024, dtype=np.int64)
    return -32768 + 64 * i + ((37 * i) & 63)


def load(folder):
    with open(os.path.join(folder, "sndcap_index.csv")) as f:
        rows = list(csv.DictReader(f))
    if not rows or "offset" not in rows[0]:
        sys.exit("no sndcap v2 index (offset column) in " + folder)
    files, segs = {}, {}
    for r in rows:
        m = GRID_RE.fullmatch(r["segment"])
        if not m:
            continue
        fn = r["file"]
        if fn not in files:
            files[fn] = np.fromfile(os.path.join(folder, fn), dtype="<i2").astype(np.int64)
        off, n = int(r["offset"]), int(r["samples"])
        side = 1 if fn.endswith("R.bin") else 0
        segs.setdefault(r["segment"], [None, None, tuple(int(g) for g in m.groups())])[side] = \
            files[fn][off:off + n]
    return segs


def drop(t, k, mode):
    """t / 2**k, floored or rounded toward zero; k may be an array."""
    if mode == "floor":
        return t >> k
    return np.where(t < 0, -((-t) >> k), t >> k)


def build_data(segs, lags):
    x = saw16()
    cols = {k: [] for k in ("s", "v", "f", "ds", "y", "g")}
    groups = sorted({(d, p) for (_, d, p) in (s[2] for s in segs.values())})
    gidx = {g: i for i, g in enumerate(groups)}
    for name, (l, r, (v7, div, pan)) in sorted(segs.items()):
        v = 128 if v7 == 127 else v7
        p = 128 if pan == 127 else pan
        lag = lags[name]
        for y, fac in ((l, 128 - p), (r, p)):
            n = len(y) - lag
            cols["s"].append(x[np.arange(n) % 1024])
            cols["y"].append(y[lag:])
            for k, val in (("v", v), ("f", fac), ("ds", DIVSHIFT[div]), ("g", gidx[(div, pan)])):
                cols[k].append(np.full(n, val, dtype=np.int64))
    return {k: np.concatenate(c) for k, c in cols.items()}, groups


def fit_lags(segs, maxlag=16):
    """Per segment (L and R together): the lag with the smallest absolute
    difference from the unrounded value. Model-free, so it can't favour a
    rounding; on melonDS it agrees with the exact model's lag everywhere."""
    x = saw16().astype(np.float64)
    lags = {}
    for name, (l, r, (v7, div, pan)) in segs.items():
        v = 128 if v7 == 127 else v7
        p = 128 if pan == 127 else pan
        err = np.zeros(maxlag + 1)
        for y, fac in ((l, 128 - p), (r, p)):
            n = len(y) - maxlag
            ideal = x[np.arange(n) % 1024] * (v * fac / 2.0 ** (14 + DIVSHIFT[div]))
            for lag in range(maxlag + 1):
                err[lag] += np.abs(y[lag:lag + n] - ideal).sum()
        lags[name] = int(np.argmin(err))
    return lags


def models():
    """Canonical pipelines: (pre_mode, mid chain, post chain); a chain is a tuple
    of (mode, const_bits, with_ds). Returns {signature: description}."""
    out = {}
    places = ("pre", "vol", "div", "pan", "sum", "cap")
    for kv in range(8):
        for kp in range(15 - kv):
            for ks in range(15 - kv - kp):
                kc = 14 - kv - kp - ks
                for place in places:
                    for mv, mp, ms, mc, md in itertools.product(MODES, repeat=5):
                        if place not in ("pre", "div") and md != "floor":
                            continue   # md unused
                        pre = md if place == "pre" else None
                        mid = [(mv, kv, place == "vol")]
                        if place == "div":
                            mid.append((md, 0, True))
                        post = [(mp, kp, place == "pan"), (ms, ks, place == "sum"), (mc, kc, place == "cap")]
                        sig = (pre, canon(mid), canon(post))
                        if sig not in out:
                            out[sig] = describe(sig)
    return out


def canon(chain):
    res = []
    for mode, k, ds in chain:
        if k == 0 and not ds:
            continue
        if res and res[-1][0] == mode:
            pm, pk, pds = res[-1]
            if pds and ds:
                return None   # (can't happen: ds is used once)
            res[-1] = (mode, pk + k, pds or ds)
        else:
            res.append((mode, k, ds))
    return tuple(res)


def describe(sig):
    pre, mid, post = sig

    def seg(m, k, ds):
        b = f"{k}+ds" if ds and k else ("ds" if ds else str(k))
        return f"{m} {b}"
    parts = []
    if pre:
        parts.append(f"s: {pre} ds")
    parts.append("x vol" + ("; " + ", ".join(seg(*c) for c in mid) if mid else ""))
    parts.append("x pan" + ("; " + ", ".join(seg(*c) for c in post) if post else ""))
    return " | ".join(parts)


MELONDS = (None, (), (("floor", 6, True), ("trunc", 8, False)))


def evaluate(sig, d, cache):
    """cache: {} holding the last (pre, mid) product."""
    pre, mid, post = sig
    key = (pre, mid)
    t = cache.get(key)
    if t is None:
        cache.clear()
        t = d["s"] if pre is None else drop(d["s"], d["ds"], pre)
        t = t * d["v"]
        for m, k, ds in mid:
            t = drop(t, k + d["ds"] if ds else k, m)
        t = t * d["f"]
        cache[key] = t
    for m, k, ds in post:
        t = drop(t, k + d["ds"] if ds else k, m)
    return np.clip(t, -32768, 32767)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder")
    ap.add_argument("--top", type=int, default=3, help="exact pipelines listed per group")
    ap.add_argument("--lag", type=int, help="capture lag for every segment (default: fitted per segment)")
    ap.add_argument("--out", help="also write the report here")
    args = ap.parse_args()
    t0 = time.time()
    segs = load(args.folder)
    if not segs:
        sys.exit("no grid_* segments in " + args.folder)
    lags = fit_lags(segs) if args.lag is None else {k: args.lag for k in segs}
    d, groups = build_data(segs, lags)
    hist = np.bincount(list(lags.values()))
    lagtxt = ", ".join(f"{k}: {c}" for k, c in enumerate(hist) if c)
    ng = len(groups)
    ms = models()
    sigs = sorted(ms, key=lambda s: (str(s[0]), s[1], s[2]))   # by (pre, mid): one cached product
    # Screen on every 16th sample, then count misses per group on all samples
    # for the pipelines that pass the screen somewhere.
    sub = np.arange(0, len(d["y"]), 16)
    ds_ = {k: v[sub] for k, v in d.items()}
    cache_s, cache_f = {}, {}
    miss = np.full((len(sigs), ng), -1, dtype=np.int64)
    gsize = np.bincount(d["g"], minlength=ng)
    best_miss = np.full(ng, np.iinfo(np.int64).max)
    for i, sig in enumerate(sigs):
        ys = evaluate(sig, ds_, cache_s)
        sm = np.bincount(ds_["g"], weights=(ys != ds_["y"]), minlength=ng)
        if (sm == 0).any() or sig == MELONDS or (sm * 16 < best_miss).any():
            yf = evaluate(sig, d, cache_f)
            miss[i] = np.bincount(d["g"], weights=(yf != d["y"]), minlength=ng).astype(np.int64)
            best_miss = np.minimum(best_miss, miss[i])
    mi = sigs.index(MELONDS)
    complexity = [len(s[1]) + len(s[2]) + (s[0] is not None) for s in sigs]

    rep = [f"# sndfit: {args.folder}\n",
           f"{len(segs)} grid segments, {len(d['y'])} samples (L and R); capture lag (segments) "
           f"{lagtxt}; "
           f"{len(sigs)} distinct pipelines. Notation: drops in order, `ds` = the divider's "
           f"bits (/1 /2 /4 /16 = 0 1 2 4); melonDS = `{ms[MELONDS]}`.\n",
           "| group | samples | exact pipelines | melonDS misses | simplest exact (or best) |",
           "| --- | ---: | ---: | ---: | --- |"]
    for gi, (div, pan) in enumerate(groups):
        col = miss[:, gi]
        exact = [i for i in range(len(sigs)) if col[i] == 0]
        exact.sort(key=lambda i: (i != mi, complexity[i], ms[sigs[i]]))
        if exact:
            best = "<br>".join(f"`{ms[sigs[i]]}`" for i in exact[:args.top])
        else:
            cand = [i for i in range(len(sigs)) if col[i] >= 0]
            b = min(cand, key=lambda i: (col[i], complexity[i]))
            best = f"none; best `{ms[sigs[b]]}` ({col[b]} misses)"
        rep.append(f"| d{div}_p{pan} | {gsize[gi]} | {len(exact)} | {miss[mi, gi]} | {best} |")
    every = [i for i in range(len(sigs)) if (miss[i] == 0).all()]
    every.sort(key=lambda i: (i != mi, complexity[i], ms[sigs[i]]))
    rep.append(f"\n**Exact on every group: {len(every)} pipeline(s).**")
    for i in every[:max(args.top, 10)]:
        rep.append(f"- `{ms[sigs[i]]}`{' (melonDS)' if i == mi else ''}")
    if not every:
        tot = np.where(miss >= 0, miss, np.iinfo(np.int32).max).sum(axis=1)
        b = int(np.argmin(tot))
        rep.append(f"- best overall: `{ms[sigs[b]]}`, {tot[b]} misses "
                   f"(melonDS: {miss[mi].sum()})")
    rep.append(f"\n({time.time() - t0:.1f} s)")
    text = "\n".join(rep) + "\n"
    print(text, end="")
    if args.out:
        with open(args.out, "w") as f:
            f.write(text)
    return 0 if every else 1


if __name__ == "__main__":
    sys.exit(main())
