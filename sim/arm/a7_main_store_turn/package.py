#!/usr/bin/env python3
"""Seal the completed bounded run, including failed harness inputs/logs."""
from pathlib import Path
import hashlib, json, shutil, subprocess, tarfile

ROOT=Path(__file__).resolve().parents[3]
B=ROOT/'build/a7-main-store-turn'
D=ROOT/'docs/results/arm7-main-store-turn-20261101'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert json.loads((B/'worker.json').read_text())['phase']=='Terminal PASS leaf'
for row in (B/'processes.jsonl').read_text().splitlines():
    r=json.loads(row);p=Path(f'/proc/{r["PID"]}/stat')
    assert not p.exists()or p.read_text().rsplit(')',1)[1].split()[19]!=r['starttime'],r
for n in ['before','default','enabled']:
    assert 'STORE_LEAF_PASS cases12 writes20'in(B/n/'run.log').read_text()
assert len(json.loads((B/'coupled.json').read_text())['rows'])==3
P=B/'production';P.mkdir(exist_ok=True)
rels=['rtl/ds/nds_arm7_port.sv','rtl/arm/cpu_domain.sv','rtl/ds/nds_top.sv','rtl/pocket/core_top_ds.sv']
production={}
for rel in rels:
    shutil.copyfile(ROOT/rel,P/Path(rel).name);production[Path(rel).name]=sha(ROOT/rel)
for n in ['run.py','package.py','tb_leaf.sv','tb_cpu.sv','main.s']:
    shutil.copyfile(ROOT/'sim/arm/a7_main_store_turn'/n,B/('controller-'+n))
unchanged={}
for rel in ['rtl/arm/arm7_ds.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_mr_arb.sv','rtl/pocket/nds_psram.sv']:
    raw=subprocess.check_output(['git','show','96f2bcd6:'+rel],cwd=ROOT)
    assert raw==(ROOT/rel).read_bytes();unchanged[rel]=sha(ROOT/rel)
(B/'source.json').write_text(json.dumps(dict(before='96f2bcd6',production=production,unchanged=unchanged,
    defaults=dict(A7_MAIN_STORE_TURN=0,A7_DATA_ACK=0),coupled_test=dict(IRQ=[0,1],loops=[4,16],DATA_ACK_HANDOFF=0),
    inherited_cpu_proof='96f2bcd6/8720c1d6: unchanged CPU; no new private Thumb or25DENSE claim'),indent=2)+'\n')
subprocess.run(['python3',ROOT/'tools/ds/qlint.py'],cwd=ROOT,check=True,stdout=(B/'qlint.log').open('w'))
subprocess.run(['git','diff','--check'],cwd=ROOT,check=True)
members={}
with tarfile.open(D/'evidence.tar.gz','w:gz')as t:
    for p in sorted(B.rglob('*')):
        if not p.is_file():continue
        if p.suffix in ['.o','.a','.d','.gch','.cpp','.h','.mk','.dat']:continue
        name=str(p.relative_to(B));members[name]=sha(p);t.add(p,arcname=name,recursive=False)
receipt=dict(before='96f2bcd6',archive_sha256=sha(D/'evidence.tar.gz'),archive_bytes=(D/'evidence.tar.gz').stat().st_size,
             production=production,unchanged=unchanged,members=members,
             disposition='component qualified, default0; affected native MAIN timing remains open')
(D/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
subprocess.run(['python3',D/'replay.py'],check=True,cwd=ROOT)
print('SEALED',receipt['archive_bytes'],'bytes',len(members),'members',receipt['archive_sha256'])
