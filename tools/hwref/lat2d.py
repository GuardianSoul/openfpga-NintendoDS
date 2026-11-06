#!/usr/bin/env python3
"""Reads lat2d's output (docs/hw-reference.md "lat2d"): for every write, the
first captured line and pixel showing the new state.

  lat2d.py DIR
"""
import csv
import os
import struct
import sys

ROW0, NROWS, LINE = 88, 16, 96


def state(kind, x, v):
    """True where the pixel shows the state after the write."""
    r, g, b = v & 31, (v >> 5) & 31, (v >> 10) & 31
    if kind == "hofs":
        if b != 16:
            return None
        return r + 32 * g - 1 == ((x + 64) & 255) % 255   # index - 1 = source x mod 255
    if kind == "pal":
        return v & 0x7FFF == 0x001F
    src = r + 32 * g - 1 if b == 16 else None   # BG pixel: source x mod 255
    if kind == "bg0cnt":   # map 29 is shifted by 4 tiles = 32 px
        return src == ((x + 32) & 255) % 255
    if kind == "win0h":    # BG0 visible left of the old 1-px window
        return x < 200 and src is not None
    if kind == "oam":      # the red OBJ at its new X
        return 128 <= x < 192 and v & 0x7FFF == 0x001F
    if kind == "mosaic":   # pixels repeat in groups of 8
        return x % 8 != 0 and src == (x - x % 8) % 255
    if kind == "bg2x":
        return src == ((x + 64) & 255) % 255
    return b == 16 and v & 0x7FFF != 0x7C00   # bgon, bgon_fine: a BG0 pixel, not the backdrop


def main():
    d = sys.argv[1]
    writes = list(csv.DictReader(open(os.path.join(d, "lat2d_writes.csv"))))
    raw = open(os.path.join(d, "lat2d_rows.bin"), "rb").read()
    print("kind  d     write@   first new: line  x    (line %d starts at VCOUNT change; 2130 ticks/line)" % LINE)
    for n, w in enumerate(writes):
        px = struct.unpack_from(f"<{NROWS * 256}H", raw, n * NROWS * 512)
        first = None
        for row in range(NROWS):
            for x in range(256):
                st = state(w["kind"], x, px[row * 256 + x])
                if st:
                    first = (ROW0 + row, x)
                    break
            if first:
                break
        mixed = ""
        if first and w["kind"] in ("hofs", "pal", "bgon", "bg0cnt", "bg2x"):
            row = first[0] - ROW0
            line = [state(w["kind"], x, px[row * 256 + x]) for x in range(256)]
            if not all(line[first[1]:]):
                mixed = " (not the whole rest of the line)"
        print(f"{w['kind']:5s} {int(w['d_ticks']):5d} {int(w['write_ticks_after_vcount']):6d}   "
              f"{str(first[0]) if first else '-':>5s} {str(first[1]) if first else '-':>4s}{mixed}")
    p = os.path.join(d, "lat2d_vramwait.csv")
    if os.path.exists(p):
        print("\nCPU wait states (ticks for 256 accesses, line 96 = display, 200 = VBlank):")
        for r in csv.DictReader(open(p)):
            print(f"  {r['target']:10s} {r['op']:10s} line {r['line']:3s} {r['ticks_for_256']}")
    p = os.path.join(d, "lat2d_dma.bin")
    if os.path.exists(p):
        raw = open(p, "rb").read()
        px = struct.unpack(f"<{len(raw) // 2}H", raw)
        print("\nHBlank DMA to BG0HOFS (table entry i = 7i mod 255): entry shown per line")
        for src, name in enumerate(("main RAM", "VRAM B")):
            ent = []
            for y in range(192):
                v = px[src * 192 + y]
                hofs = (v & 31) + 32 * ((v >> 5) & 31) - 1   # source x at screen x = 0 (mod 255)
                ent.append(next((i for i in range(255) if (7 * i) % 255 == hofs % 255), None))
            off = {(e - y) if e is not None else None for y, e in enumerate(ent) if y >= 8}
            print(f"  {name}: lines 0-7 {ent[:8]}, entry - line on lines 8-191: {sorted(off, key=str)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
