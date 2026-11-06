#!/usr/bin/env python3
"""Run one DS test ROM in the melonDS census runner and decode its result block.

The runner has no RAM dump, so this asks it for a savestate at the last
frame and reads main RAM out of the state's "NDSG" section (melonDS
savestate major 14: section magic, length, 8 reserved bytes, a config word,
then the 16 MiB main RAM array). The result block sits at physical
0x023F0000, i.e. offset 0x3F0000 of main RAM. Screenshots (PPM) are also
converted to PNG when Pillow is available.

Exit status 0 when the block is present, done, and every check passed.
"""
import argparse
import os
import struct
import subprocess
import sys

MAGIC = 0x52545344


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--census", required=True)
    p.add_argument("--bios", required=True, help="directory with bios9.bin, bios7.bin, firmware.bin")
    p.add_argument("--rom", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--frames", type=int, default=120)
    p.add_argument("--shot-every", type=int, default=30)
    a = p.parse_args()

    os.makedirs(a.out, exist_ok=True)
    script = os.path.join(a.out, "noinput.txt")
    open(script, "w").write("# no input\n")
    state = os.path.join(a.out, "end.mln")
    cmd = [a.census,
           "--bios9", os.path.join(a.bios, "bios9.bin"),
           "--bios7", os.path.join(a.bios, "bios7.bin"),
           "--firmware", os.path.join(a.bios, "firmware.bin"),
           "--rom", a.rom, "--script", script, "--out", a.out,
           "--frames", str(a.frames), "--shot-every", str(a.shot_every),
           "--save-state", state, "--save-state-at", str(a.frames - 1)]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    open(os.path.join(a.out, "census.log"), "w").write(r.stdout)
    if r.returncode != 0:
        print(r.stdout)
        sys.exit(f"census failed ({r.returncode})")

    st = open(state, "rb").read()
    i = st.find(b"NDSG")
    if i < 0:
        sys.exit("no NDSG section in the savestate")
    ram = i + 16 + 4
    blk = ram + 0x3F0000
    magic, n, mask, done = struct.unpack_from("<4I", st, blk)
    name = os.path.basename(a.rom)
    if magic != MAGIC:
        print(f"{name}: no result block (magic {magic:08X})")
        sys.exit(1)
    vals = struct.unpack_from(f"<{n}I", st, blk + 16)
    full = 0xFFFFFFFF if n >= 32 else (1 << n) - 1
    ok = done == 1 and (mask & full) == full
    print(f"{name}: {n} checks, mask {mask:08X} of {full:08X}, done {done} -> {'PASS' if ok else 'FAIL'}")
    for k, v in enumerate(vals):
        print(f"  {k:2d} {v:08X} {'ok' if mask >> k & 1 else 'BAD'}")

    try:
        from PIL import Image
        shots = os.path.join(a.out, "shots")
        for f in sorted(os.listdir(shots)):
            if f.endswith(".ppm"):
                Image.open(os.path.join(shots, f)).save(os.path.join(shots, f[:-4] + ".png"))
    except ImportError:
        pass
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
