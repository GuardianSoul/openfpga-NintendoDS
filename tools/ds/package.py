#!/usr/bin/env python3
"""Package the DS core for the Pocket (docs/phase2-integration.md).

    package.py apf_top.rbf OUTDIR [--diag] [--desc=TEXT]

Writes OUTDIR/NDS.zip: Cores/GuardianSoul.NintendoDS/ (bit-reversed RBF and the APF JSON)
and Platforms/nds.json for cards without a DS platform (install it only if
the card has none). BIOS, firmware and ROMs come from the card's
Assets/nds/common/; none is included.

--diag: the NDSDiag core (docs/diag.md; a core_top_ds DIAG = 1 build): Cores/GuardianSoul.NintendoDSDiag/ in
NDSDiag.zip, with the diagnostics log slot (ID 11, after the save: DIAG_POS 7), which the Pocket writes on
quit to Saves/nds/common/<game>.ndg. --desc: core.json's description (name the build: "NDSDiag #613 ...").
"""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
CORE = 'GuardianSoul.NintendoDS'
PLATFORM = 'nds'
LOG_FILE = 'nds-log.bin'
LOG_BYTES = 516                 # rtl/pocket/core_top_ds.sv's log: 128 words + 4 spare
VERSION = '0.2.0'

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


# parameters 0xA4 as the save's: the Pocket names the file after the launched game
DIAG_SLOT = {'name': 'Diag log', 'id': 11, 'required': False, 'parameters': '0xA4', 'nonvolatile': True,
             'extensions': ['ndg'], 'size_maximum': '0x80000', 'address': '0x70000000'}



def boot_image():
    """nds_boot.bin (ID 12): the boot ROM (8 KiB, core_top_ds BOOT_SRAM), then SERV's ROM-cache firmware
    (4 KiB, core_top_ds SHELL_CPU; nds_cart_scpu reads it at SDRAM byte 0xB02000)"""
    boot = (ROOT / 'sw/boot/bootrom.bin').read_bytes()
    fw = (ROOT / 'sw/scpu/cache.bin').read_bytes()
    assert len(boot) <= 8192, 'bootrom.bin over 8 KiB'
    assert len(fw) <= 4096, 'sw/scpu/cache.bin over 4 KiB'
    return boot + bytes(8192 - len(boot)) + fw + bytes(4096 - len(fw))

def main():
    global CORE
    diag = '--diag' in sys.argv[3:]
    desc = next((a.split('=', 1)[1] for a in sys.argv[3:] if a.startswith('--desc=')),
                'Nintendo DS (NDS_Pocket Phase 2: CPUs, system, 2D; no 3D or sound yet)')
    if diag:
        CORE = 'GuardianSoul.NintendoDSDiag'
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
        'metadata': {'platform_ids': [PLATFORM], 'shortname': 'NintendoDSDiag' if diag else 'NintendoDS',
                     'description': desc,
                     'author': 'GuardianSoul', 'url': 'https://github.com/GuardianSoul/openfpga-NintendoDS', 'version': VERSION, 'date_release': '2026-10-23'},
        'framework': {'target_product': 'Analogue Pocket', 'version_required': '1.1',
                      'sleep_supported': False, 'dock': {'supported': True, 'analog_output': False},
                      'hardware': {'link_port': False, 'cartridge_adapter': -1}},
        'cores': [{'name': 'default', 'id': 0, 'filename': 'bitstream.rbf_r'}]}})
    # Slot order matters: the core writes the log's size into data-table word
    # 9 (slot 4) and finds the others by ID.
    write('data.json', {'data': {'magic': 'APF_VER_1', 'data_slots': [
        {'name': 'NDS ROM', 'id': 1, 'required': True, 'parameters': '0x08', 'deferload': True,
         'extensions': ['nds'], 'size_maximum': '0x20000000', 'address': '0x20000000'},
        {'name': 'ARM9 BIOS', 'id': 2, 'required': True, 'parameters': '0x08', 'filename': 'bios9.bin',
         'size_exact': 4096, 'address': '0x10000000'},
        {'name': 'ARM7 BIOS', 'id': 3, 'required': True, 'parameters': '0x08', 'filename': 'bios7.bin',
         'size_exact': 16384, 'address': '0x10100000'},
        {'name': 'Firmware', 'id': 4, 'required': True, 'parameters': '0x08', 'filename': 'firmware.bin',
         'size_maximum': '0x80000', 'address': '0x10200000'},
        {'name': 'Core log', 'id': 9, 'required': False, 'parameters': '0x00', 'nonvolatile': True,
         'filename': LOG_FILE, 'extensions': ['bin'], 'size_maximum': LOG_BYTES, 'address': '0x40000000'},
        # after the log: core_top_ds's LOG_POS = 4 is the log's data-table position
        {'name': 'ROM Tables', 'id': 5, 'required': False, 'parameters': '0x08', 'extensions': ['ndt'],
         'size_maximum': '0x90000', 'address': '0x30000000'},
        # the game's save (docs/saves.md): nonvolatile, named after the launched
        # .nds, Saves/nds/common/<game>.sav; the core writes the chip size into
        # its data-table word (position 6: core_top_ds's SAVE_POS)
        {'name': 'Save', 'id': 10, 'required': False, 'parameters': '0xA4', 'nonvolatile': True,
         'extensions': ['sav'], 'size_maximum': '0x100000', 'address': '0x60000000'}]
        + ([DIAG_SLOT] if diag else [])
        # last, so no data-table position above moves: the boot ROM image (core_top_ds BOOT_SRAM), shipped in
        # Assets/nds/GuardianSoul.NintendoDS/ (the core's own folder, so Assets/nds/common stays the user's; parameters bit 1 asks for that folder)
        + [{'name': 'Boot ROM', 'id': 12, 'required': True, 'parameters': '0x0A', 'filename': 'nds_boot.bin',
            'size_exact': 12288, 'address': '0x10300000'}]}})
    # slot 0: stacked (256 x 384, two 4:3 screens); slot 1: one screen
    write('video.json', {'video': {'magic': 'APF_VER_1', 'scaler_modes': [
        {'width': 256, 'height': 384, 'aspect_w': 2, 'aspect_h': 3, 'rotation': 0, 'mirror': 0},
        {'width': 256, 'height': 192, 'aspect_w': 4, 'aspect_h': 3, 'rotation': 0, 'mirror': 0},
        # rotated for book-style games (Core Setting "Rotation", docs/screen-orientation.md; the maintainer confirmed
        # 270 = Left, anticlockwise, and 90 = Right on the Pocket): stacked 2 Left, 3 Right; one screen (top
        # only or bottom only) 4 Left, 5 Right
        {'width': 256, 'height': 384, 'aspect_w': 2, 'aspect_h': 3, 'rotation': 270, 'mirror': 0},
        {'width': 256, 'height': 384, 'aspect_w': 2, 'aspect_h': 3, 'rotation': 90, 'mirror': 0},
        {'width': 256, 'height': 192, 'aspect_w': 4, 'aspect_h': 3, 'rotation': 270, 'mirror': 0},
        {'width': 256, 'height': 192, 'aspect_w': 4, 'aspect_h': 3, 'rotation': 90, 'mirror': 0}]}})
    write('input.json', {'input': {'magic': 'APF_VER_1', 'controllers': [
        {'type': 'default', 'mappings': [
            {'id': 0, 'name': 'A', 'key': 'pad_btn_a'},
            {'id': 1, 'name': 'B', 'key': 'pad_btn_b'},
            {'id': 2, 'name': 'X', 'key': 'pad_btn_x'},
            {'id': 3, 'name': 'Y', 'key': 'pad_btn_y'},
            {'id': 4, 'name': 'L', 'key': 'pad_trig_l'},
            {'id': 5, 'name': 'R', 'key': 'pad_trig_r'},
            {'id': 6, 'name': 'Select', 'key': 'pad_btn_select'},
            {'id': 7, 'name': 'Start', 'key': 'pad_btn_start'}]}]}})
    # Core Settings: tools/ds/settings.py, the same table the RTL header comes from
    sys.path.insert(0, str(ROOT / 'tools/ds'))
    from settings import interact_variables
    write('interact.json', {'interact': {'magic': 'APF_VER_1', 'variables': interact_variables(),
                                         'messages': []}})
    write('variants.json', {'variants': {'magic': 'APF_VER_1', 'variant_list': []}})
    write('audio.json', {'audio': {'magic': 'APF_VER_1'}})
    (core / 'info.txt').write_text(
        'NDS_Pocket DS core, Phase 2 (docs/phase2-integration.md)\n'
        '* Pick a .nds ROM in Assets/nds/common. bios9.bin, bios7.bin and firmware.bin\n'
        '  must be there too.\n'
        '* Assets/nds/' + CORE + '/nds_boot.bin (in this zip) is the core\'s own boot ROM: install it with the core.\n'
        '* Direct boot: the game starts without the firmware menu.\n'
        '* No 3D and no sound in this version; no saves.\n'
        '* SELECT+R: stacked / top only / bottom only; SELECT+L: touch cursor (D-pad, A = pen)\n'
        '* On quit, a short log goes to Saves/nds/common/nds-log.bin\n'
        + ('* NDSDiag: on quit, the diagnostics log goes to Saves/nds/common/<game>.ndg (docs/diag.md)\n' if diag else ''))
    notices = core / 'licenses'
    notices.mkdir()
    for name in ('MIRLO64-LICENSE.txt', 'MIRLO64-NOTICE.txt'):
        shutil.copyfile(ROOT / 'rtl/apf' / name, notices / name)
    (notices / 'NOTICE.txt').write_text(NOTICE)
    platforms = sd / 'Platforms'
    platforms.mkdir()
    (platforms / f'{PLATFORM}.json').write_text(json.dumps({'platform': {
        'category': 'Handheld', 'name': 'Nintendo DS', 'year': 2004, 'manufacturer': 'Nintendo'}}, indent=2) + '\n')
    ad = sd / 'Assets' / PLATFORM / CORE
    ad.mkdir(parents=True, exist_ok=True)
    (ad / 'nds_boot.bin').write_bytes(boot_image())
    zpath = out / ('NDSDiag.zip' if diag else 'NDS.zip')
    with zipfile.ZipFile(zpath, 'w', zipfile.ZIP_DEFLATED) as z:
        for p in sorted(sd.rglob('*')):
            if p.is_file():
                z.write(p, p.relative_to(sd))
        z.write(ROOT / 'README.md', 'README.md')
    digest = lambda b: hashlib.sha256(b).hexdigest()
    (out / 'package.txt').write_text(f'rbf sha256 {digest(original)}\nrbf_r sha256 {digest(reversed_rbf)}\n'
                                     f'zip sha256 {digest(zpath.read_bytes())}\n')
    print(zpath)


if __name__ == '__main__':
    main()
