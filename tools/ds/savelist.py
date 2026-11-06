#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write sw/boot/savelist.s: melonDS's whole game list of save types, packed
for the boot ROM (docs/saves.md "Save type", step 2), so a game launched
without the plugin's .ndt still gets its save chip. The source is the
plugin's copy of the list (tools/pocket-plugin/src/romlist.rs, generated from
melonDS src/ROMList.cpp, GPL-3.0-or-later, the melonDS team).

  python3 tools/ds/savelist.py           write sw/boot/savelist.s
  python3 tools/ds/savelist.py --check   the file is current, and the decoder
                                         below gives every listed code its type

Types are melonDS SaveMemType 0-7; NAND (8-10) and unknown (0xFF) count as
not listed, as in the plugin (rom.rs save_type_word), and so does EEPROM
8 KiB (2): the boot program's default after the .sav size.

Layout (savelist, word aligned; boot9.s reads it):
  +0   word  NX, the exceptions
  +4   word  NL, the first letters
  +8   8 bytes: the type of each code: [0..2] the common types, [4..7] the rare
  +16  16 bytes: the first letters (NL of them)
  +32  NX words: whole game codes whose type differs from their three-letter
       prefix's; bit 7 of bytes 1-3 holds the type (bits 0-2), type 2 meaning
       not listed
  then the bitmap: bit L*1296 + c1*36 + c2 (LSB first) set for each
       three-letter prefix with a type other than 2 (c: '0'-'9' 0-9, 'A'-'Z'
       10-35; L the letter's position)
  then the types of the set bits in order, 2 bits each (LSB first): 0-2 a
       common type, 3 then 2 more bits for a rare one
A prefix's type is its USA version's, else its European one's, else the most
common; the other versions that differ are exceptions, and so are all the
codes of a letter with few games (smaller than its bitmap row).
"""
from collections import Counter, defaultdict
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'tools/pocket-plugin/src/romlist.rs'
OUT = ROOT / 'sw/boot/savelist.s'


def ci(c):
    return ord(c) - 48 if '0' <= c <= '9' else ord(c) - 55 if 'A' <= c <= 'Z' else None


def entries():
    e = [(int(a, 16), int(b)) for a, b in re.findall(r'\((0x[0-9A-F]+), (\d+)\)', SRC.read_text())]
    # NAND/unknown: not listed (the default chain), as the plugin
    return {c.to_bytes(4, 'little').decode('latin1'): (t if t <= 7 else 2) for c, t in e}


def build():
    ent = entries()
    pre = defaultdict(dict)
    for k, t in ent.items():
        pre[k[:3]][k[3]] = t
    pick = {}
    for p, v in pre.items():
        pick[p] = v['E'] if 'E' in v else v['P'] if 'P' in v else Counter(v.values()).most_common(1)[0][0]
    # a prefix the bitmap cannot hold: its codes go to the exceptions
    fits = {p for p in pick if pick[p] != 2 and all(ci(c) is not None for c in p[1:])}
    # a letter with few games: its codes are smaller as exceptions (4 bytes each) than as a bitmap row (162)
    for l in {p[0] for p in fits}:
        if 4 * sum(1 for k, t in ent.items() if k[0] == l and t != 2) < 162:
            fits -= {p for p in fits if p[0] == l}
    exc = sorted(k for k, t in ent.items() if t != (pick[k[:3]] if k[:3] in fits else 2))
    letters = sorted({p[0] for p in fits})
    assert len(letters) <= 16
    freq = sorted(Counter(pick[p] for p in fits).items(), key=lambda x: (-x[1], x[0]))   # (no hash order)
    common = [t for t, _ in freq[:3]]
    rare = [t for t, _ in freq[3:]]
    assert len(rare) <= 4
    nbits = len(letters) * 1296
    bm = bytearray((nbits + 7) // 8)
    keys = sorted((letters.index(p[0]) * 1296 + ci(p[1]) * 36 + ci(p[2]), p) for p in fits)
    tb = []
    for i, p in keys:
        bm[i >> 3] |= 1 << (i & 7)
        t = pick[p]
        tb += [common.index(t)] if t in common else [3, rare.index(t)]
    ts = bytearray((len(tb) + 3) // 4)
    for j, c in enumerate(tb):
        ts[j >> 2] |= c << ((j & 3) * 2)
    xw = []
    for k in exc:
        t = ent[k]
        b = bytearray(k.encode('latin1'))
        for n in range(3):
            b[n + 1] |= ((t >> n) & 1) << 7
        xw.append(int.from_bytes(b, 'little'))
    blob = bytearray()
    blob += len(xw).to_bytes(4, 'little') + len(letters).to_bytes(4, 'little')
    blob += bytes(common + [0] * (4 - len(common)) + rare + [0] * (4 - len(rare)))
    blob += ''.join(letters).encode().ljust(16, b'\0')
    for w in xw:
        blob += w.to_bytes(4, 'little')
    blob += bm + ts
    return ent, blob


def decode(blob, code):
    """The boot program's lookup (boot9.s), in Python: the type, or None (not listed)."""
    w = lambda o: int.from_bytes(blob[o:o + 4], 'little')
    nx, nl = w(0), w(4)
    c = int.from_bytes(code.encode('latin1'), 'little')
    for i in range(nx):
        x = w(32 + 4 * i)
        if x & 0x7F7F7F7F == c:
            t = (x >> 15 & 1) | (x >> 22 & 2) | (x >> 29 & 4)
            return None if t == 2 else t
    letters = blob[16:16 + nl].decode()
    if code[0] not in letters or ci(code[1]) is None or ci(code[2]) is None:
        return None
    idx = letters.index(code[0]) * 1296 + ci(code[1]) * 36 + ci(code[2])
    bm = 32 + 4 * nx
    tp = (bm + nl * 162) * 8
    bit = lambda o: blob[o >> 3] >> (o & 7) & 1
    for i in range(idx):
        if bit(bm * 8 + i):
            tp += 4 if (blob[tp >> 3] >> (tp & 7)) & 3 == 3 else 2
    if not bit(bm * 8 + idx):
        return None
    k = (blob[tp >> 3] >> (tp & 7)) & 3
    if k == 3:
        tp += 2
        k = 4 + ((blob[tp >> 3] >> (tp & 7)) & 3)
    return blob[8 + k]


def text(blob):
    lines = ['@ SPDX-License-Identifier: GPL-3.0-or-later',
             '@ Generated by tools/ds/savelist.py from tools/pocket-plugin/src/romlist.rs',
             '@ (melonDS src/ROMList.cpp, Copyright 2016-2026 melonDS team, GPL-3.0-or-later).',
             '@ melonDS\'s save types for the boot program (boot9.s); layout in the script. Do not edit.',
             '        .text', '        .align  2', '        .global savelist', 'savelist:']
    for o in range(0, len(blob), 16):
        lines.append('        .byte   ' + ','.join('0x%02x' % b for b in blob[o:o + 16]))
    lines.append('        .align  2')
    return '\n'.join(lines) + '\n'


def main():
    ent, blob = build()
    bad = [k for k, t in ent.items() if decode(blob, k) != (None if t == 2 else t)]
    if bad:
        sys.exit(f'decoder disagrees on {len(bad)} codes: {bad[:10]}')
    if '--check' in sys.argv:
        if OUT.read_text() != text(blob):
            sys.exit('sw/boot/savelist.s is stale: python3 tools/ds/savelist.py')
        print(f'savelist: {len(ent)} codes decode to their types; {len(blob)} bytes; current')
        return
    OUT.write_text(text(blob))
    print(f'savelist: {len(ent)} codes, {len(blob)} bytes -> {OUT.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
