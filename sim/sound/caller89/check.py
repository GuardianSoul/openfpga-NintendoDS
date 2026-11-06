"""Finite real compact caller/fabric boundary vs modern parent77 Sound."""
from pathlib import Path
import hashlib,json,os,subprocess,sys
root=Path(__file__).resolve().parents[3];out=root/'build/sound/caller89';out.mkdir(parents=True,exist_ok=True)
source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
env=os.environ.copy();env.update(REFERENCE='f923e048',CANDIDATE_REF=source,MAKEFLAGS='OPT_FAST=-O0')
subprocess.run([sys.executable,'sim/sound/pipeline76/prepare.py',str(out)],cwd=root,env=env,check=True)
subprocess.run([sys.executable,'sim/sound/caller89/prepare.py',str(out/'generated')],cwd=root,check=True)
v='build/tools/oss-cad-suite/bin/verilator';snap=root/'sim/sound/caller89/inputs'
old=[out/'old'/('old_'+n) for n in ['sound_ram.sv','sound_event_timers.sv','sound.sv','sound_job_pipe.sv','sound_pipe_group.sv']]
common=[root/'rtl/ds/nds_dsp_add.sv']+[root/'rtl/sound'/n for n in ['sound_ram.sv','sound_event_timers.sv','sound_job_pipe.sv','sound_pipe_group.sv','sound.sv','sound_compact_engine.sv','sound_compact_scalar.sv','sound_compact_lane.sv','sound_compact_fifo.sv','sound_compact_weight.sv','sound_compact_group.sv']]
files=old+common+[snap/n for n in ['nds_ram.sv','gpu2d_ram.sv','nds_fabric.sv','nds_io.sv']]+list((out/'generated').glob('*.sv'))+[root/'sim/sound/caller89/tb_caller.sv']
cmd=[v,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','-Wno-PINMISSING','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC','-I'+str(out/'old'),'-I'+str(root/'rtl/sound'),'--top-module','tb_caller89','--Mdir',str(out/'obj')]+[str(p) for p in files]
(out/'command.json').write_text(json.dumps(cmd,indent=2)+'\n')
with (out/'build.log').open('w') as f:r=subprocess.run(cmd,cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT)
assert r.returncode==0,'caller89 build failed'
rows=[]
for timer in [128,16]:
 log=out/f'timer{timer}.log';argv=[str(out/'obj/Vtb_caller89'),f'+timer={timer}']
 with log.open('w') as f:r=subprocess.run(argv,cwd=root,stdout=f,stderr=subprocess.STDOUT)
 text=log.read_text();assert r.returncode==0 and 'CALLER89_PAIRED_PASS' in text,text[-2600:]
 rows.append({'timer':timer,'sha256':hashlib.sha256(log.read_bytes()).hexdigest()});print(text[-2000:],flush=True)
mut=out/'mutant';mut.mkdir(exist_ok=True)
original=out/'generated/caller89_new.sv';changed=mut/original.name
needle="sn_addr <= {5'd0, mem_addr, 2'b00};";s=original.read_text();assert s.count(needle)==1
changed.write_text(s.replace(needle,"sn_addr <= {5'd0, mem_addr, 2'b00} ^ 32'h4;"))
mutcmd=[str(changed) if a==str(original) else a for a in cmd];mutcmd[mutcmd.index('--Mdir')+1]=str(mut/'obj')
with (mut/'build.log').open('w') as f:r=subprocess.run(mutcmd,cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT)
assert r.returncode==0,'mutant build failed'
with (mut/'run.log').open('w') as f:r=subprocess.run([str(mut/'obj/Vtb_caller89'),'+timer=128'],cwd=root,stdout=f,stderr=subprocess.STDOUT)
text=(mut/'run.log').read_text();assert r.returncode!=0 and 'CALLER89_PUBLIC_MISMATCH' in text,text[-2600:]
receipt={'source':source,'baseline':'f923e048','snapshot':json.loads((snap/'manifest.json').read_text()),'profiles':rows,
 'mutant':{'before_sha256':hashlib.sha256(original.read_bytes()).hexdigest(),'after_sha256':hashlib.sha256(changed.read_bytes()).hexdigest(),'log_sha256':hashlib.sha256((mut/'run.log').read_bytes()).hexdigest(),'caught':'CALLER89_PUBLIC_MISMATCH'},
 'scope':'Finite compact scalar caller+actual compact IO/fabric, scripted CPU-facing ARM7 transactions+ARM9/DMA contention; no actual CPU instructions/native7684/warmimport/DS accuracy closure.'}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print('CALLER89_CONTENTION_PUBLIC_MUTANT_PASS',flush=True)
