#!/usr/bin/env python3
"""Read-only source/report price for P1/P2 reuse; never compile, fit or run RTL."""
import difflib
import gzip
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / 'docs/results/raster-product60-price-20261102'
RAW = Path('/home/user/Git/NDS_Pocket/build/coordinator/compress59-fit1156/raw')
SOURCE = '755941bea0214a982eab325b7e288d44fc0e3c68'
FIT = '5846f5cf619ee88650189acb863090dd5d5c9f29'
FILE = 'rtl/gpu3d/gpu3d_raster.sv'
PREFIX = '|apf_top|core_top:ic|nds_top:ds|nds_gpu3d:g_3d.u_gpu3d|gpu3d_raster:u_raster'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    source = subprocess.check_output(['git', 'show', SOURCE + ':' + FILE], cwd=ROOT)
    assert source == subprocess.check_output(['git', 'show', FIT + ':' + FILE], cwd=ROOT)
    assert source == (ROOT / FILE).read_bytes(), 'source-only packet must not modify production'
    text = source.decode()
    requirements = [
        "p1_m1 <= 26'(T0.ix * d0.wl);",
        "p1_ix <= T0.ix; p1_xr <= 10'(d0.xdiff - T0.ix);",
        "p2_den <= 25'(26'(p1_ix * d1.wl) + 26'(p1_xr * d1.wr));",
        "assign d0  = SPO ? sd_sl[tsl[0]]  : sd_cur;",
        "assign d1  = SPO ? sd_sl[tsl[1]]  : sd_cur;",
        "for (int i = 20; i > 0; i--) tsl[i] <= tsl[i - 1];",
        "for (int i = 20; i > 0; i--) if (!AREA || i < 7 || i > 11) tg[i] <= tg[i - 1];",
        "for (int i = 0; i <= 22; i++) tg[i] <= '0;",
        "wire         sl_free = sl_n[sl_nx] == '0;",
        "wire        ld_ok = SPO ? sl_free : !early_busy;",
        "if (SPO) begin sd_sl[sl_nx] <= nx_d; wk_sl <= sl_nx; end",
        "if (!AREA || i < 7 || i > 10) early_busy |= tg[i][TV];",
    ]
    for value in requirements:
        assert text.count(value) == 1, value
    assert len(re.findall(r'\bp1_ix\b', text)) == 3
    proposed = text.replace('logic [9:0]  p1_ix, p1_xr;', 'logic [9:0]  p1_xr;')
    proposed = proposed.replace('p1_ix <= T0.ix; p1_xr <=', 'p1_xr <=')
    proposed = proposed.replace("25'(26'(p1_ix * d1.wl) + 26'(p1_xr * d1.wr))",
                                "25'(p1_m1 + 26'(p1_xr * d1.wr))")
    proposed = proposed.replace("// the denominator x*w0 + (xdiff-x)*w1 is one sum-of-two multiply in P2\n    // (w0, w1 from the descriptor); its zero tests come from the operands",
        "// P2 reuses P1's complete x*w0 product; its other product and zero\n    // tests retain the same descriptor, stage and operand widths")
    assert proposed != text and not re.search(r'\bp1_ix\b', proposed)
    patch = ''.join(difflib.unified_diff(text.splitlines(True), proposed.splitlines(True),
        fromfile='a/' + FILE, tofile='b/' + FILE))
    reports = {}
    for name in ('output_files__apf_top.fit.rpt.gz', 'output_files__apf_top.map.rpt.gz', 'map.log.gz'):
        data = (RAW / name).read_bytes()
        reports[name] = dict(sha256=sha(data), lines=gzip.decompress(data).decode(errors='replace').splitlines())
    receipt = json.loads((RAW / 'receipt.json').read_text())
    assert receipt['source'] == FIT and receipt['fit'] == 1156 and receipt['seed'] == '1asR'
    for name, row in reports.items():
        assert row['sha256'] == receipt['files'][name]
    entities = json.loads(gzip.decompress((RAW / 'entities.json.gz').read_bytes()))
    synth = json.loads(gzip.decompress((RAW / 'synthesis-entities.json.gz').read_bytes()))
    p1 = entities[PREFIX + '|lpm_mult:Mult18_rtl_99']
    assert p1['ALMs needed [=A-B+C]'] == '53.3 (0.0)' and p1['DSP Blocks'] == '0'
    fitlines = reports['output_files__apf_top.fit.rpt.gz']['lines']
    dsp = [[c.strip() for c in line.split(';')[1:-1]] for line in fitlines
           if '|gpu3d_raster:u_raster|Add72~8' in line and 'Sum of two 18x18' in line]
    assert len(dsp) == 1 and dsp[0][2] == 'Unassigned'
    packing = [[c.strip() for c in line.split(';')[1:-1]] for line in fitlines
               if '|gpu3d_raster:u_raster|p1_ix[' in line and 'Packed Register' in line]
    assert len(packing) == 10 and all(row[7] == 'BX' and row[6].endswith('|p2_den[0]') for row in packing)
    excerpts = {}
    for name, row in reports.items():
        lines = row['lines']
        selected = set()
        if name.endswith('fit.rpt.gz'):
            for i, line in enumerate(lines):
                if '|gpu3d_raster:u_raster|Add72~8' in line or '|gpu3d_raster:u_raster|p1_ix[' in line or '|gpu3d_raster:u_raster|p1_xr[' in line:
                    selected.add(i)
        elif name.endswith('map.rpt.gz'):
            i = next(i for i, line in enumerate(lines) if line.startswith('; Parameter Settings for Inferred Entity Instance:') and '|gpu3d_raster:u_raster|lpm_mult:Mult18_rtl_99' in line)
            selected.update(range(i, i + 32))
        else:
            selected = {i for i, line in enumerate(lines) if '|gpu3d_raster:u_raster|Mult18~macmult' in line}
        excerpts[name] = dict(sha256=row['sha256'], lines=[dict(line=i+1, text=lines[i]) for i in sorted(selected)])
    result = dict(status='DEFERRED_SHARED_DSP_NO_PRICED_REMOVABLE_GAIN', source=SOURCE,
        fit_source=FIT, raster_sha256=sha(source), source_byte_identical_to_actual1156=True,
        candidate_patch_sha256=sha(patch.encode()), source_statements_checked=len(requirements),
        arithmetic=dict(x_bits=10, w_bits=16, complete_product_bits=26,
            operand_pairs=1 << 26, maximum_product=1023*65535,
            exact_domain_reason='All unsigned10x16 inputs fit in26 bits. Equal complete operands imply equal complete26bit products; no colour/ix<=255 or displayed-bit bound is needed.'),
        alignment_scope='One advancing edge, with arbitrary intervening holds; valid P1 token only. See README for reset, bubble and descriptor-slot proof obligations. Full RTL proof and actual fault execution are pending.',
        p1_retained_soft_multiplier=p1,
        P2_whole_sum_two_DSP=dsp[0], P1_ix_DSP_input_packing=packing,
        raster_parent_context=dict(fitter=entities[PREFIX], synthesis=synth[PREFIX]),
        pricing=dict(duplicate_P2_product='One input of a shared sum-two18x18 DSP, not a standalone DSP/ALM leaf.',
            separate_duplicate_multiplier_leaf_present=False, measured_candidate_gain=None,
            existing_P1_soft_multiplier_ALM=53.3,
            owned_target='Expose reusable26bit product/remove10 logical p1_ix register bits; test whether mapping can combine retained P1 and remaining P2 product or eliminate owned DSP demand. Zero measured gain yet.',
            countercost='Breaking fused sum-two may add a25bit fabric adder or alter DSP packing/register placement. No parent-inclusive ALM delta or guessed standalone duplicate cost.'),
        coordinator_decision='Defer implementation: no priced removable entity or credible whole gain. Retain scoped negative receipt; no miter/model/fit.', compiled=False, native_run=False, fit_queued=False,
        proof_pending=['Complete26bit identity and valid-token one-advance temporal invariant in actual RTL',
            'SPO/default/AREA holds, bubbles, reset and descriptor reuse',
            'P2 denominator full25bit equality and downstream output/event/state equality',
            'Actual candidate RTL p1_m1 bit0 corruption caught by same check'],
        closed_scopes='lerp6/decal/colour49 remain closed; Heavy59 scoped storage/image acceptance and open audio/state gaps unchanged.')
    DEST.mkdir(parents=True, exist_ok=True)
    (DEST / 'candidate.patch').write_text(patch)
    (DEST / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    (DEST / 'actual1156-excerpts.json').write_text(json.dumps(excerpts, indent=2) + '\n')
    print(json.dumps(dict(status=result['status'], p1_soft_ALM=53.3, P2_sum_two_DSP=1,
        standalone_duplicate_cost='not separable; zero measured removable cell gain', compiled=False)))


if __name__ == '__main__':
    main()
