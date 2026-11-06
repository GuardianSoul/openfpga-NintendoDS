#!/usr/bin/env python3
"""Strict ARM7 fetch-probe software/output qualification; never a DS timing oracle."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import struct


def require(ok,message):
    if not ok:raise ValueError(message)


def sha(b):return hashlib.sha256(b).hexdigest()


def fnv(b):
    v=2166136261
    for x in b:v=((v^x)*16777619)&0xffffffff
    return v


def analyze(directory,layout,cases):
    require((directory/'arm7fetch_v1_info.txt').read_text().startswith('arm7fetch v1; built '),'wrong producer information')
    with (directory/'arm7fetch_v1_setup.csv').open() as f:setup={r['field']:int(r['value_hex'],16) for r in csv.DictReader(f)}
    helper=layout['helper'];require([setup[k] for k in ['helper_entry','itcm_base','itcm_bytes']]==[helper[k] for k in ['entry','itcm_base','itcm_bytes']],'helper placement differs')
    require(setup['result_bytes']==4448 and setup['result_pointer']>>24==2 and setup['result_pointer']%32==0,'result ABI/placement differs')
    require(setup['result_arm9_alias']==((setup['result_pointer']&0x3fffff)|0x02000000),'wrong ARM9 MAIN alias')
    image=(directory/'arm7fetch_v1_helper_itcm.bin').read_bytes()
    require(len(image)==helper['itcm_bytes'],'runtime ITCM image size differs')
    lo=helper['initialized_base']-helper['itcm_base'];n=helper['initialized_bytes']
    require(sha(image[lo:lo+n])==helper['initialized_sha256'],'runtime initialized ITCM code differs')
    at=helper['entry']-helper['itcm_base'];require(sha(image[at:at+helper['bytes']])==helper['sha256'],'runtime helper differs')
    with (directory/'arm7fetch_v1.csv').open() as f:rows=list(csv.DictReader(f))
    order=[(c['id'],region,rep,loops) for c in cases for region in (0,1) for rep in range(5) for loops in (4,16)]
    require([(int(r['case_id']),int(r['region']),int(r['rep']),int(r['loops'])) for r in rows]==order,'360 ordered raw samples required')
    journal=''.join(f'{verb} k{c["id"]:02d}_r{region}\n' for c in cases for region in (0,1) for verb in ('start','done'))
    require((directory/'arm7fetch_v1_progress.txt').read_text()==journal,'36 complete START/DONE groups required')
    summaries=[];linked={x['id']:x for x in layout['cases']}
    for c in cases:
        l=linked[c['id']]
        for region in (0,1):
            name=f'arm7fetch_v1_k{c["id"]:02d}_r{region}.bin';b=(directory/name).read_bytes()
            require(len(b)==4448,'wrong result binary size: '+name)
            h=struct.unpack_from('<16I',b)
            dst=l['main_entry'] if region else l['source_entry'];body=l['main_body'] if region else l['source_body']
            require(h[:6]==(0x41463731,1,c['id'],region,0,l['size']),'producer identity/error/size differs: '+name)
            require(h[6:12]==(l['source_entry'],l['source_body'],l['source_end'],dst,body,dst+l['size']),'actual code placement differs: '+name)
            require(h[12:15]==(l['code_fnv'],l['code_fnv'],1),'copy/FNV guard failed: '+name)
            code=b[348:348+l['size']]
            require(sha(code)==l['code_sha256'] and fnv(code)==h[12],'code snapshot differs from linked ELF: '+name)
            actual_name=b[304:328].split(b'\0')[0].decode()
            kind=('alu','branch','ring').index(c['kind']);cfg=struct.unpack_from('<5I',b,328)
            require(actual_name==c['name'] and cfg==(kind,c['offset'],c['stride'],c['nodes'],c['checksum']),'case metadata differs: '+name)
            short,long=[],[]
            for rep in range(5):
                for length,loops in enumerate((4,16)):
                    sample=struct.unpack_from('<6I',b,64+(rep*2+length)*24)
                    require(sample[0]==loops and sample[1]>0 and sample[2]==c['checksum'] and sample[3]==c['checksum']*loops,'timing/checksum failed: '+name)
                    require(0<=sample[4]<263 and 0<=sample[5]<263,'VCOUNT out of range: '+name)
                    row=rows[((c['id']*2+region)*5+rep)*2+length]
                    require(row['name']==c['name'] and [int(row[k]) for k in ['kind','offset','stride','nodes','checksum_per_loop','error']]==[kind,c['offset'],c['stride'],c['nodes'],c['checksum'],0],'CSV metadata differs')
                    require([int(row[k]) for k in ['loops','ticks','warm_checksum','checksum','start_line','end_line']]==list(sample),'CSV contradicts binary samples')
                    require([int(row[k],16) for k in ['entry','body','end']]==[dst,body,dst+l['size']],'CSV code placement differs')
                    (long if length else short).append(sample[1])
            a,z=min(short),min(long);require(z>a,'nonpositive independent-minimum slope')
            summaries.append(dict(case_id=c['id'],name=c['name'],region='MAIN' if region else 'private_WRAM',kind=c['kind'],
                                  body_offset=c['offset'],stride=c['stride'],nodes=c['nodes'],unit=c['unit'],units_per_loop=64,
                                  ticks4=short,ticks16=long,min4=a,min16=z,cycles_per_unit=(z-a)/(12*64),
                                  unit_scope='whole rounds: SUBS, checksum ADD and2/3 branches included' if c['kind']=='ring' else '64 body ops per loop; no loop bookkeeping subtraction',
                                  entry=dst,body=body,end=dst+l['size'],code_sha256=l['code_sha256']))
    return dict(output_complete=True,software_inputs_qualified=True,groups=36,raw_timings=360,warm_checksums=360,
                helper=helper,summaries=summaries,
                artifacts_sha256={p.name:sha(p.read_bytes()) for p in sorted(directory.glob('arm7fetch_v1*')) if p.is_file()},
                status='Software/producer provenance must be supplied separately; no DS measurement, N/S law or core timing acceptance implied')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path);p.add_argument('--layout',type=Path,required=True);p.add_argument('--cases',type=Path,default=Path(__file__).resolve().parents[2]/'sw/hwref/arm7fetch/cases.json');a=p.parse_args()
    print(json.dumps(analyze(a.directory,json.loads(a.layout.read_text()),json.loads(a.cases.read_text())),indent=2,sort_keys=True))
