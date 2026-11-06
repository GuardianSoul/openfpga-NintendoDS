#!/usr/bin/env python3
"""Read actual same-seed whole/WRAM demand; do not infer RAM from bit count."""
from pathlib import Path
import argparse,importlib.util,json,os,resource

R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--fits',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
p.add_argument('--candidate',required=True)
a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10)
resource.setrlimit(resource.RLIMIT_CPU,(30,30));resource.setrlimit(resource.RLIMIT_AS,(512*1024**2,512*1024**2))
spec=importlib.util.spec_from_file_location('fit_resources',R/'tools/fit/resources.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
rows=[]
for build in ['1188','1192',a.candidate]:
    D=a.fits/build
    fit=m.read(D/'apf_top.fit.rpt');mapping=m.read(D/'apf_top.map.rpt')
    needed,ram,dsp,labs=m.resources(fit,mapping)
    assert needed is not None and ram is not None and dsp is not None
    entities=m.table(fit,'Fitter Resource Utilization by Entity','Compilation Hierarchy Node')
    rams=m.table(fit,'Fitter RAM Summary','Name')
    path='|apf_top|core_top:ic|nds_top:ds|arm7_wram:u_wram'
    own=next(r for r in entities if r['Full Hierarchy Name']==path)
    prefix=path+'|'+('nds_tdp_ram'if build=='1188'else'arm7_wram_dense')+':u_private'
    private=next(r for r in entities if r['Full Hierarchy Name']==prefix)
    memory=[r for r in rams if 'arm7_wram:u_wram|'in r['Name']]
    private_ram=[r for r in memory if ':u_private|'in r['Name']]
    ownram=sum(int(r['M10K blocks'])for r in memory)
    pram=sum(int(r['M10K blocks'])for r in private_ram)
    rows.append(dict(fit=int(build),whole=[needed,int(ram),dsp],
        WRAM=[m.number(own[m.NEEDED_COLUMN]),ownram,int(m.number(own['DSP Blocks']))],
        private=[m.number(private[m.NEEDED_COLUMN]),pram,int(m.number(private['DSP Blocks']))],RAM_rows=memory,
        timing='LABs unavailable, timing FAIL (STA not reached), seed1asR — Codex',
        result=(D/'result.txt').read_text()))
before=rows[0];after=rows[-1]
result=dict(seed='1asR',clock_ns=14.92,rows=rows,
    whole_delta=[round(b-a,3)for a,b in zip(before['whole'],after['whole'])],
    WRAM_delta=[round(b-a,3)for a,b in zip(before['WRAM'],after['WRAM'])],
    private_delta=[round(b-a,3)for a,b in zip(before['private'],after['private'])],
    prior_trial='1192 REJECT: auto slicing used20M10K/bank; algebraic capacity did not prove mapping.',
    accepted_expected_mapping=after['private'][1]==52,
    limits='Actual synthesis/fitter demand only. Complete design still exceeds capacity; neither placement nor 67/134MHz STA qualified. Core/DS speed/audio/frame failures remain open.')
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items()if k not in ['rows']},indent=2))
