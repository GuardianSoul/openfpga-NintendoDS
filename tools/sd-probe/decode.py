#!/usr/bin/env python3
"""Decode an SD probe log (rtl/probe/sd_probe.sv, docs/sd-probe.md).

    decode.py sd-probe-log.bin [--rom game.nds] [--csv records.csv]

Version 2 logs start with the Pocket's start-up load of the slot: bytes,
time from first to last word, MB/s, the largest gap between writes and the
gaps over 1 ms. Then it prints per-case statistics of the APF
target_dataslot_read commands: total
command time (raise to done), the host's acknowledge, first data word, the
data transfer itself, and the throughput. --rom checks every record's data
sum (and the start-up load's) against the ROM file that was in the slot. The
Pocket saves the log big-endian and one word late; the header is found and
realigned first.
"""
import argparse
import csv
import math
from pathlib import Path
import struct
import sys

MAGIC = 0x53445042  # "SDPB"
CASE_NAMES = ['4 B random', '512 B random', '512 B sequential', '32 KiB random',
              '32 KiB sequential', '256 KiB random', '256 KiB sequential']
BUDGET_MS = 3.5   # docs/memory-replay.md: a 32 KiB fill must cost well under this


HEADER1 = {(v << 24) | (8 << 16) | 7 for v in (1, 2)}   # {version, 8 words per record, 7 cases}


def words_of(raw):
    """The Pocket's save of the bridge window is big-endian, and the one-word
    read lag drops the first word (the magic) on hardware (first log,
    2026-10-23). Simulated logs were little-endian with a leading junk word.
    Accept both: find the magic, or header word 1 at the start."""
    n = len(raw) // 4
    for order in ('>', '<'):
        words = list(struct.unpack(f'{order}{n}I', raw[:n * 4]))
        for shift in range(4):
            if shift < len(words) and words[shift] == MAGIC:
                return words[shift:], f'{order}{shift}'
        if words and words[0] in HEADER1:
            return [MAGIC] + words, f'{order}-1'
    sys.exit('no SDPB header in the first four words (either byte order): not an SD probe log')


def load(path):
    words, shift = words_of(Path(path).read_bytes())
    hdr = words[:16]
    version, per_record, ncase = words[1] >> 24, (words[1] >> 16) & 0xff, words[1] & 0xffff
    if version not in (1, 2) or per_record != 8:
        sys.exit(f'unknown log format: version {version}, {per_record} words per record')
    info = dict(shift=shift, records=hdr[2], rom_size=hdr[3], clock=hdr[4], done=hdr[5] >> 31,
                stuck=(hdr[5] >> 30) & 1, fail=(hdr[5] >> 24) & 0xf, current_case=hdr[5] & 0xff,
                per_case=hdr[6], run_s=hdr[7] * 256 / hdr[4] if hdr[4] else 0, mask=hdr[15],
                cases=[dict(seq=w >> 31, align=1 << ((w >> 24) & 0x1f), length=w & 0xffffff)
                       for w in hdr[8:8 + ncase]])
    base = 16 if version == 1 else 32
    info['load'] = None
    if version >= 2:
        w = words[16:32]
        info['load'] = dict(words=w[0], sum=w[1], first=w[2] | w[3] << 32, last=w[4] | w[5] << 32,
                            gap=w[6], gap_at=w[7], long=w[8], long_clocks=w[9] * 256,
                            done=w[10] | w[11] << 32, jumps=w[12], last_addr=w[13], base=w[14], gap_long=w[15])
    n = min(info['records'], (len(words) - base) // 8)
    recs = []
    for r in range(n):
        w = words[base + 8 * r:base + 8 + 8 * r]
        if w[0] >> 28 != 0xA:
            sys.exit(f'record {r}: bad tag {w[0]:08x}')
        c = (w[0] >> 24) & 0xf
        recs.append(dict(record=r, case=c, index=w[0] & 0xffff, error=(w[0] >> 21) & 7,
                         acked=(w[0] >> 20) & 1, timed_out=(w[0] >> 19) & 1, offset=w[1],
                         length=info['cases'][c]['length'], t_ack=w[2], t_first=w[3], t_last=w[4],
                         t_done=w[5], words=w[6], sum=w[7]))
    return info, recs


def stats(values):
    """min, median, p99 (nearest rank), max, mean"""
    v = sorted(values)
    if not v:
        return None
    mid = len(v) // 2
    median = v[mid] if len(v) % 2 else (v[mid - 1] + v[mid]) / 2
    return v[0], median, v[max(0, math.ceil(0.99 * len(v)) - 1)], v[-1], sum(v) / len(v)


def check_rom(recs, rom_path):
    """Count records whose word sum matches the ROM, read as little- or big-endian words."""
    rom = Path(rom_path).read_bytes()
    ok = {'<': 0, '>': 0}
    bad = []
    for r in recs:
        if r['error']:
            continue
        chunk = rom[r['offset']:r['offset'] + r['length']]
        chunk += b'\0' * (-len(chunk) % 4)
        hit = False
        for order in ok:
            s = sum(struct.unpack(f'{order}{len(chunk) // 4}I', chunk)) & 0xffffffff
            if s == r['sum'] and r['words'] == len(chunk) // 4:
                ok[order] += 1
                hit = True
        if not hit:
            bad.append(r)
    return ok, bad


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('log', type=Path)
    ap.add_argument('--rom', type=Path, help='the file that was loaded in the ROM slot')
    ap.add_argument('--csv', type=Path, help='write every record as CSV')
    args = ap.parse_args()
    info, recs = load(args.log)
    load_bad = False
    clk = info['clock']
    us = lambda cycles: cycles * 1e6 / clk

    print(f"SD probe log {args.log.name}: {len(recs)} of {info['per_case'] * len(info['cases'])} records, "
          f"ROM slot {info['rom_size']:,} bytes, clock {clk / 1e6:.2f} MHz, run {info['run_s']:.2f} s"
          + f", saved {'big' if info['shift'][0] == '>' else 'little'}-endian"
          + {'-1': ', magic dropped by the read lag', '0': ''}.get(info['shift'][1:], f", realigned by {info['shift'][1:]} word(s)"))
    if info['fail']:
        print(f"PROBE FAILED: code {info['fail']} "
              f"({ {1: 'ROM slot not in the APF data table', 2: 'ROM file under 512 KiB'}.get(info['fail'], '?') })")
    if not info['done']:
        print(f"not finished: stopped in case {info['current_case']} (quit before the screen turned green?)")
    if info['stuck']:
        print('some command took over 2 s (orange screen)')

    ld = info['load']
    if ld is not None:
        print()
        if not ld['words']:
            print('start-up load: no words arrived (red first box): the slot was not loaded at start-up')
        else:
            span = (ld['last'] - ld['first']) / clk
            nbytes = ld['words'] * 4
            print(f"start-up load: {nbytes:,} bytes in {span:.3f} s from first to last word "
                  f"= {nbytes / span / 1e6 if span else 0:.2f} MB/s (first word {ld['first'] / clk:.3f} s after "
                  f"power-up, all slots complete {(ld['done'] - ld['last']) / clk * 1000:.1f} ms after the last)")
            print(f"  largest gap between writes {us(ld['gap']) / 1000:.3f} ms, before byte {ld['gap_at'] * 4:,}; "
                  f"{ld['long']} gaps over {us(ld['gap_long']) / 1000:g} ms, {ld['long_clocks'] / clk:.3f} s in all; "
                  f"{ld['jumps']} writes not at the next address; last address {ld['last_addr']:#x}")
            if ld['long_clocks'] and span:
                busy = span - ld['long_clocks'] / clk
                print(f"  outside those gaps: {nbytes / busy / 1e6:.2f} MB/s")
    print()
    print(f"{'case':<20} {'n':>4} {'err':>4}  {'total ms: min / median / p99 / max':<36} "
          f"{'ack us med':>10} {'1st word us med':>15} {'xfer MB/s med':>13} {'MB/s med':>9}")
    medians = {}
    for c, case in enumerate(info['cases']):
        rs = [r for r in recs if r['case'] == c]
        good = [r for r in rs if not r['error']]
        if not rs:
            continue
        total = stats([us(r['t_done']) / 1000 for r in good])
        ack = stats([us(r['t_ack']) for r in good if r['acked']])
        first = stats([us(r['t_first']) for r in good if r['words']])
        span = [r for r in good if r['words'] > 1 and r['t_last'] > r['t_first']]
        xfer = stats([(r['words'] - 1) * 4 / us(r['t_last'] - r['t_first']) for r in span])
        rate = stats([case['length'] / us(r['t_done']) for r in good if r['t_done']])
        name = CASE_NAMES[c] if c < len(CASE_NAMES) else f'case {c}'
        tot = f"{total[0]:7.3f} / {total[1]:7.3f} / {total[2]:7.3f} / {total[3]:8.3f}" if total else '-'
        print(f"{name:<20} {len(rs):>4} {len(rs) - len(good):>4}  {tot:<36} "
              f"{ack[1] if ack else 0:>10.1f} {first[1] if first else 0:>15.1f} "
              f"{xfer[1] if xfer else 0:>13.2f} {rate[1] if rate else 0:>9.2f}")
        if total:
            medians[c] = total[1]
        errs = sorted({r['error'] for r in rs if r['error']})
        if errs:
            print(f"{'':<20} APF error codes: {errs}")

    # total time = overhead + length / bandwidth, least squares over the case medians
    seq = [(info['cases'][c]['length'], m) for c, m in medians.items() if info['cases'][c]['seq']]
    rnd = [(info['cases'][c]['length'], m) for c, m in medians.items() if not info['cases'][c]['seq']]
    print()
    for label, pts in (('sequential', seq), ('random', rnd)):
        if len(pts) >= 2:
            mx = sum(p[0] for p in pts) / len(pts)
            my = sum(p[1] for p in pts) / len(pts)
            sxx = sum((p[0] - mx) ** 2 for p in pts)
            slope = sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx if sxx else 0
            icpt = my - slope * mx
            bw = 1 / slope / 1000 if slope > 0 else float('inf')
            print(f"fit, {label} medians: {icpt:.3f} ms per command + {bw:.2f} MB/s")
    if 3 in medians:
        r32 = stats([us(r['t_done']) / 1000 for r in recs if r['case'] == 3 and not r['error']])
        verdict = 'within' if r32[2] < BUDGET_MS else 'OVER'
        print(f"32 KiB random fill: median {r32[1]:.3f} ms, p99 {r32[2]:.3f} ms, max {r32[3]:.3f} ms "
              f"-> p99 {verdict} the ~{BUDGET_MS} ms budget (docs/memory-replay.md)")

    if args.rom and ld is not None and ld['words']:
        data = args.rom.read_bytes()[:ld['words'] * 4]
        data += b'\0' * (-len(data) % 4)
        match = [o for o in '<>' if sum(struct.unpack(f'{o}{len(data) // 4}I', data)) & 0xffffffff == ld['sum']]
        whole = ld['words'] * 4 >= args.rom.stat().st_size
        print(f"start-up load check against {args.rom.name}: "
              + (f"sum matches ({'little' if match[0] == '<' else 'big'}-endian words)" if match else 'SUM MISMATCH')
              + ('' if whole else f", but only {ld['words'] * 4:,} of {args.rom.stat().st_size:,} bytes arrived"))
        if not match or not whole:
            load_bad = True
    if args.rom:
        ok, bad = check_rom(recs, args.rom)
        n = sum(1 for r in recs if not r['error'])
        order = max(ok, key=ok.get)
        print(f"data check against {args.rom.name}: {ok[order]} of {n} reads match "
              f"({'little' if order == '<' else 'big'}-endian words), {len(bad)} mismatched")
        for r in bad[:10]:
            print(f"  record {r['record']} case {r['case']} offset {r['offset']:#x}: "
                  f"{r['words']} words, sum {r['sum']:08x}")
    if args.csv:
        with args.csv.open('w', newline='') as f:
            w = csv.DictWriter(f, fieldnames=list(recs[0].keys()) if recs else ['record'])
            w.writeheader()
            w.writerows(recs)
        print(f"records written to {args.csv}")
    if args.rom and (bad or load_bad):
        sys.exit(1)


if __name__ == '__main__':
    main()
