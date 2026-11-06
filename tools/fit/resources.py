#!/usr/bin/env python3
"""Print failed-fit resource demand even when placement/STA did not finish."""
import argparse
import gzip
from pathlib import Path
import re

NEEDED_COLUMN = 'ALMs needed [=A-B+C]'


def read(path):
    if not path.exists():
        return ''
    raw = path.read_bytes()
    return (gzip.decompress(raw) if path.suffix == '.gz' else raw).decode(errors='replace')


def table(report, title, first):
    lines = report.splitlines()
    start = next((i for i, line in enumerate(lines) if line.startswith('; ' + title + ' ')), None)
    if start is None:
        return []
    headers, rows = None, []
    for line in lines[start + 1:]:
        if line.startswith(';'):
            cells = [v.strip() for v in line.split(';')[1:-1]]
            if cells and cells[0] == first:
                headers = cells
            elif headers and len(cells) == len(headers) and cells[0]:
                rows.append(dict(zip(headers, cells)))
        elif rows and not line.startswith('+'):
            break
    return rows


def number(value):
    match = re.match(r'^([\d,]+(?:\.\d+)?)(?:\s|$)', value)
    return float(match[1].replace(',', '')) if match else None


def resources(fit, mapping):
    entities = table(fit, 'Fitter Resource Utilization by Entity', 'Compilation Hierarchy Node')
    # Component studies can override their top in fit_extra/*.qsf. Use the
    # single actual hierarchy root, rather than the target's nominal name.
    roots = [r for r in entities
             if re.fullmatch(r'\|[^|]+', r.get('Full Hierarchy Name', ''))]
    root = roots[0] if len(roots) == 1 else {}
    needed = number(root.get(NEEDED_COLUMN, ''))
    rams = table(fit, 'Fitter RAM Summary', 'Name')
    counts = [number(r.get('M10K blocks', '')) for r in rams]
    # A failed fitter may report zero allocated RAMs. Use demand rows only;
    # missing demand evidence stays unavailable rather than becoming zero.
    ram = sum(counts) if counts and all(v is not None for v in counts) else None
    dsp_counts = {int(n.replace(',', '')) for n in re.findall(
        r'^;\s*Total DSP Blocks\s*;\s*([\d,]+)\s*;', mapping, re.M)}
    dsp = dsp_counts.pop() if len(dsp_counts) == 1 else None
    # Failed placement can cap LAB allocation at the device limit. That
    # number is not the complete design's LAB demand or a valid placement.
    return needed, ram, dsp, None


def render(values):
    def metric(value, label):
        return label + ' unavailable' if value is None else f'{value:,.1f}'.removesuffix('.0') + ' ' + label
    return ', '.join(metric(value, label) for value, label in zip(
        values, ['needed ALMs', 'M10K demand', 'synthesis DSP', 'LABs']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fit_report', type=Path)
    parser.add_argument('map_report', type=Path)
    args = parser.parse_args()
    print(render(resources(read(args.fit_report), read(args.map_report))))


if __name__ == '__main__':
    main()
