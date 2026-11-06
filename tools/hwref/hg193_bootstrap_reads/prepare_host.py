#!/usr/bin/env python3
"""Stage the single strict HG owner diagnostic; no compile or model run."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'hg193_combined_hook'))
from prepare_diagnostics import make as diagnostics
import check_observed
from check_capture import check_assertion_bindings

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def prepare(parent,out,component):
 parent,out=parent.resolve(),out.resolve();component=component.resolve();assert not out.exists() and parent!=out
 old=json.loads((parent/'composition.json').read_text())
 assert old['source']=='690b22e8e528f2d55e998967a9fb62b6a82ff333' and len(old['profile'])==60
 for n,h in old['copies_sha256'].items():assert sha(parent/n)==h,n
 pin=json.loads((parent/'model-pin.json').read_text());assert sha(Path(pin['binary_path']))==pin['binary_sha256']=='e38360b2ecbfbe187093e9a480d29352b906fddcdd54d0ed2fb1fd199a5c7557'
 out.mkdir(parents=True)
 folders=['snapshot','include','observed-overlay','capture-bindings','wram-expected','lifecycle-source']
 for n in folders:shutil.copytree(parent/n,out/n)
 for n in ['edits.json','wram-input-contract.json','parent-composition.json','publication-contract.json','current41-source-rebind.json','capture-source-rebind.json']:
  shutil.copyfile(parent/n,out/n)
 diagnostics(parent,out/'owner-diagnostics')
 shutil.copyfile(out/'owner-diagnostics/all-publication-diagnostics.svh',out/'include/all-publication-diagnostics.svh')
 for n in ['predicate.svh','caller.svh']:shutil.copyfile(HERE/n,out/'include'/n)
 adapter='''// Exact single-clock caller; every field is read-only.
`define HG_READ_MEM dut.ds.u_cpud.g_one.u_cpu.u_mem9
`define HG_READ_FAB dut.ds.u_fab
`define HG_READ_ARB dut.ds.u_mrarb
`define HG_READ_PHY dut.psram
`define HG_READ_CLK dut.clk_sys
`define HG_READ_RST dut.rst_sys
`define HG_READ_FETCH_PC dut.ds.u_cpud.g_one.u_cpu.u_core.fetch_pc[0]
`define HG_READ_DOMAIN_MATCH (dut.CPU_FAST==0 && dut.A9_SOLO==5 && dut.ds.u_cpud.c_b9_req===dut.ds.u_cpud.b9_req && dut.ds.u_cpud.b9_req===dut.ds.u_fab.a9_req && (!dut.ds.u_cpud.b9_req || (dut.ds.u_cpud.c_b9_addr===dut.ds.u_cpud.b9_addr && dut.ds.u_cpud.b9_addr===dut.ds.u_fab.a9_addr && dut.ds.u_cpud.c_b9_we===dut.ds.u_fab.a9_we && !dut.ds.u_cpud.b9_n8 && dut.ds.u_cpud.c_b9_ack===dut.ds.u_fab.a9_ack)))
`include "caller.svh"
function automatic bit hg193_actual_stub_bytes_match();
 if(imp_ov!='hc2400 || imp_stubn!='h89)return 0;
 for(int i=0;i<137;i++)
  if({cram1.peek(imp_ov+i),cram0.peek(imp_ov+i)}!==imp_main[imp_ov+i])return 0;
 return 1;
endfunction
task automatic hg193_actual_caller_point;
 hg193_bootstrap_reads::view_t v;
 bit original_phase;
 original_phase=imp_vc==193 && dut.line_start && dut.vcount==193 && !dut.clk_sys && !dut.clk_2x && !imp_stub_pend;
 v=hg193_actual_read_view(hg193_combined_held,original_phase,hg193_actual_stub_bytes_match());
 hg193_actual_read_diagnostics();
 $display("HG193_CALLER held=%0b phase=%0b stub_bytes=%0b fetch_pc=%08h known=%0b shadow_permit=%0b defaultoff=%0b",v.held,v.phase_original,v.stub_bytes_match,v.fetch_pc,v.owner_snapshot_complete,hg193_bootstrap_reads::permit(0,1,v),hg193_actual_caller_defaultoff(0,v.held,v.phase_original,v.stub_bytes_match));
endtask
`undef HG_READ_MEM
`undef HG_READ_FAB
`undef HG_READ_ARB
`undef HG_READ_PHY
`undef HG_READ_CLK
`undef HG_READ_RST
`undef HG_READ_FETCH_PC
`undef HG_READ_DOMAIN_MATCH
'''
 (out/'include/hg193_actual_caller.svh').write_text(adapter)
 hook=out/'include/hg193_combined_hook.svh';s=hook.read_text();marker='`include "hg193_publication_diagnostics.svh"'
 inc=marker+'\n`include "hg193_actual_caller.svh"\n`include "all-publication-diagnostics.svh"'
 assert s.count(marker)==1;s=s.replace(marker,inc)
 line=' hg193_publication_diagnostics("before-publication");\n';calls=line+' hg193_actual_caller_point();\n hg193_all_publication_diagnostics(hg193_combined_directory);\n'
 assert s.count(line)==1;s=s.replace(line,calls);hook.write_text(s)
 assert s.replace(inc,marker).replace(calls,line)==(parent/'include/hg193_combined_hook.svh').read_text()
 assert sha(out/'include/hg193_combined_drain.svh')==sha(parent/'include/hg193_combined_drain.svh')
 for n,module,instance in [('full_game_capture_contract.sv','nds_full_game_capture_contract','u_full_game_capture_contract'),('current41_binding.sv','nds_capture41_binding','u_capture41_binding')]:
  q=out/'observed-overlay'/n;s=q.read_text();assert 'bind tb_ds_pocket'not in s
  if module=='nds_full_game_capture_contract':
   marker='    else $fatal(1,"FULL_GAME_CAPTURE_LDM_WRAM_REQUIRED");'
   assert s.count(marker)==1;s=s.replace(marker,marker+'\n   $display("STRICT_HG_BOUND_LAUNCH_CONTRACT_PASS");')
  q.write_text(s+f'\nbind tb_ds_pocket {module} {instance}();\n')
 check_assertion_bindings(out,['full_game','current41'])
 plan=json.loads((parent/'game-build-plan.json').read_text());argv=[v.replace(str(parent)+'/',str(out)+'/')for v in plan['argv']]
 tb=str(out/'observed-overlay/tb_native52_import.sv');assert tb in argv
 argv.insert(argv.index(tb),str(out/'include/predicate.svh'))
 plan.update(argv=argv,cwd=plan['cwd'].replace(str(parent),str(out)),state='STRICT_HG_ACTUAL_OWNER_DIAGNOSTIC_ONLY')
 write(out/'game-build-plan.json',plan)
 inputs={str(q.relative_to(out)):sha(q)for n in folders for q in (out/n).rglob('*')if q.is_file()and q.name!='hg193_shared_model_binding.svh'}
 h=hashlib.sha256(json.dumps(inputs,sort_keys=True).encode()).hexdigest()
 q=out/'include/hg193_shared_model_binding.svh';q.write_text(q.read_text().replace(old['compiled_input_binding_sha256'],h))
 copies={str(q.relative_to(out)):sha(q)for n in folders for q in (out/n).rglob('*')if q.is_file()}
 binding=dict(old,copies_sha256=copies,staged_binding_inputs_sha256=inputs,compiled_input_binding_sha256=h,
  assertion_bindings_required=['full_game','current41'],build_plan_sha256=sha(out/'game-build-plan.json'),binary_sha256=None)
 write(out/'composition.json',binding)
 write(out/'model-pin.pending.json',dict(state='PENDING_ONE_STRICT_HG_DIAGNOSTIC_BUILD',source=old['source'],composition_sha256=sha(out/'composition.json'),game_build_plan_sha256=binding['build_plan_sha256'],actual_compile_argv_sha256=hashlib.sha256(json.dumps(argv).encode()).hexdigest(),build_exit=None,binary_path=None,binary_sha256=None))
 checks=check_observed.check(out)
 changed={n:dict(parent=old['copies_sha256'].get(n),current=h)for n,h in copies.items()if old['copies_sha256'].get(n)!=h}
 assert all(not n.startswith('snapshot/')for n in changed)
 for n in changed:
  assert n in ['include/hg193_combined_hook.svh','include/hg193_shared_model_binding.svh','include/all-publication-diagnostics.svh','include/hg193_actual_caller.svh','include/predicate.svh','include/caller.svh','observed-overlay/full_game_capture_contract.sv','observed-overlay/current41_binding.sv'],n
 write(out/'owner-source-check.json',dict(source=old['source'],profile_fields=60,parent_model=pin['binary_sha256'],production_source_unchanged=True,original_strict_guards_byte_identical=True,hook_reconstructs_parent=True,default_enable=0,all_diagnostic_clauses=456,changed=changed,source_identity=checks,qualification='Read-only caller; original first fatal remains; no waits/waivers/DUT writes or rollout. Future actual bind fix included; no inherited unbound-assertion execution claim.'))
 # Bind original argv, cwd and every input before any native launch.
 component_result=json.loads((component/'complete.json').read_text())
 assert component_result['actual_transport_positive'] and component_result['actual_live_fabric_master_fault_caught']
 for n in ['predicate.svh','caller.svh']:assert (out/'include'/n).read_bytes()==(component/'source'/n).read_bytes()
 for n in ['complete.json','model.json','source-binding.json']:shutil.copyfile(component/n,out/('component-'+n))
 original=json.loads((parent/'runtime-checks/run-plan.json').read_text())['cases'][0]
 assert original['name']=='hg85-boundary'
 argv=list(original['argv']);argv[0]=str(out/'private-game-obj/Vtb_ds_pocket')
 for i,arg in enumerate(argv):
  if arg.startswith(('+shots=','+savout=','+scene_capture_prefix=')):
   leaf='shots' if arg.startswith('+shots=') else 'save.bin' if arg.startswith('+savout=') else 'capture/capture'
   argv[i]=arg.split('=',1)[0]+'='+str(out/'diagnostic'/leaf)
  if arg.startswith('+g3d_seed='):argv[i]='+g3d_seed='+str(out/'include')
 (out/'diagnostic/shots').mkdir(parents=True);(out/'diagnostic/capture').mkdir()
 write(out/'diagnostic/argv.json',argv)
 image=Path(next(arg.split('=',1)[1]for arg in argv if arg.startswith('+imp_main=')))
 words=[int(word,16)for word in image.read_text().split()]
 stub=b''.join(word.to_bytes(4,'little')for word in words[0xc2400:0xc2400+137])
 assert stub==(out/'lifecycle-source/sw/stateload/stateload.bin').read_bytes()
 write(out/'stub-byte-binding.json',dict(bytes=548,words=137,offset_words=0xc2400,sha256=hashlib.sha256(stub).hexdigest(),actual_input_sha256=sha(image),runtime_check='all137actual paired-chip words compare with same bound imp_main before original first fatal'))
 mbox=Path(original['cwd'])/'mbox.hex'
 write(out/'diagnostic/cwd-binding.json',dict(original_cwd=original['cwd'],mbox_sha256=sha(mbox),original_run_plan_sha256=sha(parent/'runtime-checks/run-plan.json'),original_input_sha256=original['input_sha256'],parent=str(parent)))
 from launch_directory import check as check_directory
 cwd=json.loads((out/'diagnostic/cwd-binding.json').read_text());check_directory(cwd)
 rejected=[]
 for name,bad in [('wrong-working-directory',dict(cwd,original_cwd=str(out))),('wrong-mailbox-hash',dict(cwd,mbox_sha256='0'*64))]:
  try:check_directory(bad)
  except AssertionError:rejected.append(name)
  else:raise AssertionError('bad launch cwd accepted')
 write(out/'cwd-source-check.json',dict(positive=True,mutations_rejected=rejected,models_executed=0))
 return out
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--parent',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--component',type=Path,required=True);a=p.parse_args();print(prepare(a.parent,a.out,a.component))
