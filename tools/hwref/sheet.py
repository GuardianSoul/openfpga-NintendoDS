#!/usr/bin/env python3
"""Contact sheet of 256x192 captures: sheet.py OUT.png [--cols N] FILE.bin...
or of rand3d scenes: sheet.py OUT.png --rand3d DIR FIRST COUNT."""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import png, to_rgb, load_cap, W, H  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("files", nargs="*")
    ap.add_argument("--cols", type=int, default=4)
    ap.add_argument("--rand3d", nargs=3, metavar=("DIR", "FIRST", "COUNT"))
    o = ap.parse_args()
    if o.rand3d:
        import rand3d
        sc = rand3d.unpack(o.rand3d[0])
        first, n = int(o.rand3d[1]), int(o.rand3d[2])
        caps = [sc[i] for i in range(first, first + n) if i in sc]
    else:
        caps = [load_cap(f) for f in o.files]
    cols = o.cols
    rows = (len(caps) + cols - 1) // cols
    img = bytearray(cols * W * rows * H * 3)
    for k, c in enumerate(caps):
        rgb = to_rgb(c)
        cx, cy = k % cols, k // cols
        for y in range(H):
            p = ((cy * H + y) * cols * W + cx * W) * 3
            img[p:p + W * 3] = rgb[y * W * 3:(y + 1) * W * 3]
    png(o.out, img, cols * W, rows * H)
    return 0


if __name__ == "__main__":
    sys.exit(main())
