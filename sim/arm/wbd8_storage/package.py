#!/usr/bin/env python3
"""Seal already-finished owned runs. No model, simulation, compiler or fit call."""
from pathlib import Path
import hashlib,io,json,os,subprocess,tarfile
R=Path(__file__).resolve().parents[3];B=R/'build/wbd8-storage';Q=R/'docs/results/wbd8-storage-20261102';os.setpriority(os.PRIO_PROCESS,0,10)
sha=lambda b:hashlib.sha256(b).hexdigest();files={};omitted=[]
for run in ['leaf-v1','leaf-v2','leaf-v3','leaf-v4','cpu-v1','pin-v1']:
 for p in(B/run).rglob('*'):
  if not p.is_file()or'__pycache__'in p.parts:continue
  rel=p.relative_to(B)
  if 'obj'in rel.parts and p.name not in ['Vtb','Vtb_arm']:continue
  if 'gates'in rel.parts and(p.suffix in ['.csv','.log']or'gold-suite'in rel.parts or ('cpu-final'in rel.parts and p.name!='tb.sv')):omitted.append(str(rel));continue
  files[str(rel)]=p
for n in ['terminal-processes.json','compiler-cleanup.json']:files[n]=B/n
for p in(R/'sim/arm/wbd8_storage').iterdir():
 if p.is_file()and p.suffix in ['.py','.sv','.s']:files['source/sim/arm/wbd8_storage/'+p.name]=p
files['source/arm9_mem.sv']=R/'rtl/arm/arm9_mem.sv';files['replay.py']=Q/'check.py'
old=subprocess.check_output(['git','show','38503938:rtl/arm/arm9_mem.sv'],cwd=R);(B/'arm9_mem-before.sv').write_bytes(old);files['source/arm9_mem-before.sv']=B/'arm9_mem-before.sv'
(B/'production.patch').write_bytes(subprocess.check_output(['git','diff','38503938','--','rtl/arm/arm9_mem.sv'],cwd=R));files['source/production.patch']=B/'production.patch'
for p in(R/'sim/arm/ncnb_store').glob('*.py'):files['source/sim/arm/ncnb_store/'+p.name]=p
assert sha((R/'rtl/arm/arm9_mem.sv').read_bytes())=='d85e153f75900eb89ec4aa7dbb64a7157b2539191117bd8043d0e640b4bf04d1'
for name,p in list(files.items()):
 if name.endswith('/model.json')and'/gates/'not in name:
  d=json.loads(p.read_text())
  for f,h in d['inputs'].items():
   n=f.split('/build/wbd8-storage/',1)[1];assert n in files and sha(files[n].read_bytes())==h,(name,f)
  folder=name.rsplit('/',1)[0];binary=folder+'/obj/'+('Vtb'if folder.startswith('leaf-')else'Vtb_arm');assert sha(files[binary].read_bytes())==d['sha256']
receipt=dict(source_before='385039386d7d5d5a97f7c4ed4e6aaf96e6a553bf',candidate_production_commit='cd65cdcb',candidate_production_SHA256=sha((R/'rtl/arm/arm9_mem.sv').read_bytes()),unchanged_candidate_since_first_build=True,omitted_frozen_gold_and_unused_model_inputs=omitted,omission_scope='Frozen prior packet restored and hashchecked; these old gold traces/logs and unused previous model sources were not consumed as the new before model oracle. All newly executed paired logs/states/cycles/models/inputs and compiled source are included.',scope='3leaf configurations/validtailmapping, actualwrongslot;4directed25DENSE26ARM realCPU;5actualfabric/SYS/pinPSRAM reset+ARM7contention cases. Not fullcurrentnative/games/fit/STA.',invalidatedClosedIDs=[])
(B/'source-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');files['source-receipt.json']=B/'source-receipt.json'
manifest={n:dict(bytes=p.stat().st_size,sha256=sha(p.read_bytes()))for n,p in sorted(files.items())};out=Q/'evidence.tar.gz';assert not out.exists(),'preserve sealed archive'
seen={}
with tarfile.open(out,'w:gz',compresslevel=6)as t:
 for n,p in sorted(files.items()):
  h=manifest[n]['sha256'];info=t.gettarinfo(str(p),arcname=n);info.uid=info.gid=0;info.uname=info.gname='';info.mtime=0
  if h in seen:info.type=tarfile.LNKTYPE;info.linkname=seen[h];info.size=0;t.addfile(info)
  else:
   seen[h]=n
   with p.open('rb')as f:t.addfile(info,f)
 raw=(json.dumps(manifest,indent=2)+'\n').encode();info=tarfile.TarInfo('manifest.json');info.size=len(raw);info.mode=0o644;t.addfile(info,io.BytesIO(raw))
qual=dict(status='Source/cycle/state/order/actualfault component qualification PASS; measuredarea/M10K/STA and finalnative qualification pending',source=receipt,capsule_uses_hardlinks_for_identical_before_after_files=True,archive=dict(file=out.name,bytes=out.stat().st_size,sha256=sha(out.read_bytes()),members=len(files)),leaf=json.loads((B/'leaf-v4/results.json').read_text()),CPU=json.loads((B/'cpu-v1/results.json').read_text()),pin=json.loads((B/'pin-v1/results.json').read_text()),workers=dict(children=156,controllers=6,all_terminal=True,lease='Laptop2 NI10/jobs1/threads1; serial, no ownQuartus'),resource_result='UNKNOWN pendingcoordinatorbatchedfit; sourcebit reduction is not a measuredALMsaving',invalidatedClosedIDs=[])
(Q/'qualification.json').write_text(json.dumps(qual,indent=2)+'\n');print('SEALED',out.stat().st_size,len(files),qual['archive']['sha256'])
