#!/usr/bin/env python3
"""Inspect the six-case OBJ discriminator; never assume a sprite budget."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import struct


def require(ok, message):
    if not ok:
        raise ValueError(message)


def binary(path, size):
    data = path.read_bytes()
    require(len(data) == size, f'{path.name}: expected{size} bytes, got{len(data)}')
    return data


def code(x, y):
    return 1 + (x // 15 if y & 1 else x % 15)


def marker(image, palette, bank, origin, lines=8):
    """Common scanlines96..103 only; do not mix 8px/64px active heights."""
    masks, prefixes = [], []
    for row in range(lines):
        mask = sum(1 << x for x in range(64)
                   if image[(96 + row) * 256 + origin + x] ==
                   (0x8000 | palette[256 + bank * 16 + code(x, row)]))
        masks.append(mask)
        prefix = 0
        while prefix < 64 and mask & (1 << prefix):
            prefix += 1
        prefixes.append(prefix)
    full = all(mask == (1 << 64) - 1 for mask in masks)
    return dict(code_coverage='full' if full else 'no-code-match' if not any(masks) else 'nonfull',
                matched_pixels=sum(mask.bit_count() for mask in masks), line_masks=[f'{m:016x}' for m in masks],
                prefix_columns=prefixes, contiguous_prefix_each_line=[m == (1 << n) - 1 for m, n in zip(masks, prefixes)])


def case_input(kind):
    # count,width,ballast first,marker0 index,marker1 index.
    return ((0, 8, 0, 32, 33), (32, 8, 0, 32, 33),
            (32, 64, 0, 32, 33), (32, 8, 0, 33, 32),
            (32, 64, 0, 33, 32), (32, 64, 2, 0, 1))[kind]


def predict(kind, cap=None, budget=None):
    """Explicit countermodels, not DS cycle counts or acceptance criteria."""
    require((cap is None) != (budget is None), 'choose one countermodel')
    count, width, first, m0, m1 = case_input(kind)
    entries = sorted([(first + i, width, None) for i in range(count)] +
                     [(m0, 64, 0), (m1, 64, 1)])
    admitted, spent, visible = 0, 0, [False, False]
    for _, cost, marker_id in entries:
        if (cap is not None and admitted >= cap) or (budget is not None and spent + cost > budget):
            break
        admitted += 1
        spent += cost
        if marker_id is not None:
            visible[marker_id] = True
    return visible


def predictions():
    return dict(scope='countermodels extrapolated from load2d; not measured cycles; bit23=0 only',
                marker_order='[x128/palette1, x192/palette2]; true means full common eight-line code',
                fixed_count={str(cap): [predict(k, cap=cap) for k in range(6)] for cap in range(31, 35)},
                visible_width_budget_endpoints={str(b): [predict(k, budget=b) for k in range(6)] for b in (1771, 1958)})


def analyze(directory):
    require((directory / 'objlimit_v2_info.txt').read_text().startswith('objlimit v2; built '),
            'missing/wrong producer information; external ROM provenance still required')
    palette = struct.unpack('<512H', binary(directory / 'objlimit_v2_pal.bin', 1024))
    obj = binary(directory / 'objlimit_v2_obj.bin', 8192)
    binary(directory / 'objlimit_v2_bg.bin', 65536)
    input_errors = []
    expected_obj_palette = [0] * 256
    expected_obj_palette[1] = 0x001f
    for i in range(1, 16):
        expected_obj_palette[16 + i] = i | (31 << 5)
        expected_obj_palette[32 + i] = i | (31 << 10)
    if list(palette[256:]) != expected_obj_palette:
        input_errors.append('OBJ palette differs from intended colour codes')
    for base in (0, 8, 16):
        for y in range(64):
            for x in range(64):
                at = (base + (y // 8) * 32 + x // 8) * 32 + (y % 8) * 4 + (x % 8) // 2
                texel = (obj[at] >> (4 * (x & 1))) & 15
                if texel != (code(x, y) if base else 1):
                    input_errors.append(f'OBJ tile{base} texel{x},{y} differs')
                    break
    with (directory / 'objlimit_v2.csv').open() as stream:
        rows = list(csv.DictReader(stream))
    require([int(r['kind']) for r in rows] == list(range(6)),
            'six ordered cases required; missing/duplicate row')
    expected_journal = ''.join(f'{verb} k{k}\n' for k in range(6) for verb in ('start', 'done'))
    require((directory / 'objlimit_v2_progress.txt').read_text() == expected_journal, 'START/DONE coverage incomplete')
    cases = []
    for row in rows:
        kind = int(row['kind'])
        count, width, first, m0, m1 = case_input(kind)
        require([int(row[key]) for key in ('count', 'ballast_width', 'ballast_first', 'eligible', 'marker0_index', 'marker1_index')]
                == [count, width, first, count + 2, m0, m1], 'case input tuple differs')
        require(int(row['timeout']) == 0 and int(row['capture_control_after'], 16) >> 31 == 0 and
                int(row['start_line']) == 192 and 0 <= int(row['end_line']) <= 262 and int(row['capture_ticks']) > 0,
                'capture did not complete in intended phase')
        stem = f'objlimit_v2_k{kind}'
        image = struct.unpack('<49152H', binary(directory / (stem + '.bin'), 98304))
        oam = struct.unpack('<512H', binary(directory / (stem + '_oam.bin'), 1024))
        expected = [0] * 512
        for i in range(128):
            expected[i * 4] = 0x0200
        for i in range(count):
            expected[(first + i) * 4] = 0x0460
            expected[(first + i) * 4 + 1] = 0xc000 if width == 64 else 0
        expected[m0 * 4:(m0 + 1) * 4] = [96, 0xc080, 0x1008, 0]
        expected[m1 * 4:(m1 + 1) * 4] = [96, 0xc0c0, 0x2010, 0]
        if list(oam) != expected:
            input_errors.append(stem + ': actual OAM differs from intended tuple')
        with (directory / (stem + '_regs.csv')).open() as stream:
            regs = {r['field']: int(r['value_hex'], 16) for r in csv.DictReader(stream)}
        if regs['dispcnt'] != 0x11f00:
            input_errors.append(stem + ': DISPCNT readback differs')
        if int(row['oam_readback_match']) != int(list(oam) == expected):
            input_errors.append(stem + ': OAM comparison flag contradicts dumped bytes')
        if regs['bldcnt'] != 0x0241 or regs['bldalpha'] != 0x0808 or regs['mosaic'] or regs['master_bright']:
            input_errors.append(stem + ': BG/blend state differs')
        if [regs[f'bg{i}_cnt'] for i in range(4)] != [0x80 | ((28 + i) << 8) | i for i in range(4)]:
            input_errors.append(stem + ': BG control differs')
        if regs['dispcnt_b'] != 0x10080 or [regs[f'vramcnt{i}'] for i in range(9)] != [0x81, 0x82, 0x84, 0x80, 0, 0, 0, 0, 0]:
            input_errors.append(stem + ': engine-B/VRAM configuration differs')
        roi = [marker(image, palette, bank, origin) for bank, origin in ((1, 128), (2, 192))]
        control = [marker(image, palette, bank, origin, lines=64) for bank, origin in ((1, 128), (2, 192))] if kind == 0 else None
        cases.append(dict(kind=kind, bit23=0, count=count, ballast_width=width, ballast_first=first, marker_indices=[m0, m1], markers=roi, full_height_control=control,
                          capture_ticks=int(row['capture_ticks']), dispcnt_readback=regs['dispcnt']))
    controls_good = all(m['code_coverage'] == 'full' for c in cases if c['kind'] == 0 for m in c['full_height_control'])
    early_good = all(m['code_coverage'] == 'full' for c in cases if c['kind'] == 5 for m in c['markers'])
    return dict(output_complete=True, inputs_qualified=not input_errors, input_errors=input_errors,
                marker_controls_qualified=controls_good, cases=cases,
                early_order_control_full=early_good,
                artifact_sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in sorted(directory.glob('objlimit_v2*')) if p.is_file()},
                countermodel_predictions=predictions(),
                scope='common lines96..103, late/swapped/early marker order controls; code coverage is not a count-cap/cycle-price/bit23-polarity rule',
                status='producer/provenance must be identified separately; no DS result implied')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path, nargs='?')
    parser.add_argument('--predictions', action='store_true')
    args = parser.parse_args()
    require(args.predictions or args.directory is not None, 'directory or --predictions required')
    print(json.dumps(predictions() if args.predictions else analyze(args.directory), indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
