from pathlib import Path
import hashlib,json,re,subprocess,sys,shutil,os
root=Path(__file__).resolve().parents[3]
out=Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=True)
(out/'old').mkdir(exist_ok=True)
ref=subprocess.check_output(['git','rev-parse',os.environ.get('REFERENCE','76616273')],cwd=root,text=True).strip()
names=['sound','sound_worker','sound_ram','sound_mlab','sound_cpu_ram','sound_run_ram','sound_capbuf','sound_adpcm_step','sound_event_timers']
files=['sound.sv','sound_engine.svh','sound_ram.sv','sound_event_timers.sv']
prior_pipe=subprocess.run(['git','cat-file','-e',f'{ref}:rtl/sound/sound_pipe_group.sv'],cwd=root,stderr=subprocess.DEVNULL).returncode==0
prior_files=files+(['sound_job_pipe.sv','sound_pipe_group.sv'] if prior_pipe else [])
if not prior_pipe:
    for n in ['sound_job_pipe.sv','sound_pipe_group.sv']:
        (out/'old'/('old_'+n)).unlink(missing_ok=True)
names+=['sound_job_pipe','sound_pipe_group']
for n in prior_files:
    text=subprocess.check_output(['git','show',f'{ref}:rtl/sound/{n}'],cwd=root,text=True)
    for name in sorted(names,key=len,reverse=True):text=re.sub(r'\b'+name+r'\b','old_'+name,text)
    text=text.replace('"sound_engine.svh"','"old_sound_engine.svh"')
    (out/'old'/('old_'+n)).write_text(text)
manifest={'reference':ref,'prior_worker_pipe':prior_pipe,'fixture':'Sound62 full before/after fixture adapted only clocks/CE epoch, shared parameter and unobservable arithmetic comparison','sha256':{}}
for p in [root/'sim/sound/pipeline76/tb_whole_pipe.sv',root/'sim/sound/pipeline76/tb_pipe_restore.sv',*[root/'rtl/sound'/n for n in files],root/'rtl/sound/sound_job_pipe.sv',root/'rtl/sound/sound_pipe_group.sv',*[root/'sim/pocket_ds'/n for n in ['runtime_import_sound_storage.svh','runtime_import_sound_owned.svh']],root/'sim/sound/runtime_import_sound_parent_banks.svh']:
    rel=str(p.relative_to(root));data=p.read_bytes()
    candidate=os.environ.get('CANDIDATE_REF')
    if candidate and (rel.startswith('rtl/') or 'runtime_import_sound_' in rel):
        data=subprocess.check_output(['git','show',candidate+':'+rel],cwd=root)
    manifest['sha256'][rel]=hashlib.sha256(data).hexdigest()
    frozen=out/'frozen'/p.relative_to(root);frozen.parent.mkdir(parents=True,exist_ok=True);frozen.write_bytes(data)
manifest['candidate_ref']=os.environ.get('CANDIDATE_REF','working tree')
(out/'old_runtime_import_sound_owned.svh').write_bytes(subprocess.check_output(['git','show',ref+':sim/pocket_ds/runtime_import_sound_owned.svh'],cwd=root))
if os.environ.get('MUTATE_CONTEXT')=='1':
    p=out/'frozen/rtl/sound/sound_job_pipe.sv';text=p.read_text()
    before='assign decode_now_tag=dt1;';assert text.count(before)==1
    p.write_text(text.replace(before,"assign decode_now_tag=dt1 ^ 24'h400000;"))
    manifest['actual_RTL_mutation']='decode_now_tag flips owner bit22; production source unchanged'
    manifest['mutated_sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
if os.environ.get('MUTATE_PARENT')=='1':
    p=out/'frozen/rtl/sound/sound_engine.svh';text=p.read_text()
    before='sample_value=rr_q[31:16];';assert text.count(before)==1
    p.write_text(text.replace(before,"sample_value=rr_q[31:16] ^ 16'h1000;"))
    manifest['actual_RTL_mutation']='parent S_LOAD sample operand flips bit12; production source unchanged'
    manifest['mutated_sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
(out/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
