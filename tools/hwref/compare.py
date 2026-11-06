#!/usr/bin/env python3
"""Compare two hwref result folders (docs/hw-reference.md).

    tools/hwref/compare.py A B [--out DIR] [--names ds,melonds]

A and B are /hwref/ folders (real DS, melonDS, the core). Writes DIR/report.md
and, for the 3D captures, DIR/png/<scene>_<src>_{a,b,diff}.png. Exits 1 when
anything differs (timing: beyond --tol cycles per body), 0 otherwise.

- cap3d_*.bin: 256x192 little-endian u16 (RGB555 + bit 15), compared on all
  16 bits. The diff image is A dimmed with differing pixels in magenta.
- gxtime_summary.csv: per-test cycles per body (from the drain timelines) and
  isolated latency; gxtime_swap.csv, gxtime_stall.csv; DMA and FIFO-IRQ
  timelines summarised from gxtime_events.csv.
"""
import argparse
import csv
import os
import struct
import sys
import zlib
from collections import defaultdict

W, H = 256, 192


def png(path, rgb, w=W, h=H):
    raw = b"".join(b"\0" + bytes(rgb[y * w * 3:(y + 1) * w * 3]) for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def to_rgb(px):
    out = bytearray(len(px) * 3)
    for i, v in enumerate(px):
        r, g, b = v & 31, (v >> 5) & 31, (v >> 10) & 31
        out[i * 3:i * 3 + 3] = bytes(((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2)))
    return out


def load_cap(path):
    d = open(path, "rb").read()
    if len(d) != W * H * 2:
        raise ValueError(f"{path}: {len(d)} bytes, expected {W * H * 2}")
    return struct.unpack(f"<{W * H}H", d)


def compare_caps(a, b, out, names, report):
    files = sorted(f for f in os.listdir(a) if f.startswith(("cap3d_", "rules3d_", "replay3d_")) and f.endswith(".bin"))
    if not files:
        return 0
    os.makedirs(os.path.join(out, "png"), exist_ok=True)
    report.append("## 3D captures\n")
    report.append(f"| capture | differing pixels | colour only | bit 15 only | bbox | max channel delta |")
    report.append("| --- | ---: | ---: | ---: | --- | ---: |")
    bad = 0
    for f in files:
        stem = f.split("_", 1)[1][:-4] if f.startswith("cap3d_") else f[:-4]
        pb = os.path.join(b, f)
        if not os.path.exists(pb):
            report.append(f"| {stem} | missing in {names[1]} | | | | |")
            bad += 1
            continue
        pa_, pb_ = load_cap(os.path.join(a, f)), load_cap(pb)
        diff = [i for i in range(W * H) if pa_[i] != pb_[i]]
        ra = to_rgb(pa_)
        png(os.path.join(out, "png", f"{stem}_a.png"), ra)
        if not diff:
            report.append(f"| {stem} | 0 | | | | |")
            continue
        bad += 1
        conly = sum(1 for i in diff if (pa_[i] ^ pb_[i]) & 0x7FFF and not (pa_[i] ^ pb_[i]) & 0x8000)
        aonly = sum(1 for i in diff if (pa_[i] ^ pb_[i]) == 0x8000)
        xs = [i % W for i in diff]
        ys = [i // W for i in diff]
        md = max(max(abs(((pa_[i] >> s) & 31) - ((pb_[i] >> s) & 31)) for s in (0, 5, 10)) for i in diff)
        png(os.path.join(out, "png", f"{stem}_b.png"), to_rgb(pb_))
        dimg = bytearray(x // 3 for x in ra)
        for i in diff:
            dimg[i * 3:i * 3 + 3] = b"\xff\x00\xff"
        png(os.path.join(out, "png", f"{stem}_diff.png"), dimg)
        report.append(f"| {stem} | {len(diff)} ({100 * len(diff) / (W * H):.2f}%) | {conly} | {aonly} | "
                      f"x {min(xs)}-{max(xs)}, y {min(ys)}-{max(ys)} | {md} |")
    report.append("")
    return bad


def read_csv(path):
    with open(path) as f:
        return [r for r in csv.reader(f) if r and not r[0].startswith("#")]


def compare_summary(a, b, names, report, tol):
    pa, pb = os.path.join(a, "gxtime_summary.csv"), os.path.join(b, "gxtime_summary.csv")
    if not os.path.exists(pa) or not os.path.exists(pb):
        return 0
    ra, rb = read_csv(pa), read_csv(pb)
    hdr = ra[0]
    ia = {r[0]: dict(zip(hdr, r)) for r in ra[1:]}
    ib = {r[0]: dict(zip(hdr, r)) for r in rb[1:]}
    report.append("## GX command timing (system cycles, 33.514 MHz)\n")
    report.append(f"Cycles per body = (D(n2) - D(n1)) / (n2 - n1) from the drain timelines; "
                  f"iso = one body from idle until GXSTAT busy clears (includes the polling loop).\n")
    report.append(f"| test | writes | {names[0]} cyc/body | {names[1]} cyc/body | delta | "
                  f"{names[0]} iso | {names[1]} iso | {names[0]} bit0 | {names[1]} bit0 |")
    report.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    bad = 0
    for t, x in ia.items():
        y = ib.get(t)
        if not y:
            report.append(f"| {t} | | | missing | | | |")
            bad += 1
            continue
        ca, cb = int(x["cyc_per_body_x100"]) / 100, int(y["cyc_per_body_x100"]) / 100
        d = cb - ca
        mark = " **!**" if abs(d) > tol else ""
        b0a, b0b = x.get("iso_bit0_min", "-"), y.get("iso_bit0_min", "-")
        bad += abs(d) > tol or x["iso_min"] != y["iso_min"] or b0a != b0b
        report.append(f"| {t} | {x['writes_per_body']} | {ca:.2f} | {cb:.2f} | {d:+.2f}{mark} | "
                      f"{x['iso_min']} | {y['iso_min']} | {b0a} | {b0b} |")
    report.append("")
    return bad


def compare_swap(a, b, names, report):
    pa, pb = os.path.join(a, "gxtime_swap.csv"), os.path.join(b, "gxtime_swap.csv")
    if not os.path.exists(pa) or not os.path.exists(pb):
        return 0

    def agg(rows):
        m = defaultdict(list)
        for r in rows[1:]:
            if r[0].isdigit():
                m[(int(r[0]), int(r[1]))].append((int(r[3]), int(r[4])))
        return m

    def polys(rows):
        m = defaultdict(list)
        for r in rows:
            if r[0] == "swap_poly":
                m[int(r[1])].append(int(r[3]))
        return m
    ra, rb = read_csv(pa), read_csv(pb)
    ma, mb = agg(ra), agg(rb)
    report.append("## SWAP_BUFFERS: cycles from the write (at VCOUNT line) until busy clears\n")
    report.append(f"| line | param | {names[0]} min/max | {names[1]} min/max | VCOUNT after ({names[0]}/{names[1]}) |")
    report.append("| ---: | ---: | --- | --- | --- |")
    bad = 0
    for k in sorted(ma):
        xa, xb = ma[k], mb.get(k, [])
        fa = f"{min(c for c, _ in xa)}/{max(c for c, _ in xa)}"
        fb = f"{min(c for c, _ in xb)}/{max(c for c, _ in xb)}" if xb else "missing"
        bad += fa != fb
        report.append(f"| {k[0]} | {k[1]} | {fa} | {fb} | {xa[0][1]}/{xb[0][1] if xb else '-'} |")
    pa_, pb_ = polys(ra), polys(rb)
    if pa_:
        report.append(f"\nSWAP at line 150 with N triangles in polygon RAM:\n")
        report.append(f"| triangles | {names[0]} min/max | {names[1]} min/max |")
        report.append("| ---: | --- | --- |")
        for n in sorted(pa_):
            fa = f"{min(pa_[n])}/{max(pa_[n])}"
            fb = f"{min(pb_[n])}/{max(pb_[n])}" if n in pb_ else "missing"
            bad += fa != fb
            report.append(f"| {n} | {fa} | {fb} |")
    report.append("")
    return bad


def stall_stats(rows):
    m = defaultdict(list)
    for r in rows[1:]:
        m[r[0]].append(int(r[2]))
    out = {}
    for t, ts in m.items():
        gaps = [ts[i + 1] - ts[i] for i in range(len(ts) - 1)]
        cap = next((i for i, g in enumerate(gaps) if g > 10000), None)
        after = gaps[cap + 1:-1] if cap is not None else []
        out[t] = (cap, sorted(gaps[:cap])[len(gaps[:cap]) // 2] if cap else None,
                  sorted(after)[len(after) // 2] if after else None, ts[-1])
    return out


def compare_stall(a, b, names, report):
    pa, pb = os.path.join(a, "gxtime_stall.csv"), os.path.join(b, "gxtime_stall.csv")
    if not os.path.exists(pa) or not os.path.exists(pb):
        return 0
    sa, sb = stall_stats(read_csv(pa)), stall_stats(read_csv(pb))
    report.append("## FIFO-full CPU stall (SWAP pending, then one command per write)\n")
    report.append("Writes accepted before the first stall; median cycles per write before it "
                  "(CPU speed) and after VBlank (engine drain rate); total.\n")
    report.append(f"| test | {names[0]} | {names[1]} |")
    report.append("| --- | --- | --- |")
    bad = 0
    for t in sa:
        x, y = sa[t], sb.get(t)
        bad += x != y
        report.append(f"| {t} | {x} | {y} |")
    report.append("")
    return bad


def events(path):
    m = defaultdict(list)
    with open(path) as f:
        for r in csv.reader(f):
            if len(r) == 6 and r[2] == "0":
                m[(r[0], int(r[1]))].append((int(r[4]), int(r[5], 16)))
    return m


def timeline_stats(ev):
    """First level drop, IRQ flag rise, DMA end, engine idle; DMA bursts (level rises)."""
    lvl = [(t, (s >> 16) & 0x1FF) for t, s in ev]
    t0 = next((t for (t, l), (_, lp) in zip(lvl[1:], lvl) if l < lp), None)
    irq = next((t for t, s in ev if s & (1 << 28)), None)
    dma_end = next((t for (t, s), (_, sp) in zip(ev[1:], ev) if sp & (1 << 29) and not s & (1 << 29)), None)
    rises = sum(1 for (t, l), (_, lp) in zip(lvl[1:], lvl) if l > lp + 8)
    rel = lambda x: None if x is None or t0 is None else x - t0
    return dict(irq=rel(irq), dma_end=rel(dma_end), idle=rel(ev[-1][0]), bursts=rises)


def compare_events(a, b, names, report):
    pa, pb = os.path.join(a, "gxtime_events.csv"), os.path.join(b, "gxtime_events.csv")
    if not os.path.exists(pa) or not os.path.exists(pb):
        return 0
    ea, eb = events(pa), events(pb)
    keys = [k for k in ea if k[0].startswith(("dma_", "irq_"))]
    report.append("## GX FIFO DMA and FIFO IRQ timelines (cycles after the first FIFO-level drop)\n")
    report.append(f"| test | {names[0]} irq / dma end / idle / bursts | {names[1]} |")
    report.append("| --- | --- | --- |")
    bad = 0
    for k in keys:
        x = timeline_stats(ea[k])
        y = timeline_stats(eb[k]) if k in eb else None
        bad += x != y
        f = lambda s: "missing" if s is None else f"{s['irq']} / {s['dma_end']} / {s['idle']} / {s['bursts']}"
        report.append(f"| {k[0]} | {f(x)} | {f(y)} |")
    # whole-timeline identity for every test
    same = sum(1 for k in ea if eb.get(k) == ea[k])
    report.append(f"\nRep-0 event timelines identical: {same} of {len(ea)}.\n")
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--out", default="build/hwref/compare")
    ap.add_argument("--names", default="A,B")
    ap.add_argument("--tol", type=float, default=0.5, help="cycles per body (default 0.5)")
    o = ap.parse_args()
    names = o.names.split(",")
    os.makedirs(o.out, exist_ok=True)
    report = [f"# hwref compare: {names[0]} = `{o.a}`, {names[1]} = `{o.b}`\n"]
    for n, d in zip(names, (o.a, o.b)):
        for info in ("gxtime_info.txt", "cap3d_info.txt"):
            p = os.path.join(d, info)
            if os.path.exists(p):
                report.append(f"{n} {info}: `{open(p).readline().strip()}`  ")
    report.append("")
    bad = 0
    bad += compare_summary(o.a, o.b, names, report, o.tol)
    bad += compare_swap(o.a, o.b, names, report)
    bad += compare_stall(o.a, o.b, names, report)
    bad += compare_events(o.a, o.b, names, report)
    bad += compare_caps(o.a, o.b, o.out, names, report)
    report.insert(1, f"**{'DIFFERENT' if bad else 'IDENTICAL'}**: {bad} differing items.\n")
    with open(os.path.join(o.out, "report.md"), "w") as f:
        f.write("\n".join(report) + "\n")
    print(f"{'DIFFERENT' if bad else 'IDENTICAL'}: {bad} differing items; report {o.out}/report.md")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
