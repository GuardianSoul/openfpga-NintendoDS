#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reference decoder for the DS core's .ndz compressed ROMs and reader for
its .ndt ROM tables (docs/pocket-plugin.md). Written for clarity, to test the
core's RTL against: decode_block works the way a hardware decoder does, one
byte at a time, with the block itself as the match window.

  python3 ref/ndz.py decompress GAME.ndz GAME.nds   # whole ROM (checks the CRC-32)
  python3 ref/ndz.py block GAME.ndz N               # block N, as hex
  python3 ref/ndz.py check GAME.ndz GAME.nds [--every K]   # compare every K-th block
  python3 ref/ndz.py ndt GAME.ndt                   # the tables' header fields
"""
import struct
import sys
import zlib

BLOCK = 4096
NDZ_HEADER = 0x40


def words(b, at, n):
    return struct.unpack_from(f'<{n}I', b, at)


class Ndz:
    """A .ndz file: header, index, random access to blocks."""

    def __init__(self, path):
        self.f = open(path, 'rb')
        h = self.f.read(NDZ_HEADER)
        magic = h[:4]
        version, self.rom_size, shift, self.blocks, index_at, data_at, codec, self.crc, self.game_code = words(h, 4, 9)
        if magic != b'NDZ1' or version != 1 or shift != 12 or codec != 1 or index_at != NDZ_HEADER:
            raise ValueError('not a version 1 .ndz with 4 KiB LZ4 blocks')
        if self.blocks != (self.rom_size + BLOCK - 1) // BLOCK:
            raise ValueError('block count')
        self.index = words(self.f.read(4 * (self.blocks + 1)), 0, self.blocks + 1)
        if self.index[0] != data_at:
            raise ValueError('index')

    def raw_len(self, n):
        return min(BLOCK, self.rom_size - n * BLOCK)

    def stored(self, n):
        self.f.seek(self.index[n])
        return self.f.read(self.index[n + 1] - self.index[n])

    def block(self, n):
        return decode_block(self.stored(n), self.raw_len(n))


def decode_block(stored, raw_len):
    """One block: stored raw when its stored length (a multiple of 4) is at
    least raw_len rounded up to 4, else an LZ4 block decoded until raw_len
    bytes are out (the padding after it is never read)."""
    if len(stored) >= (raw_len + 3) & ~3:
        return bytes(stored[:raw_len])
    out = bytearray()
    i = 0

    def byte():
        nonlocal i
        if i >= len(stored):
            raise ValueError('block ends inside a sequence')
        i += 1
        return stored[i - 1]

    def length(n):                     # 15 means more bytes follow, each added, until one isn't 255
        if n == 15:
            while True:
                b = byte()
                n += b
                if b != 255:
                    break
        return n

    while len(out) < raw_len:
        token = byte()
        for _ in range(length(token >> 4)):          # literals
            out.append(byte())
        if len(out) >= raw_len:                       # the last sequence has no match
            break
        offset = byte() | byte() << 8                 # match: offset back from the next output byte
        if offset == 0 or offset > len(out):
            raise ValueError('match offset outside the block')
        for _ in range(length(token & 15) + 4):      # copied a byte at a time: it may overlap itself
            out.append(out[-offset])
    if len(out) != raw_len:
        raise ValueError('block overflows')
    return bytes(out)


def ndt_fields(path):
    return ndt_fields_bytes(open(path, 'rb').read())


def ndt_fields_bytes(b):
    if b[:4] != b'NDT1':
        raise ValueError('not a .ndt')
    names = ['version', 'file_size', 'rom_size', 'block_shift', 'blocks', 'table_offset', 'flags', 'game_code',
             'crc16_version', 'streams_offset', 'streams',
             'arm9_rom_offset', 'arm9_entry', 'arm9_ram_address', 'arm9_size',
             'arm7_rom_offset', 'arm7_entry', 'arm7_ram_address', 'arm7_size',
             'fnt_offset', 'fnt_size', 'fat_offset', 'fat_size', 'fat_entries', 'spans', 'marks', 'save_type']
    fields = dict(zip(names, words(b, 4, len(names))))
    fields['table'] = list(words(b, fields['table_offset'], fields['blocks']))
    at = fields['streams_offset']
    fields['stream_spans'] = [words(b, at + 8 * k, 2) for k in range(fields['streams'])]
    return fields


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'decompress':
        z, crc = Ndz(sys.argv[2]), 0
        with open(sys.argv[3], 'wb') as out:
            for n in range(z.blocks):
                b = z.block(n)
                crc = zlib.crc32(b, crc)
                out.write(b)
        if crc != z.crc:
            sys.exit('CRC-32 differs from the original')
    elif cmd == 'block':
        print(Ndz(sys.argv[2]).block(int(sys.argv[3])).hex())
    elif cmd == 'check':
        z, rom = Ndz(sys.argv[2]), open(sys.argv[3], 'rb')
        every = int(sys.argv[5]) if sys.argv[4:5] == ['--every'] else 1
        for n in range(0, z.blocks, every):
            rom.seek(n * BLOCK)
            if z.block(n) != rom.read(z.raw_len(n)):
                sys.exit(f'block {n} differs')
        print(f'{len(range(0, z.blocks, every))} of {z.blocks} blocks match')
    elif cmd == 'ndt':
        f = ndt_fields(sys.argv[2])
        t = f.pop('table')
        for k, v in f.items():
            print(f'{k:18s} {v:#x}' if isinstance(v, int) else f'{k:18s} {v}')
        print(f'{"table":18s} {sum(1 for w in t if w >> 29)} blocks with read-ahead, {sum(1 for w in t if w >> 28 & 1)} stream blocks')
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
