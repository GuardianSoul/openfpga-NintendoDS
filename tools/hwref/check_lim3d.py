#!/usr/bin/env python3
"""lim3d (sw/hwref/lim3d): a DS run against melonDS's, case by case.

    tools/hwref/check_lim3d.py DS_DIR MELONDS_DIR

MELONDS_DIR: `tools/hwref/run_melonds.sh MELONDS_DIR lim3d` (FRAMES=900 is enough); its lim3d.csv is also in
tools/hwref/results/melonds-lim3d-v1 (without the captures).

Per case: RAM_COUNT, the overflow and underflow flags, RDLINES min (lim3d.csv), and from the 3D capture the lines
that differ from melonDS's (which draws every polygon) and how far each of them got: polygon i is coloured
(i * 37) & 0x7FFF, so a pixel's colour gives the latest polygon drawn there. "reached" is the highest polygon seen
on the line (the polygons drawn so far, run 24/33's rule for a late line), against melonDS's.
"""
import csv, os, struct, sys

INV37 = pow(37, -1, 1 << 15)


def load_csv(d):
    rows = {}
    with open(os.path.join(d, 'lim3d.csv')) as f:
        for r in csv.DictReader(f):
            rows[r['name']] = r
    return rows


def capture(d, name):
    p = os.path.join(d, f'lim3d_{name}_3d.bin')
    if not os.path.exists(p):
        return None
    return struct.unpack('<%dH' % (256 * 192), open(p, 'rb').read())


def reached(cap, y):
    """highest polygon index visible on line y (-1: none), and pixels drawn"""
    best, n = -1, 0
    for x in range(256):
        v = cap[y * 256 + x]
        if v == 0x8000:                     # the clear colour (0, alpha 31)
            continue
        n += 1
        best = max(best, ((v & 0x7FFF) * INV37) & 0x7FFF)
    return best, n


def main():
    ds_dir = sys.argv[1]
    mel_dir = sys.argv[2]
    ds, mel = load_csv(ds_dir), load_csv(mel_dir)
    print('%-15s %-17s %-17s %4s %4s %4s  %s' % ('case', 'polys/verts DS', 'melonDS', 'over', 'undr', 'rdl', 'capture against melonDS'))
    for name, r in ds.items():
        m = mel.get(name, {})
        cd, cm = capture(ds_dir, name), capture(mel_dir, name)
        note = 'no capture'
        if cd and cm:
            diff = [y for y in range(192) if cd[y * 256:(y + 1) * 256] != cm[y * 256:(y + 1) * 256]]
            if not diff:
                note = 'identical'
            else:
                worst = min(diff, key=lambda y: reached(cd, y)[0] - reached(cm, y)[0])
                rd, rm = reached(cd, worst)[0], reached(cm, worst)[0]
                note = (f'{len(diff)} lines differ, first {diff[0]}, last {diff[-1]}; worst line {worst} reached '
                        f'polygon {rd} (melonDS {rm})')
        print('%-15s %-17s %-17s %4s %4s %4s  %s' % (
            name, f"{r['polys']}/{r['verts']}", f"{m.get('polys', '-')}/{m.get('verts', '-')}", r['overflow'],
            r['underflow'], r['rdlines_min'], note))


if __name__ == '__main__':
    main()
