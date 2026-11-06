#!/usr/bin/env python3
"""Reject mapped physical DSP demand above the Pocket's 66-block capacity.

Run on the synthesis report, never a capped/partially allocated fitter count.
This necessary capacity check does not prove packing, placement or timing;
new operand modes, clocks and register controls still need pre-fit review.
"""
import argparse
import gzip
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('map_report', type=Path)
    args = parser.parse_args()
    raw = args.map_report.read_bytes()
    if args.map_report.suffix == '.gz':
        raw = gzip.decompress(raw)
    report = raw.decode(errors='replace')
    # A synthesis total is an integer, without the fitter's "used / available".
    counts = {int(value.replace(',', '')) for value in re.findall(
        r'^;\s*Total DSP Blocks\s*;\s*([\d,]+)\s*;', report, re.M)}
    if len(counts) != 1:
        print('FAIL DSP: missing/inconsistent synthesis total; do not use a fitter ceiling')
        return 1
    count = counts.pop()
    if count > 66:
        print(f'FAIL DSP: {count} mapped physical blocks > 66; fitter cannot place this design')
        return 1
    print(f'PASS DSP capacity: {count}/66 mapped blocks; placement/packing/timing remain unproved')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
