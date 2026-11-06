#!/usr/bin/env python3
"""Compare two DS trace directories (melonDS census --trace-dir, or the RTL
testbench) per CPU: retired instructions (armN.trc) and writes (armN.wr).
Formats and options: tools/ds-trace/README.md.  Exit 0 = match, 1 = divergence."""
import argparse, os, sys
import numpy as np

NREG = 17                      # pc, cpsr, r0..r14
WR = np.dtype([("addr", "<u4"), ("val", "<u4"), ("size", "u1"), ("src", "u1"), ("rsvd", "<u2")])
CHUNK = 1 << 21
VEC = {9: 0xFFFF0018, 7: 0x00000018}
MODES = {0x10: "usr", 0x11: "fiq", 0x12: "irq", 0x13: "svc", 0x17: "abt", 0x1B: "und", 0x1F: "sys"}


def load_trc(d, cpu):
    p = os.path.join(d, f"arm{cpu}.trc")
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        return np.zeros((0, NREG), "<u4")
    n = os.path.getsize(p) // (4 * NREG)
    return np.memmap(p, "<u4", "r", shape=(n, NREG))


def load_wr(d, cpu):
    p = os.path.join(d, f"arm{cpu}.wr")
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        return np.zeros(0, WR)
    return np.memmap(p, WR, "r", shape=(os.path.getsize(p) // WR.itemsize,))


def mode(cpsr):
    return cpsr & 0x1F


# ------------------------------------------------------------------ filters

def exc_lines(u, vec):
    """RTL exception-entry lines: the line before the IRQ vector, already in
    IRQ mode, with r14_irq = its pc + 4, entered from another mode."""
    if len(u) < 2:
        return np.zeros(0, np.int64)
    k = np.nonzero(u[1:, 0] == vec)[0]          # k: index of the line before the vector
    k = k[(mode(u[k, 1]) == 0x12) & (u[k, 16] == (u[k, 0] + 4) & 0xFFFFFFFF)]
    prev = np.where(k > 0, k - 1, k)
    k = k[(k == 0) | (mode(u[prev, 1]) != 0x12)]
    return k


def excursions(u, idx, vec):
    """IRQ excursions in the stream u[idx]: from a record at the vector to the
    instruction that leaves IRQ mode with a jump (SUBS pc / LDM ^), nested
    entries counted. Returns list of (start, end) positions in idx, inclusive."""
    pc, cpsr = u[idx, 0], u[idx, 1]
    starts = np.nonzero(pc == vec)[0]
    m = mode(cpsr)
    isz = np.where(cpsr & 0x20, 2, 4).astype(np.uint32)
    j = np.arange(1, len(idx) - 1)
    ends = j[(m[j - 1] == 0x12) & (m[j] != 0x12) & (pc[j + 1] != ((pc[j] + isz[j - 1]) & 0xFFFFFFFF))]
    ev = sorted([(int(s), 0) for s in starts] + [(int(e), 1) for e in ends])
    out, depth, cur = [], 0, 0
    for pos, kind in ev:
        if kind == 0:
            if depth == 0:
                cur = pos
            depth += 1
        elif depth:
            depth -= 1
            if depth == 0:
                out.append((cur, pos))
    if depth:
        out.append((cur, len(idx) - 1))        # trace ends inside an excursion
    return out


def collapse(u, idx, maxp=16):
    """Drop records equal (pc, cpsr, r0..r14) to the record p back, p <= maxp:
    a repeated cycle keeps its first period."""
    n = len(idx)
    drop = np.zeros(n, bool)
    for c0 in range(0, n, CHUNK):
        c1 = min(n, c0 + CHUNK)
        lo = max(0, c0 - maxp)
        rows = u[idx[lo:c1]]
        off = c0 - lo
        for p in range(1, maxp + 1):
            s = max(off, p)
            if s >= len(rows):
                continue
            eq = (rows[s:] == rows[s - p:len(rows) - p]).all(axis=1)
            drop[lo + s:c1] |= eq
    return idx[~drop]


# ------------------------------------------------------------------ compare

def first_diff(ua, ia, ub, ib, cols=slice(None)):
    n = min(len(ia), len(ib))
    for c0 in range(0, n, CHUNK):
        c1 = min(n, c0 + CHUNK)
        d = (ua[ia[c0:c1]][:, cols] != ub[ib[c0:c1]][:, cols]).any(axis=1)
        if d.any():
            return c0 + int(np.argmax(d))
    return None


def fmt_rec(u, idx, pos, other=None):
    r = u[idx[pos]]
    prev = u[idx[pos - 1]] if pos > 0 else None
    c = int(r[1])
    flags = "".join(f if c >> b & 1 else "-" for f, b in (("N", 31), ("Z", 30), ("C", 29), ("V", 28)))
    s = f"{int(idx[pos]):>10} {int(r[0]):08x} {c:08x} {MODES.get(c & 0x1F, '???')}{'T' if c & 0x20 else ' '}{'I' if c & 0x80 else ' '} {flags}"
    regs = []
    for i in range(15):
        changed = prev is None or r[2 + i] != prev[2 + i]
        bad = other is not None and r[2 + i] != other[2 + i]
        if changed or bad:
            regs.append(f"{'*' if bad else ''}r{i}={int(r[2 + i]):08x}")
    mark = ""
    if other is not None and (r[0] != other[0] or r[1] != other[1]):
        mark = " *pc/cpsr"
    return s + "  " + " ".join(regs) + mark


def report(name, la, lb, ua, ia, ub, ib, pos, ctx):
    print(f"  first divergence at {name} position {pos} (record {int(ia[pos]) if pos < len(ia) else '-'} "
          f"in A, {int(ib[pos]) if pos < len(ib) else '-'} in B); '*' marks differing fields")
    for lab, u, i, uo, io in ((la, ua, ia, ub, ib), (lb, ub, ib, ua, ia)):
        print(f"  {lab}:      record pc       cpsr     mode  flags  registers (changed)")
        for q in range(max(0, pos - ctx), min(len(i), pos + ctx // 2 + 1)):
            other = uo[io[q]] if q < len(io) else None
            print(("  >" if q == pos else "   ") + fmt_rec(u, i, q, other))


def compare_trc(cpu, ua, ub, args):
    over = args.vec9 if cpu == 9 else args.vec7
    vec = VEC[cpu] if over is None else over
    ia, ib = np.arange(len(ua)), np.arange(len(ub))
    if not args.keep_exc:
        for lab, u, which in (("A", ua, "a"), ("B", ub, "b")):
            k = exc_lines(u, vec)
            if len(k):
                print(f"  {lab}: dropped {len(k)} exception-entry lines")
                if which == "a":
                    ia = np.setdiff1d(ia, k, assume_unique=True)
                else:
                    ib = np.setdiff1d(ib, k, assume_unique=True)
    ok = True
    xa = xb = []
    if args.irq_align:
        xa, xb = excursions(ua, ia, vec), excursions(ub, ib, vec)
        print(f"  IRQ excursions: A {len(xa)}, B {len(xb)}")

        def split(idx, xs):
            keep = np.ones(len(idx), bool)
            segs = []
            for s, e in xs:
                keep[s:e + 1] = False
                segs.append(idx[s:e + 1])
            return idx[keep], segs
        ia, sa = split(ia, xa)
        ib, sb = split(ib, xb)
    if args.collapse_loops:
        na, nb = len(ia), len(ib)
        ia, ib = collapse(ua, ia), collapse(ub, ib)
        print(f"  collapsed loops: A {na} -> {len(ia)}, B {nb} -> {len(ib)}")
    pos = first_diff(ua, ia, ub, ib)
    if pos is not None and args.resync:
        # timing-dependent divergence (one side polls a register longer): find
        # the other side's record further on in one stream and skip to it
        nres = skipped_a = skipped_b = 0
        while pos is not None and nres < args.resync:
            w = args.resync_window
            ra, rb = ua[ia[pos]], ub[ib[pos]]
            cb = ub[ib[pos:pos + w]]
            hb = np.nonzero((cb == ra).all(axis=1))[0]
            ca = ua[ia[pos:pos + w]]
            ha = np.nonzero((ca == rb).all(axis=1))[0]
            if len(hb) and (not len(ha) or hb[0] <= ha[0]):
                ib = np.concatenate([ib[:pos], ib[pos + hb[0]:]]); skipped_b += int(hb[0])
            elif len(ha):
                ia = np.concatenate([ia[:pos], ia[pos + ha[0]:]]); skipped_a += int(ha[0])
            else:
                break
            nres += 1
            p2 = first_diff(ua, ia[pos:], ub, ib[pos:])
            pos = None if p2 is None else pos + p2
        print(f"  resync: {nres} skips ({skipped_a} records of A, {skipped_b} of B)")
    n = min(len(ia), len(ib))
    if pos is None:
        print(f"  main stream: {n} records match (A {len(ia)}, B {len(ib)})")
        if len(ia) != len(ib) and args.strict_length:
            print("  length differs (--strict-length)")
            ok = False
    else:
        print(f"  main stream: DIVERGES after {pos} matching records")
        report("main", "A", "B", ua, ia, ub, ib, pos, args.context)
        ok = False
    if args.irq_align:
        cols = slice(None) if args.irq_regs else slice(0, 2)
        nx = min(len(sa), len(sb))
        bad = None
        for k in range(nx):
            a, b = sa[k], sb[k]
            if args.collapse_loops:
                a, b = collapse(ua, a), collapse(ub, b)
            p = first_diff(ua, a, ub, b, cols)
            if p is None and len(a) != len(b):
                p = min(len(a), len(b))
            if p is not None:
                bad = (k, a, b, p)
                break
        if bad is None:
            print(f"  IRQ excursions: {nx} match ({'pc,cpsr,regs' if args.irq_regs else 'pc,cpsr'})")
            if len(sa) != len(sb) and args.strict_length:
                ok = False
        else:
            k, a, b, p = bad
            print(f"  IRQ excursion {k} DIVERGES (lengths A {len(a)}, B {len(b)}; A starts at record {int(a[0])}, B at {int(b[0])})")
            report(f"excursion {k}", "A", "B", ua, a, ub, b, p, args.context)
            ok = False
    return ok


def parse_ranges(specs):
    out = []
    for s in specs or []:
        lo, hi = s.split("-")
        out.append((int(lo, 0), int(hi, 0)))
    return out


def compare_wr(cpu, wa, wb, args):
    ranges = parse_ranges(args.ignore_wr)

    def keep(w):
        m = np.ones(len(w), bool)
        for lo, hi in ranges:
            m &= ~((w["addr"] >= lo) & (w["addr"] <= hi))
        return np.nonzero(m)[0]
    ia, ib = keep(wa), keep(wb)
    n = min(len(ia), len(ib))
    fields = ("addr", "val", "size", "src")
    pos = None
    for c0 in range(0, n, CHUNK):
        c1 = min(n, c0 + CHUNK)
        a, b = wa[ia[c0:c1]], wb[ib[c0:c1]]
        d = np.zeros(c1 - c0, bool)
        for f in fields:
            d |= a[f] != b[f]
        if d.any():
            pos = c0 + int(np.argmax(d))
            break
    if pos is None:
        print(f"  writes: {n} match (A {len(ia)}, B {len(ib)}{', ' + str(len(wa) - len(ia)) + ' A ignored' if ranges else ''})")
        return not (len(ia) != len(ib) and args.strict_length)
    print(f"  writes: DIVERGE after {pos} matching writes")
    for lab, w, i, wo, io in (("A", wa, ia, wb, ib), ("B", wb, ib, wa, ia)):
        print(f"  {lab}:   write#     addr       value  size src")
        for q in range(max(0, pos - args.context), min(len(i), pos + args.context // 2 + 1)):
            r = w[i[q]]
            mark = ""
            if q < len(io):
                o = wo[io[q]]
                if any(r[f] != o[f] for f in fields):
                    mark = "  *"
            print(f"  {'>' if q == pos else ' '}{int(i[q]):>9} {int(r['addr']):08x} {int(r['val']):08x} {int(r['size'])}    "
                  f"{'dma' if r['src'] else 'cpu'}{mark}")
    return False


def dump(d, cpu, start, count):
    u = load_trc(d, cpu)
    idx = np.arange(len(u))
    for q in range(start, min(len(u), start + count)):
        print(fmt_rec(u, idx, q))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a", help="trace dir A (e.g. melonDS)")
    ap.add_argument("b", nargs="?", help="trace dir B (e.g. RTL)")
    ap.add_argument("--cpu", choices=["9", "7"], action="append", help="only this CPU (repeatable; default both)")
    ap.add_argument("--irq-align", action="store_true", help="compare main stream and IRQ excursions separately")
    ap.add_argument("--irq-regs", action="store_true", help="with --irq-align: compare registers inside excursions too")
    ap.add_argument("--collapse-loops", action="store_true", help="collapse repeating cycles (period <= 16)")
    ap.add_argument("--ignore-wr", action="append", metavar="LO-HI", help="ignore writes to this address range")
    ap.add_argument("--no-wr", action="store_true", help="skip the write comparison")
    ap.add_argument("--keep-exc", action="store_true", help="do not drop RTL exception-entry lines")
    ap.add_argument("--strict-length", action="store_true", help="a length difference is a divergence")
    ap.add_argument("--vec9", type=lambda s: int(s, 0), help="ARM9 IRQ vector (default 0xFFFF0018)")
    ap.add_argument("--vec7", type=lambda s: int(s, 0), help="ARM7 IRQ vector (default 0x18)")
    ap.add_argument("--context", type=int, default=10, help="records of context (default 10)")
    ap.add_argument("--resync", type=int, default=0, metavar="N",
                    help="on a divergence, skip ahead in one stream to the other's record (at most N times)")
    ap.add_argument("--resync-window", type=int, default=200000, help="records searched per resync")
    ap.add_argument("--cpsr-mask", type=lambda s: int(s, 0), default=0xFFFFFFBF,
                    help="CPSR bits compared (default all but F: melonDS sets F on IRQ entry, ARM does not)")
    ap.add_argument("--dump", nargs=2, type=int, metavar=("START", "COUNT"), help="print records of dir A and exit")
    args = ap.parse_args()
    cpus = [int(c) for c in (args.cpu or ["9", "7"])]
    if args.dump:
        for c in cpus:
            print(f"ARM{c}:")
            dump(args.a, c, *args.dump)
        return 0
    if not args.b:
        ap.error("need two trace dirs (or --dump)")
    ok = True
    for c in cpus:
        print(f"ARM{c}:")
        ua, ub = load_trc(args.a, c), load_trc(args.b, c)
        if args.cpsr_mask != 0xFFFFFFFF:
            # known differences, e.g. melonDS sets F on IRQ entry (ARM's IRQ entry leaves it)
            ua, ub = np.array(ua), np.array(ub)
            ua[:, 1] &= args.cpsr_mask
            ub[:, 1] &= args.cpsr_mask
        ok &= compare_trc(c, ua, ub, args)
        if not args.no_wr:
            ok &= compare_wr(c, load_wr(args.a, c), load_wr(args.b, c), args)
    print("MATCH" if ok else "DIVERGENCE")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
