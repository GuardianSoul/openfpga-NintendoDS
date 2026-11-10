#!/usr/bin/env python3
"""Save files in the whole-chip simulation (docs/saves.md, "Tests").

    sim/ds/save_test.py [--tb build/ds/obj/Vnds_top] [--mutate]

cart.nds (tools/ds-tests) reads the save chip at 0x100 (SVBLANK), writes 16
bytes there (SVWRITE), tries a write with write enable off and reads 0x2100,
which wraps to 0x100 on an 8 KiB chip (SVWRDI). Each run loads a .sav as the
Pocket shell does (tb_ds --sav: the save memory, sv_loaded and the size type)
and exports the chip at the end (--sav-out), which must be the loaded file
with the game's 16 bytes at 0x100:
  - an 8 KiB file with 0xFF at 0x100: every check passes, and the file's other
    bytes survive the boot program's choice of type (nds_cart's blank);
  - an 8 KiB file of zeros: SVBLANK reads the file's zeros, not 0xFF;
  - no file: a blank chip (0xFF), as before;
  - a 64 KiB file: the boot program takes EEPROM 64 KiB from the file size
    (0xF1C), so 0x2100 no longer wraps and SVWRDI reads the file's bytes.
  - a 6000-byte file (no size type): EEPROM 8 KiB, the file then 0xFF.
Then the boot program's game list (savelist, melonDS's), with no .sav: KH
358/2 (YKG, EEPROM 64 KiB, a bitmap prefix), HeartGold (IPK, FLASH 512 KiB, an
exception), Burnout Legends (ABO, EEPROM 512 B, issue 1 of the public repo),
The World Ends With You (AWL, EEPROM 64 KiB, issue 2) and NSMB (A2D, not
listed: EEPROM 8 KiB) from BOOT_ROMDIR, 8 frames each; the save memory's
blank must cover the whole chip (16,384, 131,072, 128, 16,384 and 2,048
words). Before the list only 26 games had a type without the plugin's .ndt;
the others got EEPROM 8 KiB, which Burnout reports as a write error and
TWEWY as deleted save data. cart.nds under three more gamecodes covers the
list's common-type and rare-type codes (CODE_CASES). Until
2026-10-24 savetab was read through an absolute address (the boot ROM is
linked at 0 and runs at 0xFFFF8000), never matched, and every game got
EEPROM 8 KiB: 2,048 words here, and "backup memory failed" in HG (#253).
--mutate: planted faults (AGENTS.md) that these runs must catch.
"""
import argparse
import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(os.environ.get('TOOLS', Path.cwd() / 'build/tools/oss-cad-suite/bin'))
ROMS = Path(os.environ.get('BOOT_ROMDIR', Path.home() / 'Git/NDS_Pocket/roms'))
WRITTEN = bytes(0x40 + 7 * i for i in range(16))     # cart.nds SVWRITE


def sav(n, fill=None, ff_at_100=True):
    rng = random.Random(n)
    b = bytearray(n) if fill == 0 else bytearray(rng.getrandbits(8) for _ in range(n))
    if ff_at_100:
        b[0x100:0x110] = b'\xff' * 16
    return bytes(b)


# (name, .sav contents or None, chip bytes, checks expected to fail)
CASES = [
    ('8 KiB file', sav(8192), 8192, set()),
    ('8 KiB of zeros', sav(8192, 0, False), 8192, {10}),
    ('no file', None, 8192, set()),
    ('64 KiB file: type from its size', sav(65536), 65536, {13}),
    # 6000 bytes: no size type (EEPROM 8 KiB by default), 0xFF after the file
    ('6000-byte file', sav(6000), 8192, set()),
]

# (ROM in BOOT_ROMDIR, words the blank of its chip writes)
TYPE_CASES = [('kh358.nds', 16384), ('heartgold.nds', 131072), ('burnout.nds', 128), ('twewy.nds', 16384),
              ('nsmb.nds', 2048)]
# cart.nds under other gamecodes, for the list's other paths: (code, words): a common type (Animal Crossing,
# FLASH 256 KiB), the rare types' escape (Explorers of Sky, EEPROM 128 KiB; Platinum, FLASH 512 KiB)
CODE_CASES = [('ADME', 65536), ('C2SE', 32768), ('CPUE', 131072)]

# (file, original, planted fault)
MUTANTS = [
    # the whole chip blanked, loaded file or not
    ('nds_cart.sv', "if (sv_lw > {1'b0, sz_w}) er_n <= 19'd0;\n                    else begin er_a <= sv_lw[17:0]; er_n <= {1'b0, sz_w} + 19'd1 - sv_lw; end",
     "begin er_a <= 18'd0; er_n <= {1'b0, sz_w} + 19'd1; end"),
    # a file shorter than the chip: its last word blanked too
    ('nds_cart.sv', "else begin er_a <= sv_lw[17:0]; er_n <= {1'b0, sz_w} + 19'd1 - sv_lw; end",
     "else begin er_a <= sv_lw[17:0] - 18'd1; er_n <= {1'b0, sz_w} + 19'd2 - sv_lw; end"),
    ('nds_io.sv', "misc_r = {24'd0, save_info};", "misc_r = 32'd0;"),
]


def run_case(tb, case, d):
    name, data, chip, bad_want = case
    args = [str(tb), '--rom', str(ROOT / 'build/ds-tests/cart.nds'), '--bios9', str(ROMS / 'bios9.bin'),
            '--bios7', str(ROMS / 'bios7.bin'), '--firmware', str(ROMS / 'firmware.bin'),
            '--frames', '100', '--result', '--quiet', '--sav-out', str(d / 'out.sav'), str(chip)]
    if data is not None:
        (d / 'in.sav').write_bytes(data)
        args += ['--sav', str(d / 'in.sav')]
    r = subprocess.run(args, capture_output=True, text=True, cwd=ROOT, timeout=3600)
    bad = {int(l.split()[1].rstrip(':')) for l in r.stdout.splitlines() if l.strip().startswith('check') and 'BAD' in l}
    if 'result: magic 52545344' not in r.stdout:
        return f'no result:\n{r.stdout[-800:]}{r.stderr[-800:]}'
    if bad != bad_want:
        return f'checks failing {sorted(bad)}, expected {sorted(bad_want)}'
    want = bytearray((data or b'') + b'\xff' * (chip - len(data or b'')))
    want[0x100:0x110] = WRITTEN
    got = (d / 'out.sav').read_bytes()
    if got != bytes(want):
        k = next(i for i in range(chip) if got[i] != want[i])
        return f'exported save differs at 0x{k:x}: {got[k:k + 8].hex()}, expected {bytes(want[k:k + 8]).hex()}'
    return None


def run_type(tb, rom, words):
    r = subprocess.run([str(tb), '--rom', str(rom if isinstance(rom, Path) else ROMS / rom), '--bios9', str(ROMS / 'bios9.bin'),
                        '--bios7', str(ROMS / 'bios7.bin'), '--firmware', str(ROMS / 'firmware.bin'),
                        '--frames', '8', '--quiet', '--sav-out', '/dev/null', '0'],
                       capture_output=True, text=True, cwd=ROOT, timeout=3600)
    line = next((l for l in r.stdout.splitlines() if l.startswith('save port')), '')
    got = int(line.split(', ')[1].split()[0]) if line else -1
    # (cart.nds under another code also runs its own save checks: a few more writes; chip sizes differ 2x)
    ok = got == words or (isinstance(rom, Path) and words <= got < words + 256)
    return None if ok else f'{rom}: blank of {got} words, expected {words} ({line or r.stdout[-300:]})'


def run_all(tb, quiet=False, types=True):
    if types:
        with tempfile.TemporaryDirectory() as t:
            roms = list(TYPE_CASES)
            for code, words in CODE_CASES:
                r = bytearray((ROOT / 'build/ds-tests/cart.nds').read_bytes())
                r[0x0C:0x10] = code.encode()
                (Path(t) / f'{code}.nds').write_bytes(r)
                roms.append((Path(t) / f'{code}.nds', words))
            for rom, words in roms:
                p = run_type(tb, rom, words)
                if not quiet:
                    print(f'savelist {rom if isinstance(rom, str) else rom.stem}: {p or "PASS"}', flush=True)
                if p:
                    return p
    with tempfile.TemporaryDirectory() as t:
        for i, case in enumerate(CASES):
            d = Path(t) / str(i)
            d.mkdir()
            p = run_case(tb, case, d)
            if not quiet:
                print(f'{case[0]}: {p or "PASS"}', flush=True)
            if p:
                return f'{case[0]}: {p}'
    return None


def build_mutant(i, f, old, new):
    d = ROOT / 'build/ds/savemut' / str(i)
    shutil.rmtree(d, ignore_errors=True)
    (d / 'rtl').mkdir(parents=True)
    shutil.copytree(ROOT / 'rtl/ds', d / 'rtl/ds')
    p = d / 'rtl/ds' / f
    s = p.read_text()
    if s.count(old) != 1:
        sys.exit(f'pattern not found once in {f}: {old}')
    p.write_text(s.replace(old, new))
    mk = (ROOT / 'sim/ds/ds.mk').read_text()
    rtl = mk.split('DS_RTL   :=')[1].split('DS_TB')[0].replace('\\', ' ').split()
    srcs = [str(d / r) if r.startswith('rtl/ds/') else str(ROOT / r) for r in rtl]
    cmd = [str(TOOLS / 'verilator'), '--cc', '--exe', '--build', '-j', '8', '-O3', '--x-assign', 'fast',
           '--x-initial', 'fast', '--savable', str(ROOT / 'sim/ds/ds_config.vlt'), '-Wno-fatal', '-Wno-WIDTHEXPAND', '-Wno-WIDTHTRUNC', '-Wno-UNUSEDSIGNAL',
           '-Wno-CASEINCOMPLETE', '--top-module', 'nds_top', '--Mdir', str(d / 'obj'), '-CFLAGS', '-std=c++17 -O2',
           *srcs, str(ROOT / 'sim/ds/tb_ds.cpp')]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit('mutant build failed: ' + (r.stdout + r.stderr)[-800:])
    return d / 'obj/Vnds_top'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--tb', type=Path, default=ROOT / 'build/ds/obj/Vnds_top')
    ap.add_argument('--mutate', action='store_true')
    a = ap.parse_args()
    p = run_all(a.tb)
    if p:
        sys.exit(f'FAIL {p}')
    print('save tests PASS')
    if not a.mutate:
        return
    missed = 0
    for i, (f, old, new) in enumerate(MUTANTS):
        p = run_all(build_mutant(i, f, old, new), quiet=True, types=False)
        print(f'mutant {i} {f} [{new[:60]}]: ' + (f'caught ({p.splitlines()[0][:120]})' if p else 'MISSED'), flush=True)
        missed += p is None
    if missed:
        sys.exit(f'FAIL: {missed} mutants missed')
    print(f'all {len(MUTANTS)} mutants caught')


if __name__ == '__main__':
    main()
