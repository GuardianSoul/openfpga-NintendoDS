#!/usr/bin/env python3
"""Decode the NDSPhase1 log (docs/phase1-foundation.md, "Log").

    decode.py phase1-log.bin [--rom FILE] [--bios9 F] [--bios7 F] [--firmware F] [--json]

The Pocket saves the 128-word log from bridge 0x40000000 when the core quits:
Saves/nds/common/phase1-log.bin. The byte order and a possible one-word read
lag (tools/sd-probe saw both) are detected from the magic word.

With --rom the ROM's CRC-32 and the pass A/B signature are recomputed from the
file and compared; with --bios9/--bios7/--firmware their CRC-32s.
"""
import argparse
import json
import struct
import sys
import zlib

MAGIC = 0x4E445031          # "NDP1"
BUS_HZ = 33_513_982
MEM_HZ = 100_541_946
STATES = ['waiting', 'running', 'PASS', 'FAIL']
BOXES = ['SDRAM', 'PSRAM', 'SRAM', 'BIOS9', 'BIOS7', 'firmware', 'pass A', 'cartridge']


def mix(i, d):
    """nds_sig_pkg::mix (rtl/pocket/nds_sig.sv)."""
    m = 0xFFFFFFFF
    h = (i ^ (i << 13) ^ (i >> 7) ^ 0x9E3779B9) & m
    t = d ^ h
    t = (t + (t << 5)) & m
    t ^= t >> 11
    t = (t + (h ^ ((t << 8) & m))) & m
    return t ^ (t >> 16)


def signature(data):
    """nds_sig over a file: bytes past the end count as zero."""
    pad = data + b'\0' * (-len(data) % 4)
    s, x = 0, 0
    for i, (w,) in enumerate(struct.iter_unpack('<I', pad)):
        s = (s + mix(i, w)) & 0xFFFFFFFF
        x ^= mix(i, ~w & 0xFFFFFFFF)
    return (x << 32) | s


def load(path):
    raw = open(path, 'rb').read()
    for order in '<>':
        for shift in (0, -1):
            n = len(raw) // 4
            words = list(struct.unpack(f'{order}{n}I', raw[:n * 4]))
            if shift < 0:
                words = [MAGIC] + words
            if words and words[0] == MAGIC:
                return (words + [0] * 128)[:128], ('little' if order == '<' else 'big') + ('-endian, first word dropped' if shift else '-endian')
    sys.exit('no NDP1 magic: not a Phase 1 log')


def fields(w):
    f = {
        'flags': w[2], 'ms': w[3], 'rom_size': w[4], 'bios9_size': w[5], 'bios7_size': w[6], 'fw_size': w[7],
        'bios9_crc': w[8], 'bios7_crc': w[9], 'fw_crc': w[10], 'load_words': w[11],
        'load_jumps': w[12] >> 16, 'fetch_errors': w[12] & 0xFFFF,
        'rom_crc': w[13], 'sig_a': w[15] << 32 | w[14], 'a_words': w[16], 'a_ms': w[17],
        'a_cmds': w[18] >> 16, 'a_errors': w[18] & 0xFFFF, 'a_jumps': w[19] >> 16, 'fetch_cmds': w[20] & 0xFFFF,
        'fifo_overflow': w[21] >> 31,
        'sig_b': w[25] << 32 | w[24], 'b_words': w[26], 'b_ms': w[27], 'b_quads': w[28],
        'lookups': w[29], 'fast': w[30], 'cmds': w[31], 'blocks': w[32], 'evictions': w[33], 'wait_ms': w[34],
        'spans': w[35], 'marks': w[36], 'cache_errors': w[37] & 0xFFFF, 'bus_flags': w[38],
        'rb9': w[39], 'rb7': w[40], 'rbfw': w[41],
        'sd_passes': w[42], 'sd_errors': w[43], 'sd_fail_addr': w[44], 'sd_exp': w[45], 'sd_act': w[46],
        'sd_wr_cycles': w[47], 'sd_rd_cycles': w[48], 'b_bytes': w[49],
        'ps_passes': w[52], 'ps_errors': w[53], 'ps_fail_addr': w[54], 'ps_exp': w[55], 'ps_act': w[56],
        'ps_wr_cycles': w[57], 'ps_rd_cycles': w[58], 'ps_rd_max': w[59] >> 16, 'ps_rd_min': w[59] & 0xFFFF,
        'sram_ok': w[60] >> 16, 'sram_bad': w[60] & 0xFFFF, 'sram_rounds': w[61] >> 16, 'ps_state': w[61] & 3,
        'sram_fail_info': w[62], 'sram_fail_data': w[63],
        'sram_errors_by_len': [(w[64 + L // 2] >> (16 * (L % 2))) & 0xFFFF for L in range(16)],
        'sram_ffff_reads': w[72],
        'underruns': w[50] >> 16, 'late': w[50] & 0xFFFF,
        'layout': w[51] >> 30, 'touch': (w[51] >> 29) & 1, 'pen': (w[51] >> 28) & 1,
    }
    f['boxes'] = {name: STATES[(w[2] >> (2 * i)) & 3] for i, name in enumerate(BOXES)}
    f['sig_match'] = (w[2] >> 22) & 1
    return f


def lengths(mask):
    return ','.join(str(i) for i in range(16) if mask >> i & 1) or '-'


def report(f, how, args):
    out = []
    p = out.append
    p(f"log: {how}, {f['ms']} ms since the slots loaded")
    p('boxes: ' + ', '.join(f'{k} {v}' for k, v in f['boxes'].items()))
    p(f"slots: ROM {f['rom_size']:,} B, BIOS9 {f['bios9_size']:,}, BIOS7 {f['bios7_size']:,}, firmware {f['fw_size']:,}")
    p(f"loads: {f['load_words']:,} words, {f['load_jumps']} out of order; CRC-32 BIOS9 {f['bios9_crc']:08x} "
      f"BIOS7 {f['bios7_crc']:08x} firmware {f['fw_crc']:08x}; read back {f['rb9']:08x} {f['rb7']:08x} {f['rbfw']:08x}")
    mb = f['rom_size'] / 1e6
    a_rate = f"{mb / (f['a_ms'] / 1000):.2f} MB/s" if f['a_ms'] else '-'
    p(f"pass A: {f['a_cmds']} commands ({f['a_errors']} APF errors), {f['a_words']:,} words, {f['a_ms']:,} ms ({a_rate}), "
      f"ROM CRC-32 {f['rom_crc']:08x}, signature {f['sig_a']:016x}")
    b_s = f['b_ms'] / 1000
    p(f"pass B: {f['b_quads']:,} quad reads, {f['b_words']:,} words, {b_s:.2f} s"
      + (f" ({mb / b_s:.2f} MB/s)" if b_s else '') + f", signature {f['sig_b']:016x} "
      + ('= pass A' if f['sig_b'] == f['sig_a'] else '!= pass A'))
    p(f"cache: {f['cmds']:,} APF commands for {f['blocks']:,} blocks ({f['cache_errors']} errors), {f['evictions']:,} evictions, "
      f"{f['lookups']:,} lookups ({f['fast']:,} same block as before), waiting {f['wait_ms'] / 1000:.2f} s; "
      f"read-ahead from the ROM tables: {'yes' if f['cmds'] < f['blocks'] else 'no (or none needed)'}")
    p(f"SDRAM test: {f['sd_passes']:,} passes, {f['sd_errors']:,} errors"
      + (f" (first at word {f['sd_fail_addr']:#x}: expected {f['sd_exp']:08x}, read {f['sd_act']:08x})" if f['sd_errors'] else '')
      + f"; one pass writes in {f['sd_wr_cycles'] / BUS_HZ * 1e3:.2f} ms, reads in {f['sd_rd_cycles'] / BUS_HZ * 1e3:.2f} ms")
    p(f"PSRAM test: {f['ps_passes']:,} passes, {f['ps_errors']:,} errors"
      + (f" (first at {f['ps_fail_addr']:#x}: expected {f['ps_exp']:08x}, read {f['ps_act']:08x})" if f['ps_errors'] else '')
      + f"; writes {f['ps_wr_cycles'] / MEM_HZ * 1e3:.2f} ms, reads {f['ps_rd_cycles'] / MEM_HZ * 1e3:.2f} ms per pass; "
      f"16-byte read {f['ps_rd_min']}-{f['ps_rd_max']} clocks ({f['ps_rd_min'] / MEM_HZ * 1e9:.0f}-{f['ps_rd_max'] / MEM_HZ * 1e9:.0f} ns)")
    p(f"SRAM: {f['sram_rounds']} rounds; access lengths (x 9.95 ns) that passed every time: {lengths(f['sram_ok'] & ~f['sram_bad'])}; "
      f"failed at least once: {lengths(f['sram_bad'])}"
      + (f"; first error L{f['sram_fail_info'] >> 17} at {f['sram_fail_info'] & 0x1FFFF:#x}: expected {f['sram_fail_data'] >> 16:04x}, "
         f"read {f['sram_fail_data'] & 0xFFFF:04x}" if f['sram_bad'] else ''))
    p("SRAM errors by access length: " + ', '.join(f"L{L} {n}" for L, n in enumerate(f['sram_errors_by_len']) if L)
      + f"; bad reads that were 0xFFFF (bus not driven): {f['sram_ffff_reads']:,}")
    p(f"stacked layout: {f['underruns']} buffered lines fetched late, {f['late']} written late")
    checks = []
    if args.rom:
        data = open(args.rom, 'rb').read()
        crc = zlib.crc32(data)
        sig = signature(data)
        checks.append(('ROM size', len(data) == f['rom_size']))
        checks.append(('ROM CRC-32 (pass A)', crc == f['rom_crc']))
        checks.append(('pass A signature', sig == f['sig_a']))
        checks.append(('pass B signature', sig == f['sig_b']))
        checks.append(('pass A words', f['a_words'] == (len(data) + 3) // 4))
        checks.append(('pass B words', f['b_words'] == (len(data) + 3) // 4))
    for name, key, sz in (('bios9', 'bios9_crc', 'bios9_size'), ('bios7', 'bios7_crc', 'bios7_size'), ('firmware', 'fw_crc', 'fw_size')):
        path = getattr(args, name)
        if path:
            data = open(path, 'rb').read()
            checks.append((f'{name} CRC-32', zlib.crc32(data) == f[key] and len(data) == f[sz]))
    for name, ok in checks:
        p(f"check {name}: {'ok' if ok else 'MISMATCH'}")
    return out, all(ok for _, ok in checks)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('log')
    ap.add_argument('--rom')
    ap.add_argument('--bios9')
    ap.add_argument('--bios7')
    ap.add_argument('--firmware')
    ap.add_argument('--json', action='store_true')
    a = ap.parse_args()
    w, how = load(a.log)
    f = fields(w)
    if a.json:
        print(json.dumps(f))
        return
    lines, ok = report(f, how, a)
    print('\n'.join(lines))
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
