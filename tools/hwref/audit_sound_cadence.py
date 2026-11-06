#!/usr/bin/env python3
"""Read existing DS32/38 sound evidence; no build, simulation or deployment."""
import argparse
from collections import Counter
import csv
import gzip
import hashlib
import io
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def require(ok, message):
    if not ok:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def pcm(data):
    require(len(data) % 2 == 0, 'PCM16 byte length must be even')
    return list(struct.unpack('<' + 'h' * (len(data) // 2), data))


def periodic(samples):
    """Fixed-window diagnostic only; never shift/crop to manufacture a PASS."""
    require(len(samples) == 1024, 'require1024 captured samples')
    window = samples[128:896]
    periods = [k for k in range(1, 129) if window[k:] == window[:-k]]
    changes = [i for i in range(1, len(window)) if window[i] != window[i-1]]
    gaps = Counter(b-a for a, b in zip(changes, changes[1:]))
    levels = sorted(set(window))
    return dict(window=[128, 896], fundamental_period=periods[0] if periods else None,
                unique_value_count=len(levels), unique_values=levels if len(levels) <= 32 else None,
                change_gaps=dict(sorted(gaps.items())),
                first32=window[:32], status='diagnostic; not raw equality acceptance')


def step(samples):
    # sndq gives soundPrepareCap a WORD count: an odd requested PCM16
    # sample count leaves the final halfword outside that programmed span.
    covered = (len(samples) // 2) * 2
    valid = samples[:covered]
    changes = [i for i in range(1, len(valid)) if valid[i] != valid[i-1]]
    return dict(requested_samples=len(samples), programmed_samples=covered,
                unqualified_tail=samples[covered:], transitions=changes,
                first_nonzero=next((i for i, x in enumerate(valid) if x), None),
                values=dict(Counter(valid)))


def audit(ds, capture_manifest, core, archive):
    capture = json.loads(capture_manifest.read_text())
    files = {}

    def raw(path, hardware=False):
        data = path.read_bytes()
        digest = sha(data)
        if hardware:
            require(capture['files'][path.name] == digest, 'returned hardware bytes changed: ' + path.name)
        files[str(path)] = digest
        return data

    cases = []
    groups = {}
    for path in sorted(ds.glob('perftime_*.csv')):
        rs = [{k: int(v) for k, v in r.items()} for r in csv.DictReader(io.StringIO(raw(path, True).decode()))]
        if rs[-1]['kind'] != 4:
            continue
        cmd, stress = rs[0]['command'], rs[0]['stress']
        arg = cmd >> 8
        channels = 16 if arg & 4 else 4
        timer = 16 if arg & 8 else 512
        cap_timer = timer if arg & 16 else 128
        require(len(rs) == 2*channels+3 and all(r['status'] == r['timeout'] == 0 for r in rs), 'incomplete sound rows')
        require([(r['kind'], r['rep']) for r in rs[1:]] ==
                [(k, c) for c in range(channels) for k in (5, 7)] + [(6, 0), (4, 0)], 'event order changed')
        for c, row in enumerate(r for r in rs if r['kind'] == 7):
            clock = not arg & 16 and c in (1, 3)
            expected = 0x80000000 | (1 << 27) | ((1 if clock else arg & 3) << 29) | (64 << 16) | (0 if clock else 8)
            require(row['before'] == row['after'] == expected, 'control format/readback mismatch')
        for row in (r for r in rs if r['kind'] in (5, 6)):
            require(row['after'] - row['before'] == row['arm7_ticks'], 'timestamp bracket mismatch')
        poll = rs[-1]['arm7_ticks']
        require(rs[-1]['before'] == channels and rs[-1]['after'] == timer, 'requested source tuple differs')
        nominal = 1024 * 2 * cap_timer
        waves = [periodic(pcm(raw(ds / f'perftime_{cmd}_{stress}_cap{u}.bin', True))) for u in (0, 1)]
        cases.append(dict(command=cmd, stress=stress, format=arg & 3, channels=channels,
                          requested_voice_timer=timer, requested_capture_timer=cap_timer,
                          capture_poll_ticks=poll, arm_bracket_ticks=rs[-2]['arm7_ticks'],
                          nominal_1024_times_2T=nominal, residual_ticks=poll-nominal,
                          register_readback_scope='SOUNDxCNT only; no TMR/PNT/LEN readbacks', units=waves))
        groups.setdefault(cap_timer, []).append(poll)
    require(len(cases) == 28, 'require all28 run38 sound conditions')
    core_report = json.loads(raw(core / 'report.json'))
    core_plan = json.loads(raw(core / 'source-plan.json'))
    shipping = ROOT / 'build/hwref-trip20261031/perftime.nds'
    require(sha(shipping.read_bytes()) == capture['shipping_rom_sha256']['perftime.nds'] ==
            core_plan['qualified_ROM_and_symbols']['ROM_sha256'], 'measured/reference ROM identity differs')
    source_hashes = {}
    for revision, paths in [('27651c4b735c936ba190d664fa3f25f736f66819',
                             ['sw/hwref/perftime/arm7.c', 'sw/hwref/perftime/main.c', 'sw/hwref/perftime/perftime.h']),
                            ('415fee64', ['sw/hwref/sndq/main.c'])]:
        for path in paths:
            data = subprocess.check_output(['git', 'show', revision + ':' + path], cwd=ROOT)
            source_hashes[revision + ':' + path] = sha(data)
    c260 = []
    for u in (0, 1):
        a = pcm(raw(ds / f'perftime_260_0_cap{u}.bin', True))
        b = pcm(raw(core / f'perftime_260_0_cap{u}.bin'))
        require(files[str(core / f'perftime_260_0_cap{u}.bin')] == core_report['cycle_trace']['PCM_sha256'][u],
                'native PCM does not match qualified accepted-write trace')
        c260.append(dict(unit=u, DS=periodic(a), core=periodic(b),
                         full_raw_different=sum(x != y for x, y in zip(a, b)),
                         core_levels_subset_DS=set(b[128:896]) <= set(a[128:896])))
    period = c260[-1]['core']['fundamental_period']
    require(period == 16, 'qualified c260 core steady period changed')
    cycle = b[128:128+period]
    double_rate = [cycle[(2*i) % period] for i in range(1024)]
    rate_mutation = dict(source='actual core steady cycle, synthetic double-rate resampling only',
                         before_period=period, mutant_period=periodic(double_rate)['fundamental_period'],
                         observed_DS_period=c260[-1]['DS']['fundamental_period'],
                         rejected_as_same_period=periodic(double_rate)['fundamental_period'] != c260[-1]['DS']['fundamental_period'],
                         new_native_run=False)
    archive_hash = sha(archive.read_bytes())

    def member(name):
        data = subprocess.check_output(['tar', '--zstd', '-xOf', str(archive), name])
        files[str(archive) + ':' + name] = sha(data)
        return data

    index = list(csv.DictReader(io.StringIO(member('sndq_index.csv').decode())))
    info = member('sndq_info.txt').decode()
    s2 = []
    for row in index:
        if not row['segment'].startswith('s2_'):
            continue
        require(row['format'] == 's16' and row['timeout'] == row['unwritten_words'] == '0', 'S2 incomplete/format mismatch')
        timer = int(row['segment'].split('_t')[1])
        data = pcm(member(f"sndq_{row['segment']}_{'R' if row['unit']=='1' else 'L'}.bin"))
        require(len(data) == int(row['samples']), 'S2 raw length mismatch')
        s2.append(dict(timer=timer, capture_timer=512, unit=int(row['unit']),
                       nominal_step_index=256*timer/512, **step(data)))
    require(len(s2) == 30, 'require15 S2 timers and both capture units')
    # Inspect the already-completed native observer, without a new run.
    ticks, caps = [], [[], []]
    with gzip.open(core / 'trace.csv.gz', 'rt') as stream:
        schema = next(stream).strip()
        for r in csv.DictReader(stream):
            if r['event'] == 'TICK': ticks.append(int(r['cycle']))
            elif r['event'] == 'CAP_SAMPLE': caps[int(r['a'])].append(int(r['cycle']))
    files[str(core / 'trace.csv.gz')] = sha((core / 'trace.csv.gz').read_bytes())
    require(sha(gzip.decompress((core / 'trace.csv.gz').read_bytes())) == core_report['cycle_trace']['trace_sha256'],
            'native observer trace changed')
    require([len(v) for v in caps] == [1024, 1024], 'native accepted capture coverage incomplete')
    return dict(status='existing-data audit only; no new probe/ROM/native/Census/card operation',
                run38_capture_manifest_sha256=sha(capture_manifest.read_bytes()),
                run38_shipping_ROM_sha256=capture['shipping_rom_sha256']['perftime.nds'],
                inspected_source_sha256=source_hashes,
                source_identity_limit='run38 ROM identity pinned; inspected run32 source/version, original run32 ROM/ELF digest not archived',
                run32_archive_sha256=archive_hash, run32_info=info,
                run32_absolute_duration_and_timer_readbacks='not recorded; index/PCM alone do not supply absolute ticks',
                capture_duration_groups={T: dict(cases=len(v), nominal=2048*T, min=min(v), max=max(v),
                                                residual_min=min(v)-2048*T, residual_max=max(v)-2048*T)
                                         for T, v in groups.items()},
                run38=cases, c260=c260, run32_s2=s2, rate_mutation_diagnostic=rate_mutation,
                core_capture_poll_ticks=core_report['native_protocol']['elapsed_poll_ticks'],
                native_observer=dict(schema=schema, tick_gaps_physical_edges=dict(Counter(b-a for a, b in zip(ticks, ticks[1:]))),
                                     cap_gaps_physical_edges=[dict(Counter(b-a for a, b in zip(v, v[1:]))) for v in caps],
                                     scope='physical edges only; not inferred DS DAC/sample epochs'),
                inference='c260 same period16 plus capture fill scaling rejects a blanket2x rate fix; missing intermediate mix states/phase remain. Capture data do not establish DAC update rate.',
                new_probe_decision='not justified for this rate-vs-mix distinction; exact independent voice startup phase remains unisolated',
                files=files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('ds', 'capture-manifest', 'core', 'archive', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    require(not args.out.exists(), 'preserve previous audit output')
    result = audit(args.ds, args.capture_manifest, args.core, args.archive)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps(result['capture_duration_groups'], sort_keys=True))


if __name__ == '__main__':
    main()
