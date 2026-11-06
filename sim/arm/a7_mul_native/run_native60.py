#!/usr/bin/env python3
"""Run the new guest once on the immutable existing native60 binary."""
from pathlib import Path
import argparse, datetime, hashlib, importlib.util, json, os, re, resource, shutil, subprocess, time

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('guest', type=Path)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--native60', type=Path, default=Path('/home/user/Git/NDS_Pocket-codex-vram-joint-turn/build/vram-native60'))
a = p.parse_args()
D = a.output.resolve()
D.mkdir(parents=True, exist_ok=False)
W = D/'run'
W.mkdir()
os.setpriority(os.PRIO_PROCESS, 0, 10)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
resource.setrlimit(resource.RLIMIT_CPU, (1200, 1200))
resource.setrlimit(resource.RLIMIT_AS, (8*1024**3, 8*1024**3))
resource.setrlimit(resource.RLIMIT_FSIZE, (64*1024**2, 64*1024**2))
sha = lambda b: hashlib.sha256(b).hexdigest()
start = lambda pid: Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()[19]
model = a.native60/'model/Vtb_ds_pocket'
meta = json.loads((a.native60/'model.json').read_text())
require_sha = 'fe889b553d710a7c7ab838c33ba5ff62d86fd763fc0e126d86d623ac9c2794da'
assert sha(model.read_bytes()) == meta['sha256'] == require_sha
assert meta['source'] == 'aeaa0cb386d2fbd6f8d2505f8033015956da54b5' and len(meta['profile']) == 60
donor = json.loads((a.native60/'run-commands.json').read_text())['unita7']
for name, digest in donor['expanded_sha256'].items():
    if name == 'rom.hex': continue
    source = Path(donor['cwd'])/name
    assert sha(source.read_bytes()) == digest, name
    shutil.copyfile(source, W/name)
for name, digest in meta['host_sha256'].items():
    assert sha((a.native60/name).read_bytes()) == digest, name
guest = a.guest.resolve()
g = json.loads((guest/'build.json').read_text())
rom = (guest/'a7mulmix-native.nds').read_bytes()
assert sha(rom) == g['ROM_SHA256']
(W/'rom.hex').write_text(''.join(f'{int.from_bytes(rom[i:i+4], "little"):08x}\n' for i in range(0, len(rom), 4)))
command = [model, f'+rom={W/"rom.hex"}', f'+romsize={len(rom)}', f'+bios9={W/"bios9.hex"}',
           f'+bios7={W/"bios7.hex"}', f'+fw={W/"firmware.hex"}', f'+boot={W/"boot.hex"}',
           '+fwsize=262144', '+frames=120', '+timeout_ms=1000', '+vmcheck', '+progress',
           '+stop_done=1', f'+dump_pc={g["dump_pc"][2:]}', f'+dump_file={D/"main.bin"}']
record = dict(source=meta['source'], model_SHA256=require_sha, profile=meta['profile'],
              ROM_SHA256=g['ROM_SHA256'], guest_build_SHA256=sha((guest/'build.json').read_bytes()),
              host=meta['host_sha256'], runtime_inputs={f.name:sha(f.read_bytes()) for f in W.iterdir()},
              command=list(map(str, command)), cwd=str(W), controller=os.getpid(), controller_starttime=start(os.getpid()),
              caps=dict(NI=10, jobs=1, threads=1, CPU_seconds=1200, wall_seconds=1200, AS_bytes=8*1024**3, file_bytes=64*1024**2),
              scope='New six-case captured-image adapter on old immutable native60; no model build or production policy change. First failure stops; no unchanged baseline rerun.')
def save(): (D/'runtime.json').write_text(json.dumps(record, indent=2)+'\n')
status_file = Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json')
def status(proc=None):
    q = json.loads(status_file.read_text())
    q['updated_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    q['phase'] = 'NEW mixed-MUL native60 executing' if proc else 'NEW mixed-MUL native60 terminal; check raw dump'
    q['current_action'] = str(D)+'; new guest only on immutable fe889b55/profile60; no rebuild; bare caller limits retained'
    q['worker'] = dict(host='Desktop', active=bool(proc), PID=proc.pid if proc else None, starttime=start(proc.pid) if proc else None, controller=os.getpid(), NI=10, jobs=1 if proc else 0, threads=1 if proc else 0)
    tmp = status_file.with_name('CPU.json.tmp.'+str(os.getpid()))
    tmp.write_text(json.dumps(q, indent=2)+'\n')
    tmp.replace(status_file)
save()
with (D/'run.log').open('w') as f:
    proc = subprocess.Popen(list(map(str, command)), cwd=W, stdout=f, stderr=subprocess.STDOUT)
    record.update(PID=proc.pid, starttime=start(proc.pid), NI=os.getpriority(os.PRIO_PROCESS, proc.pid))
    save()
    status(proc)
    print('MODEL_STARTED', proc.pid, flush=True)
    begin = time.monotonic()
    try:
        record['exit'] = proc.wait(timeout=1200)
    except subprocess.TimeoutExpired:
        proc.terminate()
        record['exit'] = proc.wait(timeout=10)
        record['timeout'] = True
record.update(reaped=True, wall_seconds=round(time.monotonic()-begin, 3))
save()
status()
assert record['exit'] == 0, (D/'run.log').read_text()[-4000:]
text = (D/'run.log').read_text()
spec = importlib.util.spec_from_file_location('original_native_guard', a.native60/'native_guard.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
original = guard.validate(text, 1, 'mixed-MUL-new')
(D/'original-guard.json').write_text(json.dumps(original, indent=2)+'\n')
assert original['canonical'] and original['values'] == {0:6} and original['PASS'] and original['no_errors']
assert all(v for k,v in original.items() if k.endswith('_ROUTE') or k in ['video','models_clean','native_finish','LDM40_route','joined44_route'])
assert original['vm_counts'] == [0, 0, 0]
# Preserve the original positive-VRAM rejection and qualify only zero-VRAM scope.
assert not original['accepted'] and not original['VM']
from check import check
checked = check(guest, (D/'main.bin').read_bytes())
checked.update(core_source=meta['source'], model_SHA256=require_sha, profile=meta['profile'])
(D/'comparison.json').write_text(json.dumps(checked, indent=2)+'\n')
record.update(scoped_function_context_PASS=True, original_guard_accepted=False,
              zero_VRAM_scope='forced blank, zero reads/mismatches required; no VRAM coverage',
              raw_dump_SHA256=sha((D/'main.bin').read_bytes()), log_SHA256=sha((D/'run.log').read_bytes()),
              all_paired_slopes_exact=checked['all_paired_slopes_exact'])
save()
print('NATIVE60_NEW_GUEST_PASS function/context; timing equality', record['all_paired_slopes_exact'], flush=True)
