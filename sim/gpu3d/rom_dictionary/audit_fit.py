#!/usr/bin/env python3
"""Audit the owned ROM subtree from cached same-seed Quartus reports only."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--before', type=Path, required=True)
p.add_argument('--after', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
H = lambda b: hashlib.sha256(b).hexdigest()
owned = '|apf_top|core_top:ic|nds_top:ds|nds_gpu3d:g_3d.u_gpu3d|gpu3d_geom:u_geom|gpu3d_gxeng:u_eng|gpu3d_gxrom_ux:g_romx.u_rom'
num = lambda s: float(s.split()[0])
runs = []
for directory in [a.before, a.after]:
    raw = directory / 'raw'
    budget = json.loads((directory / 'budget.json').read_text())
    read = lambda n: gzip.decompress((raw / n).read_bytes())
    entities = json.loads(read('entities.json.gz'))
    rams = json.loads(read('rams.json.gz'))
    row = entities[owned]
    rows = [v for v in rams if 'gpu3d_gxrom_ux:g_romx.u_rom|' in v['Name']]
    fields = ['Name', 'Port A Depth', 'Port A Width', 'Implementation Port A Depth',
              'Implementation Port A Width', 'M10K blocks', 'MIF']
    report_files = ['entities.json.gz', 'rams.json.gz', 'output_files__apf_top.map.rpt.gz',
                    'ds.sdc.gz', 'receipt.json']
    runs.append(dict(fit=budget['fit'], source=budget['source'], seed=budget['seed'],
                     clock_ns=budget['clock_ns'], needed_ALMs=num(row['ALMs needed [=A-B+C]']),
                     FF=int(num(row['Dedicated Logic Registers'])),
                     M10K=sum(int(r['M10K blocks']) for r in rows),
                     owned_entity=row, RAMs=[{f:r[f] for f in fields} for r in rows],
                     canonical_cache=str(directory.resolve()),
                     raw_sha256={n:H((raw/n).read_bytes()) for n in report_files}))
b, c = runs
assert (b['fit'], c['fit']) == (1160, 1161)
assert b['seed'] == c['seed'] == '1asR' and b['clock_ns'] == c['clock_ns'] == 14.92
assert (b['M10K'], c['M10K']) == (22, 17)
find = lambda rows, name: next(r for r in rows if '|altsyncram:'+name+'_rtl_0|' in r['Name'])
assert int(find(b['RAMs'], 'ra')['M10K blocks']) == 14
assert (int(find(c['RAMs'], 'index_mem')['M10K blocks']), int(find(c['RAMs'], 'word_mem')['M10K blocks'])) == (2, 7)
assert not any('|altsyncram:ra_rtl_0|' in r['Name'] for r in c['RAMs'])
for name in ['rb', 'imt']:
    x, y = find(b['RAMs'], name), find(c['RAMs'], name)
    assert all(x[k] == y[k] for k in ['Port A Depth', 'Port A Width', 'M10K blocks'])
delta = round(c['needed_ALMs'] - b['needed_ALMs'], 1)
assert delta <= 100
text = gzip.decompress((a.after/'raw/output_files__apf_top.map.rpt.gz').read_bytes()).decode()
lines = text.splitlines()
aliases = [dict(line=i+1, text=l.strip()) for i,l in enumerate(lines)
           if 'gpu3d_gxrom_adict:g_a_dict.u_a|' in l and
           any(s in l for s in ['Merged with', 'Lost fanout', 'index_q[0..9]', 'word_q[0..41,43..69]'])]
assert any('|tg ' in x['text'] and '|sq_tg' in x['text'] for x in aliases)
assert any('|tq ' in x['text'] and '|sq_tq' in x['text'] for x in aliases)
assert any('|ph ' in x['text'] and 'gpu3d_gxdivk:' in x['text'] and '|g_p2.ph' in x['text'] for x in aliases)
sdc = gzip.decompress((a.after/'raw/ds.sdc.gz').read_bytes()).decode()
for group in ['gxarom_regs', 'gxdivk_regs', 'gxfin_shared_phase_regs']:
    assert f'set_multicycle_path -setup -end 1 -from [get_clocks $clk_sys] -to ${group}' in sdc
    assert f'set_multicycle_path -hold -end 0 -from [get_clocks $clk_sys] -to ${group}' in sdc
assert '{*|sys_math:*|sq_tq}' in sdc and '{*|gpu3d_gxdivk:*|*}' in sdc
result = dict(runs=runs, owned_delta=dict(needed_ALMs=delta, FF=c['FF']-b['FF'], M10K=-5),
              owned_area_gate='PASS: A14->9M10K; whole ROM22->17; +8.9 neededALM <=100. Parent subtree difference only; never add its nested helper again.',
              mapping_aliases=aliases,
              constraint_source_gate='Private RAM endpoints normal setup1/hold0; merged tq -> sys_math sq_tq has existing strict shared-phase rule; merged ph -> gxdivk g_p2.ph has strict gxdivk rule. tg is the SYS launcher. Report names/source coverage only: TimeQuest collection resolution not executed.',
              whole_chip='CapacityFAIL: 50054 utilizationALM/48325 neededALM/549M10K/74 synthesisDSP. No placement LAB count or STA; no timing closure claim. Whole-chip ALM drift is not owned savings.',
              limitations='Cached MIF filenames/shapes retained, not independent MIF-body validation. Full70 values checked against source/independent baseline units; synthesis drops constant bit42. No fresh fit, report fetch, native run or actor rerun.')
a.out.parent.mkdir(parents=True, exist_ok=True)
a.out.write_text(json.dumps(result, indent=2)+'\n')
print('OWNED_AREA_PASS ROM22->17 A14->9 M10K; neededALM8.4->17.3 delta+8.9; FF21->22; capacityFAIL/noSTA')
