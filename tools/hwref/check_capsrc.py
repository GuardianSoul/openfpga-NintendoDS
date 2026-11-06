#!/usr/bin/env python3
"""CAP odd-source producer/trace qualification; output values are observations."""
import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
import struct

BASE=0x04000400

def require(ok,message):
    if not ok:raise ValueError(message)


def sha(data):return hashlib.sha256(data).hexdigest()


def cases():
    out=[]
    levels=[1,3,255,257,-1,-3,-255,-257]
    scale=[(127,0),(64,0),(65,2)]
    for k,dc in enumerate(levels):
        for v,(volume,divider) in enumerate(scale):
            for unit in (0,1):out.append(dict(name=f'o{dc}v{volume}d{divider}u{unit}',dc=dc,volume=volume,divider=divider,pan=127 if (k+v)&1 else 0,source_mask=1<<unit,format0=0,unit=unit,paired=False))
    for dc in levels:
        for volume in (127,64):out.append(dict(name=f'b{dc}v{volume}',dc=dc,volume=volume,divider=0,pan=None,source_mask=3,format0=1,unit=None,paired=True))
    return out


def expected_channel(case,ch):
    if case['paired']:
        if ch in (0,2):return case['dc'],case['volume'],0,0 if ch==0 else 127,True
    else:
        if ch==case['unit']*2:return case['dc'],case['volume'],case['divider'],case['pan'],True
        if ch==case['unit']*2+1:return 0x1234,127,0,64,True
    return 0,0,None,64,False


def trace_check(data,definitions):
    require(data[:9]==b'NDSSPU01S','missing SPU trace/snapshot')
    snap=struct.unpack_from('<464I',data,9);start=9+1856
    require((len(data)-start)%12==0,'partial SPU trace record')
    regs=bytearray(0x120)
    def put(off,size,value):regs[off:off+size]=value.to_bytes(4,'little')[:size]
    def u32(off):return struct.unpack_from('<I',regs,off)[0]
    def u16(off):return struct.unpack_from('<H',regs,off)[0]
    for ch in range(16):
        s=snap[4+ch*27:4+(ch+1)*27]
        for off,v in [(0,s[0]),(4,s[1]),(8,s[2]),(10,s[3]//4),(12,s[4]//4)]:put(ch*16+off,2 if off in (8,10)else 4,v)
    for unit in (0,1):
        s=snap[436+unit*14:436+(unit+1)*14];put(0x108+unit,1,s[0]);put(0x110+unit*8,4,s[1]);put(0x114+unit*8,2,s[3]//4)
    sessions=[[],[]];active=[None,None];groups={};mix=0;capture_words=0;first_fetch_offset=None
    for pos in range(start,len(data),12):
        typ,bits,_,addr,value=struct.unpack_from('<BBHII',data,pos)
        if typ==ord('M'):mix+=1;continue
        if typ==ord('W'):
            old=list(regs[0x108:0x10a]);off=addr-BASE;n=bits//8
            if bits in (8,16,32)and 0<=off<=len(regs)-n:put(off,n,value)
            for unit in (0,1):
                cnt=regs[0x108+unit]
                if not(cnt&128 and not old[unit]&128):continue
                index=len(sessions[unit]);require(index<len(definitions),'extra capture start')
                c=definitions[index];fmt8=unit==0 and c['format0'];expected_cnt=0x84|((1 if c['source_mask']&(1<<unit)else 0)<<1)|(8 if fmt8 else 0)
                require(cnt==expected_cnt,f'{c["name"]} unit{unit}: actual capture selector/format differs')
                dest,length=u32(0x110+unit*8),u16(0x114+unit*8)*4
                require(dest%32==0 and length==(256 if fmt8 else 512),'actual capture buffer alignment/length differs')
                channels=[]
                for ch in range(4):
                    control,source=u32(ch*16),u32(ch*16+4);dc,vol,div,pan,used=expected_channel(c,ch)
                    require(control&127==vol and (div is None or(control>>8)&3==div) and(control>>16)&127==pan,f'{c["name"]}: channel volume/divider/pan differs')
                    require((control>>29)&3==1 and(control>>27)&3==1 and u16(ch*16+8)==0xfe00 and u16(ch*16+10)==0 and u32(ch*16+12)==4,'actual PCM16/repeat/timer/loop length differs')
                    channels.append(dict(channel=ch,control=control,source=source,dc=dc,required_fetch=used))
                group=groups.setdefault(index,dict(case=c,channels=channels,fetch_words=[0]*4))
                require(group['channels']==channels,'input channel state changed between capture starts')
                item=dict(index=index,unit=unit,control=cnt,destination=dest,bytes=length,start_mix=mix,words=[],channels=channels)
                sessions[unit].append(item);active[unit]=item
        elif typ==ord('F'):
            indices={a['index']for a in active if a is not None}
            require(len(indices)<=1,'capture pair belongs to different segments')
            for index in indices:
                group=groups[index]
                for ch in group['channels']:
                    if ch['source']<=addr<ch['source']+16:
                        expected=(ch['dc']&0xffff)*0x10001
                        require(value==expected,f'{group["case"]["name"]}: source RAM fetch differs from signed DC input')
                        group['fetch_words'][ch['channel']]+=1
                        if first_fetch_offset is None and ch['required_fetch']:first_fetch_offset=pos
        elif typ==ord('C'):
            eligible=[a for a in active if a is not None and a['destination']<=addr<a['destination']+a['bytes']]
            require(len(eligible)==1,'capture write outside one active buffer')
            item=eligible[0];require(addr==item['destination']+4*len(item['words']),'missing/reordered capture word')
            item['words'].append(value);capture_words+=1
            if len(item['words'])*4==item['bytes']:item['last_mix']=mix;active[item['unit']]=None
    require([len(s)for s in sessions]==[len(definitions),len(definitions)]and all(a is None for a in active),'incomplete capture sessions')
    expected_words=sum((256 if c['format0']else 512)//4+512//4 for c in definitions)
    require(capture_words==expected_words,'wrong complete capture word count')
    for group in groups.values():
        require(all(group['fetch_words'][ch['channel']]>0 for ch in group['channels']if ch['required_fetch']),'required source did not fetch RAM')
    return sessions,dict(capture_sessions=len(definitions)*2,capture_words=capture_words,groups=[dict(index=i,**g)for i,g in sorted(groups.items())],first_required_fetch_record_offset=first_fetch_offset,scope='actual configured inputs, fetch words and capture writes only; no expected odd-value law or startup alignment')


def analyze(directory,trace):
    defs=cases();require((directory/'capsrc_info.txt').read_text().startswith('capsrc odd 1\nbuilt '),'wrong producer info')
    expected='V capsrc odd 1\n'+''.join(f'{v} {c["name"]}\n'for c in defs for v in ['start','done'])+'all done\n'
    require((directory/'capsrc_progress.txt').read_text()==expected,'64 complete ordered segments required')
    with (directory/'capsrc_index.csv').open()as f:rows=list(csv.DictReader(f))
    require([(r['segment'],int(r['unit']))for r in rows]==[(c['name'],u)for c in defs for u in (0,1)],'128 ordered index rows required')
    sessions,state=trace_check(trace.read_bytes(),defs);buffers=[]
    for i,c in enumerate(defs):
        for unit in (0,1):
            row=rows[2*i+unit];s8=unit==0 and c['format0'];require(row['format']==('s8'if s8 else's16')and int(row['samples'])==256 and int(row['unwritten_words'])==int(row['timeout'])==0,'capture format/completion failed')
            p=directory/f'capsrc_{c["name"]}_{"R"if unit else"L"}.bin';b=p.read_bytes();require(len(b)==(256 if s8 else 512),'wrong capture byte count')
            seen=struct.pack('<'+'I'*len(sessions[unit][i]['words']),*sessions[unit][i]['words'])
            require(b==seen,'SD capture bytes differ from actual SPU writes: '+p.name)
            values=struct.unpack('<256'+('b'if s8 else'h'),b)
            buffers.append(dict(segment=c['name'],unit=unit,format=row['format'],bytes=len(b),sha256=sha(b),min=min(values),max=max(values),value_counts=dict(Counter(values)),start_mix=sessions[unit][i]['start_mix'],last_mix=sessions[unit][i]['last_mix'],capture_control=sessions[unit][i]['control']))
    return dict(output_complete=True,software_inputs_qualified=True,segments=64,buffers=128,samples=32768,trace_sha256=sha(trace.read_bytes()),state=state,observed_buffers=buffers,
                artifacts_sha256={p.name:sha(p.read_bytes())for p in sorted(directory.glob('capsrc*'))if p.is_file()},
                status='Census software qualification only. Raw startup and all sample values retained; odd-rounding, paired8/16 behavior and DS timing remain unmeasured.')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path);p.add_argument('--spu-trace',type=Path,required=True);a=p.parse_args();print(json.dumps(analyze(a.directory,a.spu_trace),indent=2,sort_keys=True))
