#!/usr/bin/env python3
"""Freeze the existing c74 coupled36 fixture with only IF4 pair-credit changed."""
from pathlib import Path
import hashlib,json,shutil,subprocess,tarfile

ROOT=Path(__file__).resolve().parents[3]
ARCHIVE=ROOT/'docs/results/arm7-ack-handoff-20261101/component.tar.gz'
assert hashlib.sha256(ARCHIVE.read_bytes()).hexdigest()=='d371dce9c34bd547a373a3ecf5df27ff2f1628f09e7779fc61b858958f55d890'
with tarfile.open(ARCHIVE)as archive:
    donor={m.name:archive.extractfile(m).read()for m in archive if m.isfile()}
def pinned(path):
    return subprocess.check_output(['git','show','c74a3620:'+path],cwd=ROOT)
OUT=Path('/tmp/nds-if4-credit-cpu')
assert not OUT.exists();(OUT/'source').mkdir(parents=True)
for name,data in donor.items():
    if name.startswith('source/')and name.endswith('.sv'):(OUT/name).write_bytes(data)
rels=['rtl/arm/arm_pkg.sv','rtl/arm/arm7_ds.sv','rtl/arm/arm_thumb.sv','rtl/ds/nds_arm7_port.sv',
      'rtl/ds/nds_fabric.sv','rtl/ds/nds_mr_arb.sv','rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv',
      'rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/mem/psx_pq_psram.sv','rtl/pocket/nds_psram.sv']
for rel in rels:shutil.copyfile(ROOT/rel,OUT/'source'/Path(rel).name)
base=subprocess.check_output(['git','show','e704c35b:rtl/pocket/nds_psram.sv'],cwd=ROOT,text=True)
assert hashlib.sha256(base.encode()).hexdigest()=='b4dfdff78ba20175f273925b8a5878dd114d06b458bf7b1e59cb6968076a619e'
(OUT/'source/old_nds_psram.sv').write_text(base.replace('module nds_psram #','module old_nds_psram #',1))
p7=(ROOT/'rtl/ds/nds_arm7_port.sv').read_text()
for name in['old','bad']:(OUT/f'source/{name}_nds_arm7_port.sv').write_text(p7.replace('module nds_arm7_port #',f'module {name}_nds_arm7_port #',1))
tb=donor['tb.sv'].decode();a=tb.index('module physical_before');b=tb.index('endmodule',a)+9
tb=tb[:a]+tb[a:b].replace('nds_psram #','old_nds_psram #',1)+tb[b:]
tb=tb.replace('wire[2:0]done;','wire[1:0]done;')
needle=' cpu_bad bad_cpu(.clk(clk_sys),.clk_mem,.clk_cram,.rst_input(rst),.done(done[2]));';assert tb.count(needle)==1;tb=tb.replace(needle,'')
(OUT/'tb.sv').write_text(tb)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
j={'before':'e704c35b/b4df PSRAM, c74/9c405d1a P7 both lanes','P7':sha(ROOT/'rtl/ds/nds_arm7_port.sv'),
   'candidate_PHY':sha(ROOT/'rtl/pocket/nds_psram.sv'),'only_change':'IF4 paired_words aliases existing ld4_pairs (actual commit edge)',
   'sources':{p.name:sha(p)for p in sorted((OUT/'source').glob('*.sv'))},'TB':sha(OUT/'tb.sv')}
(OUT/'sources.json').write_text(json.dumps(j,indent=2)+'\n')
runner=donor['run.py'].decode().replace('ROOT=Path(__file__).resolve().parents[3]',f'ROOT=Path({str(ROOT)!r})').replace("OUT=ROOT/'build/a7critical/ack-consume-owner'",f'OUT=Path({str(OUT)!r})')
start=runner.index("run(next(c for c in layout['cases']")
end=runner.index("assert sha(ROOT/'rtl/ds/nds_arm7_port.sv')",start)
runner=runner[:start]+runner[end:]
runner=runner.replace("'mutant':'actual penultimate-beat handoff fault caught before final ACK'","'mutant':'physical pair/order/owner/reset faults run separately; CPU/P7 unchanged'")
helpers=OUT/'helpers';helpers.mkdir()
for name in['worker_guard.py','sim_ownership.py']:(helpers/name).write_bytes(pinned('sim/arm/read_ack/'+name))
runner=runner.replace("sys.path.insert(0,str(ROOT/'sim/arm/read_ack'))","sys.path.insert(0,str(OUT/'helpers'))")
runner=runner.replace('SEQ2_DONE36+18private+actualbadthresholdfault','IF4_CPU_DONE36+18private; physical faults separate')
(OUT/'run.py').write_text(runner);shutil.copyfile(Path(__file__),OUT/'prepare.py')
print('IF4_CPU_FROZEN',j['candidate_PHY'])
