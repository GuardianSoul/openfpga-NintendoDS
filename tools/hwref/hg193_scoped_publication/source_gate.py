#!/usr/bin/env python3
"""Audit bound publication writes and generate a default-off per-clause proposal.

This is a conservative audit of this pinned simulation adapter, not a general
SystemVerilog parser. Source hashes plus a strict hierarchical-write namespace
and a closed task/function call set make the scope explicit and reviewable.
"""
import argparse,hashlib,json,re
from pathlib import Path
HERE=Path(__file__).resolve().parent
NAMES=['hg193_sd_pair.svh','hg193_context.svh','hg193_cold_apply.svh','hg193_cold_verify.svh','hg193_profile.svh','hg193_shared_model_binding.svh','runtime_import_finalize_snapshots.svh','runtime_import_gx_sd_ready.svh']
GPU='$root.tb_ds_pocket.dut.ds.g_3d.u_gpu3d'
MACROS={'HG_GPU':GPU,'HG_GEOM':GPU+'.u_geom','HG_ENG':GPU+'.u_geom.u_eng','HG_FRONT':GPU+'.u_geom.u_front','HG_FIN':GPU+'.u_geom.u_eng.g_fu.u_fin','HG_STORE':GPU+'.g_ext.g_pair.u_store','HG_SD':GPU+'.g_ext.g_pair.u_canonical','HG_JOURNAL':GPU+'.g_ext.g_pair.u_store.u_journal','HG_RASTER':GPU+'.u_raster','HG_RING':GPU+'.g_ring.u_ringx','RUNTIME_FIN':GPU+'.u_geom.u_eng.g_fu.u_fin','RUNTIME_GX_STORE':GPU+'.g_ext.g_pair.u_store','RUNTIME_GX_SD_ADAPTER':GPU+'.g_ext.g_pair.u_canonical'}

def sha(s):return hashlib.sha256(s.encode()).hexdigest()
def code(s):return re.sub(r'//[^\n]*|/\*[\s\S]*?\*/','',s)
def expand(lhs):
 for k,v in sorted(MACROS.items(),key=lambda x:-len(x[0])):lhs=lhs.replace('`'+k,v)
 return lhs
# Every hierarchical deposit, including all array/generate-index selections.
LV=re.compile(r'(?<![\w.$`])([`$A-Za-z_][\w`$.]*(?:\[[^\]\n]*\])?(?:\.[A-Za-z_][\w$]*(?:\[[^\]\n]*\])?)*?)\s*(?<![<>=!])=(?!=)')
def audit(sources):
 writes=[];calls=set();declared=set()
 for name,text in sources.items():
  text=code(text)
  for include in re.findall(r'`include\s+"([^"]+)"',text):assert include in sources,('unbound include',name,include)
  for target in re.findall(r'\$readmemh\([^;]*?,\s*([^),]+)\)',text):assert re.fullmatch(r'hg193_\w+',target),('foreign readmemh target',name,target)
  declared.update(re.findall(r'(?:task|function)\s+automatic\s+(?:\w+(?:\[[^]]+\])?\s+)?(\w+)\s*[;(]',text))
  for m in LV.finditer(text):
   lhs=m[1];target=expand(lhs)
   if '.' in lhs or lhs.startswith('`'):
    assert target.startswith(GPU+'.')or target.startswith('sdram_chip.mem['),(name,'foreign write',target)
    writes.append(dict(file=name,line=text[:m.start()].count('\n')+1,lvalue=lhs,target=target))
  assert not re.search(r'\b(force|release|wait)\b|@\s*\(|#\s*\d',re.sub(r'"(?:\\.|[^"\\])*"','""',text)),(name,'clock/control side effect')
  # Comments and string literals cannot invent calls in this check.
  scan=re.sub(r'"(?:\\.|[^"\\])*"','""',text)
  calls.update(re.findall(r'(?<![\w.])([a-zA-Z_$][\w$]*)\s*\(',scan))
 known={'assert','if','for','while','int','bit','logic','$fatal','$display','$readmemh','$bits','sd_index','sd_poke32','sd_peek32','hg193_assert_gx_sd_pair_drained','hg193_gx_sd_pair_drained','index'}
 # User tasks/functions remain closed. Intrinsics/casts have no DUT writes.
 unknown=calls-declared-known
 assert not unknown,('unknown calls',sorted(unknown),sorted(declared))
 assert any(w['target'].startswith('sdram_chip.mem[')for w in writes)
 assert any(w['target']==GPU+'.g_ext.g_pair.u_store.ready'for w in writes)
 publisher=sources['hg193_sd_pair.svh']
 assert "for(int i=0;i<131072;i++)sd_poke32(24'h1a0000+24'(i),hg193_packets[i]);"in publisher
 return dict(hierarchical_deposits=writes,calls=sorted(calls),tasks_functions=sorted(declared),gpu_root=GPU,sdram_word_range=['1a0000','1bffff'],protected_roots=['dut.ds.u_cpud','dut.ds.u_fab','dut.ds.u_mrarb','dut.psram','dut.g_mbox.commands','bridge_*','PSRAM chip model','boot SRAM'],disjoint=True)

def generate(original):
 # Replace only the explicitly observed false clauses, keeping all residual
 # predicates and all eleven family terms. No aggregate waiver is generated.
 replacements={
 'arm9_mem_publication_ready()':'hg193_scope_arm9()',
 '!dut.ds.u_cpud.g_a7c.u_p7.i_req':'hg193_scope_arm7()',
 '!dut.ds.u_cpud.g_a7c.u_p7.d_req':'hg193_scope_arm7()',
 '!dut.ds.u_cpud.g_a7c.u_p7.rp_v':'hg193_scope_arm7()',
 '!dut.ds.u_cpud.g_a7c.u_p7.busy':'hg193_scope_arm7()',
 '!dut.ds.u_cpud.g_a7c.u_p7.f_req':'hg193_scope_arm7()',
 '!dut.ds.u_cpud.c_b9_req':'hg193_scope_arm9()',
 '!dut.ds.u_cpud.c_f7_req':'hg193_scope_arm7()',
 '!dut.ds.u_cpud.b9_req':'hg193_scope_arm9()',
 '!dut.ds.u_cpud.f7_req':'hg193_scope_arm7()',
 'dut.ds.u_fab.st==dut.ds.u_fab.S_IDLE':'hg193_scope_arm9()',
 '!dut.psram.s_rvalid':'hg193_scope_arm9()',
 '!dut.mr_rvalid':'hg193_scope_arm9()',
 '!bridge_rd':'hg193_scope_bridge()'}
 text=original[:original.index('task automatic assert_hg193_combined_drained')]
 before=text
 for old,scope in replacements.items():
  assert text.count(old)==1,(old,text.count(old))
  text=text.replace(old,'('+old+' || (HG193_SCOPED_DEFAULT_ENABLE && '+scope+'))')
 text=text.replace('hg193_drain_','hg193_ready_').replace('hg193_combined_transport_drained','hg193_scoped_transport_ready')
 # Reverse transformation must recover the original family functions and aggregate exactly.
 restored=text.replace('hg193_ready_','hg193_drain_').replace('hg193_scoped_transport_ready','hg193_combined_transport_drained')
 for old,scope in replacements.items():restored=restored.replace('('+old+' || (HG193_SCOPED_DEFAULT_ENABLE && '+scope+'))',old)
 assert restored==before
 return text,dict(affected_clauses=len(replacements),original_source_sha256=sha(original),default_enable=0,reverse_transform_exact=True,unaffected_families=['internal_wram','rom65_phase_caller','sdram_ports','fifo_ownership','sdram_controller_and_return'])
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--host',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();a.out.mkdir(parents=True,exist_ok=False)
 sources={n:(a.host/'include'/n).read_text()for n in NAMES}
 tb=(a.host/'capture-bindings/tb_ds_pocket.sv').read_text()
 for name in ['sd_index','sd_poke32']:
  m=re.search(r'(?:function|task) automatic [^\n]*\b'+name+r'\([\s\S]*?end(?:function|task)',tb);assert m,name
  sources[name+'.svh']=m[0]+'\n'
 # Peek only reads the chip. It cannot deposit into a protected root.
 sources['sd_peek32.svh']=re.search(r'function automatic [^\n]*\bsd_peek32\([\s\S]*?endfunction',tb)[0]+'\n'
 for n,s in sources.items():(a.out/n).write_text(s)
 result=audit(sources);result['source_sha256']={n:sha(s)for n,s in sources.items()}
 faults={}
 for name,addition in [('cpu_write','\ndut.ds.u_cpud.g_a7c.u_p7.rb_d=0;'),('reply_write','\ndut.g_mbox.commands.bridge_rd_data=0;'),('unknown_task','\nforeign_deposit();')]:
  bad=dict(sources);bad['hg193_cold_apply.svh']+=addition
  try:audit(bad)
  except AssertionError as e:faults[name]=dict(caught=True,reason=str(e))
  else:raise AssertionError(name+' escaped')
 original=(a.host/'include/hg193_combined_drain.svh').read_text()
 proposal,guards=generate(original);(a.out/'original_combined_drain.svh').write_text(original);(a.out/'generated_scoped_drain.svh').write_text(proposal)
 result.update(guard_proposal=guards,source_mutants=faults,scope='Static disjoint write-set and per-clause proposal only; no actual publisher execution, readiness admission, cache correctness or fullscene claim.')
 (a.out/'source-gate.json').write_text(json.dumps(result,indent=2)+'\n');print('SOURCE_GATE_PASS',len(result['hierarchical_deposits']))
if __name__=='__main__':main()
