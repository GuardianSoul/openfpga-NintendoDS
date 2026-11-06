#!/usr/bin/env python3
"""Per-unit timing scorecard: the core (Pocket model) against the real DS.

    tools/scorecard/scorecard.py [--gx GXBODIES.txt] LABEL=LOGDIR[:LOGDIR...] [LABEL=...]

LOGDIR holds sim/pocket_ds logs of the unit ROMs (sw/tests unitmem, unita7,
unitgx, unitcpu; run with --plus stop_done=1, which prints "value I V" per
result row). --gx takes the geometry rows from tools/scorecard/gxbodies.py
(the engine's own clocks in tb_geom) in the main table; --strict also
prints unitgx's CPU-visible DMA-fed body timings in a separate table.
Prints docs/unit-scorecard.md's measured table (markdown): DS
value, the core's value per LABEL, core / DS, owner. Every DS value comes
from a hwref capture on the test DS (docs/hw-reference.md, run named per row).
Times are DS time (the core's timers tick at the DS rate), so a ratio > 1
means the core's unit is slower than the DS's.
"""
import argparse
import re
from pathlib import Path

# rom: [(row name, what, DS value, unit, source run, owner)], in result-block order.
# Units: sys = system cycles (33.5 MHz) x 100 per op; a9 = ARM9 cycles x 100; a7 = ARM7 cycles x 100.
ROWS = {
    'unitmem': [
        ('LDRDTCM', 'ARM9 LDR DTCM', 54, 'sys', 35, 'CPU'),
        ('LDM8DTCM', 'ARM9 LDM8 DTCM', 416, 'sys', 35, 'CPU'),
        ('STM8DTCM', 'ARM9 STM8 DTCM', 416, 'sys', 35, 'CPU'),
        ('LDRITCM', 'ARM9 LDR ITCM (data)', 104, 'sys', 35, 'CPU'),
        ('LDRHIT', 'ARM9 LDR main, D-cache hit', 54, 'sys', 35, 'CPU'),
        ('LDM8HIT', 'ARM9 LDM8 main, D-cache hit', 416, 'sys', 35, 'CPU'),
        ('STRHIT', 'ARM9 STR main, cache hit (C1B1)', 103, 'sys', 35, 'CPU'),
        ('STM8HIT', 'ARM9 STM8 main, cache hit', 419, 'sys', 35, 'CPU'),
        ('LDRMISS', 'ARM9 D-cache line fill (LDR miss)', 2300, 'sys', 35, 'CPU / integration'),
        ('STRMISS', 'ARM9 STR main miss (to the bus)', 900, 'sys', 35, 'CPU / integration'),
        ('LDRUNC', 'ARM9 LDR main uncached (C0B0)', 903, 'sys', 35, 'integration'),
        ('STRUNC', 'ARM9 STR main uncached', 900, 'sys', 35, 'integration'),
        ('LDM8UNC', 'ARM9 LDM8 main uncached', 2313, 'sys', 35, 'integration'),
        ('LDRVRAM', 'ARM9 LDR VRAM (LCDC)', 503, 'sys', 35, 'integration'),
        ('STRVRAM', 'ARM9 STR VRAM', 503, 'sys', 35, 'integration'),
        ('STRHVRAM', 'ARM9 STRH VRAM', 403, 'sys', 35, 'integration'),
        ('LDRPAL', 'ARM9 LDR palette', 571, 'sys', 35, 'integration / 2D'),
        ('STRPAL', 'ARM9 STR palette', 570, 'sys', 35, 'integration / 2D'),
        ('LDROAM', 'ARM9 LDR OAM', 403, 'sys', 35, 'integration / 2D'),
        ('LDRIO', 'ARM9 LDR I/O (DISPSTAT)', 403, 'sys', 35, 'integration'),
        ('STRIO', 'ARM9 STR I/O (BG0OFS)', 403, 'sys', 35, 'integration'),
        ('STRLDR', 'ARM9 STR then LDR same word (C1B1)', 3300, 'sys', 35, 'CPU'),
        ('IFWARM', 'ARM9 I-fetch main, 4 KiB sled (per NOP)', 208, 'sys', 35, 'CPU'),
        ('IFCOLD', 'ARM9 I-fetch main, I-cache cold (per NOP)', 288, 'sys', 35, 'CPU'),
        ('DMAMM', 'DMA3 main→main (per word)', 1800, 'sys', 35, 'integration'),
        ('DMAMV', 'DMA3 main→VRAM', 315, 'sys', 35, 'integration'),
        ('DMAVM', 'DMA3 VRAM→main', 408, 'sys', 35, 'integration'),
        ('DMAMPAL', 'DMA3 main→palette', 320, 'sys', 35, 'integration'),
        # Run35 raw 32-bit row: (2146-562)/(1024-256) = 2.0625.
        # The 207 figure belongs to the separate 16-bit row.
        ('DMAMIO', 'DMA3 main→I/O (fixed)', 206, 'sys', 35, 'integration'),
        ('DMAGXP', 'DMA3 main→GX command port', 208, 'sys', 35, 'integration / geometry'),
        ('DMAGXF', 'DMA3 main→GXFIFO, 4 packed commands a word', 500, 'sys', 35, 'integration / geometry'),
        ('TIMEOUTS', None, None, None, None, None),
    ],
    'unita7': [
        ('ALU', 'ARM7 ALU', 106, 'a7', 30, 'CPU'),
        ('ALUSR', 'ARM7 ALU shift by register', 206, 'a7', 30, 'CPU'),
        ('B', 'ARM7 B taken', 306, 'a7', 30, 'CPU'),
        ('MUL8', 'ARM7 MUL (Rs 8-bit)', 206, 'a7', 30, 'CPU'),
        ('MUL32', 'ARM7 MUL (Rs 32-bit)', 506, 'a7', 30, 'CPU'),
        ('MLA32', 'ARM7 MLA (Rs 32-bit)', 606, 'a7', 30, 'CPU'),
        ('LDRWRAM', 'ARM7 LDR WRAM', 306, 'a7', 30, 'CPU'),
        ('STRWRAM', 'ARM7 STR WRAM', 306, 'a7', 30, 'CPU'),
        ('LDM4WRAM', 'ARM7 LDM4 WRAM', 606, 'a7', 30, 'CPU'),
        ('STM4WRAM', 'ARM7 STM4 WRAM', 606, 'a7', 30, 'CPU'),
        ('LDRMAIN', 'ARM7 LDR main', 904, 'a7', 30, 'CPU / integration'),
        ('STRMAIN', 'ARM7 STR main', 900, 'a7', 30, 'CPU / integration'),
        ('LDM4MAIN', 'ARM7 LDM4 main', 1504, 'a7', 30, 'CPU / integration'),
        ('STM4MAIN', 'ARM7 STM4 main', 1500, 'a7', 30, 'CPU / integration'),
        ('SWPMAIN', 'ARM7 SWP main', 1801, 'a7', 30, 'CPU / integration'),
        ('MCALU', 'ARM7 code in main: ALU', 223, 'a7', 30, 'CPU / integration'),
        ('MCB', 'ARM7 code in main: B taken', 1410, 'a7', 30, 'CPU / integration'),
        ('MCLDRW', 'ARM7 code in main: LDR WRAM', 922, 'a7', 30, 'CPU / integration'),
        ('MCSTRW', 'ARM7 code in main: STR WRAM', 923, 'a7', 30, 'CPU / integration'),
        ('LDRVRAMC', 'ARM7 LDR VRAM C', 406, 'a7', 30, 'integration'),
        ('STRVRAMC', 'ARM7 STR VRAM C', 306, 'a7', 30, 'integration'),
        ('DONE', None, None, None, None, None),
    ],
    'unitgx': [
        ('MULT44M2', 'GX MTX_MULT_4x4 (position+vector)', 6475, 'sys', 8, 'geometry'),
        ('LOAD44', 'GX MTX_LOAD_4x4', 3425, 'sys', 8, 'geometry'),
        ('TRIV16', 'GX triangle, 3× VTX_16', 2770, 'sys', 8, 'geometry'),
        ('TRIOFF', 'GX triangle off screen (rejected)', 1980, 'sys', 8, 'geometry'),
        ('TRIXCLIP', 'GX triangle clipped on x', 10810, 'sys', 8, 'geometry'),
        ('TRINRML4', 'GX triangle with NORMAL, 4 lights', 2970, 'sys', 8, 'geometry'),
        ('NORMALL0', 'GX NORMAL, 0 lights', 900, 'sys', 8, 'geometry'),
        ('NORMALL1', 'GX NORMAL, 1 light', 900, 'sys', 8, 'geometry'),
        ('NORMALL4', 'GX NORMAL, 4 lights', 1206, 'sys', 8, 'geometry'),
        ('TEXCOORD', 'GX TEXCOORD (DMA-feed bound at ≤ 2.6)', 75, 'sys', 8, 'geometry'),
        ('COLOR', 'GX COLOR (DMA-feed bound at ≤ 2.6)', 75, 'sys', 8, 'geometry'),
        ('BEGINEND', 'GX BEGIN_VTXS + END_VTXS (DMA-feed bound at ≤ 3.1)', 187, 'sys', 8, 'geometry'),
        ('TIMEOUTS', None, None, None, None, None),
    ],
    'cputime': [
        ('NOP', 'ARM9 NOP / ALU', 106, 'a9', 22, 'CPU'),
        ('ADDDEP', 'ARM9 ADD dependent', 106, 'a9', 22, 'CPU'),
        ('ADDINDEP', 'ARM9 ADD independent', 106, 'a9', 22, 'CPU'),
        ('ADDSHIFT', 'ARM9 ADD register shift', 206, 'a9', 22, 'CPU'),
        ('BTAKEN', 'ARM9 B taken', 306, 'a9', 22, 'CPU'),
        ('BNOT', 'ARM9 B not taken', 206, 'a9', 22, 'CPU'),
        ('MUL', 'ARM9 MUL', 206, 'a9', 22, 'CPU'),
        ('MULDEP', 'ARM9 MUL dependent', 306, 'a9', 22, 'CPU'),
        ('MLA', 'ARM9 MLA', 206, 'a9', 22, 'CPU'),
        ('SMULL', 'ARM9 SMULL', 306, 'a9', 22, 'CPU'),
        ('SMULBB', 'ARM9 SMULBB', 106, 'a9', 22, 'CPU'),
        ('THADD', 'ARM9 Thumb ADD', 106, 'a9', 22, 'CPU'),
        ('THB', 'ARM9 Thumb B taken', 306, 'a9', 22, 'CPU'),
        ('LDUSEDT', 'ARM9 LDR DTCM + use', 306, 'a9', 22, 'CPU'),
        ('LDNUSEDT', 'ARM9 LDR DTCM, no use', 206, 'a9', 22, 'CPU'),
        ('LDUSEMN', 'ARM9 LDR main hit + use', 306, 'a9', 22, 'CPU'),
        ('STRVRAM', 'ARM9 STR VRAM back to back', 1006, 'a9', 22, 'integration'),
        ('STRVNOP4', 'ARM9 STR VRAM + 4 NOP', 1406, 'a9', 22, 'integration'),
        ('STRHVRAM', 'ARM9 STRH VRAM back to back', 806, 'a9', 22, 'integration'),
        ('STRMAIN', 'ARM9 STR main (C1B1) back to back', 1800, 'a9', 22, 'CPU / integration'),
        ('MISSCLN', 'ARM9 line miss, clean evict', 4600, 'a9', 22, 'CPU / integration'),
        ('MISSDRTY', 'ARM9 line miss, dirty evict', 4600, 'a9', 22, 'CPU / integration'),
        ('FILLW0', 'ARM9 fill, miss word 0', 4600, 'a9', 22, 'CPU / integration'),
        ('FILLW3', 'ARM9 fill, miss word 3', 4600, 'a9', 22, 'CPU / integration'),
        ('FILLW4', 'ARM9 fill, miss word 4', 4600, 'a9', 22, 'CPU / integration'),
        ('FILLW7', 'ARM9 fill, miss word 7', 4600, 'a9', 22, 'CPU / integration'),
        ('FILLW0W7', 'ARM9 fill w0 then w7', 4806, 'a9', 22, 'CPU / integration'),
        ('FILLW7W0', 'ARM9 fill w7 then w0', 4806, 'a9', 22, 'CPU / integration'),
    ],
}
ROWS['unitcpu'] = ROWS.pop('cputime')   # cputime's rows, ARM7 halted
UNIT = {'sys': 'system cycles', 'a9': 'ARM9 cycles', 'a7': 'ARM7 cycles'}


def values(log):
    """value lines of a stop_done run, and its result line"""
    v, res = {}, ''
    for l in Path(log).read_text(errors='replace').splitlines():
        m = re.match(r'value (\d+) (\d+)', l)
        if m:
            v[int(m.group(1))] = int(m.group(2))
        if l.startswith('result:'):
            res = l
    return v, res


def gx_engine(path):
    """tools/scorecard/gxbodies.py output: engine clk_sys per body -> system cycles x 100"""
    v = {}
    for l in Path(path).read_text().splitlines():
        m = re.match(r'(\w+) ([\d.]+) clk per body', l)
        if m:
            v[m.group(1)] = round(float(m.group(2)) * 50)
    return v


def validate(log, rows):
    """Reject partial/result-only logs before they can become timing evidence."""
    v, res = values(log)
    m = re.fullmatch(r'result: magic ([0-9a-fA-F]+) checks (\d+) mask ([0-9a-fA-F]+) done (\d+)', res)
    if not m or int(m[1], 16) != 0x52545344 or int(m[4]) != 1:
        raise ValueError(f'{log}: missing valid completed result block')
    n, mask = int(m[2]), int(m[3], 16)
    if n != len(rows) or mask != (1 << n) - 1 or set(v) != set(range(n)):
        raise ValueError(f'{log}: incomplete rows or failing check mask')
    for i, (name, what, *_rest) in enumerate(rows):
        if (what is not None and v[i] <= 0) or (name == 'TIMEOUTS' and v[i] != 0) or (name == 'DONE' and v[i] != 1):
            raise ValueError(f'{log}: invalid {name}={v[i]}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--strict', action='store_true', help='require complete successful ROM logs and per-tree GX inputs')
    parser.add_argument('--gx', action='append', default=[], metavar='[LABEL=]FILE', help='per-tree engine result; unlabelled input is historical shared-engine mode')
    parser.add_argument('trees', nargs='+', metavar='LABEL=LOGDIR[:LOGDIR...]')
    ns = parser.parse_args()
    trees = [a.split('=', 1) for a in ns.trees]
    if any(len(t) != 2 or not all(t) for t in trees) or len({t[0] for t in trees}) != len(trees):
        parser.error('trees need unique nonempty LABEL=LOGDIR entries')
    gx_by_tree = {}
    for arg in ns.gx:
        if '=' in arg:
            label, path = arg.split('=', 1)
            if label not in {t[0] for t in trees} or label in gx_by_tree:
                parser.error(f'unknown or duplicate GX label: {label}')
            gx_by_tree[label] = gx_engine(path)
        else:
            if ns.strict:
                parser.error('--strict requires --gx LABEL=FILE for each tree')
            for label, _ in trees:
                gx_by_tree[label] = gx_engine(arg)
    visible_gx = {}
    visible_gx_paths = {}
    if ns.strict:
        try:
            for label, folders in trees:
                gx = gx_by_tree.get(label)
                required = {r[0] for r in ROWS['unitgx'] if r[1] is not None}
                if gx is None or not required <= gx.keys() or any(gx[k] <= 0 for k in required):
                    raise ValueError(f'{label}: missing/invalid per-tree geometry engine rows')
                for rom, rows in ROWS.items():
                    # unitgx remains mandatory: CPU-visible GX and engine timing are separate gates.
                    paths = [Path(d) / f'{rom}.log' for d in folders.split(':')]
                    path = next((p for p in paths if p.exists()), None)
                    if path is None:
                        raise ValueError(f'{label}: missing {rom}.log')
                    validate(path, rows)
                    if rom == 'unitgx':
                        visible_gx[label] = values(path)[0]
                        visible_gx_paths[label] = path
        except ValueError as exc:
            parser.error(str(exc))
    out, ranked = [], []
    head = '| Unit | Item | DS | ' + ' | '.join(f'{t} | {t}/DS' for t, _ in trees) + ' | DS source | Owner |'
    out.append(head)
    out.append('| ' + ' | '.join(['---'] * (head.count('|') - 1)) + ' |')
    for rom, rows in ROWS.items():
        got = {}
        if rom == 'unitgx' and gx_by_tree:
            rows = [(n, w and w.replace('GX ', 'GX engine: ').split(' (DMA-feed')[0], ds, u, run, o) for n, w, ds, u, run, o in rows]
        for t, d in trees:
            if rom == 'unitgx' and t in gx_by_tree:
                gx = gx_by_tree[t]
                got[t] = ({i: gx[r[0]] for i, r in enumerate(rows) if r[0] in gx}, 'tb_geom')
                continue
            got[t] = ({}, '')
            for dd in d.split(':'):   # the first folder with this ROM's log
                p = Path(dd) / f'{rom}.log'
                if p.exists():
                    got[t] = values(p)
                    break
        for i, (name, what, ds, unit, run, owner) in enumerate(rows):
            if what is None:
                continue
            cells, worst = [], 0
            for t, _ in trees:
                v = got[t][0].get(i)
                if v is None:
                    cells += ['–', '–']
                    continue
                r = v / ds if ds and v else 0
                worst = max(worst, r)
                cells += [f'{v / 100:.2f}', f'{r:.2f}' if v else 'n/a']
            row = f'| {rom} | {what} | {ds / 100:.2f} | ' + ' | '.join(cells) + f' | run {run} ({UNIT[unit]}) | {owner} |'
            out.append(row)
            ranked.append((worst, what, ds, cells, owner))
    if ns.strict:
        print('Coverage: 92 CPU/memory/DMA/GX engine timing rows plus 12 separate CPU-visible GX body rows. 2D deadlines, sound service, WiFi and SPI/AUX timing are not covered by this table; no full-core DS-speed-exact claim.\n')
    print('\n'.join(out))
    if ns.strict:
        print('\nGX CPU-visible DMA-fed body timing (separate from engine capacity):\n')
        print('Values are system cycles per body from unitgx, including FIFO/DMA feed effects. '
              'These are not isolated command-register latencies; command/GXSTAT timing tests remain required.\n')
        print(head)
        print('| ' + ' | '.join(['---'] * (head.count('|') - 1)) + ' |')
        for i, (name, what, ds, unit, run, owner) in enumerate(ROWS['unitgx']):
            if what is None:
                continue
            what = what.replace('GX ', 'GX CPU-visible: ', 1)
            cells, worst = [], 0
            for label, _ in trees:
                v = visible_gx[label][i]
                ratio = v / ds
                worst = max(worst, ratio)
                cells += [f'{v / 100:.2f}', f'{ratio:.2f}']
            print(f'| unitgx CPU-visible | {what} | {ds / 100:.2f} | ' + ' | '.join(cells) +
                  f' | run {run} ({UNIT[unit]} per body) | {owner} |')
            ranked.append((worst, what, ds, cells, owner))
        print('\nCPU-visible core sources: ' + '; '.join(
            f'{label}: `{visible_gx_paths[label]}`' for label, _ in trees) + '.\n')
    print('\nRanked (worst core/DS first, > 1.0 only):\n')
    print('| Rank | Item | DS | ' + ' | '.join(f'{t} | {t}/DS' for t, _ in trees) + ' | Owner |')
    print('| ' + ' | '.join(['---'] * (4 + 2 * len(trees))) + ' |')
    k = 0
    for worst, what, ds, cells, owner in sorted(ranked, key=lambda x: -x[0]):
        if worst > 1.0:
            k += 1
            print(f'| {k} | {what} | {ds / 100:.2f} | ' + ' | '.join(cells) + f' | {owner} |')
    for t, d in trees:
        for rom in ROWS:
            for dd in d.split(':'):
                p = Path(dd) / f'{rom}.log'
                if p.exists():
                    print(f'\n<!-- {t} {rom} ({p}): {values(p)[1]} -->', end='')
                    break
    print()


if __name__ == '__main__':
    main()
