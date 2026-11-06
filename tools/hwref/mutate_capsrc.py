#!/usr/bin/env python3
"""Check that actual CAP qualification artifacts reject seven corruptions."""
import argparse
import json
from pathlib import Path
import shutil
import struct
import tempfile

import check_capsrc


def run(directory, trace):
    baseline = check_capsrc.analyze(directory, trace)
    raw = trace.read_bytes()
    records = range(1865, len(raw), 12)

    def find_record(typ, predicate):
        return next(p for p in records if raw[p] == ord(typ)
                    and predicate(*struct.unpack_from('<BBHII', raw, p)))

    selectors = find_record('W', lambda t, bits, pad, addr, val:
                            addr == 0x04000508 and val & 255 == 0x86)
    format8 = find_record('W', lambda t, bits, pad, addr, val:
                          addr == 0x04000508 and val & 255 == 0x8e)
    capture = find_record('C', lambda *args: True)
    fetch = baseline['state']['first_required_fetch_record_offset']
    results = []
    for name in ['missing-index-row', 'missing-DONE', 'capture-byte',
                 'source-bit', 'source-fetch', 'duplicate-capture-word',
                 '8bit-format']:
        with tempfile.TemporaryDirectory(prefix='capsrc-mutant-') as tmp:
            root = Path(tmp)
            target = root / 'data'
            shutil.copytree(directory, target)
            mutated = bytearray(raw)
            if name == 'missing-index-row':
                path = target / 'capsrc_index.csv'
                path.write_text('\n'.join(path.read_text().splitlines()[:-1]) + '\n')
            elif name == 'missing-DONE':
                path = target / 'capsrc_progress.txt'
                path.write_text(path.read_text().replace('done b-257v64\n', ''))
            elif name == 'capture-byte':
                path = target / 'capsrc_o1v127d0u0_L.bin'
                data = bytearray(path.read_bytes())
                data[40] ^= 1
                path.write_bytes(data)
            elif name == 'source-bit':
                mutated[selectors + 8] ^= 2
            elif name == 'source-fetch':
                mutated[fetch + 8] ^= 1
            elif name == 'duplicate-capture-word':
                mutated[capture:capture] = mutated[capture:capture + 12]
            elif name == '8bit-format':
                mutated[format8 + 8] ^= 8
            mutated_trace = root / 'spu.trace'
            mutated_trace.write_bytes(mutated)
            try:
                check_capsrc.analyze(target, mutated_trace)
            except ValueError as error:
                results.append(dict(name=name, caught=True, observation=str(error)))
            else:
                raise AssertionError('uncaught mutation: ' + name)
    return results


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--spu-trace', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.directory, args.spu_trace), indent=2))
