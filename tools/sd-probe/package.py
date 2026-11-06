#!/usr/bin/env python3
"""Package the SD probe for the Pocket (docs/sd-probe.md).

    package.py apf_top.rbf OUTDIR

Writes OUTDIR/NDSSDProbe.zip: the core (bit-reversed RBF, as openFPGA cores
ship it) with its APF JSON, and a Platforms/nds.json for cards that have no
DS platform yet (install it only if the card has none). ROMs come from
Assets/nds/common/; none is included.
"""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
CORE = 'GuardianSoul.NintendoDSSDProbe'
PLATFORM = 'nds'
LOG_FILE = 'sd-probe-log.bin'
# rtl/probe/sd_probe.sv: 32 header words + 8 per record, 7 cases of 64, 4 spare words
SAVE_BYTES = (32 + 8 * 7 * 64 + 4) * 4


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
        'metadata': {'platform_ids': [PLATFORM], 'shortname': 'NDSSDProbe',
                     'description': 'Measures APF data-slot read latency and throughput from the SD card',
                     'author': 'GuardianSoul', 'url': 'https://github.com/GuardianSoul/openfpga-NintendoDS', 'version': '0.2.0', 'date_release': '2026-10-23'},
        'framework': {'target_product': 'Analogue Pocket', 'version_required': '1.1',
                      'sleep_supported': False, 'dock': {'supported': True, 'analog_output': False},
                      'hardware': {'link_port': False, 'cartridge_adapter': -1}},
        'cores': [{'name': 'default', 'id': 0, 'filename': 'bitstream.rbf_r'}]}})
    # Slot order matters: the core writes the log's size into data-table
    # word 3 (pairs of ID, size in this order), and finds the ROM by ID 1.
    # The ROM is not deferred: the Pocket loads it to bridge 0 at start-up
    # (the core times it), and the core reads it again with target commands.
    write('data.json', {'data': {'magic': 'APF_VER_1', 'data_slots': [
        {'name': 'NDS ROM', 'id': 1, 'required': True, 'parameters': '0x09', 'deferload': False,
         'extensions': ['nds'], 'size_maximum': '0x20000000', 'address': '0x00000000'},
        {'name': 'Probe log', 'id': 2, 'required': False, 'parameters': '0x00', 'nonvolatile': True,
         'filename': LOG_FILE, 'extensions': ['bin'], 'size_maximum': SAVE_BYTES, 'address': '0x40000000'}]}})
    write('video.json', {'video': {'magic': 'APF_VER_1', 'scaler_modes': [
        {'width': 640, 'height': 480, 'aspect_w': 4, 'aspect_h': 3, 'rotation': 0, 'mirror': 0}]}})
    for key, field in [('input', 'controllers'), ('interact', 'variables'), ('variants', 'variant_list')]:
        body = {'magic': 'APF_VER_1', field: []}
        if key == 'interact':
            body['messages'] = []
        write(key + '.json', {key: body})
    write('audio.json', {'audio': {'magic': 'APF_VER_1'}})
    (core / 'info.txt').write_text(
        'NDS SD read probe (NDS_Pocket docs/sd-probe.md)\n'
        '* Pick a .nds ROM: the Pocket loads it (timed), then the probe re-reads parts of it\n'
        '* Top bar: blue waiting, yellow running, green done, red failed\n'
        '* When green, quit: the log is saved to Saves/nds/common/sd-probe-log.bin\n'
        '* Audio is silent; this does not run DS games\n')
    notices = core / 'licenses'
    notices.mkdir()
    for name in ('MIRLO64-LICENSE.txt', 'MIRLO64-NOTICE.txt'):
        shutil.copyfile(ROOT / 'rtl/apf' / name, notices / name)
    platforms = sd / 'Platforms'
    platforms.mkdir()
    (platforms / f'{PLATFORM}.json').write_text(json.dumps({'platform': {
        'category': 'Handheld', 'name': 'Nintendo DS', 'year': 2004, 'manufacturer': 'Nintendo'}}, indent=2) + '\n')
    zpath = out / 'NDSSDProbe.zip'
    with zipfile.ZipFile(zpath, 'w', zipfile.ZIP_DEFLATED) as z:
        for p in sorted(sd.rglob('*')):
            if p.is_file():
                z.write(p, p.relative_to(sd))
        z.write(ROOT / 'docs/sd-probe.md', 'NDSSDProbe-INSTALL.md')
    digest = lambda b: hashlib.sha256(b).hexdigest()
    (out / 'package.txt').write_text(f'rbf sha256 {digest(original)}\nrbf_r sha256 {digest(reversed_rbf)}\n'
                                     f'zip sha256 {digest(zpath.read_bytes())}\n')
    print(zpath)


if __name__ == '__main__':
    main()
