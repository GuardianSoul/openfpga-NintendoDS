#!/usr/bin/env python3
"""Stage qualified scenes and run only the authorized exact-model race24 reuse."""
import argparse
from datetime import datetime, timezone
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
ROOT = Path(__file__).resolve().parents[2]
HEAVY = ROOT / 'build/heavy-game59'
ACTOR = '3fa66f90c09138028868e4aa49a58387411318e95f17f84f501bf24c407910d6'


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda:f.read(1<<20),b''): h.update(block)
    return h.hexdigest()


def write(path, value):
    path.parent.mkdir(parents=True,exist_ok=True)
    q=path.with_name(path.name+'.tmp');q.write_text(json.dumps(value,indent=2)+'\n');q.replace(path)

OUT = ROOT / 'build/scenes62'
MAIN = Path('/home/user/Git/NDS_Pocket')
REF = Path('/home/user/Git/NDS_Pocket-codex-census23-games/references-ABI-v3')
SOURCE = '2f86d1e69b0fc477d179375315acdefc1b438a68'
MODEL = '71d08826ff3b7de66f45aec7623480d16991efb37a2d99cf42e261030fc84c25'
SCENES = [('race', 'inherited-mkds-race-ss', 24, 6),
          ('corner', 'inherited-mkds-intro-corner', 39, 6),
          ('startline', 'inherited-mkds-intro-startline', 39, 6),
          ('ac', 'acww-title', 106, 6), ('hg', 'hg-title', 85, 7)]


def prepare():
    assert not (OUT / 'readiness.json').exists()
    assert sha(HEAVY / 'model.bin') == MODEL
    bound = json.loads((HEAVY / 'bound-source.json').read_text())
    assert bound['source'] == SOURCE and len(bound['profile']) == 58
    assert '-GROM_AW=25' in json.loads((HEAVY / 'build-command.json').read_text())
    capture = HEAVY / 'staged/overlay/sim/pocket_ds/storage_pair_capture.sv'
    assert 'if(last_frame>=24)begin trace_stop=1;pair_capture_close();end' in capture.read_text()
    actor = HEAVY / 'staged/overlay/sim/pocket_ds/tb_ds_pocket.sv'
    assert sha(actor) == ACTOR
    spec = importlib.util.spec_from_file_location('pocket_scene62_import', ROOT / 'sim/pocket_ds/run.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    index_path = MAIN / 'docs/results/census23-games-20261101/reference23-ready.json'
    index = json.loads(index_path.read_text()); catalog = {r['name']: r for r in index['scenes']}
    original = json.loads((HEAVY / 'runtime-command.json').read_text())
    inputs0 = HEAVY / 'staged/inputs'
    rows = []
    for key, name, frames, release in SCENES:
        reference = REF / name
        assert sha(reference / 'ready.json') == catalog[name]['ready_sha256']
        ready = json.loads((reference / 'ready.json').read_text())
        assert ready['generator']['binary_sha256'] == index['generator']['binary_sha256']
        assert ready['generator']['mode_info']['compiled_rule_count'] == 23
        for fname, value in ready['export_sha256'].items():
            assert sha(reference / 'exp' / fname) == value, (key, fname)
        for path, value in ready['runtime_sha256'].items():
            assert sha(Path(path)) == value, path
        base = OUT / key; inputs = base / 'inputs'; inputs.mkdir(parents=True)
        for fname in ('bios9.hex', 'bios7.hex', 'firmware.hex', 'boot.hex', 'bootrom.mif', 'mbox.hex'):
            os.link(inputs0 / fname, inputs / fname)
        rom = MAIN / 'roms' / ready['scene']['rom']
        assert rom.stat().st_size <= 4 * (1 << 25)
        if key in ('race', 'corner', 'startline'):
            os.link(inputs0 / 'rom.hex', inputs / 'rom.hex')
        else:
            module.write_hex(inputs / 'rom.hex', rom.read_bytes())
        imports = module.import_images(reference / 'exp', inputs)
        save = reference / 'exp/save.bin'; module.write_hex(inputs / 'sav.hex', save.read_bytes())
        assert len(list(inputs.iterdir())) == 12
        argv = [x.replace(str(HEAVY), str(base)).replace(str(base / 'run') + '/', str(inputs) + '/')
                for x in original if not x.startswith('+imp_')]
        argv[0] = str(HEAVY / 'model.bin')
        for prefix, value in [('+romsize=', rom.stat().st_size), ('+savsize=', save.stat().st_size),
                              ('+frames=', frames), ('+scene_save_words=', save.stat().st_size // 4)]:
            matches = [i for i, x in enumerate(argv) if x.startswith(prefix)]
            assert len(matches) == 1
            argv[matches[0]] = prefix + str(value)
        argv += imports
        write(base / 'runtime-command.json', argv)
        manifest = {p.name: sha(p) for p in inputs.iterdir()}
        assert len(manifest) == 12 and '+root40_ldm_capture' in argv
        pairs = [dict(raw=i, reference=i-release+1,
                      settled=i>=release+4, reference_available=(reference/'mel/shots'/f'f{i-release+1:06d}.ppm').is_file())
                 for i in range(frames)]
        row = dict(scene=key, reference=name, reference_path=str(reference),
            ready_sha256=catalog[name]['ready_sha256'], input_seed=ready['scene'],
            export_sha256=ready['export_sha256'], runtime_sha256=ready['runtime_sha256'],
            import_plusargs=imports, native_frames=frames, frozen_prior_release_video=release,
            fixed_mapping='reference=raw-frozen_prior_release+1; both screens; no dynamic rephasing',
            frame_pairs=pairs, inputs=manifest, runtime_command_sha256=sha(base / 'runtime-command.json'),
            native_save_bytes=save.stat().st_size, clean_epoch=(reference / 'exp/clean.txt').read_text().strip(),
            exact_model_captures_full_window=frames<=24, capture_cutoff_raw_frame=24,
            state_snapshots_if_reused=min(frames,24)+1,
            qualified_reference_PCM_available=False,
            architectural_reference_scope='Census23 seed/import and terminal100 verified; no matched per-clock native CPU/memory or PCM oracle. Retain native streams/snapshots and report this coverage gap; no baseline rerun.',
            budget=dict(host='Desktop', NI=10, jobs=1, threads=1, wall_timeout_seconds=3600,
                        virtual_timeout_ms=2000, expected_raw_budget_GiB=2 if frames<=39 else 5))
        write(base / 'preparation.json', row); rows.append(row)
    write(OUT / 'readiness.json', dict(source=SOURCE, profile=bound['profile'], model_sha256=MODEL,
        reused_heavy_terminal_sha256=sha(HEAVY / 'terminal.json'),
        source_binding_sha256=sha(HEAVY / 'bound-source.json'), actor_sha256=sha(actor),
        capture_source_sha256=sha(capture), reference23_index_sha256=sha(index_path),
        host_importer_sha256=sha(ROOT / 'sim/pocket_ds/run.py'), scenes=rows,
        compiled=False, executed=False, scope='Source/runtime/input readiness only. ONE exact-model race24 authorized; four longer full-observable gates need a passive capture-limit change and separately approved shared model. Accepted AC-RATE/HG-WING remain closed.'))
    print('READY_FIVE_INPUT_RUNTIME_SCOPES; exact-model race24 only; longer observer limit required', flush=True)


def race():
    readiness = json.loads((OUT / 'readiness.json').read_text())
    base = OUT / 'race'; prep = json.loads((base / 'preparation.json').read_text())
    assert sha(HEAVY / 'model.bin') == MODEL == readiness['model_sha256']
    assert readiness['source'] == SOURCE and prep['native_frames'] == 24
    assert sha(base / 'runtime-command.json') == prep['runtime_command_sha256']
    for name, value in prep['inputs'].items():
        assert sha(base / 'inputs' / name) == value, name
    assert os.getloadavg()[0] < 24 and shutil.disk_usage(base).free > 3 * 1024**3
    (base / 'attempt.lock').open('x').write(MODEL + '\n')
    for name in ('capture', 'shots'):
        (base / name).mkdir()
    os.nice(max(0, 10-os.getpriority(os.PRIO_PROCESS,0)))
    state = dict(source=SOURCE, model_sha256=MODEL, profile=readiness['profile'], host=os.uname().nodename,
        controller_PID=os.getpid(), controller_starttime=Path('/proc/self/stat').read_text().split()[21],
        NI=os.getpriority(os.PRIO_PROCESS,0), jobs=1, threads=1, capture_cutoff_raw_frame=24,
        input_preparation_sha256=sha(base / 'preparation.json'), at_UTC=datetime.now(timezone.utc).isoformat())
    start = time.monotonic()
    with (base / 'native.log').open('w') as log:
        child = subprocess.Popen(json.loads((base / 'runtime-command.json').read_text()), cwd=base/'inputs', stdout=log, stderr=subprocess.STDOUT)
        state.update(PID=child.pid, starttime=Path(f'/proc/{child.pid}/stat').read_text().split()[21], phase='ONE_EXACT_MODEL_RACE24_ACTIVE')
        write(base / 'status.json', state)
        try:
            rc = child.wait(timeout=3600)
        except subprocess.TimeoutExpired:
            child.terminate()
            try: child.wait(timeout=15)
            except subprocess.TimeoutExpired: child.kill(); child.wait()
            rc = child.returncode; state['wall_timeout'] = True
    state.update(phase='ONE_EXACT_MODEL_RACE24_TERMINAL', exit=rc, reaped=True, wall_seconds=time.monotonic()-start)
    write(base / 'status.json', state)
    assert rc == 0, ('native failed; no automatic retry', rc)
    assert sha(HEAVY / 'model.bin') == MODEL
    for name, value in prep['inputs'].items(): assert sha(base/'inputs'/name)==value, name
    assert len(list((base/'shots').glob('*.ppm'))) == 24
    assert len((base/'capture/capture.states.jsonl').read_text().splitlines()) == 25
    write(base/'capture-manifest.json', {p.name:dict(bytes=p.stat().st_size,sha256=sha(p)) for p in (base/'capture').iterdir()})
    write(base/'terminal.json', state)
    print('ONE_EXACT_MODEL_RACE24_TERMINAL', MODEL, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('action', choices=['prepare','race']); args=parser.parse_args()
    prepare() if args.action == 'prepare' else race()
