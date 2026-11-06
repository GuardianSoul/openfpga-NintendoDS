#!/usr/bin/env python3
"""Freeze the clean native mode separately from the original SOUND import."""
from pathlib import Path
import ast,hashlib,json,shutil
ROOT=Path(__file__).resolve().parents[3];J=ROOT/'build/a7-native42';T=J/'thumb';C=T/'source'
assert not C.exists();S=J/'sound';N=Path('/home/user/Git/NDS_Pocket/build/join-27340ba4-if4')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
shutil.copytree(S/'prepared/core',C,ignore=shutil.ignore_patterns('build','obj','obj_dir','__pycache__'))
shutil.copytree(S/'runtime',T/'runtime');shutil.copytree(S/'prepared/core/build/boot',C/'build/boot')
# The normal canonical driver has no SOUND packet requirement. All39 source
# parameters and the inherited physical guards remain identical.
s=(N/'source/rnd/pocket_cpu.py').read_text().replace("mod.CACHE = ROOT.parent / ('model-cache-' + socket.gethostname())","mod.CACHE = Path('/tmp/nds-a7-native39-clean-cache')")
(C/'rnd/pocket_cpu.py').write_text(s)
(T/'test-roms').mkdir();shutil.copyfile(T/'a7thumb42.nds',T/'test-roms/a7thumb42.nds')
profile=json.loads((J/'profile.json').read_text());inputs=json.loads((N/'inputs.json').read_text())
inputs.update(source=profile['source'],profile=profile['profile'],references={},rom_sha256={'a7thumb42.nds':sha(T/'a7thumb42.nds')},runtime_root=str(T/'runtime'),scope='Exact DS42 captured Thumb9 kernels/context;90 samples/630 signatures and full scratch/code/helper; clean native39, no CPU39 repeat')
(T/'inputs.json').write_text(json.dumps(inputs,indent=2)+'\n')
files={str(p.relative_to(C)):sha(p)for p in C.rglob('*')if p.is_file()}
(T/'source-manifest.json').write_text(json.dumps(dict(source=profile['source'],files=files,scope='All RTL exact merged f9; qualified canonical physical harness plus inactive SOUND ROI/passive declarations'),indent=2)+'\n')
(T/'host-instrumentation.json').write_text(json.dumps(dict(files=[],additional_inputs={}),indent=2)+'\n')
for name in ['native_guard.py','sim_ownership.py']:shutil.copyfile(N/name,T/name)
s=(N/'run-chain.py').read_text();a=s.index('cases=');b=s.index('\nstatus=',a);s=s[:a]+"cases=[('arm7thumb42','a7thumb42.nds',240,None,1)]"+s[b:]
s=s.replace("len(INPUT['profile'])==37","len(INPUT['profile'])==39")
s=s.replace("status['cpu39_groups']=36;status['cpu39_samples']=360","status['cpu39_groups']=0;status['cpu39_samples']=0")
s=s.replace("        if name=='a7fetch39':cmd+=", "        if name=='arm7thumb42':cmd+=['--plus','dump_pc='+json.loads((BASE/'build.json').read_text())['dump_pc'][2:],'--plus',f'dump_file={out/\"main.bin\"}']\n        if name=='a7fetch39':cmd+=")
ast.parse(s);(T/'run-chain.py').write_text(s)
shutil.copyfile(Path(__file__),T/'prepare-native.py')
print('FROZEN clean DS42 native9; source',profile['source'],'profile39')
