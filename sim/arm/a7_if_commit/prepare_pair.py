#!/usr/bin/env python3
"""Bind the production CPU/P7 transplant to the qualified paired fixture."""
from pathlib import Path
import argparse, hashlib, json, shutil, subprocess

R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--reference',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();B=a.reference.resolve();D=a.output.resolve();D.mkdir(parents=True,exist_ok=False)
S=D/'source';S.mkdir();A=B/'a7-logical-slot-pair-v2'
sha=lambda b:hashlib.sha256(b).hexdigest()
for name in ['inputs','helpers']:
    shutil.copytree(A/name,D/name)
for f in (A/'source').glob('*.sv'):
    if f.name!='tb.sv':shutil.copyfile(f,S/f.name)
cpu=(R/'rtl/arm/arm7_ds.sv').read_text()
p7=subprocess.check_output(['git','show','d087bb7f:rtl/ds/nds_arm7_port.sv'],cwd=R).decode()
assert sha(p7.encode())=='dacb3dc37fbfc75b23ba47ec1873753e95d7c3f8138841b64df561e4ddd43016'
cpu=cpu.replace('module arm7_ds import','module arm7_ds_slot_trial import',1)
cpu=cpu.rstrip()[:-len('endmodule')]+(R/'sim/arm/a7_logical_slot/cpu_ledger.svh').read_text()+'\nendmodule\n'
p7=p7.replace('module nds_arm7_port #(','module nds_arm7_port_slot_trial #(',1)
anchor='    // simulation (+a7dbg):';assert p7.count(anchor)==1
p7=p7.replace(anchor,(R/'sim/arm/a7_logical_slot/p7_ledger.svh').read_text()+'\n'+anchor,1)
(S/'cpu.sv').write_text(cpu);(S/'p7.sv').write_text(p7)
s=(A/'source/tb.sv').read_text()
assert s.count('module tb;')==1;s=s.replace('module tb;','module tb #(parameter bit COMMIT=0);',1)
s=s.replace('arm7_ds_slot_trial #(','arm7_ds_slot_trial #(.MAIN_IF_COMMIT(COMMIT),',1)
assert s.count('.phase_trial(policy!=0),')==1;s=s.replace('.phase_trial(policy!=0),','',1)
s=s.replace('.i_rdata_in(iq),.i_ok_in(io)','.i_rdata(iq),.i_ok(io)',1)
s=s.replace('cpu.i_ok','cpu.fetch_ok')
(S/'tb.sv').write_text(s)
mutant=D/'cpu-drop.sv';needle='          phase_commit_pending <= 1;';assert cpu.count(needle)==1
mutant.write_text(cpu.replace(needle,'          phase_commit_pending <= 0;',1))
shutil.copyfile(A/'run-inputs.json',D/'run-inputs.json')
rows=json.loads((A/'results.json').read_text());reference={}
for key,row in rows.items():
    if not key.startswith('normal/'):continue
    root=B/('a7-logical-slot-pair-v1' if row.get('reused_from') else 'a7-logical-slot-pair-v2')
    stem=key.removeprefix('normal/');out=D/'reference'/stem;out.mkdir(parents=True)
    for ext in ['state','data','edge','full','pins','slot']:
        b=(root/(key+'.'+ext)).read_bytes();assert sha(b)==row['captures'][ext]
        (out/ext).write_bytes(b)
    reference[stem]=dict(source_root=root.name,captures=row['captures'])
(D/'reference.json').write_text(json.dumps(reference,indent=2)+'\n')
receipt=dict(status='SOURCE FROZEN; production runtime gate pending',CPU_base='de6039a5',P7='d087bb7f',
    qualified_pair='98373e35',source_sha256={str(f.relative_to(D)):sha(f.read_bytes()) for f in D.rglob('*') if f.is_file()},
    scope='Production on/off versus immutable paired control. No DS progression/native/fit claim.')
(D/'inputs.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('Prepared production adapter:',len(reference),'actual previous paired captures')
