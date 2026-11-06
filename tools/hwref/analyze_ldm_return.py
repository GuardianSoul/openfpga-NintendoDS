#!/usr/bin/env python3
"""Analyze qualified LDM return timing; never substitute an emulator target."""
from collections import Counter
import argparse
import contextlib
import csv
from fractions import Fraction
import io
import json
from pathlib import Path
from check_arm9ldm import check, CASES


def context(path):
    lines=path.read_text().splitlines();result={}
    for tag in ('initial','uncached','restored'):
        row=next(s for s in lines if s.startswith(tag+' ctrl='))
        result[tag]={k:int(v,16) for k,v in (x.split('=') for x in row.split()[1:])}
        result[tag]['regions']=[int(next(s for s in lines if s.startswith(f'{tag} region{i}=')).split('=')[1],16) for i in range(8)]
    assert result['initial']==result['restored'],'CP15 was not restored'
    initial=result['initial'];assert result['uncached']==dict(initial,dc=initial['dc']&~2,wb=initial['wb']&~2),'unexpected C/B context'
    return result


def analyze(root):
    checked=io.StringIO()
    with contextlib.redirect_stdout(checked):check(root)
    times=list(csv.DictReader((root/'times.csv').open()));groups=[];repeat=Counter()
    for i in range(0,len(times),12):
        rows=times[i:i+12];lengths=[]
        for n in (256,1024):
            observed=[int(r['ticks']) for r in rows if int(r['blocks'])==n and int(r['rep'])>=0]
            warm=[int(r['ticks']) for r in rows if int(r['blocks'])==n and int(r['rep'])==-1]
            assert len(observed)==5 and len(warm)==1
            hits=observed.count(min(observed));repeat[hits]+=1
            lengths.append(dict(blocks=n,warm=warm[0],samples=observed,min=min(observed),max=max(observed),span=max(observed)-min(observed),minimum_occurrences=hits))
        short,long=lengths;slope=Fraction(long['min']-short['min'],768)
        groups.append(dict(case=rows[0]['case'],words=int(rows[0]['words']),offset_bytes=int(rows[0]['offset_bytes']),lengths=lengths,
                           cycles_per_block=float(slope),slope_fraction=str(slope),
                           paired_rep_slopes=[(b-a)/768 for a,b in zip(short['samples'],long['samples'])],
                           observed_envelope=[(long['min']-short['max'])/768,(long['max']-short['min'])/768]))
    # A compact description of the measured alignment residuals. Count exact
    # source addresses, without treating the matching accounting as a bus trace.
    accounting=[]
    for g in groups:
        name=g['case'];off=g['offset_bytes'];first28=0
        if name in ('ldm2','ldm4','ldm8_anchor','split2','split4'):
            chunk=2 if name in ('ldm2','split2') else 4 if name in ('ldm4','split4') else 8
            words=8 if name.startswith('split')else chunk
            for block in range(16):
                for part in range(words//chunk):
                    if (off+4*(block*words+part*chunk))%32==28:first28+=1
            instructions=words//chunk
            base=Fraction(2*words+7*instructions)+Fraction(1,8)
            predicted=base+Fraction(7*first28,16)
            actual=Fraction(g['slope_fraction']);assert actual==predicted,(name,off,actual,predicted)
            accounting.append(dict(case=name,offset_bytes=off,LDM_words=chunk,first_word_mod32_28_per16blocks=first28,
                                   base_description='2SYS/word +7SYS/load-instruction +0.125SYS/block, in the measured progressing forms',
                                   predicted_cycles_per_block=float(predicted),measured_cycles_per_block=float(actual),residual=0))
    return dict(checker_stdout=checked.getvalue(),cases=53,raw_times=636,measured_samples=530,warm_times=106,register_signatures=106,
                clock='33513982Hz timer/system cycles;2ARM9 clocks per tick',unit='one block as defined by producer; split/scalar blocks contain8words and2/4/8 load instructions',
                repeatability=dict(minimum_occurrence_distribution=dict(repeat),worst_short_span=max(g['lengths'][0]['span'] for g in groups),
                                  worst_long_span=max(g['lengths'][1]['span'] for g in groups),scope='within this one execution,5 measured samples per length; envelopes are observed ranges, not confidence intervals'),
                CP15=context(root/'info.txt'),groups=groups,streaming_accounting=accounting,
                limits='First-word-mod32 accounting fits observed aggregate residuals; no per-word DS bus events, unmeasured offset28 LDM8, or universal N/S/prefetch rule inferred. Fixed kernels include extra pointer resets and repeated addresses; no common NOP-baseline subtraction applied.')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path);a=p.parse_args()
    print(json.dumps(analyze(a.directory),indent=2)+'\n',end='')
