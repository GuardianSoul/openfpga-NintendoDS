#!/usr/bin/env python3
"""Check the new producer's raw protocol, journal and live bytes; no DS timing target."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import struct
from check_arm7thumb import Elf, fnv, require, words

SOURCE = ['protocol.h','arm7.c','measure.c','main.c','quiet.itcm.c','Makefile',
          '../common/hwref.c','../common/hwref.h','../Makefile','../wramarb/linker.py']


def phase_fit(samples, indices):
    """All constant phases of the declared254SYS stream; never align a buffer."""
    period=16384
    wave=bytes(0 if t//1024<2 else t//1024-1 for t in range(period))
    observed=list(zip(indices,samples))
    phases=[]
    for p in range(0,period,2):
        if all(wave[(p+n*254)%period]==v for n,v in observed):phases.extend((p,p+1))
    return phases


def check(root, source, elf7, elf9):
    root, source = Path(root), Path(source)
    e, e9 = Elf(elf7), Elf(elf9)
    base, end = e.sym('__wram_start'), e.sym('__sl_code_end')
    code = e.read(base, end-base)
    require(0x03800000 <= base < end <= 0x0380f000 and len(code) <= 32768, 'private code bounds')
    build = hashlib.sha256(b''.join((source/n).read_bytes() for n in SOURCE)).hexdigest()
    meta = words((root/'metadata.bin').read_bytes())
    require(len(meta) == 8 and meta[:3] == (0x534c5631,1,0), 'metadata identity')
    require(meta[4:] == (65920,base,len(code),fnv(code)), 'actual code/result ABI')
    require(meta[3] >> 24 == 2 and not(meta[3]&31), 'MAIN result pointer')
    helper = e9.read(0,32)+e9.read(0x01ff8020,e9.sym('__itcm_end')-0x01ff8020)
    require((root/'helper.bin').read_bytes() == helper, 'actual quiet helper bytes')
    tag = (f'soundlabels-v1 source={build} cases=2 samples=8192\n'
           f'meta bytes=32 fnv={fnv(struct.pack("<8I",*meta)):08x} helper entry={e9.sym("tp_quiet"):08x} base={e9.sym("__itcm_start"):08x} bytes={len(helper)} fnv={fnv(helper):08x}\n')
    require((root/'manifest.txt').read_text() == tag, 'source/code/helper binding')
    require((root/'progress.txt').read_bytes() == b'start 0\ndone 0\nstart 1\ndone 1\n', 'complete durable journal')
    results=[]
    wave = struct.pack('<32h', *[scale*(0 if i<2 else i-1) for scale in (64,1024) for i in range(16)])
    for c in (0,1):
        commit=f'soundlabels-v1 source={build} condition={c}\n'
        for ext in ['bin','events.csv','code.bin','context.txt','cap0.bin','cap1.bin']:
            name=f'case{c}.{ext}';b=(root/name).read_bytes();commit+=f'{name} {len(b)} {fnv(b):08x}\n'
        require((root/f'case{c}.commit').read_text() == commit, 'raw/journal commit')
        blob=(root/f'case{c}.bin').read_bytes();a=words(blob[:280])
        require(len(blob)==65920 and a[:4]==(0x534c5631,1,0,c), 'raw result/error identity')
        require(a[4]&0x80 and 0x03800000<=a[5]<0x03810000, 'actual private stack/IRQ mask')
        require(a[6:10]==(base,len(code),fnv(code),fnv(code)), 'live code hashes')
        require(blob[280:280+len(code)]==code and (root/f'case{c}.code.bin').read_bytes()==code, 'live compiled code bytes')
        require(not any(blob[280+len(code):33048]), 'unused code packet padding')
        require(blob[33048:33112]==wave and blob[33112:33144]==bytes(32), 'actual labeled waves/silence')
        require(a[13]==a[14]==fnv(wave)^fnv(bytes(32)), 'wave before/after identity')
        require(all(0x03800000<=p<0x0380f000 and not(p&31) for p in a[10:13]), 'private wave locations')
        require(a[15:18]==(127,512,8192) and a[20]==a[21], 'programmed clocks/count/power restore')
        events=[a[22+4*i:26+4*i] for i in range(8)]
        names=['clock1','clock3','capture','voice0','voice2','switch0','switch1','completion']
        rows=list(csv.DictReader((root/f'case{c}.events.csv').open()))
        require(len(rows)==8 and [r['event'] for r in rows]==names, 'all ordered brackets')
        for row,event in zip(rows,events):
            require((int(row['before']),int(row['after']),int(row['written'],16),int(row['readback'],16))==event, 'CSV/raw event equality')
            require(event[0]<=event[1], 'monotonic individual bracket')
        require([v[2] for v in events[:7]]==[0xa8400000,0xa8400000,0x8486,0xa8400008,0xa8400008,0x84 if c else 0x86,0x86], 'actual requested controls')
        require(all(v[2]==v[3] for v in events[:7]), 'actual control readbacks')
        require(events[-1][3]&0x8080==0 and a[19]-a[18]<3351398, 'bounded actual capture completion')
        require(a[18]==events[2][1] and a[19]==events[-1][1], 'same F/1 epoch')
        require(events[5][0]-a[18]>=600000 and events[6][0]-a[18]>=1200000, 'both source crossover events executed')
        arrays=[]
        for u in (0,1):
            raw=blob[33144+u*16384:33144+(u+1)*16384]
            require((root/f'case{c}.cap{u}.bin').read_bytes()==raw, 'all raw capture bytes')
            samples=struct.unpack('<8192h',raw)
            require(0x5a5a not in samples and any(samples), 'complete nonempty capture')
            arrays.append(samples)
        direct=lambda v: 0<=v<=56 and v%4==0
        mixed=lambda v: 0<=v<=476 and v%2==0 and (v//2)%16<15 and (v//2)//16<15
        require(all(mixed(v) for v in arrays[1]), 'always-mixer unique label alphabet')
        for first,last in [(256,1280),(5100,6124)]:
            require(all(direct(v) for v in arrays[0][first:last]), 'direct stable windows retained')
        middle=arrays[0][2700:3724]
        require(all((mixed if c else direct)(v) for v in middle), 'middle source label alphabet')
        require(any(v>56 for v in middle) if c else True, 'actual source mux crossover occurred')
        gap=[events[4][0]-events[3][1],events[4][1]-events[3][0]]
        direct_indices=[*range(256,1280),*range(5100,6124)]
        direct_values=[arrays[0][n]//4 for n in direct_indices]
        if not c:
            direct_indices.extend(range(2700,3724));direct_values.extend(v//4 for v in middle)
        phases=phase_fit(direct_values,direct_indices)
        mixed_phases=phase_fit([(v//2)%16 for v in middle],range(2700,3724)) if c else []
        # Empty sets are retained as an out-of-family observation. Software
        # capture batching must not become a DS timing law or be phase-shifted.
        delays=sorted({(a-b)%16384 for a in phases for b in mixed_phases}) if c else []
        first0=next(i for i,v in enumerate(arrays[1]) if (v//2)%16)
        first2=next(i for i,v in enumerate(arrays[1]) if (v//2)//16)
        observed_separation=first2-first0
        in_envelope=255<=gap[0]<=gap[1]<=507
        onset='unqualified actual bracket envelope'
        if in_envelope:
            onset=('start-relative equal-pipeline family' if observed_separation in (1,2)
                   else 'common-grid equal-pipeline family' if observed_separation in (0,4,5)
                   else 'neither declared family')
        results.append(dict(condition=c,samples_per_unit=8192,events={n:list(v) for n,v in zip(names,events)},
                            observed_gap_interval_SYS=gap,onset_family_envelope=in_envelope,
                            enable_widths_SYS=[events[i][1]-events[i][0] for i in (3,4)],
                            capture_arm_width_SYS=events[2][1]-events[2][0],
                            elapsed_SYS=a[19]-a[18],functional='PASS',
                            declared_family_direct_phase_candidates=phases,
                            declared_family_middle_phase_candidates=mixed_phases,
                            relative_visibility_SYS_mod16384=delays,
                            first_labeled_onsets=[first0,first2],onset_separation=observed_separation,
                            declared_onset_family=onset,
                            DS_timing_verdict=False))
    return dict(status='NEW PRODUCER PROTOCOL/BYTES/COMPLETION PASS; NOT DS TIMING',source_build_id=build,
                cases=results,code_bytes=len(code),hardware_verdict=False,
                relative_visibility_model='finite design family only; actual DS fit/continuity still required')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['root','source','elf7','elf9','out']:p.add_argument('--'+name,type=Path,required=True)
    a=p.parse_args();result=check(a.root,a.source,a.elf7,a.elf9)
    a.out.write_text(json.dumps(result,indent=2)+'\n');print(result['status'])
