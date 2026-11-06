#!/usr/bin/env python3
"""Build native ROM from frozen run39 bytes, without rebuilding its kernels."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tarfile

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
sha=lambda data:hashlib.sha256(data).hexdigest()

def captured():
    with tarfile.open(HERE/'captured.tar.gz') as archive:
        files={m.name:archive.extractfile(m).read() for m in archive if m.isfile()}
    manifest=json.loads(files['manifest.json'])
    assert all(sha(files[name])==digest for name,digest in manifest['files'].items())
    return files,json.loads(files['layout.json'])

def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=ROOT/'build/a7fetch39');a=p.parse_args()
    out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
    files,layout=captured();asm=['.section .rodata,"a"','.balign 4'];rows=[]
    for c in layout['cases']:
        raw=files[f'arm7fetch_v1_k{c["id"]:02d}_r0.bin'];words=struct.unpack_from('<5I',raw,328)
        code=raw[348:348+c['size']]
        assert sha(code)==c['code_sha256'] and len(raw)==4448
        for region in (0,1):
            paired=files[f'arm7fetch_v1_k{c["id"]:02d}_r{region}.bin']
            assert paired[348:348+c['size']]==code
            assert struct.unpack_from('<5I',paired)==(0x41463731,1,c['id'],region,0)
        blob=out/f'k{c["id"]:02d}.bin';blob.write_bytes(code)
        symbol=f'captured_k{c["id"]:02d}'
        asm.extend([f'.global {symbol}',f'{symbol}:',f'.incbin "{blob}"','.balign 4'])
        values=[c['source_entry'],c['source_body'],c['source_end'],c['main_entry'],c['code_fnv'],*words]
        rows.append(' {'+','.join(hex(x)+'u' for x in values)+','+json.dumps(c['case'])+','+symbol+'},')
    (out/'kernels.s').write_text('\n'.join(asm)+'\n')
    (out/'cases.h').write_text('\n'.join(f'extern const u32 captured_k{i:02d}[];' for i in range(18))+'\nstatic const AfCase af_cases[AF_CASES]={\n'+'\n'.join(rows)+'\n};\n')
    helper=files['arm7fetch_v1_helper_itcm.bin'];h=layout['helper']
    assert len(helper)==h['itcm_bytes'] and sha(helper[32:32+h['bytes']])==h['sha256']
    assert sha(helper[32:])==h['initialized_sha256']
    (out/'helper.bin').write_bytes(helper)
    (out/'helper.s').write_text('.section .rodata,"a"\n.balign 4\n.global captured_helper,captured_helper_end\ncaptured_helper:\n.incbin "'+str(out/'helper.bin')+'"\ncaptured_helper_end:\n')
    commands=[]
    def run(cmd):
        commands.append([str(x) for x in cmd]);subprocess.run(cmd,check=True,cwd=ROOT)
    for cpu,target in [(7,'armv4t-none-eabi'),(9,'armv5te-none-eabi')]:
        cc=['clang',f'--target={target}',f'-mcpu={"arm7tdmi" if cpu==7 else "arm946e-s"}']
        crt=out/f'crt{cpu}.o';obj=out/f'arm{cpu}.o';blob=out/f'blob{cpu}.o'
        run(cc+(['-Wa,-defsym,ARM9=1'] if cpu==9 else [])+['-c',HERE.parent/'common/crt0.s','-o',crt])
        run(cc+['-O2','-marm','-ffreestanding','-fno-builtin','-nostdlib','-fno-pic','-mfloat-abi=soft','-fno-unwind-tables','-fno-asynchronous-unwind-tables','-Wall','-Wextra','-I',out,'-c',HERE/f'arm{cpu}.c','-o',obj])
        run(cc+['-c',out/('kernels.s' if cpu==7 else 'helper.s'),'-o',blob])
        run(['ld.lld','-T',HERE.parent/'common/ds.ld',f'--defsym=__base={"0x037f8000" if cpu==7 else "0x02000000"}',crt,obj,blob,'-o',out/f'arm{cpu}.elf'])
        run(['llvm-objcopy','-O','binary',out/f'arm{cpu}.elf',out/f'arm{cpu}.bin'])
        assert (out/f'arm{cpu}.bin').stat().st_size<0x8000,'bootstrap exceeds shared WRAM or unexpectedly sparse image'
    run(['python3',ROOT/'tools/ds-tests/mknds.py',out/'a7fetch39.nds','--title','A7FETCH39','--code','AF39','--arm9',out/'arm9.bin','--arm7',out/'arm7.bin'])
    symbols=subprocess.check_output(['llvm-nm',out/'arm9.elf'],text=True)
    done=int(next(line.split()[0] for line in symbols.splitlines() if line.endswith(' af_native_done')),16)
    manifest={'base':'bfd0a07ad2d2bca295c1bf0fcba427d00f2490b3','dump_pc':f'{done:x}','commands':commands,
              'inputs':{str(p.relative_to(ROOT)):sha(p.read_bytes()) for p in [HERE/'captured.tar.gz',HERE/'arm7.c',HERE/'arm9.c',HERE/'protocol.h',Path(__file__)]},
              'rom_sha256':sha((out/'a7fetch39.nds').read_bytes()),'kernels':'all18 exact DS bytes, WRAM and MAIN addresses','helper':'all2024 runtime bytes at01ff8000; entry01ff8020',
              'differences':['Minimal crt0/raw FIFO replace Calico/SD outside timing','ARM7 timing wrapper recompiled; startup/stack and context differ','Both native CPUs remain IRQ masked outside timing too']}
    (out/'build.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('PASS18 exact DS kernels/addresses and runtime ITCM helper; dump_pc='+manifest['dump_pc'])

if __name__=='__main__':main()
