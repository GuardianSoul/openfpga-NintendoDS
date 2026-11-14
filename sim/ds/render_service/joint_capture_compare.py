#!/usr/bin/env python3
"""Compare fixed game windows and the shared-service component prefixes."""
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import re
import sys

from joint_capture_games import CONTROL, TAG, load

def open_trace(path, mode):
    if path.is_file():
        return path.open(mode)
    return gzip.open(path.with_suffix(path.suffix + '.gz'), mode)

def readbacks(path):
    base = 0x06860000
    words_per_copy = 24576
    copies = []
    current = None
    with open_trace(path, 'rt') as trace:
        for line in trace:
            if not line.startswith('R,'):
                continue
            fields = line.rstrip().split(',')
            assert len(fields) == 24
            cycle, frame, duration = map(int, (fields[1], fields[2], fields[4]))
            address = int(fields[5], 16)
            assert sum(map(int, fields[6:])) == duration
            if address == base:
                current = dict(first_SYS=cycle-duration+1, first_frame=frame,
                               words=0, read_cycles=0, contiguous=True)
                copies.append(current)
            if current is None or current['words'] == words_per_copy:
                continue
            current['contiguous'] &= address == base + 4 * current['words']
            current['words'] += 1
            current['read_cycles'] += duration
            current['last_SYS'] = cycle
            current['last_frame'] = frame
    return dict(completed=sum(c['words'] == words_per_copy and c['contiguous'] for c in copies), copies=copies)

def compact_scene(data, run):
    fog = data['fog_effect']
    capture = data['capture']
    swaps = {int(frame): int(count) for count, frame in
             re.findall(r'g3d swaps: (\d+) at video frame (\d+)', (run / 'run.log').read_text())}
    window = data['window']
    capture_counts = Counter()
    for row in capture['rows']:
        if row['words'] == row['width']:
            capture_counts[f"bank{row['bank']}_source3d{row['source_3d']}"] += 1
    capture_arm_frames = [int(c[1]) for c in capture['io_writes']
                          if int(c[3], 16) == 0x64 and int(c[4], 16) & 8 and int(c[5], 16) & 0x80000000]
    motion = {'top': [], 'bottom': []}
    for pair in data['motion_diagnostic']:
        for region in pair['regions']:
            screen = region['region']
            if screen in motion:
                motion[screen].append(dict(changed_pixels=region['changed_pixels'],
                                           adjacent_dy_min_sad=region['adjacent_dy_min_sad']))
    return dict(complete=data['complete'], window=data['window'], rows=data['counts'],
                swaps_through_target=swaps[window['target']],
                two_d_late=data['totals']['two_d_late_pulses'],
                owners=data['owners_wrong_row_wrong_gen_unknown_prefix'], fog=fog,
                capture=data['capture_digest'],
                capture_rows=sum(capture_counts.values()), capture_rows_by_bank_source=capture_counts,
                capture_arm_frames=capture_arm_frames,
                functional_digest=data['functional_digest'],
                full_data=data['full_request_data'], consumed_data=data['consumed_full_data'],
                import_readback=data['initial_memory_readback_pass'],
                check_failures=data['check_failures'], harness_errors=data['harness_errors'], motion=motion,
                fixed_pairs=[{k:row[k] for k in ['frame','rgb555_projection_differing_pixels',
                                                  'rgb666_projection_differing_pixels',
                                                  'reference_sha256']} for row in data['fixed_pairs']])

def compare_scenes(control, test, name):
    before = load(control / 'analysis.json')
    after = load(test / 'analysis.json')
    assert before['run']['inventory_sha256'] == after['run']['inventory_sha256']
    frames = before['run']['fixed_frames']
    assert frames == after['run']['fixed_frames']
    assert before['complete'] and after['complete']
    assert len(before['fixed_shots']) == len(after['fixed_shots']) == frames
    assert [s['frame'] for s in before['fixed_shots']] == [s['frame'] for s in after['fixed_shots']]
    assert [p['reference_sha256'] for p in before['fixed_pairs']] == [
        p['reference_sha256'] for p in after['fixed_pairs']]
    assert before['window'] == after['window']
    result = dict(before=compact_scene(before, control), after=compact_scene(after, test),
                  equal_fixed_images=sum(a['sha256']==b['sha256'] for a,b in zip(before['fixed_shots'],after['fixed_shots'])),
                  same_release_and_target=before['window']==after['window'],
                  same_capture_row_ownership=before['capture']['rows']==after['capture']['rows'])
    if name == 'title':
        result['readback'] = {label:readbacks(path / 'observer.csv.waits.csv')
                              for label,path in [('before',control),('after',test)]}
    return result

def scene(out, name):
    return compare_scenes(CONTROL / f'{name}-{TAG}-observe', out / name, name)

def component(out, before_trace, stop=770325):
    cases = {'before': before_trace}
    for version in (1, 2, 3):
        trial = out / f'render-joint-capture-v{version}'
        if (trial / 'joint-on.result.json').is_file():
            cases[f'joint_v{version}'] = trial / 'joint-on.csv'
    result = {}
    for name, trace in cases.items():
        misses = Counter()
        digest = hashlib.sha256()
        log_text = trace.with_suffix('.log').read_text()
        if name == 'before':
            expected_hash = '0383251056105134a4a076199b8aa3a684413590ad6a06697746a3304b8487b6'
        else:
            expected_hash = load(trace.with_suffix('.result.json'))['trace_sha256']
        match = re.search(r'CONSUMER_VALUE gen=(\d+) y=(\d+) x=(\d+)', log_text)
        failure = tuple(map(int, match.groups())) if match else None
        publication = snapshot = done = None
        with open_trace(trace, 'rb') as stream:
            for line in stream:
                digest.update(line)
                kind, _, rest = line.partition(b',')
                if kind == b'TRAFFIC_DEADLINE_MISS':
                    traffic, _, cycle, *_ = rest.split(b',')
                    if int(cycle) <= stop:
                        misses[int(traffic)] += 1
                elif failure and kind in (b'SNAPSHOT', b'PUBLICATION', b'PRODUCER_DONE'):
                    generation, row, _ = failure
                    values = list(map(int, rest.split(b',')))
                    if values[1] != generation:
                        continue
                    if kind == b'PUBLICATION' and values[3] == row:
                        publication = values
                    elif kind == b'SNAPSHOT' and values[2] == row:
                        snapshot = values
                    elif kind == b'PRODUCER_DONE' and values[2] == row:
                        done = values
                else:
                    assert kind != b'TRACE_CAP_REACHED'
        assert digest.hexdigest() == expected_hash
        data = dict(trace_sha256=expected_hash, traffic_misses=misses, common_stop_SYS=stop)
        if failure:
            generation, row, x = failure
            assert publication and publication[-1] == 1 and snapshot and snapshot[5] < row and done is None
            data['consumer_failure'] = dict(generation=generation, row=row, x=x,
                                            publication=publication, snapshot=snapshot)
        else:
            data['measurement_complete'] = 'COMPLETE_CONE_PASS' in log_text
            data['first_fatal'] = next((line for line in log_text.splitlines() if '%Fatal' in line), None)
        result[name] = data
    return result

def paired_wait(log, stop=770325):
    reasons = ('older_read', 'older_cpu', 'register_post', 'credit', 'fifo_full',
               'ring_post', 'video_post', 'capture_ack', 'unclassified')
    legacy = {}
    attribution = {}
    for line in log.read_text().splitlines():
        kind, _, rest = line.partition(',')
        if kind not in ('CAP_BUDGET', 'PAIR_BUDGET'):
            continue
        cycle, *counts = map(int, rest.split(','))
        if cycle > stop:
            continue
        if kind == 'CAP_BUDGET':
            legacy[cycle] = counts[2]
        else:
            assert len(counts) == len(reasons)
            attribution[cycle] = counts
    assert legacy and legacy.keys() == attribution.keys()
    assert all(sum(attribution[cycle]) == cycles for cycle, cycles in legacy.items())
    totals = {reason: sum(row[index] for row in attribution.values())
              for index, reason in enumerate(reasons)}
    assert totals['unclassified'] == 0
    return dict(stop_SYS=stop, last_full_period_end_SYS=max(legacy), paired_wait_SYS=sum(legacy.values()),
                first_active_gate_SYS=totals)

if __name__ == '__main__':
    output = Path(sys.argv[1]).resolve()
    which = sys.argv[2]
    if which == 'component':
        result = component(output, Path(sys.argv[3]).resolve())
    else:
        result = scene(output, which)
    target = output / f'{which}-comparison.json'
    assert not target.exists(), target
    target.write_text(json.dumps(result, indent=2) + '\n')
    if which == 'component':
        print(json.dumps(result, indent=2))
    else:
        print(which, 'rows', result['before']['rows'], result['after']['rows'],
              '2D', result['before']['two_d_late'], result['after']['two_d_late'],
              'same images', result['equal_fixed_images'])
        if 'readback' in result:
            print('complete readbacks', {k:v['completed'] for k,v in result['readback'].items()})
