#!/usr/bin/env python3
"""Package the rejected native gate, retaining exact sources/models/raw witnesses."""
from pathlib import Path
import argparse,gzip,hashlib,io,json,os,tarfile
R=Path(__file__).resolve().parents[3]
H=lambda b:hashlib.sha256(b).hexdigest()
p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args();D=a.directory.resolve();O=a.output.resolve();O.mkdir(parents=True,exist_ok=True);os.setpriority(os.PRIO_PROCESS,0,10)
files={}
def add(name,f):
 if '__pycache__'in f.parts or f.suffix in ['.pyc','.tmp']:return
 assert name not in files,name;files[name]=f.read_bytes()
for f in sorted(D.iterdir()):
 if f.is_file():add(f.name,f)
for folder in ['common','amendment','source-audit']:
 for f in sorted((D/folder).rglob('*')):
  if f.is_file()and not(folder=='common'and f.relative_to(D).parts[1]=='runtime'):add(str(f.relative_to(D)),f)
for mode in ['before','ACK1']:
 V=D/mode
 for f in sorted(V.rglob('*')):
  if not f.is_file():continue
  rel=f.relative_to(V);parts=rel.parts
  if parts[0]=='model'and f.name!='Vtb_ds_pocket':continue
  if parts[0]=='runs'and len(parts)>2 and parts[2]=='run':continue
  add(str(f.relative_to(D)),f)
# ACK0's actual model/runs were omitted; include its immutable profile receipt.
add('ACK0/source-profile.json',D/'ACK0/source-profile.json')
prior=D.parent/'cpu-ldm4-native-reference-v2'
for rel in ['results.json','observer-binding-failure.json','before/build.log','before/host-overlay/ldm4_observe.svh','before/runs/unita7/run.log','before/model/Vtb_ds_pocket']:
 add('attempts/observer-v2/'+rel,prior/rel)
for f in sorted((R/'sim/arm/ldm4_native').rglob('*')):
 if f.is_file():add('proof-tools/'+str(f.relative_to(R/'sim/arm/ldm4_native')),f)
plan=json.loads((D/'plan.json').read_text())
private={rel:h for rel,h in plan['input_SHA256'].items()if rel.startswith('runtime/')}
for mode in ['before','ACK1']:
 for guest in plan['guests']:
  m=json.loads((D/mode/'runs'/guest/'manifest.json').read_text())
  private.update({f'{mode}/runs/{guest}/run/{n}':h for n,h in m['expanded_sha256'].items()})
manifest={'status':'GLOBAL ACK1 ENABLE REJECT; default0 only','files':{n:H(b)for n,b in sorted(files.items())},'omitted_private_expanded_runtime_SHA256':private,'omitted_generated_python_cache_SHA256':{rel:h for rel,h in plan['input_SHA256'].items()if '__pycache__'in Path(rel).parts},'private_scope':'Expanded BIOS/firmware/boot/ROM hex runtime files were checked live before/after; raw private runtime omitted. Homegrown original NDS inputs are included separately. No offline byte-validation claim for omitted files.'}
files['manifest.json']=(json.dumps(manifest,sort_keys=True,indent=2)+'\n').encode();packet=O/'evidence.tar.gz'
with packet.open('wb')as raw,gzip.GzipFile(filename='',mode='wb',fileobj=raw,mtime=0,compresslevel=6)as gz,tarfile.open(fileobj=gz,mode='w')as t:
 for n,b in sorted(files.items()):
  info=tarfile.TarInfo(n);info.mode=0o644;info.size=len(b);t.addfile(info,io.BytesIO(b))
rec={'before':'9fca32ff12a457599c4bdbf182b84e364381756a','after':'4452b3368ed3f971f8e4dcd2d17a0769dac61031','packet_SHA256':H(packet.read_bytes()),'hashed_members':len(manifest['files']),'expanded_bytes':sum(map(len,files.values())),'packet_bytes':packet.stat().st_size,'enabled_promotion':'REJECT quiettiming; full-state equality not claimed'};(O/'capsule.json').write_text(json.dumps(rec,indent=2)+'\n');print(json.dumps(rec))
