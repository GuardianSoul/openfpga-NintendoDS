#!/usr/bin/env python3
"""The Pocket ROM cache's policy (sw/scpu/cache.c) over census cartridge traces, per run length.

    cart_policy.py ROM TRACE [ROM TRACE ...]      (TRACE: census --cart-trace 1's cart_trace.csv)

A cold cache, no evictions. A demand miss on block b fetches b and up to dra more blocks of its file
(the .ndt read-ahead field, at most 4), stopping at a cached block, and waits for that command; if the
file goes on, a background prefetch of the next run (1 + up to pfn blocks) follows, and the client
reaching that run starts the one after it. A demand miss waits for the prefetch in flight. Link: one
command at a time, 0.9 ms + bytes / rate; 'probe' is docs/sd-probe.md's 1.75 MB/s, 'loaded' 1.2 MB/s
(phase1-foundation.md's pass B: 7.7 ms per 8 KiB command). The trace's own times are the real card's, so
every wait shifts the rest. Columns: total stall (s) / worst 60 frames (ms) / worst frame (ms).
docs/memory-replay.md, "Read-ahead of one block".
"""
import struct, sys
SYS = 33_513_982; BLK = 4096
MODELS = {'probe': (0.9e-3, 1.75e6), 'loaded': (0.9e-3, 1.2e6)}
def load(romp, tracep):
    rom = open(romp, 'rb').read(); n = (len(rom) + BLK - 1) // BLK
    fat_off, fat_len = struct.unpack_from('<II', rom, 0x48)
    spans = []
    for i in range(fat_len // 8):
        s, e = struct.unpack_from('<II', rom, fat_off + 8 * i)
        if e > s: spans.append((s, e))
    for off in (0x20, 0x30):
        s = struct.unpack_from('<I', rom, off)[0]; spans.append((s, s + struct.unpack_from('<I', rom, off + 12)[0]))
    fnt_off = struct.unpack_from('<I', rom, 0x40)[0]
    streams = set()
    def walk(d):
        sub, fid = struct.unpack_from('<IH', rom, fnt_off + 8 * (d & 0xFFF))
        o = fnt_off + sub
        while True:
            t = rom[o]; o += 1
            if t == 0: break
            nm = rom[o:o + (t & 0x7F)].decode('latin1'); o += t & 0x7F
            if t & 0x80:
                walk(struct.unpack_from('<H', rom, o)[0]); o += 2
            else:
                if nm.lower().endswith(('.mods', '.vx')): streams.add(fid)
                fid += 1
    walk(0xF000)
    ra = [0] * n; st = [False] * n
    for i in streams:
        s, e = struct.unpack_from('<II', rom, fat_off + 8 * i)
        for b in range(s // BLK, -(-e // BLK)): st[b] = True
    for s, e in spans:
        sb, se = -(-s // BLK), -(-e // BLK)
        for b in range(sb, se): ra[b] = min(se - 1 - b, 4)
    tr = []
    for l in open(tracep):
        f = l.strip().split(',')
        if f[0] == 'frame': continue
        if int(f[3]) + int(f[4]) <= n * BLK: tr.append((int(f[0]), int(f[2]), int(f[3]), int(f[4])))   # (not past the ROM)
    return n, (ra, st), tr

def sim(n, rs, tr, dra, pfn, model, stream=False):
    ra, st = rs
    """dra: demand read-ahead cap (4 = today's), pfn: background prefetch run cap (0 = none; 4 = today's 5-block runs)"""
    ovh, rate = MODELS[model]
    cost = lambda k: ovh + k * BLK / rate
    cached = set(); link = 0.0; pf = None; pf_due = None; trig = None
    ramp = pfn < 0; pcap = 0                   # ramp: the next prefetch run's cap (blocks past the first)
    shift = 0.0; t0 = tr[0][1] / SYS; byfr = {}; cmds = 0
    def mkrun(b, cap):
        if stream and st[b]: cap = 4
        run = [b]; ext = min(ra[b], cap, n - 1 - b)
        while len(run) <= ext and b + len(run) not in cached: run.append(b + len(run))
        return run
    for fr, cyc, ad, ln in tr:
        now = cyc / SYS - t0 + shift
        if pf and pf[2] <= now: cached.update(pf[1]); pf = None
        for b in range(ad // BLK, (ad + ln - 1) // BLK + 1):
            if trig and b == trig[0]:
                if trig[2]: pf_due = trig[1]
                trig = None
                if ramp: pcap = min(4, 2 * pcap + 1)
            if b in cached: continue
            if pf and b in pf[1]: wait = pf[2] - now
            else:
                if pf: now = max(now, pf[2]); cached.update(pf[1]); pf = None
                if b in cached: continue
                run = mkrun(b, dra); fin = max(now, link) + cost(len(run)); link = fin; cmds += 1
                cached.update(run); wait = fin - now
                last = run[-1]
                if ramp: pcap = 0
                if (pfn or (stream and st[last])) and ra[last] != 0 and last + 1 < n: pf_due = last + 1
            wait = max(0, wait); shift += wait; now += wait; byfr[fr] = byfr.get(fr, 0) + wait
            if pf and pf[2] <= now: cached.update(pf[1]); pf = None
        if pf_due is not None and pf is None:
            b = pf_due; pf_due = None
            if b not in cached:
                run = mkrun(b, pcap if ramp else pfn); fin = max(now, link) + cost(len(run)); link = fin; cmds += 1
                pf = (b, run, fin); trig = (b, run[-1] + 1, ra[run[-1]] != 0)
    w = max((sum(v for f, v in byfr.items() if s <= f < s + 60) for s in byfr), default=0)
    return shift, w, max(byfr.values(), default=0), cmds

def sim_streams(n, rs, tr, model, ns=4):
    """sw/scpu/cache.c's streams (docs/memory-replay.md, "Streams"): ns entries, each with its next block, the first
    block of its last prefetched run (the trigger) and its ramp. A demand miss fetches its block alone; on a stream's
    next block it continues that stream (ramping), otherwise it starts one in the least recently used entry. The
    client reaching a block in a stream's last prefetched run (the cache's new-block event) makes the stream's next
    run due; due runs go out one at a time, in entry order, after the command in flight."""
    ra, st = rs
    ovh, rate = MODELS[model]
    cost = lambda k: ovh + k * BLK / rate
    cached = set(); link = 0.0; shift = 0.0; t0 = tr[0][1] / SYS; byfr = {}; cmds = 0; now = 0.0; tick = 0
    S = [dict(next=None, trig=None, ahead=0, due=False, used=-1) for _ in range(ns)]
    fly = None                                  # (run, finish)
    ramp = lambda a: min(1, 2 * a + 1)          # sw/scpu/cache.c PF_MAX
    def land(t):
        nonlocal fly
        if fly and fly[1] <= t: cached.update(fly[0]); fly = None
    def issue(t):
        nonlocal fly, link, cmds
        if fly: return
        for s in S:
            if not s['due']: continue
            s['due'] = False
            b = s['next']
            for i in range(8):                  # past cached blocks
                if b not in cached: break
                if ra[b] == 0 or b + 1 >= n: b = None; break
                if i == 7: break
                b += 1
            if b is None: s['next'] = s['trig'] = None; continue
            if b in cached: s['trig'] = b; s['next'] = b + 1; continue
            run = [b]
            while len(run) <= min(ra[b], s['ahead'], n - 1 - b) and b + len(run) not in cached: run.append(b + len(run))
            fin = max(t, link) + cost(len(run)); link = fin; cmds += 1; fly = (run, fin)
            s['trig'] = b; s['next'] = run[-1] + 1 if ra[run[-1]] and run[-1] + 1 < n else None
            return
    for fr, cyc, ad, ln in tr:
        now = cyc / SYS - t0 + shift
        land(now); issue(now)
        for b in range(ad // BLK, (ad + ln - 1) // BLK + 1):
            if b in cached:
                tick += 1
                for s in S:
                    if s['trig'] is not None and s['next'] is not None and s['trig'] <= b < s['next']:
                        s['trig'] = None; s['used'] = tick; s['ahead'] = ramp(s['ahead']); s['due'] = True
                issue(now)
                continue
            if fly and b in fly[0]: wait = fly[1] - now
            else:
                if fly: now = max(now, fly[1]); land(now)
                tick += 1
                f = next((s for s in S if s['next'] == b), None)
                if f: f['ahead'] = ramp(f['ahead'])
                else: f = min(S, key=lambda s: s['used']); f['ahead'] = 0
                fin = max(now, link) + cost(1); link = fin; cmds += 1
                cached.add(b); wait = fin - now
                f['used'] = tick; f['trig'] = None
                f['next'] = b + 1 if ra[b] and b + 1 < n else None
                f['due'] = f['next'] is not None
            wait = max(0, wait); shift += wait; now += wait; byfr[fr] = byfr.get(fr, 0) + wait
            land(now); issue(now)
    w = max((sum(v for f, v in byfr.items() if s <= f < s + 60) for s in byfr), default=0)
    return shift, w, max(byfr.values(), default=0), cmds

POL = [('NDSPlay18 on the Pocket', 0, -1, 'none'), ('ra0+ramp', 0, -1), ('streams (4)', 'streams')]
args = sys.argv[1:]
for model in MODELS:
    print(f'## link {model}: total stall s / worst 60-frame window ms / worst frame ms')
    print('%-22s' % 'trace' + ''.join('%-24s' % p[0] for p in POL))
    for i in range(0, len(args), 2):
        n, ra, tr = load(args[i], args[i + 1])
        name = args[i + 1].split('/')[-2]
        row = '%-22s' % name
        for pp in POL:
            if pp[1] == 'streams': t, w, f, c = sim_streams(n, ra, tr, model)
            elif pp[3:] == ('none',):           # no read-ahead table: the core never loaded the .ndt (until 08369e51)
                t, w, f, c = sim(n, ([0] * n, [False] * n), tr, pp[1], pp[2], model)
            else: t, w, f, c = sim(n, ra, tr, pp[1], pp[2], model)
            row += '%-24s' % f'{t:.2f} / {w*1e3:.0f} / {f*1e3:.0f}'
        print(row)
