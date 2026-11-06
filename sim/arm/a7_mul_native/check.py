#!/usr/bin/env python3
"""Check raw native state/code/context and retain every unadjusted timing."""
from pathlib import Path
import argparse, hashlib, importlib.util, json, struct

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('mixed_oracle', ROOT/'sw/hwref/a7mulmix/check.py')
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)
sha = lambda b: hashlib.sha256(b).hexdigest()
require = oracle.require
CP15 = (0x5507d, 0x02ff000a, 0x20, 0x42, 0x42, 2, 0x06330033, 0x66600060,
        0x04000033, 0x0200002b, 0, 0, 0x02ff001f, 0x01ff801d, 0xffff001d, 0x17)

def check(base, ram):
    require(len(ram) == 4*1024*1024, 'exact4MiB MAIN dump required')
    manifest = json.loads((base/'build.json').read_text())
    for name, digest in manifest['inputs'].items():
        require(sha((base/name).read_bytes()) == digest, 'changed pinned guest input: '+name)
    layout = json.loads((base/'inputs/layout.json').read_text())
    status = struct.unpack_from('<32I', ram, 0x230000)
    require(status[:3] == (0x414d5831, 6, 0), 'native six-group completion/error differs')
    require(status[4:10] == (0,)*6, 'quiet helper failed')
    require(status[24:27] == (0xe880, 0x02ff000a, 0x20), 'EXMEM/DTCM/ITCM setup differs')
    require(struct.unpack_from('<5I', ram, 0x3f0000) == (0x52545344, 1, 1, 1, 6), 'native done protocol incomplete')
    helper = (base/'inputs/helper.bin').read_bytes()
    require(ram[0x220000:0x220000+2024] == ram[0x221000:0x221000+2024] == helper, 'quiet full ITCM before/after differs')
    kernel = (base/'inputs/kernel.bin').read_bytes()
    wrapper = (base/'inputs/wrapper.bin').read_bytes()
    oracle.kernel(kernel)
    oracle.wrapper_code(wrapper)
    rows = []
    for i in range(6):
        require(struct.unpack_from('<32I', ram, 0x231000+i*128) == CP15*2, f'ARM9 CP15 context differs group{i}')
        case, region = divmod(i, 2)
        raw = ram[0x200000+i*0x1800:0x200000+i*0x1800+4128]
        ds = (base/'inputs'/f'a7mulmix_v1_k{case:02d}_r{region}.bin').read_bytes()
        words = struct.unpack_from('<24I', raw)
        dwords = struct.unpack_from('<24I', ds)
        require(words == dwords, f'identity/code/hash/Rs/return/reserved differs group{i}')
        require(raw[3104:] == ds[3104:], f'full live code snapshots differ group{i}')
        for offset in [3104, 3616]:
            oracle.kernel(raw[offset:offset+272])
        for offset in [96, 160]:
            c = struct.unpack_from('<16I', raw, offset)
            require(c[0]&0x80 and not c[0]&0x20 and c[8] == 0x80 and c[10] == 0x84, 'ARM7 IRQ/ARM/timer context differs')
            require(0x03800000 <= c[1] < 0x03810000 and c[2] == 1 and c[3] == 0x71061 and c[5:7] == (0xe880, 3), 'ARM7 private stack/IME/IE/EXMEM/WRAM context differs')
            require(0 <= c[11] < 263 and c[12] == 0 and c[13]&15 == 1 and c[14:16] == (0x1204, 1), 'ARM7 quiet/sound/BIOS/power context differs')
        native_ticks, ds_ticks = [], []
        for j in range(10):
            n = [4, 16][j%2]
            at = 224+j*288
            meta = struct.unpack_from('<8I', raw, at)
            dmeta = struct.unpack_from('<8I', ds, at)
            require(meta[0] == n and meta[1] > 0 and meta[2:4] == ((3*words[16])&0xffffffff,)*2, 'loop/timing/return differs')
            require(0 <= meta[6] < 263 and 0 <= meta[7] < 263, 'VCOUNT out of bounds')
            for offset, count, checksum in [(32, 1, meta[4]), (160, n, meta[5])]:
                b = raw[at+offset:at+offset+128]
                require(oracle.invocation(b, count, words[15], words[16], words[9], words[17]) == checksum, 'full invocation checksum differs')
                pre = struct.unpack_from('<16I', b)
                require(pre[13] == 0x0380fce8, 'captured wrapper stack differs')
                require(pre[5] == (0x0380fd40 if offset == 32 else 0x0380fdc0), 'private capture address differs')
            native_ticks.append(meta[1])
            ds_ticks.append(dmeta[1])
        slopes = [(native_ticks[2*r+1]-native_ticks[2*r])/768 for r in range(5)]
        dslopes = [(ds_ticks[2*r+1]-ds_ticks[2*r])/768 for r in range(5)]
        rows.append(dict(case_id=case, region=region, native_ticks=native_ticks, DS_ticks=ds_ticks,
                         native_paired_slopes=slopes, DS_paired_slopes=dslopes,
                         native_minimum_slope=(min(native_ticks[1::2])-min(native_ticks[::2]))/768,
                         DS_minimum_slope=(min(ds_ticks[1::2])-min(ds_ticks[::2]))/768,
                         paired_slopes_exact=slopes == dslopes))
    return dict(status='PASS function/code/context; timing equality reported separately', guest_source_base=manifest['source'],
                ROM_SHA256=manifest['ROM_SHA256'], groups=6, raw_times=60, invocations=120, register_words=3840,
                helper_before_after_exact=True, ARM9_context_snapshots=12, rows=rows,
                all_paired_slopes_exact=all(r['paired_slopes_exact'] for r in rows),
                scope=manifest['scope'], limitations='Native caller/boot/timer wrapper replaces SDK. Captured MUL wrapper bytes, SP, output addresses and full helper retained. No fixed intercept subtraction; no current-source/game/contended native acceptance from this checker alone.')

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('base', type=Path)
    p.add_argument('dump', type=Path)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    result = check(a.base, a.dump.read_bytes())
    a.out.write_text(json.dumps(result, indent=2)+'\n')
    print(result['status'], 'all paired slopes exact:', result['all_paired_slopes_exact'])
