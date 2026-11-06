"""White 2 load-time check (suspect 3, nds-geometry-2): the Pocket model's main RAM and GX entries against
melonDS's after a map load (sim/pocket_ds/w2load.sh runs both and calls this).

    w2load_cmp.py POCKET_MAIN MELON_BEFORE MELON_MAIN... MELON_LATER POCKET_GXLOG MELON_GXBIN

Main RAM: the Pocket's dump against the closest of melonDS's dumps around the same frame (the Pocket can be a
frame or two behind). A game's dynamic state (stack, heap bookkeeping, timers, the player's position)
differs with the frame phase; the load's data does not: the words melonDS changed from the state
(MELON_BEFORE) and still holds frames later (MELON_LATER), grouped into regions. A differing word in a
loaded region (>= 1 KiB) is the suspect.

GX: vertex data is in model space, so a model's vertex words are the same whatever the camera. Every
vertex-like entry (VTX_16/10/XY/XZ/YZ/DIFF, TEXCOORD, NORMAL, COLOR) the Pocket sent that melonDS never
sent in its window is listed per flush (SWAP_BUFFERS), with its neighbours. Exit 1 when either check finds
something.
"""
import struct
import sys
from collections import Counter

VTX = {0x20: 'COLOR', 0x21: 'NORMAL', 0x22: 'TEXCOORD', 0x23: 'VTX_16', 0x24: 'VTX_10', 0x25: 'VTX_XY',
       0x26: 'VTX_XZ', 0x27: 'VTX_YZ', 0x28: 'VTX_DIFF'}
VSZ = [128, 128, 128, 128, 64, 16, 16, 32, 16]          # VRAM banks A..I, KiB


def gx_entries(path):
    """('C', cmd, param) entries and flush marks from a census gx.bin or a tb +gxlog file"""
    d = open(path, 'rb').read()
    i, out = (8 if d[:6] == b'NDSGX0' else 0), []      # (census: an 8-byte header)
    while i < len(d):
        k = d[i]; i += 1
        if k == ord('C'):
            out.append((d[i], struct.unpack_from('<I', d, i + 1)[0])); i += 5
        elif k == ord('F'):
            i += 20 + 1 + 64 + 16 + 4 + 4 + 32 + 4 + 4
        elif k == ord('V'):
            i += 4 + 9 + sum(VSZ) * 1024
        else:
            sys.exit(f'{path}: unknown record {k:#x} at {i - 1}')
    return out


def flushes(ents):
    cur, out = [], []
    for c, p in ents:
        cur.append((c, p))
        if c == 0x50:
            out.append(cur); cur = []
    return out


def ram(pocket, before, mels):
    """mels: melonDS main RAM at several frames around the dump, the last some frames later. The Pocket's dump is
    compared with the closest of the others; the load's data are the words melonDS changed from the state and
    then kept (closest == last): those must match"""
    P, M0 = open(pocket, 'rb').read(), open(before, 'rb').read()
    Ms = [(f, open(f, 'rb').read()) for f in mels]
    W = lambda b, k: struct.unpack_from('<I', b, k)[0]
    pages = lambda B: sum(1 for p in range(0, len(P), 4096) if P[p:p + 4096] != B[p:p + 4096])
    best = min(Ms[:-1], key=lambda m: pages(m[1]))
    M, ML = best[1], Ms[-1][1]
    print(f'main RAM: closest melonDS dump {best[0]} ({pages(M)} of {len(P) // 4096} 4 KiB pages differ)')
    ld = [k for k in range(0, len(P), 4) if M0[k:k + 4] != M[k:k + 4] and M[k:k + 4] == ML[k:k + 4]]
    bad = [k for k in ld if P[k:k + 4] != M[k:k + 4]]
    print(f'  words the load wrote and kept (melonDS): {len(ld)}; different on the Pocket: {len(bad)}')
    runs, s0, prev = [], None, None
    for k in ld:
        if prev is None or k - prev > 64:
            if s0 is not None: runs.append((s0, prev))
            s0 = k
        prev = k
    if s0 is not None: runs.append((s0, prev))
    loaded = []
    for a, b in runs:
        if b - a >= 1024:
            nb = sum(1 for k in bad if a <= k <= b)
            ch = sum(1 for k in range(a, b + 4, 4) if M[k:k + 4] != ML[k:k + 4]) / ((b - a + 4) // 4)
            kind = 'dynamic' if ch > 0.05 else 'loaded'
            if kind == 'loaded':
                loaded.append((a, b))
            print(f'  region {0x2000000 + a:08x}-{0x2000000 + b + 3:08x} ({(b - a + 4) // 1024} KiB, {100 * ch:.1f}% of its '
                  f'words still changing in melonDS: {kind}): {nb} words differ on the Pocket')
    per = Counter(k >> 12 for k in bad)
    if per:
        print('  differing words per 4 KiB page: ' + ' '.join(f'{0x2000000 + (q << 12):08x}:{n}' for q, n in sorted(per.items())))
    for k in bad[:12]:
        print(f'    {0x2000000 + k:08x} before {W(M0, k):08x} melonDS {W(M, k):08x} Pocket {W(P, k):08x}')
    # a loaded region (>= 1 KiB of kept words, < 5% of its words still changing) with a differing word is the
    # suspect; small scattered state and structures the game keeps rewriting aren't
    return sum(1 for a, b in loaded for k in bad if a <= k <= b)


def gx(pocket, melon):
    P, M = gx_entries(pocket), gx_entries(melon)
    known = Counter((c, p) for c, p in M if c in VTX)
    pf, mf = flushes(P), flushes(M)
    print(f'GX: Pocket {len(P)} entries, {len(pf)} flushes; melonDS {len(M)} entries, {len(mf)} flushes')
    pv = sum(1 for c, _ in P if c in VTX)
    print(f'  vertex-like entries: Pocket {pv}, melonDS {sum(known.values())} ({len(known)} distinct)')
    bad = 0
    for fi, f in enumerate(pf):
        new = [(j, c, p) for j, (c, p) in enumerate(f) if c in VTX and (c, p) not in known]
        if new:
            bad += len(new) if fi else 0        # (flush 0: the release's frame, partly drawn before it)
            ex = ', '.join(f'#{j} {VTX[c]} {p:08x}' for j, c, p in new[:6])
            print(f'  flush {fi}: {len(new)} of {sum(1 for c, _ in f if c in VTX)} vertex entries melonDS never sent: {ex}')
    # the commands' shape: per flush, the command histogram against melonDS's closest flush
    if pf and mf:
        mh = [Counter(c for c, _ in f) for f in mf]
        worst = 0
        for f in pf[1:]:
            h = Counter(c for c, _ in f)
            d = min(sum(((h - m) + (m - h)).values()) for m in mh)
            worst = max(worst, d)
        print(f'  command-count distance to melonDS\'s closest flush (worst over the Pocket\'s flushes): {worst}')
    print(f'  {bad} vertex entries melonDS never sent (from flush 1)')
    return bad


def main():
    a = sys.argv[1:]
    if len(a) < 6:
        sys.exit(__doc__)
    r = ram(a[0], a[1], a[2:-2])
    g = gx(a[-2], a[-1])
    print(f'RESULT: {r} words differ in loaded regions, {g} unknown vertex entries -> {"DIFFERENCE" if r or g else "no difference"}')
    sys.exit(1 if r or g else 0)


if __name__ == '__main__':
    main()
