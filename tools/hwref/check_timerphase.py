#!/usr/bin/env python3
"""Check actual producer/code/bounds, then retain both timer-phase hypotheses."""
from pathlib import Path
import argparse,csv,hashlib,json,struct
from check_arm7thumb import Elf,fnv,require,words
from timerphase_model import candidates

SOURCE=['protocol.h','arm7.c','timer.S','main.c','quiet.itcm.c','Makefile','../common/hwref.c','../common/hwref.h','../Makefile','../wramarb/linker.py']

def check(root,elf7,elf9,source,defines=''):
 root=Path(root);e=Elf(elf7);e9=Elf(elf9)
 entry=e.sym('tp_timer');end=e.sym('tp_timer_end');pc=e.sym('tp_joint_read');code=e.read(entry,end-entry)
 require(0x03800000<=entry<end<=0x0380f000 and not(entry&31) and len(code)<=1024,'private WRAM code bounds')
 require(e.read(pc,4)==struct.pack('<I',0xe59a3000),'actual joint 32-bit IF load')
 require(e.read(pc-12,12)==struct.pack('<III',0xe58ab000,0xe1d910b8,0xe1d920b8),'clear and before timestamps surround joint read')
 require(e.read(pc+4,8)==struct.pack('<II',0xe1d940b8,0xe1d960bc),'after timestamps before all stores')
 m=words((root/'metadata.bin').read_bytes());require(len(m)==8 and m[:3]==(0x50485437,1,0),'metadata identity')
 require(m[4:]==(17536,entry,end,fnv(code)),'metadata actual code/result ABI')
 require(m[3]>>24==2 and not(m[3]&31),'MAIN result pointer')
 helper=e9.read(0,32)+e9.read(0x01ff8020,e9.sym('__itcm_end')-0x01ff8020)
 require((root/'helper.bin').read_bytes()==helper,'actual ARM9 quiet helper bytes')
 build=hashlib.sha256(b''.join((Path(source)/n).read_bytes()for n in SOURCE)+defines.encode()).hexdigest()
 tag=f'timerphase-v1 source={build} rows=512\nmeta bytes=32 fnv={fnv(struct.pack("<8I",*m)):08x} helper entry={e9.sym("tp_quiet"):08x} base={e9.sym("__itcm_start"):08x} bytes={len(helper)} fnv={fnv(helper):08x}\n'
 require((root/'manifest.txt').read_text()==tag,'source/code/helper manifest')
 require((root/'progress.txt').read_bytes()==b'start 0\ndone 0\n','complete durable journal')
 commit=f'timerphase-v1 source={build} code={fnv(code):08x}\n'
 for name in ['result.bin','result.csv','code.bin','context.txt']:
  blob=(root/name).read_bytes();commit+=f'{name} {len(blob)} {fnv(blob):08x}\n'
 require((root/'result.commit').read_text()==commit,'durable result checksums')
 require((root/'code.bin').read_bytes()==code,'live code file')
 data=(root/'result.bin').read_bytes();a=words(data)
 require(len(data)==17536 and a[:8]==(0x50485437,1,0,512,entry,end,fnv(code),fnv(code)),'actual result/header/code hashes')
 require(a[8:12]==a[16:20] and a[24]&0x80 and not a[31],'readable control restore and IRQ masked')
 require(data[16512:16512+len(code)]==code and not any(data[16512+len(code):]),'raw live code and padding')
 require((a[30]-a[29])&65535>=512,'steady state after enable-edge carry')
 csvrows=list(csv.DictReader((root/'result.csv').open()));require(len(csvrows)==512,'all raw rows retained')
 rows=[];widths=set()
 for i,r in enumerate(csvrows):
  raw=a[32+i*8:40+i*8];require(tuple(map(int,r.values()))==raw,'CSV/raw equality')
  c0,c1,s0,if_word,s1,h0,h1,guard=raw
  require(guard==0x5aa55aa5,'actual probe/output guard fault')
  require(max(c0,c1,s0,s1,h0,h1)<=65535 and (h1-h0)&65535<=1,'F/1 anchor words')
  t=[c0]
  for x in (c1,s0,s1):t.append(t[-1]+((x-t[-1])&65535))
  require(t==sorted(t) and t[-1]-t[0]<64,'clear/read window within one period')
  widths.add((t[1]-t[0],t[3]-t[2]));rows.append(dict(bounds=t,bits=(if_word>>3)&3))
 allowed=candidates(rows)
 status='shared-only' if allowed['0'] and not(allowed['10']or allowed['-10']) else 'offset-only' if not allowed['0'] and (allowed['10']or allowed['-10']) else 'inconclusive'
 return dict(functional='PASS',classification=status,phase_candidates=allowed,rows=512,raw_bounds=rows,
             actual_window_widths=sorted(widths),code_bytes=len(code),ROM_build_id=build,
             scope='joint observable TM0/1 IF edge phase, F64 steady state; no hidden-state normalization or independent IF-delay claim')

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('root');p.add_argument('--elf7',required=True);p.add_argument('--elf9',required=True);p.add_argument('--source',required=True);p.add_argument('--defines',default='');p.add_argument('--out');a=p.parse_args()
 result=check(a.root,a.elf7,a.elf9,a.source,a.defines);text=json.dumps(result,indent=2)+'\n'
 if a.out:Path(a.out).write_text(text)
 else:print(text,end='')
