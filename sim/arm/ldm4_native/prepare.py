#!/usr/bin/env python3
"""Freeze the authorized reference LDM4 native gate; no compiler/model invocation."""
from pathlib import Path
import argparse,hashlib,io,json,re,shutil,subprocess,tarfile
R=Path(__file__).resolve().parents[3];M=Path('/home/user/Git/NDS_Pocket')
DONOR=M/'build/coordinator/native65-head';QUIET=M/'build/coordinator/ds30-native58-independent-replay/prepared'
BEFORE='9fca32ff12a457599c4bdbf182b84e364381756a';AFTER='4452b3368ed3f971f8e4dcd2d17a0769dac61031'
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);a=p.parse_args();D=a.output.resolve();D.mkdir(parents=True,exist_ok=False)
def save(p,d):p.write_text(json.dumps(d,indent=2)+'\n')
build=json.loads((DONOR/'build-command.json').read_text());inputs=json.loads((DONOR/'inputs.json').read_text())
macro=next(x for x in build['argv']if x.startswith('+define+TB_CORE_PARAMS='))
profile={k:int(v)for k,v in re.findall(r'\.([A-Z0-9_]+)\((\d+)\)',macro)}
assert profile==inputs['profile']and len(profile)==61 and profile['A7_DATA_ACK']==0
P=D/'common';P.mkdir();shutil.copytree(QUIET,P/'ds30');shutil.copy2(DONOR/'native_guard.py',P/'native_guard.py')
for n in ['prepare.py','run.py','observe.svh']:shutil.copy2(R/'sim/arm/ldm4_native'/n,P/n)
runtime=P/'runtime';runtime.mkdir()
for src in (DONOR/'results/unita7/run').iterdir():
 if src.is_file()and src.name!='rom.hex':shutil.copy2(src,runtime/src.name)
roms=P/'roms';roms.mkdir()
guests={
 'unita7':(DONOR/'test-roms/unita7.nds','bec6c66e8729a0dfaf47be1988b2d5330edeafbacd3fc8066319c3b8b634b292',240,3000,3600),
 'ds30':(QUIET/'arm7-ds30.nds','5163eb3cb0653b6278be3604e4abb827c85513d58175c67cb7e3987fea2e333e',160,3000,7200),
 'unitmem':(Path('/home/user/Git/NDS_Pocket-codex-vram-joint-turn/build/vram-native60/guest-inputs/unitmem.nds'),'3eda7c1b6cf15da99fbb938aef88be8176ba7e2e8cf01be1a92b35f8b4a7b573',240,3000,3600)}
guest_specs={}
for name,(src,sha,frames,sim_ms,wall)in guests.items():
 assert H(src)==sha,name;shutil.copy2(src,roms/(name+'.nds'));guest_specs[name]={'ROM_SHA256':sha,'frames':frames,'simulated_ms':sim_ms,'wall_seconds':wall}
variants={}
for name,source,ack in [('before',BEFORE,None),('ACK0',AFTER,0),('ACK1',AFTER,1)]:
 V=D/name;V.mkdir();S=V/'source';S.mkdir()
 data=subprocess.check_output(['git','archive',source,'rtl','sim','sw','tools'],cwd=R)
 with tarfile.open(fileobj=io.BytesIO(data))as t:t.extractall(S,filter='data')
 # Explicit donor-generated host support, never production RTL substitution.
 for rel in ['build/boot/bootrom.hex','build/ds41/witness.svh','sim/pocket_ds/ds30_observer.svh','sim/pocket_ds/ds30_tables.svh']:
  dest=S/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(DONOR/'source'/rel,dest)
 for folder in ['host-overlay','host-sound51']:shutil.copytree(DONOR/folder,V/folder)
 tb=V/'host-overlay/tb_native52.sv';text=tb.read_text();assert text.count('\nendmodule')==1
 text=text.replace('\nendmodule','\n`include "ldm4_observe.svh"\nendmodule');tb.write_text(text)
 shutil.copy2(P/'observe.svh',V/'host-overlay/ldm4_observe.svh')
 pr=dict(profile,A7_LDM4_META=1)
 if ack is not None:pr['A7_LDM4_ACK']=ack
 command=[]
 for x in build['argv']:
  if x.startswith('+define+TB_CORE_PARAMS='):x='+define+TB_CORE_PARAMS='+''.join(', .%s(%d)'%(k,v)for k,v in pr.items())
  command.append(x.replace(str(DONOR),str(V)).replace('model-native52','model'))
 command+=['-I'+str(S),'-I'+str(V/'host-overlay'),'+define+L4_EXPECT_ACK='+str(ack or 0)]
 # Confirm all explicit inputs exist without running the compiler.
 for x in command:
  if x.endswith(('.sv','.v'))and x.startswith('/'):assert Path(x).is_file(),x
 production={str(x.relative_to(S)):H(x)for x in sorted((S/'rtl').rglob('*'))if x.is_file()}
 host={str(x.relative_to(V)):H(x)for folder in ['host-overlay','host-sound51']for x in sorted((V/folder).rglob('*'))if x.is_file()}
 variants[name]={'source':source,'profile':pr,'normalized_ACK':ack or 0,'model_SHA256':None,'model_state':'NOT BUILT','build_command':command,'build_cwd':str(S),'build_wall_seconds':5400,'production_SHA256':production,'host_SHA256':host}
 save(V/'source-profile.json',variants[name])
assert variants['ACK0']['production_SHA256']==variants['ACK1']['production_SHA256']
changed=[n for n,h in variants['before']['production_SHA256'].items()if variants['ACK0']['production_SHA256'][n]!=h]
assert changed==['rtl/arm/cpu_domain.sv','rtl/ds/nds_top.sv','rtl/pocket/core_top_ds.sv'],changed
donor_model=json.loads((DONOR/'results/unita7/model.json').read_text())
plan={'version':1,'status':'PINNED; NOT LAUNCHED','reference_source':AFTER,'before_source':BEFORE,'compact_source60':'excluded; no compact rebuild/import or timing transfer','authority':'Root delegation after4452 integration: complete pinned plan and execute D2 NI10/j1/t1, stop value/owner corruption; no further permission wait.','donor':{'source':inputs['source'],'model_SHA256':donor_model['sha256'],'actual_profile_fields':61,'old_build_receipt_summary_fields':len(build['profile']),'actual_profile_matches_inputs':True,'model_reuse':False},'variants':variants,'guests':guest_specs,'input_SHA256':{str(x.relative_to(P)):H(x)for x in sorted(P.rglob('*'))if x.is_file()},'bounds':{'host':'DesktopD2','NI':10,'jobs':1,'threads':1,'concurrent_workers':1,'builds':3,'guests_per_model':3,'maximum_model_launches':9,'execution':'serial; no retry loops; timeout/corruption stops whole worker'},'controls':{'canonical_LDM4':{'slot':12,'historical_reference_core_x100':2892,'DS_x100':1504,'context':'reference native65 ARM9 MAIN-fetch/IO-poll helper; this is not compact60 or quietDS30'},'quiet_LDM4':{'kernel':'ldm4_main','arg':0,'historical_core_x100':1439,'DS_x100':1504,'context':'original DS30 guest5163; all50livebodies/32calls/31rows/context guards retained; historical core1439 not asserted as measured current9fca'},'unitmem':'32 canonical values/transport/VM guards as negative shared-service control; no LDM8 timing closure or optimization'},'prediction':{'isolated_matching_return_saved_SYS':2,'conditional_four_fresh_beats_saved_SYS':8,'conditional_A7_cycles_per_LDM4':4,'unit_witness':'24 actual accepts saved48SYS (1449->1401), synthetic component only','not_aggregate_forecast':'Do not subtract4A7 from native aggregate. Earlier requests change arbitration/phase/helper progress; paused/IFblocked/cachehit cases need ledger evidence. Record old legacyRB hit offers and added admissions.'},'required_checks':['before/ACK0 exact full scoped RF+RFB/SPSR state, words/order, edges, all published values and canonical/DS30 guard/context checks','ACK1 same selected word sequence/payload/CPSR; full scoped RF state retained and differences inspected; r2-r5 and both RF copies must match per list; timers/call-count state differences explicitly classified','All22canonical +31quiet +32memory rows retained with DS denominators; unchanged accepted scopes are regression controls only','Source/profile/input/model hashes before and after; actual host child PID/starttime/NI and reaped status','Actual P7 admission, physical ACK, availability vs accept, RP/RB owner, word/beat/address, phase/run/IFwait, ARM9/fabric/MR/PSRAM contention ledger; assert same captured physical backing at actual CPU consume','Stop first value/owner corruption. Timing regressions remain data, never hidden; no margin, blanket waits, probes, LDM8 change or generic ACK.'],'open_gates':'No game/audio/enabled area/67MHz or absent simultaneous DMA/sound deadline qualification implied.'}
save(D/'plan.json',plan)
save(D/'frozen.json',{'plan_SHA256':H(D/'plan.json'),'source_profile_SHA256':{n:H(D/n/'source-profile.json')for n in variants},'runner_SHA256':H(P/'run.py')})
print(json.dumps({'plan':str(D/'plan.json'),'plan_SHA256':H(D/'plan.json'),'execute':['python3',str(P/'run.py'),'--plan',str(D/'plan.json'),'--execute'],'models':'not built; SHA256 recorded after each authorized build','source_delta':changed}))
