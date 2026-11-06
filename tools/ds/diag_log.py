#!/usr/bin/env python3
"""The NDSDiag log (Saves/nds/common/<game>.ndg, docs/diag.md) as tables.

    diag_log.py [LOG.ndg] [--frames] [--seconds] [--compare OTHER.ndg] [--csv OUT.csv]

Without LOG: every .ndg on the mounted Pocket SD card (/run/media/$USER/*/Saves/nds/common/) is copied to
build/diag/<game>-<date>.ndg in this repository and its report written beside it (<game>-<date>.txt, with
--frames and the CSV), so a test needs no setup beyond inserting the card.

Prints the header, the per-second table (the whole session, from the second records), a summary of the
per-frame records (the last ~30 s) with the means and worst frames of each counter, the latency histograms
and the late-line positions. --frames also prints every frame; --csv writes the per-frame table.
--compare puts a second log beside it (hardware against the Pocket model's log of the same scene: the
Pocket model writes the same file through the quit read-back, so the numbers compare one for one).

The accumulators are free-running 32-bit counts sampled at the same scanner offset every frame: a frame's
value is the difference between consecutive records (modulo 2^32).
"""
import argparse
import struct
import sys

# docs/diag.md: the events (index -> name), values, histograms
EVENTS = ['r_stream', 'r_edge', 'r_pixel', 'r_final', 'r_late', 'r_restart', 'r_tmiss', 'r_pmiss', 'r_px', 'r_treq',
          'r_ring_under', 'g_busy', 'g_stall_full', 'g_stall_bp', 'g_store_hold', 'g_swap', 'g_exec', 'g_fetch_wait',
          'g_load_wait', 'a9_retire', 'a9_halt', 'a9_wait_main', 'a9_dma', 'a9_ifill', 'a9_dfill', 'a9_wait_gx',
          'a9_wait_other', 'a7_retire', 'a7_halt', 'd_late', 'd_bg_stall', 'd_obj_stall', 'd_vreq', 'd_cap_line',
          'i_vm_blk', 'i_ps_req', 'i_ps_wait', 'i_rg_wwait', 'i_rg_rwait', 'i_rg_undrained',
          'k_cart_wait', 'k_cart_cmds'] + \
         [f'i_sd_wait{p}' for p in (0, 1, 2, 3, 4, 6)] + ['i_ref_late']
# logs of builds before the cartridge counters (NDSDiag #638 and earlier: 47 events) lack events 40-41
EVENTS47 = [e for e in EVENTS if not e.startswith('k_cart')]
# builds with the 3D ring's underrun causes (53 events): 42-45 before the clk_mem counters
RING_EV = ['r_ring_rd', 'r_ring_unsafe', 'r_ring_skip', 'r_nx2_hit']
EVENTS53 = EVENTS[:42] + RING_EV + EVENTS[42:]


def event_names(ne):
    return EVENTS47 if ne == 47 else EVENTS53 if ne == 53 else EVENTS


# the header's CONFIG word (core_top_ds g_diag CFG): bit -> option
CONFIG = ['GPU3D', 'SOUND', 'RING', 'NDS_DEBUG', 'ARM7_CACHE', 'CPU_FAST', 'G3D_AA', 'G3D_TOON', 'G3D_FOG',
          'G3D_ATEST', 'G3D_EDGE', 'G3D_SHADOW', 'G3D_LOWER', 'G3D_TCFAST', 'G3D_TCMIF2', None, None, 'WIFI',
          'G2D_MOSAIC', 'G3D_TCV2', 'G3D_NXB', 'LEAN']   # LEAN: the lean diag (CPU, cartridge, clk_mem events 0)


def config_str(c):
    on = [n for i, n in enumerate(CONFIG) if n and c >> i & 1]
    return ' '.join(on) + f' TCWAYS={c >> 15 & 3} TXD={c >> 24 & 15} TL={c >> 28 & 15}'
VALUES = [('r_first_late', 'r_min_lead'), ('g_polys', 'g_verts'), ('g_used_max', 'i_wfifo_max'),
          ('d_bgbusy_max', 'i_underruns'), ('ds_frame', None), (None, None)]
HISTS = ['texel block (log2)', 'VRAM block (16-43 by 2)', 'PSRAM main RAM (4 clk)', '2D VRAM (0-47 by 4, 48/64/128/256)']
LINES = ['late 3D lines', 'late 2D lines']
HDR, HIST, LHIST, SECR, FRR = 0x0, 0x40, 0x100, 0x400, 0x4400


def bin_label(h, b):
    if h == 0:
        return '0' if b == 0 else f'{1 << (b - 1)}-{(1 << b) - 1}' if b < 15 else f'{1 << 14}+'
    if h == 2:
        return f'{4 * b}-{4 * b + 3}' if b < 15 else '60+'
    if h == 1:
        return '<16' if b == 0 else '44+' if b == 15 else f'{16 + 2 * (b - 1)}-{17 + 2 * (b - 1)}'
    return f'{4 * b}-{4 * b + 3}' if b < 12 else ['48-63', '64-127', '128-255', '256+'][b - 12]


class Log:
    def __init__(self, path):
        d = open(path, 'rb').read()
        w = list(struct.unpack('<%dI' % (len(d) // 4), d[:len(d) // 4 * 4]))
        # the Pocket's nonvolatile read-back may lag by a word: find the magic
        lag = next((k for k in range(4) if k < len(w) and w[k] == 0x3147444E), None)
        if lag is None:
            sys.exit(f'{path}: no NDG1 magic ({" ".join("%08x" % x for x in w[:4])})')
        w = w[lag:] + [0] * lag
        self.w = w
        self.ne, self.nv, self.nh, self.nl = (w[2] >> 24) & 255, (w[2] >> 16) & 255, (w[2] >> 8) & 255, w[2] & 255
        self.config, self.frames, self.seconds = w[3], w[4], w[5]
        self.fslots, self.sslots, self.lost = w[6], w[7], w[10]
        self.hist = [w[HIST + 16 * h: HIST + 16 * h + 16] for h in range(self.nh)]
        self.lines = [w[LHIST + 32 * l: LHIST + 32 * l + 32] for l in range(self.nl)]
        self.frame_recs = self.records(FRR, self.fslots, extend=True)
        self.sec_recs = self.records(SECR, self.sslots)

    def records(self, base, n, extend=False):
        """the ring's records in frame order. The SDRAM is not cleared at power-up, so a slot may hold
        another session's record: up to the header's frame count only this session's slots qualify; past it
        (the header is rewritten once a second), frame F is taken from its slot (F - 1 mod n) only while each
        next record continues the last: frame number F and the DS-frame count (value 4) 0-3 frames on"""
        recs = {}
        for s in range(n):
            r = self.w[base + 64 * s: base + 64 * s + 64]
            if len(r) == 64 and 0 < r[0] <= self.frames:
                recs[r[0]] = r
        if extend and recs:
            dsf = 1 + self.ne + 4
            f = self.frames + 1
            while True:
                r = self.w[base + 64 * ((f - 1) % n): base + 64 * ((f - 1) % n) + 64]
                last = recs[max(recs)]
                if len(r) < 64 or r[0] != f or not 0 <= r[dsf] - last[dsf] <= 3:
                    break
                recs[f] = r
                f += 1
        return [recs[k] for k in sorted(recs)]

    @staticmethod
    def deltas(recs, ne, nv):
        """per interval: {event: count} and {value: v}, for consecutive records"""
        out = []
        for a, b in zip(recs, recs[1:]):
            row = {'frame': b[0], 'span': b[0] - a[0]}
            for i in range(ne):
                names = event_names(ne)
                row[names[i] if i < len(names) else f'ev{i}'] = (b[1 + i] - a[1 + i]) & 0xFFFFFFFF
            for j in range(nv):
                v = b[1 + ne + j]
                hi, lo = VALUES[j] if j < len(VALUES) else (f'v{j}', None)
                if lo is None:
                    if hi: row[hi] = v
                else:
                    row[hi] = v >> 16
                    row[lo] = v & 0xFFFF if lo != 'r_min_lead' else ((v & 0xFFFF) ^ 0x8000) - 0x8000
            out.append(row)
        return out


def table(rows, cols, title):
    print(f'\n{title}')
    print('  ' + ' '.join(f'{c:>12s}' for c in cols))
    for r in rows:
        print('  ' + ' '.join(f'{r.get(c, ""):>12}' for c in cols))


def summary(rows, title, other=None):
    print(f'\n{title} ({len(rows)} frames)')
    keys = [k for k in rows[0] if k not in ('frame', 'span')] if rows else []
    print(f'  {"counter":16s} {"mean":>12s} {"min":>10s} {"max":>10s}' + (f' {"other mean":>12s} {"ratio":>7s}' if other else ''))
    for k in keys:
        vs = [r[k] / r['span'] if k in EVENTS else r[k] for r in rows]
        m = sum(vs) / len(vs)
        line = f'  {k:16s} {m:12.1f} {min(vs):10.0f} {max(vs):10.0f}'
        if other:
            ov = [r[k] / r['span'] if k in EVENTS else r[k] for r in other if k in r]
            om = sum(ov) / len(ov) if ov else 0
            line += f' {om:12.1f} {(m / om if om else 0):7.2f}'
        print(line)


def from_card():
    """copy every .ndg on the mounted Pocket SD card into build/diag/ and write each report beside it"""
    import contextlib, getpass, glob, os, shutil, time
    from pathlib import Path
    logs = glob.glob(f'/run/media/{getpass.getuser()}/*/Saves/nds/common/*.ndg') + \
        glob.glob(f'/media/{getpass.getuser()}/*/Saves/nds/common/*.ndg')
    if not logs:
        sys.exit('no Saves/nds/common/*.ndg on a mounted SD card (/run/media/$USER/*): insert the Pocket\'s card, '
                 'or give the .ndg')
    out = Path(__file__).resolve().parents[2] / 'build/diag'
    out.mkdir(parents=True, exist_ok=True)
    for src in logs:
        stamp = time.strftime('%Y%m%d-%H%M', time.localtime(os.path.getmtime(src)))
        dst = out / f'{Path(src).stem}-{stamp}.ndg'
        shutil.copyfile(src, dst)
        rpt = dst.with_suffix('.txt')
        with open(rpt, 'w') as f, contextlib.redirect_stdout(f):
            report(argparse.Namespace(log=str(dst), frames=True, seconds=True, compare=None,
                                      csv=str(dst.with_suffix('.csv'))))
        print(f'{src} -> {dst}, report {rpt}')
        report(argparse.Namespace(log=str(dst), frames=False, seconds=False, compare=None, csv=None))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('log', nargs='?')
    ap.add_argument('--frames', action='store_true')
    ap.add_argument('--seconds', action='store_true')
    ap.add_argument('--compare')
    ap.add_argument('--csv')
    a = ap.parse_args()
    if not a.log:
        from_card()
    else:
        report(a)


def play(rows):
    """the frames the DS ran (a Pocket-model scene's first records are before its import released: all zero)"""
    # (a build without the CPU events, the lean diag: every a9_retire is 0, keep all)
    if not any(r.get('a9_retire', 0) for r in rows):
        return rows
    return [r for r in rows if r.get('a9_retire', 1) > 0]


def rates(rows):
    """per-unit figures that compare across scenes of different weight"""
    n = len(rows)
    tot = {k: sum(r.get(k, 0) for r in rows) for k in rows[0]} if rows else {}
    def per(a, b):
        if b == 'span':                     # a share of the DS frame: 1,120,380 clk_sys (67.028 MHz / 59.83 Hz)
            return tot.get(a, 0) / (tot['span'] * 1120380) if tot.get('span') else 0.0
        return tot.get(a, 0) / tot[b] if tot.get(b) else 0.0
    rast = sum(tot.get(k, 0) for k in ('r_stream', 'r_edge', 'r_pixel'))
    return [('game frames/s (3D swaps)', 60 * tot.get('g_swap', 0) / n if n else 0),
            ('PSRAM wait per request (clk_sys)', per('i_ps_wait', 'i_ps_req')),
            ('raster clocks per pixel', rast / tot['r_px'] if tot.get('r_px') else 0.0),
            ('ARM9 retired per frame', tot.get('a9_retire', 0) / n if n else 0),
            ('ARM9 main-RAM wait, share of the frame', per('a9_wait_main', 'span')),
            ('ARM9 DMA, share of the frame', per('a9_dma', 'span')),
            ('ARM9 GX wait, share of the frame', per('a9_wait_gx', 'span')),
            ('ARM9 halted, share of the frame', per('a9_halt', 'span')),
            ('cartridge wait, share of the frame', per('k_cart_wait', 'span'))]


def report(a):
    lg = Log(a.log)
    print(f'{a.log}: NDG1, {lg.ne} events, {lg.nv} values, {lg.nh} + {lg.nl} histograms, config {lg.config:08x} ({config_str(lg.config)})')
    print(f'  {lg.frames} frames recorded ({len(lg.frame_recs)} kept), {lg.seconds} seconds ({len(lg.sec_recs)} kept), '
          f'histogram updates lost {lg.lost}')
    fr = play(Log.deltas(lg.frame_recs, lg.ne, lg.nv))
    sr = Log.deltas(lg.sec_recs, lg.ne, lg.nv)
    other = Log(a.compare) if a.compare else None
    ofr = play(Log.deltas(other.frame_recs, other.ne, other.nv)) if other else None
    key = ['frame', 'g_swap', 'r_late', 'r_restart', 'd_late', 'a9_retire', 'a9_wait_main', 'r_tmiss', 'g_stall_bp',
           'r_first_late', 'i_underruns'] + (['r_ring_under'] + RING_EV if lg.ne == 53 else [])
    if a.seconds or not a.frames:
        table(sr, key, 'per second (whole session; counts per second)')
    if a.frames:
        table(fr, key, 'per frame (the last ~30 s)')
    if fr:
        summary(fr, 'per-frame counters' + (f' (beside {a.compare})' if other else ''), ofr)
        print('\nrates' + (' (this log / the other)' if other else ''))
        ra = rates(fr)
        rb = rates(ofr) if ofr else None
        for i, (name, v) in enumerate(ra):
            print(f'  {name:40s} {v:12.2f}' + (f' {rb[i][1]:12.2f}' if rb else ''))
    for h in range(lg.nh):
        tot = sum(lg.hist[h])
        print(f'\nlatency: {HISTS[h] if h < len(HISTS) else h} ({tot} samples)')
        for b, n in enumerate(lg.hist[h]):
            if n:
                extra = ''
                if other:
                    on = other.hist[h][b]
                    extra = f'   other {on:10d} {100 * on / max(1, sum(other.hist[h])):5.1f}%'
                print(f'  {bin_label(h, b):>12s} {n:10d} {100 * n / max(1, tot):5.1f}%{extra}')
    for l in range(lg.nl):
        tot = sum(lg.lines[l])
        print(f'\n{LINES[l] if l < len(LINES) else l} by line ({tot} total)')
        for b, n in enumerate(lg.lines[l]):
            if n:
                print(f'  lines {8 * b:3d}-{8 * b + 7 if b < 31 else 262:3d} {n:10d}')
    if a.csv and fr:
        cols = list(fr[0])
        with open(a.csv, 'w') as f:
            f.write(','.join(cols) + '\n')
            for r in fr:
                f.write(','.join(str(r[c]) for c in cols) + '\n')


if __name__ == '__main__':
    main()
