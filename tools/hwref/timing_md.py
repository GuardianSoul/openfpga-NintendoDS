#!/usr/bin/env python3
"""Write release/TIMING.md: the Pocket core against a real DS, per probe row.

    timing_md.py --ds DSDIR --pocket POCKETDIR --core "NAME" --out release/TIMING.md

DSDIR and POCKETDIR are hwref result folders (the DS's SD /hwref/, and the
Pocket's save decoded by sav_extract.py). The same hwref.nds runs on both.
Each probe file has an entry in FILES: its area, the columns that identify a
row, its timing columns (shown as Pocket / DS) and its exact columns (must be
equal, such as read values and polygon counts). Rows are matched on the key
columns; a row only one side has is left out and counted.
"""
import argparse
import csv
from collections import defaultdict
from pathlib import Path

AREAS = ['CPU', 'Caches and memory', 'Cache misses (inferred from timing)', 'Write buffer',
         'DMA and bus contention', 'Timers', 'VRAM', 'Geometry', '3D rendering', 'Sound']

# file: (area, title, key columns, timing columns, exact columns[, options])
# options: 'workload': columns that must be equal for a row to be compared (the
# same work on both sides); 'timeline': cumulative timestamps, shown but not
# counted in the shares; 'min_over': a repetition column, rows reduced to their
# minimum (timer reps start at different prescaler phases).
FILES = {
    'cputime.csv': ('CPU', 'ARM9 instruction timing (cycles per op x100)', ['op'], ['cyc_per_op_x100'], []),
    'cputime_timers.csv': ('Timers', 'Timer start, overflow and reload (minimum over repetitions)',
                           ['case', 'prescaler', 'reload'], ['value'], [], {'min_over': 'rep_or_n'}),
    'memtime.csv': ('Caches and memory', 'ARM9 memory access per region (cycles per access x100)',
                    ['test', 'region', 'width', 'op'], ['cyc_per_access_x100'], [], {'workload': ['n1', 'n2']}),
    'memtime_gx.csv': ('Geometry', 'DMA into the geometry port (cycles per word x100)',
                       ['test', 'region', 'width', 'op'], ['cyc_per_access_x100'], []),
    'cacheorg.csv': ('Caches and memory', 'Cache organisation: hits, misses, strides',
                     ['cache', 'rr', 'test', 'stride', 'n', 'j'], ['avg_x100', 'misses'], [],
                     {'inferred': {'misses': 'Cache misses (inferred from timing)'}, 'skip_key': ('test', 'calib')}),
    'wbuf.csv': ('Write buffer', 'ARM9 write buffer: issue and drain (x100)',
                 ['case', 'pattern', 'mode', 'op', 'k', 'addr', 'nops', 'delay', 'load', 'reps'],
                 ['issue_x100', 'drained_x100'], []),
    'dmacpu.csv': ('DMA and bus contention', 'DMA against a CPU loop (contention)', ['variant', 'dma', 'k'],
                   ['dma_plus_loop', 'loop_alone', 'dma_alone'], []),
    'dmacpu_collide.csv': ('DMA and bus contention', 'CPU and DMA on the same word (order)', ['case', 'dma', 'offset'], [], ['value']),
    'dmaslip.csv': ('DMA and bus contention', 'DMA start and CPU slip per route', ['route', 'kind', 'n_target', 'n_loops', 'l_loops', 'flag'],
                    ['avg_x100'], []),
    'openq.csv': ('Caches and memory', 'Open questions: cascade, LDM, register values', ['test', 'case', 'trial'], [], ['value']),
    'tmcnt.csv': ('Timers', 'Timer counter reads', ['case', 'timer'], [], ['written', 'read16', 'read32_hi', 'read32_lo']),
    'vramcnt.csv': ('VRAM', 'VRAM bank mapping and access', ['case', 'n', 'kind'], ['mean_cycles_x100'],
                    ['mapped', 'unmapped', 'other', 'first_value']),
    'gxtime_summary.csv': ('Geometry', 'Geometry commands (cycles per command body x100)',
                           ['test', 'writes_per_body', 'prefix_writes'], ['cyc_per_body_x100', 'iso_med'], []),
    'gxtime_swap.csv': ('Geometry', 'SWAP_BUFFERS to the next frame', ['line', 'param', 'rep'], ['cycles'], ['vcount_end']),
    'gxtime_stall.csv': ('Geometry', 'Geometry FIFO stall timeline (cumulative, not counted)', ['test', 'i'], ['t'], [],
                         {'timeline': True}),
    'gxcount.csv': ('Geometry', 'Polygon and vertex counts (RAM_COUNT)', ['probe'], [], ['polys', 'verts', 'overflow', 'polys_late', 'verts_late'],
                    {'note': 'Known difference: no polygons are lost. The probe reads RAM_COUNT when GXSTAT busy clears; '
                             'on the Pocket busy follows the DS timing model while the geometry engine (4-6x slower) is '
                             'still storing, so the count read is the part stored so far. GXSTAT is not compared: its box-test bit '
                             'keeps the last BOX_TEST result, which depends on what ran before (the DS row comes from a '
                             'partial run without gxtime). polys_late/verts_late (gxcount v5, read once the count is stable) match the '
                             'DS except two known rules: the DS counter keeps counting past a full RAM, and the DS stops '
                             'sharing strip vertices at very large W (2 vertices more).'}),
    'gxmix.csv': ('Geometry', 'Game-like command mixes through DMA', ['mix', 'rep'], ['t_dma', 't_idle'],
                  ['polys', 'verts'], {'workload': ['commands', 'words', 'entries'],
                  'note': 'Polygon counts: see RAM_COUNT above (read before the engine has stored them). t_dma is '
                          'shorter because the Pocket spills a full FIFO to SDRAM instead of stalling the DMA.'}),
    'late3d.csv': ('3D rendering', 'Rendering against the scanline deadline', ['test'], ['rdlines_min'], ['polys', 'verts']),
    'late3d_restart.csv': ('3D rendering', 'Renderer restart after an overload', [], [], ['overload_vcount', 'light_vcount']),
    'rules3d_fog_sweep.csv': ('3D rendering', 'Depth values (fog sweep)', ['sub', 'strip', 'target_depth'], [], ['depth']),
    'sndq_index.csv': ('Sound', 'Sound FIFO segments', ['segment', 'unit'], [], ['samples', 'unwritten_words']),
    'sndq_s1_levels.csv': ('Sound', 'PCM16 output levels', ['level_index'], [], ['pcm16']),
}


def rows(path):
    if not path.exists():
        return None
    lines = [l for l in path.read_text(errors='replace').splitlines() if l and not l.startswith('#')]
    return list(csv.DictReader(lines))


def reduce_min(rs, key, timing):
    out = {}
    for r in rs:
        k = tuple(r.get(c, '') for c in key)
        if k not in out:
            out[k] = dict(r)
        else:
            for c in timing:
                a, b = num(out[k].get(c)), num(r.get(c))
                if a is not None and b is not None and b < a:
                    out[k][c] = r[c]
    return list(out.values())


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def fmt(v):
    f = num(v)
    if f is None:
        return v or ''
    return f'{f:.0f}' if f == int(f) else f'{f:.2f}'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--ds', type=Path, required=True)
    ap.add_argument('--pocket', type=Path, required=True)
    ap.add_argument('--core', required=True, help='the Pocket build measured, for the header')
    ap.add_argument('--ds-note', default='a real DS', help='the DS measured, for the header')
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()

    stats = defaultdict(lambda: [0, 0, 0, 0])      # area: rows, <=2 %, <=5 %, <=10 %
    exact = defaultdict(lambda: [0, 0])            # area: checks, matching
    sections = defaultdict(list)
    zeros = defaultdict(int)
    unmatched = []
    for name, spec in FILES.items():
        area, title, key, timing, exact_cols = spec[:5]
        opt = spec[5] if len(spec) > 5 else {}
        d, p = rows(a.ds / name), rows(a.pocket / name)
        if d and p and opt.get('min_over'):
            d, p = reduce_min(d, key, timing), reduce_min(p, key, timing)
        if not d or not p:
            if d or p:
                unmatched.append(f'{name}: {"no Pocket result" if d else "no DS result"}')
            continue
        dk = {tuple(r.get(k, '') for k in key): r for r in d}
        pk = {tuple(r.get(k, '') for k in key): r for r in p}
        common = [k for k in pk if k in dk]
        if len(pk) != len(common) or len(dk) != len(common):
            unmatched.append(f'{name}: {len(common)} rows on both, {len(dk) - len(common)} DS-only, {len(pk) - len(common)} Pocket-only')
        wl = [c for c in opt.get('workload', []) if c in d[0] and c in p[0]]
        diff_wl = [k for k in common if any(dk[k][c] != pk[k][c] for c in wl)]
        if diff_wl:
            unmatched.append(f'{name}: {len(diff_wl)} rows ran a different workload ({", ".join(wl)}), left out')
            common = [k for k in common if k not in diff_wl]
        sk = opt.get('skip_key')
        if sk and sk[0] in key:                       # calibration rows: shown elsewhere, not scored
            common = [k for k in common if not k[key.index(sk[0])].startswith(sk[1])]
        if not common:
            continue
        tl = [f'### {title} (`{name}`)', '']
        if opt.get('note'):
            tl += [opt['note'], '']
        tcols = [c for c in timing if c in d[0] and c in p[0]]
        ecols = [c for c in exact_cols if c in d[0] and c in p[0]]
        if tcols:
            tl += ['| ' + ' / '.join(key) + ' | Measurement | DS | Pocket | Pocket / DS |', '|---|---|---:|---:|---:|']
            for k in common:
                for c in tcols:
                    dv, pv = num(dk[k].get(c)), num(pk[k].get(c))
                    if dv is None or pv is None:
                        continue
                    ratio = pv / dv if dv else (1.0 if pv == 0 else None)
                    if dv == 0 and pv == 0:
                        zeros[area] += 1               # both zero: shown, not scored (says nothing about timing)
                    elif not opt.get('timeline'):
                        s = stats[opt.get('inferred', {}).get(c, area)]
                        s[0] += 1                  # a zero DS value with a non-zero Pocket one counts as outside
                        dev = abs(ratio - 1) if ratio is not None else 1e9
                        s[1] += dev <= 0.02
                        s[2] += dev <= 0.05
                        s[3] += dev <= 0.10
                    tl.append(f'| {" / ".join(k) or "-"} | {c} | {fmt(dk[k][c])} | {fmt(pk[k][c])} | '
                              f'{"-" if ratio is None else f"{ratio:.3f}"} |')
            tl.append('')
        if ecols:
            tl += ['| ' + (' / '.join(key) or 'check') + ' | Value | DS | Pocket | Same |', '|---|---|---|---|:---:|']
            for k in common:
                for c in ecols:
                    dv, pv = dk[k].get(c, ''), pk[k].get(c, '')
                    same = dv == pv or (num(dv) is not None and num(dv) == num(pv))
                    exact[area][0] += 1
                    exact[area][1] += same
                    tl.append(f'| {" / ".join(k) or "-"} | {c} | {dv} | {pv} | {"yes" if same else "**no**"} |')
            tl.append('')
        sections[area] += tl

    def pct(x, n):
        return f'{100 * x / n:.0f}%' if n else '-'
    out = ['# Timing: the Pocket core against a real DS', '',
           f'{a.core} against {a.ds_note}, with the same test ROM (`hwref.nds`, `sw/hwref`). '
           'Each probe times its operation with the console\'s own timers. On the Pocket the results go into the '
           'game save (the core has no flashcart SD) and are decoded with `tools/hwref/sav_extract.py`.', '',
           'Ratios are Pocket / DS: 1.000 is equal, above 1 the Pocket is slower, below 1 faster. '
           'Generated by `tools/hwref/timing_md.py`.', '',
           '## How close, per area', '',
           'Share of timing rows within 2 % / 5 % / 10 % of the DS. Rows count only when both sides ran the same '
           'work; cumulative timelines, calibration rows and rows where both sides read 0 are shown but not counted; '
           'a DS value of 0 against a non-zero Pocket value counts as outside. Cache misses are inferred from '
           'timing, so they have their own row. These shares describe the probes here, not game compatibility.', '',
           '| Area | Rows | ≤2 % | ≤5 % | ≤10 % |', '|---|---:|---:|---:|---:|']
    tot = [0, 0, 0, 0]
    for ar in AREAS:
        s = stats.get(ar)
        if not s:
            continue
        tot = [x + y for x, y in zip(tot, s)]
        out.append(f'| {ar} | {s[0]} | {pct(s[1], s[0])} | {pct(s[2], s[0])} | {pct(s[3], s[0])} |')
    out.append(f'| **All** | **{tot[0]}** | **{pct(tot[1], tot[0])}** | **{pct(tot[2], tot[0])}** | **{pct(tot[3], tot[0])}** |')
    out += ['', 'Exact checks (results that must equal the DS\'s, such as read values and polygon counts):', '',
            '| Area | Checks | Matching |', '|---|---:|---:|']
    for ar in AREAS:
        e = exact.get(ar)
        if e:
            out.append(f'| {ar} | {e[0]} | {e[1]} of {e[0]} |')
    if unmatched:
        out += ['', 'Rows not compared (a probe version or case only one side ran):', '']
        out += [f'- {u}' for u in unmatched]
    for ar in AREAS:
        if sections.get(ar):
            out += ['', f'## {ar}', ''] + sections[ar]
    a.out.write_text('\n'.join(out).rstrip() + '\n')
    print(f'{a.out}: {tot[0]} timing rows, {sum(e[0] for e in exact.values())} exact checks')


if __name__ == '__main__':
    main()
