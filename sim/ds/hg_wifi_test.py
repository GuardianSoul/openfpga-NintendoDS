#!/usr/bin/env python3
"""HeartGold reaches CONTINUE without "A communication error" (docs/wifi.md).

    sim/ds/hg_wifi_test.py [--tb build/ds/obj/Vnds_top] [--mutate] [--v2]

Runs HeartGold (BOOT_ROMDIR/heartgold.nds) with a full save
(heartgold-100.sav: Mystery Gift unlocked, so the main menu starts the
wireless) in tb_ds from boot, pressing START and A through the intro, and
looks at frame 1000: the CONTINUE menu has a black top screen; the error
screen is blue on both. About an hour per run under load. --mutate: the same
with the WiFi block absent (a WIFI=0 build), which must show the error.
--v2: nds_wifi's state machine (a WIFI_MC=0 build) instead of the default nds_wifi_mc.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(os.environ.get('TOOLS', Path.cwd() / 'build/tools/oss-cad-suite/bin'))
ROMS = Path(os.environ.get('BOOT_ROMDIR', Path.home() / 'Git/NDS_Pocket/roms'))
KEYS = '200 206 START; 300 306 START; 400 406 START; 500 506 START; 600 606 A; 700 706 A; 800 806 A; 900 906 A'


def top_screen(ppm):
    """Fractions of the top screen's pixels that are the error screen's blue, and black."""
    data = ppm.read_bytes()
    # P6\n256 384\n255\n
    hdr_end = 0
    for _ in range(3):
        hdr_end = data.index(b'\n', hdr_end) + 1
    px = data[hdr_end:hdr_end + 256 * 192 * 3]
    blue = sum(1 for i in range(0, len(px), 3) if px[i] < 40 and px[i + 1] < 40 and px[i + 2] > 150)
    black = sum(1 for i in range(0, len(px), 3) if px[i] < 24 and px[i + 1] < 24 and px[i + 2] < 24)
    return blue / (256 * 192), black / (256 * 192)


def menu(b):
    """The CONTINUE menu: no error-screen blue (the error screen measures 0.30, its text box covers
    the rest; the menu 0.00) and a mostly black top screen (a white or other screen is not the menu)"""
    return b is not None and b[0] <= 0.15 and b[1] >= 0.9


def run(tb, out, extra=()):
    out.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([str(tb), '--rom', str(ROMS / 'heartgold.nds'), '--bios9', str(ROMS / 'bios9.bin'),
                        '--bios7', str(ROMS / 'bios7.bin'), '--firmware', str(ROMS / 'firmware.bin'),
                        '--frames', '1001', '--shots', str(out), '--shot-every', '1000',
                        '--sav', str(ROMS / 'heartgold-100.sav'), '--keys', KEYS, '--quiet', *extra],
                       capture_output=True, text=True, cwd=ROOT, timeout=6 * 3600)
    for l in r.stdout.splitlines():
        if l.startswith(('wifi-check', 'wifi-reads')):
            print(l)
    shot = out / 'f001000.ppm'
    if not shot.exists():
        return None, f'no frame 1000 ({r.stdout[-300:]}{r.stderr[-300:]})'
    b, k = top_screen(shot)
    return (b, k), f'top screen {b:.0%} error-blue, {k:.0%} black'


def build(obj, params):
    obj.mkdir(parents=True, exist_ok=True)       # Verilator does not create its parents
    mk = (ROOT / 'sim/ds/ds.mk').read_text()
    rtl = mk.split('DS_RTL   :=')[1].split('DS_TB')[0].replace('\\', ' ').split()
    cmd = [str(TOOLS / 'verilator'), '--cc', '--exe', '--build', '-j', '8', '-O3', '--x-assign', 'fast',
           '--x-initial', 'fast', '--savable', '-Wno-fatal', '-Wno-WIDTHEXPAND', '-Wno-WIDTHTRUNC', '-Wno-UNUSEDSIGNAL',
           '-Wno-CASEINCOMPLETE', '--top-module', 'nds_top', *params, '--Mdir', str(obj), '-CFLAGS', '-std=c++17 -O2',
           *[str(ROOT / f) for f in rtl], str(ROOT / 'sim/ds/tb_ds.cpp')]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit('build failed: ' + (r.stdout + r.stderr)[-800:])
    return obj / 'Vnds_top'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--tb', type=Path)
    ap.add_argument('--mutate', action='store_true')
    ap.add_argument('--v2', action='store_true')
    ap.add_argument('--store', action='store_true', help='WIFI=3: plain words in SDRAM, no radio (no lockstep check)')
    a = ap.parse_args()
    sfx = '_v2' if a.v2 else '_store' if a.store else ''
    tb = a.tb or build(ROOT / f'build/hgwifi/obj{sfx}', ['-GWIFI_MC=0'] if a.v2 else ['-GWIFI=3'] if a.store else [])
    b, msg = run(tb, ROOT / f'build/hgwifi/shots{sfx}', [] if a.store else ['--wifi-check'])
    print(f'HeartGold, WiFi block: {msg}')
    if not menu(b):
        sys.exit('FAIL: no CONTINUE menu at frame 1000')
    if a.mutate:
        b, msg = run(build(ROOT / 'build/hgwifi/obj0', ['-GWIFI=0']), ROOT / 'build/hgwifi/shots0')
        print(f'HeartGold, no WiFi block (planted fault): {msg}')
        if menu(b):
            sys.exit('FAIL: the fault (WiFi absent) was not caught')
        print('fault caught')
    print('PASS')


if __name__ == '__main__':
    main()
