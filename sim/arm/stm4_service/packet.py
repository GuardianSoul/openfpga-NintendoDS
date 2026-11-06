#!/usr/bin/env python3
"""Stage deduplicated immutable evidence; finish one component+native61 packet."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

R=Path(__file__).resolve().parents[3]
COMPONENTS=['stm4-service-7aa-v1','stm4-service-7aa-v2','stm4-service-7aa-v3','stm4-service-7aa-v4',
 'stm4-service-candidate-v1','stm4-service-candidate-v3','stm4-service-turn-fault-v1',
 'stm4-service-fallback-v1','stm4-service-fallback-v2','stm4-service-cpu-reset-v1',
 'stm4-service-cpu-reset-v2','stm4-service-cpu-reset-v3','stm4-service-cpu-reset-v4','stm4-group-observer-v1']


def digest(p):
    with p.open('rb')as f:return hashlib.file_digest(f,'sha256').hexdigest()


def selected(relative):
    parts=relative.parts
    if '__pycache__'in parts or 'tmp'in parts:return False
    if parts[0]=='runs'and'run'in parts[2:]:return False
    if 'obj'in parts or parts[0]=='model':
        return relative.name in {'Vtb_main','Vtb_fallback','Vtb_ds_pocket','Vtb_group_observer'}
    return True


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('staging',type=Path)
    p.add_argument('--native',type=Path)
    p.add_argument('--destination',type=Path)
    a=p.parse_args();S=a.staging.resolve();(S/'objects').mkdir(parents=True,exist_ok=True)
    inventory={};prefixes={}
    def collect(label,root):
        assert root.is_dir(),root
        prefixes[str(root.resolve())]=label
        for f in sorted(root.rglob('*')):
            if not f.is_file():continue
            rel=f.relative_to(root)
            if not selected(rel):continue
            old=f.stat();h=digest(f);new=f.stat()
            assert(old.st_size,old.st_mtime_ns)==(new.st_size,new.st_mtime_ns),f
            target=S/'objects'/h
            if target.exists()and digest(target)!=h:
                # Earlier provisional staging linked a mutable driver.
                # Restore from this exact frozen source without writing
                # through a link into any original input.
                target.unlink()
            if not target.exists():
                shutil.copyfile(f,target)
            elif target.stat().st_nlink>1:
                temp=target.with_suffix('.copytmp');shutil.copyfile(target,temp);os.replace(temp,target)
            assert target.stat().st_size==old.st_size
            inventory[label+'/'+str(rel)]=dict(sha256=h,bytes=old.st_size)
    for name in COMPONENTS:collect('component/'+name,R/'build'/name)
    # The actual failed/superseded preparation receipts are retained without
    # copying expanded private BIOS/firmware or compiler scratch.
    for name in ['stm4-native61-v1','stm4-native61-v2','stm4-native61-v3','stm4-native61-v4']:
        collect('preparation/'+name,R/'build'/name)
    collect('drivers',R/'sim/arm/stm4_service')
    if (S/'retention').is_dir():collect('retention',S/'retention')
    metadata=dict(schema=1,paths=inventory,original_prefixes=prefixes,stage='COMPONENT_READY_NATIVE_PENDING',
                  scope='Raw evidence and exact model/source bindings, including rejected setup-only fault controls; no blanket DS/global/area acceptance')
    if a.native:
        N=a.native.resolve();assert(N/'complete.json').exists()and(N/'public-fault.json').exists()
        collect('native61',N)
        B=Path('/home/user/Git/NDS_Pocket-codex-vram-joint-turn/build/vram-native60')
        controls=S/'reference60';controls.mkdir(exist_ok=True)
        for n in ['source-manifest.json','profile.json','model.json','native-complete.json','runtime-results.json']:
            shutil.copy2(B/n,controls/n)
        for name in ['ds30','unita7','unitmem']:
            for n in ['result.json','manifest.json','run.process.json']:
                f=controls/'runs'/name/n;f.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(B/'runs'/name/n,f)
        collect('native60-control',controls)
        metadata.update(stage='COMPLETE_COMPONENT_AND_NATIVE',native_source=json.loads((N/'source-manifest.json').read_text())['source'],
                        model_sha256=json.loads((N/'model.json').read_text())['sha256'])
    metadata['paths']=inventory;metadata['original_prefixes']=prefixes
    (S/'packet-manifest.json').write_text(json.dumps(metadata,indent=2,sort_keys=True)+'\n')
    if not a.destination:
        print(json.dumps(dict(stage=metadata['stage'],paths=len(inventory),objects=len({r['sha256']for r in inventory.values()}))))
        return
    assert a.native and metadata['stage']=='COMPLETE_COMPONENT_AND_NATIVE'
    D=a.destination.resolve();D.mkdir(parents=True,exist_ok=False)
    archive=D/'evidence.tar.xz'
    hashes=sorted({r['sha256']for r in inventory.values()})
    with tarfile.open(archive,'w:xz',preset=3)as tar:
        b=(S/'packet-manifest.json').read_bytes();info=tarfile.TarInfo('packet-manifest.json');info.size=len(b);tar.addfile(info,io.BytesIO(b))
        for h in hashes:
            f=S/'objects'/h;assert digest(f)==h;tar.add(f,arcname='objects/'+h,recursive=False)
    qualification=dict(source=metadata['native_source'],model_sha256=metadata['model_sha256'],archive=dict(sha256=digest(archive),bytes=archive.stat().st_size,members=len(hashes)+1),paths=len(inventory),
                       scope=metadata['scope'],native_guests=['ds30','unita7','unitmem'],original53='Not rerun: native60 reference and nine exact producer guards retained; no current53 acceptance claimed')
    (D/'qualification.json').write_text(json.dumps(qualification,indent=2)+'\n')
    shutil.copy2(R/'sim/arm/stm4_service/check_packet.py',D/'check.py')
    with(D/'replay.json').open('w')as out:subprocess.run([sys.executable,D/'check.py',archive],stdout=out,check=True)
    replay=json.loads((D/'replay.json').read_text())
    qualification['enabled_integration']=replay['enabled_integration']
    (D/'qualification.json').write_text(json.dumps(qualification,indent=2)+'\n')
    native_source=json.loads((N/'source-manifest.json').read_text())
    bindings=dict(source=native_source['source'],model_sha256=metadata['model_sha256'],profile=json.loads((N/'profile.json').read_text()),
                  source_files=len(native_source['files']),RTL_files=sum(n.startswith('rtl/')and n.endswith('.sv')for n in native_source['files']),
                  component_composition='All16 compiled source/support files exact;14RTL+2simulation files',
                  native60_control=dict(source=json.loads((controls/'source-manifest.json').read_text())['source'],model=json.loads((controls/'model.json').read_text())['sha256']),
                  guests={name:{k:json.loads((N/'runs'/name/'manifest.json').read_text())[k]for k in ['ROM_sha256','expanded_sha256']}for name in ['ds30','unita7','unitmem']})
    (D/'inputs.json').write_text(json.dumps(bindings,indent=2)+'\n')
    shutil.copy2(N/'source-delta-from60.json',D/'source-delta-from60.json')
    (D/'DS30-comparison.json').write_text(json.dumps(replay['native_DS30'],indent=2)+'\n')
    (D/'canonical-comparison.json').write_text(json.dumps(replay['native_canonical_comparison'],indent=2)+'\n')
    lines=['# Native61 timing observations','',
           'All values are published hundredths of the named cycle. Equality at that precision does not qualify other contexts. Sentinels carry no DS timing target.','',
           '## Original DS30','',
           '| Kernel | Argument | Native60 | Native61 | DS | Core / DS |',
           '| --- | ---: | ---: | ---: | ---: | ---: |']
    for row in replay['native_DS30']:
        lines.append('| {kernel} | {arg} | {native60} | {native61} | {DS_x100} | {ratio:.4f}× |'.format(**row,ratio=row['native61']/row['DS_x100']))
    for name,rows in replay['native_canonical_comparison'].items():
        lines+=['','## Canonical '+name,'',
                '| Row | Kernel | Unit | Native60 | Native61 | DS | Core / DS |',
                '| ---: | --- | --- | ---: | ---: | ---: | ---: |']
        for row in rows:
            target=row['DS_x100'];ratio=f"{row['native61']/target:.4f}×"if target else'—'
            lines.append('| {index} | {key} | {unit} | {native60} | {native61} | {target} | {ratio} |'.format(**{**row,'unit':row['unit']or'—'},target=target if target is not None else'—',ratio=ratio))
    lines+=['','Canonical target source is the archived production `tools/scorecard/scorecard.py`: DS run30 for ARM7 and run35 for memory. The run35 32-bit MAIN→I/O target is206, from its raw slope; the older207 belongs to a separate16-bit row. Canonical ARM7 helper contention differs from original DS30. No blanket margin is used.','']
    (D/'timings.md').write_text('\n'.join(lines))
    print(json.dumps(qualification,indent=2))


if __name__=='__main__':main()
