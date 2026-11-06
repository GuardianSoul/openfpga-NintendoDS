#!/usr/bin/env python3
"""The core's actual memory placement through replay.py's demand and costs
(docs/phase2-integration.md, "First fit with 3D"):

    python3 tools/mem-replay/placement.py build/census/{kh358,heartgold,mkds,nsmb,...} [--poly psram|sdram]

  SDRAM  all VRAM banks (2D blocks through the 32-byte line caches, 3D
         texels through the 32-byte texture cache, capture writes) and the
         cartridge cache
  PSRAM  main RAM (ARM9/ARM7 bus bytes and DMA as 32-byte bursts)
  SRAM   ARM7 WRAM, shared WRAM and BIOS7 (ARM9/ARM7 WRAM and ARM7 BIOS
         bytes, every access uncached: an upper bound on the ARM7 port caches)
  poly   the polygon store, on PSRAM or SDRAM: each polygon written once by
         the geometry engine and read once into the on-chip active list,
         80 bytes each way (16-byte header, four 16-byte vertices)

Per memory and game: the busiest line's utilization (max), the 99th
percentile and the lines over budget, with --util of each line usable.
3D texels and the polygon stream spread over --window lines; CPU, DMA,
cartridge and polygon traffic is spread evenly over its frame.
"""
import argparse
import csv
from pathlib import Path

import numpy as np

import replay

POLY_BYTES = 80


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("games", nargs="+")
    ap.add_argument("--poly", choices=("psram", "sdram"), default="psram")
    ap.add_argument("--window", type=int, default=8, help="3D ring lines (nds_gpu3d RB=3: 8)")
    ap.add_argument("--util", type=float, default=0.85)
    a = ap.parse_args()
    budget = a.util * replay.LINE_NS
    print(f"polygon store on {a.poly}; window {a.window}; util {a.util}\n")
    print(f"{'game':14s} {'memory':6s} {'max':>6s} {'p99':>6s} {'over':>6s}   of which (max line, us): ")
    for d in a.games:
        g = replay.load_game(d, a.window)
        fr = {int(r["frame"]): r for r in csv.DictReader(open(Path(d, "frames.csv")))}
        frames = sorted(fr)
        f0 = min(int(r["frame"]) for r in csv.DictReader(open(Path(d, "vram_lines.csv"))))
        frames = [f for f in frames if f >= f0][: g["n"] // replay.LINES]
        n = g["n"]
        sram = np.zeros(n); poly = np.zeros(n)
        for k, f in enumerate(frames):
            r = fr[f]
            sl = slice(k * replay.LINES, (k + 1) * replay.LINES)
            b = int(r["arm9_wram_bytes"]) + int(r["arm7_wram_bytes"]) + int(r["arm7_bios_bytes"])
            sram[sl] = b / replay.LINES / 4 * (2 * 20.0 * 1.5)   # 32-bit = two 16-bit accesses, 1.5x for writes/turnaround
            poly[sl] = int(r["polys"]) * POLY_BYTES / replay.LINES
        sd = sum(replay.bank_ns(g, b, "sdram", True, True, a.window) for b in replay.BANKS)
        sd = sd + g["cart"] / 32 * replay.COSTS["sdram"]["r32"]
        ps = g["main"] / 32 * replay.COSTS["psram"]["r32"]
        pc = replay.COSTS[a.poly]
        poly_ns = replay.smooth(poly / 32 * pc["r32"] + poly / 16 * pc["w16"], a.window)
        if a.poly == "psram":
            ps = ps + poly_ns
        else:
            sd = sd + poly_ns
        for name, v, parts in (("sdram", sd, {"poly": poly_ns if a.poly == "sdram" else 0}),
                               ("psram", ps, {"poly": poly_ns if a.poly == "psram" else 0}),
                               ("sram", sram, {})):
            u = v / budget
            i = int(np.argmax(u))
            extra = "  ".join(f"{k} {(p[i] if not np.isscalar(p) else p) / 1000:.1f}" for k, p in parts.items())
            print(f"{g['name']:14s} {name:6s} {u.max():6.2f} {np.percentile(u, 99):6.2f} {int((u > 1).sum()):6d}   "
                  f"total {v[i] / 1000:.1f} {extra}")
        print()


if __name__ == "__main__":
    main()
