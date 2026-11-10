#!/usr/bin/env python3
"""Build a $readmemh image for sim/arm/tb_arm.sv.

usage: mkhex.py out.hex file.bin@0x08000000 [file2.bin@0x00000000 ...]

The testbench retains {addr[27:24], addr[17:2]} for its 256 KB regions.
Region 2 has 4 MB main RAM: beyond its first 256 KB, image slots are
0x100000 | addr[21:2]. Bit22 remains a mirror. A binary must not cross
its region's boundary (4 MB for main RAM, 256 KB otherwise).
"""
import sys


def main():
    out = sys.argv[1]
    words = {}
    for spec in sys.argv[2:]:
        path, addr = spec.rsplit("@", 1)
        base = int(addr, 0)
        data = open(path, "rb").read()
        data += b"\0" * (-len(data) % 4)
        main_ram = ((base >> 24) & 0xF) == 2
        size = 0x400000 if main_ram else 0x40000
        if (base & (size - 1)) + len(data) > size:
            sys.exit(f"{path}: crosses a {size // 1024} KB region boundary at {base:#x}")
        for i in range(0, len(data), 4):
            a = base + i
            idx = ((a >> 24) & 0xF) << 16 | ((a >> 2) & 0xFFFF)
            if main_ram and (a & 0x3C0000):
                idx = 0x100000 | ((a >> 2) & 0xFFFFF)
            words[idx] = int.from_bytes(data[i:i + 4], "little")
    with open(out, "w") as f:
        last = None
        for idx in sorted(words):
            if last is None or idx != last + 1:
                f.write(f"@{idx:x}\n")
            f.write(f"{words[idx]:08x}\n")
            last = idx


if __name__ == "__main__":
    main()
