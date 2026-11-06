#!/usr/bin/env python3
"""Bundle the one SDK/software qualification result; omit external runtime."""
from pathlib import Path
import argparse,hashlib,io,json,os,tarfile
S=Path(__file__).resolve().parent;R=S.parents[2]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('run',type=Path);p.add_argument('packet',type=Path);a=p.parse_args();D=a.run.resolve();P=a.packet.resolve();P.mkdir(parents=True,exist_ok=False)
os.setpriority(os.PRIO_PROCESS,0,10);sha=lambda b:hashlib.sha256(b).hexdigest();F={}
def put(name,path):F[name]=path.read_bytes()
q=json.loads((D/'results.json').read_text());assert q['state'].startswith('PASS_SDK')and len(q['stages'])==10 and all(x['reaped']for x in q['stages'])
for name in ['results.json','layout.json','linked-audit.json','normal-check.json','real-output-faults.json','UI-review.json','checks.json','Census23-build-info.log','SDK-build.log','a7mulmix.dis','a7mulmix7.dis','first-MUL-NOP.nds']:
 put(name,D/name)
for name in ['a7mulmix7.elf','a7mulmix.elf','a7mulmix.nds','build-id.h','private-ds7.ld']:
 put('sdk/'+name,D/'sdk'/name)
for name in q['cases']:
 for f in (D/name/'sd/hwref/a7mulmix-v1').iterdir():
  if f.is_file():put('cases/'+name+'/outputs/'+f.name,f)
 for part in ['summary.json','frames.csv']:put('cases/'+name+'/'+part,D/name/'run'/part)
 put('cases/'+name+'/run.log',D/(name+'-Census23.log'));put('images/'+name+'-screen.png',D/(name+'-screen.png'))
for name in ['last-CSV-sample-missing','coherent-real-R6-fault']:
 for f in (D/name/'outputs').iterdir():
  if f.is_file():put('faults/'+name+'/'+f.name,f)
for path in S.iterdir():
 if path.is_file():put('source/sw/hwref/a7mulmix/'+path.name,path)
for name in ['common/hwref.c','common/hwref.h','Makefile','wramarb/linker.py','arm7fetch/sdk-check.py','arm7fetch/check.py','arm7fetch/cases.json']:
 put('source/sw/hwref/'+name,S.parent/name)
archive=P/'evidence.tar.gz'
with tarfile.open(archive,'w:gz',compresslevel=9)as t:
 for name,b in sorted(F.items()):
  info=tarfile.TarInfo(name);info.size=len(b);info.mtime=0;info.mode=0o644;t.addfile(info,io.BytesIO(b))
audit=json.loads((D/'linked-audit.json').read_text())
Q=dict(source=q['source'],producer_source_commit='1d2fdadb1c6f47a6c393d81da13f4dac748915d0',branch='codex/cpu-a7mulmix-sdk',ROM_SHA256=q['ROM_SHA256'],build_id=q['layout']['build_id'],Census_SHA256=q['Census_SHA256'],
 prior_helper_dependency=dict(directory='a7mulphase-completion-20261102',file='evidence.tar.gz',SHA256=audit['prior_helper_archive_SHA256']),
 proof=dict(SDK_pair=True,same272B_kernel=True,exact100B_wrapper=True,paired_call_audit=True,helper_exact_qualified_previous=True,normal_groups=6,raw_times=60,register_words=3840,live_code_snapshots=12,completed_resume_preserves_measurements=True,software_runs=6,real_ROM_opcode_fault_caught=True,coherent_R6_payload_fault_caught=True,truncated_final_sample_caught=True,all_worker_stages_terminal_reaped=True),
 limits='Software protocol/state/linked-body/completion only. Actual DS timings unmeasured. No RTL/default/area/card/staging/deploy/updater or native DS baseline. BIOS/firmware/executable external and hash-bound, omitted.',
 archive=dict(file=archive.name,bytes=archive.stat().st_size,sha256=sha(archive.read_bytes()),files={name:dict(bytes=len(b),sha256=sha(b))for name,b in sorted(F.items())}))
(P/'qualification.json').write_text(json.dumps(Q,indent=2)+'\n');print('packet',len(F),archive.stat().st_size,Q['archive']['sha256'])
