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
    # per-second history: words 32..127, a ring of the last 96 seconds (60 DS
    # frames each), {ARM9, ARM7} retired instructions in 1,024s
    secs = w[22] if len(w) > 127 else 0
    if secs:
        n = min(secs, 96)
        print(f"history: {secs} seconds, the last {n} (ARM9 / ARM7 M instructions per second of DS time):")
        for k in range(secs - n, secs):
            h = w[32 + k % 96]
            print(f"  s{k:5d}  {(h >> 16) * 1024 / 1e6:6.2f} / {(h & 0xFFFF) * 1024 / 1e6:6.2f}")


if __name__ == '__main__':
    main()
