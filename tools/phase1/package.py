#!/usr/bin/env python3
"""Package the Phase 1 test core for the Pocket (docs/phase1-foundation.md).

    package.py apf_top.rbf OUTDIR

Writes OUTDIR/NDSPhase1.zip: Cores/GuardianSoul.NintendoDSPhase1/ (bit-reversed RBF and the
APF JSON) and Platforms/nds.json for cards without a DS platform (install it
only if the card has none). BIOS, firmware and ROMs come from the card's
Assets/nds/common/; none is included.
"""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
CORE = 'GuardianSoul.NintendoDSPhase1'
PLATFORM = 'nds'
LOG_FILE = 'phase1-log.bin'
LOG_BYTES = 528                 # rtl/pocket/core_top.sv LOG_BYTES: 128 words + 4 spare
VERSION = '0.1.0'

NOTICE = """The Nintendo DS core for Analogue Pocket is distributed under the GNU General
Public License, version 3 or (at your option) any later version. It contains
third-party parts under their own terms (the APF template files via MIRLO64,
whose NOTICE and LICENSE are in this folder; sound_i2s and the PocketQuake
PSRAM controller by Adam Gastineau, MIT; SERV by Olof Kindgren, ISC; parts of
the PlayStation core for Analogue Pocket, MIT). Files whose header says MIT are
under the MIT License. The full list is THIRD_PARTY_NOTICES.md in the source:
https://github.com/GuardianSoul/openfpga-NintendoDS

The core was designed to match the behaviour of melonDS, copyright the melonDS
team, GNU General Public License version 3 or later.

MIT License text: Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including without
limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom
the Software is furnished to do so, subject to the following conditions: The
above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS
IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.
"""


def main():
    rbf, out = Path(sys.argv[1]), Path(sys.argv[2])
    original = rbf.read_bytes()
    if len(original) < 10000:
        sys.exit('RBF missing or truncated')
    table = bytes(int(f'{b:08b}'[::-1], 2) for b in range(256))
    reversed_rbf = original.translate(table)
    if reversed_rbf.translate(table) != original:
        sys.exit('bit reversal round trip failed')
    shutil.rmtree(out, ignore_errors=True)
    sd = out / 'SD'
    core = sd / 'Cores' / CORE
    core.mkdir(parents=True)
    (core / 'bitstream.rbf_r').write_bytes(reversed_rbf)

    def write(name, value):
        (core / name).write_text(json.dumps(value, indent=2) + '\n')
    write('core.json', {'core': {
        'magic': 'APF_VER_1',
        'metadata': {'platform_ids': [PLATFORM], 'shortname': 'NDSPhase1',
                     'description': 'NDS_Pocket Phase 1 test: memories, video, BIOS loading and cartridge streaming',
                     'author': 'GuardianSoul', 'url': 'https://github.com/GuardianSoul/openfpga-NintendoDS', 'version': VERSION, 'date_release': '2026-10-23'},
        'framework': {'target_product': 'Analogue Pocket', 'version_required': '1.1',
                      'sleep_supported': False, 'dock': {'supported': True, 'analog_output': False},
                      'hardware': {'link_port': False, 'cartridge_adapter': -1}},
        'cores': [{'name': 'default', 'id': 0, 'filename': 'bitstream.rbf_r'}]}})
    # Slot order matters: the core writes the log's size into data-table word
    # 9 (position 4) and finds the others by ID. The ROM stays the required
    # launch slot, so the test core starts from any .nds (no ROM tables: the
    # cache's demand-only fallback). Slots 5 (ROM tables) and 0 (game file)
    # are docs/pocket-plugin.md's, optional here: the DS core is where the
    # plugin's game files are the launch path.
    write('data.json', {'data': {'magic': 'APF_VER_1', 'data_slots': [
        {'name': 'NDS ROM', 'id': 1, 'required': True, 'parameters': '0x09', 'deferload': True,
         'extensions': ['nds'], 'size_maximum': '0x20000000', 'address': '0x20000000'},
        {'name': 'ARM9 BIOS', 'id': 2, 'required': False, 'parameters': '0x08', 'filename': 'bios9.bin',
         'size_exact': 4096, 'address': '0x10000000'},
        {'name': 'ARM7 BIOS', 'id': 3, 'required': False, 'parameters': '0x08', 'filename': 'bios7.bin',
         'size_exact': 16384, 'address': '0x10100000'},
        {'name': 'Firmware', 'id': 4, 'required': False, 'parameters': '0x08', 'filename': 'firmware.bin',
         'size_maximum': '0x80000', 'address': '0x10200000'},
        {'name': 'Phase 1 log', 'id': 9, 'required': False, 'parameters': '0x00', 'nonvolatile': True,
         'filename': LOG_FILE, 'extensions': ['bin'], 'size_maximum': LOG_BYTES, 'address': '0x40000000'},
        {'name': 'ROM Tables', 'id': 5, 'required': False, 'parameters': '0x08', 'extensions': ['ndt'],
         'size_maximum': '0x90000', 'address': '0x30000000'},
        {'name': 'Game', 'id': 0, 'required': False, 'parameters': '0x12', 'extensions': ['json']},
        # the game's save (docs/saves.md): nonvolatile, named after the launched
        # .nds, Saves/nds/common/<game>.sav; the core writes the chip size
        {'name': 'Save', 'id': 10, 'required': False, 'parameters': '0xA4', 'nonvolatile': True,
         'extensions': ['sav'], 'size_maximum': '0x100000', 'address': '0x60000000'}]}})
    # slot 0: stacked (256 x 384, two 4:3 screens); slot 1: one screen
    write('video.json', {'video': {'magic': 'APF_VER_1', 'scaler_modes': [
        {'width': 256, 'height': 384, 'aspect_w': 2, 'aspect_h': 3, 'rotation': 0, 'mirror': 0},
        {'width': 256, 'height': 192, 'aspect_w': 4, 'aspect_h': 3, 'rotation': 0, 'mirror': 0}]}})
    write('input.json', {'input': {'magic': 'APF_VER_1', 'controllers': [
        {'type': 'default', 'mappings': [
            {'id': 0, 'name': 'Test tone (hold) / pen in touch mode', 'key': 'pad_btn_a'},
            {'id': 1, 'name': 'SELECT+R: screen layout, SELECT+L: touch mode', 'key': 'pad_btn_select'}]}]}})
    write('interact.json', {'interact': {'magic': 'APF_VER_1', 'variables': [], 'messages': []}})
    write('variants.json', {'variants': {'magic': 'APF_VER_1', 'variant_list': []}})
    write('audio.json', {'audio': {'magic': 'APF_VER_1'}})
    (core / 'info.txt').write_text(
        'NDS_Pocket Phase 1 test core (docs/phase1-foundation.md)\n'
        '* Pick a .nds ROM. BIOS9/BIOS7/firmware come from Assets/nds/common\n'
        '  (bios9.bin, bios7.bin, firmware.bin) if present\n'
        '* Eight boxes: SDRAM, PSRAM, SRAM, BIOS9, BIOS7, firmware, pass A, cartridge\n'
        '  grey waiting/absent, yellow running, green pass, red fail\n'
        '* Two bars: pass A (direct reads) and pass B (through the ROM cache)\n'
        '* SELECT+R: stacked / top only / bottom only; SELECT+L: touch cursor (D-pad, A = pen)\n'
        '* Hold A for a test tone\n'
        '* When the cartridge box is green, quit: the log goes to Saves/nds/common/phase1-log.bin\n'
        '* This does not run DS games\n')
    notices = core / 'licenses'
    notices.mkdir()
    for name in ('MIRLO64-LICENSE.txt', 'MIRLO64-NOTICE.txt'):
        shutil.copyfile(ROOT / 'rtl/apf' / name, notices / name)
    (notices / 'NOTICE.txt').write_text(NOTICE)
    platforms = sd / 'Platforms'
    platforms.mkdir()
    (platforms / f'{PLATFORM}.json').write_text(json.dumps({'platform': {
        'category': 'Handheld', 'name': 'Nintendo DS', 'year': 2004, 'manufacturer': 'Nintendo'}}, indent=2) + '\n')
    zpath = out / 'NDSPhase1.zip'
    with zipfile.ZipFile(zpath, 'w', zipfile.ZIP_DEFLATED) as z:
        for p in sorted(sd.rglob('*')):
            if p.is_file():
                z.write(p, p.relative_to(sd))
        z.write(ROOT / 'docs/phase1-foundation.md', 'NDSPhase1-INSTALL.md')
    digest = lambda b: hashlib.sha256(b).hexdigest()
    (out / 'package.txt').write_text(f'rbf sha256 {digest(original)}\nrbf_r sha256 {digest(reversed_rbf)}\n'
                                     f'zip sha256 {digest(zpath.read_bytes())}\n')
    print(zpath)


if __name__ == '__main__':
    main()
