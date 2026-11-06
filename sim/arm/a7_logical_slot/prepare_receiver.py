#!/usr/bin/env python3
"""Freeze a small receiver-contract gate; does not build or run a model."""
from pathlib import Path
import argparse, hashlib, json, shutil
from p7_trial import patch

R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--control',type=Path,required=True,help='Frozen a7-prepare-finish adverse source directory')
p.add_argument('--p7',type=Path,required=True)
p.add_argument('--guard',type=Path,required=True)
a=p.parse_args(); D=a.output.resolve(); D.mkdir(parents=True,exist_ok=False)
S=D/'source'; S.mkdir(); sha=lambda b:hashlib.sha256(b).hexdigest()
for f in sorted(a.control.glob('*.sv')):
    if f.name in ['tb.sv','arm7_ds.sv','arm_thumb.sv','arm_pkg.sv','nds_arm7_port.sv']:
        continue
    shutil.copyfile(f,S/f.name)
shutil.copyfile(Path(__file__).with_name('slot_tb.sv'),S/'tb.sv')
base=a.p7.read_text(); (D/'p7-before.sv').write_text(base)
for role in ['normal','drop-capture','consume-wins']:
    (D/f'p7-{role}.sv').write_text(patch(base,'none'if role=='normal'else role))
baseline=base.replace('module nds_arm7_port #(','module nds_arm7_port_slot_trial #(',1)
baseline=baseline.replace('    input  logic        i_consume,',
    '    input logic i_commit_valid,\n    input logic [31:0] i_commit_addr,\n    output wire i_commit_accept,\n    input  logic        i_consume,',1)
baseline=baseline.replace('    localparam bit FLOW =',"    assign i_commit_accept = 1'b0;\n    localparam bit FLOW =",1)
(D/'p7-before-ports.sv').write_text(baseline)
for name in ['p7_trial.py','p7_ledger.svh','prepare_receiver.py','run_receiver.py']:
    shutil.copyfile(Path(__file__).with_name(name),D/name)
(D/'helpers').mkdir()
for name in ['sim_ownership.py','worker_guard.py']:
    shutil.copyfile(a.guard/name,D/'helpers'/name)
receipt=dict(status='FROZEN SOURCE ONLY; gate unrun',
    source_sha256={str(f.relative_to(D)):sha(f.read_bytes())for f in sorted(D.rglob('*'))if f.is_file()},
    roles=['before','normal','drop-capture','consume-wins'],
    cases=dict(positive='normal scenarios0/1/2/3/4 x pressure0/1',
               literal_equivalence='before vs normal scenario4 pressure0/1, all saved data/edge/pins',
               faults='actual drop-capture and consume-wins, normal scenario0 pressure0',
               scope='Receiver protocol fixture; actual PSRAM/read payload/A9 order. No CPU producer or DS service timing claim.'))
(D/'inputs.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(dict(path=str(D),files=len(receipt['source_sha256']),status=receipt['status'])))
