#!/usr/bin/env python3
"""Freeze the exact CPU producer/P7 receiver and targeted paired fixture."""
from pathlib import Path
import argparse,hashlib,json,shutil,importlib.util
import cpu_trial,p7_trial

R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True);p.add_argument('--adverse',type=Path,required=True)
p.add_argument('--phase',type=Path,required=True);p.add_argument('--guard',type=Path,required=True)
a=p.parse_args();D=a.output.resolve();D.mkdir(parents=True,exist_ok=False);S=D/'source';S.mkdir()
sha=lambda f:hashlib.file_digest(f.open('rb'),'sha256').hexdigest()
shutil.copytree(a.adverse/'inputs',D/'inputs');shutil.copytree(a.guard,D/'helpers',ignore=shutil.ignore_patterns('__pycache__'))
for f in (a.adverse/'source').glob('*.sv'):
 if f.name not in ['tb.sv','arm7_ds.sv','nds_arm7_port.sv']:shutil.copyfile(f,S/f.name)
cpu=(a.phase.parent.parent/'a7-mul-local/attempt1/source/arm7_ds.sv').read_text()
p7=Path('/home/user/Git/NDS_Pocket/rtl/ds/nds_arm7_port.sv').read_text()
assert hashlib.sha256(cpu.encode()).hexdigest()=='662c582fcd2f965185f1018f4adc2eeb12f37dbc7ac4ed6f0b5951ad5c357d4e'
assert hashlib.sha256(p7.encode()).hexdigest()=='0ce5fbcf4878a4b0603ee85e8a63a88551865f94e4b93ea08778b921404fd457'
phase=cpu_trial._phase.patch(cpu).replace('module arm7_ds_trial import','module arm7_ds_slot_trial import',1)
phase=phase.replace('  input logic phase_trial,','  input logic phase_trial,\n  output wire i_commit_valid,\n  output wire[31:0]i_commit_addr,\n  input wire i_commit_accept,',1)
phase=phase.replace('  logic phase_f_done, phase_prepared;',"  assign i_commit_valid=1'b0;assign i_commit_addr=32'd0;\n  logic phase_f_done, phase_prepared;",1)
oldp7=p7.replace('module nds_arm7_port #(','module nds_arm7_port_slot_trial #(',1)
oldp7=oldp7.replace('    input  logic        i_consume,','    input  logic        i_consume,\n    input logic i_commit_valid,\n    input logic[31:0]i_commit_addr,\n    output wire i_commit_accept,',1)
oldp7=oldp7.replace('    localparam bit FLOW =',"    assign i_commit_accept=1'b0;\n    localparam bit FLOW =",1)
for role in ['before','normal','cpu-drop','p7-consume']:
 Q=D/role;Q.mkdir()
 (Q/'cpu.sv').write_text(phase if role=='before'else cpu_trial.patch(cpu,'drop-unaccepted'if role=='cpu-drop'else'none'))
 (Q/'p7.sv').write_text(oldp7 if role=='before'else p7_trial.patch(p7,'consume-wins'if role=='p7-consume'else'none'))
s=(a.adverse/'source/tb.sv').read_text()
s=s.replace(' arm7_ds_trial #(',' arm7_ds_slot_trial #(',1)
s=s.replace('.phase_trial(policy!=0),','.phase_trial(policy!=0),.i_commit_valid(cv),.i_commit_addr(cvaddr),.i_commit_accept(ca),',1)
begin=s.index(' nds_arm7_port #(');end=s.index(' physical_before #(',begin)
block=s[begin:end].replace('nds_arm7_port #(','nds_arm7_port_slot_trial #(',1)
block=block.replace('.i_req(ir),.i_addr(ia)', '.i_req(p7_request),.i_addr(p7_address)',1)
block=block.replace('.i_redirect(iredirect),.i_consume(iconsume)',
 '.i_redirect(iredirect||cpu_reset),.i_consume(p7_consume),.i_commit_valid(cv),.i_commit_addr(cvaddr),.i_commit_accept(ca)',1)
s=s[:begin]+block+s[end:]
s=s.replace(' logic initialized,idle;',Path(__file__).with_name('paired.svh').read_text()+'\n logic initialized,idle;',1)
s=s.replace('  phasefd=$fopen', '  slotfd=$fopen({out,".slot"},"w");pinfd=$fopen({out,".pins"},"w");fullfd=$fopen({out,".full"},"w");\n  phasefd=$fopen',1)
s=s.replace('  $fclose(phasefd);','''  if(policy!=0)begin
   assert(slot_offers==phase_commits&&slot_accepts==phase_commits)else $fatal(1,"PAIR_OFFER_ACCEPT_CONSERVATION");
   assert(slot_turns>0)else $fatal(1,"PAIR_SAME_EDGE_NOT_REACHED");
   if(scenario==5)assert(intervention&&slot_waits>=8)else $fatal(1,"PAIR_BACKPRESSURE_NOT_REACHED");
  end
  $display("PAIRED_SLOT_PASS offers%0d accepts%0d waits%0d turns%0d",slot_offers,slot_accepts,slot_waits,slot_turns);
  $fclose(slotfd);$fclose(pinfd);$fclose(fullfd);
  $fclose(phasefd);''',1)
(S/'tb.sv').write_text(s)
template=next(x['command']for x in json.loads((a.phase/'results.json').read_text())['stages']if x['tag']=='c1-r1-p1-n4')
(D/'run-inputs.json').write_text(json.dumps(dict(template=template,IRQ_symbols=json.loads((a.adverse/'results.json').read_text())['IRQ_symbols']),indent=2)+'\n')
T=D/'drivers';T.mkdir()
for name in ['cpu_trial.py','cpu_ledger.svh','p7_trial.py','p7_ledger.svh','paired.svh','prepare_pair.py','run_pair.py']:
 shutil.copyfile(Path(__file__).with_name(name),T/name)
shutil.copyfile(R/'sim/arm/a7_prepare_finish/trial.py',T/'original-phase-trial.py')
receipt=dict(status='SOURCE FROZEN; PAIRED GATE UNRUN',CPU='d006ad38',P7='087e3a66/174d268d',
 source_sha256={str(f.relative_to(D)):sha(f)for f in sorted(D.rglob('*'))if f.is_file()},
 scope='Sequential ARM MAIN; deliberate 8edge logical-link backpressure only in scenario5, no DS service price/debt/native qualification')
(D/'inputs.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(dict(path=str(D),files=len(receipt['source_sha256']))))
