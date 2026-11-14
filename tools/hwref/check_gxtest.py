#!/usr/bin/env python3
"""gxtest v1 (sw/hwref/gxtest): a DS run against melonDS's, case by case.

    tools/hwref/check_gxtest.py DS_DIR [MELONDS_DIR]

MELONDS_DIR defaults to tools/hwref/results/melonds-gxtest-v1 (`tools/hwref/run_melonds.sh DIR gxtest`,
FRAMES=2400). Exit 1 when the DS run is incomplete or unusable: a case missing (a hang skips the case that hung,
gxtest_v1_progress.txt shows it as "start" without "done"), a case twice, a timeout/reset/dropped write, a D of 0
(no FIFO drop seen), a sample buffer overflow, a BOX_TEST result unlike its expectation (box_enclose: open), or a
cycles-per-body value outside the sanity range. Prints per case: DS and melonDS cycles per body (system cycles, D
slope), iso latency, the BOX_TEST result, and the run-3/run-8 controls.
"""
import csv, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
# earlier DS runs of the same bodies (gxtime run 3 / run 8, system cycles per body)
CONTROLS = {'box_in_q': 257.1, 'box_out_right': 102.9, 'box_part_x': 519.0, 'pos_alone': 7.12, 'vec_alone': 5.25,
            'vtx_only': 27.7}
# sanity range of cycles per body (a probe bug, not a DS answer, lands outside)
RANGE = (2.0, 3000.0)


def load(d):
    rows, dup = {}, []
    with open(os.path.join(d, 'gxtest_v1.csv')) as f:
        for r in csv.DictReader(f):
            if r['case'] in rows:
                dup.append(r['case'])
            rows[r['case']] = r
    return rows, dup


def progress(d):
    st, dn = [], set()
    p = os.path.join(d, 'gxtest_v1_progress.txt')
    if os.path.exists(p):
        for line in open(p):
            v = line.split()
            if len(v) == 2 and v[0] == 'start':
                st.append(v[1].removeprefix('gxtest1_'))
            elif len(v) == 2 and v[0] == 'done':
                dn.add(v[1].removeprefix('gxtest1_'))
    return [c for c in st if c not in dn]


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    ds_dir = sys.argv[1]
    mel_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, 'results', 'melonds-gxtest-v1')
    mel, _ = load(mel_dir)
    ds, dup = load(ds_dir)
    bad = []
    hung = progress(ds_dir)
    if hung:
        bad.append('started but not done (a hang): ' + ', '.join(hung))
    if dup:
        bad.append('cases twice: ' + ', '.join(dup))
    print(f"{'case':20} {'DS':>8} {'melonDS':>8} {'DS/mel':>7} {'ctrl':>7} {'iso DS':>7} {'iso mel':>7}  box DS (exp)")
    for name, m in mel.items():
        r = ds.get(name)
        if r is None:
            bad.append(f'{name}: missing')
            print(f'{name:20} {"-":>8}')
            continue
        per, mper = int(r['cyc_per_body_x100']) / 100, int(m['cyc_per_body_x100']) / 100
        for k in ('timeouts', 'resets', 'dropped'):
            if int(r[k]):
                bad.append(f'{name}: {k} {r[k]}')
        if int(r['d1']) == 0 or int(r['d2']) == 0:
            bad.append(f'{name}: no FIFO drop seen (D = 0)')
        if int(r['samples_max']) >= 1023:
            bad.append(f'{name}: sample buffer full')
        if not RANGE[0] <= per <= RANGE[1]:
            bad.append(f'{name}: {per} cycles per body outside {RANGE}')
        box = ''
        exp = int(r['box_expect'])
        if exp >= 0:
            got = (int(r['box_n1']), int(r['box_n2']))
            box = f'{got[0]}/{got[1]} ({"open" if exp == 2 else exp})'
            if got[0] != got[1] or (exp != 2 and got[0] != exp):
                bad.append(f'{name}: BOX_TEST result {got}, expected {exp}')
        ctrl = CONTROLS.get(name)
        print(f"{name:20} {per:8.2f} {mper:8.2f} {per / mper if mper else 0:7.3f} {ctrl if ctrl else '':>7} "
              f"{r['iso_min']:>7} {m['iso_min']:>7}  {box}")
    for name in ds:
        if name not in mel:
            bad.append(f'{name}: not in the melonDS run')
    if bad:
        print('\nUNUSABLE / INCOMPLETE:\n  ' + '\n  '.join(bad))
        sys.exit(1)
    print('\nCOMPLETE: every case once, no timeouts, BOX_TEST results as expected')


if __name__ == '__main__':
    main()
