#!/usr/bin/env python3
"""Prepare one changed-source heavy24 gate; source binding requires a supplied pin.

prepare-host does not stage production, invoke a compiler or run a model.
bind-source accepts only an explicit full Git SHA; run requires that same pin.
"""
import argparse
from datetime import datetime, timezone
import difflib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import tarfile
import time

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'build/heavy-game59'
STAGED=OUT/'staged'
PREFIX=ROOT/'build/c549-fetch-prefix51'
GAME=ROOT/'build/c549-fetch-game52'
CONTROL=ROOT/'build/storage-control56'
NATIVE58=Path('/home/user/Git/NDS_Pocket-codex-native58/build/joined-native58')
OLD_SOURCE='/tmp/nds-c549-fetch-prefix51-b50a215bfea9/source'
OLD_MODEL='83ef7483449b85d3c4a54572ad45fdd1bef5afcf4de93aeb1c066a4df11dd496'
CONTROL_MODEL='ccc39939530ece8d890f74c6dba8782e5c8fc834ac2469f1a886ceae113c2b56'
ACTOR='3fa66f90c09138028868e4aa49a58387411318e95f17f84f501bf24c407910d6'


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for data in iter(lambda:f.read(1<<20),b''):h.update(data)
    return h.hexdigest()


def write(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    q=path.with_name(path.name+'.tmp');q.write_text(json.dumps(value,indent=2)+'\n');q.replace(path)


def git(*args):return subprocess.check_output(['git',*args],cwd=ROOT)


def validate_profile(profile,old):
    assert len(old)==54 and len(profile)==58
    delta={k:v for k,v in profile.items() if old.get(k)!=v}
    assert delta==dict(A7_WRAM_SWP_PIPE=1,A7_VRAM_READ_SIDE=1,A7_VRAM_DATA_ACK=1,G3D_STORAGE_PAIR=1),delta
    assert all(profile.get(k)==v for k,v in old.items()),'inherited54 changed'
    assert profile['A7_IF_TURN']==profile['DMA_VRAM_WRITE_TAIL']==profile['A7_DATA_ACK']==0


def prepare_host():
    assert not STAGED.exists(),'host preparation already sealed'
    assert sha(GAME/'model.bin')==OLD_MODEL and sha(CONTROL/'model.bin')==CONTROL_MODEL
    qualified=json.loads((PREFIX/'preparation.json').read_text())
    for name,h in qualified['files'].items():assert sha(PREFIX/'staged'/name)==h,name
    native=json.loads((NATIVE58/'production-preparation.json').read_text())
    old=json.loads(Path('/home/user/Git/NDS_Pocket-codex-native44/build/joined-native52/inputs.json').read_text())['profile']
    profile=native['profile'];validate_profile(profile,old)
    shutil.copytree(PREFIX/'staged/overlay',STAGED/'overlay')
    # The import actor stays byte-identical. Only passive strict guards change.
    tb=STAGED/'overlay/sim/pocket_ds/tb_ds_pocket.sv';assert sha(tb)==ACTOR
    actor=tb.read_text();assert 'runtime_import_' not in actor and '`include' not in actor
    ldm=STAGED/'overlay/sim/pocket_ds/storage_pair_ldm_capture.sv';before=ldm.read_text();after=before
    for name in ('A9_IO_REPLAY','A7_MAIN_STORE_TURN','A7_IF_REJOIN'):
        a='`LD.'+name+'!=0';assert after.count(a)==1;after=after.replace(a,'`LD.'+name+'!=1')
    label='LDM3/base1/storage1; IO/store/data/rejoin0'
    assert after.count(label)==1
    after=after.replace(label,'LDM3/base1/storage1; IO/store/rejoin1/data0; heavy59 full58-profile guard separate')
    ldm.write_text(after)
    (OUT/'passive-guard.patch').write_text(''.join(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='retained/storage_pair_ldm_capture.sv',tofile='heavy59/storage_pair_ldm_capture.sv')))
    lines=['// Passive constants only: no DUT drive, input deposit or clock change.',
        '`define H59 $root.tb_ds_pocket.dut','module heavy59_profile;',
        'timeunit 1ps; timeprecision 1ps;',
        'import "DPI-C" function void pair_capture_emit(input int unsigned kind,port,input longint unsigned t,input int unsigned addr,data,x,y,input longint unsigned z);',
        'bit checked=0;',
        'always @(posedge `H59.clk_sys) if(!checked && !`H59.rst_sys) begin']
    for i,(name,value) in enumerate(sorted(profile.items())):
        assert re.fullmatch('[A-Z0-9_]+',name) and isinstance(value,int)
        lines += [f' if(`H59.{name}!={value}) $fatal(1,"HEAVY59_PROFILE {name}");',
                  f' pair_capture_emit(63,0,$time,{i},32\'(`H59.{name}),{value},0,0);']
    lines += [' if(`H59.x_vram.CUT_WRITE_TURN!=0) $fatal(1,"HEAVY59_PROFILE CUT_WRITE_TURN must remain0");',
              ' $display("HEAVY59_PROFILE_PASS: exact58 fields; CUT_WRITE_TURN0");',
              ' checked=1; end','endmodule',
              'bind tb_ds_pocket heavy59_profile u_heavy59_profile();','`undef H59','']
    (STAGED/'heavy59_profile.sv').write_text('\n'.join(lines))
    inputs=json.loads((GAME/'expanded-inputs.json').read_text());assert len(inputs)==11
    assert inputs==json.loads((CONTROL/'expanded-inputs.json').read_text())
    (STAGED/'inputs').mkdir()
    for name in [*inputs,'bootrom.mif']:
        p=PREFIX/'staged/inputs'/name
        if name in inputs:assert sha(p)==inputs[name],name
        os.link(p,STAGED/'inputs'/name)
    argv=[s.replace(str(GAME),str(OUT)) for s in json.loads((GAME/'runtime-command.json').read_text())]
    assert '+frames=24' in argv and '+root40_ldm_capture' in argv
    assert not any(s.startswith(('+scalar','+timeout_ms=')) for s in argv)
    command=json.loads((PREFIX/'build-command.json').read_text())
    command=[s.replace(OLD_SOURCE,str(STAGED/'production')).replace(str(PREFIX/'staged'),str(STAGED))
             for s in command if s!=str(PREFIX/'staged/scalar.sv')]
    macro='+define+TB_CORE_PARAMS=, .G3D_STORAGE_PAIR(1)';assert command.count(macro)==1
    command[command.index(macro)]='+define+TB_CORE_PARAMS='+''.join(', .'+k+'('+str(v)+')' for k,v in sorted(profile.items()))
    command[command.index('--Mdir')+1]=str(OUT/'PIN_REQUIRED/obj')
    command.append(str(STAGED/'heavy59_profile.sv'))
    assert command[command.index('-j')+1]==command[command.index('--threads')+1]=='1'
    write(OUT/'profile.json',profile);write(OUT/'expanded-inputs.json',inputs)
    write(OUT/'build-command-template.json',command);write(OUT/'runtime-command.json',argv)
    write(OUT/'host-preparation.json',dict(state='SOURCE_ONLY_HOST_READY_COORDINATOR_POST_FF_PIN_REQUIRED',
        production_source=None,profile=profile,profile_template_source=native['source'],
        profile_template_path=str(NATIVE58/'production-preparation.json'),profile_template_file_sha256=sha(NATIVE58/'production-preparation.json'),
        inherited54=old,TB_actor_sha256=ACTOR,original_build_sha256=sha(PREFIX/'build-command.json'),
        original_runtime_sha256=sha(GAME/'runtime-command.json'),control_models=[OLD_MODEL,CONTROL_MODEL],
        files={str(p.relative_to(STAGED)):sha(p) for p in STAGED.rglob('*') if p.is_file()},
        prepared_UTC=datetime.now(timezone.utc).isoformat(),frames=24,
        fixed_pairs='Original raw10..23/reference5..18, Pocket precision. No epoch/input/frame/sample shifts.',
        capture='Original all-port/CPU/state/PCM observer; same actor/11inputs/boot. Full58 strict profile witness; scalar stop observer omitted while disabled.',
        comparison='CPU timing changes are intentional. Compare architectural state/order, original fixed frames/save/physical causal ownership/deadlines; retain every raw timestamp. Semantic/state/audio differences require actual attribution, not an automatic timing waiver.',
        known_open='Old MAINhit/helper context gaps remain; current-source/six-scene/audio/DS/full fit and67MHz qualification remain separate.',
        resource='L1 reserved oneNI10/j1/t1 after supplied pin+cap/load/diskcheck. No old baseline/model/native rerun.'))
    print('HOST_READY_WAIT_COORDINATOR_PIN: exact58 profile/11inputs/unchanged actor; no production staged or compiler/native invoked')


def bind_source(source):
    assert re.fullmatch('[0-9a-f]{40}',source),'require explicit full coordinator-supplied source SHA'
    assert git('rev-parse',source).decode().strip()==source
    for ancestor in ('1c721722','3954162d','5e4b1db7'):
        subprocess.run(['git','merge-base','--is-ancestor',ancestor,source],cwd=ROOT,check=True)
    prep=json.loads((OUT/'host-preparation.json').read_text())
    for name,h in prep['files'].items():assert sha(STAGED/name)==h,name
    assert not (STAGED/'production').exists(),'production pin already sealed'
    cmd=json.loads((OUT/'build-command-template.json').read_text())
    support=[s.removeprefix(str(STAGED/'production')+'/') for s in cmd if s.startswith(str(STAGED/'production')+'/') and s.endswith(('.sv','.v','.cpp')) and '/rtl/' not in s]
    data=git('archive',source,'--','rtl',*support)
    with tarfile.open(fileobj=io.BytesIO(data)) as t:t.extractall(STAGED/'production',filter='data')
    profile=json.loads((OUT/'profile.json').read_text());validate_profile(profile,prep['inherited54'])
    core=(STAGED/'production/rtl/pocket/core_top_ds.sv').read_text()
    for name in profile:assert re.search(r'parameter\s+(?:bit|int|integer)\s+'+name+r'\s*=',core),name
    temp=Path('/tmp/nds-heavy-game59-'+source[:12]);cmd[cmd.index('--Mdir')+1]=str(temp/'obj')
    assert cmd.count('-march=native')==1
    cmd[cmd.index('-march=native')]='-march=x86-64-v3'
    compiled=[Path(s) for s in cmd if s.endswith(('.sv','.v','.cpp'))]
    assert len(compiled)==143 and all(p.is_file() for p in compiled)
    prod={str(p.relative_to(STAGED/'production')):sha(p) for p in (STAGED/'production').rglob('*') if p.is_file()}
    write(OUT/'production-manifest.json',prod);write(OUT/'compiled-inputs.json',{str(p):sha(p) for p in compiled})
    write(OUT/'build-command.json',cmd)
    write(OUT/'bound-source.json',dict(state='PINNED_SOURCE_HOST_READY_NO_BUILD_NATIVE',source=source,
        profile=profile,production_files=len(prod),compiled_files=len(compiled),temporary_build=str(temp),
        portable_host_isa='x86-64-v3',
        host_preparation_sha256=sha(OUT/'host-preparation.json'),build_command_sha256=sha(OUT/'build-command.json'),
        runtime_command_sha256=sha(OUT/'runtime-command.json'),production_manifest_sha256=sha(OUT/'production-manifest.json'),
        compiled_inputs_sha256=sha(OUT/'compiled-inputs.json'),bound_UTC=datetime.now(timezone.utc).isoformat()))
    print('SOURCE_PINNED_NO_EXECUTION',source)


def run(source):
    assert re.fullmatch('[0-9a-f]{40}',source)
    assert (OUT/'bound-source.json').is_file(),'coordinator source pin must be bound before build/native'
    bound=json.loads((OUT/'bound-source.json').read_text());assert bound['source']==source
    for name,key in [('host-preparation.json','host_preparation_sha256'),('build-command.json','build_command_sha256'),
        ('runtime-command.json','runtime_command_sha256'),('production-manifest.json','production_manifest_sha256'),('compiled-inputs.json','compiled_inputs_sha256')]:
        assert sha(OUT/name)==bound[key],name
    prep=json.loads((OUT/'host-preparation.json').read_text())
    for name,h in prep['files'].items():assert sha(STAGED/name)==h,name
    for name,h in json.loads((OUT/'production-manifest.json').read_text()).items():assert sha(STAGED/'production'/name)==h,name
    assert os.getloadavg()[0]<24 and shutil.disk_usage('/tmp').free>2*1024**3
    assert shutil.disk_usage(ROOT).free>3*1024**3
    with (OUT/'attempt.lock').open('x') as f:f.write(source+'\n')
    temp=Path(bound['temporary_build']);temp.mkdir()
    for name in ('run','capture','shots'):(OUT/name).mkdir()
    for p in (STAGED/'inputs').iterdir():(OUT/'run'/p.name).symlink_to(p)
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    if os.getpriority(os.PRIO_PROCESS,0)<10:os.setpriority(os.PRIO_PROCESS,0,10)
    state=dict(source=source,profile=bound['profile'],controller_PID=os.getpid(),controller_starttime=Path('/proc/self/stat').read_text().split()[21],
        host=os.uname().nodename,NI=os.getpriority(os.PRIO_PROCESS,0),jobs=1,threads=1,stages=[])
    def call(argv,label,limit):
        start=time.monotonic()
        with (OUT/(label+'.log')).open('w') as log:
            p=subprocess.Popen(argv,cwd=OUT/'run',stdout=log,stderr=subprocess.STDOUT)
            row=dict(phase=label,PID=p.pid,starttime=Path(f'/proc/{p.pid}/stat').read_text().split()[21]);state['stages'].append(row)
            write(OUT/'status.json',dict(state,phase=label,child_PID=p.pid))
            try:rc=p.wait(timeout=limit)
            except subprocess.TimeoutExpired:
                p.terminate()
                try:p.wait(timeout=15)
                except subprocess.TimeoutExpired:p.kill();p.wait()
                rc=p.returncode;row['wall_timeout']=True
            row.update(exit=rc,reaped=True,wall_seconds=time.monotonic()-start)
        write(OUT/'status.json',dict(state,phase=label+'_TERMINAL',child_PID=None));assert rc==0,(label,rc,'no automatic retry')
    call(json.loads((OUT/'build-command.json').read_text()),'build',1800)
    shutil.copy2(temp/'obj/Vtb_ds_pocket',OUT/'model.bin');state['model_sha256']=sha(OUT/'model.bin')
    write(OUT/'model.json',dict(source=source,profile=bound['profile'],mode=1,sha256=state['model_sha256']))
    call(json.loads((OUT/'runtime-command.json').read_text()),'native',3600)
    for name,h in prep['files'].items():assert sha(STAGED/name)==h,name
    assert sha(OUT/'model.bin')==state['model_sha256']
    assert len(list((OUT/'shots').glob('*.ppm')))==24
    assert len((OUT/'capture/capture.states.jsonl').read_text().splitlines())==25
    write(OUT/'capture-manifest.json',{p.name:dict(bytes=p.stat().st_size,sha256=sha(p)) for p in (OUT/'capture').iterdir()})
    write(OUT/'terminal.json',dict(exit=0,all_children_reaped=True,model_sha256=state['model_sha256'],stages=state['stages']))
    write(OUT/'status.json',dict(state,phase='ONE_CHANGED_HEAVY24_TERMINAL',child_PID=None))
    print('ONE_CHANGED_HEAVY24_TERMINAL',source,state['model_sha256'],flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('action',choices=['prepare-host','bind-source','run']);p.add_argument('--source');a=p.parse_args()
    if a.action=='prepare-host':assert a.source is None;prepare_host()
    elif a.action=='bind-source':bind_source(a.source or '')
    else:run(a.source or '')
