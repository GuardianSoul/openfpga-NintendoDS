#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks the plugin's formats on real ROMs (docs/pocket-plugin.md, "Tests").
For every ROM:

  header  the plugin's header fields and FAT equal melonDS's (its NDSHeader,
          tests/melonds_header.cpp), and the .ndt's save type equals the
          game's entry in melonDS's ROMList
  rtl     the .ndt's read-ahead table equals the one nds_cart_cache.sv built
          with its own start-up scan (tests/tb_cart_table.sv in Verilator),
          with its span, mark and cap counts. The scan left the core in
          e9fffce (the core now loads the .ndt), so the reference is the last
          version that had it, SCAN_REV.
  model   ... and the one sim/phase1/run.py's cache model builds from
          melonDS's fields, and the .ndt sim/phase1/run.py's make_ndt()
          writes (what the Phase 1 tests feed the core)
  ndz     compress -> decompress gives the ROM back, both with the plugin's
          decoder and with the reference decoder (ref/ndz.py)

ROMs are only read. Outputs go to --out (default target/checks).

  python3 tests/check_roms.py ../../roms/*.nds
  python3 tests/check_roms.py --card /path/to/sd-card     # + Assets/nds/common/*.nds
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
PLUGIN = HERE.parent
REPO = PLUGIN.parents[1]
sys.path.insert(0, str(PLUGIN / 'ref'))
import ndz  # noqa: E402

SCAN_REV = 'fdc5368'  # the last rtl/pocket/nds_cart_cache.sv with the start-up scan
TOOLS = Path(os.environ.get('TOOLS', Path.cwd() / 'build/tools/oss-cad-suite/bin'))


def load_phase1():
    import importlib.util
    spec = importlib.util.spec_from_file_location('phase1_run', REPO / 'sim/phase1/run.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


phase1 = load_phase1()


def melonds_src():
    for root in (REPO, REPO.parents[2] if REPO.parent.name == 'worktrees' else REPO):
        if (root / 'references/melonDS/src/NDS_Header.h').is_file():
            return root / 'references/melonDS/src'
    sys.exit('references/melonDS is not checked out')


def build(out):
    subprocess.run(['cargo', 'build', '--release', '--example', 'dstool', '-q'], cwd=PLUGIN, check=True)
    mel = out / 'melonds_header'
    subprocess.run(['g++', '-std=c++17', '-O2', '-I', str(melonds_src()), str(HERE / 'melonds_header.cpp'), str(melonds_src() / 'ROMList.cpp'), '-o', str(mel)], check=True)
    vdir = out / 'vtb'
    cache = out / 'nds_cart_cache_scan.sv'
    cache.write_bytes(subprocess.run(['git', 'show', f'{SCAN_REV}:rtl/pocket/nds_cart_cache.sv'], cwd=REPO, check=True,
                                     capture_output=True).stdout)
    subprocess.run([str(TOOLS / 'verilator'), '--binary', '--timing', '-O2', '-j', '8', '-Wno-fatal', '-Wno-WIDTHEXPAND',
                    '-Wno-WIDTHTRUNC', '--top-module', 'tb_cart_table', '-Mdir', str(vdir),
                    str(HERE / 'tb_cart_table.sv'), str(cache)],
                   check=True, stdout=subprocess.DEVNULL)
    return PLUGIN / 'target/release/examples/dstool', mel, vdir / 'Vtb_cart_table'


def model_table(m):
    """sim/phase1/run.py's mark rule (expected_fetches), from melonDS's fields."""
    size = m['size']
    n = (size + 4095) // 4096
    ra = [0] * n
    spans = marks = 0
    budget = 4 * n
    capped = False
    fat_off, fat_len = m['fat_at']
    fat_n = 0 if fat_off >= size else min(fat_len, size - fat_off) >> 3
    a9, a7 = m['arm9'], m['arm7']
    for s, e in [(a9[0], (a9[0] + a9[3]) & 0xFFFFFFFF), (a7[0], (a7[0] + a7[3]) & 0xFFFFFFFF)] + [tuple(f) for f in m['fat'][:fat_n]]:
        e = min(e, size)
        if s >= e:
            continue
        sb, se = (s + 4095) // 4096, (e + 4095) // 4096
        spans += 1
        for b in range(sb, se):
            if budget == 0:
                capped = True
                break
            ra[b] = min(4, se - 1 - b)
            budget -= 1
            marks += 1
        if capped:
            break
    return ra, spans, marks, capped


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while chunk := f.read(1 << 22):
            h.update(chunk)
    return h.hexdigest()


def check(rom, out, tools):
    dstool, mel, tb = tools
    name = rom.stem
    fails = []
    m = json.loads(subprocess.run([str(mel), str(rom)], check=True, capture_output=True, text=True).stdout)
    info = json.loads(subprocess.run([str(dstool), 'info', str(rom)], check=True, capture_output=True, text=True).stdout)
    for k in ('size', 'game_code', 'arm9', 'arm7', 'fnt', 'fat_at', 'fat'):
        if info[k] != m[k]:
            fails.append(f'header: {k} differs from melonDS')
    # .ndt
    ndt_path = out / f'{name}.ndt'
    subprocess.run([str(dstool), 'ndt', str(rom), str(ndt_path)], check=True)
    f = ndz.ndt_fields(ndt_path)
    want = {'rom_size': m['size'], 'game_code': m['game_code'], 'arm9_rom_offset': m['arm9'][0], 'arm9_entry': m['arm9'][1],
            'arm9_ram_address': m['arm9'][2], 'arm9_size': m['arm9'][3], 'arm7_rom_offset': m['arm7'][0], 'arm7_entry': m['arm7'][1],
            'arm7_ram_address': m['arm7'][2], 'arm7_size': m['arm7'][3], 'fat_offset': m['fat_at'][0], 'fat_size': m['fat_at'][1],
            'fnt_offset': m['fnt'][0], 'fnt_size': m['fnt'][1], 'blocks': (m['size'] + 4095) // 4096}
    for k, v in want.items():
        if f[k] != v:
            fails.append(f'ndt: {k} {f[k]:#x}, melonDS {v:#x}')
    if f['crc16_version'] & 0xFFFF != m['header_crc16']:
        fails.append('ndt: header CRC differs')
    st = m['save_mem_type']
    if f['save_type'] != ((1 << 31 | st) if 0 <= st <= 7 else 0):
        fails.append(f'ndt: save type {f["save_type"]:#x}, melonDS ROMList {st}')
    if f['table'] != info['table']:
        fails.append('ndt: table differs from the plugin\'s own')
    table_ra = [w >> 29 for w in f['table']]
    # RTL
    rtl_out = out / f'{name}.rtl.txt'
    subprocess.run([str(tb), f'+rom={rom}', f'+size={m["size"]}', f'+out={rtl_out}'], check=True, stdout=subprocess.DEVNULL)
    lines = rtl_out.read_text().split('\n')
    stats = dict(zip(*[iter(lines[0].split())] * 2))
    rtl_ra = [int(x) for x in lines[1:] if x]
    if rtl_ra != table_ra:
        bad = next(i for i, (a, b) in enumerate(zip(rtl_ra, table_ra)) if a != b) if len(rtl_ra) == len(table_ra) else 'length'
        fails.append(f'rtl: table differs (block {bad})')
    if (int(stats['spans']), int(stats['marks']), int(stats['capped'])) != (f['spans'], f['marks'], f['flags'] & 1):
        fails.append(f'rtl: counts {stats} vs ndt spans {f["spans"]} marks {f["marks"]} flags {f["flags"]}')
    if stats['fail'] != '0':
        fails.append('rtl: fetch failed')
    # model
    ra, spans, marks, capped = model_table(m)
    if (ra, spans, marks, int(capped)) != (table_ra, f['spans'], f['marks'], f['flags'] & 1):
        fails.append('model: table or counts differ')
    # sim/phase1/run.py's .ndt (only reads; the ROM is at most 512 MiB)
    data = rom.read_bytes()
    p1 = phase1.make_ndt(data)
    t1 = ndz.ndt_fields_bytes(p1)
    if [w >> 29 for w in t1['table']] != table_ra or any(t1[k] != f[k] for k in ('version', 'rom_size', 'block_shift', 'blocks', 'table_offset')):
        fails.append('phase1: sim/phase1/run.py make_ndt() differs')
    del data, p1
    # ndz round trip
    z_path, back = out / f'{name}.ndz', out / f'{name}.back.nds'
    t = time.time()
    r = json.loads(subprocess.run([str(dstool), 'ndz', str(rom), str(z_path)], check=True, capture_output=True, text=True).stdout)
    subprocess.run([str(dstool), 'unndz', str(z_path), str(back)], check=True)
    want_sha = sha(rom)
    if sha(back) != want_sha:
        fails.append('ndz: the plugin\'s decoder gives different bytes')
    back.unlink()
    subprocess.run([sys.executable, str(PLUGIN / 'ref/ndz.py'), 'decompress', str(z_path), str(back)], check=True)
    if sha(back) != want_sha:
        fails.append('ndz: the reference decoder gives different bytes')
    back.unlink()
    z_path.unlink()
    streams = f['streams']
    print(f'{name:40s} {"PASS" if not fails else "FAIL"}  save {st}  files {len(m["fat"]):5d}  spans {f["spans"]:5d}  marks {f["marks"]:6d}'
          f'  streams {streams:3d}  ndz {r["ratio"]:.3f}x ({r["seconds"]:.1f} s)  [{time.time() - t:.0f} s]')
    for line in fails:
        print('   ', line)
    return not fails


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('roms', nargs='*', type=Path)
    p.add_argument('--card', type=Path, help='SD card root: also check Assets/nds/common/*.nds (read only)')
    p.add_argument('--out', type=Path, default=PLUGIN / 'target/checks')
    a = p.parse_args()
    roms = [r.resolve() for r in a.roms]
    if a.card:
        roms += sorted((a.card / 'Assets/nds/common').glob('*.nds'))
    if not roms:
        sys.exit('no ROMs')
    a.out.mkdir(parents=True, exist_ok=True)
    tools = build(a.out)
    ok = [check(r, a.out, tools) for r in roms]
    print(f'{sum(ok)} of {len(ok)} ROMs pass')
    sys.exit(0 if all(ok) else 1)


if __name__ == '__main__':
    main()
