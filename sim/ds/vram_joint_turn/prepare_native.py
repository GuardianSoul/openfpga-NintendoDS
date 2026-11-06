#!/usr/bin/env python3
"""Freeze native60 production, host observer and four existing guest invocations."""
from pathlib import Path
import argparse
import ast
import hashlib
import io
import json
import shutil
import subprocess
import tarfile

R = Path(__file__).resolve().parents[3]
SOURCE = 'aeaa0cb386d2fbd6f8d2505f8033015956da54b5'
HOST = 'e1337f1f711d9543272fefe333a60b68f3c059ed'
OLD = Path('/home/user/Git/NDS_Pocket-codex-vram-io-side/build/vram-io-native59')
N58 = Path('/home/user/Git/NDS_Pocket-codex-native58/build/joined-native58')
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('out', type=Path)
a = p.parse_args()
G = a.out.resolve()
G.mkdir(parents=True, exist_ok=False)
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
show = lambda ref, name: subprocess.check_output(['git', 'show', ref + ':' + name], cwd=R)

def save(name, value):
    path = G / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')

paths = ['rtl','sim','tools','sw','scripts','fit','.gitignore','.gitmodules','AGENTS.md','LICENSE','Makefile','README.md']
archive = subprocess.check_output(['git', 'archive', SOURCE, *paths], cwd=R)
with tarfile.open(fileobj=io.BytesIO(archive)) as t:
    for item in t:
        if not item.isfile():
            continue
        path = G / 'source' / item.name
        assert path.resolve().is_relative_to(G / 'source')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(t.extractfile(item).read())
for name in ['build/boot/bootrom.hex','build/ds41/witness.svh']:
    path = G / 'source' / name
    path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(OLD / 'source' / name, path)
files = {str(f.relative_to(G / 'source')): sha(f) for f in (G / 'source').rglob('*') if f.is_file()}
save('source-manifest.json', dict(source=SOURCE, files=files, generated_support='Two exact native59 boot/witness files; no old1190 invariant'))
old = json.loads((OLD / 'source-manifest.json').read_text())
rtl = {n: h for n, h in files.items() if n.startswith('rtl/')}
delta = {n: dict(before=old['files'].get(n), after=rtl.get(n)) for n in sorted(set(rtl) | {n for n in old['files'] if n.startswith('rtl/')}) if old['files'].get(n) != rtl.get(n)}
save('production-delta-from59.json', dict(before=old['source'], after=SOURCE, RTL=delta, scope='Qualified main40 area/CPU/sound/ROM changes plus public CUT0; native timing not previously measured'))
joint = R / 'build/vram-joint-c445-v1/before/model.json'
inputs = json.loads(joint.read_text())['inputs']
guard = {}
for name, h in inputs.items():
    if '/rtl/' not in name:
        continue
    name = 'rtl/' + name.split('/rtl/', 1)[1]
    assert files[name] == h, name
    guard[name] = h
save('joint-source-guard.json', dict(component='c445c240e4138f347ea256d98f9f20e3eca68e50', production=SOURCE, identical_compiled_RTL=guard))
for sub in ['host-overlay','host-sound51','ds30']:
    shutil.copytree(OLD / sub, G / sub)
for name in ['sim/pocket_ds/dma_service_observer.svh','sim/pocket_ds/ds30_observer.svh','sim/pocket_ds/ds30_tables.svh','sim/pocket_ds/runtime_import_sound_owned.svh','sim/pocket_ds/runtime_import_sound_parent.svh','sim/sound/full_v2/sound_v2_roi.svh','sim/sound/runtime_import_sound_parent_banks.svh']:
    if (G / 'source' / name).exists():
        continue
    target=G / 'host-overlay' / name
    target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(OLD / 'source' / name,target)
for name in ['donor-build-command.json','donor-tb_native52.sv','control-check.json','native_guard.py']:
    shutil.copy2(OLD / name, G / name)
for name in ['manifest.json','check.log','source-manifest.json','build-inputs.json','model.json','unita7-result.json']:
    shutil.copy2(OLD / name, G / ('native59-' + name))
profile = json.loads((OLD / 'profile.json').read_text())
profile['VRAM_CUT_WRITE_TURN'] = 1
assert len(profile) == 60
save('profile.json', profile)
hook = json.loads((G / 'ds30/hook-manifest.json').read_text())
hook['source'] = SOURCE
save('ds30/hook-manifest.json', hook)
host = G / 'host-observer/sim/pocket_ds/ldm53_observer.sv'
host.parent.mkdir(parents=True, exist_ok=True)
host.write_bytes(show(HOST, 'sim/pocket_ds/ldm53_observer.sv'))
assert sha(host) == '49355f602164b535a9ab4bedfcf20df14c64aaf8b2cd5b9ae8eedf213f7b6391'
assert "bytes(n)-4+(n%7==6?8:0)" in host.read_text()
for name in ['tools/scorecard/ldm53_observer_plan.json','tools/scorecard/ldm53_roi_first_timed.hex','docs/results/ldm53-observer-source-20261102/source-ready.json']:
    path = G / 'host-inputs' / Path(name).name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(show(HOST, name))
plan = json.loads((G / 'host-inputs/ldm53_observer_plan.json').read_text())
mask = G / 'host-inputs/ldm53_roi_first_timed.hex'
assert sha(mask) == plan['ROI_candidate_sha256'] == 'cca3cfd655beebbe1132e4c990bdc51b44cfabff651f31a03cb945e98013b9e9'
assert len(mask.read_text().split()) == 742 and sum(int(x,16) for x in mask.read_text().split()) == 106
guards = {}
for name, spec in plan['source_blocks'].items():
    text = (G / 'source' / name.split(':')[0]).read_text()
    begin = text.index(spec['start_marker'])
    end = text.index(spec['end_marker_exclusive'], begin + len(spec['start_marker']))
    h = hashlib.sha256(text[begin:end].encode()).hexdigest()
    assert h == spec['fragment_sha256'], name
    guards[name] = h
save('host-inputs/actual-source-guard.json', dict(production=SOURCE, observer_ref=HOST, observer_sha256=sha(host), nine_source_guards=guards, ROI_sha256=sha(mask), detail_calls=106, detail_body_words=358400, all_summaries=742, binding='NOT YET ELABORATED/RUN', receipt_note='Finalf2ebaebd includes58d453 return fix and checker; actual corrected-source pin matches refreshed receipt'))
observer_root = G / 'host-observer'
for name in ['tools/scorecard/ldm53_observer.py', 'tools/scorecard/ldm53_observer_selftest.py', 'tools/scorecard/ldm53_observer_plan.json', 'tools/scorecard/ldm53_roi_first_timed.hex']:
    path = observer_root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(show(HOST, name))
for name in ['rtl/arm/arm_cpu.sv','rtl/arm/arm_core.sv','rtl/arm/arm9_mem.sv','rtl/ds/nds_fabric.sv','rtl/pocket/core_top_ds.sv']:
    path = observer_root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(G / 'source' / name, path)
    assert sha(path) == files[name]
subprocess.run(['python3', observer_root / 'tools/scorecard/ldm53_observer.py','source-check','--root',observer_root,'--out',G / 'host-inputs/source-check.json'],check=True)
receipt=json.loads((G / 'host-inputs/source-ready.json').read_text())
assert receipt['observer_sha256']==sha(host)
assert receipt['verifier_sha256']==sha(observer_root / 'tools/scorecard/ldm53_observer.py')
assert receipt['plan_sha256']==sha(observer_root / 'tools/scorecard/ldm53_observer_plan.json')

tb = G / 'host-overlay/tb_native52.sv'
text = tb.read_text().replace('VRAM_IO59_PUBLIC_ROUTE_PASS exact2f+00ef/profile59', 'VRAM_IO59_PUBLIC_ROUTE_PASS retained IO binding; native60 source/profile separate')
needle = '    initial begin\n        #1;'
assert needle in text
marker = '''    initial begin : native60_binding
        string destination;
        bit wants_ldm;
        wants_ldm=$value$plusargs("ldm53_observe=%s",destination);
        #1;
        if(dut.VRAM_CUT_WRITE_TURN!=1 || dut.x_vram.CUT_WRITE_TURN!=1 || dut.x_vram.CUT_TAG!=1 || dut.x_vram.QW!=8 || dut.x_vram.SHARED!=1)
            $fatal(1,"NATIVE60_WRITE_TURN_ROUTE_FAIL");
        if(u_ldm53_observer.enabled!==wants_ldm)$fatal(1,"NATIVE60_LDM53_BIND_FAIL");
        $display("NATIVE60_WRITE_TURN_ROUTE_PASS sourceaeaa/profile60");
        if(wants_ldm)$display("NATIVE60_LDM53_ACTIVE_PASS COPY01ff8020 ANCHOR01ffb1d4");
        else $display("NATIVE60_LDM53_INACTIVE_PASS");
    end
'''
text = text.replace(needle, marker + needle, 1)
tb.write_text(text)
build = json.loads((OLD / 'build-inputs.json').read_text())['argv']
command = [x.replace(str(OLD), str(G)) for x in build]
indices = [i for i,x in enumerate(command) if x.startswith('+define+TB_CORE_PARAMS=')]
assert len(indices) == 1
command[indices[0]] += ', .VRAM_CUT_WRITE_TURN(1)'
new_rom = str(G / 'source/rtl/gpu3d/gpu3d_gxrom_adict.sv')
assert new_rom not in command
command += [new_rom, str(host)]
# Derive current build-list requirements from the pinned run.py, including +=.
module = ast.parse((G / 'source/sim/pocket_ds/run.py').read_text())
current = []
for node in module.body:
    if isinstance(node, ast.Assign) and any(isinstance(x,ast.Name) and x.id=='RTL' for x in node.targets):
        current = ast.literal_eval(node.value)
    if isinstance(node, ast.AugAssign) and isinstance(node.target,ast.Name) and node.target.id=='RTL':
        current += ast.literal_eval(node.value)
for name in current:
    assert str(G / 'source/rtl' / name) in command, name
save('build-command.json', dict(source=SOURCE, profile=profile, argv=command, host_observer_ref=HOST,
    explicit_new_main40_source='rtl/gpu3d/gpu3d_gxrom_adict.sv', host_sha256={str(f.relative_to(G)):sha(f) for sub in ['host-overlay','host-sound51','host-inputs','host-observer'] for f in (G / sub).rglob('*') if f.is_file()}))
commands = {}
for name in ['ds30','unita7','unitmem','ldm53-live']:
    directory = G / 'runs' / name
    directory.mkdir(parents=True)
    if name == 'ds30':
        shutil.copytree(OLD / 'run', directory / 'run')
        rom = G / 'ds30/arm7-ds30.nds'
        oldrun = str(OLD / 'run')
        template = json.loads((OLD / 'manifest.json').read_text())
        argv = [str(G / 'model/Vtb_ds_pocket')] + [x.replace(str(OLD / 'ds30-capture'),str(directory / 'ds30-capture')).replace(str(OLD / 'ds30'),str(G / 'ds30')).replace(oldrun,str(directory / 'run')).replace('+vramcause='+str(OLD / 'vram'),'+vramcause='+str(directory / 'vram')) for x in template['argv'][1:]]
    else:
        shutil.copytree(OLD / 'run', directory / 'run')
        rom = G / 'guest-inputs' / (name + '.nds')
        rom.parent.mkdir(exist_ok=True)
        donor = N58 / ('test-roms/' + name + '.nds')
        shutil.copy2(donor, rom)
        if name == 'ldm53-live':
            assert sha(rom) == plan['ROM_sha256']
            template = json.loads(Path('/home/user/Git/NDS_Pocket/build/coordinator/ldm40-independent-replay/results/ldm53-live/model.json').read_text())
            oldrun = '/home/user/Git/NDS_Pocket-codex-ldm-joined40/build/ldm-native40/results/ldm53-live/run'
            argv = [str(G / 'model/Vtb_ds_pocket')] + [x.replace(oldrun,str(directory / 'run')).replace('/home/user/Git/NDS_Pocket-codex-ldm-joined40/build/ldm-native40/results/ldm53-live/main.bin',str(directory / 'main.bin')) for x in template['argv'][1:]]
            argv += ['+ldm53_observe='+str(directory / 'ldm53.csv'), '+ldm53_roi='+str(mask)]
        else:
            template = json.loads((N58 / 'results' / name / 'model.json').read_text())
            oldrun = str(N58 / 'results' / name / 'run')
            argv = [str(G / 'model/Vtb_ds_pocket')] + [x.replace(oldrun,str(directory / 'run')).replace('+iocause='+str(N58 / 'results' / name / 'iocause'),'+iocause='+str(directory / 'iocause')) for x in template['argv'][1:]]
        b = rom.read_bytes()
        b += bytes(-len(b)%4)
        (directory / 'run/rom.hex').write_text(''.join(f'{int.from_bytes(b[i:i+4],"little"):08x}\n' for i in range(0,len(b),4)))
    save('donor-commands/'+name+'.json', template)
    commands[name] = dict(argv=argv,cwd=str(directory / 'run'),ROM_sha256=sha(rom),expanded_sha256={f.name:sha(f) for f in (directory / 'run').iterdir() if f.is_file()},scope='53 form actor distinct from unitmem; checker pending' if name=='ldm53-live' else 'actual changed-source existing guest; no baseline rerun')
    if name in ['unita7','unitmem']:
        expected = json.loads((N58 / 'results' / name / 'manifest.json').read_text())
        assert sha(rom) == expected['rom_sha256']
        for n,h in expected['expanded_inputs_sha256'].items():
            assert commands[name]['expanded_sha256'][n] == h,(name,n)
save('run-commands.json', commands)
save('plan.json', dict(production=SOURCE,host_observer=HOST,profile=profile,model_build_authorized_after_source_guards=True,
    runtime_gate='Separate run-release only after exact53/body/ROI/checker binding is delivered and recorded',
    runs=list(commands),old_baseline='native59 only; main40 areas equivalence qualified, native timing not measured',
    targets='DS30 stores310/342 vs306; canonical349; retain DS30read406/406, affectedtypedDMA and53form actual ownership',
    actor53=plan,source_files=len(files),RTL_files=len(rtl),changed_RTL_from59=len(delta)))
print(json.dumps(dict(source=SOURCE,files=len(files),RTL=len(rtl),RTL_delta=len(delta),profile=len(profile),observer_sha256=sha(host),guards=len(guards),runs=list(commands)),indent=2))
