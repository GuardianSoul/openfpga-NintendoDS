#!/usr/bin/env python3
"""Build a direct-boot .nds image from an ARM9 and an ARM7 binary.

Header layout from GBATEK "DS Cartridge Header". The ARM9 binary goes at
ROM offset 0x8000 or above, so no loader decrypts a KEY1 secure area
(melonDS decrypts only when the ARM9 ROM offset is in 0x4000..0x7FFF).
The Nintendo logo is left as zeroes (direct boot does not check it); the
logo CRC and header CRC are computed over what is written.

Optional pattern section (--pattern OFS:LEN): fills ROM bytes OFS..OFS+LEN-1
with 32-bit words pattern_word(o) = ((o * 0x9E3779B1) ^ 0xC3A5F00F) mod 2^32,
o = the word's ROM byte offset. sw/tests/cart computes the same formula.
"""
import argparse
import struct
import sys


def crc16(data, crc=0xFFFF):
    # GBATEK "BIOS CRC16": CRC-16 with reflected polynomial 0xA001
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def pattern_word(o):
    return ((o * 0x9E3779B1) ^ 0xC3A5F00F) & 0xFFFFFFFF


def align(n, a):
    return (n + a - 1) & ~(a - 1)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("out")
    p.add_argument("--title", required=True)
    p.add_argument("--code", required=True, help="4-character game code")
    p.add_argument("--arm9", required=True)
    p.add_argument("--arm9-ram", type=lambda s: int(s, 0), default=0x02000000)
    p.add_argument("--arm9-entry", type=lambda s: int(s, 0))
    p.add_argument("--arm7", required=True)
    p.add_argument("--arm7-ram", type=lambda s: int(s, 0), default=0x037F8000)
    p.add_argument("--arm7-entry", type=lambda s: int(s, 0))
    p.add_argument("--arm9-rom", type=lambda s: int(s, 0), default=0x8000)
    p.add_argument("--pattern", default=None, help="OFS:LEN pattern section")
    a = p.parse_args()

    if len(a.code) != 4:
        sys.exit("game code must be 4 characters")
    if a.arm9_rom < 0x8000:
        sys.exit("ARM9 ROM offset must be >= 0x8000 (no secure area)")
    arm9 = open(a.arm9, "rb").read()
    arm7 = open(a.arm7, "rb").read()
    arm9 += b"\0" * (align(len(arm9), 4) - len(arm9))
    arm7 += b"\0" * (align(len(arm7), 4) - len(arm7))
    arm9_entry = a.arm9_entry if a.arm9_entry is not None else a.arm9_ram
    arm7_entry = a.arm7_entry if a.arm7_entry is not None else a.arm7_ram

    arm9_off = a.arm9_rom
    arm7_off = align(arm9_off + len(arm9), 0x200)
    end = align(arm7_off + len(arm7), 0x200)

    pat = None
    if a.pattern:
        po, pl = (int(x, 0) for x in a.pattern.split(":"))
        if po < end or po % 4 or pl % 4:
            sys.exit("pattern section must be word-aligned and after the binaries")
        pat = (po, pl)
        end = po + pl

    used = end
    cap = 0
    while (0x20000 << cap) < used:
        cap += 1
    size = 0x20000 << cap

    rom = bytearray(size)
    h = bytearray(0x200)
    h[0x000:0x00C] = a.title.upper().encode("ascii")[:12].ljust(12, b"\0")
    h[0x00C:0x010] = a.code.encode("ascii")
    h[0x010:0x012] = b"00"            # maker code
    h[0x012] = 0                       # unit code: NDS
    h[0x013] = 0                       # encryption seed select
    h[0x014] = cap                     # device capacity: 128 KiB << n
    struct.pack_into("<IIII", h, 0x020, arm9_off, arm9_entry, a.arm9_ram, len(arm9))
    struct.pack_into("<IIII", h, 0x030, arm7_off, arm7_entry, a.arm7_ram, len(arm7))
    # FNT/FAT/overlays: empty (offset = end of used ROM, size 0)
    struct.pack_into("<IIII", h, 0x040, used, 0, used, 0)
    struct.pack_into("<IIII", h, 0x050, 0, 0, 0, 0)
    struct.pack_into("<II", h, 0x060, 0x00586000, 0x001808F8)  # ROMCTRL normal / KEY1 settings
    struct.pack_into("<I", h, 0x068, 0)                         # no icon/title
    struct.pack_into("<HH", h, 0x06C, 0, 0x051E)                # secure CRC, secure delay
    struct.pack_into("<I", h, 0x080, used)                      # total used ROM size
    struct.pack_into("<I", h, 0x084, 0x4000)                    # header size
    struct.pack_into("<H", h, 0x15C, crc16(h[0x0C0:0x15C]))     # logo CRC (logo is zero)
    struct.pack_into("<H", h, 0x15E, crc16(h[0x000:0x15E]))     # header CRC
    rom[0:0x200] = h
    rom[arm9_off:arm9_off + len(arm9)] = arm9
    rom[arm7_off:arm7_off + len(arm7)] = arm7
    if pat:
        po, pl = pat
        for o in range(po, po + pl, 4):
            struct.pack_into("<I", rom, o, pattern_word(o))
    open(a.out, "wb").write(rom)
    print(f"{a.out}: ARM9 rom {arm9_off:#x} ram {a.arm9_ram:#010x} entry {arm9_entry:#010x} "
          f"size {len(arm9):#x}; ARM7 rom {arm7_off:#x} ram {a.arm7_ram:#010x} "
          f"entry {arm7_entry:#010x} size {len(arm7):#x}; ROM {size:#x}")


if __name__ == "__main__":
    main()
