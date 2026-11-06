#!/usr/bin/env python3
"""A game's movie decoder in isolation (docs/hw-reference.md "mvdec method"):
builds <tag>.nds (tb_ds, melonDS) and <tag>_ds.nds (the DS) from the maintainer's
local ROM.

  mkmvdec.py GAME [--rom ROM] [--calls N] [--check]      GAME: kssu | kh358

Copyright: everything this writes holds the game's code and data, so it
goes to roms/mvdec/ (gitignored) and is never committed. Only this script
and sw/hwref/mvdec/ (our harness) are in the repository.

Steps, in build/mvdec/<game>/ (work) and roms/mvdec/ (output):
 1. melonDS census from boot without input to the profile's frame, inside
    the movie: state f<N>.mst
 2. census --snap-pcs on the profile's per-picture functions, from that
    state: the machine at each call's entry, the function's own writes, the
    main RAM KiB it touches and a checksum of its picture
 3. <tag>_main.bin: the main RAM the calls touch (R, plus 1 KiB either
    side) at the first call; <tag>_calls.bin, the call blob
    (sw/hwref/mvdec/run.h): display set-up, CP15, VRAMCNT, ITCM, DTCM, then
    per call r0-r3, SP before the function's push, the game's frame/line,
    melonDS's ticks and picture checksum, and the bytes of R that differ
    between the call's entry and (previous entry + previous call's own
    writes): the data the game streamed in, its bookkeeping
 4. <tag>.nds: sw/hwref/mvdec/tb.c on the sw/tests runtime, linked at the
    start of the largest main RAM range outside R (the hole), inside the
    image, the blob 128 KiB further on; ARM7 idle in WRAM
 5. <tag>_ds.nds: sw/hwref/mvdec/ds.c on calico + libfat, calico's ds9.ld
    moved into the hole, the blob at the hole's end. It reads
    fat:/hwref/<tag>_main.bin and _calls.bin and writes /hwref/<tag>.csv
 6. --check: both in melonDS; prints each call's cycles, VCOUNT, lateness
    and whether its picture matches the game's (<tag>-melonds.txt)
"""
import argparse
import hashlib
import os
import struct
import subprocess
import sys

import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
COMMON = subprocess.run(["git", "-C", ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                        capture_output=True, text=True).stdout.strip()
ROMS = os.path.normpath(os.path.join(COMMON, "..", "roms"))
DEVKITPRO = os.environ.get("DEVKITPRO", os.path.expanduser("~/devkitpro"))


def bg3_bitmap(engine, base16k=0, y=0):
    e = 0x1000 * engine
    return [(0x04000000 + e, 0x00010803, 4),            # mode 3, BG3
            (0x0400000E + e, 0x4087 | base16k << 8, 2),  # BG3: 256x256 direct colour bitmap
            (0x04000030 + e, 0x100, 2), (0x04000032 + e, 0, 2), (0x04000034 + e, 0, 2), (0x04000036 + e, 0x100, 2),
            (0x04000038 + e, 0, 4), (0x0400003C + e, (y << 8) & 0x0FFFFFFF, 4)]


GAMES = {
    # Kirby Super Star Ultra (USA): the intro movie (Actimagine Mobiclip) on
    # both screens, a picture per screen every 4 frames. decode(ctx);
    # convert(ctx, vram, 0x100): YUV 4:2:0 -> 256x192 RGB15 straight into
    # the displayed BG3 bitmap (ctx 0x0222FE50 bottom/0x06200000, 0x021E53E0
    # top/0x06000000). The per-picture function 0x020178D8 also polls cart
    # reads and talks to the ARM7, so it isn't run.
    "kssu": dict(tag="kssumv", code=b"YKWE", sha1="0bec02a27800da1194a48bc92e35de8edee02aee",
                 rom="card/Kirby Super Star Ultra (USA).nds", boot_frames=1000, calls=48,
                 funcs={0x02017EC4: "decode", 0x02017EE8: "convert"}, ck_funcs=(0x02017EE8,), snap_args=[],
                 display=[(0x04000304, 0x8203, 2)] + bg3_bitmap(0) + bg3_bitmap(1)),
    # Kingdom Hearts 358/2 Days (Europe): the intro movie on the top screen
    # (engine B), 256x160, a picture every 4 frames. convert(ctx, ...) runs in
    # the timer 1 IRQ handler: YUV -> RGB15 at the word at ctx+8, alternately
    # 0x06208000 (bank C, BG) and 0x06600000 (bank D, OBJ), 512-byte stride.
    # decode(ctx, n, 1) in the main loop; 0x0208437C(ctx, n, k) writes 8 KiB
    # of buffers at 0x02345000 (most likely the movie's audio).
    "kh358": dict(tag="khmv", code=b"YKGP", sha1="6fae8f5bbe80114b4e2535260eab5f4d0fc8a844",
                  rom="card/Kingdom Hearts - 358-2 Days (Europe) (En,Fr,De,Es,It).nds", boot_frames=7550,
                  calls=48, funcs={0x0208435C: "decode", 0x0208437C: "audio", 0x02086004: "convert"},
                  ck_funcs=(0x02086004,), snap_args=["--snap-irq", "1", "--snap-cksum", "*0x022A6744:0x14000"],
                  display=[(0x04000304, 0x0203, 2)] + bg3_bitmap(1, base16k=2, y=-16)),
}

MAIN = 0x02000000
TOP = 0x023C0000                  # calico's ARM7 (0x023CC000), the result block, the system area
HARNESS_SPACE = 0x20000           # tb build: harness code + BSS before the blob
TABLE = 0x3F2000                  # tb.c TABLE_ADDR (offset)
HDR = "<4s4IQ15I4I"
CP15 = "<9I8I9s3x"
TRAIL = "<4s2IQ6I"
WR = np.dtype([("off", "<u4"), ("val", "<u4"), ("space", "u1"), ("size", "u1"), ("pad", "<u2")])
KRES = "<4I2H3I"


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode:
        sys.exit(f"failed: {' '.join(cmd)}\n{r.stdout}{r.stderr}")
    return r.stdout


def census(o, out, frames, *extra):
    return run([o.census, "--bios9", f"{o.bios}/bios9.bin", "--bios7", f"{o.bios}/bios7.bin",
                "--firmware", f"{o.bios}/firmware.bin", "--script", o.script, "--out", out,
                "--frames", str(frames), *extra])


def load_snap(path):
    b = open(path, "rb").read()
    h = struct.unpack_from(HDR, b, 0)
    o = struct.calcsize(HDR)
    ram, itcm, dtcm = h[-3:]
    mem = [np.frombuffer(b, np.uint8, n, o + k) for n, k in ((ram, 0), (itcm, ram), (dtcm, ram + itcm))]
    o += ram + itcm + dtcm
    cp = struct.unpack_from(CP15, b, o)
    o += struct.calcsize(CP15)
    t = struct.unpack_from(TRAIL, b, o)
    o += struct.calcsize(TRAIL)
    assert h[0] == b"KSNP" and t[0] == b"KSEX", path
    wr = np.frombuffer(b, WR, t[6], o)
    o += t[6] * WR.itemsize
    touched = np.unpackbits(np.frombuffer(b, np.uint8, 512, o), bitorder="little").astype(bool)
    return dict(func=h[2], frame=h[3], line=h[4], ts=h[5], r=h[6:21], cpsr=h[21], mem=mem, cp15=cp,
                ts_out=t[3], cksum=t[7], ck_addr=t[8], ck_len=t[9], wr=wr, touched=touched)


def with_writes(mem, wr):
    """mem (3 spaces) after the writes, in order (the last write to a byte wins)."""
    out = [m.copy() for m in mem]
    for sp in range(3):
        w = wr[wr["space"] == sp]
        j = np.arange(len(w))
        pos, val, seq = [], [], []
        for k in range(4):
            m = w["size"] > k
            pos.append(w["off"][m].astype(np.int64) + k)
            val.append(((w["val"][m] >> (8 * k)) & 0xFF).astype(np.uint8))
            seq.append(j[m] * 4 + k)
        pos, val, seq = np.concatenate(pos), np.concatenate(val), np.concatenate(seq)
        order = np.argsort(seq)[::-1]                 # latest first
        u, first = np.unique(pos[order], return_index=True)
        out[sp][u] = val[order][first]
    return out


def spans(mask):
    """[(start, end)] of the True runs of a bool array."""
    d = np.diff(np.concatenate([[0], mask.astype(np.int8), [0]]))
    return list(zip(np.nonzero(d == 1)[0].tolist(), np.nonzero(d == -1)[0].tolist()))


def runs(diff_idx, gap=8):
    if len(diff_idx) == 0:
        return []
    br = np.nonzero(np.diff(diff_idx) > gap)[0]
    starts = np.concatenate([[0], br + 1])
    ends = np.concatenate([br, [len(diff_idx) - 1]])
    return [(int(diff_idx[s]), int(diff_idx[e]) + 1) for s, e in zip(starts, ends)]


def sp_before(snap):
    """SP before the function's first instruction (STMDB sp!, {...})."""
    off = snap["func"] - MAIN
    op = int.from_bytes(snap["mem"][0][off:off + 4].tobytes(), "little")
    assert op & 0xFFFF0000 == 0xE92D0000, f"{snap['func']:08x}: first instruction {op:08x} is not a push"
    return snap["r"][13] + 4 * bin(op & 0xFFFF).count("1")


def layout(snaps):
    """R (bool per KiB) and the hole: the largest KiB range below TOP that no call touches."""
    touched = np.zeros(4096, bool)
    for s in snaps:
        touched |= s["touched"]
        w = s["wr"][s["wr"]["space"] == 0]
        touched[np.unique(w["off"] >> 10)] = True
    r = touched | np.roll(touched, 1) | np.roll(touched, -1)
    if r[(TOP - MAIN) >> 10:].any():
        sys.exit("the calls touch main RAM from 0x023C0000 (calico's ARM7, the result block)")
    free = ~r
    free[(TOP - MAIN) >> 10:] = False
    free[:16] = False
    a, b = max(spans(free), key=lambda s: s[1] - s[0])
    h0 = MAIN + ((a * 1024 + 0xFFF) & ~0xFFF)
    h1 = MAIN + ((b * 1024) & ~0xFFF)
    return r, h0, h1


def build_payload(g, snaps, r):
    s0 = snaps[0]
    cp = s0["cp15"]
    dtcm_base = cp[3]
    control, dtcm_set, itcm_set, _, code_c, data_c, wbuf, code_ap, data_ap = cp[:9]
    blob = bytearray(struct.pack("<8s4I", b"MVDCCALL", 2, len(snaps), s0["frame"], s0["line"]))
    blob += struct.pack("<16I", control, dtcm_set, itcm_set, code_c, data_c, wbuf, code_ap, data_ap, *cp[9:17])
    blob += cp[17] + b"\0" * 3
    blob += struct.pack("<I", len(g["display"]))
    for a, v, n in g["display"]:
        blob += struct.pack("<3I", a, v & 0xFFFFFFFF, n)
    blob += s0["mem"][1].tobytes() + s0["mem"][2].tobytes()
    rbytes = np.repeat(r, 1024)
    pred, sizes = None, []
    for i, s in enumerate(snaps):
        rr = []
        if pred is not None:
            for sp, base in ((0, MAIN), (1, 0x01FF8000), (2, dtcm_base)):
                d = np.nonzero(s["mem"][sp] != pred[sp])[0]
                if sp == 0:
                    d = d[rbytes[d]]
                for a, b in runs(d):
                    rr.append((base + a, s["mem"][sp][a:b].tobytes()))
        ck = s["func"] in g["ck_funcs"] and s["ck_len"]
        rec = struct.pack("<13I", s["func"], *s["r"][:4], sp_before(s), s["frame"], s["line"],
                          s["ts_out"] - s["ts"], s["cksum"] if ck else 0, s["ck_addr"] if ck else 0,
                          s["ck_len"] if ck else 0, len(rr))
        for a, data in rr:
            rec += struct.pack("<2I", a, len(data)) + data + b"\0" * (-len(data) & 3)
        sizes.append(len(rec))
        blob += rec
        pred = with_writes(s["mem"], s["wr"])
    segs = [(MAIN + a * 1024, s0["mem"][0][a * 1024:b * 1024].tobytes()) for a, b in spans(r)]
    print(f"blob: {len(snaps)} calls, {len(blob)} bytes (deltas {min(sizes[1:])}-{max(sizes[1:])} bytes); "
          f"image: {len(segs)} ranges, {sum(len(d) for _, d in segs)} bytes")
    return segs, bytes(blob)


def build_tb(o, g, segs, blob, h0, h1):
    w = os.path.join(o.work, "tb")
    os.makedirs(w, exist_ok=True)
    tests = os.path.join(ROOT, "sw", "tests", "common")
    src = os.path.join(ROOT, "sw", "hwref", "mvdec")
    blob_at = h0 + HARNESS_SPACE
    if blob_at + len(blob) > h1:
        sys.exit(f"the blob ({len(blob)} bytes) doesn't fit the hole {h0:08x}-{h1:08x}")
    font = os.path.join(w, "font.c")
    run([sys.executable, os.path.join(ROOT, "tools", "ds-tests", "mkfont.py"), font])
    cf = ["-O2", "-marm", "-ffreestanding", "-fno-builtin", "-nostdlib", "-fno-pic", "-mfloat-abi=soft",
          "-fno-unwind-tables", "-fno-asynchronous-unwind-tables", "-Wall", "-Wextra", "-Wno-unused-parameter"]
    cf9 = ["--target=armv5te-none-eabi", "-mcpu=arm946e-s"] + cf + [f"-DMV_BLOB={blob_at:#x}u", f'-DMV_TAG="{g["tag"]}"']
    cf7 = ["--target=armv4t-none-eabi", "-mcpu=arm7tdmi"] + cf
    run([o.clang, "--target=armv5te-none-eabi", "-mcpu=arm946e-s", "-Wa,-defsym,ARM9=1", "-c",
         os.path.join(tests, "crt0.s"), "-o", os.path.join(w, "crt0_9.o")])
    objs = [os.path.join(w, "crt0_9.o")]
    for c in (os.path.join(src, "tb.c"), os.path.join(src, "run.c"), os.path.join(tests, "con.c"),
              os.path.join(tests, "results.c"), font):
        ob = os.path.join(w, os.path.basename(c)[:-2] + ".o")
        run([o.clang] + cf9 + ["-DA7BASE=0x037F8000", "-c", c, "-o", ob])
        objs.append(ob)
    elf9 = os.path.join(w, "arm9.elf")
    run([o.lld, "-T", os.path.join(tests, "ds.ld"), f"--defsym=__base={h0:#x}", *objs, "-o", elf9])
    run([o.clang, "--target=armv4t-none-eabi", "-mcpu=arm7tdmi", "-c", os.path.join(tests, "crt0.s"),
         "-o", os.path.join(w, "crt0_7.o")])
    run([o.clang] + cf7 + ["-DA7BASE=0x037F8000", "-c", os.path.join(src, "tb7.c"), "-o", os.path.join(w, "tb7.o")])
    run([o.lld, "-T", os.path.join(tests, "ds.ld"), "--defsym=__base=0x037F8000", os.path.join(w, "crt0_7.o"),
         os.path.join(w, "tb7.o"), "-o", os.path.join(w, "arm7.elf")])
    for n in ("arm9", "arm7"):
        run([o.objcopy, "-O", "binary", os.path.join(w, n + ".elf"), os.path.join(w, n + ".bin")])
    syms = {l.split()[-1]: int(l.split()[0], 16) for l in run([o.nm, elf9]).splitlines() if len(l.split()) == 3}
    if syms["__end"] > blob_at:
        sys.exit(f"harness ends at {syms['__end']:08x}, past the blob at {blob_at:08x}")
    end = max([a + len(d) for a, d in segs] + [blob_at + len(blob)])
    arm9 = bytearray(end - MAIN)
    for a, d in segs:
        arm9[a - MAIN:a - MAIN + len(d)] = d
    h = open(os.path.join(w, "arm9.bin"), "rb").read()
    arm9[h0 - MAIN:h0 - MAIN + len(h)] = h
    arm9[blob_at - MAIN:blob_at - MAIN + len(blob)] = blob
    a9 = os.path.join(w, "image.bin")
    open(a9, "wb").write(arm9)
    nds = os.path.join(o.out, g["tag"] + ".nds")
    run([sys.executable, os.path.join(ROOT, "tools", "ds-tests", "mknds.py"), nds, "--title", g["tag"],
         "--code", "TSMV", "--arm9", a9, "--arm9-ram", f"{MAIN:#x}", "--arm9-entry", f"{h0:#x}",
         "--arm7", os.path.join(w, "arm7.bin"), "--arm7-ram", "0x037F8000"])
    print(f"{nds}: harness at {h0:08x} ({len(h)} bytes), blob at {blob_at:08x}, mvdec_done at {syms['mvdec_done']:#010x}")
    return nds


def build_ds(o, g, blob, h0, h1):
    """calico build in the hole: main from h0, loaded at h0 + 0x3000, the blob at the hole's end."""
    w = os.path.join(o.work, "ds")
    os.makedirs(os.path.join(w, "ld"), exist_ok=True)
    blob_at = (h1 - len(blob)) & ~0xFFF
    calico, libnds = os.path.join(DEVKITPRO, "calico"), os.path.join(DEVKITPRO, "libnds")
    ld = open(os.path.join(calico, "lib", "ds9.ld")).read()
    for a, b in (("lma9    : ORIGIN = 0x2004000, LENGTH = 0x27c000",
                  f"lma9    : ORIGIN = {h0 + 0x3000:#x}, LENGTH = {blob_at - h0 - 0x3000:#x}"),
                 ("main    : ORIGIN = 0x2001000, LENGTH = 0xf7f000",
                  f"main    : ORIGIN = {h0:#x}, LENGTH = {blob_at - h0:#x}")):
        if a not in ld:
            sys.exit(f"calico ds9.ld changed: no '{a}'")
        ld = ld.replace(a, b)
    open(os.path.join(w, "ld", "ds9.ld"), "w").write(ld)
    cc = os.path.join(DEVKITPRO, "devkitARM", "bin", "arm-none-eabi-gcc")
    arch = ["-march=armv5te", "-mtune=arm946e-s"]
    cf = ["-O2", "-g", "-Wall", "-Wno-missing-braces", *arch, "-D__NDS__", "-DARM9", f"-I{calico}/include",
          f"-I{libnds}/include", "-ffunction-sections", "-fdata-sections", f"-DMV_BLOB={blob_at:#x}u",
          f"-DMV_BLOB_MAX={h1 - blob_at:#x}u", f'-DMV_TAG="{g["tag"]}"']
    hw = os.path.join(ROOT, "sw", "hwref")
    objs = []
    for c, mode in ((os.path.join(hw, "mvdec", "ds.c"), "-mthumb"), (os.path.join(hw, "mvdec", "run.c"), "-marm"),
                    (os.path.join(hw, "common", "hwref.c"), "-mthumb")):
        ob = os.path.join(w, os.path.basename(c)[:-2] + ".o")
        run([cc, *cf, mode, "-fno-tree-loop-distribute-patterns", "-c", c, "-o", ob])
        objs.append(ob)
    elf = os.path.join(w, g["tag"] + "_ds.elf")
    run([cc, f"-specs={calico}/share/ds9.specs", *arch, f"-L{w}/ld", f"-L{calico}/lib", f"-L{libnds}/lib",
         *objs, "-lfat", "-lnds9", "-lcalico_ds9", "-lm", "-o", elf])
    end = max(int(l.split()[0], 16) for l in run([o.nm, elf]).splitlines()
              if len(l.split()) == 3 and h0 <= int(l.split()[0], 16) < h1)
    if blob_at - end < 0x40000:
        sys.exit(f"calico ends at {end:08x}: under 256 KiB of heap before the blob at {blob_at:08x}")
    nds = os.path.join(o.out, g["tag"] + "_ds.nds")
    run([os.path.join(DEVKITPRO, "tools", "bin", "ndstool"), "-c", nds, "-9", elf, "-7",
         os.path.join(calico, "bin", "ds7_maine.elf"), "-b", os.path.join(calico, "share", "nds-icon.bmp"),
         f"hwref movie decode {g['tag']};NDS_Pocket hw reference;needs /hwref/{g['tag']}_*.bin"])
    print(f"{nds}: calico {h0:08x}-{end:08x}, blob at {blob_at:08x}")
    return nds


def report(g, tpl, rows, out=sys.stdout):
    frame = tpl * 263
    print("call func     target(f:l)  start-late  vc0  vc1  ARM9 cycles  melonDS cycles  picture", file=out)
    bad = 0
    for i, (func, target, start, end, vc0, vc1, ck, gt, gck) in enumerate(rows):
        late = (start - target) / tpl
        same = "" if not ck and not gck else ("same" if ck == gck else "DIFFERENT")
        bad += same == "DIFFERENT"
        print(f"{i:4d} {g['funcs'].get(func, hex(func)):8s} {target // frame:3d}:{target % frame // tpl:3d}  "
              f"{late:8.1f}ln {vc0:4d} {vc1:4d} {2 * (end - start):12d} {2 * gt:15d}  {same}", file=out)
    print(f"{len(rows)} calls, {bad} pictures differ from the game's", file=out)
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("game", choices=sorted(GAMES))
    ap.add_argument("--rom")
    ap.add_argument("--bios", default=ROMS)
    ap.add_argument("--census", default=os.path.join(ROOT, "build", "census-melonds", "build", "census"))
    ap.add_argument("--work")
    ap.add_argument("--out", default=os.path.join(ROMS, "mvdec"))
    ap.add_argument("--calls", type=int)
    ap.add_argument("--check", action="store_true", help="run both builds in melonDS and report")
    ap.add_argument("--clang", default=os.environ.get("CLANG", "clang"))
    ap.add_argument("--lld", default=os.environ.get("LLD", "ld.lld"))
    ap.add_argument("--objcopy", default=os.environ.get("OBJCOPY", "llvm-objcopy"))
    ap.add_argument("--nm", default=os.environ.get("NM", "llvm-nm"))
    o = ap.parse_args()
    g = GAMES[o.game]
    o.rom = o.rom or os.path.join(ROMS, g["rom"])
    o.work = o.work or os.path.join(ROOT, "build", "mvdec", o.game)
    calls = o.calls or g["calls"]
    rom = open(o.rom, "rb").read()
    if rom[12:16] != g["code"]:
        sys.exit(f"{o.rom}: game code {rom[12:16]}, want {g['code']}")
    if hashlib.sha1(rom).hexdigest() != g["sha1"]:
        sys.exit(f"{o.rom}: not the ROM the addresses were taken from (sha1)")
    os.makedirs(o.work, exist_ok=True)
    os.makedirs(o.out, exist_ok=True)
    o.script = os.path.join(o.work, "noinput.txt")
    open(o.script, "w").write("# no input\n")

    state = os.path.join(o.work, f"f{g['boot_frames']}.mst")
    if not os.path.exists(state):
        print(f"booting to frame {g['boot_frames']} ...")
        census(o, os.path.join(o.work, "boot"), g["boot_frames"] + 1, "--rom", o.rom, "--shot-every",
               str(g["boot_frames"]), "--save-state", state, "--save-state-at", str(g["boot_frames"]))
    snapdir = os.path.join(o.work, "snap")
    os.makedirs(snapdir, exist_ok=True)
    for f in os.listdir(snapdir):
        os.remove(os.path.join(snapdir, f))
    census(o, os.path.join(o.work, "game"), calls * 2 + 30, "--rom", o.rom, "--load-state", state,
           "--shot-every", "4", "--snap-pcs", ",".join(hex(f) for f in g["funcs"]),
           "--snap-dir", snapdir, "--snap-max", str(calls), *g["snap_args"])
    snaps = [load_snap(os.path.join(snapdir, f)) for f in sorted(os.listdir(snapdir))]
    if len(snaps) < calls:
        sys.exit(f"only {len(snaps)} calls captured: is frame {g['boot_frames']} still in the movie?")
    r, h0, h1 = layout(snaps)
    print(f"R: {int(r.sum())} KiB; hole {h0:08x}-{h1:08x}")
    segs, blob = build_payload(g, snaps, r)
    img = bytearray(b"MVDCIMG1" + struct.pack("<I", len(segs)))
    for a, d in segs:
        img += struct.pack("<2I", a, len(d)) + d
    tag = g["tag"]
    open(os.path.join(o.out, tag + "_main.bin"), "wb").write(img)
    open(os.path.join(o.out, tag + "_calls.bin"), "wb").write(blob)
    nds = build_tb(o, g, segs, blob, h0, h1)
    ds_nds = build_ds(o, g, blob, h0, h1)
    if not o.check:
        return 0

    frames = snaps[-1]["frame"] - snaps[0]["frame"] + 30
    out = os.path.join(o.work, "check")
    st = os.path.join(out, "end.mst")
    census(o, out, frames, "--rom", nds, "--shot-every", "4", "--save-state", st, "--save-state-at", str(frames - 1))
    b = open(st, "rb").read()
    i = b.find(b"NDSG") + 20
    magic, n, tpl = struct.unpack_from("<8sII", b, i + TABLE)
    if magic != b"MVDCRES1":
        sys.exit(f"{tag}.nds left no result table in melonDS")
    sz = struct.calcsize(KRES)
    rows = [struct.unpack_from(KRES, b, i + TABLE + 16 + k * sz) for k in range(n)]
    with open(os.path.join(o.out, tag + "-melonds.txt"), "w") as f:
        report(g, tpl, rows, out=f)
    bad = report(g, tpl, rows)
    out = os.path.join(o.work, "check_ds")
    sd = os.path.join(out, "sd", "hwref")
    os.makedirs(sd, exist_ok=True)
    for f in (tag + "_main.bin", tag + "_calls.bin"):
        subprocess.run(["cp", os.path.join(o.out, f), sd], check=True)
    census(o, os.path.join(out, "run"), frames + 300, "--rom", ds_nds, "--shot-every", "60",
           "--sd-dir", os.path.join(out, "sd"), "--sd-mb", "64")
    csv = os.path.join(sd, tag + "_warm.csv")
    if not os.path.exists(csv):
        sys.exit(f"{tag}_ds.nds wrote no {tag}.csv in melonDS")
    ds_rows = [l.split(",") for l in open(csv).read().splitlines()[1:]]
    diff = sum(x[-1] != "1" for x in ds_rows)
    dcyc = max(abs(int(x[7]) - 2 * (y[3] - y[2])) for x, y in zip(ds_rows, rows))
    print(f"{tag}_ds.nds in melonDS (warm caches): {len(ds_rows)} calls, {diff} pictures differ; ARM9 cycles vs "
          f"{tag}.nds (cold): max |diff| {dcyc}")
    return 1 if bad or diff else 0


if __name__ == "__main__":
    sys.exit(main())
