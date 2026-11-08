#!/usr/bin/env python3
"""A melonDS state as a tb_ds start (docs/state-import.md).

    sim/ds/state_import.py EXPORT_DIR

EXPORT_DIR is census --export-state's output (tools/melonds-census/export_state.cpp).
This adds EXPORT_DIR/overlay.bin and EXPORT_DIR/import.txt, which
`tb_ds --import-state EXPORT_DIR` reads.

The overlay holds the restore stub (sw/stateload/stateload.bin) and each CPU's
table, in the largest run of zeros in the state's main RAM. A 24-byte block
at 0x02000000 tells the boot ROM (sw/boot/import.s) where they are. tb_ds
writes the state's own bytes back over both before it releases the CPUs.
"""
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
MAIN = 0x02000000
READY9, READY7 = 0x02000018, 0x0200001C       # in the block: each stub's last write
SCRATCH = 0x04000F04                          # core scratch register: ARM9's I/O done (ARM7 waits)
CP15_IDX = {0x100: 0, 0x200: 1, 0x201: 2, 0x300: 3, 0x502: 4, 0x503: 5,
            0x600: 6, 0x610: 7, 0x620: 8, 0x630: 9, 0x640: 10, 0x650: 11, 0x660: 12, 0x670: 13,
            0x910: 14, 0x911: 15}


def read_state(d):
    st = {}
    for l in (d / 'state.txt').read_text().splitlines():
        if l and not l.startswith('#'):
            k, v = l.split()[:2]
            st[k] = int(v, 16) if k not in ('vcount',) and not k.endswith('.halted') else int(v, 0)
    return st


def io_ops(d, cpu):
    ops = []
    for l in (d / f'io{cpu}.txt').read_text().splitlines():
        p = l.split()
        if p[0] == 'fifo':
            ops.append((3, 0x04000188, int(p[1], 16)))
        else:
            ops.append(({'w8': 1, 'w16': 2, 'w32': 3}[p[0]], int(p[1], 16), int(p[2], 16)))
    return ops


def regblock(st, n):
    w = [st[f'{n}.cpsr'], st[f'{n}.pc'], st[f'{n}.halted'], st.get('cp15.100', 0) if n == 'arm9' else 0]
    w += [st[f'{n}.fiq_r{i}'] for i in range(8, 15)] + [st[f'{n}.fiq_spsr']]
    for m in ('irq', 'svc', 'abt', 'und'):
        w += [st[f'{n}.{m}_r13'], st[f'{n}.{m}_r14'], st[f'{n}.{m}_spsr']]
    w += [st[f'{n}.usr_r{i}'] for i in range(8, 15)]
    w += [st[f'{n}.r{i}'] for i in range(8)]
    assert len(w) == 39
    return w


def tcm(v):
    """(base, bytes) of a CP15 c9 region value"""
    return v & 0xFFFFF000, 512 << ((v >> 1) & 0x1F)


def main():
    d = Path(sys.argv[1])
    st = read_state(d)
    mode9, mode7 = st['arm9.cpsr'] & 0x1F, st['arm7.cpsr'] & 0x1F
    for n, m in (('ARM9', mode9), ('ARM7', mode7)):
        if m in (0x17, 0x1B):
            sys.exit(f'{n} is in abort/undefined mode: the trampoline uses those modes (docs/state-import.md)')
    # the geometry engine's frame in progress is not restored (docs/state-import.md "Not restored", 3D)
    gx = {l.split()[0]: l.split()[1] for l in (d / 'state.txt').read_text().splitlines() if l.startswith('gx.')}
    if gx.get('gx.flushrequest', '0') != '0' or gx.get('gx.numpolygons', '0') != '0':
        print(f'note: 3D mid-frame at the save point (swap pending {gx.get("gx.flushrequest")}, '
              f'{gx.get("gx.numpolygons")} polygons submitted): the first 3D frames after the release differ from melonDS')
    main_ram = bytearray((d / 'main.bin').read_bytes())
    stub = (ROOT / 'sw/stateload/stateload.bin').read_bytes()
    dbase, dsize = tcm(st['cp15.910'])
    _, isize = tcm(st['cp15.911'])

    # ---- the tables (addresses filled in once the overlay is placed)
    def build(stage):
        itcm_src = stage + 0x1000
        dtcm_src = itcm_src + 0x8000
        pal_src = dtcm_src + 0x4000
        oam_src = pal_src + 0x800
        t9 = []
        # BOOTCTL (core register 0x04000F00, set by the normal boot): IR cart, save type, DSi-enhanced cart (bit 7,
        # header unit code bit 1: chip ID bit 30, which the game stored at boot)
        sv = d / 'save.bin'
        stype = {0x200: 1, 0x2000: 2, 0x10000: 3, 0x20000: 4, 0x40000: 5, 0x80000: 6, 0x100000: 7}.get(
            sv.stat().st_size if sv.exists() else 0, 0)
        ir = main_ram[0x3FFE0C] == ord('I')
        dsi = bool(main_ram[0x3FFE12] & 2)
        t9 += [3, 0x04000F00, (2 if ir else 0) | stype << 4 | (0x80 if dsi else 0)]
        ctl = st['cp15.100']
        t9 += [5, 14, st['cp15.910'], 5, 15, st['cp15.911']]
        # TCMs on (the state's bases), load modes, protection and caches off, for the copies
        t9 += [5, 0, (ctl | 0x50000) & ~(0x1 | 0x4 | 0x1000 | 0x20000 | 0x80000)]
        t9 += [4, 0x00000000, itcm_src, min(0x8000, isize)]
        t9 += [4, dbase, dtcm_src, min(0x4000, dsize)]
        t9 += [4, 0x05000000, pal_src, 0x800, 4, 0x07000000, oam_src, 0x800]
        ops9 = io_ops(d, 9)
        for i, o in enumerate(ops9):
            t9 += list(o)
            if o[1] == 0x04000247:           # after POWCNT1, EXMEMCNT and WRAMCNT: the ARM7 may go on
                t9 += [3, SCRATCH, 0x5A]
        for k, idx in CP15_IDX.items():
            if 1 <= idx <= 13:
                t9 += [5, idx, st[f'cp15.{k:03x}']]
        t9 += [3, READY9, 1, 0] + regblock(st, 'arm9')
        t7 = [6, SCRATCH, 0xFF, 0x5A]
        for o in io_ops(d, 7):
            t7 += list(o)
        t7 += [3, READY7, 1, 0] + regblock(st, 'arm7')
        data = {itcm_src: (d / 'itcm.bin').read_bytes()[:0x8000], dtcm_src: (d / 'dtcm.bin').read_bytes()[:0x4000],
                pal_src: (d / 'palette.bin').read_bytes(), oam_src: (d / 'oam.bin').read_bytes()}
        return t9, t7, data, oam_src + 0x800

    # ---- the overlay: the largest run of zeros in main RAM, outside the TCM windows
    _, _, _, end0 = build(0)
    t9, t7, _, _ = build(0)
    need = (end0 + 4 * (len(t9) + len(t7)) + 0xFFF) & ~0xFFF
    best, run, start = (0, 0), 0, 0
    for a in range(0x1000, 0x400000, 0x1000):        # (page 0 holds the block)
        page = main_ram[a:a + 0x1000]
        zero = page.count(0) == 0x1000
        ab = MAIN + a
        tcm_hit = (dsize and dbase <= ab < dbase + dsize) or ab < isize
        if zero and not tcm_hit:
            if run == 0:
                start = a
            run += 0x1000
            if run > best[1]:
                best = (start, run)
        else:
            run = 0
    if best[1] < need:
        # no run long enough (gsdd-continue: 0x12000 of 0x13000): the window with the most zero pages. tb_ds writes
        # main RAM's own bytes back over the overlay before the release, so only the restore sees the overlay there
        pages = [a for a in range(0x1000, 0x400000 - need + 0x1000, 0x1000)
                 if not ((dsize and dbase <= MAIN + a + need - 1 and MAIN + a < dbase + dsize) or MAIN + a < isize)]
        zp = {a: main_ram[a:a + 0x1000].count(0) == 0x1000 for a in range(0x1000, 0x400000, 0x1000)}
        a0 = max(pages, key=lambda a: sum(zp[b] for b in range(a, a + need, 0x1000)))
        print(f'warning: no {need:#x}-byte run of zeros in main RAM (largest {best[1]:#x}); the overlay covers '
              f'{sum(not zp[b] for b in range(a0, a0 + need, 0x1000))} non-zero pages at {MAIN + a0:#010x}')
        best = (a0, need)
    stage = MAIN + best[0]
    t9, t7, data, end = build(stage)
    ov = bytearray(end - stage + 4 * (len(t9) + len(t7)))
    ov[0:len(stub)] = stub
    for a, b in data.items():
        ov[a - stage:a - stage + len(b)] = b
    tab9 = end
    tab7 = tab9 + 4 * len(t9)
    ov[tab9 - stage:tab9 - stage + 4 * len(t9)] = struct.pack(f'<{len(t9)}I', *[x & 0xFFFFFFFF for x in t9])
    ov[tab7 - stage:tab7 - stage + 4 * len(t7)] = struct.pack(f'<{len(t7)}I', *[x & 0xFFFFFFFF for x in t7])
    (d / 'overlay.bin').write_bytes(bytes(ov))
    block = struct.pack('<6I', 0x444F4C53, 0x49534E44, stage, stage + 4, tab9, tab7)
    (d / 'block.bin').write_bytes(block)
    (d / 'import.txt').write_text(
        f'overlay {stage:08x} {len(ov):x}\nblock {MAIN:08x} {len(block) + 8:x}\n'
        f'ready9 {READY9:08x}\nready7 {READY7:08x}\nvcount {st["vcount"]:x}\nstub {len(stub):x}\n')
    print(f'overlay at {stage:#010x}, {len(ov):#x} bytes (run of zeros {best[1]:#x}); '
          f'ARM9 {len(t9)} words, ARM7 {len(t7)} words; release at line {st["vcount"]}')


if __name__ == '__main__':
    main()
