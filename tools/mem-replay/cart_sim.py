#!/usr/bin/env python3
"""Simulate DS cartridge streaming over the Pocket's APF bridge.

    python3 tools/mem-replay/cart_sim.py [--ndz DIR] GAME=ROM [GAME=ROM ...]
    e.g. heartgold=roms/heartgold.nds  (trace: build/census/carttrace/GAME/cart_trace.csv)

--ndz DIR takes the *+lz ratios from DIR/GAME.ndz (the Pocket plugin's
compressed ROM, docs/pocket-plugin.md) instead of zlib-1.

Link model, measured on the test Pocket (docs/sd-probe.md): one command at a
time, each costing OVERHEAD plus bytes / RATE, with commands of at most
MAX_CMD bytes. The game blocks on a read until its bytes are in the SDRAM ROM
cache, so every wait beyond a real card's ~0.1 ms per 512-byte read delays
the rest of the trace.

Strategies:
  base       16 MB LRU cache, 4 KiB blocks, fetch on miss (today's plan)
  big        48 MB LRU cache, 4 KiB blocks
  file       big + whole-file read-ahead: a miss inside a NitroFS file (FAT
             entry) fetches the requested block first, then the rest of the
             file in the background, in MAX_CMD chunks. This loses: Pokemon
             files are multi-MB archives that block the link.
  ra16/ra64  big + read-ahead capped at 16/64 KiB past the missed block,
             within its file, as one command with the demand block
  ra16pf     ra16 + the core's sequential prefetch (rtl/pocket/nds_cart_cache.sv):
             a run that ends inside its file starts a background fetch of the
             next run (up to 5 blocks); the first read of a prefetched run
             starts the one after it. A demand miss waits for the command in
             flight
  ra*+lz     the same with a compressed ROM
  file+lz    file + a compressed ROM: transfer time scaled by each 32 KiB
             chunk's zlib-1 ratio (decoder assumed faster than the link)
  preload    file+lz, with every block this session touches loaded at boot
             (upper bound for a learned hot list); boot time reported
"""
import bisect
import csv
import struct
import sys
import zlib
from collections import OrderedDict

SYS = 33_513_982
OVERHEAD = 0.9e-3
RATE = 1.75e6
MAX_CMD = 256 * 1024
BLK = 4096
T_DS = 512 / 6.7e6 + 20e-6           # real card time per 512 B read, already in the trace


def nitro_files(rom):
    """Sorted (start, end) of every FAT entry plus the ARM9/ARM7 binaries."""
    fat_off, fat_len = struct.unpack_from('<II', rom, 0x48)
    spans = []
    for i in range(fat_len // 8):
        s, e = struct.unpack_from('<II', rom, fat_off + 8 * i)
        if e > s:
            spans.append((s, e))
    for off in (0x20, 0x30):          # ARM9, ARM7: rom offset, entry, ram, size
        s = struct.unpack_from('<I', rom, off)[0]
        n = struct.unpack_from('<I', rom, off + 12)[0]
        spans.append((s, s + n))
    spans.sort()
    return spans


class Link:
    def __init__(self, ratio=None):
        self.free_at = 0.0            # link busy until
        self.ratio = ratio            # per-32K-chunk compression ratio, or None

    def cost(self, start, nbytes):
        b = nbytes
        if self.ratio:
            b = nbytes / self.ratio.get(start // 32768, 1.0)
        return OVERHEAD + b / RATE

    def fetch(self, now, start, nbytes):
        t0 = max(now, self.free_at)
        self.free_at = t0 + self.cost(start, nbytes)
        return self.free_at


def simulate(trace, rom, strategy, ratio):
    cache_mb = 16 if strategy == 'base' else 48
    cap = {'ra16': 16384, 'ra64': 65536, 'ra16+lz': 16384, 'ra64+lz': 65536, 'ra16pf': 16384}.get(strategy)
    pf = strategy == 'ra16pf'
    trig = {}                         # first block of a prefetched run -> (next block, file end)
    nblk = cache_mb * 1024 * 1024 // BLK
    files = nitro_files(rom) if (strategy in ('file', 'file+lz', 'preload') or cap) else []
    starts = [s for s, _ in files]
    link = Link(ratio if strategy.endswith('+lz') or strategy == 'preload' else None)
    ready = OrderedDict()             # block -> time its bytes are in the cache
    boot = 0.0
    if strategy == 'preload':
        blocks = sorted({b for _, a, l in trace for b in range(a // BLK, (a + l - 1) // BLK + 1)})
        for b in blocks:              # coalesce into large commands
            ready[b] = 0.0
        runs, cur = [], None
        for b in blocks:
            if cur and b == cur[1] and (cur[1] - cur[0]) * BLK < MAX_CMD:
                cur[1] = b + 1
            else:
                cur = [b, b + 1]; runs.append(cur)
        for s, e in runs:
            boot += link.cost(s * BLK, (e - s) * BLK)
        link.free_at = 0.0
    shift = 0.0                       # accumulated stall
    stalls = []                       # (emulated time, extra seconds)
    def prefetch(at, nb, fe):
        # one background command: the next run of the file from block nb
        end = min(fe, nb + 1 + cap // BLK)
        run = [x for x in range(nb, end) if x not in ready]
        if not run or run[0] != nb:
            return
        run = run[:next((k for k in range(1, len(run)) if run[k] != nb + k), len(run))]
        fin = link.fetch(at, nb * BLK, len(run) * BLK)
        for x in run:
            ready[x] = fin
        if nb + len(run) < fe:
            trig[nb] = (nb + len(run), fe)

    for t, a, l in trace:
        now = t + shift
        need = range(a // BLK, (a + l - 1) // BLK + 1)
        done = now
        for b in need:
            if b in ready:
                ready.move_to_end(b)
                done = max(done, ready[b])
                if pf and b in trig:
                    prefetch(now, *trig.pop(b))
                continue
            if cap:                   # one command: the block plus up to `cap` more of its file
                i = bisect.bisect_right(starts, b * BLK) - 1
                end = b + 1
                if i >= 0 and files[i][0] <= b * BLK < files[i][1]:
                    end = min((files[i][1] + BLK - 1) // BLK, b + 1 + cap // BLK)
                fin = link.fetch(now, b * BLK, (end - b) * BLK)
                for x in range(b, end):
                    if x not in ready:
                        ready[x] = fin
                done = max(done, fin)
                if pf and i >= 0 and files[i][0] <= b * BLK < files[i][1]:
                    fe = (files[i][1] + BLK - 1) // BLK
                    if end < fe:
                        prefetch(fin, end, fe)
                while len(ready) > nblk:
                    ready.popitem(last=False)
                continue
            # miss: fetch this block first
            fin = link.fetch(now, b * BLK, BLK)
            ready[b] = fin
            done = max(done, fin)
            if files:                 # then the rest of its file, in the background
                i = bisect.bisect_right(starts, b * BLK) - 1
                if i >= 0 and files[i][0] <= b * BLK < files[i][1]:
                    fe = (files[i][1] + BLK - 1) // BLK
                    nb = b + 1
                    while nb < fe:
                        chunk = min(fe - nb, MAX_CMD // BLK)
                        missing = [x for x in range(nb, nb + chunk) if x not in ready]
                        if missing:
                            fin2 = link.fetch(fin, nb * BLK, chunk * BLK)
                            for x in missing:
                                ready[x] = fin2
                        nb += chunk
            while len(ready) > nblk:
                ready.popitem(last=False)
        extra = max(0.0, done - now - T_DS)
        if extra:
            shift += extra
            stalls.append((t, extra))
    # worst 1-second window of emulated time
    worst, j, acc = 0.0, 0, 0.0
    for i, (t, e) in enumerate(stalls):
        acc += e
        while stalls[j][0] < t - 1.0:
            acc -= stalls[j][1]; j += 1
        worst = max(worst, acc)
    return shift, worst, boot


def ndz_ratio(path):
    """Per-32K-chunk ratio of a .ndz: raw bytes / stored bytes of its 4 KiB blocks."""
    data = open(path, 'rb').read()
    assert data[:4] == b'NDZ1'
    rom_size, _, blocks, index_at = struct.unpack_from('<IIII', data, 8)
    index = struct.unpack_from(f'<{blocks + 1}I', data, index_at)
    raw, stored = {}, {}
    for b in range(blocks):
        c = b // 8
        raw[c] = raw.get(c, 0) + min(BLK, rom_size - b * BLK)
        stored[c] = stored.get(c, 0) + index[b + 1] - index[b]
    return {c: raw[c] / stored[c] for c in raw}


def main():
    args = sys.argv[1:]
    ndz_dir = None
    if args[:1] == ['--ndz']:
        ndz_dir, args = args[1], args[2:]
    print(f"link: {OVERHEAD*1e3:.1f} ms/command + {RATE/1e6:.2f} MB/s, commands <= {MAX_CMD//1024} KiB, {BLK//1024} KiB blocks")
    print("per game: total extra load time over the session / worst 1-s window (s of extra time per s of DS time)\n")
    strategies = ['base', 'file', 'ra16', 'ra16pf', 'ra64', 'ra16+lz', 'ra64+lz', 'preload']
    print(f"{'game':15s} {'session':>8s} " + " ".join(f"{s:>16s}" for s in strategies))
    for arg in args:
        game, path = arg.split('=', 1)
        rom = open(path, 'rb').read()
        tdir = game if '/' in game else f'build/census/carttrace/{game}'   # GAME may be a census directory
        game = game.rstrip('/').split('/')[-1]
        trace = [(int(r['sys_cycle']) / SYS, int(r['addr']), int(r['len']))
                 for r in csv.DictReader(open(f'{tdir}/cart_trace.csv'))]
        chunks = {a // 32768 for _, a, _ in trace}
        files = nitro_files(rom)
        for s, e in files:            # ratio for every chunk read-ahead may fetch
            for c in range(s // 32768, (e + 32767) // 32768):
                chunks.add(c)
        ratio = ndz_ratio(f'{ndz_dir}/{game}.ndz') if ndz_dir else {}
        for c in chunks if not ndz_dir else ():
            d = rom[c * 32768:(c + 1) * 32768]
            ratio[c] = len(d) / max(1, len(zlib.compress(d, 1))) if d else 1.0
        cells = []
        boot = 0.0
        for s in strategies:
            total, worst, b = simulate(trace, rom, s, ratio)
            boot = b or boot
            cells.append(f"{total:6.1f}s / {worst:4.2f}")
        dur = (trace[-1][0] - trace[0][0]) / 60
        print(f"{game:15s} {dur:6.1f}m " + " ".join(f"{c:>16s}" for c in cells) + f"   (preload boot {boot:.1f} s)")


if __name__ == '__main__':
    main()
