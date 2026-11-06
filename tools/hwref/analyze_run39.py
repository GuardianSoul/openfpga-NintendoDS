#!/usr/bin/env python3
"""Analyze immutable run39 DS returns; no simulation or timing-law fitting."""
import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
import struct

from check_arm7fetch import analyze as arm7_check
from check_objlimit import analyze as obj_check
from check_capsrc import cases as cap_cases, require


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cap_returns(directory):
    """Reuse qualified CAP definitions/completeness checks, without a fake trace.

    Hardware files contain no SPU register/fetch trace. Source identity is
    supplied externally; these checks qualify returned bytes and journals.
    """
    defs = cap_cases()
    require((directory/'capsrc_info.txt').read_text().startswith('capsrc odd 1\nbuilt '), 'wrong producer')
    expected = 'V capsrc odd 1\n'+''.join(f'{v} {c["name"]}\n' for c in defs for v in ('start', 'done'))+'all done\n'
    require((directory/'capsrc_progress.txt').read_text() == expected, 'incomplete ordered CAP journal')
    rows = list(csv.DictReader((directory/'capsrc_index.csv').open()))
    require([(r['segment'], int(r['unit'])) for r in rows] == [(c['name'], u) for c in defs for u in (0, 1)], 'incomplete ordered CAP index')
    buffers = []
    for i, c in enumerate(defs):
        for u in (0, 1):
            row = rows[2*i+u]
            s8 = u == 0 and c['format0']
            require(row['format'] == ('s8' if s8 else 's16') and int(row['samples']) == 256, 'format/sample count differs')
            require(int(row['unwritten_words']) == int(row['timeout']) == 0, 'unwritten/timeout')
            name = f'capsrc_{c["name"]}_{"R" if u else "L"}.bin'
            data = (directory/name).read_bytes()
            require(len(data) == (256 if s8 else 512), 'wrong CAP byte count')
            values = struct.unpack('<256'+('b' if s8 else 'h'), data)
            buffers.append(dict(segment=c['name'], unit=u, format=row['format'], filename=name,
                                source_selected=bool(c['source_mask'] & (1 << u)),
                                bytes=len(data), sha256=sha(directory/name),
                                min=min(values), max=max(values), value_counts=dict(Counter(values)),
                                first8=list(values[:8]), suffix_from_index2_constant=len(set(values[2:])) == 1,
                                suffix_value=values[2] if len(set(values[2:])) == 1 else None,
                                values=list(values)))
    return dict(output_complete=True, segments=64, buffers=128, samples=32768,
                timeouts=0, unwritten_words=0, observed_buffers=buffers,
                actual_DS_SPU_trace_available=False,
                limits='No hardware SPU register/fetch trace or register readback. Qualified source/ROM provenance is separate; no Census trace is substituted.')


def candidate_residuals(cap):
    """Test the explicitly proposed integer pipeline, retaining every sample.

    Fixed indices0/1 are reported separately: all observed selected buffers
    start with two zeros. Indices2..255 are compared without a fitted phase.
    No mismatch invalidates the capture or selects a replacement formula.
    """
    by_key = {(r['segment'], r['unit']): r for r in cap['observed_buffers']}
    rows, paired, composed = [], [], []
    for c in cap_cases():
        u = 1 if c['paired'] else c['unit']
        record = by_key[c['name'], u]
        shifted = c['dc'] >> c['divider']
        volume = 128 if c['volume'] == 127 else c['volume']
        pred = (-1 if shifted < 0 else 1) * (abs(shifted)*volume // 128)
        values = record['values']
        rows.append(dict(segment=c['name'], unit=u, dc=c['dc'], volume=c['volume'], divider=c['divider'],
                         predicted_s16=pred, observed_suffix=record['suffix_value'],
                         first2=values[:2], constant_prediction_mismatches_all256=sum(v != pred for v in values),
                         suffix_residual_counts=dict(Counter(v-pred for v in values[2:])),
                         suffix_mismatches=sum(v != pred for v in values[2:])))
        for source_unit in ((0, 1) if c['paired'] else (c['unit'],)):
            observed = by_key[c['name'], source_unit]
            shift = (4, 3, 2, 0)[c['divider']]
            capture_input = ((c['dc'] << shift)*volume) >> 3
            intermediate = capture_input >> (15 if observed['format'] == 's8' else 7)
            predicted = (-1 if intermediate < 0 else 1)*(abs(intermediate)//2)
            composed.append(dict(segment=c['name'], unit=source_unit, format=observed['format'],
                                 capture_input=capture_input, shifted_intermediate=intermediate, predicted=predicted,
                                 observed_suffix=observed['suffix_value'], first2=observed['values'][:2],
                                 suffix_mismatches=sum(v != predicted for v in observed['values'][2:])))
        if c['paired']:
            left = by_key[c['name'], 0]['values']
            right = values
            shifted8 = [v >> 8 for v in right]
            truncated8 = [(-1 if v < 0 else 1)*(abs(v)//256) for v in right]
            paired.append(dict(segment=c['name'], dc=c['dc'], volume=c['volume'], first2_s8=left[:2],
                               observed_s8_suffix=by_key[c['name'], 0]['suffix_value'], observed_s16_suffix=record['suffix_value'],
                               arithmetic_shift_of_returned_s16_mismatches=sum(a != b for a, b in zip(left, shifted8)),
                               toward_zero_div256_of_returned_s16_mismatches=sum(a != b for a, b in zip(left, truncated8))))
    return dict(candidate='signed arithmetic divider shift on integer PCM16 first, then magnitude*volume//128 and sign restore; volume127 means128',
                accepted=False, selected_s16_buffers=64, s16_suffix_failures=[r for r in rows if r['suffix_mismatches']],
                s16_rows=rows, paired8_from_returned16=paired,
                existing_Census_composed_quantizer=dict(source_buffers=len(composed), suffix_samples=len(composed)*254,
                    mismatches=sum(r['suffix_mismatches'] for r in composed), rows=composed,
                    formula='Q=(((dc << [4,3,2,0][divider])*V) >>>3); s16=trunc0((Q>>>7)/2), s8=trunc0((Q>>>15)/2); V=128 for volume127',
                    scope='Composed software output mapping checked on finite DS grid; no hardware internal stage order inferred; startup first2 samples retained separately'),
                conclusion='Candidate rejected by +255,v65,div2 in both units. Neither arithmetic >>8 nor toward-zero /256 of returned s16 explains all paired s8. Internal stage precision/order remains unresolved.')


def analyze(root, layout, cases, manifest, census):
    imported = json.loads(manifest.read_text())
    for name, wanted in imported['files'].items():
        require(sha(root/name) == wanted, 'import hash differs: '+name)
    actual = {str(p.relative_to(root)) for p in root.rglob('*') if p.is_file()}
    require(actual == set(imported['files']), 'import member coverage differs')
    arm7 = arm7_check(root/'arm7fetch-v1', json.loads(layout.read_text()), json.loads(cases.read_text()))
    obj = obj_check(root/'objlimit-v2')
    require(obj['inputs_qualified'] and obj['marker_controls_qualified'] and obj['early_order_control_full'], 'OBJ control/input failure')
    cap = cap_returns(root/'capsrc-v1')
    compared = []
    if census:
        for row in cap['observed_buffers']:
            data = (census/row['filename']).read_bytes()
            require(len(data) == row['bytes'], 'Census buffer size differs')
            values = struct.unpack('<256'+('b' if row['format'] == 's8' else 'h'), data)
            different = [i for i, (a, b) in enumerate(zip(row['values'], values)) if a != b]
            compared.append(dict(segment=row['segment'], unit=row['unit'], format=row['format'],
                                 DS_sha256=row['sha256'], Census_sha256=sha(census/row['filename']),
                                 mismatching_samples=len(different), first_mismatch=different[0] if different else None,
                                 Census_first8=list(values[:8]), Census_value_counts=dict(Counter(values))))
    return dict(imported_files=len(actual), imported_bytes=sum((root/n).stat().st_size for n in actual),
                arm7=arm7, obj=obj, cap=cap, CAP_candidate=candidate_residuals(cap), CAP_Census22_comparison=compared,
                DS_provenance=imported, scope='Run39 real DS returns; all raw startup samples retained; no new probe/run, fit or core acceptance')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('returns', type=Path)
    p.add_argument('--layout', type=Path, required=True)
    p.add_argument('--manifest', type=Path, required=True)
    p.add_argument('--cases', type=Path, default=Path(__file__).resolve().parents[2]/'sw/hwref/arm7fetch/cases.json')
    p.add_argument('--census-cap', type=Path)
    a = p.parse_args()
    print(json.dumps(analyze(a.returns, a.layout, a.cases, a.manifest, a.census_cap), indent=2, sort_keys=True))
