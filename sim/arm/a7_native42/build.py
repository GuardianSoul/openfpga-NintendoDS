#!/usr/bin/env python3
"""Build a native adapter from immutable DS42 live kernel/helper bytes."""
from pathlib import Path
import hashlib,json,os,struct,subprocess,tarfile
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/a7-native42/thumb';assert not OUT.exists();OUT.mkdir()
os.setpriority(os.PRIO_PROCESS,0,10)
sha=lambda b:hashlib.sha256(b).hexdigest()
archive=ROOT/'docs/results/hwref-run42-20261101/evidence.tar.gz'
assert sha(archive.read_bytes())=='96fa0b6180475a656f9a6dedea0b04d6e8cfe37884af5b87c5f01c9e840e2a9a'
with tarfile.open(archive)as t:files={m.name:t.extractfile(m).read()for m in t if m.isfile()}
(OUT/'inputs').mkdir();meta=struct.unpack('<56I',files['raw/metadata.bin']);assert meta[:4]==(0x3754484d,1,9,0)
assert meta[5:8]==(0x038039c0,0x038039a0,0x038049c0)
asm=['.section .rodata,"a"','.balign 4'];decl=[];cases=[]
for i in range(9):
 entry,body,end,fnv=meta[8+i*4:12+i*4];code=files[f'raw/case{i}.code.bin'];raw=files[f'raw/case{i}.bin'];assert len(code)==end-(entry&~1)
 assert raw[704:704+len(code)]==code
 for n,b in[(f'k{i}.bin',code),(f'DS-case{i}.bin',raw),(f'DS-case{i}.csv',files[f'raw/case{i}.csv'])]:(OUT/'inputs'/n).write_bytes(b)
 p=OUT/'inputs'/f'k{i}.bin';asm.extend([f'.global native_k{i}',f'native_k{i}:',f'.incbin "{p}"','.balign 4']);decl.append(f'extern const u8 native_k{i}[];');cases.append(' {'+','.join(hex(x)+'u'for x in[entry,body,end,fnv])+f',native_k{i}'+'},')
helper=files['raw/helper.bin'];assert len(helper)==2128;(OUT/'inputs/helper.bin').write_bytes(helper)
asm.extend(['.global captured_helper,captured_helper_end','captured_helper:',f'.incbin "{OUT/"inputs/helper.bin"}"','captured_helper_end:'])
(OUT/'blobs.S').write_text('\n'.join(asm)+'\n');(OUT/'cases.c').write_text('#include "protocol.h"\n'+'\n'.join(decl)+'\nconst NativeCase native_cases[9]={\n'+'\n'.join(cases)+'\n};\n')
(OUT/'case_protocol.h').write_bytes(files['source/arm7thumb/protocol.h'])
for name in['protocol.h','arm7.c','arm9.c','invoke.S']:(OUT/name).write_bytes((HERE/name).read_bytes())
(OUT/'ds.h').write_bytes((ROOT/'sw/tests/common/ds.h').read_bytes());crt=(ROOT/'sw/tests/common/crt0.s').read_text()
(OUT/'crt7.s').write_text(crt.replace('add     sp, r4, #0x3E00','add     sp, r4, #0x3000'))
(OUT/'crt9.s').write_text(crt.replace('0x0B00000A','0x02FF000A').replace('0x0B000000','0x02FF0000'))
commands=[]
def run(cmd):
 commands.append(list(map(str,cmd)));subprocess.run(list(map(str,cmd)),cwd=ROOT,check=True)
for cpu,target in[(7,'armv4t-none-eabi'),(9,'armv5te-none-eabi')]:
 cc=['clang',f'--target={target}',f'-mcpu={"arm7tdmi"if cpu==7 else"arm946e-s"}'];crtobj=OUT/f'crt{cpu}.o';obj=OUT/f'arm{cpu}.o';blob=OUT/f'blob{cpu}.o';case=OUT/f'cases{cpu}.o'
 run(cc+(['-Wa,-defsym,ARM9=1']if cpu==9 else[])+['-c',OUT/f'crt{cpu}.s','-o',crtobj])
 flags=['-O2','-mthumb'if cpu==7 else'-marm','-ffreestanding','-fno-builtin','-nostdlib','-fno-pic','-mfloat-abi=soft','-fno-unwind-tables','-fno-asynchronous-unwind-tables','-Wall','-Wextra','-I',OUT]
 run(cc+flags+['-c',OUT/f'arm{cpu}.c','-o',obj]);run(cc+['-c',OUT/'blobs.S','-o',blob]);run(cc+flags+['-c',OUT/'cases.c','-o',case])
 objects=[crtobj,obj,blob,case]
 if cpu==7:
  invoke=OUT/'invoke.o';run(cc+['-c',OUT/'invoke.S','-o',invoke]);objects.append(invoke)
 run(['ld.lld','-T',ROOT/'sw/tests/common/ds.ld',f'--defsym=__base={"0x037f8000"if cpu==7 else"0x02000000"}',*objects,'-o',OUT/f'arm{cpu}.elf'])
 run(['llvm-objcopy','-O','binary',OUT/f'arm{cpu}.elf',OUT/f'arm{cpu}.bin']);assert(OUT/f'arm{cpu}.bin').stat().st_size<32768
run(['python3',ROOT/'tools/ds-tests/mknds.py',OUT/'a7thumb42.nds','--title','A7THUMB42','--code','AT42','--arm9',OUT/'arm9.bin','--arm7',OUT/'arm7.bin'])
symbols=subprocess.check_output(['llvm-nm',OUT/'arm9.elf'],text=True);done=int(next(l.split()[0]for l in symbols.splitlines()if l.endswith(' native42_done')),16)
record=dict(source=json.loads((OUT.parent/'job.json').read_text())['source'],DS_capsule_SHA256=sha(archive.read_bytes()),ROM_SHA256=sha((OUT/'a7thumb42.nds').read_bytes()),dump_pc=hex(done),SP=0x0380fd88,scratch=meta[5],commands=commands,inputs={str(p.relative_to(OUT)):sha(p.read_bytes())for p in OUT.rglob('*')if p.is_file()},scope='Actual DS live Thumb kernels, addresses/literals/scratch/SP and full quiet helper. Minimal boot/FIFO and explicit invoke/time wrapper replace SDK/journal; paired raw timings retained; no wrapper offset fit.')
(OUT/'build.json').write_text(json.dumps(record,indent=2)+'\n');print('BUILT DS42 native9',record['ROM_SHA256'],record['dump_pc'])
