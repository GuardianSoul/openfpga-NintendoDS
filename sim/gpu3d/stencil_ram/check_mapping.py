#!/usr/bin/env python3
"""Check the *actual* fitted private stencil RAM contract and owned area.

Usage: check_mapping.py FIT_REPORT_DIRECTORY
The directory contains queue-nds-fit's rams.json(.gz) and entities.json(.gz).
Simulation alone cannot establish that a ramstyle request was honored.
"""
import argparse
import gzip
import json
from pathlib import Path
import sys


def read(directory, name):
    p = directory / (name + '.json')
    if p.exists():
        return json.loads(p.read_text())
    with gzip.open(str(p) + '.gz', 'rt') as f:
        return json.load(f)


def check(directory):
    entities = read(directory, 'entities')
    roots = [(k, v) for k, v in entities.items() if k.endswith('gpu3d_ram:u_stencil')]
    assert len(roots) == 1, 'expected exactly one private stencil instance'
    node, entity = roots[0]
    rams = [r for r in read(directory, 'rams') if 'gpu3d_ram:u_stencil|' in r['Name']]
    assert len(rams) == 1, 'private stencil not mapped to one physical RAM'
    ram = rams[0]
    required = {'Mode': 'Simple Dual Port', 'Clock Mode': 'Single Clock',
                'Port A Depth': '512', 'Port B Depth': '512',
                'Port A Width': '2', 'Port B Width': '2',
                'Port B Input Registers': 'yes', 'Port B Output Registers': 'no',
                'Mixed Width RDW Mode': 'Old data', 'M10K blocks': '1', 'MLABs': '0'}
    for key, expected in required.items():
        assert ram.get(key) == expected, f'{key}: expected {expected}, actual {ram.get(key)}'
    needed = float(entity['ALMs needed [=A-B+C]'].split(' (')[0])
    own = float(entity['ALMs needed [=A-B+C]'].split('(')[1].strip(')'))
    registers = int(entity['Dedicated Logic Registers'].split(' (')[0])
    gain = round(900.3 - needed, 1)
    assert gain >= 500, f'owned gain {gain} ALMs falls below this experiment\'s 500-ALM target'
    assert registers < 26, f'expected to remove the 1024 storage flops, actual registers {registers}'
    return dict(verdict='PASS_PRIVATE_STENCIL_MAPPING_AND_OWNED_GAIN', node=node,
                needed_ALMs=needed, own_ALMs=own, registers=registers,
                baseline1145_needed_ALMs=900.3, owned_gain_ALMs=gain,
                additional_private_M10K=1, ram=ram,
                limits='Full-design capacity/timing and coordinator source/profile identity remain separate gates; compare same1asR14.92ns.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(check(args.directory), indent=2))
    except (AssertionError, KeyError, ValueError) as e:
        print(json.dumps(dict(verdict='FAIL_MAPPING_OR_OWNED_GAIN', reason=str(e)), indent=2))
        sys.exit(1)
