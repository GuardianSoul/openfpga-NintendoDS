#!/usr/bin/env python3
"""Project the shipped packed-GX protocol into a private RAM-output ROM.

No DS ROM is modified. The sampler is linked from its shipped object and
its complete function bytes must equal the qualified shipping ELF.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def elf_symbol(path, name):
    data = path.read_bytes()
    if data[:7] != b'\x7fELF\x01\x01\x01':
        raise ValueError('require ELF32 little endian')
    offset = struct.unpack_from('<I', data, 32)[0]
    size, count = struct.unpack_from('<HH', data, 46)
    sections = [struct.unpack_from('<10I', data, offset + i * size) for i in range(count)]
    for section in sections:
        if section[1] != 2:
            continue
        strings = sections[section[6]]
        names = data[strings[4]:strings[4] + strings[5]]
        for pos in range(section[4], section[4] + section[5], section[9]):
            n, address, length, _, _, index = struct.unpack_from('<IIIBBH', data, pos)
            if names[n:].split(b'\0', 1)[0].decode() == name:
                s = sections[index]
                start = s[4] + (address & ~1) - s[3]
                body = None if s[1] == 8 else data[start:start + length]
                return dict(address=address, size=length, body=body)
    raise ValueError(f'{path}: missing symbol {name}')


def function(source, name):
    m = re.search(r'^static void ' + re.escape(name) + r'\([^\n]*\)\s*\{', source, re.M)
    if not m:
        raise ValueError(f'missing frozen function {name}')
    # These five frozen definitions contain no braces in string literals.
    depth = 1
    end = m.end()
    while depth:
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
        end += 1
    return source[m.start():end] + '\n'


PREFIX = r'''
#include "read.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static bool output_ok=true;
static u32 step_number, failures, rows_done, current_kind, current_length;
u32 packed_rows[18][16] __attribute__((aligned(64)));
#define RESULT ((volatile u32*)0x023f0000)
#define PACKET ((volatile u32*)0x023f0100)
void gx_note_timeout(void){ failures++; }
static void csv_header(const char* name,const char* header){ (void)name;(void)header; }
static bool start_step(const char* family,int kind,int length,int n,int rep){
    (void)family;(void)n;(void)rep;
    if(step_number>=18){failures++;return false;}
    step_number++;current_kind=kind;current_length=length;return true;
}
static void done_step(void){}
static void append(Buf* b,const char* name);
'''

SUFFIX = r'''
static void append(Buf* b,const char* name)
{
    (void)name;
    if(b->len){
        char body[20];unsigned long n,rep,entries,words,dma,idle,ds,is,clip,timeout;
        int fields=sscanf(b->p,"%19[^,],%lu,%lu,%lu,%lu,%lu,%lu,%lx,%lx,%lx,%lu",
            body,&n,&rep,&entries,&words,&dma,&idle,&ds,&is,&clip,&timeout);
        if(fields!=11 || rows_done>=18){failures++;output_ok=false;}
        else {
            u32 hash=2166136261u;
            for(u32 j=0;j<dma_words;j++)for(int byte=0;byte<4;byte++)
                hash=(hash^((dma_stream[j]>>(8*byte))&255))*16777619u;
            u32 packet[16]={0x47585031u,rows_done+1,current_kind,n,rep,entries,words,
                dma,idle,ds,is,clip,timeout,current_length,hash,0};
            memcpy(packed_rows[rows_done],packet,sizeof packet);
            packed_rows[rows_done][15]=rows_done+1;
            for(int j=0;j<16;j++)PACKET[j]=packet[j];
            armDCacheFlush((void*)PACKET,64);
            PACKET[15]=rows_done+1;armDCacheFlush((void*)(PACKET+8),32);
            rows_done++;
            if(timeout || idle<dma || clip!=0x1000)failures++;
        }
    }
    free(b->p);b->p=NULL;b->len=b->cap=0;
}
int main(void)
{
    hw_init("GX packed endpoints - Pocket only");
    videoSetMode(MODE_0_3D);R_DISP3DCNT=0;R_GXSTAT=1u<<15;
    RESULT[0]=0x52545344u;RESULT[1]=2;RESULT[2]=0;RESULT[3]=0;
    packedcosts();
    failures+=g_timeouts+g_reset_fail+g_dropped;
    armDCacheFlush(packed_rows,sizeof packed_rows);
    RESULT[4]=rows_done;RESULT[5]=failures;
    RESULT[2]=(rows_done==18 ? 1u : 0u)|(failures==0 ? 2u : 0u);
    RESULT[3]=1;armDCacheFlush((void*)RESULT,32);
    hw_done();
}
'''


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--shipping-build', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    shipped, out = a.shipping_build.resolve(), a.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    contract = json.loads((ROOT / 'docs/results/hwref-speed-trip-20261031.json').read_text())
    paths = ['sw/hwref/gxlatency/main.c', 'sw/hwref/gxlatency/read.h',
             'sw/hwref/gxtime/gxtime.h', 'sw/hwref/common/hwref.c', 'sw/hwref/common/hwref.h']
    for path in paths:
        if sha(ROOT / path) != contract['sources'][path]:
            raise SystemExit(f'frozen DS source changed: {path}')
    source = (ROOT / paths[0]).read_text()
    macros = '\n'.join(re.findall(r'^#define (?:XY|P10)[^\n]*', source, re.M)) + '\n'
    identity = re.search(r'^static const u32 identity\[16\].*;', source, re.M)[0] + '\n'
    stream = re.search(r'^static u32 dma_stream.*;\nstatic u32 dma_words.*;', source, re.M)[0] + '\n'
    bodies = {name: function(source, name) for name in
              ('put', 'pack_command', 'feed_setup', 'packedcosts')}
    generated = PREFIX + macros + identity + stream + ''.join(bodies.values()) + SUFFIX
    (out / 'main.c').write_text(generated)
    sampler = shipped / 'chain/gxlatency/read.itcm.o'
    helper = shipped / 'chain/gxtime/run.itcm.o'
    ds_rom = shipped / 'hwref.nds'
    expected_rom = next(x['sha256'] for x in contract['payload'] if x['name'] == 'hwref.nds')
    if sha(ds_rom) != expected_rom:
        raise SystemExit('shipping ROM differs from qualified physical-trip bytes')
    original = elf_symbol(shipped / 'hwref.elf', 'gxlat_dma')
    if ds_rom.read_bytes().count(original['body']) != 1:
        raise SystemExit('sampler is not uniquely embedded in the qualified shipping ROM')
    if elf_symbol(sampler, 'gxlat_dma')['body'] != original['body']:
        raise SystemExit('sampler object differs from shipped machine code')
    shutil.copy2(sampler, out / 'sampler.o')
    shutil.copy2(helper, out / 'gx-helper.o')
    dev = Path.home() / 'devkitpro'
    cc = dev / 'devkitARM/bin/arm-none-eabi-gcc'
    flags = ['-O2', '-g', '-Wall', '-march=armv5te', '-mtune=arm946e-s', '-mthumb',
             '-D__NDS__', '-DARM9', '-DHWREF_HEADLESS', '-ffunction-sections', '-fdata-sections',
             '-I' + str(dev / 'calico/include'), '-I' + str(dev / 'libnds/include'),
             '-I' + str(ROOT / 'sw/hwref/gxlatency')]
    commands = [[str(cc), *flags, '-c', str(out / 'main.c'), '-o', str(out / 'main.o')],
                [str(cc), *flags, '-c', str(ROOT / 'sw/hwref/common/hwref.c'), '-o', str(out / 'common.o')],
                [str(cc), '-specs=' + str(dev / 'calico/share/ds9.specs'), '-march=armv5te',
                 '-mtune=arm946e-s', '-L' + str(dev / 'calico/lib'), '-L' + str(dev / 'libnds/lib'),
                 str(out / 'main.o'), str(out / 'common.o'), str(out / 'sampler.o'), str(out / 'gx-helper.o'),
                 '-lfat', '-lnds9', '-lcalico_ds9', '-lm', '-Wl,-Map,' + str(out / 'packed.elf.map'),
                 '-o', str(out / 'packed.elf')],
                [str(dev / 'tools/bin/ndstool'), '-c', str(out / 'packed.nds'), '-9', str(out / 'packed.elf'),
                 '-7', str(dev / 'calico/bin/ds7_maine.elf')]]
    with (out / 'build.log').open('w') as log:
        for command in commands:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    now = elf_symbol(out / 'packed.elf', 'gxlat_dma')
    if now['body'] != original['body']:
        raise SystemExit('linked sampler machine code changed')
    if (out / 'packed.nds').read_bytes().count(now['body']) != 1:
        raise SystemExit('sampler is not uniquely embedded in the headless ROM')
    m = dict(ds_source_freeze=contract['source_freeze'], ds_probe_source_sha256=sha(ROOT / paths[0]),
             copied_function_sha256={n: hashlib.sha256(b.encode()).hexdigest() for n, b in bodies.items()},
             commands=commands, sampler_bytes=len(now['body']),
             sampler_machine_sha256=hashlib.sha256(now['body']).hexdigest(), sampler_byte_identical=True,
             qualified_ds_rom_sha256=sha(ds_rom), sampler_embedded_once_in_each_rom=True,
             ds_sampler_address=original['address'], pocket_sampler_address=now['address'],
             ds_stream_address=elf_symbol(shipped / 'hwref.elf', 'dma_stream')['address'],
             pocket_stream_address=elf_symbol(out / 'packed.elf', 'dma_stream')['address'],
             rows_address=elf_symbol(out / 'packed.elf', 'packed_rows')['address'],
             row_words=16, expected_rows=18, packet_address=0x023f0100,
             rom_sha256=sha(out / 'packed.nds'), elf_sha256=sha(out / 'packed.elf'),
             scope='same timed machine code and packed/setup source; FAT/journals replaced by RAM, layout/context differ; no DS timing acceptance')
    (out / 'manifest.json').write_text(json.dumps(m, indent=2, sort_keys=True) + '\n')
    print(json.dumps(m, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
