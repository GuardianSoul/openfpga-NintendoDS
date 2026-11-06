#!/usr/bin/env python3
"""Seal one immutable native60 model and all four completed homegrown guests."""
import argparse
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
from compare_native import digest

R = Path(__file__).resolve().parents[3]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('root', type=Path)
    p.add_argument('destination', type=Path)
    a = p.parse_args()
    g, d = a.root.resolve(), a.destination.resolve()
    assert (g/'native-complete.json').is_file()
    assert (g/'runs/ldm53-live/native-vs-DS53.json').is_file()
    source = json.loads((g/'source-manifest.json').read_text())
    for name, sha in source['files'].items():
        assert digest(g/'source'/name) == sha, name
    files = {}
    for f in g.iterdir():
        if f.is_file() and f.suffix in {'.json', '.jsonl', '.log', '.py'}:
            files[f.name] = f
    for directory in ['source', 'host-overlay', 'host-sound51', 'host-observer',
                      'host-inputs', 'host-tools', 'ds30', 'guest-inputs', 'ldm53-control',
                      'reference-inputs', 'failed-compile-v1', 'failed-compile-v2', 'runs']:
        for f in (g/directory).rglob('*'):
            if not f.is_file() or '__pycache__' in f.parts:
                continue
            rel = f.relative_to(g)
            # Expanded BIOS/firmware stay in the private original run directory;
            # the receipts retain their exact hashes. Only homegrown ROMs travel.
            if directory == 'runs' and 'run' in rel.parts[2:]:
                continue
            files[str(rel)] = f
    files['model/Vtb_ds_pocket'] = g/'model/Vtb_ds_pocket'
    for name in ['compare_native.py', 'check_native.py', 'seal_native.py']:
        files['replay/'+name] = R/'sim/ds/vram_joint_turn'/name
    manifest = {name: dict(bytes=f.stat().st_size, sha256=digest(f)) for name, f in sorted(files.items())}
    d.mkdir(parents=True, exist_ok=False)
    archive = d/'evidence.tar.xz'
    with tarfile.open(archive, 'w:xz', preset=3) as tar:
        b = (json.dumps(manifest, indent=2, sort_keys=True)+'\n').encode()
        info = tarfile.TarInfo('packet-manifest.json')
        info.size = len(b)
        tar.addfile(info, io.BytesIO(b))
        for name, f in sorted(files.items()):
            tar.add(f, arcname=name, recursive=False)
    qualification = dict(source=source['source'], frozen_source_files=len(source['files']),
        production_RTL_files=sum(n.startswith('rtl/') for n in source['files']),
        model=json.loads((g/'model.json').read_text()),
        archive=dict(sha256=digest(archive), bytes=archive.stat().st_size, members=len(manifest)+1),
        numeric53=json.loads((g/'runs/ldm53-live/native-vs-DS53.json').read_text())['counts'],
        component_archive_sha256='5137a69bd73724bcc01dbbddc23a4e8668ca32b0fe76277f8c67061e36198aba',
        scope='All4 native60 functional/body/context/model/video/VM guards and raw742/106 capture contract; no dynamic-uop ownership, DS timing/global/game/area/STA acceptance',
        timing_gaps='DS30 STR309/339 versus306; unita7 STR343 versus306, LDR409 versus406; unitmem native58 DMAMV423->418/DS315, DMAVM447->451/DS408, DMAMIO212->213/DS207. All53 numeric rows retained, including below-DS values.',
        private_inputs='Expanded BIOS/firmware excluded; exact input hashes retained. Original model/source/raw and private expanded runtime remain on both nodes.')
    (d/'qualification.json').write_text(json.dumps(qualification, indent=2)+'\n')
    for name in ['compare_native.py', 'check_native.py']:
        shutil.copy2(R/'sim/ds/vram_joint_turn'/name, d/name)
    with (d/'replay.json').open('w') as out:
        subprocess.run([sys.executable, d/'check_native.py', archive], stdout=out, check=True)
    print(json.dumps(qualification['archive'], indent=2))


if __name__ == '__main__':
    main()
