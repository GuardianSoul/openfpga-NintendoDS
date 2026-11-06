#!/usr/bin/env python3
"""Compiler-free replay of the frozen tag-tail result; no simulations."""
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys


def sha(b):
    return hashlib.sha256(b).hexdigest()


def simulation(s):
    s = s.split('endmodule',1)[0]
    stack, out, active = [], [], True
    for line in s.splitlines():
        if line.strip().startswith('`ifdef'):
            stack.append(active); active=False
        elif line.strip()=='`else':
            active=stack[-1]
        elif line.strip()=='`endif':
            active=stack.pop()
        elif active:
            out.append(line)
    s='\n'.join(out)
    s=re.sub(r'/\*.*?\*/','',s,flags=re.S)
    s=re.sub(r'//[^\n]*','',s)
    s=re.sub(r'localparam bit TAG_TAIL\s*=.*?;','',s,flags=re.S)
    return re.sub(r'\s+','',s)


def main(root):
    manifest=json.loads((root/'manifest.json').read_text())
    for name,digest in manifest['files'].items():
        assert sha((root/name).read_bytes())==digest, 'file hash: '+name
    spec=importlib.util.spec_from_file_location('resources',root/'resources.py')
    resources=importlib.util.module_from_spec(spec);spec.loader.exec_module(resources)
    fits={}
    for num in (1198,1202):
        p=root/'fits'/str(num)
        fit=resources.read(p/'fit.rpt.gz');mapping=resources.read(p/'map.rpt.gz')
        values=resources.resources(fit,mapping)
        entities=resources.table(fit,'Fitter Resource Utilization by Entity','Compilation Hierarchy Node')
        rams=resources.table(fit,'Fitter RAM Summary','Name')
        tags=[e for e in entities if e.get('Full Hierarchy Name','').endswith(('arm9_ram:u_dtag','arm9_ram:u_itag'))]
        tag_alms=sum(resources.number(e[resources.NEEDED_COLUMN]) for e in tags)
        owned=[r for r in rams if '|arm9_ram:' in r['Name']]
        tagr=[r for r in owned if ':u_dtag|' in r['Name'] or ':u_itag|' in r['Name']]
        fits[str(num)]=dict(whole=values,tag_ALM=round(tag_alms,1),
                           backend_M10K=sum(int(r['M10K blocks']) for r in owned),
                           tag_M10K=sum(int(r['M10K blocks']) for r in tagr))
        assert 'Failed' in resources.read(p/'fit.summary.gz')
    assert fits['1198']['whole']==(23016.5,371.0,72,None)
    assert fits['1202']['whole']==(23061.5,363.0,72,None)
    assert (fits['1198']['tag_ALM'],fits['1202']['tag_ALM'])==(0.8,51.2)
    assert (fits['1198']['backend_M10K'],fits['1202']['backend_M10K'])==(80,72)
    assert (fits['1198']['tag_M10K'],fits['1202']['tag_M10K'])==(16,8)

    before=json.loads((root/'trees/before.json').read_text())
    after=json.loads((root/'trees/after.json').read_text())
    assert before.keys()==after.keys()
    assert [n for n in before if before[n]!=after[n]]==['rtl/arm/arm9_ram.sv']
    for name,blob in before.items():
        b=(root/'before'/name).read_bytes()
        assert hashlib.sha1(b'blob '+str(len(b)).encode()+b'\0'+b).hexdigest()==blob
    old=(root/'before/rtl/arm/arm9_ram.sv').read_text()
    new=(root/'candidate.sv').read_text()
    assert simulation(old)==simulation(new), 'behavioral module/import namespace changed'
    b=new.encode()
    assert hashlib.sha1(b'blob '+str(len(b)).encode()+b'\0'+b).hexdigest()==after['rtl/arm/arm9_ram.sv']
    mutation=(root/'native/mutant.sv').read_text()
    oldbit='.data(a_d[t*LANE_W+20 +: LANE_W-20]),'
    badbit=".data(a_d[t*LANE_W+20 +: LANE_W-20] ^ ((LANE_W-20)'(1))),"
    assert new.count(oldbit)==1 and new.replace(oldbit,badbit)==mutation
    expected=[(5,24,17952,168996),(6,22,28736,270466)]
    for f in ['native/pass.log','behavioral/run.log']:
        log=(root/f).read_text()
        rows=[tuple(map(int,m)) for m in re.findall(r'PASS_TAG AW=(\d+) W=(\d+) cycles=(\d+) defined_lane_reads=(\d+)',log)]
        assert rows==expected and 'PASS_BOTH_TAGS' in log, 'proof count '+f
    log=(root/'native/mutant.log').read_text()
    assert 'CANDIDATE_A AW5 cycle32 lane0 expected000001 got100001' in log
    behavioral=json.loads((root/'behavioral/result.json').read_text())
    assert behavioral['status']=='PASS' and behavioral['NI']==10
    assert all(j['NI']==10 and j['exit']==0 and j['reaped'] for j in behavioral['jobs'])
    assert behavioral['source_sha256']['candidate.sv']==sha(new.encode())
    assert behavioral['source_sha256']['tb.sv']==sha((root/'tb.sv').read_bytes())
    assert (root/'qlint.log').read_bytes()==b''
    result=dict(status='PASS',source=manifest['source'],parent=manifest['parent'],fits=fits,
                owned_tag_delta=dict(ALM=50.4,M10K=-8,DSP=0),
                whole_delta=dict(ALM=45.0,M10K=-8,DSP=0),
                native=dict(cycles=46688,defined_lane_reads=439462,actual_mutant_caught=True),
                behavioral_literal=True,unchanged_other_RTL=len(before)-1,
                limits='No placement/LAB/STA or DS timing acceptance; before/after preserve one-cycle ports and SIM import namespace.')
    expected_result=root/'analysis.json'
    encoded=json.dumps(result,indent=2,sort_keys=True)+'\n'
    if expected_result.exists():
        assert expected_result.read_text()==encoded, 'analysis differs'
    else:
        expected_result.write_text(encoded)
    print(json.dumps(result))


if __name__=='__main__':
    main(Path(sys.argv[1] if len(sys.argv)>1 else '.').resolve())
