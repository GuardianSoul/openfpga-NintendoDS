#!/usr/bin/env python3
"""One changed CPU leaf on the already-qualified production held fixture."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--previous',type=Path,required=True)
p.add_argument('--out',type=Path,required=True)
a=p.parse_args();old=a.previous.resolve();out=a.out.resolve();out.mkdir(parents=True,exist_ok=False)
s=out/'source';shutil.copytree(old/'source',s);shutil.copytree(old/'inputs',out/'inputs')
cpu=(R/'rtl/arm/arm7_ds.sv').read_text()
pkg=(R/'rtl/arm/arm_pkg.sv').read_text()
before=subprocess.check_output(['git','-C',str(R),'show','e77b21b6:rtl/arm/arm7_ds.sv'],text=True)
before_pkg=subprocess.check_output(['git','-C',str(R),'show','e77b21b6:rtl/arm/arm_pkg.sv'],text=True)
erased=cpu.replace('  parameter bit MUL_META = 0,     // passive request-time MUL context / advances\n  parameter bit MAIN_IF_PHASE_META = 0 // passive actual I/held-owner events only',
                  '  parameter bit MUL_META = 0      // passive request-time MUL context / advances')
erased=erased.replace('  output logic        dbg_halted,\n  output a7_if_phase_t if_phase','  output logic        dbg_halted')
lo=erased.index('  // Passive producer only:')
hi=erased.index('  wire if_wait',lo)
erased=erased[:lo]+erased[hi:]
assert erased==before,'non-producer CPU source changed'
lo=pkg.index('  // Logical next-F preparation events')
hi=pkg.index('  // temp_addr update',lo)
assert pkg[:lo]+pkg[hi:]==before_pkg,'old package definitions changed'
shutil.copyfile(old/'results.json',out/'previous-results.json')
shutil.copyfile(old/'run-inputs.json',out/'run-inputs.json')
cpu=cpu.replace('module arm7_ds import','module arm7_ds_slot_trial import',1)
cpu=cpu.rstrip()[:-len('endmodule')]+(R/'sim/arm/a7_logical_slot/cpu_ledger.svh').read_text()+'\nendmodule\n'
(s/'cpu.sv').write_text(cpu);(s/'arm_pkg.sv').write_text(pkg)
tb=(old/'source/tb.sv').read_text()
tb=tb.replace('module tb #(parameter bit COMMIT=0);','module tb #(parameter bit COMMIT=1, PHASE_META=1);')
tb=tb.replace(' import arm_pkg::*;',' import arm_pkg::*;\n a7_if_phase_t phase_meta;')
tb=tb.replace('arm7_ds_slot_trial #(.MAIN_IF_COMMIT(COMMIT),','arm7_ds_slot_trial #(.MAIN_IF_PHASE_META(PHASE_META),.MAIN_IF_COMMIT(COMMIT),')
assert tb.count('.i_commit_accept(ca),')==2  # CPU input, then P7 output
tb=tb.replace('.i_commit_accept(ca),','.i_commit_accept(ca),.if_phase(phase_meta),',1)
at=tb.rindex('endmodule')
tb=tb[:at]+(R/'sim/arm/a7_if_phase/observe.svh').read_text()+'\n'+tb[at:]
finish='  $display("PAIRED_SLOT_PASS offers%0d accepts%0d waits%0d turns%0d",slot_offers,slot_accepts,slot_waits,slot_turns);'
assert tb.count(finish)==1
tb=tb.replace(finish,finish+'\n  $display("IF_PHASE_META_PASS starts%0d advances%0d accepts%0d cancels%0d",phase_obs_starts,phase_obs_advances,phase_obs_accepts,phase_obs_cancels);\n  $fclose(phase_obs_fd);')
(s/'tb.sv').write_text(tb)
needle='if_phase.address = (phase_owner_live ? {phase_f_owner,2\'b00} : i_addr) + 32\'d4;'
assert cpu.count(needle)==1
(out/'cpu-wrong-owner.sv').write_text(cpu.replace(needle,needle.replace("32'd4","32'd8")))
ref=out/'reference';ref.mkdir()
rows=json.loads((old/'results.json').read_text())
for key,row in rows['cases'].items():
    if not key.startswith('on/'):
        continue
    q=ref/key.removeprefix('on/');q.mkdir()
    for ext,h in row['captures'].items():
        b=(old/(key+'.'+ext)).read_bytes();assert hashlib.sha256(b).hexdigest()==h
        (q/ext).write_bytes(b)
guard=dict(CPU_erasure=True,package_erasure=True,previous=str(old),
           source={str(f.relative_to(out)):hashlib.sha256(f.read_bytes()).hexdigest() for f in out.rglob('*') if f.is_file()})
(out/'inputs.json').write_text(json.dumps(guard,indent=2)+'\n')
print('Prepared changed leaf with exact CPU/package erasure and retained captures')
