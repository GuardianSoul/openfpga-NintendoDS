#!/usr/bin/env python3
"""Validate every native run39 kernel/result and compare raw DS slopes."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
from build import captured

def read_record(raw,c,region):
    assert len(raw)==4448
    head=struct.unpack_from('<16I',raw)
    expected=(0x41463731,1,c['id'],region,0,c['size'],c['source_entry'],c['source_body'],c['source_end'])
    assert head[:9]==expected,('header',c['case'],region,head)
    entry=c['main_entry'] if region else c['source_entry']
    assert head[9:15]==(entry,entry+c['source_body']-c['source_entry'],entry+c['size'],c['code_fnv'],c['code_fnv'],1)
    assert hashlib.sha256(raw[348:348+c['size']]).hexdigest()==c['code_sha256'],('kernel',c['case'])
    meta=struct.unpack_from('<5I',raw,328)
    samples=[]
    for rep in range(5):
        for length,loops in enumerate((4,16)):
            s=struct.unpack_from('<6I',raw,64+24*(2*rep+length))
            assert s[0]==loops and s[1]>0 and s[2]==meta[4] and s[3]==meta[4]*loops,('sample',c['case'],rep,length,s)
            assert s[4]<263 and s[5]<263
            samples.append(dict(rep=rep,loops=s[0],ticks=s[1],warm=s[2],checksum=s[3],start_line=s[4],end_line=s[5]))
    mins=[min(s['ticks'] for s in samples if s['loops']==loops) for loops in (4,16)]
    return dict(name=c['case'],region=region,minimum4=mins[0],minimum16=mins[1],cycles=(mins[1]-mins[0])/768,samples=samples,metadata=meta)

def check(main,log=None):
    files,layout=captured();assert len(main)==4*1024*1024
    status=struct.unpack_from('<40I',main,0x230000)
    assert status[:3]==(0x41463731,36,0) and not any(status[4:40]),('native status',status)
    assert struct.unpack_from('<5I',main,0x3f0000)==(0x52545344,1,1,1,36)
    helper=files['arm7fetch_v1_helper_itcm.bin']
    assert main[0x231000:0x231000+len(helper)]==helper,'runtime ITCM helper before'
    assert main[0x232000:0x232000+len(helper)]==helper,'runtime ITCM helper after'
    rows=[]
    for c in layout['cases']:
        at=c['main_entry']&0x3fffff
        assert hashlib.sha256(main[at:at+c['size']]).hexdigest()==c['code_sha256'],('runtime MAIN slot',c['case'])
        for region in (0,1):
            i=c['id']*2+region;raw=main[0x200000+i*0x1200:0x200000+i*0x1200+4448]
            native=read_record(raw,c,region)
            ds=read_record(files[f'arm7fetch_v1_k{c["id"]:02d}_r{region}.bin'],c,region)
            assert native['metadata']==ds['metadata']
            rows.append(dict(case=c['case'],region=region,core=native['cycles'],DS=ds['cycles'],ratio=native['cycles']/ds['cycles'],core_min=[native['minimum4'],native['minimum16']],DS_min=[ds['minimum4'],ds['minimum16']],samples=native['samples']))
    verdict={'groups':len(rows),'samples':sum(len(r['samples']) for r in rows),'all_kernel_snapshots':True,'all_runtime_MAIN_slots':True,'both_runtime_ITCM_helpers':True,'all_checksums':True,'rows':rows,
             'scope':'Exact run39 kernel bytes/PCs and ITCM helper. Native minimal boot and rebuilt wrapper differ from DS Calico; no N/S or retention law inferred.'}
    if log is not None:
        for label in ('DS_CACHE_ROUTE','DS_GX_ROUTE','JOINED_ROUTES','REFERENCE28_ROUTE','REFERENCE_NEXT_ROUTE','REFERENCE_CLOSURE_ROUTE','REFERENCE_MEMORY_ROUTE','REFERENCE_IO_ROUTE','REFERENCE_CPU_ACK_ROUTE'):
            assert label+'_OK' in log and label+'_ERROR' not in log,('combined route',label)
        assert re.search(r'^result: magic 52545344 checks 1 mask 00000001 done 1$',log,re.M)
        assert re.search(r'^PASS$',log,re.M) and log.count('Verilog $finish')==1
        assert not re.search(r'^FAIL$|%Error|%Fatal|TIMEOUT|Assertion failed',log,re.M)
        assert re.search(r'^models: sdram errors 0, cram errors 0/0;',log,re.M)
        assert re.search(r'^vmcheck: .*?, 0 mismatches$',log,re.M)
        assert re.search(r'^video: [1-9]\d* frames, 0 errors;.*?underruns 0$',log,re.M)
        verdict['models_clean']=True
        verdict['VM_scope']='Both displays forced blank:0 reads/0 mismatches, not VRAM data-path coverage'
    return verdict

def mutations(main):
    # Real captured result mutations: kernel data, warm/timed checksums and
    # case/address descriptors are all independently rejected.
    caught=[]
    for label,at in [('code',0x200000+348+16),('warm',0x200000+64+8),('timed',0x200000+64+12),('entry',0x200000+36),('last-sample',0x200000+35*0x1200+64+9*24+12)]:
        bad=bytearray(main);bad[at]^=1
        try:check(bad)
        except AssertionError:caught.append(label)
        else:raise AssertionError('mutation survived: '+label)
    return caught

def main():
    p=argparse.ArgumentParser();p.add_argument('dump',type=Path);p.add_argument('--log',type=Path);p.add_argument('--out',type=Path);a=p.parse_args()
    data=a.dump.read_bytes();result=check(data,a.log.read_text() if a.log else None);result['mutations_caught']=mutations(data)
    if a.out:a.out.write_text(json.dumps(result,indent=2)+'\n')
    for r in result['rows']:print(f'{r["case"]:12s} {"MAIN" if r["region"] else "WRAM"}: core {r["core"]:.6f} DS {r["DS"]:.6f} {r["ratio"]:.3f}x')
    print('PASS36 exact kernel/descriptor pairs;360 timings/checksums;5 actual result mutations caught')

if __name__=='__main__':main()
