#!/usr/bin/env python3
"""Seal the single current-heavy result, raw bindings, and remaining open gaps."""
import gzip
import hashlib
import io
import json
import subprocess
import tarfile
from heavy_game59 import ROOT, OUT, GAME, STAGED, PREFIX, sha, write

DEST = ROOT / 'docs/results/heavy-game59-20261102'


def main():
    terminal = json.loads((OUT / 'terminal.json').read_text())
    assert terminal['exit'] == 0 and terminal['all_children_reaped']
    assert json.loads((OUT / 'analysis-launch.json').read_text())['all_children_reaped']
    assert sha(OUT / 'actual-controller.py') == json.loads((OUT / 'controller-receipt.json').read_text())['driver_sha256']
    assert sha(OUT / 'actual-comparison.py') == json.loads((OUT / 'comparison-checker-receipt.json').read_text())['checker_sha256']
    assert sha(ROOT / 'tools/scorecard/heavy_game59_attribute.py') == sha(OUT / 'actual-attribution.py')
    assert json.loads((OUT / 'attribution.json').read_text())['acceptance']['full_current_source_game'] == 'OPEN'
    generated = {p.name: sha(p) for p in sorted((OUT / 'generated-obj').iterdir()) if p.is_file()}
    assert len([n for n in generated if n.endswith('.h')]) == 5
    assert generated['Vtb_ds_pocket'] == terminal['model_sha256']
    write(OUT / 'generated-build-manifest.json', generated)
    members = {}

    def add(name, path):
        assert name not in members
        members[name] = path.read_bytes()

    names = ['host-preparation.json', 'bound-source.json', 'profile.json', 'production-manifest.json',
        'compiled-inputs.json', 'expanded-inputs.json', 'build-command.json', 'runtime-command.json',
        'source-interface-binding.json', 'controller-receipt.json', 'comparison-checker-receipt.json',
        'attribution-checker-receipt.json', 'model.json', 'status.json', 'terminal.json', 'capture-manifest.json',
        'generated-build-manifest.json', 'passive-guard.patch', 'build.log', 'native.log', 'save.bin',
        'comparison.json', 'frames.json', 'CPU-comparison.json', 'first-semantic-context.json',
        'first-source-gap.json', 'current-service.json', 'current-ldm.json', 'actual-profile-witness.json',
        'analysis-launch.json', 'analysis-status.json', 'analysis.log', 'attribution.json', 'attribution.log']
    for name in names:
        add('current/' + name, OUT / name)
    for label, base in [('game52', GAME), ('current', OUT)]:
        for p in sorted((base / 'shots').glob('*.ppm')):
            add(label + '/shots/' + p.name, p)
        add(label + '/capture.states.jsonl', base / 'capture/capture.states.jsonl')
    for name in ['model.json', 'capture-manifest.json', 'expanded-inputs.json', 'runtime-command.json',
                 'native.log', 'save.bin', 'game52-service.json']:
        add('game52/' + name, GAME / name)
    for n in range(5, 19):
        p = GAME / 'controls/reference/mel/shots' / f'f{n:06d}.ppm'
        add('reference/' + p.name, p)
    add('control56/game52-cache-binding.json', OUT / 'controls/control56/game52-cache-binding.json')
    add('source/tb_ds_pocket.sv', STAGED / 'overlay/sim/pocket_ds/tb_ds_pocket.sv')
    add('source/original-ldm-capture.sv', PREFIX / 'staged/overlay/sim/pocket_ds/storage_pair_ldm_capture.sv')
    add('source/current-ldm-capture.sv', STAGED / 'overlay/sim/pocket_ds/storage_pair_ldm_capture.sv')
    add('source/heavy59_profile.sv', STAGED / 'heavy59_profile.sv')
    add('source/import.s', STAGED / 'production/sw/boot/import.s' if (STAGED / 'production/sw/boot/import.s').exists()
        else ROOT / 'sw/boot/import.s')
    # Bind the owned boot source to the exact production pin, too.
    assert members['source/import.s'] == subprocess.check_output(['git', 'show',
        '2f86d1e69b0fc477d179375315acdefc1b438a68:sw/boot/import.s'], cwd=ROOT)
    for name in ('actual-controller.py', 'actual-comparison.py', 'actual-attribution.py'):
        add('source/' + name, OUT / name)
    for p in sorted((OUT / 'generated-obj').glob('*.h')):
        add('generated/' + p.name, p)
    for name in ['heavy_game59.py', 'storage_control56_compare.py', 'c549_fetch_game52_compare.py']:
        add('checker/' + name, ROOT / 'tools/scorecard' / name)
    for p in sorted((ROOT / 'tools/scorecard/game52_lib').glob('*.py')):
        add('checker/game52_lib/' + p.name, p)
    archive = DEST / 'evidence.tar.gz'
    assert not archive.exists(), 'refuse to overwrite sealed archive'
    with archive.open('wb') as f, gzip.GzipFile(filename='', fileobj=f, mode='wb', mtime=0) as gz, tarfile.open(fileobj=gz, mode='w') as tar:
        for name, data in sorted(members.items()):
            info = tarfile.TarInfo(name); info.size = len(data); info.mode = 0o644; info.mtime = 0
            tar.addfile(info, io.BytesIO(data))
    retained = {}
    for base in (GAME, OUT):
        for p in [base / 'model.bin', base / 'save.bin', *(base / 'capture').iterdir(), *(base / 'shots').glob('*.ppm')]:
            retained[str(p)] = sha(p)
    for p in STAGED.rglob('*'):
        if p.is_file():
            retained[str(p)] = sha(p)
    for p in (OUT / 'generated-obj').iterdir():
        if p.is_file():
            retained[str(p)] = generated[p.name]
    for p in [GAME / 'comparison-streams.json.gz', OUT / 'current-streams.json.gz',
              OUT / 'actual-controller.py', OUT / 'actual-comparison.py', OUT / 'actual-attribution.py',
              OUT / 'controls/control56/model.bin', OUT / 'controls/control56/game52-cache-binding.json']:
        retained[str(p)] = sha(p)
    for base in (GAME, OUT):
        manifest = json.loads((base / 'capture-manifest.json').read_text())
        for name, row in manifest.items():
            assert retained[str(base / 'capture' / name)] == row['sha256'], name
    write(DEST / 'packet.json', dict(archive_sha256=sha(archive), archive_bytes=archive.stat().st_size,
        members={n: hashlib.sha256(d).hexdigest() for n, d in members.items()}, retained=retained,
        scope='Compact image/state/save/profile and parser receipts. Private full raw streams, exact input/production sources, model and all generated build files are retained by hash. No baseline or native rerun; current audio and later CPU/state OPEN.'))
    print('SEALED', len(members), 'members', len(retained), 'retained hashes', sha(archive), archive.stat().st_size)


if __name__ == '__main__':
    main()
