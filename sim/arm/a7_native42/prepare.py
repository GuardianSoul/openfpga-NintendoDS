#!/usr/bin/env python3
"""Freeze merged production39 and existing original SOUND inputs; no simulation."""
from pathlib import Path
import ast,hashlib,io,json,re,shutil,subprocess,tarfile
ROOT=Path(__file__).resolve().parents[3]
REF=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
J=ROOT/'build/a7-native42';assert not J.exists();J.mkdir(parents=True)
OLD=Path('/home/user/Git/NDS_Pocket-codex-shell/build/sound-joined30-806-v1')
NATIVE=Path('/home/user/Git/NDS_Pocket/build/join-27340ba4-if4')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,j):p.write_text(json.dumps(j,indent=2)+'\n')
profile=json.loads((NATIVE/'inputs.json').read_text())['profile'];assert len(profile)==37
profile.update(GX_DIV_P2X=1,A7_DATA_ACK=1);assert len(profile)==39
for name,value in profile.items():
 m=re.search(r'parameter\s+(?:integer|bit)\s+'+name+r'\s*=\s*([^,\n]+)',(ROOT/'rtl/pocket/core_top_ds.sv').read_text());assert m
 if name!='A7_DATA_ACK':assert int(m[1].strip(),0)==value,(name,m[1],value)
write(J/'profile.json',dict(source=REF,profile=profile,baseline='qualified root38 plus explicit A7_DATA_ACK1'))
S=J/'sound';S.mkdir();P=S/'prepared';P.mkdir();C=P/'core'
shutil.copytree(OLD/'prepared/core',C,ignore=shutil.ignore_patterns('build','obj','obj_dir','__pycache__','*.o','*.out','*.vcd','*.fst'))
for d in ['rtl','scripts']:
 if(C/d).exists():shutil.rmtree(C/d)
with tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['git','archive',REF,'rtl','scripts','sw/boot','sw/scpu'],cwd=ROOT)))as t:t.extractall(C,filter='data')
# Keep the latest qualified physical/native driver and pin models. Add only
# the existing SOUND ROI and passive witnesses to its testbench.
tb=(NATIVE/'source/sim/pocket_ds/tb_ds_pocket.sv').read_text()
anchor='    initial begin\n        reg [31:0] magic, n, mask, done;';assert tb.count(anchor)==1
tb=tb.replace(anchor,'    `include "sound_v2_roi.svh"\n'+anchor)
guards='''
    initial begin
        #1;
        if(dut.A7_DATA_ACK!=1 || dut.ds.A7_DATA_ACK!=1 || dut.ds.u_cpud.A7_DATA_ACK!=1 || dut.ds.u_cpud.g_a7c.u_p7.DATA_ACK_HANDOFF!=1 || dut.GX_DIV_P2X!=1 || dut.ds.GX_DIV_P2X!=1)
            $fatal(1,"A7_NATIVE39_ROUTE_ERROR");
        $display("A7_NATIVE39_ROUTE_OK fields39 dataACK1 divider1; all inherited physical gates retained");
    end
'''
i=tb.rindex('endmodule');(C/'sim/pocket_ds/tb_ds_pocket.sv').write_text(tb[:i]+guards+tb[i:])
driver=(NATIVE/'source/sim/pocket_ds/run.py').read_text()
anchor="'sim/pocket_ds/tb_ds_pocket.sv']";assert driver.count(anchor)==1
driver=driver.replace(anchor,"'sim/pocket_ds/tb_ds_pocket.sv', 'sim/sound/cycle_observer/sound_cycle_observer.sv', 'sim/sound/setup_observer/sound_setup_observer.sv', 'sim/sound/capture_cpu_service_observer.sv', 'sim/sound/a7_data_owner_observer.sv']")
if "'--assert'"not in driver:driver=driver.replace("'--binary', '--timing'","'--binary', '--assert', '--timing'")
# Preserve the qualified frozen boot image instead of rebuilding it.
a="    subprocess.run(['make', '-s', '-C', str(ROOT), 'build/boot/bootrom.hex'], check=True)"
if a in driver:driver=driver.replace(a,"    assert (ROOT/'build/boot/bootrom.hex').is_file()")
driver=driver.replace("'-I' + str(rtl / 'pocket')]","'-I' + str(rtl / 'pocket'), '-I'+str(rtl/'sound'), '-I'+str(ROOT/'sim/pocket_ds')]")
driver=driver.replace('    model_lock = None',"    cmd += ['-I'+str(ROOT/'sim/pocket_ds')]\n    model_lock = None")
(C/'sim/pocket_ds/run.py').write_text(driver)
for rel in ['sim/phase1/sim_prims.sv','sim/pocket_ds/cram_model.sv']:
 if(NATIVE/'source'/rel).exists():shutil.copyfile(NATIVE/'source'/rel,C/rel)
shutil.copyfile(OLD/'prepared/core/sim/pocket_ds/sound_v2_roi.svh',C/'sim/pocket_ds/sound_v2_roi.svh')
shutil.copyfile(Path('/home/user/Git/NDS_Pocket-codex-shell/build/sound-prefix-cpu-dde90d15/prepared/core/sim/sound/capture_cpu_service_observer.sv'),C/'sim/sound/capture_cpu_service_observer.sv')
obs=(ROOT/'sim/arm/a7_data_handoff/observe.sv').read_text();obs=obs[:obs.index('bind old_nds_arm7_port')];obs=obs.replace('if(fd)$fdisplay(fd,','if(fd && $root.tb_ds_pocket.snd_v2_active)$fdisplay(fd,')
(C/'sim/sound/a7_data_owner_observer.sv').write_text(obs)
wrapper=(NATIVE/'source/rnd/pocket_cpu.py').read_text()
wrapper=wrapper.replace('original_run = mod.subprocess.run', '''from job_guard import install
install(mod.subprocess)
packet=next(sys.argv[i+1]for i,a in enumerate(sys.argv[:-1])if a=='--plus'and sys.argv[i+1].startswith('sound_v2_packet='))
out=Path(packet.split('=',1)[1]).parent
sys.argv += ['--roms-dir',str(ROOT.parents[1]/'runtime'),'--plus','sndsetup='+str(out/'setup.csv'),'--plus','sndservice='+str(out/'parent-states.csv'),'--plus','a7data_witness='+str(out/'p7'),'--vmcheck']
original_run = mod.subprocess.run''')
wrapper=wrapper.replace("mod.CACHE = ROOT.parent / ('model-cache-' + socket.gethostname())","mod.CACHE = Path('/tmp/nds-a7-native39-cache')")
(C/'rnd/pocket_cpu.py').write_text(wrapper)
for folder in ['inputs','runtime','reader','helpers','golden']:shutil.copytree(OLD/folder,S/folder,ignore=shutil.ignore_patterns('__pycache__'))
for name in ['job_guard.py','sim_ownership.py','sound_process_identity.py','expected-native-images.json']:shutil.copyfile(OLD/name,S/name)
for name in ['job_guard.py','sim_ownership.py','sound_process_identity.py']:shutil.copyfile(S/name,C/'rnd'/name)
for name,h in json.loads((OLD/'runtime-sha256.json').read_text()).items():
 assert sha(S/'runtime'/name)==h,name
 if '/'in name:
  p=C/name;p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(S/'runtime'/name,p)
# The imported checkpoint and its timer fractional seed are exact old inputs.
plan=json.loads((OLD/'prepared/plan.json').read_text());plan.update(core_source=REF,canonical_profile=profile,status='frozen merged39 original7684; strict V2 runtime route proof required',reader_policy=dict(donor_reader_plan_sha256=sha(S/'reader/reader-plan.json'),current_body_sha256=sha(C/'rtl/sound/sound_engine.svh'),policy='same strict V2 owner/global rules; compression source independently qualified; actual121 routes must pass'))
plan['source_sha256']={str(p.relative_to(C)):sha(p)for p in C.rglob('*')if p.is_file()}
write(P/'plan.json',plan);write(P/'inputs.json',dict(source=REF,profile=profile));write(P/'source-manifest.json',dict(files=plan['source_sha256']))
runner=S/'helpers/sound_v2_full_run.py';s=runner.read_text().replace("'--no-cache',",'');runner.write_text(s)
shutil.copyfile(Path(__file__),J/'prepare.py')
write(J/'job.json',dict(source=REF,profile=profile,P7_sha256=sha(C/'rtl/ds/nds_arm7_port.sv'),PSRAM_sha256=sha(C/'rtl/pocket/nds_psram.sv'),sound_plan_sha256=sha(P/'plan.json'),no_native_started=True,defaults_unchanged=True))
print(J,REF,'fields',len(profile))
