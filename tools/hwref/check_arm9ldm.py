#!/usr/bin/env python3
"""Check bounded LDM capture completeness/data; impose no timing target."""
import argparse
import csv
from pathlib import Path

CASES = dict(ldm1=(1,False),ldm2=(2,False),ldm4=(4,False),ldm8_anchor=(8,False),
             fixed1=(1,True),fixed2=(2,True),fixed4=(4,True),fixed8=(8,True),
             split4=(8,False),split2=(8,False),scalar8=(8,False),gap4=(8,False),
             dep4=(8,False),nop16=(0,False))
def check(root):
    times=list(csv.DictReader((root/'times.csv').open()))
    signatures=list(csv.DictReader((root/'signatures.csv').open()))
    expected=[(case,off,n) for case,(words,_) in CASES.items()
              for off in range(0,16 if words else 4,4) for n in (256,1024)]
    assert len(times)==636 and len(signatures)==106, 'incomplete rows'
    wanted=[(case,off,n,rep) for case,off,n in expected for rep in range(-1,5)]
    assert [(r['case'],int(r['offset_bytes']),int(r['blocks']),int(r['rep'])) for r in times]==wanted,'time ordering'
    assert [(r['case'],int(r['offset_bytes']),int(r['blocks'])) for r in signatures]==expected,'signature ordering'
    for r in times:
        assert int(r['words'])==CASES[r['case']][0] and int(r['ticks'])>0,'invalid time'
    for r in signatures:
        words,fixed=CASES[r['case']]
        first=int(r['offset_bytes'])//4+(128 if fixed else 15*words)
        assert int(r['words'])==words and r['ok']=='1', ('producer signature failure',r['case'])
        actual=[int(r[f'r{x}'],16) for x in range(2,10)]
        want=[((first+i)*0x9e3779b9)&0xffffffff if i<words else 0 for i in range(8)]
        assert actual==want,(r['case'],actual,want)
        assert all(actual[i]!=0 for i in range(words)), "zero active register"
    assert (root/'DONE.txt').read_text()=='PASS 53 cases 106 signatures\n','no successful completion'
    assert not (root/'FAILED.txt').exists(),'failed capture'
    info=(root/'info.txt').read_text()
    assert 'cases=53 checks=106 failures=0 pass=1' in info
    print('PASS: 53 cases, 636 raw timings, 106 independent register signatures; timing unqualified')
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path)
    check(p.parse_args().root)
