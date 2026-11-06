#!/usr/bin/env python3
"""Qualify one compact held-point observation or name its exact remaining gap.

Reads console/source extracts only; no protected raw streams or ELF execution.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[3]
def write(p,d):p.write_text(json.dumps(d,indent=2)+'\n')
def number(values,group,key):
 s=values[group][key]
 return None if any(c in s.lower()for c in 'xz')else int(s,16)
def arm7_scope(values):
 n=lambda k:number(values,'arm7',k);f=lambda k:number(values,'fabric',k);c=lambda k:number(values,'cpu_domain',k)
 checks=dict(selected_BOOT_FAB_buffer=n('ireg')==0 and n('ia_r')==0 and n('i_req')==1 and 0x94a0<=n('i_addr')<0x94b8 and n('i_rdata')==0x1afffffa and n('i_addr')==0x94b4,
  no_instruction_packet_or_window=all(n(k)==0 for k in ['rp_i','rp_flow','flow_v','flow_qv','flow_pv','i_redirect','i_consume']),
  queued_KEYINPUT_data=n('rp_v')==1 and n('rp_i')==0 and n('rp_a')==0x04000130 and n('busy')==1 and n('busy_w')==0,
  read_not_write=n('d_we')==n('f_we')==n('wb_v')==0,
  matching_halfword=n('d_addr')==n('rp_a')==n('f_addr')==0x04000130 and n('d_be')==n('rp_be')==n('f_be')==3 and n('f_n4')==0,
  direct_domain=all(c('c_f7_'+k)==c('f7_'+k)for k in ['req','addr','we','be','ack','rdata','n4','rvalid','ifseq','ifgen','ifword'])and c('f7_addr')==n('f_addr')and c('f7_req')==n('f_req')==f('a7_req')==1,
  not_fabric_accepted=f('mst')==1 and f('st')==4 and n('f_ack')==c('f7_ack')==f('a7_ack')==0,
  no_other_side_owner=all(f(k)==0 for k in ['v7_live','sd_busy','ra_busy','ls_end','ld4_active','ld4_pending']),
  no_SRAM_or_store_debt=all(n(k)==0 for k in ['fl_v','xs_busy','su_v','sf_n','w_req','x_req']),
  completed_slot_bounded=n('rb_v')==0 or(n('rb_v')==1 and n('rb_a')==0x04000130))
 return checks

def bridge_scope(observation):
 values=observation['values'];b=lambda k:number(values,'bridge',k);m=lambda k:number(values,'mailbox',k);mux=lambda k:number(values,'bridge_mux',k)
 h={int(k):v for k,v in observation['bridge_history'].items()};num=lambda s:None if any(c in s.lower()for c in 'xz')else int(s,16)
 allowed={0xf8001000,0xf8001020,0xf8001024,0xf8001028,0xf800102c}
 checks=dict(actual_command_read=b('bridge_rd')==1 and b('bridge_wr')==0 and b('bridge_addr')in allowed and m('in_cmd')==1,
  pre_save_target_service=b('done_loading')==1 and b('serving')==1 and b('stop_serving')==0 and b('v_frames')<b('frames')==85,
  no_hidden_bridge_write=all(m(k)==0 for k in ['b_we','f0','f1','f2','fw_v']),
  output_preserved_word=b('bridge_rd_data')==mux('cmd_bridge_rd_data')==m('bridge_rd_data'),
  history_complete=all(num(h[i]['valid'])==1 for i in range(4)))
 # At last bridge edge the registered output either uses the captured recent
 # write or the prior RAM word. With current wf_n>=6, its previous value was
 # already>=5, so the last active edge cannot select forwarding. No live
 # RAM payload is substituted for the captured registered result.
 if checks['history_complete']and num(h[0]['read'])==1 and m('wf_n')>=6 and num(h[0]['write'])==0:
  owner=num(h[3]['address']);lane='RAM_at_last_active_edge';qualified=owner in allowed
  gap=None if qualified else 'Registered RAM address at age3 is outside qualified target command reads.'
 else:
  owner=None;lane='UNQUALIFIED_last_output_update_or_forwarding';qualified=False
  gap='Four-edge history does not uniquely identify the last registered-output update/RAM address or captured forwarding slot at that update. Preserve current output and forwarding state; do not relabel it.'
 checks['registered_reply_owner']=qualified
 return checks,dict(lane=lane,owner_address=f'{owner:08x}'if owner is not None else None,registered_payload=f'{m("bridge_rd_data"):08x}',gap=gap,policy='Current request and stored reply stay separate. No key/ACK/clock/DUT state is changed.')

def analyze(base,parent,selected):
 observation=json.loads((base/'diagnostic/observations.json').read_text());values=observation['values'];current=(base/'diagnostic/native.log').read_text();prior=(parent/'diagnostic/native.log').read_text()
 prefixes=('HG193_CPU_CLAUSE','HG193_CPU_RAW','HG193_ALL_GUARD','HG193_OWNER','HG193_CALLER')
 old=[s for s in prior.splitlines()if s.startswith(prefixes)];new=[s for s in current.splitlines()if s.startswith(prefixes)]
 identity=dict(original_CPU_raw_guard_owner_console_equal=old==new,original_lines=len(old),original_failure_time_equal=bool(re.search(r'\[129210695000\] %Fatal:.*HG193 combined drain: cpu_arm9_cache',current)),scope='Original held-point console observables/source erasure only; no new CPU/bus stream, trajectory, frame or full-scene equivalence claim.')
 assert identity['original_CPU_raw_guard_owner_console_equal']and identity['original_failure_time_equal']
 initial=[int(x,16)for x in(selected/'initial.hex').read_text().split()];selection=json.loads((selected/'selection.json').read_text());expected=list(initial);expected[107]=int(selection['selected_tail'],16)
 rows={int(k):r for k,r in observation['stub'].items()};assert len(rows)==137 and all(int(rows[i]['expected'],16)==expected[i]for i in range(137))
 live=[int(rows[i]['actual'],16)for i in range(137)];mismatches=[dict(word=i,actual=f'{a:08x}',expected=f'{e:08x}')for i,(a,e)in enumerate(zip(live,expected))if a!=e]
 stub=dict(exact_selected_match=not mismatches,words=137,mutable_word=107,selected_tramp=f'{expected[107]:08x}',live_tramp=f'{live[107]:08x}',live_sha256=hashlib.sha256(b''.join(w.to_bytes(4,'little')for w in live)).hexdigest(),mismatches=mismatches,source_known=True)
 # Resolve the actual compiled path, rather than assuming the optional
 # dedicated boot M10K route. This root defaults BOOT_SRAM1, propagated to
 # A7_BOOTF and BOOT_FAB; the unused boot_qa/qb outputs are tied to zero.
 src=base/'snapshot/source';core=(src/'rtl/pocket/core_top_ds.sv').read_text();top=(src/'rtl/ds/nds_top.sv').read_text();domain=(src/'rtl/arm/cpu_domain.sv').read_text();port=(src/'rtl/ds/nds_arm7_port.sv').read_text()
 assert 'parameter integer BOOT_SRAM = 1'in core and '.BOOT_SRAM(BOOT_SRAM)'in core
 assert '.A7_BOOTF(BOOT_SRAM)'in top and '.BOOT_FAB(FAST || A7_BOOTF != 0)'in domain
 assert 'assign boot_qa = 32\'d0; assign boot_qb = 32\'d0;'in top
 plan=json.loads((base/'game-build-plan.json').read_text());assert not any('BOOT_SRAM('in arg for arg in plan['argv']if 'TB_CORE_PARAMS='in arg)
 boot_words=[int(x,16)for x in(ROOT/'build/hg193-selected-stub-20261102/evidence/bound-boot.hex').read_text().split()]
 assert boot_words[(0x94b4-0x8000)//4]==0x1afffffa
 a7=arm7_scope(values);bridge,reply=bridge_scope(observation)
 boot_route=dict(BOOT_SRAM=1,A7_BOOTF=1,BOOT_FAB=1,ireg=number(values,'arm7','ireg'),ia_r=number(values,'arm7','ia_r'),actual_fetch_address=values['arm7']['i_addr'],actual_presented_word=values['arm7']['i_rdata'],bound_word='1afffffa',route='Completed boot-ROM line data in CPU-local u_il, originally filled through fabric/SRAM; direct boot_qa/qb route disabled.',limits='i_ok0/i_consume0: no instruction transfer asserted at this held lookup phase. Private IL tag/bank contents are not dumped or independently qualified; they are not publication targets and no instruction packet/window is pending. No whole CPU/cache correctness claim.',source_sha256={n:hashlib.sha256((src/n).read_bytes()).hexdigest()for n in ['rtl/pocket/core_top_ds.sv','rtl/ds/nds_top.sv','rtl/arm/cpu_domain.sv','rtl/ds/nds_arm7_port.sv']})
 owner_line=next(s for s in observation['owners']if s.startswith('HG193_OWNER known='));raw_line=next(s for s in observation['owners']if s.startswith('HG193_OWNER_RAW'))
 logical,physical=owner_line.split(' physical_v=',1)
 tags=dict(re.findall(r'(\w+)=(\S+)',logical));packet=dict(re.findall(r'(\w+)=(\S+)','physical_v='+physical));raw=dict(re.findall(r'(\w+)=(\S+)',raw_line))
 debt=dict(known=tags['known']=='1',logical_owner=int(tags['id']),physical_owner=int(packet['id']),master=int(tags['master']),address=tags['addr'],packet_base=packet['base'],words=int(packet['words']),returned=int(packet['returned']),current_valid=int(raw['rvalid']),arbiter_own=int(raw['arb_own']),arbiter_beat=int(raw['beat']),busy=int(raw['phy_busy']))
 debt['all_credits_preserved']=debt['known']and debt['logical_owner']==debt['physical_owner']and debt['returned']==3 and debt['current_valid']==1 and debt['words']==4 and debt['arbiter_own']==1 and debt['arbiter_beat']==3
 assert debt['all_credits_preserved']
 # Mutate captured views, not DUT state. The classification must reject the
 # wrong selected word, endpoint, operation and bridge namespace.
 mutants=[]
 for i in [0,107]:
  bad=list(live);bad[i]^=1;assert bad!=expected;mutants.append('captured_stub_word'+str(i)+'_bit')
 if all(a7.values()):
  for field,value in [('f_addr','04000600'),('rp_i','1'),('busy_w','1'),('f_be','f'),('ireg','1'),('i_rdata','1afffffb')]:
   bad=copy.deepcopy(values);bad['arm7'][field]=value;assert not all(arm7_scope(bad).values());mutants.append('captured_arm7_'+field)
 if all(bridge.values()):
  bad=copy.deepcopy(observation);bad['values']['bridge']['bridge_addr']='60000000';assert not all(bridge_scope(bad)[0].values());mutants.append('captured_bridge_namespace')
 original_rows=json.loads((ROOT/'docs/results/hg193-actual-caller-20261102/summary.json').read_text())['false_guards'];classifications=[]
 for row in original_rows:
  g,i=row['group'],row['index'];r=dict(row,original_guard_retained=True)
  if g=='cpu_arm9_cache':ok=stub['exact_selected_match']and debt['all_credits_preserved'];r.update(scope='Exact selected live stub content plus previously qualified/captured ARM9 read ownership; original strict-ready false remains.',qualified=ok,gap=None if ok else 'Live selected-content or ARM9 credit mismatch.')
  elif g=='cpu_arm7_ports'or(g=='cpu_domain_requests'and i in [3,7]):ok=all(a7.values());r.update(scope='Actual BOOT_FAB1 selected boot word held in CPU-local instruction buffer plus queued, not accepted, KEYINPUT halfword read; completed slots/generation fields/side flags preserved.',qualified=ok,gap=None if ok else [k for k,v in a7.items()if not v])
  elif g=='cpu_domain_requests':r.update(scope='Actual direct ARM9 request aliases, no extra response owner.',qualified=debt['all_credits_preserved'],gap=None)
  elif g in ['fabric','main_psram']or(g=='shell_capture_cart'and i==2):r.update(scope='Captured ARM9 physical quad fourth-word credit retained despite busy0; no idle claim.',qualified=debt['all_credits_preserved'],gap=None)
  elif g=='shell_capture_cart':r.update(scope='Actual target-command read and registered mailbox reply, preserved RAM/forwarding pipeline.',qualified=all(bridge.values()),gap=None if all(bridge.values())else [k for k,v in bridge.items()if not v],reply=reply)
  else:r.update(scope='Unchanged strict child aggregation; qualification does not change its Boolean value.',qualified=stub['exact_selected_match']and all(a7.values())and all(bridge.values())and debt['all_credits_preserved'],gap=None if stub['exact_selected_match']and all(a7.values())and all(bridge.values())else 'One or more child ownership/content scopes remain unqualified.')
  classifications.append(r)
 report=dict(source=observation['source'],model_sha256=observation['model_sha256'],profile=60,time_ps=129210695000,stub=stub,ARM7_boot_route=boot_route,ARM7_checks=a7,ARM7_values=values['arm7'],bridge_checks=bridge,registered_bridge_reply=reply,physical_ARM9_debt=debt,clauses=classifications,scoped_qualified=sum(r['qualified']for r in classifications),explicit_gaps=[r for r in classifications if not r['qualified']],captured_view_mutations_caught=mutants,mutation_scope='Offline parsed actual-value faults; not new DUT/ELF mutation runs.',console_identity=identity,proposal_enable=0,all_original_guards_retained=True,history_published=False,scene_accepted=False,raw_scans=0,new_full_bus_dump=False)
 write(base/'diagnostic/qualification.json',report);write(base/'diagnostic/console-identity.json',identity);return report
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--base',type=Path,required=True);p.add_argument('--parent',type=Path,required=True);p.add_argument('--selected',type=Path,required=True);a=p.parse_args();r=analyze(a.base.resolve(),a.parent.resolve(),a.selected.resolve());print(json.dumps({k:r[k]for k in ['stub','ARM7_checks','bridge_checks','registered_bridge_reply','physical_ARM9_debt','scoped_qualified','captured_view_mutations_caught']},indent=2))
