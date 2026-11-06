#!/usr/bin/env python3
"""Wrap retained DS30 producer binaries, preserving both original runtimes."""
from pathlib import Path
import argparse,csv,hashlib,io,json,shutil,struct,subprocess,sys
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/hwref'))
from check_arm7thumb import Elf
from ds30.check import check_rom
HASHES={'arm7time.elf':'9512b15e5a4636a4372c1e350cd3cf7209397f76f28b36cc8de8c6f57518621b',
 'arm7time7.elf':'b5bdd58338a3019e4d3f9b4c7c5131a4832dcb857cec656a48fb7eaf82bbc32b',
 'arm7time.nds':'a8657e02631eed609197666b5c279349ee6973ebe4b262f69a3182bab2542f6e'}
ARCHIVE='4e10c3a6ba63fa47c0547b2c93b587dea49c925ffdb3ec531275ed02b76fdffb'
sha=lambda b:hashlib.sha256(b).hexdigest()
def prepare(captured,out):
 assert not out.exists(),'fresh output required';out.mkdir(parents=True)
 (out/'captured').mkdir()
 for n,h in HASHES.items():
  p=captured/n;assert sha(p.read_bytes())==h,('retained producer identity',n);shutil.copy2(p,out/'captured'/n)
 e9,e7=Elf(captured/'arm7time.elf'),Elf(captured/'arm7time7.elf');elfs={9:e9,7:e7}
 original=(captured/'arm7time.nds').read_bytes();rom=bytearray(original)
 a9off,a9entry,a9base,a9size,a7off,a7entry,a7base,a7size=struct.unpack_from('<8I',rom,0x20)
 assert (a9off,a9entry,a9base,a9size,a7off,a7entry,a7base,a7size)==(0x4000,0x02004800,0x02004000,0x2c1d4,0x30200,0x02380000,0x02380000,0x4518)
 def file_offset(cpu,address,size):
  for p in elfs[cpu].segments:
   if p[0]==1 and p[2]<=address and address+size<=p[2]+p[4]:
    physical=p[3]+address-p[2];base,offset,limit=(a9base,a9off,a9size)if cpu==9 else(a7base,a7off,a7size)
    assert base<=physical and physical+size<=base+limit
    off=offset+physical-base
    assert original[off:off+size]==elfs[cpu].read(address,size),'ELF/ROM load binding'
    return off
  raise AssertionError(('not NTR ROM-backed',cpu,hex(address),size))
 bodies=[]
 names9=['a7','mailboxTryRecv','pxiSendPacket','_pxiRecvIrqHandler','crt0Startup','crt0SetupMPU','armDCacheFlushAll']
 names7=['main','timed','k_alu','k_alu_sr','k_b','k_mul','k_mla','k_ldr','k_str','k_ldm4','k_stm4','k_swp','km_alu','km_alu_sr','km_b','km_mul','km_ldr','km_str']
 for cpu,names in [(9,names9),(7,names7)]:
  for n in names:
   address,size,*_=elfs[cpu].symbols[n];address&=~1;assert size>0
   off=file_offset(cpu,address,size);blob=original[off:off+size]
   bodies.append(dict(cpu=cpu,name=n,address=address,bytes=size,ROM_offset=off,sha256=sha(blob)))
 # Compile only a small ARM9 endpoint, never a replacement timing kernel.
 commands=[]
 def run(args):
  args=list(map(str,args));commands.append(args);subprocess.run(args,check=True)
 src=ROOT/'tools/scorecard/ds30/capture.S'
 run(['nice','-n','10','clang','--target=armv5te-none-eabi','-mcpu=arm946e-s','-marm','-nostdlib','-c',src,'-o',out/'capture.o'])
 run(['nice','-n','10','ld.lld','-Ttext=0x02001dc0','--entry=capture_start',out/'capture.o','-o',out/'capture.elf'])
 run(['llvm-objcopy','-O','binary',out/'capture.elf',out/'capture.bin'])
 cap=(out/'capture.bin').read_bytes();ce=Elf(out/'capture.elf');assert ce.sym('capture_start')==0x02001dc0
 assert len(cap)<=e9.symbols['_dvmDiscCacheReadWrite'][1]==0x408
 assert e9.sym('_dvmDiscCacheReadWrite')==0x02001dc0 and e9.sym('armDCacheFlushAll')==0x01ff85c0
 patches=[]
 def patch(address,before,after,reason):
  assert len(before)==len(after);off=file_offset(9,address,len(before));assert rom[off:off+len(before)]==before
  rom[off:off+len(after)]=after;patches.append(dict(address=address,ROM_offset=off,bytes=len(after),before_sha256=sha(before),after_sha256=sha(after),reason=reason))
 # Original Calico boot/MPU/IRQ/PXI/stack and ARM9 mailbox helper execute.
 patch(0x02001886,e9.read(0x02001886,4),struct.pack('<2H',0x2000,0x46c0),'before timing: replace only fatInitDefault call with return-false input; no SD emulation')
 assert e9.sym('buf_write')&~1==0x02001a7c
 patch(0x02001a7c,e9.read(0x02001a7c,8),struct.pack('<2HI',0x4b00,0x4718,0x02001dc0),'after all31 timing rows: buf_write endpoint to reserved capture code; no contention phase')
 patch(0x02001dc0,e9.read(0x02001dc0,len(cap)),cap,'unused FAT cache routine holds endpoint; FAT call disabled before entry')
 for b in bodies:
  assert sha(rom[b['ROM_offset']:b['ROM_offset']+b['bytes']])==b['sha256'],('timed/helper body changed',b)
 assert rom[a7off:a7off+a7size]==original[a7off:a7off+a7size],'entire original ARM7 image preserved'
 archive=ROOT/'tools/hwref/results/ds-20261025-run30-onetrip.tar.zst';assert sha(archive.read_bytes())==ARCHIVE
 raw={n:subprocess.check_output(['tar','--zstd','-xOf',str(archive),n])for n in ['arm7time.csv','arm7time_contention.csv','arm7time_info.txt']}
 assert b'built Oct 25 2026 23:09:39\n'in raw['arm7time_info.txt']
 assert b'Oct 25 2026\0'in e9.data and b'23:09:39\0'in e9.data
 for n,data in raw.items():(out/'captured'/n).write_bytes(data)
 rows=list(csv.DictReader(io.StringIO(raw['arm7time.csv'].decode())));assert len(rows)==31
 (out/'arm7-ds30.nds').write_bytes(rom)
 fault=next(b for b in bodies if b['cpu']==7 and b['name']=='k_str')
 changed=[i for i,(a,b)in enumerate(zip(original,rom))if a!=b];assert all(any(p['ROM_offset']<=i<p['ROM_offset']+p['bytes']for p in patches)for i in changed)
 m=dict(status='BUILT/HOST BYTE-CHECKED ONLY; no native/DS execution',retained_origin=str(captured),retained_producer_SHA256=HASHES,
  DS_archive_SHA256=ARCHIVE,DS_capture_SHA256={n:sha(d)for n,d in raw.items()},DS_rows=rows,
  producer_binding='retained Oct25 23:09:39 build stamp equals actual DSrun30 info; original measured ROM digest/live CPU context were not captured',
  preserved_bodies=bodies,ARM7_image_bytes=a7size,ARM7_image_SHA256=sha(original[a7off:a7off+a7size]),patches=patches,actual_changed_bytes=len(changed),
  ROM_SHA256=sha(rom),capture_bytes=len(cap),capture_elf_SHA256=sha((out/'capture.elf').read_bytes()),capture_done_PC=ce.sym('adapter_done'),
  native_plusargs=['+dump_pc=%08x'%ce.sym('adapter_done'),'+dump_file=arm7-ds30-main.bin'],native_dump=dict(bytes=4*1024*1024,result_base=0x023d0000,header_bytes=256,CSV_limit_bytes=4096),
  commands=commands,source_SHA256={str(p.relative_to(ROOT)):sha(p.read_bytes())for p in [Path(__file__),src,ROOT/'tools/scorecard/ds30/check.py']},
  limits=['Native has not run; Calico boot/PXI/IRQ support and actual completion require the coordinator batch.',
   'Retained producer stamp/source/bytes are pinned; DSrun30 did not capture a loaded-ROM hash, raw short/long minima, CP15 snapshot or live helper/cache state.',
   'Original ARM9 helper/startup/stack/layout/cache policy instructions, full ARM7 image and all original31 rows are retained; native completion CP15/IO are observations, not measured DS live-state equality.',
   'FAT initialization/card services are omitted before measurements; original successful FAT heap/cache prehistory and SDK interrupt interleaving are not reproduced exactly.',
   'Capture code runs only at original first buf_write after timing, then stops before the distinct contention experiment.',
   'No guessed wait, CPU RTL change, new baseline or timing acceptance; preserve all previous canonical observations.'])
 m['host_ROM_check']=check_rom(rom,original,m)
 bad=bytearray(rom);bad[fault['ROM_offset']+16]^=4
 try:check_rom(bad,original,m)
 except AssertionError as error:
  assert str(error)=='original kernel/helper byte identity: k_str'
  m['host_kernel_fault']=dict(name='actual retained k_str body byte changed',cpu=7,ROM_offset=fault['ROM_offset']+16,caught=str(error))
 else:raise AssertionError('actual kernel-byte fault escaped')
 (out/'manifest.json').write_text(json.dumps(m,indent=2)+'\n');return m
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--captured',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();m=prepare(a.captured.resolve(),a.out.resolve());print(json.dumps({k:m[k]for k in ['status','ROM_SHA256','capture_bytes','capture_done_PC','actual_changed_bytes']},indent=2))
