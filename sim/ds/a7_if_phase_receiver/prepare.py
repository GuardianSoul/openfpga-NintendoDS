"""Prepare the changed P7 against accepted producer captures and DS layouts."""
from pathlib import Path
import argparse,hashlib,json,shutil,subprocess
R=Path(__file__).resolve().parents[3]
B=Path('/home/user/Git/NDS_Pocket-cpu-a7-i-phase-producer/build/i-phase-producer/pair2')
p=argparse.ArgumentParser();p.add_argument('--allocated',required=True,action='store_true');p.add_argument('--out',required=True,type=Path);a=p.parse_args();G=a.out.resolve();G.mkdir(parents=True,exist_ok=False)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
shutil.copytree(B/'source',G/'source');shutil.copytree(B/'inputs',G/'inputs');shutil.copytree(B/'reference',G/'reference');shutil.copy2(B/'results.json',G/'previous-results.json');shutil.copy2(B/'run-inputs.json',G/'run-inputs.json')
for n,h in json.loads((B/'results.json').read_text())['models']['on']['sources'].items():assert sha(B/n)==h,n
old=subprocess.check_output(['git','show','0a5a1cee:rtl/ds/nds_arm7_port.sv'],cwd=R,text=True);new=(R/'rtl/ds/nds_arm7_port.sv').read_text()
erased=new.replace("    parameter bit TAG_WLATE = 1'b1,     // tag writes a cycle late (nds_lcache WLATE): timing, same cycles\n    parameter bit MAIN_IF_PHASE_SERVICE = 0 // owner-local actual-I eligibility; no physical preparation","    parameter bit TAG_WLATE = 1'b1      // tag writes a cycle late (nds_lcache WLATE): timing, same cycles")
erased=erased.replace('    input  arm_pkg::a7_if_phase_t i_phase,\n','');lo=erased.index('    // The accepted CPU producer describes');hi=erased.index('    // A real new N demand',lo);erased=erased[:lo]+erased[hi:]
erased=erased.replace('phase_commit ? phase_left : !(first_s','!(first_s');assert erased==old,'unrelated P7 or physical scheduler source changed'
def fixture(src):
 src=src.replace('module nds_arm7_port #(','module nds_arm7_port_slot_trial #(',1);anchor='    // simulation (+a7dbg):';assert src.count(anchor)==1
 return src.replace(anchor,(R/'sim/arm/a7_logical_slot/p7_ledger.svh').read_text()+'\n'+anchor,1)
assert fixture(old)==(B/'source/p7.sv').read_text(),'prior fixture source differs from production baseline'
(G/'source/p7.sv').write_text(fixture(new))
tb=(B/'source/tb.sv').read_text().replace('module tb #(parameter bit COMMIT=1, PHASE_META=1);','module tb #(parameter bit COMMIT=1, PHASE_META=1, PHASE_SERVICE=1);')
tb=tb.replace('nds_arm7_port_slot_trial #(','nds_arm7_port_slot_trial #(.MAIN_IF_PHASE_SERVICE(PHASE_SERVICE),',1)
pos=tb.index(' nds_arm7_port_slot_trial #');s=tb[pos:];needle='.i_commit_addr(cvaddr),.i_commit_accept(ca),';assert s.count(needle)==1;s=s.replace(needle,needle+'.i_phase(phase_meta),',1);tb=tb[:pos]+s
observer=(Path(__file__).with_name('observe.svh')).read_text();pos=tb.rindex('endmodule');tb=tb[:pos]+observer+'\n'+tb[pos:];(G/'source/tb.sv').write_text(tb)
fault=fixture(new);needle='phase_address <= i_phase.address[31:2];';assert fault.count(needle)==1;(G/'p7-wrong-owner.sv').write_text(fault.replace(needle,"phase_address <= i_phase.address[31:2] ^ 30'd1;"))
shutil.copytree(Path('/home/user/Git/NDS_Pocket-codex-dma-chain-cut/build/dma-reverse-turn-v1/helpers'),G/'helpers')
shutil.copy2(Path(__file__).with_name('worker.py'),G/'worker.py');shutil.copy2(__file__,G/'prepare.py')
write=lambda n,j:(G/n).write_text(json.dumps(j,indent=2)+'\n')
write('source-audit.json',dict(previous='0a5a1cee',producer='2d6b3a7a',P7_erasure=True,prior_actual_fixture_exact=True,changed_production=['rtl/ds/nds_arm7_port.sv'],physical_source_changed=False,public_forwarding_owner='Root',scope='Finite actual-I pure-MAIN hypothesis, no opcode/Rs/elapsed credit. Seven DS anchors gate result; DS30 data-owner residual explicit.'))
write('inputs.json',{str(p.relative_to(G)):sha(p)for p in G.rglob('*')if p.is_file()and p.name!='inputs.json'})
print('PHASE_RECEIVER_PREPARED',G)
