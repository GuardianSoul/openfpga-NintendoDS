#!/usr/bin/env python3
"""Finite new-only trip completeness. Never substitutes for DS timing analysis."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import struct

import check_speed_probes as basic


def rows(d, name):
    with (d / name).open(newline='') as f:
        return list(csv.DictReader(f))


def require(ok, message):
    basic.require(ok, message)


def wram_keys():
    keys = [(1 | ((store | (size << 1) | (state << 2)) << 8), rep, 0)
            for state in range(3) for store in range(2) for size in range(2) for rep in range(4)]
    keys += [(2 | (store << 8), rep, delay) for store in range(2)
             for delay in (0, 2, 4, 8, 16, 32, 64) for rep in range(4)]
    return [f'c{command}_r{rep}_d{delay}' for command, rep, delay in keys]


def wram_progress(d):
    lines = (d / 'wramarb_progress.txt').read_text().splitlines()
    events, malformed = [], []
    for number, line in enumerate(lines, 1):
        match = re.fullmatch(r'(start|done) (c\d+_r\d+_d\d+)', line)
        if match:
            events.append(list(match.groups()))
        else:
            malformed.append(dict(line=number, text=line))
    starts = [key for verb, key in events if verb == 'start']
    done = [key for verb, key in events if verb == 'done']
    expected = wram_keys()
    exact = [[verb, key] for key in expected for verb in ('start', 'done')]
    return dict(starts=len(starts), done=len(done), expected=len(expected),
                complete=events == exact and not malformed,
                started_without_done=[key for key in starts if key not in done],
                never_started=[key for key in expected if key not in starts],
                duplicate_starts=sorted({key for key in starts if starts.count(key) > 1}),
                duplicate_done=sorted({key for key in done if done.count(key) > 1}),
                done_without_start=[key for key in done if key not in starts],
                unknown_keys=sorted({key for _, key in events if key not in expected}),
                malformed=malformed, last_event=events[-1] if events else None)


def wram(d):
    data = basic.records(d / 'wramarb.csv')
    expected = {(1 | ((store | (size << 1) | (state << 2)) << 8), rep, 0)
                for state in range(3) for store in range(2) for size in range(2) for rep in range(4)}
    expected |= {(2 | (store << 8), rep, delay) for store in range(2)
                 for rep in range(4) for delay in (0, 2, 4, 8, 16, 32, 64)}
    got = [(r['command'], r['rep'], r['delay']) for r in data]
    require(len(got) == 104 and set(got) == expected, 'WRAM missing/duplicate cases')
    for r in data:
        require(r['error'] == r['cap_timeout'] == 0 and r['arm7_ticks'] > 0, 'WRAM failed case')
        require(r['private_addr'] & 0xff800000 == 0x03800000, 'WRAM private placement')
        if r['command'] & 255 == 1:
            b = basic.binary(d / f'wramarb_{r["command"]}_r{r["rep"]}.bin', 2048)
            require(b != struct.pack('<h', 0x5a5a) * 1024, 'WRAM untouched sound capture')
            n = 1024 if (r['command'] >> 8) & 2 else 256
            require(r['operations'] == n, 'WRAM operation count')
        else:
            require(r['operations'] == 1024 and r['switched'] == 1 and
                    0 < r['arm9_loss_ticks'] <= r['arm9_return_ticks'], 'WRAM handover incomplete')
    require(wram_progress(d)['complete'], 'WRAM missing/malformed/reordered START/DONE journal')
    require((d / 'wramarb_info.txt').read_text().startswith('wramarb 1;'), 'WRAM final protocol info absent')
    require((d / 'wramarb_active.txt').read_text() == 'complete\n', 'WRAM final case not marked complete')
    return dict(rows=len(data), sound=48, handover=56)


def wram_status(d):
    """Preserve partial observations; never diagnose a hang from missing data."""
    result = dict(complete_output=False, ds_timing_status='unqualified; output/provenance inspection only',
                  console_sd_ok='FAT initialization only',
                  active_complete='per-case marker only; not global completion', files={})
    for path in sorted(d.glob('wramarb*')):
        if path.is_file():
            data = path.read_bytes()
            result['files'][path.name] = dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
    for name, read in [('progress', lambda: wram_progress(d)),
                       ('active', lambda: (d / 'wramarb_active.txt').read_text()),
                       ('csv_rows', lambda: len(basic.records(d / 'wramarb.csv')))]:
        try:
            result[name] = read()
        except (OSError, ValueError, TypeError) as error:
            result[name + '_unavailable'] = str(error)
    try:
        result['complete_counts'] = wram(d)
        result['complete_output'] = True
    except (OSError, ValueError, KeyError, TypeError) as error:
        result['incomplete_reason'] = str(error)
    result['interpretation'] = 'Missing data or unmatched START remains unmeasured; not proof of a hang or cause.'
    return result


def gx(d):
    counts = {}
    for name, count in [('summary', 270), ('reads', 72), ('setup', 228), ('packed', 18), ('matrix', 315)]:
        data = rows(d, f'gxlatency_v4_{name}.csv')
        require(len(data) == count, f'GX {name}: incomplete rows')
        counts[name] = len(data)
        if name == 'summary':
            keys = [(r['prefix'], int(r['shape']), int(r['n']), int(r['rep'])) for r in data]
            expected = {(p, s, n, rep) for p in ('warm', 'identity_m1', 'load44_m1', 'mult44_m1', 'mult44_m2')
                        for s in range(3) for n in (0, 1, 2, 4, 16, 32) for rep in range(3)}
        elif name == 'reads':
            keys = [(r['port'], int(r['load']), int(r['delay']), int(r['rep'])) for r in data]
            expected = {(p, load, delay, rep) for p in ('clip', 'vector') for load in range(2)
                        for delay in (0, 1, 2, 4, 16, 64) for rep in range(3)}
        elif name == 'setup':
            keys = [(r['body'], int(r['n']), int(r['rep'])) for r in data]
            names = ('difamb', 'difamb_color', 'speemi', 'speemi_table', 'lightcol', 'lightvec',
                     'shininess', 'store0_m2', 'restore0_m2', 'pushpop_m2')
            expected = {(p, n, rep) for p in names for n in (0, 1, 2, 4, 8, 16, 32, 64)
                        for rep in range(3) if p != 'shininess' or n <= 4}
        elif name == 'packed':
            keys = [(r['body'], int(r['n']), int(r['rep'])) for r in data]
            expected = {(p, 1200 * multiple // entries, rep) for p, entries in
                        (('LOAD44', 16), ('TRINRML4', 9), ('TRIXCLIP', 6))
                        for multiple in (1, 2) for rep in range(3)}
        else:
            keys = [(r['body'], int(r['mode']), int(r['n']), int(r['rep'])) for r in data]
            names = ('pushpop', 'store', 'restore', 'identity', 'load44', 'load43', 'mult44',
                     'mult43', 'mult33', 'scale', 'trans')
            masks = (0x5, 0x4, 0x4, 0x7, 0x7, 0x4, 0xf, 0x6, 0x6, 0x6, 0x6)
            expected = {(p, mode, n, rep) for p, mask in zip(names, masks) for mode in range(4)
                        for n in (0, 1, 2, 4, 8) for rep in range(3) if not mask & (1 << mode)}
        require(len(keys) == len(expected) and set(keys) == expected, f'GX {name}: input coverage')
        for r in data:
            if 'drain_sys' in r:
                require(int(r['drain_sys']) >= 0 and 0 < int(r['samples']) < 1023 and
                        int(r['timeouts']) == 0, f'GX {name}: invalid drain')
            if name == 'packed':
                require(int(r['timeout']) == 0 and 0 < int(r['dma_sys']) <= int(r['idle_sys']) and
                        0 < int(r['words']) <= 3200 and not (int(r['idle_gxstat'], 16) & (1 << 27)),
                        'GX packed completion invalid')
            if name == 'reads':
                require(int(r['read_sys']) > 0 and r['port'] in ('clip', 'vector'), 'GX invalid read')
    for name in ('events', 'setup_events', 'matrix_events'):
        require(bool(rows(d, f'gxlatency_v4_{name}.csv')), f'GX {name}: raw events absent')
    journal = (d / 'gxlatency_v4_progress.txt').read_text().splitlines()
    for kind in ('START', 'DONE'):
        ids = [int(line.split(',')[1]) for line in journal if line.startswith(kind + ',')]
        require(ids == list(range(1, 904)), f'GX {kind}: missing/duplicate step')
    info = (d / 'gxlatency_v4_info.txt').read_text()
    require('output_ok 1' in info and 'timeouts 0 resets 0 failed 0 dropped 0' in info,
            'GX failure counters')
    return counts


def raster(d):
    for n, width in ((48, 32), (64, 24), (128, 12)):
        stem = f'rdtimeline_n{n}_s{width}'
        data = basic.records(d / (stem + '.csv'))
        info = basic.records(d / (stem + '_info.csv'))
        require(len(data) == 790 and len(info) == 1, 'raster timeline incomplete')
        i = info[0]
        require(i['polys'] == n and i['verts'] == n * 4 and i['samples'] == 790 and
                i['missed_edges'] == 0 and i['capture_done'] == i['gx_ok'] == 1 and i['timeouts'] == 0,
                'raster timeline input/state failure')
        require(all(0 <= r['vcount'] <= 262 and 0 <= r['vcount_after'] <= 262 for r in data),
                'raster invalid scanline range')
        basic.binary(d / (stem + '_f0.bin'), 256 * 192 * 2)
    data = basic.records(d / 'late3d_restart.csv')
    require(len(data) == 1 and data[0]['timeouts_before'] == data[0]['timeouts_after'] == 0,
            'late3d restart incomplete')
    for i in (0, 1):
        basic.binary(d / f'late3d_restart_n192_f{i}.bin', 256 * 192 * 2)
    require(not (d / 'late3d.csv').exists() and not list(d.glob('late3d_ctrl_n8*')),
            'new-only unexpectedly wrote historical late3d outputs')
    log = (d / 'hwref_speed_progress.txt').read_text()
    for name in ('late3d_v2', 'rdtimeline_v1', 'gxlatency_v4'):
        require(f'done  {name}' in log, f'menu incomplete: {name}')
    require('all done' in log, 'menu incomplete')
    return dict(timelines=3, samples_each=790, restart_captures=2)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('kind', choices=['wramarb', 'wramarb-status', 'menu', 'all'])
    p.add_argument('directory', type=Path)
    a = p.parse_args()
    if a.kind == 'wramarb-status':
        print(json.dumps(wram_status(a.directory), indent=2, sort_keys=True))
        return
    try:
        if a.kind in ('wramarb', 'all'):
            print('WRAM', wram(a.directory))
        if a.kind in ('menu', 'all'):
            print('GX', gx(a.directory))
            print('raster', raster(a.directory))
        if a.kind == 'all':
            basic.check('load2d', a.directory)
            basic.check('perftime2', a.directory)
    except (OSError, ValueError, KeyError) as e:
        p.exit(1, f'INCOMPLETE: {e}\n')
    print('COMPLETE output only; no DS timing/correctness assertion.')


if __name__ == '__main__':
    main()
