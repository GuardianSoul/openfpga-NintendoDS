#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Runs plugin.wasm on test SD cards through host/run_plugin.py (the extism
host Pocket Sync and pupdate use) and checks what it leaves on the card:
game files, ROM tables, compression with keep and replace, a card too full
for the compressed ROM, and runs stopped part-way.

Needs `pip install extism`. Build first (scripts/build.sh).

  python3 tests/test_plugin.py [--rom ../../roms/nsmb.nds]
"""
import argparse
import json
from pathlib import Path
import random
import shutil
import struct
import subprocess
import sys
import tempfile

PLUGIN = Path(__file__).resolve().parents[1]
WASM = PLUGIN / 'target/wasm32-wasip1/release/plugin.wasm'
sys.path.insert(0, str(PLUGIN / 'ref'))
import ndz  # noqa: E402

CORE = 'GuardianSoul.NintendoDS'
RESERVE = 256 << 20
# The slots proposed in docs/pocket-plugin.md ("Core side").
DATA_SLOTS = [
    {'name': 'Game', 'id': 0, 'required': True, 'parameters': '0x12', 'extensions': ['json']},
    {'name': 'NDS ROM', 'id': 1, 'required': False, 'parameters': '0x09', 'deferload': True, 'extensions': ['nds'],
     'size_maximum': '0x20000000', 'address': '0x20000000'},
    {'name': 'ARM9 BIOS', 'id': 2, 'required': True, 'parameters': '0x08', 'filename': 'bios9.bin', 'size_exact': 4096,
     'address': '0x10000000'},
    {'name': 'Save', 'id': 10, 'required': False, 'parameters': '0xA4', 'nonvolatile': True, 'extensions': ['sav'],
     'size_maximum': '0x100000', 'address': '0x60000000'},
    {'name': 'ROM Tables', 'id': 5, 'required': False, 'parameters': '0x08', 'extensions': ['ndt'],
     'size_maximum': '0x90000', 'address': '0x30000000'},
]


def make_rom(path, size, seed, files):
    """A ROM with a header, compressible data and a FAT (no FNT names)."""
    rng = random.Random(seed)
    words = [bytes(rng.getrandbits(8) for _ in range(8)) for _ in range(32)]
    body = bytearray()
    while len(body) < size:
        body += rng.choice(words) if rng.random() < 0.8 else bytes([rng.getrandbits(8)])
    rom = bytearray(body[:size])
    rom[0:12] = b'TESTROM'.ljust(12, b'\0')
    rom[0x0C:0x10] = b'ATS' + bytes([0x41 + seed])
    struct.pack_into('<IIII', rom, 0x20, 0x4000, 0x02000800, 0x02000000, 0x3000)
    struct.pack_into('<IIII', rom, 0x30, 0x8000, 0x02380000, 0x02380000, 0x1000)
    struct.pack_into('<IIII', rom, 0x40, 0, 0, 0x9000, 8 * len(files))
    for i, (s, e) in enumerate(files):
        struct.pack_into('<II', rom, 0x9000 + 8 * i, s, e)
    path.write_bytes(rom)


def make_card(root, roms, slots=DATA_SLOTS):
    core = root / 'Cores' / CORE
    core.mkdir(parents=True)
    (core / 'core.json').write_text(json.dumps({'core': {'metadata': {'platform_ids': ['ds']}}}))
    (core / 'data.json').write_text(json.dumps({'data': {'magic': 'APF_VER_1', 'data_slots': slots}}))
    common = root / 'Assets/nds/common'
    common.mkdir(parents=True)
    for name, src in roms.items():
        shutil.copyfile(src, common / name)
    return common


def run(card, *answers, config=(), host=None, expect_fail=False):
    cmd = [sys.executable, str(PLUGIN / 'host/run_plugin.py'), str(WASM), str(card)]
    for a in answers:
        cmd += ['--answer', a]
    for c in config:
        cmd += ['--config', c]
    if host:
        cmd += ['--host-folder', str(host)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if (r.returncode != 0) != expect_fail:
        sys.exit(f'run {answers} {config}: exit {r.returncode}\n{r.stdout}\n{r.stderr}')
    return r.stdout


def used(card):
    return sum(p.stat().st_size for p in card.rglob('*') if p.is_file())


def check(cond, what):
    if not cond:
        sys.exit(f'FAIL: {what}')
    print(f'ok    {what}')


def instance(card, name):
    return json.loads((card / f'Assets/nds/{CORE}/{name}.json').read_text())['instance']


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--rom', type=Path, help='a real ROM to add to the test card (copied)')
    a = p.parse_args()
    if not WASM.is_file():
        sys.exit('build plugin.wasm first (scripts/build.sh)')
    tmp = Path(tempfile.mkdtemp(prefix='ds-plugin-'))
    try:
        src = tmp / 'src'
        src.mkdir()
        make_rom(src / 'Alpha.nds', 3 << 20, 1, [(0xA000, 0x20000), (0x20000, 0x20010), (0x2F000, 0x200000)])
        make_rom(src / 'Beta Game (Europe).nds', 1 << 20, 2, [(0xC000, 0xFF000)])
        roms = {'Alpha.nds': src / 'Alpha.nds', 'Beta Game (Europe).nds': src / 'Beta Game (Europe).nds'}
        if a.rom:
            roms['Real.nds'] = a.rom

        # 1. game files
        card = tmp / 'card1'
        common = make_card(card, roms)
        (common / 'Stale.ndz.part').write_bytes(b'x' * 100)
        out = run(card, 'Generate Game Files')
        check('Compress ROMs' not in out, 'no compression choice while the core reads no .ndz')
        check(not (common / 'Stale.ndz.part').exists(), 'unfinished .part files from a stopped run are removed')
        for name in roms:
            game = name[:-4]
            t = ndz.ndt_fields(common / f'{game}.ndt')
            check(t['rom_size'] == (common / name).stat().st_size and t['table_offset'] == 0x1000, f'{game}.ndt written')
            inst = instance(card, game)
            check(inst['data_path'] == '' and inst['data_slots'] == [{'id': 1, 'filename': name}, {'id': 5, 'filename': f'{game}.ndt'},
                                                                     {'id': 10, 'filename': f'{game}.sav'}],
                  f'{game}.json names the ROM (slot 1), its tables (slot 5) and its save (slot 10)')
        t = ndz.ndt_fields(common / 'Alpha.ndt')
        check([w >> 29 for w in t['table'][4:8]] == [2, 1, 0, 0] and [w >> 29 for w in t['table'][28:33]] == [3, 2, 1, 0, 0],
              'Alpha.ndt read-ahead fields follow the cache rule')
        out = run(card, 'Generate Game Files')
        check(out.count('tables up to date') == len(roms), 'a second run leaves the tables as they are')
        (common / 'More').mkdir()
        shutil.copyfile(roms['Alpha.nds'], common / 'More/Gamma.nds')
        run(card, 'Generate Game Files')
        check(instance(card, 'Gamma') == {'magic': 'APF_VER_1', 'data_path': '', 'data_slots': [
            {'id': 1, 'filename': 'More/Gamma.nds'}, {'id': 5, 'filename': 'More/Gamma.ndt'}, {'id': 10, 'filename': 'Gamma.sav'}]},
              'a game in a subfolder: its folder in the ROM and table names, the save in Saves/nds/common')
        (common / 'More/Gamma.nds').unlink()
        (common / 'More/Gamma.ndt').unlink()
        (card / f'Assets/nds/{CORE}/Gamma.json').unlink()

        # 2. a core without game-file slots: tables only
        card = tmp / 'card2'
        make_card(card, roms, slots=[DATA_SLOTS[1]])
        out = run(card, 'Generate Game Files')
        check((card / 'Assets/nds/common/Alpha.ndt').is_file() and not (card / f'Assets/nds/{CORE}').exists(),
              'a core without a .json slot gets the tables only')
        check("doesn't take game files" in out, '... and the plugin says so')

        # 3. compression behind the setting: keep
        card = tmp / 'card3'
        common = make_card(card, roms)
        out = run(card, 'Compress ROMs', 'Compress, Keep the Originals', config=['compress=1'])
        for name in roms:
            game = name[:-4]
            z = common / f'{game}.ndz'
            check(z.is_file() and (common / name).is_file(), f'keep: {game}.ndz next to {name}')
            back = tmp / 'back.nds'
            subprocess.run([sys.executable, str(PLUGIN / 'ref/ndz.py'), 'decompress', str(z), str(back)], check=True)
            check(back.read_bytes() == (common / name).read_bytes(), f'keep: {game}.ndz decompresses to the ROM')
            check(instance(card, game)['data_slots'][0]['filename'] == name, f'keep: {game}.json still names the .nds (core reads no .ndz)')
        out = run(card, 'Generate Game Files', config=['compress=1'])
        check('Compress ROMs' not in out, 'no compression choice once every ROM has its .ndz')

        # 4. replace, with a core that reads .ndz
        ndz_slots = [dict(s) for s in DATA_SLOTS]
        ndz_slots[1]['extensions'] = ['nds', 'ndz']
        card = tmp / 'card4'
        common = make_card(card, roms, slots=ndz_slots)
        out = run(card, 'Compress ROMs', 'Compress, Replace the Originals')
        for name in roms:
            game = name[:-4]
            check(not (common / name).exists() and (common / f'{game}.ndz').is_file(), f'replace: {name} replaced by {game}.ndz')
            check(instance(card, game)['data_slots'][0] == {'id': 1, 'filename': f'{game}.ndz'}, f'replace: {game}.json names the .ndz')
            t = ndz.ndt_fields(common / f'{game}.ndt')
            t0 = ndz.ndt_fields(tmp / 'card1/Assets/nds/common' / f'{game}.ndt')
            check(t == t0, f'replace: {game}.ndt from the .ndz equals the one from the .nds')
        (common / 'Alpha.ndz').write_bytes(b'NDZ1' + bytes(100))
        out = run(card, 'Generate Game Files')
        check("skip Alpha.ndz: the .ndz can't be read" in out, 'a broken .ndz is reported, not used')

        # 5. a card too full for the .ndz next to the ROM
        card = tmp / 'card5'
        common = make_card(card, {'Alpha.nds': roms['Alpha.nds']}, slots=ndz_slots)
        host = tmp / 'host5'
        host.mkdir()
        limit = used(card) + RESERVE + (64 << 10)
        out = run(card, 'Compress ROMs', 'Compress, Keep the Originals', config=[f'test_card_bytes={limit}'], host=host)
        check(not (common / 'Alpha.ndz').exists() and (common / 'Alpha.nds').is_file() and 'not enough free space' in out,
              'full card, keep: nothing written, the ROM stays')
        out = run(card, 'Compress ROMs', 'Compress, Replace the Originals', config=[f'test_card_bytes={limit}'], host=host)
        check('compressing on the computer first' in out and (common / 'Alpha.ndz').is_file() and not (common / 'Alpha.nds').exists(),
              'full card, replace: compressed on the computer, then swapped')
        check(not any((host / 'DS Conversions').iterdir()), "the computer's work folder is cleared")

        # 6. stopped part-way: the next run finishes the job
        for step in ('journal', 'remove', 'copied'):
            card = tmp / f'card6-{step}'
            common = make_card(card, {'Alpha.nds': roms['Alpha.nds']}, slots=ndz_slots)
            host = tmp / f'host6-{step}'
            host.mkdir()
            run(card, 'Compress ROMs', 'Compress, Replace the Originals', config=[f'test_card_bytes={limit}', f'test_stop_at={step}'],
                host=host, expect_fail=True)
            check((host / 'DS Conversions/Alpha/journal.json').is_file(), f'stopped at {step}: the journal waits on the computer')
            out = run(card, 'Generate Game Files', host=host)
            check('Finishing the compression of' in out and (common / 'Alpha.ndz').is_file() and not (common / 'Alpha.nds').exists()
                  and not (common / 'Alpha.ndz.part').exists(), f'stopped at {step}: the next run finishes it')
            back = tmp / 'back.nds'
            subprocess.run([sys.executable, str(PLUGIN / 'ref/ndz.py'), 'decompress', str(common / 'Alpha.ndz'), str(back)], check=True)
            check(back.read_bytes() == roms['Alpha.nds'].read_bytes(), f'stopped at {step}: the .ndz holds the ROM')

        # 7. stopped after the .ndz is written, before the original goes: both stay
        card = tmp / 'card7'
        common = make_card(card, {'Alpha.nds': roms['Alpha.nds']}, slots=ndz_slots)
        run(card, 'Compress ROMs', 'Compress, Replace the Originals', config=['test_stop_at=before-remove'], expect_fail=True)
        check((common / 'Alpha.nds').is_file() and (common / 'Alpha.ndz').is_file(), 'stopped before removing: ROM and .ndz both stay')
        out = run(card, 'Generate Game Files')
        check(instance(card, 'Alpha')['data_slots'][0]['filename'] == 'Alpha.ndz', '... and the game file uses the checked .ndz')
        print('all plugin tests pass')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()
