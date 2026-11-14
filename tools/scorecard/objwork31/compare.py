#!/usr/bin/env python3
"""Compare full raw16 captures; no ROI, threshold, frame search or retiming."""
import argparse
import array
import hashlib
import json
from pathlib import Path
import re
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def pixels(p):
    a=array.array('H',p.read_bytes());assert len(a)==49152,p
    return a
def compare(out):
    m=json.loads((out/'manifest.json').read_text())
    for root,key in [('inputs','inputs'),('source','source'),('golden','golden')]:
        for n,h in m[key].items():assert sha(out/root/n)==h,(root,n)
    records=json.loads((out/'processes.json').read_text());assert [r['exit']for r in records]==[0,0],records
    text=(out/'native.log').read_text()
    status=re.findall(r'OBJWORK (\S+) pixels=(\d+) rgbdiff=(\d+) capdiff=(\d+) statebad=(\d+) memory_equal=(\d) unique=(\d+)/(\d+)',text)
    assert len(status)==20 and len({v[0]for v in status})==20
    assert all(list(map(int,r[1:]))==[98304,0,0,0,1,49152,49152]for r in status),status
    rows=[]
    def row(name,raw):
        a=out/'captures'/(name+'-rtl.bin');g=out/'captures'/(name+'-gold.bin')
        assert a.read_bytes()==g.read_bytes(),name
        u,v=pixels(a),pixels(raw);diff=[i for i,(x,y)in enumerate(zip(u,v))if x!=y]
        rows.append(dict(fixture=name,DS_file=raw.name,DS_sha256=sha(raw),native_sha256=sha(a),gold_sha256=sha(g),
                         pixels=49152,different_pixels=len(diff),first_differences=[[i%256,i//256,u[i],v[i]]for i in diff[:8]]))
    for load in range(3):
        for b in range(2):
            for stress in range(2):
                for rep in range(2):row(f'run38-load{load}-b{b}',out/'inputs/run38'/f'load2d_{load}_{b}_{stress}_f{rep}.bin')
    for run,prefix,count in [(39,'objlimit_v2',6),(40,'objwork_v1',8)]:
        for k in range(count):row(f'run{run}-k{k}',out/f'inputs/run{run}'/f'{prefix}_k{k}.bin')
    result=dict(source_base=m['base'],model_sha256=sha(out/'obj/Vgpu2d'),manifest_sha256=sha(out/'manifest.json'),
                native_log_sha256=sha(out/'native.log'),frames=20,lines=3840,RGB_pixels=1966080,
                raw_DS_comparisons=38,raw_DS_pixels=38*49152,all_raw_DS_exact=all(r['different_pixels']==0 for r in rows),
                rows=rows,state_scope='All terminal physical memory including capture, loaded palette/OAM/state words, idle jobs; no CPU or post-release game state claim')
    (out/'comparison.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items()if k!='rows'},indent=2))
    print('DS differences:',[(r['DS_file'],r['different_pixels'])for r in rows])
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('output',type=Path);a=p.parse_args();compare(a.output.resolve())
