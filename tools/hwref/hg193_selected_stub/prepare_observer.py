#!/usr/bin/env python3
"""Bind one compact observer-only HG host, preserving the frozen strict path."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'hg193_combined_hook'))
import check_observed
from check_capture import check_assertion_bindings

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,d):p.write_text(json.dumps(d,indent=2)+'\n')
def check_observer_bind(text):
 assert re.search(r'^\s*bind\s+tb_ds_pocket\s+hg193_observer_contract\s+\w+\s*\(',text,re.M),'observer contract unbound'
def erase_observer(hook):
 return hook.replace('`include "hg193_actual_caller.svh"\n`include "bridge-history.svh"\n`include "missing-discriminators.svh"','`include "hg193_actual_caller.svh"').replace(' hg193_missing_discriminators();\n','')
def prepare(parent,lint,observations,out):
 parent,lint,observations,out=[p.resolve()for p in [parent,lint,observations,out]];assert not out.exists()
 old=json.loads((parent/'composition.json').read_text());assert old['source']=='690b22e8e528f2d55e998967a9fb62b6a82ff333'and len(old['profile'])==60
 for n,h in old['copies_sha256'].items():assert sha(parent/n)==h,n
 pin=json.loads((parent/'model-pin.json').read_text());assert sha(Path(pin['binary_path']))==pin['binary_sha256']=='b0fffeeb4a7ec0173f63757fa2a67a6f5b7b0c88b7465003d2a3e74935b51be7'
 assert json.loads((lint/'complete.json').read_text())['exit']==0
 lintinputs=json.loads((lint/'input-binding.json').read_text())
 for n in ['matcher.svh','bridge-history.svh','missing-discriminators.svh']:
  assert sha(observations/n)==lintinputs['include/'+n]
  assert (lint/'include'/n).read_bytes()==(observations/n).read_bytes()
 old_hook=(parent/'include/hg193_combined_hook.svh').read_text();new_hook=(lint/'include/hg193_combined_hook.svh').read_text();assert erase_observer(new_hook)==old_hook
 assert (lint/'include/hg193_combined_drain.svh').read_bytes()==(parent/'include/hg193_combined_drain.svh').read_bytes()
 out.mkdir(parents=True)
 folders=['snapshot','include','observed-overlay','capture-bindings','wram-expected','lifecycle-source']
 for n in folders:shutil.copytree(parent/n,out/n)
 for n in ['edits.json','wram-input-contract.json','parent-composition.json','publication-contract.json','current41-source-rebind.json','capture-source-rebind.json','component-complete.json','component-model.json','component-source-binding.json','stub-byte-binding.json']:
  shutil.copyfile(parent/n,out/n)
 for n in ['matcher.svh','bridge-history.svh','missing-discriminators.svh']:shutil.copyfile(observations/n,out/'include'/n)
 (out/'include/hg193_combined_hook.svh').write_text(new_hook)
 contract='''// Compact observation launch only. No original readiness guard replaced.
module hg193_observer_contract;
 timeunit 1ns;timeprecision 1ps;
 initial begin
  integer frames,vc;string kind;
  #1;
  assert(!$test$plusargs("scene_capture_prefix=") && !$test$plusargs("root40_ldm_capture") && !$test$plusargs("fst="))
   else $fatal(1,"HG193_OBSERVER_FORBIDS_FULL_DUMPS");
  assert($value$plusargs("frames=%d",frames) && frames==85 &&
   $value$plusargs("imp_vcount=%d",vc) && vc==193 &&
   $value$plusargs("g3d_seed_kind=%s",kind) && kind=="hg193" &&
   $test$plusargs("combined_wram_restore"))else $fatal(1,"HG193_OBSERVER_ORIGINAL_WINDOW_REQUIRED");
  assert(hg193_bootstrap_reads::PROPOSAL_DEFAULT_ENABLE==0)
   else $fatal(1,"HG193_OBSERVER_PROPOSAL_MUST_REMAIN_OFF");
  $display("HG193_COMPACT_OBSERVER_BOUND_DEFAULT0_NO_FULL_DUMPS_PASS");
 end
endmodule
bind tb_ds_pocket hg193_observer_contract u_hg193_observer_contract();
'''
 check_observer_bind(contract);(out/'observed-overlay/observer_contract.sv').write_text(contract)
 oldplan=json.loads((parent/'game-build-plan.json').read_text());argv=[v.replace(str(parent)+'/',str(out)+'/')for v in oldplan['argv']]
 tb=str(out/'observed-overlay/tb_native52_import.sv');argv.insert(argv.index(tb),str(out/'include/matcher.svh'));argv.append(str(out/'observed-overlay/observer_contract.sv'))
 plan=dict(oldplan,argv=argv,cwd=oldplan['cwd'].replace(str(parent),str(out)),state='ONE_REQUIRED_COMPACT_HG_OBSERVER_ONLY_MODEL');write(out/'game-build-plan.json',plan)
 inputs={str(p.relative_to(out)):sha(p)for n in folders for p in(out/n).rglob('*')if p.is_file()and p.name!='hg193_shared_model_binding.svh'}
 digest=hashlib.sha256(json.dumps(inputs,sort_keys=True).encode()).hexdigest();q=out/'include/hg193_shared_model_binding.svh';q.write_text(q.read_text().replace(old['compiled_input_binding_sha256'],digest))
 copies={str(p.relative_to(out)):sha(p)for n in folders for p in(out/n).rglob('*')if p.is_file()}
 binding=dict(old,copies_sha256=copies,staged_binding_inputs_sha256=inputs,compiled_input_binding_sha256=digest,build_plan_sha256=sha(out/'game-build-plan.json'),binary_sha256=None)
 write(out/'composition.json',binding)
 write(out/'model-pin.pending.json',dict(state='PENDING_ONE_COMPACT_OBSERVER_BUILD',source=old['source'],composition_sha256=sha(out/'composition.json'),game_build_plan_sha256=binding['build_plan_sha256'],actual_compile_argv_sha256=hashlib.sha256(json.dumps(argv).encode()).hexdigest(),build_exit=None,binary_path=None,binary_sha256=None))
 check_observed.check(out);check_assertion_bindings(out,['full_game','current41'])
 args=json.loads((parent/'diagnostic/argv.json').read_text());old_args=list(args);args[0]=str(out/'private-game-obj/Vtb_ds_pocket')
 removed=[];keep=[]
 for arg in args:
  if arg.startswith(('+scene_capture_prefix=','+shots=','+savout='))or arg=='+root40_ldm_capture':removed.append(arg);continue
  if arg.startswith('+g3d_seed='):arg='+g3d_seed='+str(out/'include')
  keep.append(arg)
 args=keep
 assert not any(a.startswith(('+scene_capture_prefix=','+fst='))or a=='+root40_ldm_capture'for a in args)
 (out/'diagnostic').mkdir();write(out/'diagnostic/argv.json',args);shutil.copyfile(parent/'diagnostic/cwd-binding.json',out/'diagnostic/cwd-binding.json')
 from launch_directory import check as check_directory
 # launch_directory lives with the existing qualified launcher.
 check_directory(json.loads((out/'diagnostic/cwd-binding.json').read_text()))
 changed={n:dict(before=old['copies_sha256'].get(n),after=h)for n,h in copies.items()if old['copies_sha256'].get(n)!=h}
 allowed={'include/hg193_combined_hook.svh','include/hg193_shared_model_binding.svh','include/matcher.svh','include/bridge-history.svh','include/missing-discriminators.svh','observed-overlay/observer_contract.sv'};assert set(changed)==allowed
 # Erasure is tested against the real parent; changing any original guard is caught.
 bad=new_hook.replace(' assert_hg193_combined_drained();'," assert(1'b1);",1);assert erase_observer(bad)!=old_hook
 try:check_observer_bind(contract.replace('bind tb_ds_pocket hg193_observer_contract','// missing binding: hg193_observer_contract'))
 except AssertionError:pass
 else:raise AssertionError('missing observer binding survived')
 result=dict(source=old['source'],profile_fields=60,parent_model=pin['binary_sha256'],new_source_files=changed,observer_erase_reconstructs_parent=True,all_original_guard_bytes_unchanged=True,default_enable=0,key_edges_unchanged=True,owner_debt_unchanged=True,history_publication_not_authorized=True,expected_time_ps=129210695000,expected_signals=192,expected_live_words=137,expected_bridge_histories=4,original_argv=old_args,compact_argv=args,output_only_removed=removed,source_faults_caught=['original-strict-call-replaced','new-contract-bind-missing'],raw_scans=0,old_models_executed=0)
 write(out/'observer-source-check.json',result);write(out/'observation-plan.json',json.loads((observations/'plan.json').read_text()))
 return result
if __name__=='__main__':
 sys.path.insert(0,str(HERE.parent/'hg193_bootstrap_reads'))
 p=argparse.ArgumentParser();p.add_argument('--parent',type=Path,required=True);p.add_argument('--lint',type=Path,required=True);p.add_argument('--observations',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();r=prepare(a.parent,a.lint,a.observations,a.out);print(json.dumps({k:r[k]for k in ['source','observer_erase_reconstructs_parent','expected_signals','expected_live_words','source_faults_caught']},indent=2))
