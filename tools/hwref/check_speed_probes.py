#!/usr/bin/env python3
"""Check staged speed probe output completeness, not DS correctness or timing.

Run after capture: check_speed_probes.py {load2d,perftime,perftime2,aux} DIRECTORY
Never use this check as a substitute for DS capture provenance or paired
core-vs-DS image/sample/timing comparisons.
"""
import argparse
import csv
from pathlib import Path
import struct


def records(path):
    with path.open(newline='') as f:
        return [{k: int(v) for k, v in r.items()} for r in csv.DictReader(f)]


def require(ok, message):
    if not ok:
        raise ValueError(message)


def binary(path, size):
    b = path.read_bytes()
    require(len(b) == size, f'{path}: expected {size} bytes, got {len(b)}')
    return b


def check(kind, directory):
    d = Path(directory)
    if kind == 'load2d':
        rows = records(d / 'load2d.csv')
        expect = {(load, sub, stress, rep) for load in range(3) for sub in range(2)
                  for stress in range(2) for rep in range(2)}
        got = [(r['load'], r['engine_b'], r['stress'], r['rep']) for r in rows]
        require(len(got) == len(expect) and set(got) == expect, 'load2d: missing or duplicate condition')
        for r in rows:
            require(r['timeout'] == 0 and r['dma_busy'] == 0 and r['arm9_system_ticks'] > 0,
                    f'load2d: incomplete capture: {r}')
            require(r['start_line'] == 192 and 0 <= r['end_line'] <= 262,
                    f'load2d: invalid capture phase: {r}')
            name = 'load2d_%d_%d_%d_f%d.bin' % (r['load'], r['engine_b'], r['stress'], r['rep'])
            binary(d / name, 256 * 192 * 2)
    else:
        if kind == 'perftime2':
            require((d / 'perftime_info.txt').read_text().startswith('perftime 2;'),
                    'perftime2: missing version2 protocol identity')
        for command, stress in peripheral_cases(kind):
            check_peripheral_case(kind, d, command, stress)


def peripheral_cases(kind):
    commands = [(2, 0)] if kind == 'aux' else [(1, 0), (3, 0)] + [
        (4 | ((fmt | ((load & 1) << 2) | ((load & 2) << 2)) << 8), stress)
        for fmt in range(3) for load in range(4) for stress in range(2)]
    if kind == 'perftime2':
        commands += [(4 | ((2 | 4 | 16 | (fast << 3)) << 8), stress)
                     for fast in range(2) for stress in range(2)]
    return commands


def check_peripheral_case(kind, directory, command, stress):
    """Check one original case; retains the strict WiFi advancement check."""
    d = Path(directory)
    path = d / f'perftime_{command}_{stress}.csv'
    rows = records(path)
    require(rows and all(r['command'] == command and r['stress'] == stress and
                        r['status'] == 0 and r['timeout'] == 0 and r['arm7_ticks'] > 0
                        for r in rows), f'{path}: invalid or unsuccessful rows')
    require((rows[0]['kind'], rows[0]['arg'], rows[0]['rep']) == (0, 0, 0), f'{path}: missing overhead control')
    cmd = command & 255
    got = [(r['kind'], r['arg'], r['rep']) for r in rows[1:]]
    if cmd in (1, 2):
        expected = {(cmd, baud | (byte << 8), rep) for baud in range(4)
                    for byte in range(2) for rep in range(16)}
    elif cmd == 3:
        expected = {(3, offset, rep) for offset in (0, 0xf8, 0x158) for rep in range(32)}
        for r in rows[1:]:
            if r['arg'] == 0:
                require(r['after'] not in (0, 0xffff), f'{path}: invalid WiFi ID')
            if r['arg'] == 0xf8:
                require((r['after'] - r['before']) & 0xffff, f'{path}: WiFi counter not advancing')
    else:
        expected = {(4, command >> 8, 0)}
        if kind == 'perftime2':
            arg = command >> 8
            channels = 16 if arg & 4 else 4
            expected |= {(k, arg, c) for k in (5, 7) for c in range(channels)} | {(6, arg, 0)}
            events = {r['rep']: r for r in rows if r['kind'] == 5}
            capture = [r for r in rows if r['kind'] == 6]
            require(set(events) == set(range(channels)) and len(capture) == 1,
                    f'{path}: missing sound start timestamps')
            ordered = [events[c] for c in range(channels)] + capture
            origin = ordered[0]['before']
            previous = 0
            for r in ordered:
                require(((r['after'] - r['before']) & 0xffffffff) == r['arm7_ticks'],
                        f'{path}: inconsistent timestamp bracket')
                begin = (r['before'] - origin) & 0xffffffff
                finish = (r['after'] - origin) & 0xffffffff
                require(previous <= begin <= finish < 3351398,
                        f'{path}: invalid sound start ordering')
                previous = finish
            for r in rows:
                if r['kind'] != 7:
                    continue
                clock = not (arg & 16) and r['rep'] in (1, 3)
                fmt = 1 if clock else arg & 3
                require(((r['before'] >> 29) & 3) == fmt and
                        ((r['after'] >> 29) & 3) == fmt,
                        f'{path}: sound format readback mismatch')
        for unit in range(2):
            b = binary(d / f'perftime_{command}_{stress}_cap{unit}.bin', 1024 * 2)
            require(b != struct.pack('<h', 0x5a5a) * 1024, f'{path}: untouched capture unit {unit}')
    require(len(got) == len(expected) and set(got) == expected, f'{path}: missing or duplicate observations')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('kind', choices=['load2d', 'perftime', 'perftime2', 'aux'])
    p.add_argument('directory', type=Path)
    args = p.parse_args()
    try:
        check(args.kind, args.directory)
    except (OSError, KeyError, ValueError) as exc:
        p.exit(1, f'INCOMPLETE: {exc}\n')
    print('COMPLETE output only; no DS timing or correctness assertion.')


if __name__ == '__main__':
    main()
