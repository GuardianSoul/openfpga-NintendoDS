#!/usr/bin/env python3
"""Frame pace of an imported scene: game frames per video frame, against melonDS (docs/state-import.md).

    sim/ds/scene_pace.py CORE_SHOTS MEL_SHOTS [--e0 N] [--from K]

CORE_SHOTS: the core's frames after an import (tb_ds --import-state ... --shots DIR --shot-every 1:
f000001.ppm...; or the Pocket model's fNNN.ppm with --from set past its release frame). MEL_SHOTS: melonDS's
frames from the same export (census --export-clean ... --shot-every 1; --e0 the frame in DIR/clean.txt).
Each core frame is matched to the melonDS frame nearest in pixels (both screens). The pace is the matched
game frames advanced per core frame over the run: 1.00 is full speed; 0.50 is one game frame every two video
frames. Frames matching no melonDS frame within 2% of the pixels are listed as unmatched.
"""
import argparse
from pathlib import Path


def screens(p):
    data = p.read_bytes()
    end = 0
    for _ in range(3):
        end = data.index(b'\n', end) + 1
    return data[end:end + 256 * 384 * 3]


def diff(a, b):
    return sum(1 for i in range(0, len(a), 3)
               if max(abs(a[i] - b[i]), abs(a[i + 1] - b[i + 1]), abs(a[i + 2] - b[i + 2])) > 8)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('core', type=Path)
    ap.add_argument('mel', type=Path)
    ap.add_argument('--e0', type=int, default=0, help="the export's frame in melonDS's numbering (clean.txt)")
    ap.add_argument('--from', dest='first', type=int, default=3, help='first core frame to match (default 3: past the release)')
    a = ap.parse_args()
    mel = {int(f.stem[1:]) - a.e0: screens(f) for f in a.mel.glob('f*.ppm')}
    core = sorted((int(f.stem[1:]), f) for f in a.core.glob('f*.ppm'))
    tol = 256 * 384 * 2 // 100
    matched = []
    for n, f in core:
        if n < a.first:
            continue
        c = screens(f)
        best = min(((diff(c, m), j) for j, m in mel.items() if abs(j - (n - a.first)) <= 40), default=None)
        if best is None:
            continue
        d, j = best
        print(f'core f{n}: melonDS f{j} ({d} px)' + ('' if d <= tol else '  unmatched'))
        if d <= tol:
            matched.append((n, j))
    if len(matched) < 2:
        raise SystemExit('pace: fewer than two matched frames')
    (n0, j0), (n1, j1) = matched[0], matched[-1]
    print(f'pace: {(j1 - j0) / (n1 - n0):.2f} game frames per video frame '
          f'(core f{n0}..f{n1} = melonDS f{j0}..f{j1}; {len(matched)} of {sum(1 for n, _ in core if n >= a.first)} frames matched)')


if __name__ == '__main__':
    main()
