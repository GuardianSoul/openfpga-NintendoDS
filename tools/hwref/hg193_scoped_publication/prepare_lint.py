#!/usr/bin/env python3
"""Elaborate the disabled proposal in the actual profile60 hierarchy, no model."""
import argparse,hashlib,json,shutil
from pathlib import Path
HERE=Path(__file__).resolve().parent

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--parent',required=True,type=Path);p.add_argument('--gate',required=True,type=Path);p.add_argument('--out',required=True,type=Path);a=p.parse_args();parent=a.parent.resolve();out=a.out.resolve();out.mkdir(parents=True,exist_ok=False)
 for n in ['snapshot','include','observed-overlay','capture-bindings','wram-expected','lifecycle-source']:shutil.copytree(parent/n,out/n)
 shutil.copyfile(HERE/'scoped.svh',out/'include/scoped.svh');shutil.copyfile(a.gate/'generated_scoped_drain.svh',out/'include/generated_scoped_drain.svh')
 wrapper='''// Elaboration only. Original hook and strict assertions remain installed.
wire hg_scope_held=hg193_combined_held;
wire hg_scope_original_phase=imp_vc==193 && dut.line_start && dut.vcount==193 && !dut.clk_sys && !dut.clk_2x && !imp_stub_pend;
wire hg_scope_content=hg193_selected_stub_actual_match();
wire[3:0]hg_bridge_valid=hg_bridge_history_valid;
wire[3:0]hg_bridge_read=hg_bridge_rd_history,hg_bridge_write=hg_bridge_wr_history;
wire hg_bridge_rd=bridge_rd,hg_bridge_wr=bridge_wr;
wire[31:0]hg_bridge_current=bridge_addr;
wire[31:0]hg_bridge_addr[4]=hg_bridge_address_history;
`define HG_READ_MEM dut.ds.u_cpud.g_one.u_cpu.u_mem9
`define HG_READ_FAB dut.ds.u_fab
`define HG_READ_PHY dut.psram
`define HG_SCOPE_P7 dut.ds.u_cpud.g_a7c.u_p7
`define HG_SCOPE_MBOX dut.g_mbox.commands
`include "scoped.svh"
`include "generated_scoped_drain.svh"
wire hg193_unused_scoped_candidate=hg193_scoped_transport_ready();
`undef HG_READ_MEM
`undef HG_READ_FAB
`undef HG_READ_PHY
`undef HG_SCOPE_P7
`undef HG_SCOPE_MBOX
'''
 (out/'include/scoped-wrapper.svh').write_text(wrapper)
 hook=out/'include/hg193_combined_hook.svh';before=hook.read_text();mark='`include "all-publication-diagnostics.svh"';after=before.replace(mark,mark+'\n`include "scoped-wrapper.svh"');assert after.count('`include "scoped-wrapper.svh"')==1;hook.write_text(after)
 assert after.replace('\n`include "scoped-wrapper.svh"','')==before
 assert(out/'include/hg193_combined_drain.svh').read_bytes()==(parent/'include/hg193_combined_drain.svh').read_bytes()
 old=json.loads((parent/'game-build-plan.json').read_text());argv=[x.replace(str(parent)+'/',str(out)+'/')for x in old['argv']];assert '--binary'in argv;argv[argv.index('--binary')]='--lint-only'
 assert '--binary'not in argv
 argv.insert(1,'-I'+str(out/'snapshot/source'))
 (out/'plan.json').write_text(json.dumps({'lint':argv},indent=2)+'\n')
 shutil.copyfile(HERE/'run_component.py',out/'run_component.py')
 binding={'parent_model':'2ae334615d7c40c8f1dfd597449c8ffb9bb0d60510bca1b569686d90389d349a','production':old['source'],'profile':old['full_profile'],'operation':'LINT_ONLY_NO_ELF_NO_NATIVE','default_enable':0,'original_hook_reconstructs_exact':True,'original_drain_byte_identical':True,'inputs':{str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest()for p in out.rglob('*')if p.is_file()}}
 (out/'binding.json').write_text(json.dumps(binding,indent=2)+'\n')
 print('PREPARED_SCOPED_HIERARCHY_LINT',out)
if __name__=='__main__':main()
