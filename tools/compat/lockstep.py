#!/usr/bin/env python3
"""Instruction lockstep for the compatibility sweep (docs/compat.md).

Compares one CPU's retired-instruction traces (tools/ds-trace format, 68-byte
records: pc, cpsr, r0..r14) of melonDS (A) and tb_ds (B) from the direct-boot
entry. The two run at different speeds, so polls of timers, VCOUNT or the
other CPU last different lengths and IRQs land at different points. On a
divergence it looks ahead (--window records in each stream) for the earliest
record that is identical in both and continues from there, noting the skip:
- "irq": a skipped stretch is in IRQ mode (an interrupt taken at a different time)
- "poll": a stretch that loops over few distinct PCs (a wait of different length)
- "other": anything else that still rejoins.
A divergence that does not rejoin within the window is reported as the first
real divergence, with the melonDS frame it falls in (frames.csv from a
census --count-insns 1 run of the same ROM).

  lockstep.py MEL_TRACE RTL_TRACE --cpu 9|7 [--frames-csv F] [--window N]
"""
import argparse, csv, sys
import numpy as np

REC = 17   # u32 per record


def load(path):
    a = np.fromfile(path, dtype='<u4')
    return a[: len(a) // REC * REC].reshape(-1, REC)


def keys(recs):
    # one 64-bit key per record (hash of all 17 words)
    v = recs.astype(np.uint64)
    h = np.zeros(len(recs), dtype=np.uint64)
    for k in range(REC):
        h = (h * np.uint64(0x100000001B3)) ^ v[:, k]
    return h


def frame_of(n, cum):
    if cum is None:
        return None
    return int(np.searchsorted(cum, n, side='right'))


def kind(recs):
    mode = recs[:, 1] & 0x1F
    if np.any(mode == 0x12):
        return 'irq'
    if len(np.unique(recs[:, 0])) <= 16:
        return 'poll'
    return 'other'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('a')
    ap.add_argument('b')
    ap.add_argument('--cpu', choices=['9', '7'], required=True)
    ap.add_argument('--frames-csv')
    ap.add_argument('--window', type=int, default=400000)
    ap.add_argument('--cpsr-mask', type=lambda s: int(s, 0), default=0xFFFFFFBF)
    a = ap.parse_args()

    A = load(f'{a.a}/arm{a.cpu}.trc')
    B = load(f'{a.b}/arm{a.cpu}.trc')
    for R in (A, B):
        R[:, 1] &= a.cpsr_mask
    # the RTL retires IRQ entry as its own line (tools/ds-trace/README.md): drop it
    vec = 0xFFFF0018 if a.cpu == '9' else 0x18
    nxt = np.append(B[1:, 0], 0)
    prev_mode = np.insert(B[:-1, 1] & 0x1F, 0, 0)
    exc = ((B[:, 1] & 0x1F) == 0x12) & (B[:, 15] == B[:, 0] + 4) & (nxt == vec) & (prev_mode != 0x12)
    B = B[~exc]
    KA, KB = keys(A), keys(B)

    cum = None
    if a.frames_csv:
        col = f'arm{a.cpu}_insns'
        with open(a.frames_csv) as f:
            rows = list(csv.DictReader(f))
        if rows and col in rows[0]:
            cum = np.cumsum([int(r[col]) for r in rows])

    i = j = 0
    skips = {'irq': 0, 'poll': 0, 'other': 0}
    first_skip = None
    real = None
    na, nb = len(A), len(B)
    while i < na and j < nb:
        n = min(na - i, nb - j)
        d = np.nonzero(KA[i:i + n] != KB[j:j + n])[0]
        if len(d) == 0:
            i += n; j += n
            break
        i += int(d[0]); j += int(d[0])
        # earliest record identical in both, within the window
        wa, wb = KA[i:i + a.window], KB[j:j + a.window]
        pos_b = {}
        for k, v in enumerate(wb.tolist()):
            pos_b.setdefault(v, k)
        best = None
        for k, v in enumerate(wa.tolist()):
            m = pos_b.get(v)
            if m is not None and (best is None or k + m < best[0] + best[1]):
                best = (k, m)
                if k + m == 0:
                    break
            if best is not None and k > best[0] + best[1]:
                break
        if best is None or best == (0, 0):
            real = (i, j)
            break
        sk = kind(np.concatenate([A[i:i + best[0]], B[j:j + best[1]]]))
        skips[sk] += 1
        if first_skip is None:
            first_skip = (sk, i, int(A[i, 0]), frame_of(i, cum))
        i += best[0]; j += best[1]

    print(f'ARM{a.cpu}: A {na} records, B {nb}; compared to A {i}, B {j}')
    print(f'  timing skips: irq {skips["irq"]}, poll {skips["poll"]}, other {skips["other"]}')
    if first_skip:
        print(f'  first skip: {first_skip[0]} at A record {first_skip[1]} pc {first_skip[2]:08x} (melonDS frame {first_skip[3]})')
    if real:
        ri, rj = real
        print(f'  REAL DIVERGENCE at A record {ri} (melonDS frame {frame_of(ri, cum)}), B record {rj}')
        names = ['pc', 'cpsr'] + [f'r{k}' for k in range(15)]
        for k in range(max(0, -3), 4):
            if ri + k < na and rj + k < nb:
                ra, rb = A[ri + k], B[rj + k]
                diff = [f'{names[x]} {ra[x]:08x}/{rb[x]:08x}' for x in range(REC) if ra[x] != rb[x]]
                print(f'    +{k}: pc {ra[0]:08x}/{rb[0]:08x}  ' + ', '.join(diff[:6]))
        sys.exit(1)
    print('  no real divergence in the traced range')


if __name__ == '__main__':
    main()
