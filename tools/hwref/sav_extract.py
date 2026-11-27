#!/usr/bin/env python3
"""Rebuild hwref's result files from a Pocket save (the maintainer 2026-11-27).

On the Pocket core (no DLDI SD), hwref.nds writes its "fat:/hwref/" files into
the cartridge's FLASH save as a log (sw/hwref/common/hwref.c, the save device):
"HWRFSAV1", then records {tag 'W' (the file's whole new contents) or 'A'
(appended), name length, name, u32 length LE, data}, ended by blank 0xFF.

    sav_extract.py Saves/nds/common/hwref.sav OUTDIR

writes OUTDIR/<name> for every file, as the DS writes them to its SD's /hwref/.
A file whose last 'W' record is empty was removed (hwref's remove()) and is not
written. --blank N writes a blank N-byte save (default 1 MiB: the core then
gives hwref.nds a 1 MiB FLASH chip) and exits.

    sav_extract.py OLD.sav OUTDIR --compact NEW.sav [--drop GLOB ...]

also writes NEW.sav (the two-half HWRFSAV2 layout, half 0): one 'W' record
per kept file (its latest contents), so
a full save gets its room back and hwref resumes where it stopped (progress
files kept). --drop leaves files out of NEW.sav only (default: *.bin captures
and files over 64 KiB); OUTDIR keeps everything.
"""
import fnmatch
import argparse
from pathlib import Path
import struct
import sys

MAGIC = b'HWRFSAV1'       # one log from byte 0 (the first Pocket runs)
MAGIC2 = b'HWRFSAV2'      # two 512 KiB halves, each magic + u32 generation + 4 spare, then records
HALF, HDR = 1 << 19, 16


def parse(data):
    """(files, removed, end) of the save's live log, either layout."""
    halves = [(struct.unpack_from('<I', data, b + 8)[0], b) for b in (0, HALF)
              if len(data) >= b + HDR and data[b:b + 8] == MAGIC2]
    if halves:
        _, base = max(halves)
        files, removed, end = parse_log(data, base + HDR, base + HALF)
        return files, removed, end - base
    if data[:8] != MAGIC:
        raise SystemExit('not an hwref save (no HWRFSAV header): was hwref.nds run with no SD?')
    return parse_log(data, 8, len(data))


def parse_log(data, a, lim):
    files, removed = {}, set()
    while a + 6 < lim:
        tag, n = data[a], data[a + 1]
        if tag not in (ord('W'), ord('A')):
            break
        name = data[a + 2:a + 2 + n].decode('ascii', 'replace')
        (size,) = struct.unpack_from('<I', data, a + 2 + n)
        body = a + 6 + n
        if body + size > lim:
            print(f'warning: record {name} at {a:#x} runs past the save; stopping', file=sys.stderr)
            break
        chunk = data[body:body + size]
        if tag == ord('W'):
            files[name] = bytearray(chunk)
            if size == 0:
                removed.add(name)
            else:
                removed.discard(name)
        else:
            files.setdefault(name, bytearray()).extend(chunk)
            removed.discard(name)
        a = body + size
    return files, removed, a


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('save', type=Path)
    ap.add_argument('out', type=Path, nargs='?')
    ap.add_argument('--blank', type=int, nargs='?', const=1 << 20, help='write a blank save of this size and exit')
    ap.add_argument('--compact', type=Path, help='also write a compacted save here')
    ap.add_argument('--drop', action='append', default=None, help='glob left out of the compacted save')
    ap.add_argument('--max-keep', type=int, default=64 << 10, help='files over this size are left out of the compacted save')
    args = ap.parse_args()
    if args.blank:
        args.save.write_bytes(b'\xff' * args.blank)
        print(f'{args.save}: blank {args.blank} bytes')
        return
    if not args.out:
        ap.error('OUTDIR is required')
    files, removed, end = parse(args.save.read_bytes())
    args.out.mkdir(parents=True, exist_ok=True)
    for name, body in sorted(files.items()):
        if name in removed:
            continue
        p = args.out / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(body)
    kept = len(files) - len(removed)
    print(f'{kept} files to {args.out} ({end:,} of {len(args.save.read_bytes()):,} save bytes used)')
    if args.compact:
        drops = args.drop or ['*.bin']
        size = len(args.save.read_bytes())
        new = bytearray(b'\xff' * size)
        new[:HDR] = MAGIC2 + struct.pack('<I', 1) + b'\xff' * 4   # half 0, generation 1
        a, left = HDR, []
        for name, body in sorted(files.items()):
            if name in removed:
                continue
            if any(fnmatch.fnmatch(name, g) for g in drops) or len(body) > args.max_keep:
                left.append(name)
                continue
            n = name.encode('ascii')
            rec = bytes([ord('W'), len(n)]) + n + struct.pack('<I', len(body)) + bytes(body)
            new[a:a + len(rec)] = rec
            a += len(rec)
        if a + 1 > HALF:
            raise SystemExit(f'kept files need {a:,} bytes, over the {HALF:,}-byte half')
        args.compact.write_bytes(new)
        print(f'{args.compact}: {a:,} bytes used; left out (kept in {args.out}): {", ".join(left) or "none"}')


if __name__ == '__main__':
    main()
