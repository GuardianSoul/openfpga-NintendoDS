#!/usr/bin/env python3
"""Recompute V3_PAD and V3_PAD_RO in v3.c (docs/hw-reference.md "sndcap").

    sw/hwref/sndcap/v3pad.py

Builds sw/hwref, reads build/hwref/sndcap.elf and sets the two pads so that
.main.rw starts at 0x0d0 and the heap (__heap_start_ntr) at 0x030 modulo
4 KiB, as in sndcap 2, then rebuilds until both hold. Run it after any change
to v3.c, then rerun the v1/v2 equivalence check.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
SRC = os.path.join(ROOT, "sw/hwref/sndcap/v3.c")
ELF = os.path.join(ROOT, "build/hwref/sndcap.elf")
BIN = os.path.join(os.environ.get("DEVKITARM", os.path.expanduser("~/devkitpro/devkitARM")), "bin")
RW, HEAP = 0x0D0, 0x030


def build():
    r = subprocess.run(["make", "-C", os.path.join(ROOT, "sw/hwref")], capture_output=True, text=True)
    if r.returncode or "warning" in r.stdout + r.stderr:
        sys.exit(r.stdout[-3000:] + r.stderr[-3000:])


def layout():
    h = subprocess.run([os.path.join(BIN, "arm-none-eabi-objdump"), "-h", ELF],
                       capture_output=True, text=True).stdout
    rw = next(int(f[3], 16) for f in (line.split() for line in h.splitlines())
              if len(f) > 3 and f[1] == ".main.rw")
    n = subprocess.run([os.path.join(BIN, "arm-none-eabi-nm"), ELF], capture_output=True, text=True).stdout
    return rw, int(re.search(r"(\w+) b __heap_start_ntr", n).group(1), 16)


def main():
    for _ in range(4):
        build()
        rw, heap = layout()
        s = open(SRC).read()
        pad = int(re.search(r"#define V3_PAD (0x[0-9a-f]+)", s).group(1), 16)
        pro = int(re.search(r"#define V3_PAD_RO (0x[0-9a-f]+)", s).group(1), 16)
        print(f".main.rw 0x{rw:08x}  heap 0x{heap:08x}  V3_PAD 0x{pad:x}  V3_PAD_RO 0x{pro:x}")
        if (rw & 0xFFF) == RW and (heap & 0xFFF) == HEAP:
            print("ok")
            return 0
        npad = (pad + RW - (rw & 0xFFF)) % 0x1000
        npro = (pro + HEAP - ((heap + npad - pad) & 0xFFF)) % 0x1000
        s = re.sub(r"#define V3_PAD 0x[0-9a-f]+", f"#define V3_PAD 0x{npad:x}", s)
        s = re.sub(r"#define V3_PAD_RO 0x[0-9a-f]+", f"#define V3_PAD_RO 0x{npro:x}", s)
        open(SRC, "w").write(s)
    sys.exit("no fixed point")


if __name__ == "__main__":
    sys.exit(main())
