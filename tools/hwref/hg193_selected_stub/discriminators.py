#!/usr/bin/env python3
"""Stage missing held-point observations only; no guard edits or model run."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

HERE=Path(__file__).resolve().parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,d):p.write_text(json.dumps(d,indent=2)+'\n')
def stage(parent,selection,out):
 assert not out.exists();out.mkdir(parents=True)
 selected=json.loads((selection/'selection.json').read_text());assert selected['selected_tail']=='023091b0'and selected['tables']['arm9']['halted']==0
 source=parent/'snapshot/source'
 groups={
 'arm7':('dut.ds.u_cpud.g_a7c.u_p7','i_req i_addr i_seq i_arm i_redirect i_consume i_ok i_rdata ireg ib_addr i_boot_q d_req d_we d_be d_addr d_ok d_rdata dreg d_boot db_addr d_boot_q rp_v rp_i rp_a rp_be rp_k rp_il rp_bad rp_flow rp_ifgen rp_ifword rp_ifseq rp_stale if_gen rp_rejoin_window rp_rejoined busy busy_w wb_v wb_a wb_d wb_be rb_v rb_a rb_d f_req f_addr f_we f_be f_ack f_rdata f_n4 f_rvalid f_ifseq f_ifgen f_ifword flow_v flow_a flow_left flow_qv flow_q flow_pv flow_pa flow_pg flow_sc ia_v ia_r da_v da_r da_owned fl_v xs_busy su_v sf_n w_req w_ok x_req x_done'),
 'cpu_domain':('dut.ds.u_cpud','CPU_FAST A9_SOLO c_f7_req c_f7_addr c_f7_we c_f7_be c_f7_ack c_f7_rdata c_f7_n4 c_f7_rvalid c_f7_ifseq c_f7_ifgen c_f7_ifword f7_req f7_addr f7_we f7_be f7_ack f7_rdata f7_n4 f7_rvalid f7_ifseq f7_ifgen f7_ifword'),
 'fabric':('dut.ds.u_fab','st mst cpu addr we be blk grant a7_req a7_addr a7_we a7_be a7_ack a7_rdata a7_n4 a7_rvalid a7_ifgen a7_ifword io_req io_cpu io_we io_be io_addr io_ack io_rdata sd_st sd_busy sd_n4 sd_fw ra_st ra_busy ra_fill ra_q ra_fw ra_wide ls_active ls_end ls_end_addr ls_end_data ls_end_meta ls_work ld4_req ld4_active ld4_pending ld4_word ld4_valid q7 q7_gen q7_word v7_live v7_read v7_addr v7_data v7_io_read v7_ack'),
 'bridge':('', 'bridge_addr bridge_rd bridge_wr bridge_wr_data bridge_rd_data clk_74a done_loading serving stop_serving v_frames frames'),
 'bridge_mux':('dut','cmd_bridge_rd_data save_sel log_window'),
 'mailbox':('dut.g_mbox.commands','in_cmd b_map b_addr b_we b_d b_q b_qr b_q2 bridge_rd_data wf_a wf_d wf_n h_ev t_ev f0 f1 f2 fw_v fw_word fw_slot fw_data'),
 }
 refs={'arm7':'rtl/ds/nds_arm7_port.sv','cpu_domain':'rtl/arm/cpu_domain.sv','fabric':'rtl/ds/nds_fabric.sv','bridge':'../observed-overlay/tb_native52_import.sv','bridge_mux':'rtl/pocket/core_top_ds.sv','mailbox':'rtl/pocket/nds_mbox.sv'}
 rows=[]
 for group,(prefix,names)in groups.items():
  text=(parent/'observed-overlay/tb_native52_import.sv').read_text()if group=='bridge'else(source/refs[group]).read_text()
  for name in names.split():
   import re
   assert re.search(r'\b'+name+r'\b',text),(group,name)
   rows.append(dict(group=group,name=name,expression=prefix+'.'+name if prefix else name))
 # Addresses are observations, not fabricated acceptance witnesses. The RAM
 # lane may describe the address three bridge edges earlier; forwarding uses
 # its captured write slot instead. Capture both rather than guessing.
 history='''// Read-only source proposal: retain four actual bridge edge descriptors.
logic[31:0] hg_bridge_address_history[4];
logic[3:0] hg_bridge_rd_history=0,hg_bridge_wr_history=0,hg_bridge_history_valid=0;
always @(posedge clk_74a)begin
 hg_bridge_address_history[0]<=bridge_addr;
 for(int i=1;i<4;i++)hg_bridge_address_history[i]<=hg_bridge_address_history[i-1];
 hg_bridge_rd_history<={hg_bridge_rd_history[2:0],bridge_rd};
 hg_bridge_wr_history<={hg_bridge_wr_history[2:0],bridge_wr};
 hg_bridge_history_valid<={hg_bridge_history_valid[2:0],1'b1};
end
'''
 (out/'bridge-history.svh').write_text(history)
 lines=['// SOURCE ONLY: no guard or key edge change; no call in frozen b0ff/e383.',
 'function automatic bit hg193_selected_stub_actual_match();',
 ' logic[31:0] initial_words[137],live_words[137];',
 " if(imp_ov!='hc2400 || imp_stubn!='h89)return 0;",
 ' for(int i=0;i<137;i++)begin',
 '  initial_words[i]=imp_main[imp_ov+i];',
 '  live_words[i]={cram1.peek(imp_ov+i),cram0.peek(imp_ov+i)};',
 ' end',
 " return hg193_selected_stub::content_match(initial_words,live_words,1'b1,1'b0);",
 'endfunction',
 'task automatic hg193_missing_discriminators;',
 ' logic[31:0] expected,current;',
 ' for(int i=0;i<137;i++)begin',
 "  expected=i==107?32'h023091b0:imp_main[imp_ov+i];",
 '  current={cram1.peek(imp_ov+i),cram0.peek(imp_ov+i)};',
 '  $display("HG193_STUB_WORD index=%0d actual=%08h expected=%08h",i,current,expected);',
 ' end',
 ' $display("HG193_SELECTED_STUB match=%0b selected=023091b0 halted9=0 halted7=1 default_enable=0",hg193_selected_stub_actual_match());']
 for row in rows:lines.append(f' $display("HG193_MISSING group={row["group"]} name={row["name"]} value=%h",{row["expression"]});')
 lines+=[' for(int i=0;i<4;i++)',
 '  $display("HG193_BRIDGE_HISTORY age=%0d valid=%0b addr=%08h rd=%0b wr=%0b",i,hg_bridge_history_valid[i],hg_bridge_address_history[i],hg_bridge_rd_history[i],hg_bridge_wr_history[i]);',
 'endtask','']
 text='\n'.join(lines);assert all(x not in text for x in ['@(', '#', 'force ', 'release ', 'wait(', '$fatal'])
 (out/'missing-discriminators.svh').write_text(text)
 shutil.copyfile(selection/'matcher.svh',out/'matcher.svh')
 plan=dict(state='SOURCE_ONLY_UNCOMPILED_NOT_INSTALLED',signal_values=len(rows),live_stub_words=137,bridge_address_history=4,expressions=rows,source_sha256={n:sha(source/n)for n in sorted(set(v for k,v in refs.items()if k!='bridge'))},actor_sha256=sha(parent/'observed-overlay/tb_native52_import.sv'),selected_table_binding_sha256=sha(selection/'selection.json'),callsite='Inside same held original publication, after current caller diagnostics and before original first fatal; add package before TB, bridge-history observer inside TB. Every existing strict helper/call stays byte-identical.',DUT_writes=0,waits_added=0,proposal_enable=0,game_native_runs=0,raw_scans=0,missing_discriminator='ActualARM7 pending/accepted/completed address/class/width/gen/returned-data relation, all137live words including selectedtramp, actualbridgeaddress+3edge pipeline/forwarded-reply provenance. No retiredPC/request Boolean is substituted for an owner.',debt='CurrentARM9quad still owes fourthword despite psram.busy0; requestaliases/rvalid fanouts are the same owner, not permission to drop its credit. ARM7/IO/V7/LS/side/forwarded replies retain actual debt.',qualification='Identifier presence/source staging only, not elaboration or runtime proof. Bridge address history records observations and does not declare consumed/outstanding responses. This source is not permission to run another game/native or relax a guard.')
 write(out/'plan.json',plan)
 return dict(state=plan['state'],signals=len(rows),live_stub_words=137,bridge_history=4,game_native_runs=0,raw_scans=0)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--parent',type=Path,required=True);p.add_argument('--selection',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();print(json.dumps(stage(a.parent.resolve(),a.selection.resolve(),a.out.resolve()),indent=2))
