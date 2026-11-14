#!/usr/bin/env python3
"""Pin baseline fixture parity against independent qualified full-system captures."""
import hashlib
import json
from pathlib import Path
import sys
import tarfile
MAIN=Path('/home/user/Git/NDS_Pocket')
def sha(data):return hashlib.sha256(data).hexdigest()
def check(out):
    records=[]
    def compare(name,raw,origin):
        gold=out/'captures'/(name+'-gold.bin');assert gold.read_bytes()==raw,(name,origin)
        records.append(dict(fixture=name,bytes=len(raw),sha256=sha(raw),independent_origin=origin))
    root=Path('/home/user/Git/NDS_Pocket-codex-shell/build/load2d-run38-qualified-v2/census')
    pinned=json.loads((MAIN/'docs/results/run38-load2d-core-20261031/plan.json').read_text())
    for load in range(3):
        for b in range(2):
            for stress in range(2):
                for rep in range(2):
                    name=f'load2d_{load}_{b}_{stress}_f{rep}.bin';data=(root/name).read_bytes()
                    assert sha(data)==pinned['census_sha256'][name]
                    compare(f'run38-load{load}-b{b}',data,str(root/name))
    archives={39:MAIN/'docs/results/objlimit-v2-census-20261101/software-evidence.tar.gz',
              40:MAIN/'docs/results/objwork-v1-20261101/evidence.tar.gz'}
    archive_hashes={}
    for run,path in archives.items():
        archive_hashes[str(path)]=sha(path.read_bytes())
        with tarfile.open(path)as tar:
            for k in range(6 if run==39 else 8):
                member=f'outputs/objlimit_v2_k{k}.bin'if run==39 else f'results/positive/sd/hwref/objwork-v1/objwork_v1_k{k}.bin'
                data=tar.extractfile(member).read();compare(f'run{run}-k{k}',data,str(path)+':'+member)
    result=dict(baseline_full_system_parity=True,raw16_comparisons=len(records),pixels=len(records)*49152,
                archive_sha256=archive_hashes,comparisons=records,
                scope='Standalone copied renderer/producer fixture equals independently executed qualified full-system Census outputs; no new Census rule qualification')
    (out/'reference-parity.json').write_text(json.dumps(result,indent=2)+'\n')
    print('Independent full-system parity:',len(records),'complete frames, exact raw16')
if __name__=='__main__':check(Path(sys.argv[1]).resolve())
