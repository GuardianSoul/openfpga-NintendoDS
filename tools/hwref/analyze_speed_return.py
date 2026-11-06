#!/usr/bin/env python3
"""Read-only DS return analysis: distinguish recorded behavior from missing output."""
import argparse
from collections import Counter
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import struct

import check_speed_probes as basic
import check_speed_trip as trip


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_files(directory, files):
    basic.require({p.name for p in directory.iterdir() if p.is_file()} == set(files), 'capture file inventory differs')
    for name, digest in files.items():
        basic.require(sha(directory / name) == digest, f'raw capture digest mismatch: {name}')


def wifi(rows):
    """Validate all raw input tuples, preserving zero counter deltas as observations."""
    expected = [(0, 0, 0)] + [(3, arg, rep) for rep in range(32) for arg in (0, 0xf8, 0x158)]
    basic.require([(r['kind'], r['arg'], r['rep']) for r in rows] == expected,
                  'WiFi missing/duplicate/reordered protocol rows')
    basic.require(all(r['command'] == 3 and r['stress'] == r['status'] == r['timeout'] == 0
                      and r['arm7_ticks'] > 0 and all(type(v) is int and 0 <= v <= 0xffffffff
                                                     for v in r.values()) for r in rows),
                  'WiFi invalid row metadata/timer/status')
    counter = [dict(rep=r['rep'], ticks=r['arm7_ticks'], before=r['before'], after=r['after'],
                    delta=(r['after'] - r['before']) & 0xffff) for r in rows if r['arg'] == 0xf8]
    basic.require(all(r['before'] <= 0xffff and r['after'] <= 0xffff for r in rows),
                  'WiFi readback exceeds shipped 16-bit register width')
    first = next((r['rep'] for r in counter if r['delta']), None)
    return dict(rows=len(rows), output_complete=True, counter=counter,
                zero_delta_reps=[r['rep'] for r in counter if r['delta'] == 0],
                delta_counts=dict(Counter(r['delta'] for r in counter)),
                first_advancing_rep=first,
                counter_progress_monitor_passed=first is not None and all(r['delta'] for r in counter[first:]),
                power_enable_readback_captured=False,
                id_values=sorted({r['after'] for r in rows if r['kind'] == 3 and r['arg'] == 0}),
                bb0_values=sorted({r['after'] for r in rows if r['arg'] == 0x158}),
                qualification='minimal wakeup, no settle/readiness/BB-power readback; startup cause/latency unisolated')


def pcm(path):
    data = basic.binary(path, 2048)
    samples = struct.unpack('<1024h', data)
    return dict(sha256=sha(path), samples=1024, minimum=min(samples), maximum=max(samples),
                unique=len(set(samples)), nonzero=sum(v != 0 for v in samples))


def wram(rows):
    result = []
    for store in range(2):
        baseline = None
        for state in range(3):
            groups = []
            for size in range(2):
                command = 1 | ((store | (size << 1) | (state << 2)) << 8)
                groups.append(sorted((r for r in rows if r['command'] == command), key=lambda r: r['rep']))
            basic.require(all([r['rep'] for r in group] == list(range(4)) for group in groups),
                          'WRAM incomplete/duplicate repeats')
            small, large = groups
            basic.require(all(r['operations'] == n for group, n in zip(groups, (256, 1024)) for r in group),
                          'WRAM wrong access denominator')
            delta = [b['arm7_ticks'] - a['arm7_ticks'] for a, b in zip(small, large)]
            slope = [Fraction(t, 768) for t in delta]
            if state == 0:
                baseline = slope
            result.append(dict(operation='store' if store else 'read',
                               source=('off', 'same32B', 'different32B')[state],
                               small_ticks=[r['arm7_ticks'] for r in small],
                               large_ticks=[r['arm7_ticks'] for r in large],
                               delta_ticks=delta, delta_accesses=768,
                               sys_per_access=[float(v) for v in slope],
                               relative_to_off=[float(v / b) for v, b in zip(slope, baseline)],
                               scope='fixed kernel includes EOR and loop work; not isolated LDR/STR latency'))
    return result


def census_comparison(root, measured, ds_directory):
    references = {}
    for name, rom in [('perftime-final', 'f228ab533c1e58f1824f429f4a39128fe4b8acc789d6e7fd3ddfa7030aaf2f44'),
                      ('wramarb-fixed', '3f3b0abf47c17d8809d03a51d1d4914e5d7a6a780635cf441526e73f6ce929ea')]:
        path = root / name / 'qualification.json'
        record = json.loads(path.read_text())
        basic.require(record['rom_sha256'] == rom and record['census_sha256'] ==
                      'ede89703348a7a3c5866a92917608c859e4b54bc22256fd58163e704fdbc926f', 'wrong census/ROM comparator')
        for relative, digest in record['output_sha256'].items():
            basic.require(sha(root / name / 'sd' / relative) == digest, 'census output changed')
        references[name] = dict(qualification=str(path), sha256=sha(path), rom_sha256=rom,
                                census_sha256=record['census_sha256'], output_sha256=record['output_sha256'])
    p = root / 'perftime-final/sd/hwref/trip20261031'
    wr = root / 'wramarb-fixed/sd/hwref/trip20261031'
    baseline = wram(basic.records(wr / 'wramarb.csv'))
    counter = wifi(basic.records(p / 'perftime_3_0.csv'))
    basic.check('perftime2', p)
    sound = []
    for case in measured['sound']:
        command, stress = case['command'], case['stress']
        rows = basic.records(p / f'perftime_{command}_{stress}.csv')
        comparisons = []
        for unit in range(2):
            name = f'perftime_{command}_{stress}_cap{unit}.bin'
            a = struct.unpack('<1024h', basic.binary(ds_directory / name, 2048))
            b = struct.unpack('<1024h', basic.binary(p / name, 2048))
            comparisons.append(dict(unit=unit, unequal_samples=sum(x != y for x, y in zip(a, b)),
                                    max_abs_difference=max(abs(x - y) for x, y in zip(a, b)),
                                    ds_sha256=sha(ds_directory / name), census_sha256=sha(p / name)))
        sound.append(dict(command=command, stress=stress, ds_poll_ticks=case['poll_ticks'],
                          census_poll_ticks=next(r['arm7_ticks'] for r in rows if r['kind'] == 4),
                          ds_enable_ticks=case['enable_ticks'],
                          census_enable_ticks=[r['arm7_ticks'] for r in rows if r['kind'] == 5],
                          raw_sample_comparison=comparisons))
    return dict(references=references, wifi=counter, wram_contention=baseline,
                sound=sound, sample_comparison_scope='raw index equality only; no start-phase/time alignment; differences are retained, not accepted as equivalence or diagnosed as wrong audio',
                wram_ds_over_census=[dict(operation=a['operation'], source=a['source'],
                                         ratios=[x / y for x, y in zip(a['sys_per_access'], b['sys_per_access'])])
                                    for a, b in zip(measured['wram_contention'], baseline)],
                interpretation='Census has no measured WRAM sound contention and starts WiFi counter immediately in 8-count steps; DS observations win. No delay fitting.')


def analyze(directory, manifest, census_preflight=None):
    capture = json.loads(manifest.read_text())
    files = capture['files']
    verify_files(directory, files)
    result = dict(capture_manifest=str(manifest), capture_manifest_sha256=sha(manifest),
                  analysis_tools_sha256={Path(p).name: sha(Path(p)) for p in
                                         (__file__, basic.__file__, trip.__file__)},
                  capture=dict(model=capture['ds_model'], cart=capture['cart'], source=capture['source'],
                               qualification=capture['qualification'], files=len(files),
                               bytes=sum((directory / name).stat().st_size for name in files)),
                  raw_files_sha256=files, ds_vs_census='measured DS behavior is the target; no padding or ratio inferred')
    root = Path(__file__).resolve().parents[2]
    contract_path = root / 'docs/results/hwref-speed-trip-20261031.json'
    contract = json.loads(contract_path.read_text())
    sources = {name: digest for name, digest in contract['sources'].items()
               if name.startswith(('sw/hwref/perftime/', 'sw/hwref/wramarb/'))
               or name == 'sw/hwref/common/mpu_map.h'}
    for name, digest in sources.items():
        basic.require(sha(root / name) == digest, f'shipping probe source changed: {name}')
    result['shipping_source_contract'] = dict(path=str(contract_path), sha256=sha(contract_path), sources=sources)
    result['wram_complete'] = trip.wram(directory)
    result['gx_complete'] = trip.gx(directory)
    result['raster_complete'] = trip.raster(directory)
    basic.check('load2d', directory)
    result['load2d_complete'] = dict(cases=24, captures=24)
    basic.require((directory / 'perftime_info.txt').read_text().startswith('perftime 2;'), 'wrong peripheral protocol')
    cases = basic.peripheral_cases('perftime2')
    expected_journal = ''.join(f'{verb} c{c}_s{s}\n' for c, s in cases for verb in ('start', 'done'))
    basic.require((directory / 'perftime2_progress.txt').read_text() == expected_journal,
                  'perftime incomplete/reordered START/DONE journal')
    # Preserve the original strict verdict. A separate output audit does not
    # rewrite its behavioral expectation or manufacture a nonzero counter.
    try:
        basic.check('perftime2', directory)
        result['original_strict_perftime'] = dict(passed=True)
    except ValueError as error:
        result['original_strict_perftime'] = dict(passed=False, reason=str(error))
    sound, spi = [], []
    for command, stress in cases:
        path = directory / f'perftime_{command}_{stress}.csv'
        rows = basic.records(path)
        if command == 3:
            result['wifi'] = wifi(rows)
            continue
        basic.check_peripheral_case('perftime2', directory, command, stress)
        if command == 1:
            for baud in range(4):
                for byte in range(2):
                    group = [r for r in rows if r['kind'] == 1 and r['arg'] == baud | (byte << 8)]
                    spi.append(dict(baud=baud, byte=byte, ticks=[r['arm7_ticks'] for r in group],
                                    responses=sorted({r['after'] for r in group})))
            continue
        poll = next(r for r in rows if r['kind'] == 4)
        start = sorted((r for r in rows if r['kind'] == 5), key=lambda r: r['rep'])
        arm = next(r for r in rows if r['kind'] == 6)
        arg = command >> 8
        sound.append(dict(command=command, arg=arg, stress=stress, rows=len(rows),
                          format=('PCM8', 'PCM16', 'ADPCM')[arg & 3], channels=len(start),
                          timer=16 if arg & 8 else 512, all16_adpcm=bool(arg & 16),
                          overhead_ticks=rows[0]['arm7_ticks'], poll_ticks=poll['arm7_ticks'],
                          enable_ticks=[r['arm7_ticks'] for r in start],
                          enable_span_ticks=(start[-1]['after'] - start[0]['before']) & 0xffffffff,
                          capture_arm_ticks=arm['arm7_ticks'],
                          captures=[pcm(directory / f'perftime_{command}_{stress}_cap{u}.bin') for u in range(2)]))
    result['spi'] = spi
    result['sound'] = sound
    result['perftime_output_complete'] = dict(csv_files=30, sound_cases=len(sound), captures=56,
                                               journal_pairs=len(cases), status='complete output; WiFi startup findings retained')
    wr = basic.records(directory / 'wramarb.csv')
    result['wram_contention'] = wram(wr)
    result['wram_handover'] = [r for r in wr if r['command'] & 255 == 2]
    result['wram_captures'] = {p.name: pcm(p) for p in sorted(directory.glob('wramarb_*.bin'))}
    result['limitations'] = [
        'WRAM software phase brackets do not certify an individual accepted request was in flight',
        'Counter zero intervals are observations, not missing output; exact power-ready latency/cause not isolated',
        'BB0 under minimal wakeup is not an initialized-radio calibration identity',
        'Sound has one capture per condition; enable/capture/poll windows include MMIO/timestamp/loop overhead',
        'No Pocket-native packed-GX result, game/state/save proof or new DS trip in this analysis']
    if census_preflight is not None:
        result['census_comparison'] = census_comparison(census_preflight, result, directory)
    verify_files(directory, files)
    result['raw_files_unchanged_after_analysis'] = True
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--census-preflight', type=Path)
    args = parser.parse_args()
    result = analyze(args.directory.resolve(), args.manifest.resolve(),
                     args.census_preflight.resolve() if args.census_preflight else None)
    with args.out.open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True)
        stream.write('\n')
    print('Output complete; original strict WiFi startup failure retained. Raw files unchanged.')


if __name__ == '__main__':
    main()
