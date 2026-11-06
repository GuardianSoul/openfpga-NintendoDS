#!/usr/bin/env python3
"""Decode RAM-published GX endpoints; validate inputs, never invent DS rates."""
import argparse
import json
from pathlib import Path
import re
import struct


def stream(kind, length):
    entries = (16, 9, 6)[kind]
    n = 1200 * length // entries
    commands = []
    identity = [0x1000 if i in (0, 5, 10, 15) else 0 for i in range(16)]
    for _ in range(n):
        if kind == 0:
            commands.append((0x16, identity))
        else:
            for v in range(3):
                if kind == 1:
                    commands.append((0x21, [0x20100000]))
                x = (0x1400 if v == 1 else 0xe00) if kind == 2 else (0x400 if v == 1 else 0)
                y = 0x400 if v == 2 else 0
                commands.append((0x23, [x | (y << 16), 0]))
    words = []
    for i in range(0, len(commands), 4):
        group = commands[i:i + 4]
        words.append(sum(cmd << (8 * j) for j, (cmd, _) in enumerate(group)))
        for _, parameters in group:
            words.extend(parameters)
    return n, n * entries, words


def input_hash(words):
    value = 2166136261
    for word in words:
        for byte in struct.pack('<I', word):
            value = ((value ^ byte) * 16777619) & 0xffffffff
    return value


def validate(rows):
    if len(rows) != 18:
        raise ValueError(f'require 18 committed rows, got {len(rows)}')
    result = []
    for index, row in enumerate(rows):
        kind, length, rep = index // 6, (index % 6) // 3 + 1, index % 3
        n, entries, words = stream(kind, length)
        if (len(row) != 16 or any(type(word) is not int for word in row) or
                row[:7] != [0x47585031, index + 1, kind, n, rep, entries, len(words)] or
                row[13:] != [length, input_hash(words), index + 1]):
            raise ValueError(f'row {index + 1}: protocol/input/commit mismatch')
        if (any(not 0 <= word <= 0xffffffff for word in row) or row[12] or
                row[7] <= 0 or row[8] < row[7] or row[11] != 0x1000 or row[10] & (1 << 27)):
            raise ValueError(f'row {index + 1}: endpoint/outcome failure')
        result.append(dict(body=('LOAD44', 'TRINRML4', 'TRIXCLIP')[kind], n=n, rep=rep,
                           entries=entries, words=len(words), dma_sys=row[7], idle_sys=row[8],
                           dma_gxstat=row[9], idle_gxstat=row[10], clip0_after_idle=row[11],
                           timeout=row[12], stream_fnv1a32=row[14]))
    return result


def decode_log(text, address=0x023f0100):
    state = [0] * 16
    result = []
    seen = 0
    active = False
    cleared_commit = False
    pattern = r'WW port\s+([0-9a-fA-F]+) <= ([0-9a-fA-F]+) be ([0-9a-fA-F]+)'
    for at, value, enables in re.findall(pattern, text):
        at, value, enables = int(at, 16), int(value, 16), int(enables, 16)
        offset = at - (address & 0x3fffff)
        if not 0 <= offset < 64 or offset % 4:
            continue
        word = offset // 4
        if word == 0 and enables == 15 and value == 0x47585031:
            if active:
                raise ValueError('new packet header before previous commit')
            state = [0] * 16
            seen = 0
            active = True
            cleared_commit = False
        if not active:
            if word == 15 and value:
                raise ValueError('packet commit without a fresh header')
            continue
        if enables == 15:
            seen |= 1 << word
        for byte in range(4):
            if enables & (1 << byte):
                mask = 255 << (byte * 8)
                state[word] = (state[word] & ~mask) | (value & mask)
        if word == 15 and enables == 15 and state[15] == 0:
            cleared_commit = True
        if word == 15 and state[15]:
            if enables != 15 or seen != 0xffff or not cleared_commit:
                raise ValueError('incomplete packet writes or missing cleared commit')
            if state[15] != len(result) + 1:
                raise ValueError('missing, repeated or reordered packet commit')
            result.append(state.copy())
            active = False
    if active:
        raise ValueError('incomplete packet at end of log')
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('input', type=Path)
    p.add_argument('--melonds-json', action='store_true')
    a = p.parse_args()
    rows = json.loads(a.input.read_text())['rows'] if a.melonds_json else decode_log(a.input.read_text())
    result = dict(rows=validate(rows), ds_timing_status='pending matched real-DS capture; no ratio accepted')
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
