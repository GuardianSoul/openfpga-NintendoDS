#!/usr/bin/env python3
"""Offline linked/input/completion replay; never executes a DS emulator."""
from pathlib import Path,PurePosixPath
import argparse,hashlib,importlib.util,io,json,struct,tarfile,tempfile
p=argparse.ArgumentParser(description=__doc__);p.add_argument('packet',type=Path);a=p.parse_args();D=a.packet.resolve();Q=json.loads((D/'qualification.json').read_text());sha=lambda b:hashlib.sha256(b).hexdigest()
def unpack(b):
 with tarfile.open(fileobj=io.BytesIO(b))as t:return{m.name:t.extractfile(m).read()for m in t if m.isfile()}
b=(D/Q['archive']['file']).read_bytes();assert sha(b)==Q['archive']['sha256']and len(b)==Q['archive']['bytes'];F=unpack(b);assert set(F)==set(Q['archive']['files'])
for name,v in Q['archive']['files'].items():assert len(F[name])==v['bytes']and sha(F[name])==v['sha256'],name
dep=Q['prior_helper_dependency'];b=(D.parent/dep['directory']/dep['file']).read_bytes();assert sha(b)==dep['SHA256'];prior=json.loads(unpack(b)['layout.json'])
js=lambda n:json.loads(F[n]);layout=js('layout.json');q=js('results.json');assert layout['helper']==prior['helper']
with tempfile.TemporaryDirectory(prefix='mulmix-sdk-replay-')as tmp:
 T=Path(tmp)
 for name,b in F.items():
  path=PurePosixPath(name);assert not path.is_absolute()and'..'not in path.parts;target=T/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(b)
 spec=importlib.util.spec_from_file_location('mix_replay_checker',T/'source/sw/hwref/a7mulmix/check.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
 assert c.sdk(T/'sdk/a7mulmix7.elf',T/'sdk/a7mulmix.elf',T/'sdk/build-id.h')==layout
 producer=T/'source/sw/hwref/a7mulmix';inputs='protocol.h arm7.c kernel.S main.c quiet.itcm.c Makefile ../common/hwref.c ../common/hwref.h ../Makefile ../wramarb/linker.py'.split()
 assert sha(b''.join((producer/n).read_bytes()for n in inputs))==layout['build_id']
 assert sha(F['sdk/a7mulmix.nds'])==q['ROM_SHA256']==Q['ROM_SHA256']
 for n,h in q['producer_SHA256'].items():assert sha((producer/n).read_bytes())==h,n
 audit=js('linked-audit.json');assert audit['PASS']and audit['helper_exact_previous']and audit['arm7_ELF_SHA256']==layout['arm7_elf_SHA256']and audit['arm9_ELF_SHA256']==layout['arm9_elf_SHA256']
 assert len(audit['actual_byte_faults_caught'])==2 and audit['stack_frame_bytes']==344
 # Recheck actual linked argument/veneer bytes independently of saved PASS.
 fn=c.elf.elf_symbol(T/'sdk/a7mulmix7.elf','measure');body=fn['body'];base=fn['address']&~1;assert sha(body)==audit['measure_SHA256']
 assert struct.unpack_from('<6H',body,0x15a)==(0x9b04,0x2101,0x9300,0x9a03,0xab0c,0x9805)
 assert struct.unpack_from('<7H',body,0x18a)==(0x9b04,0x4659,0x9300,0x9a03,0x003b,0x9805,0x9509)
 veneer=c.elf.elf_symbol(T/'sdk/a7mulmix7.elf','__mm_invoke_from_thumb');assert sha(veneer['body'])==audit['veneer_SHA256']
 for off,row in zip([0x166,0x198],audit['paired_calls']):
  hi,lo=struct.unpack_from('<HH',body,off);high=hi&0x7ff;high=high-0x800 if high&0x400 else high;target=base+off+4+(high<<12)+((lo&0x7ff)<<1)
  assert row==dict(pc=base+off,target=target)and target==veneer['address']&~1
 expected={
  'normal':dict(status='SUCCESS',complete='6',new='6',resumed='0',failed='0',interrupted='0'),
  'resume':dict(status='SUCCESS',complete='6',new='0',resumed='6',failed='0',interrupted='0'),
  'interrupted':dict(status='INCOMPLETE',complete='5',new='5',resumed='0',failed='0',interrupted='1'),
  'damaged-DONE':dict(status='INCOMPLETE',complete='5',new='0',resumed='5',failed='1',interrupted='0'),
  'refusal':None,
  'real-ROM-opcode-mutant':dict(status='INCOMPLETE',complete='0',new='0',resumed='0',failed='6',interrupted='0')}
 assert set(q['cases'])==set(expected)
 for name,comp in expected.items():
  target=T/'cases'/name/'outputs';row=q['cases'][name];assert row['completion']==comp
  for filename,h in row['output_SHA256'].items():assert sha((target/filename).read_bytes())==h,(name,filename)
  if comp is not None:
   actual=dict(x.split('=',1)for x in(target/'a7mulmix_v1_completion.txt').read_text().splitlines());assert actual==comp
  summary=js(f'cases/{name}/summary.json');assert summary['census_mode']=='ds-rules-23'and summary['declared_rule_count']==summary['compiled_rule_count']==23
  if name in ['normal','resume']:
   checked=c.analyze(target,layout);assert(checked['groups'],checked['raw_times'],checked['register_words'])==(6,60,3840)
   if name=='normal':assert checked==js('normal-check.json')
  else:
   try:c.analyze(target,layout)
   except(ValueError,FileNotFoundError):pass
   else:raise AssertionError(name+' accepted')
  if name in ['resume','damaged-DONE','refusal']:
   for filename,h in row['seed_SHA256'].items():
    if filename!='a7mulmix_v1_completion.txt':assert row['output_SHA256'][filename]==h
 for name,why in [('last-CSV-sample-missing','60 ordered complete raw samples required'),('coherent-real-R6-fault','second multiplier r6 differs')]:
  try:c.analyze(T/'faults'/name,layout)
  except ValueError as e:assert str(e)==why
  else:raise AssertionError(name+' accepted')
 # Exactly one actual ARM7 ROM opcode is changed; all120 captured call
 # register results still pass, while live code and device completion fail.
 good=F['sdk/a7mulmix.nds'];bad=F['first-MUL-NOP.nds'];off=q['real_ROM_opcode_fault']['offset'];assert bad==good[:off]+struct.pack('<I',0xe1a00000)+good[off+4:]
 assert struct.unpack_from('<I',good,off)[0]==0xe0030291 and sha(bad)==q['cases']['real-ROM-opcode-mutant']['ROM_SHA256']
 faults=T/'cases/real-ROM-opcode-mutant/outputs'
 for path in faults.glob('a7mulmix_v1_k*.bin'):
  raw=path.read_bytes();i,region=struct.unpack_from('<II',raw,8);rs2,rs6=c.PAIRS[i];entry=layout['main_entry']if region else layout['source_entry']
  for rep in range(5):
   for j,n in enumerate([4,16]):
    at=224+(rep*2+j)*288;c.invocation(raw[at+32:at+160],1,rs2,rs6,entry,layout['wrapper']['return_address']);c.invocation(raw[at+160:at+288],n,rs2,rs6,entry,layout['wrapper']['return_address'])
  try:c.kernel(raw[3104:3376])
  except ValueError:pass
  else:raise AssertionError('actual ROM code fault accepted')
for stage in q['stages']:assert stage['exit']==0 and stage['reaped']and stage['NI']==10 and not stage.get('timeout')
assert len(q['stages'])==10 and q['Census_SHA256']=='2ff706841070a5a40ae401b7e92b25c72bb5ba2accae2469423f7d00cb23c86d'
assert all(row['visually_reviewed']for row in js('UI-review.json')['screens'].values())
print(json.dumps(dict(status='PASS SDK/input/functional/completion replay',ROM_SHA256=Q['ROM_SHA256'],groups=6,raw_times=60,register_words=3840,software_runs=6,actual_ROM_opcode_fault_caught=True,DS_timing='UNMEASURED; Census is not the timing oracle',staging='not performed'),indent=2))
