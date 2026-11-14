#!/usr/bin/env python3
"""Bounded Burnout-race/GS-title observation; never dispatches a fit.

inventory is read-only; build/run enforce disk, memory, mutex and worker caps.
Controls require a recorded mechanism reason. No scene preparation refreshes
another owner's exports. Existing ROM/state/export/reference files are pinned.
"""
import argparse
import fcntl
import io
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess as source_process
import subprocess
import sys
import time
import tarfile

ROOT = Path(__file__).resolve().parents[2]
MAIN = Path('/home/user/Git/NDS_Pocket')
BASE = '1d90f68aab4b5a239fe32f8a8872adf06552aefe'
OUT = ROOT / 'build/title-waits'
STATUS = MAIN / 'build/coordinator/units/CPUCompression.json'
LIMIT = 512 * 1024**2
SCENES = {
    'race': dict(name='burnout-race', rom='burnout.nds', frames=16, hold='001',
                 retained=MAIN/'build/census/exports/burnout-race-rc4hw'),
    'title': dict(name='gsdd-title', rom='gsdd.nds', frames=10, hold=None,
                  retained=Path('/home/user/Git/NDS_Pocket-qwen-rc6a/build/scenes/gsdd-title')),
    'battle': dict(name='gsdd-battle',rom='gsdd.nds',frames=10,hold=None,
                  retained=MAIN/'build/census/exports/gsdd-battle-clean'),
}


def digest(p):
    h = hashlib.sha256()
    with Path(p).open('rb') as f:
        for b in iter(lambda: f.read(1024 * 1024), b''):
            h.update(b)
    return h.hexdigest()


def atomic(p, data):
    p.parent.mkdir(parents=True, exist_ok=True)
    temp = p.with_name(p.name + '.Raster.tmp')
    temp.write_text(json.dumps(data, separators=(',', ':')) + '\n')
    os.replace(temp, p)


def status(phase, workers=None, **updates):
    d = json.loads(STATUS.read_text())
    d.update(phase=phase, updated_at=time.time(), workers=workers or [], **updates)
    encoded = json.dumps(d, separators=(',', ':'))
    if len(encoded.encode()) > 2047:
        raise RuntimeError('owner status exceeds2KiB')
    atomic(STATUS, d)


def guard(build=False):
    free = shutil.disk_usage(ROOT).free
    mem = int(next(x.split()[1] for x in Path('/proc/meminfo').read_text().splitlines()
                   if x.startswith('MemAvailable:'))) * 1024
    if free < 30 * 1024**3 or (build and mem < 12 * 1024**3):
        reason = f'disk={free/1024**3:.2f}GiB (need30); MemAvailable={mem/1024**3:.2f}GiB (build needs12)'
        status('SYMPTOM_OBSERVER_RESOURCE_BLOCKED', resource_blocker=reason)
        raise RuntimeError(reason)


def run_module():
    s = importlib.util.spec_from_file_location('pocket_run', ROOT/'sim/pocket_ds/run.py')
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


def inventory(output):
    if output.exists():
        raise RuntimeError(f'refuse to overwrite immutable input inventory: {output}')
    files = set()
    result = {'source': BASE, 'scenes': {}, 'files': []}
    for key, scene in SCENES.items():
        retained = scene['retained']
        state = MAIN/'build/census/states'/f'{scene["name"]}.mln'
        clean_frame=int((retained/'exp/clean.txt').read_text().split()[1])
        paths = [state, MAIN/'roms'/scene['rom']]
        paths += list((retained/'exp').glob('*'))
        paths += [retained/'mel'/x for x in ['summary.json', 'frames.csv', 'swaps.txt']]
        # Explicit first N frames only, no nearest-frame selection or new sweep.
        paths += [retained/'mel/shots'/f'f{i:06d}.ppm' for i in range(clean_frame+1,clean_frame+scene['frames']+1)]
        for p in paths:
            if not p.is_file():
                raise RuntimeError(f'missing pinned input: {p}')
        files.update(paths)
        result['scenes'][key] = {**{k: v for k, v in scene.items() if k!='retained'},
                                'retained': str(retained), 'state': str(state),
                                'reference_summary': json.loads((retained/'mel/summary.json').read_text()),
                                'clean_export_frame':clean_frame,
                                'fixed_reference_frames': [clean_frame+1,clean_frame+scene['frames']],
                                'motion_estimation_is_not_oracle_alignment': True}
    files.update(MAIN/'roms'/x for x in ['bios9.bin', 'bios7.bin', 'firmware.bin'])
    files.update([ROOT/'sw/boot/bootrom.bin', ROOT/'sw/scpu/cache.bin', MAIN/'build/boot/bootrom.hex'])
    for p in sorted(files):
        result['files'].append(dict(path=str(p), bytes=p.stat().st_size, sha256=digest(p)))
    if 'battle' in result['scenes']:
        root=json.loads((MAIN/'build/coordinator/rc053-gs-battle-inventory.json').read_text())
        for path,expected in root['files'].items():
            if digest(path)!=expected['sha256']:
                raise RuntimeError('Root battle preflight hash mismatch: '+path)
        result['battle_Root_inventory_sha256']=digest(MAIN/'build/coordinator/rc053-gs-battle-inventory.json')
    atomic(output, result)
    return result


def check_inputs(inventory_path):
    info = json.loads(inventory_path.read_text())
    for f in info['files']:
        p = Path(f['path'])
        if p.stat().st_size != f['bytes'] or digest(p) != f['sha256']:
            raise RuntimeError(f'PINNED INPUT CHANGED: {p}')
    return info


def bounded(cmd, cwd, log, phase, seconds=7200, observation=None):
    guard(build=phase.endswith('BUILD'))
    start = time.monotonic()
    os.setpriority(os.PRIO_PROCESS,0,10)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    if phase.endswith('SIM'):
        cmd = ['stdbuf', '-oL', *cmd]
    with log.open('w') as f:
        p = subprocess.Popen(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
        child_nice=os.getpriority(os.PRIO_PROCESS,p.pid)
        if child_nice<10:
            os.killpg(p.pid,15);p.wait();raise RuntimeError('child priority is above authorized NI10')
        status(phase, workers=[dict(host='Desktop', parent=os.getpid(), pid=p.pid, ni=child_nice, threads=1)],
               resource_blocker=None)
        atomic(log.with_suffix('.process.json'), dict(pid=p.pid, parent=os.getpid(), command=cmd,
                                                    cwd=str(cwd), start_unix=time.time(),ni=child_nice))
        while p.poll() is None:
            size = log.stat().st_size
            if observation:
                size += sum(x.stat().st_size for x in observation.rglob('*') if x.is_file())
            if time.monotonic()-start > seconds or size > LIMIT:
                # This exact process group belongs to this invocation only.
                os.killpg(p.pid, 15)
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(p.pid, 9)
                    p.wait()
                raise RuntimeError('bounded worker exceeded2h/512MiB cap')
            time.sleep(5)
    atomic(log.with_suffix('.receipt.json'), dict(returncode=p.returncode, seconds=time.monotonic()-start,
                                                log_sha256=digest(log), command=cmd))
    status('SYMPTOM_OBSERVER_WORKER_REAPED')
    return p.returncode


def build(variant, reason, capture=False, inventory_path=None):
    inventory_path=inventory_path or OUT/'inventory.json'
    check_inputs(inventory_path)
    if variant != 'on' and not reason:
        raise RuntimeError('off diagnostic requires a concrete mechanism reason')
    guard(build=True)
    m = run_module()
    key=variant+('-capture' if capture else '')
    if (OUT/f'model-{key}.json').exists():
        raise RuntimeError(f'refuse to replace immutable successful model: {key}')
    obj = OUT/f'obj-{key}'
    obj.mkdir(parents=True, exist_ok=True)
    rtl = ROOT/'rtl'
    if variant=='final-word-control':
        rtl=OUT/'rtl-word-control-412c'
        if not rtl.exists():
            archive=source_process.check_output(['git','archive','412c18818c35c5201b60d235b27fe0250d00f416','rtl'],cwd=ROOT)
            with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
                for member in tar:
                    if not member.isfile():continue
                    relative=Path(member.name).relative_to('rtl')
                    target=rtl/relative;target.parent.mkdir(parents=True,exist_ok=True)
                    target.write_bytes(tar.extractfile(member).read())
    if variant == 'tpf-off':
        rtl = OUT/'rtl-tpf-off'
        if not rtl.exists():
            shutil.copytree(ROOT/'rtl', rtl)
        path = rtl/'ds/nds_gpu3d.sv'
        old = (ROOT/'rtl/ds/nds_gpu3d.sv').read_text()
        needle = 'parameter bit TPF = 1,'
        assert old.count(needle)==1
        new = old.replace(needle, 'parameter bit TPF = 0,')
        assert new.replace('parameter bit TPF = 0,', needle)==old
        path.write_text(new)
    headers=[ROOT/'sim/pocket_ds/title_wait_observer.svh',ROOT/'sim/pocket_ds/raster_observer.svh']+([ROOT/'sim/pocket_ds/raster_capture_observer.svh'] if capture else [])
    if variant.startswith('final-'):
        assert capture, 'final-consumer profile requires independent capture oracle'
        headers += [ROOT/'sim/pocket_ds/raster_lifetime_observer.svh']
    frozen=OUT/f'frozen-model-{key}-source'
    lock = Path.home()/'.cache/nds-sim-build.lock'
    lock.parent.mkdir(parents=True, exist_ok=True)
    with lock.open('w') as f:
        status('FINAL_CONSUMER_BUILD_MUTEX_WAIT' if variant.startswith('final-') else 'SYMPTOM_OBSERVER_BUILD_MUTEX_WAIT')
        fcntl.flock(f, fcntl.LOCK_EX)
        guard(build=True)
        if frozen.exists():
            raise RuntimeError(f'refuse to replace source snapshot: {frozen}')
        # Compile the snapshot itself. Recording live inputs after compilation
        # could bind a newer edit to an older binary.
        frozen.mkdir()
        shutil.copytree(rtl, frozen/'rtl')
        entries=[]
        for original in sorted(rtl.rglob('*')):
            if original.is_file():
                target=frozen/'rtl'/original.relative_to(rtl)
                entries.append(dict(path=str(original),frozen_source=str(target),sha256=digest(target)))
        for original in [*[ROOT/p for p in m.SIM],*headers]:
            target=frozen/original.relative_to(ROOT)
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(original,target)
            entries.append(dict(path=str(original),frozen_source=str(target),sha256=digest(target)))
        actual_source=BASE
        if variant.startswith('final-'):
            actual_source=source_process.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
        if variant=='final-word-control':
            actual_source='412c18818c35c5201b60d235b27fe0250d00f416 RTL; guarded word-chronology observer'
        diff=source_process.check_output(['git','diff','HEAD','--','rtl','sim','tools'],cwd=ROOT)
        snapshot=dict(source=actual_source,workspace_patch_sha256=hashlib.sha256(diff).hexdigest(),
                      frozen_before_compilation_unix=time.time(),sources=entries)
        atomic(frozen/'snapshot.json',snapshot)
        for entry in entries:Path(entry['frozen_source']).chmod(0o444)
        tools = Path('build/tools/oss-cad-suite/bin')
        cmd = [str(tools/'verilator'), '--binary', '--timing', '-O3', '-j', '4', '--threads', '1',
               '-Wno-fatal', '-Wno-WIDTHEXPAND', '-Wno-WIDTHTRUNC', '-Wno-UNUSEDSIGNAL',
               '--timescale', '1ns/1ps', '--top-module', 'tb_ds_pocket', '-GROM_AW=26',
               '+define+NODEBUG', '+define+IMPORT', '+define+RASTER_OBSERVER', '+define+TITLE_WAIT_OBSERVER',
               '-I'+str(frozen/'rtl/pocket'), '-I'+str(frozen/'sim/pocket_ds'), '--Mdir', str(obj)]
        if variant=='llr-off':cmd += ['+define+TB_CORE_PARAMS=, .G3D_LLR(0)']
        if variant=='nx2' or (variant.startswith('final-') and variant.endswith('-nx2')):
            cmd += ['+define+TB_CORE_PARAMS=, .G3D_NX2(1)']
        if variant=='final-rhit-on':cmd += ['+define+TB_CORE_PARAMS=, .VR_RHIT(1)']
        if variant.startswith('final-'):cmd += ['+define+RASTER_LIFETIME_OBSERVER']
        if capture:cmd += ['+define+RASTER_CAPTURE_OBSERVER']
        cmd += [str(frozen/'rtl'/p) for p in m.RTL]+[str(frozen/p) for p in m.SIM]
        rc = bounded(cmd, ROOT, OUT/f'build-{key}.log', 'SYMPTOM_OBSERVER_BUILD')
    if rc:raise RuntimeError(f'build failed{rc}: {OUT/f"build-{key}.log"}')
    for entry in entries:
        assert digest(entry['frozen_source'])==entry['sha256'], 'compiled snapshot was modified'
    atomic(OUT/f'model-{key}.json', dict(**snapshot,variant=variant,capture_observer=capture,reason=reason,
           model=str(obj/'Vtb_ds_pocket'),sha256=digest(obj/'Vtb_ds_pocket'),compiled_from_snapshot=True))


def run(scene_key, variant, mode, capture=False, inventory_path=None):
    if mode=='capture-fault' and not capture:
        raise RuntimeError('capture-address witness requires the capture observer model')
    inventory_path=inventory_path or OUT/'inventory.json'
    inputs=check_inputs(inventory_path)
    if scene_key not in inputs['scenes']:
        raise RuntimeError('scene absent from selected pinned inventory')
    input_hash=digest(inventory_path)
    guard()
    m = run_module()
    scene = SCENES[scene_key]
    data = OUT/f'inputs-{scene_key}'
    data.mkdir(parents=True, exist_ok=True)
    if not (data/'ready.json').exists():
        shutil.copyfile(MAIN/'build/boot/bootrom.hex', data/'bootrom.mif')
        target = data/'rtl/ds/nds_io_route.hex'
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT/'rtl/ds/nds_io_route.hex', target)
        for name in ['bios9', 'bios7', 'firmware']:
            m.write_hex(data/f'{name}.hex', (MAIN/'roms'/f'{name}.bin').read_bytes())
        rom = MAIN/'roms'/scene['rom']
        m.write_hex(data/'rom.hex', rom.read_bytes())
        save = scene['retained']/'exp/save.bin'
        m.write_hex(data/'sav.hex', save.read_bytes())
        boot=(ROOT/'sw/boot/bootrom.bin').read_bytes();serv=(ROOT/'sw/scpu/cache.bin').read_bytes()
        m.write_hex(data/'boot.hex',boot+bytes(8192-len(boot))+serv+bytes(4096-len(serv)))
        extra = m.import_images(scene['retained']/'exp', data)
        atomic(data/'ready.json', dict(import_args=extra, files=[dict(path=str(p),sha256=digest(p))
                                               for p in data.rglob('*') if p.is_file()]))
    ready=json.loads((data/'ready.json').read_text())
    for f in ready['files']:
        if digest(f['path'])!=f['sha256']:
            raise RuntimeError('frozen runtime input changed: '+f['path'])
    key=variant+('-capture' if capture else '')
    if (OUT/f'model-{key}-quarantine.json').exists():
        raise RuntimeError('model source binding is quarantined: '+key)
    model=json.loads((OUT/f'model-{key}.json').read_text())
    for entry in model['sources']:
        if 'frozen_source' in entry:
            assert digest(entry['frozen_source'])==entry['sha256'], 'frozen model source changed'
    if digest(model['model'])!=model['sha256']:
        raise RuntimeError('frozen model changed')
    dest=OUT/f'{scene_key}-{key}-{mode}'
    if dest.exists():
        raise RuntimeError(f'refuse to overwrite retained run: {dest}')
    shots=dest/'shots';shots.mkdir(parents=True)
    plus=[f'+rom={data/"rom.hex"}',f'+romsize={(MAIN/"roms"/scene["rom"]).stat().st_size}',
          f'+bios9={data/"bios9.hex"}',f'+bios7={data/"bios7.hex"}',f'+fw={data/"firmware.hex"}',
          f'+fwsize={(MAIN/"roms/firmware.bin").stat().st_size}',f'+boot={data/"boot.hex"}',
          f'+sav={data/"sav.hex"}',f'+savsize={(scene["retained"]/"exp/save.bin").stat().st_size}',
          '+frames=9999',f'+ro_frames={scene["frames"]}',f'+robs={dest/"observer.csv"}',
          f'+ro_enable={0 if mode=="inverse" else 1}',f'+ro_fault={1 if mode=="hint-fault" else 2 if mode=="read-fault" else 3 if mode=="capture-fault" else 0}',
          f'+shots={shots}',*ready['import_args']]
    if capture:plus += [f'+rcap={dest/"capture.csv"}']
    if scene['hold']:
        plus += [f'+hold={scene["hold"]}']
    rc=bounded([model['model'],*plus],data,dest/'run.log','SYMPTOM_OBSERVER_SIM',observation=dest)
    atomic(dest/'run.json',dict(scene=scene_key,variant=variant,capture_observer=capture,mode=mode,rc=rc,model_sha256=model['sha256'],
                              fixed_frames=scene['frames'],inventory_path=str(inventory_path),inventory_sha256=input_hash))
    if mode in ['hint-fault','read-fault','capture-fault']:
        text=(dest/'run.log').read_text(errors='replace')
        expected={'hint-fault':'hint got=','read-fault':'ring_read got=','capture-fault':'capture_address got='}[mode]
        if not (rc!=0 and 'ROBS_INJECT actual=' in text and 'ROBS_ACTUAL_FAULT_OR_DATA_ERROR' in text and expected in text):
            raise RuntimeError('actual fault was not exercised and caught at the required boundary')
    if rc and mode not in ['hint-fault','read-fault','capture-fault']:
        raise RuntimeError(f'simulation failed{rc}: {dest}')


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=['inventory','build','run'])
    ap.add_argument('--scene',choices=SCENES,default='race')
    ap.add_argument('--variant',choices=['on','tpf-off','llr-off','nx2','final-off','final-nx2','final-prime-off','final-prime-nx2','final-word-control','final-prime2-off','final-prime2-nx2','final-look-off','final-look-nx2'],default='on')
    ap.add_argument('--mode',choices=['observe','inverse','hint-fault','read-fault','capture-fault'],default='observe')
    ap.add_argument('--capture',action='store_true',help='include capture/effective affine-state probes')
    ap.add_argument('--reason',default='')
    ap.add_argument('--inventory',type=Path,default=OUT/'inventory.json')
    a=ap.parse_args();OUT.mkdir(parents=True,exist_ok=True)
    os.setpriority(os.PRIO_PROCESS,0,10)
    try:
        if a.action=='inventory':inventory(a.inventory)
        elif a.action=='build':build(a.variant,a.reason,a.capture,a.inventory)
        else:run(a.scene,a.variant,a.mode,a.capture,a.inventory)
    except Exception as e:
        atomic(OUT/'last-error.json',dict(error=str(e),at=time.time(),action={k:str(v) if isinstance(v,Path) else v for k,v in vars(a).items()}))
        status('SYMPTOM_OBSERVER_BLOCKED_OR_FAILED',resource_blocker=str(e)[:240])
        raise


if __name__=='__main__':
    main()
