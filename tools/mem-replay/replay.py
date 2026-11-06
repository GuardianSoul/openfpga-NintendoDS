#!/usr/bin/env python3
"""Plan 0.4: replay the census memory demand through openfpga-PlayStation's measured
memory costs and search VRAM bank placements.

    python3 tools/mem-replay/replay.py build/census/{heartgold,platinum,kh358,mkds,nsmb}

Demand (per DS line, 63.56 us), from tools/melonds-census:
  vram_lines.csv  per frame, line, unit (2da, 2db, 3d, cap) and bank: distinct
                  bytes, 8-byte fetches (no cache) and 32-byte blocks (per-line cache)
  frames.csv      per frame: ARM9/ARM7 main-RAM bus bytes, DMA bytes, cartridge
                  bytes, polygon line coverage (poly_lines, line_polys_max)
Supply: nanoseconds per access with one request in flight, from openfpga-PlayStation
docs/memory-bandwidth.md (SDRAM, PSRAM) or assumed (SRAM). See COSTS.
Deadlines: 2D reads and capture writes must finish within their line; 3D
texture reads and the polygon stream may spread over the rasterizer's
WINDOW-line ring. CPU and DMA traffic is spread evenly over its frame.
"""
import argparse
import csv
import itertools
import sys
from pathlib import Path

import numpy as np

LINE_NS = 63_556.0          # 2130 cycles at 33.514 MHz
LINES = 263
BANKS = "ABCDEFGHI"
BANK_KB = dict(A=128, B=128, C=128, D=128, E=64, F=16, G=16, H=32, I=16)

# ns per access, one request in flight (openfpga-PlayStation docs/memory-bandwidth.md).
#   sdram: psx_sdram with pipelined reads: 8 B 54.1 MB/s, 16 B 87.4 MB/s; writes 121.9/161.9 MB/s.
#          32 B read extrapolated linearly from the 8/16 B points.
#   sdram_native: Codex's native VRAM port incl. CDC: small reads 21.9/41.6 MB/s (pessimistic bound).
#   psram: paired dies, PocketQuake recipe (hardware-verified): WAIT-gated burst reads,
#          128 ns + 4 ns/B (4 B 144 ns, 16 B 192 ns, 64 B 384 ns); async writes ~75 ns per 4 B.
#   sram:  ASSUMED, not measured: 20 ns per 16-bit access (async 10 ns part, conservative).
COSTS = {
    "sdram":        dict(r8=148, r32=253, w16=99),
    "sdram_native": dict(r8=365, r32=420, w16=99),
    "psram":        dict(r8=160, r32=256, w16=300),
    "sram":         dict(r8=80, r32=320, w16=160),
    "m10k":         dict(r8=0, r32=0, w16=0),
}
POLY_BYTES = 80             # 16 B header + 4 x 16 B vertex beats per polygon per line


def load_game(d, window):
    """Per-line ns demand components for one game, indexed [line]."""
    rows = list(csv.DictReader(open(Path(d, "vram_lines.csv"))))
    frames = sorted({int(r["frame"]) for r in rows})
    f0 = frames[0]
    n = len(frames) * LINES
    idx = lambda r: (int(r["frame"]) - f0) * LINES + int(r["line"])
    # [unit][bank] -> arrays of seq8 / b32 / bytes per line
    z = lambda: np.zeros(n)
    dem = {u: {b: dict(seq8=z(), b32=z(), bytes=z()) for b in BANKS} for u in ("2d", "3d", "cap")}
    for r in rows:
        b = r["bank"]
        if b not in BANKS:
            continue
        u = {"2da": "2d", "2db": "2d", "3d": "3d", "cap": "cap"}[r["unit"]]
        i = idx(r)
        for k in ("seq8", "b32", "bytes"):
            dem[u][b][k][i] += int(r[k])
    fr = {int(r["frame"]): r for r in csv.DictReader(open(Path(d, "frames.csv")))}
    main = z(); poly_line = z(); poly_frame = z(); cart = z()
    for k, f in enumerate(frames):
        r = fr[f]
        sl = slice(k * LINES, (k + 1) * LINES)
        cpu = int(r["arm9_main_bytes"]) + int(r["arm7_main_bytes"]) + int(r["dma9_bytes"]) + int(r["dma7_bytes"])
        main[sl] = cpu / LINES
        # worst line of the frame, applied to every line of the frame (conservative)
        poly_line[sl] = int(r["line_polys_max"]) * POLY_BYTES
        poly_frame[sl] = int(r["polys"]) * POLY_BYTES / LINES
        cart[sl] = 2 * int(r["cart_bytes"]) / LINES      # SD -> cache write + read
    return dict(name=Path(d).name, n=n, dem=dem, main=main, poly_line=poly_line,
                poly_frame=poly_frame, cart=cart, window=window)


def smooth(v, w):
    if w <= 1:
        return v
    return np.convolve(v, np.ones(w) / w, mode="same")


def bank_ns(g, bank, mem, cache2d, cache3d, window):
    """ns per line that `bank` costs on memory `mem`."""
    c = COSTS[mem]
    d2, d3, dc = g["dem"]["2d"][bank], g["dem"]["3d"][bank], g["dem"]["cap"][bank]
    t2 = d2["b32"] * c["r32"] if cache2d else d2["seq8"] * c["r8"]
    t3 = d3["b32"] * c["r32"] if cache3d else d3["seq8"] * c["r8"]
    tc = dc["bytes"] / 16 * c["w16"]
    return t2 + smooth(t3, window) + tc


def fixed_ns(g, mem, what, polymode, window):
    c = COSTS[mem]
    if what == "main":
        # CPU line fills and DMA are mostly 32 B bursts; cartridge streaming shares this memory
        return (g["main"] + g["cart"]) / 32 * c["r32"]
    if what == "poly":
        v = g["poly_line"] if polymode == "refetch" else g["poly_frame"]
        return smooth(v / 32 * c["r32"], window)
    raise ValueError(what)


def search(games, args, cache2d, cache3d, polymode, sdram="sdram"):
    mems = [sdram, "psram", "sram", "m10k"]
    w = args.window
    # per memory, per bank: concatenated per-line ns over all games
    vec = {m: {b: np.concatenate([bank_ns(g, b, m, cache2d, cache3d, w) for g in games]) for b in BANKS} for m in mems}
    fix = {m: {k: np.concatenate([fixed_ns(g, m, k, polymode, w) for g in games]) for k in ("main", "poly")} for m in mems}
    budget = args.util * LINE_NS
    # peak utilization for every subset of banks on each memory, with/without main/poly
    subsets = list(range(1 << len(BANKS)))
    peak = {}
    for m in (sdram, "psram", "sram"):
        for extra in itertools.product((0, 1), repeat=2):
            base = sum(fix[m][k] for k, e in zip(("main", "poly"), extra) if e) if any(extra) else 0
            acc = {}
            for s in subsets:
                if s == 0:
                    v = np.zeros_like(vec[m]["A"]) + base
                else:
                    low = s & -s
                    v = acc[s & ~low] + vec[m][BANKS[low.bit_length() - 1]]
                acc[s] = v
                peak[(m, extra, s)] = v.max() / budget
    best = []
    for assign in itertools.product(range(4), repeat=len(BANKS)):
        sets = [0, 0, 0, 0]
        kb = [0, 0, 0, 0]
        for i, a in enumerate(assign):
            sets[a] |= 1 << i
            kb[a] += BANK_KB[BANKS[i]]
        if kb[2] > args.sram_kb or kb[3] > args.m10k_kb:
            continue
        for main_m, poly_m in itertools.product((0, 1), repeat=2):   # 0 = SDRAM, 1 = PSRAM
            if polymode == "cached":
                pass
            e_sd = (int(main_m == 0), int(poly_m == 0))
            e_ps = (int(main_m == 1), int(poly_m == 1))
            u = max(peak[(sdram, e_sd, sets[0])], peak[("psram", e_ps, sets[1])],
                    peak[("sram", (0, 0), sets[2])])
            best.append((u, assign, main_m, poly_m))
    best.sort(key=lambda x: x[0])
    return best, vec, fix


def describe(assign, main_m, poly_m, sdram="sdram"):
    names = [sdram, "psram", "sram", "m10k"]
    out = {}
    for i, a in enumerate(assign):
        out.setdefault(names[a], []).append(BANKS[i])
    s = "  ".join(f"{k}: {''.join(v)}" for k, v in out.items())
    return f"{s}  | main RAM: {['sdram', 'psram'][main_m]}  polygon RAM: {['sdram', 'psram'][poly_m]}"


def per_game(games, args, cache2d, cache3d, polymode, assign, main_m, poly_m, sdram="sdram"):
    names = [sdram, "psram", "sram", "m10k"]
    rows = []
    for g in games:
        line = {}
        for mi, m in enumerate(names[:3]):
            v = sum(bank_ns(g, BANKS[i], m, cache2d, cache3d, args.window) for i, a in enumerate(assign) if a == mi)
            v = v + 0
            if (mi == 0 and main_m == 0) or (mi == 1 and main_m == 1):
                v = v + fixed_ns(g, m, "main", polymode, args.window)
            if (mi == 0 and poly_m == 0) or (mi == 1 and poly_m == 1):
                v = v + fixed_ns(g, m, "poly", polymode, args.window)
            if np.isscalar(v):
                v = np.zeros(g["n"])
            u = v / (args.util * LINE_NS)
            line[m] = (u.max(), int((u > 1).sum()), np.percentile(u, 99))
        rows.append((g["name"], line))
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("games", nargs="+")
    ap.add_argument("--window", type=int, default=4, help="3D ring lines (default 4)")
    ap.add_argument("--util", type=float, default=0.85, help="usable fraction of each line (refresh, turnaround)")
    ap.add_argument("--m10k-kb", type=int, default=128, help="M10K left for VRAM banks")
    ap.add_argument("--sram-kb", type=int, default=256)
    ap.add_argument("--top", type=int, default=3)
    args = ap.parse_args()
    games = [load_game(d, args.window) for d in args.games]
    print(f"games: {', '.join(g['name'] for g in games)}; {sum(g['n'] for g in games)} lines; "
          f"window {args.window}, util {args.util}, M10K {args.m10k_kb} KB, SRAM {args.sram_kb} KB\n")
    for sdram in ("sdram", "sdram_native"):
        for cache2d, cache3d, polymode in [(False, False, "refetch"), (True, True, "refetch"),
                                           (True, True, "cached"), (False, False, "cached")]:
            best, _, _ = search(games, args, cache2d, cache3d, polymode, sdram)
            tag = (f"{sdram:12s} 2D {'32B cache' if cache2d else 'no cache '}  3D {'32B cache' if cache3d else 'no cache '}  "
                   f"polygons {'re-fetched per line' if polymode == 'refetch' else 'fetched once (active cache)'}")
            u, assign, mm, pm = best[0]
            print(f"{tag}\n  best peak utilization {u:.2f}  ({describe(assign, mm, pm, sdram)})")
            for name, line in per_game(games, args, cache2d, cache3d, polymode, assign, mm, pm, sdram):
                cells = "  ".join(f"{m} max {v[0]:.2f} p99 {v[2]:.2f} over {v[1]}" for m, v in line.items() if v[0] > 0)
                print(f"    {name:10s} {cells}")
            print()


if __name__ == "__main__":
    main()
