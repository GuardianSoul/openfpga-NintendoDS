#!/usr/bin/env python3
"""One allocated D2 worker for the newly selected scalar divider context."""
import argparse
import datetime
import hashlib
import json
import os
import resource
import subprocess
from pathlib import Path

R=Path(__file__).resolve().parents[3]
B=R/'build/geometry-scalar-div14'
S=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json')
V='build/tools/oss-cad-suite/bin/verilator'
p=argparse.ArgumentParser();p.add_argument('--lease-confirmed',action='store_true',required=True)
p.add_argument('mode',choices=['unit','caller','mutant','build']);a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
out=B/a.mode;out.mkdir(parents=True,exist_ok=True)
print('SCALAR_D2',os.getpid(),a.mode,'NI10/j1/t1',flush=True)

def status(stage,child=None,active=True):
    d=json.loads(S.read_text());d['phase']=stage
    d['worker']={'active':active,'host':'Desktop','lease':'D2 scalar context','PID':os.getpid(),'child_PID':child,'nice':10,'jobs':1,'threads':1}
    d['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat()
    t=S.with_suffix('.tmp');s=json.dumps(d,separators=(',',':'))+'\n';assert len(s.encode())<=2048;t.write_text(s);t.replace(S)

def run(cmd,log,stage):
    with log.open('w') as f:
        child=subprocess.Popen(cmd,cwd=R,stdout=f,stderr=subprocess.STDOUT)
        status(stage,child.pid);rc=child.wait()
    status(stage+' reaped',child.pid,False)
    return rc,child.pid

primitive=R/'rtl/gpu3d/gpu3d_gxdiv.sv'
deferred=False
if a.mode=='mutant':
    text=primitive.read_text();needle="else if (busy) q <= rsm ? 32'd0 : q_n;"
    assert text.count(needle)==1
    text=text.replace(needle,needle.replace('q_n','q2'))
    # Defer only the existing helper self-check to the new selected-XS_Q
    # consumer relation, so the mutation must escape the divider boundary.
    check='if (!rst && (busy !== busy_r || started_r && !busy_r && q !== q_r))'
    assert text.count(check)==1;text=text.replace(check,check.replace('if (!rst','if (1\'b0 && !rst'))
    primitive=out/'actual-retention-phase-mutant.sv';primitive.write_text(text);deferred=True

base=[V,'--cc','--build','--build-jobs','1','-j','1','--threads','1','--assert','-Wno-fatal','-MAKEFLAGS','VM_PARALLEL_BUILDS=0','--Mdir',str(out/'obj')]
if a.mode=='unit':
    cmd=base+['--exe','--top-module','tb_scalar_divider','-CFLAGS','-std=c++20 -O1',str(primitive),str(B/'before-div.sv'),str(B/'unit.sv'),str(R/'sim/gpu3d/scalar_div_p2x/unit.cpp')]
    binary=out/'obj/Vtb_scalar_divider'
else:
    files=[R/'rtl/gpu3d/gpu3d_gxu_pkg.sv',R/'rtl/gpu3d/gpu3d_ram.sv']
    files+=sorted((R/'rtl/gpu3d').glob('gpu3d_gxrom*.sv'))
    files += [R/f'rtl/gpu3d/gpu3d_{n}.sv'for n in ['gxlight','gxvfin','gxfront','gxeng','gxsort','geom']]+[primitive]
    if a.mode=='build':
        cmd=base+['--top-module','gpu3d_geom','-GFF=1','-GLUNIT=1','-GVFIN=2','-GUSORT=1','-GGX_DSX=1','-GGX_SWAP_OVERLAP=1','-GGX_L44_READ=1','-GGX_DIV_P2X=1','-GGX_SCALAR_DIV_P2X=1','-GGX_MAT_PAR=1','-GGX_ROM_DICT=1','-GENG_M10K=0','-GSPILL=1','-GSP_ON=4096','-GSP_AW=18']+list(map(str,files))
        binary=None
    else:
        files += [B/'before-div.sv',B/'before-eng.sv',B/'before-geom.sv',B/'caller.sv']
        cmd=base+['--exe','--top-module','tb_scalar_caller','-CFLAGS','-std=c++20 -O1']+list(map(str,files))+[str(R/'sim/gpu3d/scalar_div_p2x/caller.cpp')]
        binary=out/'obj/Vtb_scalar_caller'
(out/'command.json').write_text(json.dumps(cmd,indent=2)+'\n')
rc,child=run(cmd,out/'build.log',a.mode+' compile')
if rc:raise SystemExit('compile failed; see '+str(out/'build.log'))
run_rc=None;output=''
if binary:
    run_rc,child=run([str(binary)],out/'run.log',a.mode+' execution')
    output=(out/'run.log').read_text();print(output[-2200:],flush=True)
    if a.mode=='mutant':assert run_rc and 'actual scalar caller selected XS_Q mismatch' in output,output[-1800:]
    else:assert run_rc==0,output[-1800:]
record={'before':'f0bbdcd12ec35493376de90030439496ca32856a','mode':a.mode,'controller_PID':os.getpid(),'last_child_PID':child,'compile_exit':rc,'run_exit':run_rc,'command':cmd,'helper_selfcheck_deferred_for_actual_caller_mutant':deferred,'output':output,'source_hashes':{str(Path(f).relative_to(R)):hashlib.sha256(Path(f).read_bytes()).hexdigest()for f in cmd if f.endswith(('.sv','.cpp'))},'scope':'New scalar K4/SYS quotient context only; existing clip/cohort/front/microcode and accepted proofs retained; no native fit or STA claim.'}
if a.mode=='build':
    archive=out/'obj/Vgpu3d_geom__ALL.a';assert archive.is_file()
    record['archive']={'path':str(archive),'bytes':archive.stat().st_size,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest()}
(out/'receipt.json').write_text(json.dumps(record,indent=2)+'\n')
status(a.mode+' PASS; worker finished',child,False)
print(a.mode,'PASS',flush=True)
