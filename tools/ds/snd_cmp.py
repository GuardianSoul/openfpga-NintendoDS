#!/usr/bin/env python3
"""Sound through rtl/ds against melonDS: tb_ds --wav output vs a census SPU trace.

    snd_cmp.py OUT.wav TRACE.spu [--min-run N]

The two runs start the game at different times (boot timing differs), so the
output streams are aligned first: every stretch of 64 samples (left/right
pairs) of the wav that is not silence is looked up in the census's mixer
outputs (the 'O' records, sim/sound/spu_trace.h). From each alignment the
matching run is extended; the longest run of identical samples is reported.
"""
import argparse
import struct
import sys

import numpy as np

SNAP = 16 + 16 * 108 + 2 * 56          # sizeof(spu::Snap)


def census_out(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'NDSSPU01' and d[8:9] == b'S'
    recs = np.frombuffer(d[9 + SNAP:9 + SNAP + (len(d) - 9 - SNAP) // 12 * 12],
                         dtype=[('t', 'u1'), ('s', 'u1'), ('p', '<u2'), ('a', '<u4'), ('b', '<u4')])
    o = recs[recs['t'] == ord('O')]
    return (o['a'].astype(np.uint32) & 0xFFFF) << 16 | (o['b'].astype(np.uint32) & 0xFFFF)


def wav_out(path):
    d = open(path, 'rb').read()
    i = d.index(b'data') + 8
    s = np.frombuffer(d[i:], dtype='<i2').astype(np.int32)
    return (s[0::2].astype(np.uint32) & 0xFFFF) << 16 | (s[1::2].astype(np.uint32) & 0xFFFF)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('wav')
    ap.add_argument('spu')
    ap.add_argument('--min-run', type=int, default=32768)
    a = ap.parse_args()
    ref, got = census_out(a.spu), wav_out(a.wav)
    K = 64
    index = {}
    for i in range(0, len(ref) - K, 16):
        index.setdefault(ref[i:i + K].tobytes(), i)
    best = (0, 0, 0)
    tried = 0
    i = 0
    while i < len(got) - K:
        w = got[i:i + K]
        if len(np.unique(w)) > 8:                     # not silence or a steady level
            for s in range(16):                       # the index has every 16th offset
                j = index.get(got[i + s:i + s + K].tobytes())
                if j is not None:
                    j -= s
                    n = 0
                    m = min(len(got) - i, len(ref) - j)
                    eq = got[i:i + m] == ref[j:j + m]
                    n = int(np.argmin(eq)) if not eq.all() else m
                    if n > best[0]:
                        best = (n, i, j)
                    tried += 1
                    break
            if best[0] >= a.min_run:
                break
            i += best[0] if best[0] > K else K
        else:
            i += K
    n, i, j = best
    print(f'wav {len(got)} samples, census {len(ref)}; longest identical run {n} samples '
          f'({n / 32768:.2f} s) at wav {i} / census {j} ({tried} alignments tried)')
    sys.exit(0 if n >= a.min_run else 1)


if __name__ == '__main__':
    main()
