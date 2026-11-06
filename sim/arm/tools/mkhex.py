#!/usr/bin/env python3
"""Build a $readmemh image for sim/arm/tb_arm.sv.

usage: mkhex.py out.hex file.bin@0x08000000 [file2.bin@0x00000000 ...]

The testbench memory is indexed by {addr[27:24], addr[17:2]}: 16 regions of
256 KB each. A binary must not cross a 256 KB boundary.
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
        if (base & 0x3FFFF) + len(data) > 0x40000:
            sys.exit(f"{path}: crosses a 256 KB region boundary at {base:#x}")
        for i in range(0, len(data), 4):
            a = base + i
            idx = ((a >> 24) & 0xF) << 16 | ((a >> 2) & 0xFFFF)
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
