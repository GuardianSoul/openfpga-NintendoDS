#!/usr/bin/env python3
"""Decode the DS core's log (Saves/nds/common/nds-log.bin, rtl/pocket/core_top_ds.sv).

    decode_log.py nds-log.bin

128 words: 0-7 APF side (magic NDS1, sizes, ms since start-up), 8-15 the DS
(magic NDS2, frames, retired instructions and last PC per CPU), 16-21 the
ROM cache, 22 seconds of history, 32-127 the per-second history ring. The Pocket's save may lag by one word or drop word 0; the magics find the start.
"""
import struct
import sys


def main():
    d = open(sys.argv[1], 'rb').read()
    w = list(struct.unpack('<%dI' % (len(d) // 4), d[:len(d) // 4 * 4]))
    lag = next((k for k in range(3) if k < len(w) and w[k] == 0x4E445331), None)
    if lag is None:
        # the Pocket's save can also drop word 0 (the NDS1 magic, as in
        # docs/sd-probe.md): place the words by the NDS2 magic (word 8)
        k2 = next((k for k in range(5, 11) if k < len(w) and w[k] == 0x4E445332), None)
        if k2 is None:
            sys.exit('no NDS1/NDS2 magic: %s' % ' '.join('%08x' % x for x in w[:10]))
        lag = k2 - 8
        print(f"(log shifted by {-lag} word(s): placed by the NDS2 magic)")
    w = w[lag:] + [0] * lag if lag >= 0 else [0x4E445331] * -lag + w
    if len(w) > 127 and (w[1] >> 16) == 0x0202:
        decode_v3(w)
        return
    print(f"APF:   ms since start-up {w[3]}, FIFO overflow {w[2] & 1}")
    print(f"       ROM {w[4]} bytes, BIOS9 {w[5]}, BIOS7 {w[6]}, firmware {w[7]}")
    if w[8] != 0x4E445332:
        print(f"DS words missing (word 8 = {w[8]:08x})")
    else:
        print(f"DS:    running {w[14] & 1}, frames {w[9]}, retired ARM9 {w[10]} ARM7 {w[11]}")
        print(f"       last PC ARM9 {w[12]:08x} ARM7 {w[13]:08x}")
        print(f"       layout {w[15] >> 16 & 3}, stacked-buffer underruns {w[15] & 0xFFFF}")
    print(f"cache: ROM size seen {w[16]}, ready {w[17] & 1}, fail {w[17] >> 1 & 1}")
    print(f"       lookups {w[18]}, APF commands {w[19]}, blocks {w[20]}, ms waiting {w[21]}")
    print(f"sound: steps started late {w[23]}, longest memory access {w[24]} clk_sys cycles"
          f" ({w[24] / 67.03:.1f} us; a step has 2,048)")
    print(f"display: DS lines not drawn in time {w[25]}, most in one frame {w[26] >> 16},"
          f" last at line {w[26] & 0x1FF} of frame {w[27]}")
    v2 = len(w) > 31 and (w[1] >> 16) == 0x0201   # RC9d's log (core_top_ds g_log, words 28-31, the history's ROM-cache waits)
    if v2:
        gmin = w[29] & 0xFFFF
        print(f"bridge FIFO: words dropped {w[28] >> 16}{'+' if w[28] >> 16 == 0xFFFF else ''}, most waiting {w[29] >> 24 & 0x7F} of 64,"
              f" shortest gap between ROM-cache words {'none seen' if gmin == 0xFFFF else f'{gmin} clk_74a ({gmin / 74.25:.2f} us)'},"
              f" words under 40 clk after the last {w[29] >> 16 & 0xFF}{'+' if (w[29] >> 16 & 0xFF) == 255 else ''}")
        print(f"APF:   ROM-cache fetch commands {w[30] & 0xFFFF} (errors {w[28] & 0xFF}), direct target commands"
              f" {w[30] >> 16} (errors {w[28] >> 8 & 0xFF})")
        print(f"ROM cache: longest single wait for an APF fetch {(w[31] & 0xFFFF) * 4096 / 67.03e3:.1f} ms, at DS frame"
              f" {w[31] >> 16} (mod 65,536)")
    # per-second history: words 32..127, a ring of the last 96 seconds (60 DS
    # frames each), {ARM9, ARM7} retired instructions in 1,024s
    secs = w[22] if len(w) > 127 else 0
    if secs:
        n = min(secs, 96)
        if v2:
            print(f"history: {secs} seconds, the last {n} (ARM9 M instructions; ROM cache waiting for APF fetches, ms;"
                  f" its longest single wait, ms; per second of DS time):")
            for k in range(secs - n, secs):
                h = w[32 + k % 96]
                print(f"  s{k:5d}  {(h >> 20) * 65536 / 1e6:6.2f}  {(h >> 10 & 0x3FF) * 65536 / 67.03e3:7.1f}"
                      f"  {(h & 0x3FF) * 65536 / 67.03e3:7.1f}")
            return
        print(f"history: {secs} seconds, the last {n} (ARM9 / ARM7 M instructions per second of DS time):")
        for k in range(secs - n, secs):
            h = w[32 + k % 96]
            print(f"  s{k:5d}  {(h >> 16) * 1024 / 1e6:6.2f} / {(h & 0xFFFF) * 1024 / 1e6:6.2f}")


def decode_v3(w):
    """RC9e's display log (core_top_ds g_log, version 0x0202): the display registers and per-second layer counts"""
    def h16(x): return f"{x >> 16 & 0xFFFF:04x}"
    def l16(x): return f"{x & 0xFFFF:04x}"
    lay = lambda d: ' '.join(n for b, n in ((8, 'BG0'), (9, 'BG1'), (10, 'BG2'), (11, 'BG3'), (12, 'OBJ')) if d >> b & 1)
    print(f"APF:   ms since start-up {w[3]}, FIFO overflow {w[2] & 1}")
    print(f"DS:    running {w[14] & 1}, frames {w[9]}, retired ARM9 {w[10]} ARM7 {w[11]}, last PC ARM9 {w[12]:08x}")
    for e, (dc, bl) in (('A', (w[16], w[20])), ('B', (w[17], w[21]))):
        print(f"engine {e}: DISPCNT {dc:08x} (mode {dc & 7}, BG0 {'3D' if dc & 8 else '2D'}, layers on: {lay(dc)},"
              f" windows {dc >> 13 & 7:03b}, display mode {dc >> 16 & 3}); BLDCNT {bl & 0x3FFF:04x} (effect {bl >> 6 & 3}),"
              f" EVY {bl >> 16 & 31}, MASTER_BRIGHT mode {bl >> 28 & 3} factor {bl >> 23 & 31}")
    print(f"       EVA/EVB A {w[28] & 31}/{w[28] >> 8 & 31}, B {w[28] >> 16 & 31}/{w[28] >> 24 & 31};"
          f" BG0CNT {l16(w[18])} BG1CNT {h16(w[18])} BG2CNT {l16(w[19])} BG3CNT {h16(w[19])} (engine A)")
    p = w[29] >> 16
    print(f"POWCNT1 {p:04x} (engine A on the {'top' if p >> 15 & 1 else 'bottom'} screen, 2D A {p >> 1 & 1}, 3D render {p >> 2 & 1},"
          f" geometry {p >> 3 & 1}, 2D B {p >> 9 & 1}), DISP3DCNT {w[29] & 0xFFFF:04x}")
    v = w[23] | w[24] << 32 | (w[30] >> 24) << 64
    print("VRAMCNT " + ' '.join(f"{'ABCDEFGHI'[k]}={v >> (8 * k) & 0xFF:02x}" for k in range(9)) +
          f", WRAMCNT {w[30] >> 22 & 3}; raster restarts {w[30] & 0xFFFFF}; last swap {w[31] >> 16 & 0xFFF} polygons,"
          f" {w[31] & 0x1FFF} vertices (RC9e: reads 0, the counts are cleared before the swap's pulse)")
    print(f"display: DS lines not drawn in time {w[25]}, most in one frame {w[26] >> 16}, last at line {w[26] & 0x1FF} of frame {w[27]}")
    secs = w[22]
    n = min(secs, 48)
    print(f"history: {secs} seconds, the last {n} (engine A's composite pixels by top layer and its non-black output, in"
          f" % of a second's pixels; raster drawn pixels in 16,384s; 3D swaps; R restart, L late 3D line):")
    print("      s  swaps  raster   BG0/3D   BG1   BG2   OBJ  backdrop  out-nonblack")
    # (the counters stop at 2^21 a second, 71 % of a full second's 2,949,120 pixels: 255 reads ">71")
    pc = lambda x: "  >71" if x == 255 else f"{x * 100 / 180:5.0f}"
    for k in range(secs - n, secs):
        a = w[32 + 2 * (k % 48)]; b = w[33 + 2 * (k % 48)]
        print(f"  s{k:5d}  {a >> 26:5d}  {a >> 18 & 0xFF:6d}  {pc(a >> 10 & 0xFF)}  {pc(b >> 24 & 0xFF)} {pc(b >> 16 & 0xFF)}"
              f" {pc(b >> 8 & 0xFF)} {pc(b & 0xFF)}     {pc(a >> 2 & 0xFF)}  {'R' if a & 2 else ' '}{'L' if a & 1 else ' '}")


if __name__ == '__main__':
    main()
