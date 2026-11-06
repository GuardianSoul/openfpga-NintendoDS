#!/usr/bin/env python3
"""Match tb_ds frames against a melonDS census run (docs/compat.md).

tb_ds runs behind melonDS (it boots through the card, and CPU-bound frames
take longer), so frames are not compared by index. Every tb_ds frame should
equal *some* melonDS frame exactly; one that does not is a mismatch. For a
mismatch the nearest melonDS frame (around the last matched one) is given
with its differing pixel count, and whether melonDS drew 3D there (the core
under test has 3D off, so those are counted apart).

  framematch.py MEL_OUT RTL_SHOTS [--window N] [--json]
MEL_OUT is the census --out directory (shots/, frames.csv).
"""
import argparse, csv, glob, hashlib, json, os, sys
import numpy as np


def load(path):
    with open(path, 'rb') as f:
        data = f.read()
    # "P6\n256 384\n255\n"
    hdr = data.split(b'\n', 3)
    return np.frombuffer(hdr[3], dtype=np.uint8).reshape(384, 256, 3)


def frames(dirname):
    out = {}
    for p in glob.glob(os.path.join(dirname, 'f*.ppm')):
        out[int(os.path.basename(p)[1:7])] = p
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mel')
    ap.add_argument('rtl')
    ap.add_argument('--window', type=int, default=120)
    ap.add_argument('--json', action='store_true')
    a = ap.parse_args()

    mel = frames(os.path.join(a.mel, 'shots'))
    rtl = frames(a.rtl)
    polys = {}
    fcsv = os.path.join(a.mel, 'frames.csv')
    if os.path.exists(fcsv):
        with open(fcsv) as f:
            for row in csv.DictReader(f):
                # shots/fN is written after frame N-1 ran
                polys[int(row['frame']) + 1] = int(row.get('polys', 0) or 0)
    mh, mimg = {}, {}
    for n, p in sorted(mel.items()):
        img = load(p)
        mimg[n] = img
        mh.setdefault(hashlib.md5(img.tobytes()).hexdigest(), []).append(n)

    last = 0
    res = []
    for n in sorted(rtl):
        img = load(rtl[n])
        hits = mh.get(hashlib.md5(img.tobytes()).hexdigest(), [])
        if hits:
            after = [h for h in hits if h >= last]
            m = after[0] if after else hits[-1]
            last = max(last, m)
            res.append({'rtl': n, 'mel': m, 'diff': 0})
            continue
        lo, hi = max(1, last - 10), last + a.window
        best, bestd = None, None
        for m in range(lo, hi + 1):
            if m not in mimg:
                continue
            d = int(np.count_nonzero(np.any(mimg[m] != img, axis=2)))
            if bestd is None or d < bestd:
                best, bestd = m, d
        is3d = best is not None and any(polys.get(k, 0) > 0 for k in range(best - 2, best + 3))
        res.append({'rtl': n, 'mel': best, 'diff': bestd, '3d': is3d})

    unmatched = [r for r in res if r['diff'] != 0]
    not3d = [r for r in unmatched if not r.get('3d')]
    summary = {
        'rtl_frames': len(res),
        'mel_frames': len(mel),
        'reached_mel_frame': last,
        'unmatched': len(unmatched),
        'unmatched_3d': len(unmatched) - len(not3d),
        'first_unmatched_2d': not3d[0] if not3d else None,
        'first_unmatched_3d': next((r for r in unmatched if r.get('3d')), None),
    }
    if a.json:
        print(json.dumps({'summary': summary, 'frames': res}))
    else:
        for k, v in summary.items():
            print(f'{k}: {v}')


if __name__ == '__main__':
    main()
