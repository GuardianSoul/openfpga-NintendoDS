#!/usr/bin/env python3
"""Bind one explicitly opted-in original-point publication host, no execution."""
import argparse,hashlib,json,re,shutil,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'hg193_combined_hook'))
import check_observed
from source_gate import generate
SOURCE='690b22e8e528f2d55e998967a9fb62b6a82ff333'

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def protected(header,out):
 prefixes=['dut.ds.u_cpud.','dut.ds.u_fab.','dut.ds.u_mrarb.','dut.psram.','dut.g_mbox.commands.']
 rows=[]
 for line in header.read_text().splitlines():
  m=re.fullmatch(r'\s*((?:CData|SData|IData|QData|VlWide<.*>|VlUnpacked<.*>)(?:/\*.*?\*/)?)[ ]+(tb_ds_pocket__DOT__[\w]+);',line)
  if not m:continue
  path=m[2].removeprefix('tb_ds_pocket__DOT__').replace('__DOT__','.').replace('__BRA__','[').replace('__KET__',']')
  if '__V'in path:continue
  if not(any(path.startswith(p)for p in prefixes)or path in ['bridge_addr','bridge_rd','bridge_wr','bridge_wr_data','bridge_rd_data','dut.keys','dut.mr_rvalid']):continue
  dtype=m[1];dims=[]
  while dtype.startswith('VlUnpacked<'):
   d=re.fullmatch(r'VlUnpacked<(.*), (\d+)>',dtype);assert d,dtype;dtype=d[1];dims.append(int(d[2]))
  assert re.fullmatch(r'(?:[CSIQ]Data|VlWide<\d+>)/\*\d+:0\*/',dtype),dtype
  rows.append(dict(path=path,dimensions=dims))
 assert len(rows)>1500
 # Add the live stub words/owned physical quad without copying the entire
 # PSRAM model. All backing-store writes are separately source-audited.
 declarations=[];capture=[];verify=[];elements=0
 for i,row in enumerate(rows):
  path=row['path'];dims=row['dimensions'];idx=''.join('[hg_k'+str(k)+']'for k in range(len(dims)))
  loops=''.join(f'for(int hg_k{k}=0;hg_k{k}<{n};hg_k{k}++)'for k,n in enumerate(dims))
  first=path+''.join('[0]'for _ in dims)
  declarations.append(f'logic[$bits({first})-1:0] hg_saved_{i}'+''.join(f'[{n}]'for n in dims)+';')
  capture.append(f' {loops} hg_saved_{i}{idx}={path}{idx};')
  verify.append(f' {loops} assert({path}{idx}===hg_saved_{i}{idx})else $fatal(1,"HG193_NATIVE_PROTECTED_CHANGED {path}");')
  n=1
  for d in dims:n*=d
  elements+=n
 declarations+=['logic[31:0]hg_saved_stub[137];']
 capture+=[' for(int i=0;i<137;i++)hg_saved_stub[i]={cram1.peek(imp_ov+i),cram0.peek(imp_ov+i)};']
 verify+=[' for(int i=0;i<137;i++)assert({cram1.peek(imp_ov+i),cram0.peek(imp_ov+i)}===hg_saved_stub[i])else $fatal(1,"HG193_NATIVE_STUB_CHANGED index%0d",i);']
 text='// Generated from the pinned control root header. No DUT writes.\n'+'\n'.join(declarations)+'\ntask automatic hg193_protected_capture;\n'+'\n'.join(capture)+'\nendtask\ntask automatic hg193_protected_verify;\n'+'\n'.join(verify)+f'\n $display("HG193_NATIVE_PROTECTED_READBACK_PASS fields={len(rows)} elements={elements} stub137");\nendtask\n'
 (out/'include/protected-state.svh').write_text(text)
 write(out/'protected-schema.json',dict(header_sha256=sha(header),header_path=str(header),fields=rows,field_count=len(rows),element_count=elements,stub_words=137,scope='Every retained original-header RTL leaf under CPU domain, fabric, MR arbiter, PSRAM controller and mailbox, excluding compiler temporaries; plus bridge aliases and137physicalstubwords. This is not a copy of all main PSRAM/ROM/SRAM backing memory. Static exact publisher write-set covers those disjoint stores.'))
 return len(rows),elements

def prepare(parent,out):
 parent=parent.resolve();out=out.resolve();assert not out.exists()
 old=json.loads((parent/'composition.json').read_text());assert old['source']==SOURCE and len(old['profile'])==60
 for n,h in old['copies_sha256'].items():assert sha(parent/n)==h,n
 pin=json.loads((parent/'model-pin.json').read_text());assert pin['binary_sha256']=='2ae334615d7c40c8f1dfd597449c8ffb9bb0d60510bca1b569686d90389d349a'
 # Read the retained control header, never execute or rescan old capture data.
 out.mkdir(parents=True);folders=['snapshot','include','observed-overlay','capture-bindings','wram-expected','lifecycle-source']
 for n in folders:shutil.copytree(parent/n,out/n)
 for n in ['edits.json','wram-input-contract.json','parent-composition.json','publication-contract.json','current41-source-rebind.json','capture-source-rebind.json','stub-byte-binding.json']:
  shutil.copyfile(parent/n,out/n)
 fields,elements=protected(parent/'private-game-obj/Vtb_ds_pocket___024root.h',out)
 for n in ['scoped.svh','native_proof.svh','native_time_pkg.sv']:shutil.copyfile(HERE/n,out/'include'/n)
 proposal,guard=generate((parent/'include/hg193_combined_drain.svh').read_text())
 native=proposal.replace('HG193_SCOPED_DEFAULT_ENABLE &&','(HG193_SCOPED_DEFAULT_ENABLE || hg193_proposal_enable) &&')
 assert native.replace('(HG193_SCOPED_DEFAULT_ENABLE || hg193_proposal_enable) &&','HG193_SCOPED_DEFAULT_ENABLE &&')==proposal
 (out/'include/generated_native_scoped_drain.svh').write_text(native)
 q=out/'include/hg193_combined_hook.svh';before=q.read_text();text=before
 changes=[]
 for oldpart,newpart in [
  ('`include "all-publication-diagnostics.svh"','`include "all-publication-diagnostics.svh"\n`include "native_proof.svh"'),
  (' assert_hg193_combined_drained();',' if(hg193_proposal_enable)hg193_native_assert_ready();\n else assert_hg193_combined_drained();'),
  (' hg193_publish(hg193_combined_directory,hg193_combined_held,hg193_combined_transport_drained());',' if(hg193_proposal_enable)hg193_native_before();\n hg193_publish(hg193_combined_directory,hg193_combined_held,hg193_native_ready());'),
  (' hg193_combined_release_clocks();',' if(hg193_proposal_enable)hg193_native_after();\n hg193_combined_release_clocks();')]:
  count=text.count(oldpart);assert count==(2 if oldpart==' assert_hg193_combined_drained();'else 1),(oldpart,count)
  text=text.replace(oldpart,newpart);changes.append(dict(old=oldpart,new=newpart,count=count))
 restored=text
 for c in reversed(changes):assert restored.count(c['new'])==c['count'];restored=restored.replace(c['new'],c['old'])
 assert restored==before;q.write_text(text)
 assert(out/'include/hg193_combined_drain.svh').read_bytes()==(parent/'include/hg193_combined_drain.svh').read_bytes()
 assert(out/'include/hg193_sd_pair.svh').read_bytes()==(parent/'include/hg193_sd_pair.svh').read_bytes()
 assert(out/'observed-overlay/tb_native52_import.sv').read_bytes()==(parent/'observed-overlay/tb_native52_import.sv').read_bytes()
 oldplan=json.loads((parent/'game-build-plan.json').read_text());argv=[v.replace(str(parent)+'/',str(out)+'/')for v in oldplan['argv']]
 argv.insert(argv.index(str(out/'observed-overlay/tb_native52_import.sv')),str(out/'include/native_time_pkg.sv'))
 plan=dict(oldplan,argv=argv,cwd=oldplan['cwd'].replace(str(parent),str(out)),state='ONE_EXPLICIT_SCOPED_PUBLICATION_BUILD_STOP_AFTER_PENDING_COMPLETIONS');write(out/'game-build-plan.json',plan)
 inputs={str(p.relative_to(out)):sha(p)for n in folders for p in(out/n).rglob('*')if p.is_file()and p.name!='hg193_shared_model_binding.svh'}
 digest=hashlib.sha256(json.dumps(inputs,sort_keys=True).encode()).hexdigest();q=out/'include/hg193_shared_model_binding.svh';q.write_text(q.read_text().replace(old['compiled_input_binding_sha256'],digest))
 copies={str(p.relative_to(out)):sha(p)for n in folders for p in(out/n).rglob('*')if p.is_file()}
 binding=dict(old,copies_sha256=copies,staged_binding_inputs_sha256=inputs,compiled_input_binding_sha256=digest,build_plan_sha256=sha(out/'game-build-plan.json'),binary_sha256=None)
 write(out/'composition.json',binding)
 write(out/'model-pin.pending.json',dict(state='PENDING_ONE_EXPLICIT_SCOPED_PUBLICATION_BUILD',source=SOURCE,composition_sha256=sha(out/'composition.json'),game_build_plan_sha256=sha(out/'game-build-plan.json'),actual_compile_argv_sha256=hashlib.sha256(json.dumps(argv).encode()).hexdigest(),build_exit=None,binary_path=None,binary_sha256=None))
 check_observed.check(out)
 args=json.loads((parent/'diagnostic/argv.json').read_text());args[0]=str(out/'private-game-obj/Vtb_ds_pocket')
 args=[('+g3d_seed='+str(out/'include')if x.startswith('+g3d_seed=')else x)for x in args];args.append('+hg193_scoped_publication')
 (out/'diagnostic').mkdir();write(out/'diagnostic/argv.json',args);shutil.copyfile(parent/'diagnostic/cwd-binding.json',out/'diagnostic/cwd-binding.json')
 # Keep all publisher files byte-identical; only separate opt-in hook and
 # observation functions differ. Default hook erasure is exact, no time step.
 result=dict(source=SOURCE,profile=60,parent_model=pin['binary_sha256'],hook_edits=changes,parent_hook_sha256=sha(parent/'include/hg193_combined_hook.svh'),default_hook_reconstructs_exact=True,default_enable=0,proposal_flag='+hg193_scoped_publication',original_publisher_byte_identical=True,original_drain_byte_identical=True,original_importer_key_and_clock_schedule_byte_identical=True,guard_proposal=guard,protected_fields=fields,protected_elements=elements,expected_console_time_ps=129210695000,expected_publication_time_ps=129210695256,time_precision_ps=1,new_game_builds_admitted=1,new_native_invocations_admitted=1,forbidden=['new_fullscene','rawdump','unchanged_baseline','forced_ACK','readiness_wait','new_key_edge'])
 write(out/'native-source-check.json',result)
 return result
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--parent',required=True,type=Path);p.add_argument('--out',required=True,type=Path);a=p.parse_args();r=prepare(a.parent,a.out);print(json.dumps({k:r[k]for k in ['source','profile','protected_fields','protected_elements','expected_publication_time_ps']},indent=2))
