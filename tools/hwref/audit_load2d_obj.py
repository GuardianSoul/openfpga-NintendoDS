#!/usr/bin/env python3
"""Explain existing run38 OBJ captures with source geometry; never simulate."""
import argparse
import csv
import gzip
import hashlib
import json
from pathlib import Path
import struct

W, H, OBJ = 256, 192, 0x803f


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def pixels(data):
    require(len(data) == W*H*2, 'require full raw16 capture')
    return list(struct.unpack('<49152H', data))


def active(y):
    # Only this probe's non-affine64x64, positive-X/Y OAM configuration.
    return [i for i in range(128) if (i % 6)*32 <= y < (i % 6)*32+64]


def prefixes(y, reverse=False):
    order = active(y)
    if reverse:
        order.reverse()
    masks, work = [0], [0]
    for i in order:
        x = (i*17) & 255
        width = min(64, W-x)
        masks.append(masks[-1] | (((1 << width)-1) << x))
        work.append(work[-1]+width)
    return order, masks, work


def render(background, count=None, budget=None, reverse=False):
    """Countermodels, not proposed DS rules; budget is visible-pixel units."""
    require((count is None) != (budget is None), 'choose one model family')
    out, admitted = [], []
    for y in range(H):
        order, masks, work = prefixes(y, reverse)
        n = min(count, len(order)) if count is not None else max(i for i, cost in enumerate(work) if cost <= budget)
        admitted.append(n)
        mask = masks[n]
        out.extend(OBJ if mask >> x & 1 else background[y*W+x] for x in range(W))
    return out, admitted


def differences(a, b):
    return [i for i, (x, y) in enumerate(zip(a, b)) if x != y]


def audit(ds, evidence, fixture, capture_manifest):
    files = {}

    def raw(path):
        data = path.read_bytes()
        files[str(path)] = digest(data)
        return data

    capture = json.loads(raw(capture_manifest))
    plan = json.loads(raw(evidence/'plan.json'))
    native = json.loads(raw(evidence/'native-result.json'))
    comparison = json.loads(raw(evidence/'core-comparison.json'))
    require(digest(raw(fixture/'source/probe/sw/hwref/load2d/main.c')) == plan['probe_source_sha256'],
            'qualified probe source changed')
    require(native['exit'] == 0 and native['fixture_reference_valid'] and
            digest((evidence/'plan.json').read_bytes()) == native['plan_sha256'] and
            digest((evidence/'core-comparison.json').read_bytes()) == native['comparison_sha256'],
            'native measurement/fixture provenance differs')
    reference_rows = {r['capture']: r for r in comparison['comparisons']}
    frames = {}
    for load in range(3):
        for b in range(2):
            core_path = fixture/'captures'/f'run38-load{load}-b{b}-rtl.bin'
            core_data = raw(core_path)
            for stress in range(2):
                for rep in range(2):
                    name = f'load2d_{load}_{b}_{stress}_f{rep}.bin'
                    data = raw(ds/name)
                    require(digest(data) == capture['files'][name] == plan['ds_sha256'][name], 'DS capture changed')
                    require(digest(core_data) == reference_rows[name]['core_capture_sha256'], 'core capture changed')
                    ref = raw(fixture/'census'/name)
                    require(digest(ref) == plan['census_sha256'][name], 'qualified Census capture changed')
                    require(core_data == ref, 'frozen core no longer equals qualified Census')
                    frames[name] = (pixels(data), pixels(core_data))
    rows = [{k: int(v) for k, v in r.items()} for r in csv.DictReader((ds/'load2d.csv').open())]
    require(len(rows) == 24 and all(r['timeout'] == r['dma_busy'] == 0 and r['start_line'] == 192 for r in rows),
            'incomplete/failing hardware condition matrix')
    raw(ds/'load2d.csv')
    background = frames['load2d_1_0_0_f0.bin'][0]
    heavy = frames['load2d_2_0_0_f0.bin'][0]
    unlimited, _ = render(background, count=128)
    require(unlimited == frames['load2d_2_0_0_f0.bin'][1], 'source-only unlimited overlay differs from core/Census')
    target = differences(heavy, unlimited)
    require(len(target) == 256 and all(heavy[i] == background[i] and unlimited[i] == OBJ for i in target),
            'difference is not the observed missing-OBJ/background mask')
    count_fits = [n for n in range(129) if render(background, count=n)[0] == heavy]
    reverse_fits = [n for n in range(129) if render(background, count=n, reverse=True)[0] == heavy]
    bands = []
    budget_lo, budget_hi = 0, 1 << 30
    for y in range(0, H, 32):
        order, masks, work = prefixes(y)
        good = []
        for n, mask in enumerate(masks):
            image = [OBJ if mask >> x & 1 else background[y*W+x] for x in range(W)]
            if image == heavy[y*W:(y+1)*W]: good.append(n)
        low = work[min(good)]
        high = work[max(good)+1]-1 if max(good) < len(order) else 1 << 30
        budget_lo, budget_hi = max(budget_lo, low), min(budget_hi, high)
        missing = sorted(i % W for i in target if i // W == y)
        witnesses = []
        for x in missing:
            cover = [i for i in order if (i*17)&255 <= x < ((i*17)&255)+64]
            witnesses.append(dict(x=x, y=y, DS_raw16=f'{heavy[y*W+x]:04x}',
                                  background_raw16=f'{background[y*W+x]:04x}',
                                  unlimited_raw16='803f', covering_OAM_indices=cover,
                                  eligible_ordinals=[order.index(i)+1 for i in cover]))
        bands.append(dict(y=[y, y+31], eligible=len(order), missing_x=missing,
                          conditional_prefix_count_range=[min(good), max(good)],
                          conditional_visible_width_budget_range=[low, None if high == 1 << 30 else high], witnesses=witnesses))
    require(count_fits == [31, 32, 33, 34] and not reverse_fits and (budget_lo, budget_hi) == (1771, 1958),
            'countermodel ambiguity changed')
    # Build an oracle without reading the heavy DS/Census/core pixels:
    # independent DS BG control + literal probe OAM/palette geometry.
    predictions = [render(background, count=n)[0] for n in count_fits]
    require(all(p == predictions[0] for p in predictions), 'candidate predictions are observably different')
    expected = predictions[0]
    budget_prediction, admitted = render(background, budget=1800)
    require(budget_prediction == expected == heavy, 'distinct budget countermodel does not reproduce capture')
    require(all(render(background, budget=b)[0] == expected for b in (budget_lo, budget_hi)),
            'budget interval endpoints do not reproduce all scanlines')
    conditions = []
    for name, (hardware, core) in frames.items():
        is_heavy = name.startswith('load2d_2_')
        oracle = expected if is_heavy else hardware
        require(hardware == oracle, 'oracle does not predict hardware condition')
        errors = differences(oracle, core)
        require(len(errors) == (256 if is_heavy else 0), 'baseline regression changed')
        conditions.append(dict(file=name, core_different_pixels=len(errors), hardware_matches_oracle=True,
                               raw_sha256=files[str(ds/name)]))
    mutated = expected.copy()
    mutated[64*W+9] = OBJ
    mutation_errors = len(differences(mutated, heavy))
    require(mutation_errors == 1, 'single missing-OBJ oracle mutation not caught')
    encoded = struct.pack('<49152H', *expected)
    return dict(status='read-only existing captures; no RTL/build/native/Census/card operation',
                core_source=comparison['core_source_sha'], model_sha256=comparison['model_sha256'],
                probe_source=plan['probe_source_sha'], probe_source_sha256=plan['probe_source_sha256'],
                probe_ROM_sha256=plan['probe_rom_sha256'],
                missing_pixels_per_heavy=256, bands=bands, conditions=conditions,
                countermodels=dict(ascending_prefix_count=count_fits, descending_prefix_count=reverse_fits,
                                   whole_object_visible_width_budget=[budget_lo, budget_hi], example_budget=1800,
                                   example_admitted_counts_per_band=[admitted[y] for y in range(0, H, 32)],
                                   scope='compatible model families only; pixel-units are not measured hardware cycles'),
                oracle=dict(sha256=digest(encoded), matches_all8_hardware_heavy=True,
                            construction='DS four-BG control + source OAM coverage + palette003f/capture highbit; identical predictions for all four compatible count models and budget1800',
                            source_assumption_limit='observationally fitted model family; not a general DS selection/order law or independent new-scene prediction',
                            ignored_pixels=0),
                mutants=dict(single_missing_pixel_changed_to_OBJ_differences=mutation_errors,
                             count30_differences=len(differences(render(background, count=30)[0], heavy)),
                             count35_differences=len(differences(render(background, count=35)[0], heavy))),
                missing_distinction='same64x64/nonaffine/solid/semitransparent/priority/palette and fixedbit23: count versus work and identifiable object order are confounded',
                fixture_limit='isolated bench lets lines finish; integrated line-deadline behavior and general stress arbitration are not measured',
                files=files), encoded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('ds', 'evidence', 'fixture', 'capture-manifest', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    require(not args.out.exists(), 'fresh evidence directory required')
    result, expected = audit(args.ds, args.evidence, args.fixture, args.capture_manifest)
    args.out.mkdir(parents=True)
    (args.out/'expected-heavy.bin.gz').write_bytes(gzip.compress(expected, mtime=0))
    (args.out/'audit.json').write_text(json.dumps(result, indent=2, sort_keys=True)+'\n')
    print(json.dumps(dict(prefix_counts=result['countermodels']['ascending_prefix_count'],
                          visible_width_budget=result['countermodels']['whole_object_visible_width_budget'],
                          oracle_sha256=result['oracle']['sha256'], mutants=result['mutants'])))


if __name__ == '__main__':
    main()
