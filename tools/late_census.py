#!/usr/bin/env python3
"""late_census.py TAG [SCENES]: late lines per scene from scenes.py --tag TAG runs (build/scenes/NAME/run-TAG.log).

After the release, nds_gpu3d's simulation census 'g3d LATECOUNT: render-late R delivery-late D' per frame: composed
3D lines the raster had not finished, and finished lines the ring had not delivered (rc053 frozen-report's classes). Late 2D rows: the 'g2d LATE: N 2D lines late' sum. Pace:
swaps against melonDS's over the same frames (scenes.py's rule). Exit 1 if any scene has a late row (the card gate)."""
import re, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
tag = sys.argv[1]
names = sys.argv[2].split(',') if len(sys.argv) > 2 else sorted({l.split()[0] for l in (ROOT / 'sim/pocket_ds/scenes.txt').read_text().splitlines() if l.strip() and not l.startswith('#')})
rows, bad = [], 0
for n in names:
    d = ROOT / 'build/scenes' / n
    log = d / f'run-{tag}.log'
    if not log.exists():
        rows.append((n, 'not run', '', '', '', '')); continue
    t = log.read_text(errors='replace')
    m = re.search(r'import: released at \d+, video frame (\d+)', t)
    if not m:
        rows.append((n, 'no release', '', '', '', '')); continue
    end = t.find('\nvideo: '); run = t[t.index(m.group(0)):end if end > 0 else len(t)]
    rl = sum(int(x) for x in re.findall(r'g3d LATECOUNT: render-late (\d+)', run))
    dl = sum(int(x) for x in re.findall(r'g3d LATECOUNT: render-late \d+ delivery-late (\d+)', run))
    l2 = sum(int(x) for x in re.findall(r'g2d LATE: (\d+) 2D lines late', run))
    tot3 = sum(int(x) for x in re.findall(r'g3d LATE: (\d+) 3D lines late in the last frame', run))
    errs = sum(1 for l in t.splitlines() if 'ERROR' in l or '%Error' in l or '%Fatal' in l)
    rel = int(m.group(1)); ps = {int(v): int(k) for k, v in re.findall(r'g3d swaps: (\d+) at video frame (\d+)', run)}
    pace = ''
    ms_p = d / 'mel/swaps.txt'; e0 = int((d / 'exp/clean.txt').read_text().split()[1]) if (d / 'exp/clean.txt').exists() else 0
    if ps and ms_p.exists():
        ms = {int(a): int(b) for a, b in (l.split() for l in ms_p.read_text().splitlines() if l.strip())}
        v0, v1 = rel + 4, max(ps)
        if v0 in ps and (v0 - rel + e0) in ms and (v1 - rel + e0) in ms and ms[v1 - rel + e0] > ms[v0 - rel + e0]:
            p, q = ps[v1] - ps[v0], ms[v1 - rel + e0] - ms[v0 - rel + e0]
            pace = f'{p}/{q} ({100 * p / q:.0f}%)'
    if rl or dl or l2 or tot3: bad += 1
    # the first late frame (video frames after the release) and its first late line, from the per-frame reports
    fl = ''
    cur = rel
    for line in run.splitlines():
        mv = re.search(r'video frame (\d+):', line)
        if mv: cur = int(mv.group(1))
        ml = re.search(r'g3d LATE: (\d+) 3D lines late in the last frame \(first: line (\d+)\)', line)
        if ml and not fl: fl = f'first late 3D: frame +{cur - rel}, line {ml.group(2)} ({ml.group(1)} lines)'
        m2 = re.search(r'g2d LATE: (\d+) 2D lines late', line)
        if m2 and 'first late 2D' not in fl: fl += (', ' if fl else '') + f'first late 2D: frame +{cur - rel}'
    rows.append((n, str(rl), str(dl), str(l2), pace, '; '.join(x for x in [fl, f'3D total {tot3}' if tot3 != rl + dl else '', f'{errs} error lines' if errs else ''] if x)))
print('| scene | render-late | delivery-late | late 2D | pace (swaps vs melonDS) | note |')
print('|---|---:|---:|---:|---|---|')
for r in rows: print('| ' + ' | '.join(r) + ' |')
print(f'\n{bad} of {len(rows)} scenes with late rows')
sys.exit(1 if bad else 0)
