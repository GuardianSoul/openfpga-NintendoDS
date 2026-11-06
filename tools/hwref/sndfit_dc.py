#!/usr/bin/env python3
"""Fit the DS mixer's rounding to sndcap v3's DC staircases (docs/hw-reference.md "sndcap").

    tools/hwref/sndfit_dc.py FOLDER [--edge 16] [--top 3] [--out report.md]

FOLDER is a /hwref/ result folder of sndcap v3: sndcap_info.txt (plateau
values per channel), sndcap_index.csv and sndcap_v3_{L,R}.bin. Each dc_* and
dc2_* segment plays a staircase of plateaus (each value held for 64 samples,
sample timer = capture timer), so the capture lag and phase don't matter:

1. Plateaus. Per segment the lag is where the output's steps fall (the most
   common sample index mod 64 at which the value changes, L and R
   together). Each plateau's interior (its 64 samples minus --edge at each
   end) must be constant; any that isn't is listed (that would itself be a
   finding).
2. One channel (dc_v<vol7>_d<div>_p<pan>, ch0): the pipelines of sndfit.py
   (floor or round toward zero at volume, divider, pan, sum and capture,
   with melonDS's 127 -> 128 rules) against (value, vol7, divider, pan).
   Per group (divider x pan: 8 volumes, L and R) the exact pipelines, and
   those exact on every group.
3. Two channels (dc2_* directed pairs, dc2r_* staircases; ch0 + ch2 with
   their own vol7/divider/pan): for each
   one-channel pipeline that is exact everywhere (else the best few), every
   place the sum can sit in its drop chain, from "each channel rounds fully,
   then sum" to "sum the exact products, round once" (the divider's bits
   stay per channel). Which placements are exact.
4. Lag probe (lag_t*): the capture sample at which the step from 0 appears,
   against the step's place in the sample stream (256 samples x timer / 512).

Exits 0 when some one-channel pipeline is exact on every group and (with
two-channel segments) some placement is exact on all of them. Needs numpy.
"""
import argparse
import csv
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sndfit  # noqa: E402

PLAT = 64
DIVSHIFT = sndfit.DIVSHIFT
DIVS = {0: 1, 1: 2, 2: 4, 3: 16}   # SOUNDxCNT div field -> divisor
MELONDS = sndfit.MELONDS


def load(folder):
    """segment -> {"voices": [dict], "L": array, "R": array}. Sets PLAT."""
    global PLAT
    segs, cur = {}, None
    with open(os.path.join(folder, "sndcap_info.txt")) as f:
        for line in f:
            m = re.match(r"segment (\S+) ", line)
            if m:
                cur = segs.setdefault(m.group(1), {"voices": []}) if \
                    m.group(1).startswith(("dc_", "dc2", "lag_")) else None
                continue
            if cur is not None and line.startswith("  ch="):
                v = {k: val for k, val in re.findall(r"(\w+)=(\S+)", line)}
                vd = {"ch": int(v["ch"]), "pan": int(v["pan"]), "timer": int(v["timer"]),
                      "v7": int(re.search(r"vol7=(\d+)", line).group(1)),
                      "div": int(re.search(r"div=(\d+)", line).group(1))}
                if "values" in v:
                    vd["values"] = [int(x) for x in v["values"].split(",")]
                    PLAT = int(v.get("plateau", PLAT))   # v3.c's PLAT (64)
                cur["voices"].append(vd)
    files = {}
    with open(os.path.join(folder, "sndcap_index.csv")) as f:
        for r in csv.DictReader(f):
            if r["segment"] not in segs:
                continue
            fn = r["file"]
            if fn not in files:
                files[fn] = np.fromfile(os.path.join(folder, fn), dtype="<i2").astype(np.int64)
            off, n = int(r["offset"]), int(r["samples"])
            segs[r["segment"]]["R" if fn.endswith("R.bin") else "L"] = files[fn][off:off + n]
    return segs


def plateau_lag(l, r):
    """The sample index mod 64 at which the output steps (None if it never does)."""
    hist = np.zeros(PLAT, dtype=np.int64)
    for y in (l, r):
        k = np.nonzero(np.diff(y) != 0)[0] + 1
        hist += np.bincount(k % PLAT, minlength=PLAT)
    return int(np.argmax(hist)) if hist.any() else None


def plateaus(seg, edge, lag):
    """Per side: list of (interior values) for each plateau that fits."""
    nplat = len(seg["voices"][0]["values"])
    out = {}
    for side in "LR":
        y = seg[side]
        wins = []
        for j in range(nplat):
            a, b = PLAT * j + lag + edge, PLAT * (j + 1) + lag - edge
            wins.append(y[a:b] if b <= len(y) else None)
        out[side] = wins
    return out


def factors(v):
    vol = 128 if v["v7"] == 127 else v["v7"]
    pan = 128 if v["pan"] == 127 else v["pan"]
    return vol, {"L": 128 - pan, "R": pan}, DIVSHIFT[DIVS[v["div"]]]


def pre_mid(sig, s, v, ds):
    pre, mid, _ = sig
    t = s if pre is None else sndfit.drop(s, ds, pre)
    t = t * v
    for m, k, d in mid:
        t = sndfit.drop(t, k + ds if d else k, m)
    return t


def chain(t, ch, ds):
    for m, k, d in ch:
        t = sndfit.drop(t, k + ds if d else k, m)
    return t


def splits(post):
    """Ways to split a post-pan drop chain at the sum: (exact divider?, per
    channel, after the sum). With the divider's bits in the chain, the divider
    is also tried as melonDS does it, an exact x 2**(4 - ds) per channel, which
    leaves 4 fixed bits in the chain that can go before or after the sum
    (after: the sum of the exact products)."""
    res = set()
    if any(d for _, _, d in post):
        fixed = [(m, k + 4 if d else k, False) for m, k, d in post]
        for i, (m, k, d) in enumerate(fixed):
            for a in range(k + 1):
                before = list(fixed[:i]) + ([(m, a, False)] if a else [])
                after = ([(m, k - a, False)] if k - a else []) + list(fixed[i + 1:])
                res.add((True, tuple(before), tuple(after)))
        res.add((True, (), tuple(fixed)))
        return sorted(res, key=lambda s: -sum(k for _, k, _ in s[1]))
    for i, (m, k, d) in enumerate(post):
        if any(dd for _, _, dd in post[i + 1:]):
            continue
        for a in range(k + 1):
            before = list(post[:i]) + ([(m, a, d)] if a or d else [])
            after = ([(m, k - a, False)] if k - a else []) + list(post[i + 1:])
            res.add((False, tuple(before), tuple(after)))
    res.add((False, (), tuple(post)))
    return sorted(res, key=lambda s: -sum(k for _, k, _ in s[1]))


def chain_text(ch):
    if not ch:
        return "-"
    return ", ".join(f"{m} {k}+ds" if d and k else (f"{m} ds" if d else f"{m} {k}") for m, k, d in ch)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder")
    ap.add_argument("--edge", type=int, default=16, help="samples dropped at each plateau edge")
    ap.add_argument("--top", type=int, default=3)
    ap.add_argument("--out")
    args = ap.parse_args()
    segs = load(args.folder)
    dc = {k: s for k, s in segs.items() if k.startswith("dc_")}
    dc2 = {k: s for k, s in segs.items() if k.startswith("dc2")}
    lagp = {k: s for k, s in segs.items() if k.startswith("lag_")}
    if not dc:
        sys.exit("no sndcap v3 dc_* segments in " + args.folder)
    rep = [f"# sndfit_dc: {args.folder}\n"]
    ok2 = True

    # 1. Plateaus
    rows1, rows2, bad, lags, missing = [], [], [], {}, 0
    for name, seg in sorted(segs.items()):
        if name.startswith("lag_"):
            continue
        lag = plateau_lag(seg["L"], seg["R"])
        lags[name] = lag
        if lag is None:
            lag = 0
        wins = plateaus(seg, args.edge, lag)
        vs = seg["voices"]
        for j in range(len(vs[0]["values"])):
            for side in "LR":
                w = wins[side][j]
                if w is None:
                    missing += 1
                    continue
                if (w != w[0]).any():
                    bad.append((name, side, j, sorted(set(int(x) for x in w))[:6]))
                    continue
                y = int(w[0])
                if name.startswith("dc_"):
                    v = vs[0]
                    vol, fac, ds = factors(v)
                    rows1.append((v["values"][j], vol, fac[side], ds, y, (DIVS[v["div"]], v["pan"])))
                else:
                    a, b = vs[0], vs[1]
                    va, fa, da = factors(a)
                    vb, fb, db = factors(b)
                    rows2.append((a["values"][j], va, fa[side], da, b["values"][j], vb, fb[side], db, y, name))
    lh = {}
    for v in lags.values():
        lh[v] = lh.get(v, 0) + 1
    rep.append(f"**Plateaus.** {len(dc)} one-channel and {len(dc2)} two-channel segments, "
               f"{len(rows1) + len(rows2) + len(bad)} plateau interiors (L and R, {PLAT - 2 * args.edge} "
               f"samples each), {missing} past the capture's end. Step lag mod 64 (segments): "
               + ", ".join(f"{k}: {c}" for k, c in sorted(lh.items(), key=lambda x: (x[0] is None, x[0] or 0)))
               + f". **Non-constant interiors: {len(bad)}.**")
    for b in bad[:20]:
        rep.append(f"- {b[0]} {b[1]} plateau {b[2]}: values {b[3]}")
    rep.append("")

    # 2. One channel
    a = np.array([r[:5] for r in rows1], dtype=np.int64)
    d = {"s": a[:, 0], "v": a[:, 1], "f": a[:, 2], "ds": a[:, 3]}
    y = a[:, 4]
    groups = sorted({r[5] for r in rows1})
    gi = {g: i for i, g in enumerate(groups)}
    g = np.array([gi[r[5]] for r in rows1])
    ms = sndfit.models()
    sigs = sorted(ms, key=lambda s: (str(s[0]), s[1], s[2]))
    cache = {}
    miss = np.zeros((len(sigs), len(groups)), dtype=np.int64)
    for i, sig in enumerate(sigs):
        yy = sndfit.evaluate(sig, d, cache)
        miss[i] = np.bincount(g, weights=(yy != y), minlength=len(groups)).astype(np.int64)
    mi = sigs.index(MELONDS)
    cx = [len(s[1]) + len(s[2]) + (s[0] is not None) for s in sigs]
    order = lambda i: (i != mi, cx[i], ms[sigs[i]])  # noqa: E731
    rep += [f"**One channel** ({len(rows1)} plateaus, {len(sigs)} pipelines; melonDS = `{ms[MELONDS]}`)\n",
            "| group | plateaus | exact | melonDS misses | simplest exact (or best) |",
            "| --- | ---: | ---: | ---: | --- |"]
    gsize = np.bincount(g, minlength=len(groups))
    for k, (div, pan) in enumerate(groups):
        ex = sorted((i for i in range(len(sigs)) if miss[i, k] == 0), key=order)
        if ex:
            best = "<br>".join(f"`{ms[sigs[i]]}`" for i in ex[:args.top])
        else:
            b = min(range(len(sigs)), key=lambda i: (miss[i, k], cx[i]))
            best = f"none; best `{ms[sigs[b]]}` ({miss[b, k]} misses)"
        rep.append(f"| d{div}_p{pan} | {gsize[k]} | {len(ex)} | {miss[mi, k]} | {best} |")
    every = sorted((i for i in range(len(sigs)) if not miss[i].any()), key=order)
    rep.append(f"\n**Exact on every group: {len(every)} pipeline(s).**")
    for i in every[:10]:
        rep.append(f"- `{ms[sigs[i]]}`{' (melonDS)' if i == mi else ''}")
    tot = miss.sum(axis=1)
    if not every:
        b = int(np.argmin(tot))
        rep.append(f"- best: `{ms[sigs[b]]}`, {tot[b]} misses of {len(rows1)} (melonDS: {tot[mi]})")

    # 3. Two channels
    if rows2:
        b2 = np.array([r[:9] for r in rows2], dtype=np.int64)
        names2 = [r[9] for r in rows2]
        cands = every[:args.top] if every else list(np.argsort(tot, kind="stable")[:args.top])
        if mi not in cands:
            cands.append(mi)
        rep += [f"\n**Two channels** ({len(dc2)} segments, {len(rows2)} plateaus; per channel = drops "
                "before the sum, after = drops on the sum)\n",
                "| one-channel pipeline | per channel | after the sum | misses | directed / staircase misses | segments off |",
                "| --- | --- | --- | ---: | ---: | ---: |"]
        directed = np.array([n.startswith("dc2_") for n in names2])
        n_exact = 0
        for i in cands:
            sig = sigs[i]
            for exdiv, before, after in splits(sig[2]):
                ta = pre_mid(sig, b2[:, 0], b2[:, 1], b2[:, 3]) * b2[:, 2]
                tb = pre_mid(sig, b2[:, 4], b2[:, 5], b2[:, 7]) * b2[:, 6]
                if exdiv:
                    ta, tb = ta << (4 - b2[:, 3]), tb << (4 - b2[:, 7])
                ta, tb = chain(ta, before, b2[:, 3]), chain(tb, before, b2[:, 7])
                yy = np.clip(chain(ta + tb, after, 0), -32768, 32767)
                off = yy != b2[:, 8]
                n_exact += not off.any()
                segoff = len({names2[k] for k in np.nonzero(off)[0]})
                pc = ("x 2^(4-ds); " if exdiv else "") + chain_text(before)
                rep.append(f"| `{ms[sig]}` | {pc} | {chain_text(after)} | "
                           f"{int(off.sum())}{' **exact**' if not off.any() else ''} | "
                           f"{int(off[directed].sum())} / {int(off[~directed].sum())} | {segoff} |")
        rep.append(f"\n**Two-channel placements exact: {n_exact}.**")
        ok2 = n_exact > 0

    # 4. Lag probe
    if lagp:
        rep += ["\n**Lag probe** (256 zero samples, then the step; expected = 256 x timer / 512 capture "
                "samples after the channel's start)\n",
                "| segment | ch | timer | first non-zero L / R | first at final L / R | expected | first non-zero - expected | samples around the step (L) |",
                "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |"]
        for name, seg in sorted(lagp.items()):
            v = seg["voices"][0]
            exp = 256 * v["timer"] / 512
            fn, ff = [], []
            for side in "LR":
                yv = seg[side]
                fin = int(np.median(yv[-64:]))
                nz = np.nonzero(yv)[0]
                fn.append(int(nz[0]) if len(nz) else -1)
                at = np.nonzero(yv == fin)[0]
                ff.append(int(at[0]) if len(at) else -1)
            k0 = max(fn[0] - 2, 0)
            around = " ".join(str(int(x)) for x in seg["L"][k0:k0 + 6])
            rep.append(f"| {name} | {v['ch']} | {v['timer']} | {fn[0]} / {fn[1]} | {ff[0]} / {ff[1]} | "
                       f"{exp:.1f} | {fn[0] - exp:+.1f} | {around} |")

    text = "\n".join(rep) + "\n"
    print(text, end="")
    if args.out:
        with open(args.out, "w") as f:
            f.write(text)
    return 0 if every and ok2 else 1


if __name__ == "__main__":
    sys.exit(main())
