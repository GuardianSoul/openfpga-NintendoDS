#!/usr/bin/env python3
"""Freeze SDK addresses and bytes; run on the SDK host before Census."""
from pathlib import Path
import argparse,hashlib,json,re,struct
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def elf(path):
 b=path.read_bytes();assert b[:7]==b'\x7fELF\x01\x01\x01';off=struct.unpack_from('<I',b,32)[0];ent,num,names=struct.unpack_from('<HHH',b,46)
 sections=[struct.unpack_from('<10I',b,off+i*ent)for i in range(num)];symbols={}
 for s in sections:
  if s[1]!=2:continue
  st=sections[s[6]];strings=b[st[4]:st[4]+st[5]]
  for pos in range(s[4],s[4]+s[5],s[9]):
   name,value,size,info,other,ndx=struct.unpack_from('<IIIBBH',b,pos)
   text=strings[name:strings.index(b'\0',name)].decode();symbols[text]=value
 def span(start,end):
  candidates=[s for s in sections if s[1]!=8 and s[2]&2 and s[3]<=start<end<=s[3]+s[5]];assert len(candidates)==1,(hex(start),hex(end));s=candidates[0];return b[s[4]+start-s[3]:s[4]+end-s[3]]
 return symbols,span

def seal(sdk):
 s7,read7=elf(sdk/'pwram647.elf');s9,read9=elf(sdk/'pwram64.elf')
 addresses=[s7['pw_stack'],s7['pw_stack']+4096]+[s7[x]for x in ['pw_chain','pw_chain_end','pw_store','pw_store_end','pw_read','pw_read_end','pw_switch','pw_switch_end']]
 assert 0x037f8000<=s7['__wram_start']<s7['__wram_bss_end']<=0x03800000
 assert s7['__sp_usr']==0x0380fe80 and s7['__sp_irq']==0x0380ff80 and s7['__sp_svc']==0x0380ffc0
 assert s7['backup']+65536<=s7['out'] and s7['out']+68928<=s7['__heap_start']<=s7['__heap_end']
 code=read7(s7['pw_chain'],s7['pw_switch_end']);assert len(code)<=1024
 stores=read7(s7['pw_store'],s7['pw_store_end']);burst=struct.pack('<16I',*[0xe5824000+i*32 for i in range(16)]);assert stores.count(burst)==1
 assert read7(s7['pw_chain'],s7['pw_chain_end'])==struct.pack('<8I',0xe3a03000,0xe5900000,0xe02030e3,0xe2511001,0x1afffffb,0xe5820000,0xe1a00003,0xe12fff1e)
 itcm=read9(s9['__itcm_start']+32,s9['__itcm_end']);assert s9['__itcm_start']<=s9['pw_quiet']<s9['__itcm_end']
 build=re.fullmatch('#define PW_BUILD_ID "([0-9a-f]{64})"\n',(sdk/'build-id.h').read_text()).group(1)
 return dict(version=1,build_id=build,header_addresses=addresses,image=s7['out']+3392,out=s7['out'],helper=s9['pw_quiet'],kernel_hex=code.hex(),itcm_sha256=hashlib.sha256(itcm).hexdigest(),rom_sha256=sha(sdk/'pwram64.nds'),arm7_elf_sha256=sha(sdk/'pwram647.elf'),arm9_elf_sha256=sha(sdk/'pwram64.elf'),actual_mutant_kernel_offset=code.index(burst),linked_checks=dict(shared_bss_end=s7['__wram_bss_end'],private_startup_stack=s7['__sp_usr'],main_heap_bytes=s7['__heap_end']-s7['__heap_start'],back_to_back_distinct_stores=16),timing_helpers={n:dict(address=s7[n]&~1,bytes=read7(s7[n]&~1,(s7[n]&~1)+(100 if n=='timed'else 220)).hex())for n in ['timed','timed_dma']})
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('sdk',type=Path);p.add_argument('output',type=Path);a=p.parse_args();a.output.write_text(json.dumps(seal(a.sdk),indent=2)+'\n')
