#!/usr/bin/env python3
"""Bound native-source controls; no compiler, ELF or raw-capture access."""
import argparse,hashlib,json,re
from pathlib import Path
from source_gate import generate,code,LV

def check(host,parent):
 checkdata=json.loads((host/'native-source-check.json').read_text());hook=(host/'include/hg193_combined_hook.svh').read_text()
 for edit in reversed(checkdata['hook_edits']):
  assert hook.count(edit['new'])==edit['count'];hook=hook.replace(edit['new'],edit['old'])
 assert hook==(parent/'include/hg193_combined_hook.svh').read_text()
 for name in ['hg193_sd_pair.svh','hg193_combined_drain.svh','runtime_import_gx_sd_ready.svh']:
  assert(host/'include'/name).read_bytes()==(parent/'include'/name).read_bytes(),name
 tb=(host/'observed-overlay/tb_native52_import.sv').read_text();assert tb==(parent/'observed-overlay/tb_native52_import.sv').read_text()
 proposal,_=generate((host/'include/hg193_combined_drain.svh').read_text())
 assert proposal.replace('HG193_SCOPED_DEFAULT_ENABLE &&','(HG193_SCOPED_DEFAULT_ENABLE || hg193_proposal_enable) &&')==(host/'include/generated_native_scoped_drain.svh').read_text()
 proof=(host/'include/native_proof.svh').read_text()
 assert proof.count('hg193_proposal_enable=$test$plusargs("hg193_scoped_publication");')==1
 assert len(re.findall(r'\bhg193_proposal_enable\s*=(?!=)',proof))==2 # declaration0 and exact plusarg
 assert 'bit hg193_proposal_enable=0,'in proof
 assert 'localparam bit HG193_SCOPED_DEFAULT_ENABLE=0;'in(host/'include/scoped.svh').read_text()
 for name in ['native_proof.svh','protected-state.svh']:
  text=code((host/'include'/name).read_text())
  assert not re.search(r'\b(?:force|release|wait)\b|#',re.sub(r'"[^"\n]*"','',text)),name
  for m in LV.finditer(text):
   assert not m[1].startswith(('dut.','cram0.','cram1.','bridge_','clk_')),(name,'DUT write',m[1])
 schema=json.loads((host/'protected-schema.json').read_text());snapshot=(host/'include/protected-state.svh').read_text()
 for i,row in enumerate(schema['fields']):
  idx=''.join('[hg_k'+str(k)+']'for k in range(len(row['dimensions'])))
  assert f"hg_saved_{i}{idx}={row['path']}{idx};"in snapshot
  assert f"assert({row['path']}{idx}===hg_saved_{i}{idx})else"in snapshot
 if (host/'include/native_time_pkg.sv').exists():
  tick=(host/'include/native_time_pkg.sv').read_text()
  assert 'timeunit 1ps;'in tick and 'timeprecision 1ps;'in tick and 'return $time;'in tick
  assert "ORIGINAL_TICKS_PS=64'd129210695256"in tick
  assert 'hg193_native_time::exact(hg193_native_time::now_ps())'in proof
  assert 'hg193_native_time::now_ps()==hg_native_publication_ticks'in proof
 assert 'hg193_protected_capture();'in proof and 'hg193_protected_verify();'in proof
 assert '$realtime==hg_native_publication_time'in proof
 args=json.loads((host/'diagnostic/argv.json').read_text());oldargs=json.loads((parent/'diagnostic/argv.json').read_text())
 normal=[s.replace(str(host),str(parent))for s in args if s!='+hg193_scoped_publication'];assert normal==oldargs
 assert args.count('+hg193_scoped_publication')==1
 for module in ['full_game_capture_contract.sv','current41_binding.sv','observer_contract.sv']:
  assert(host/'observed-overlay'/module).read_bytes()==(parent/'observed-overlay'/module).read_bytes(),module
 return dict(default_hook_reconstructs_exact=True,publisher_importer_guards_key_schedule_unchanged=True,only_runtime_flag_expands_scope=True,new_proof_has_no_DUT_deposits_or_waits=True,native_argv_only_model_history_directory_and_flag_changed=True)
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--host',required=True,type=Path);p.add_argument('--parent',required=True,type=Path);p.add_argument('--out',required=True,type=Path);a=p.parse_args();r=check(a.host.resolve(),a.parent.resolve());a.out.write_text(json.dumps(r,indent=2)+'\n');print('NATIVE_SOURCE_CONTROLS_PASS')
if __name__=='__main__':main()
