#!/usr/bin/env python3
"""Restore hash-checked regression inputs from the retained qualification packet."""
from pathlib import Path
import argparse
import hashlib
import json
import tarfile

ROOT = Path(__file__).resolve().parents[3]
PACKET = ROOT / 'docs/results/arm9-fetch-retry-20261101'


def restore(destination, broad=False):
    destination = Path(destination)
    qualification = json.loads((PACKET / 'qualification.json').read_text())
    archive = PACKET / qualification['archive']['file']
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == qualification['archive']['sha256']
    with tarfile.open(archive) as source:
        for name, expected in qualification['archive']['files'].items():
            if broad and (name.startswith('gates/inputs/') or name.startswith('gates/gold-suite/')):
                target = destination / name.removeprefix('gates/')
            elif broad and name == 'gates/input-receipt.json':
                target = destination / 'input-receipt.json'
            elif not broad and name in ['focused/program.hex', 'focused/waits.hex', 'focused/counts.hex']:
                target = destination / Path(name).name
            else:
                continue
            data = source.extractfile(name).read()
            assert len(data) == expected['bytes']
            assert hashlib.sha256(data).hexdigest() == expected['sha256'], name
            if target.exists():
                assert target.read_bytes() == data, f'refusing to overwrite different input: {target}'
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--broad', action='store_true')
    args = parser.parse_args()
    restore(args.destination, args.broad)
