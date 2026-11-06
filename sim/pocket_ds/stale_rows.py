#!/usr/bin/env python3
"""Stale-ring rows in a scene run (the 3D line ring showing an old line instead of the one due).

    stale_rows.py POCKET_SHOTS MEL_SHOTS REL [E0] [--screen top|bottom|both]

For each Pocket frame from the 4th after the release (REL: the video frame of the release, run.log; E0: the
export's frame in melonDS's numbering, exp/clean.txt), against the nearest melonDS frame: a row is stale when
it differs from melonDS (more than 16 pixels) and equals the row 4 or 8 lines above it in the same Pocket
frame (the ring's staging periods; at most 2 pixels apart), while melonDS's two rows differ (so it is not
just a flat area). A row equal to the row just above is not stale: late lines drawn as the rear plane (the smear fix) repeat
each other with period 1, while a ring slot shown again repeats with the slot period only.
Prints the stale rows per frame and a total; exits 1 if there are any.
"""
import sys
from pathlib import Path


def px(p):
    d = p.read_bytes()
    e = 0
    for _ in range(3):
        e = d.index(b'\n', e) + 1
    return d[e:e + 256 * 384 * 3]


def row(img, y):
    return img[y * 768:(y + 1) * 768]


def ndiff(a, b):
    return sum(1 for i in range(0, 768, 3) if max(abs(a[i] - b[i]), abs(a[i + 1] - b[i + 1]), abs(a[i + 2] - b[i + 2])) > 8)


def stale_in(c, m, ys=range(384)):
    """the stale rows of Pocket frame c (pixels, px()) against melonDS frame m"""
    stale = []
    for y in ys:
        top = 0 if y < 192 else 192
        if ndiff(row(c, y), row(m, y)) <= 16:
            continue
        # a run of late lines drawn as the rear plane repeats with period 1 (flat), not just 4 or 8
        if y - 1 >= top and ndiff(row(c, y), row(c, y - 1)) <= 2:
            continue
        # a row of one colour is no ring slot shown again (kh-movie: a missing 2D image, black rows
        # between sparse ones); the pixel difference reports it
        r = row(c, y)
        if all(r[i:i + 3] == r[0:3] for i in range(3, 768, 3)):
            continue
        for d in (4, 8):
            yy = y - d
            if yy >= top and ndiff(row(c, y), row(c, yy)) <= 2 and ndiff(row(m, y), row(m, yy)) > 16:
                stale.append(y)
                break
    return stale


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    screen = next((a.split('=')[1] for a in sys.argv[1:] if a.startswith('--screen=')), 'both')
    core, mel, rel = Path(args[0]), Path(args[1]), int(args[2])
    e0 = int(args[3]) if len(args) > 3 else 0
    mels = {int(f.stem[1:]) - e0: px(f) for f in mel.glob('f*.ppm')}
    ys = range(0, 192) if screen == 'top' else range(192, 384) if screen == 'bottom' else range(0, 384)
    total = 0
    for f in sorted(core.glob('f*.ppm')):
        v = int(f.stem[1:])
        k = v - rel
        if k < 4:
            continue
        c = px(f)
        best = min(((sum(ndiff(row(c, y), row(m, y)) for y in range(0, 384, 4)), j) for j, m in mels.items()
                    if k - 4 <= j <= k + 1), default=None)
        if best is None:
            continue
        m = mels[best[1]]
        stale = stale_in(c, m, ys)
        total += len(stale)
        if stale:
            print(f'pocket f{v} ~ melonDS f{best[1]}: {len(stale)} stale rows: {stale[:20]}{" ..." if len(stale) > 20 else ""}')
    print(f'stale rows: {total}')
    sys.exit(1 if total else 0)


if __name__ == '__main__':
    main()
