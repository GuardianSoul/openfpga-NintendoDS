#!/usr/bin/env python3
"""Find observed tagged-write release boundaries; predict no native speed gain."""
from pathlib import Path
import argparse
import bisect
import collections
import hashlib
import json
from analyze_native import load


def audit(root):
    cpu = load(root / 'vram.cpu.csv')
    mem = load(root / 'vram.mem.csv')
    causal = json.loads((root / 'causal-analysis.json').read_text())
    takes = [r for r in mem if r['take']]
    times = [r['time_ps'] for r in takes]
    commands = {}
    for cmd in [28, 284]:
        rows = [r for r in cpu if r['cmd'] == cmd]
        found = []
        excluded = collections.Counter()
        for prev, now in zip(rows, rows[1:]):
            if not (prev['xpbusy'] and not now['xpbusy'] and prev['vsreq'] and now['vsreq']):
                continue
            assert now['edge'] == prev['edge'] + 1
            at = bisect.bisect_right(times, prev['time_ps']) - 1
            assert at >= 0
            taken = takes[at]
            eligible = (prev['vmwe'] and not prev['vmblk'] and prev['ccut'] and not prev['vsack']
                        and taken['cut'] and taken['we'] and taken['n'] == 1 and taken['be'] == 15)
            if not eligible:
                excluded[str((prev['vmwe'], prev['vmblk'], prev['ccut'], taken['cut'], taken['we'], taken['n'], taken['be']))] += 1
                continue
            assert prev['ccpu'] and prev['cwe'] and taken['addr'] == 0x10040
            assert taken['time_ps'] < prev['time_ps'] < now['time_ps']
            assert now['xpcapture'] and not prev['xpcapture']
            found.append(dict(prior_take_ps=taken['time_ps'], prior_take_edge=taken['edge'],
                wait_edge=prev['edge'], capture_edge=now['edge'], wait_time_ps=prev['time_ps'],
                take_age_ps=prev['time_ps'] - taken['time_ps'], pc=prev['pc'],
                display_pending=prev['greq'] or prev['bwleft'],
                IO_owner=prev['fst'] != 0 and prev['target'] == 7 and prev['mst'] == 1))
        operations = causal['commands'][str(cmd)]['operations']
        ack_edges = {w['capture_edge'] + 1 for w in found}
        assert sum(op['ACK_edge'] in ack_edges for op in operations) == len(found)
        blocked = collections.Counter()
        for index, op in enumerate(operations):
            if 'previous_write_blocker' not in op:
                continue
            assert index > 0
            blocked['CPU_stores_waiting_for_previous_write'] += 1
            if operations[index - 1]['ACK_edge'] in ack_edges:
                blocked['previous_write_has_observed_turn_window'] += 1
        commands[str(cmd)] = dict(actual_eligible_release_windows=len(found), excluded=dict(excluded),
            take_age_ps=dict(sorted(collections.Counter(x['take_age_ps'] for x in found).items())),
            IO_owner_windows=sum(x['IO_owner'] for x in found), blocked_CPU_stores=dict(blocked), windows=found)
    return dict(scope='Actual pre-edge release/capture windows only; no changed-source execution, timing gain or DS internal-edge inference.',
        source=json.loads((root / 'manifest.json').read_text())['source'],
        model=json.loads((root / 'manifest.json').read_text())['model_sha256'],
        input_sha256={n: hashlib.sha256((root / n).read_bytes()).hexdigest() for n in ['vram.cpu.csv', 'vram.mem.csv', 'manifest.json', 'causal-analysis.json']},
        CPU_rows=len(cpu), MEM_rows=len(mem), commands=commands)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('root', type=Path)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    result = audit(a.root)
    a.out.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: {n: v for n, v in x.items() if n != 'windows'} for k, x in result['commands'].items()}, indent=2))
