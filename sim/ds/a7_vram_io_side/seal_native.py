#!/usr/bin/env python3
"""Seal completed native59 inputs, actual model and raw observable evidence."""
from pathlib import Path
import argparse
import hashlib
import io
import json
import shutil
import subprocess
import sys
import tarfile

R = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('root', type=Path)
p.add_argument('destination', type=Path)
a = p.parse_args()
G, D = a.root.resolve(), a.destination.resolve()
assert (G / 'completion.json').is_file()
assert (G / 'causal-analysis.json').is_file()
D.mkdir(parents=True, exist_ok=False)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
source = json.loads((G / 'source-manifest.json').read_text())
for n, h in source['files'].items():
    assert sha(G / 'source' / n) == h, n
files = {}
for item in G.iterdir():
    if item.is_file() and (item.suffix in ['.json', '.jsonl', '.csv', '.log'] or item.name.startswith('ds30-capture.')):
        if item.name.startswith('store-turn-'):
            continue
        files['actual/' + item.name] = item
for sub in ['host-overlay', 'host-sound51']:
    for item in (G / sub).rglob('*'):
        if item.is_file():
            files[str(item.relative_to(G))] = item
for item in (G / 'ds30').rglob('*'):
    if item.is_file():
        files['prepared/' + str(item.relative_to(G / 'ds30'))] = item
for item in (G / 'source/rtl').rglob('*'):
    if item.is_file():
        files['source/' + str(item.relative_to(G / 'source'))] = item
extras = [
    'build/ds41/witness.svh', 'sim/phase1/cram_model.sv', 'sim/phase1/sdram_chip_model.sv',
    'sim/phase1/sim_prims.sv', 'sim/phase1/sram_model.sv', 'sim/pocket_ds/dma_service_observer.svh',
    'sim/pocket_ds/ds30_observer.svh', 'sim/pocket_ds/ds30_tables.svh',
    'sim/pocket_ds/runtime_import_sound_owned.svh', 'sim/pocket_ds/runtime_import_sound_parent.svh',
    'sim/pocket_ds/sim_prims_ds.sv', 'sim/probe/mf_datatable_model.sv',
    'sim/sound/full_v2/sound_v2_roi.svh', 'sim/sound/runtime_import_sound_parent_banks.svh',
]
for n in extras:
    files['source/' + n] = G / 'source' / n
files['model/Vtb_ds_pocket'] = G / 'model/Vtb_ds_pocket'
files['unita7.nds'] = G / 'unita7.nds'
files['drivers/native_guard.py'] = G / 'native_guard.py'
for n in ['native.py', 'analyze_native.py', 'check_native.py', 'seal_native.py']:
    files['drivers/' + n] = R / 'sim/ds/a7_vram_io_side' / n
for n in ['worker_guard.py', 'sim_ownership.py']:
    files['support/' + n] = R / 'sim/arm/ncnb_store' / n
manifest = {n: dict(bytes=f.stat().st_size, sha256=sha(f)) for n, f in files.items()}
archive = D / 'evidence.tar.gz'
with tarfile.open(archive, 'w:gz', compresslevel=6) as t:
    for n, f in sorted(files.items()):
        t.add(f, arcname=n, recursive=False)
    b = (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode()
    info = tarfile.TarInfo('packet-manifest.json')
    info.size = len(b)
    t.addfile(info, io.BytesIO(b))
qualification = dict(source=source['source'], profile=json.loads((G / 'profile.json').read_text()),
    model=json.loads((G / 'model.json').read_text()),
    archive=dict(sha256=sha(archive), bytes=archive.stat().st_size, members=len(manifest) + 1),
    component_archive_sha256='7bbd2142b8ae336e0ac1b3eb306d79d6a578255b0f3083e2c10ff11d475a257c',
    baseline_originalDS30_archive_sha256='1ee6e003afa0cfe5356aafbbc87228c1a15fd6626dc397c91c64b207de7f62f3',
    scope='One changed originalDS30 and canonicalunita7; timing judged against DS, no broad game/fit qualification')
(D / 'qualification.json').write_text(json.dumps(qualification, indent=2) + '\n')
shutil.copy2(R / 'sim/ds/a7_vram_io_side/check_native.py', D / 'check.py')
with (D / 'replay.json').open('w') as f:
    subprocess.run([sys.executable, D / 'check.py', archive], stdout=f, check=True)
print(json.dumps(qualification['archive'], indent=2))
