#!/usr/bin/env python3
"""Throughput model of one context of the barrel pipeline (arm_core.sv).

Replays a retired-instruction trace through a timing model of fetch, the
instruction buffer, D-stage issue and redirects, in two modes:

  alt   today: the context issues on every other cycle (the other context
        holds the other slots), so its uops are always two cycles apart
  solo  the other context is halted and this one issues every cycle; the
        two-apart spacing no longer hides hazards, so D interlocks on them

Stage offsets from D (F=-3 .. WB2=+5) follow the 9-stage pipeline:
F F2 PD D E1 E2 E3 WB WB2. Timing rules (cycles between the D slots of a
producer uop and its consumer):
  ALU result -> operand        2   (E3 result register bypassed into E2;
                                    distance 3 needs a WB2 bypass in solo)
  load / MRC data -> operand   4   (data in WB, written in WB2)
  flags -> condition / carry   2   (written in WB, checked in E3)
  temporaries, product         2   (written in WB, read in E3)
Redirects refetch from: PD (predicted-taken branches), E3 (mispredictions,
Thumb BL/BLX suffix, SWI, exceptions), WB (ALU writes to the PC, BX, MSR),
WB2 (loads into the PC).

Memory is assumed to answer at once (cache/TCM hits); misses cost the same
cycles in both modes and are added separately (see docs/arm-pipeline.md).

Inputs:
  --ops FILE        testbench +opsN output: "pc word cpsr cycle" per line
  --melon DIR       census --trace-dir with --trace-op: arm9.trc + arm9.op
                    (+ irq9.txt)
"""
import argparse
import struct
import sys

# uop kinds of a register write
ALU, LOAD = 1, 2
# redirect stages
NONE, PD, E3, WB, WB2 = 0, 1, 2, 3, 4


class Uop:
    __slots__ = ("rd", "wr", "wkind", "rflags", "sflags", "chain")

    def __init__(self, rd=(), wr=(), wkind=ALU, rflags=False, sflags=False, chain=False):
        self.rd, self.wr, self.wkind = rd, wr, wkind
        self.rflags, self.sflags, self.chain = rflags, sflags, chain


def regs(mask):
    return tuple(r for r in range(16) if mask >> r & 1)


def cond_pass(cond, f):
    n, z, c, v = f >> 31 & 1, f >> 30 & 1, f >> 29 & 1, f >> 28 & 1
    return [z, not z, c, not c, n, not n, v, not v, c and not z, not c or z,
            n == v, n != v, not z and n == v, z or n != v, True, True][cond]


def dec_arm(w, flags):
    """-> (uops, redirect kind, is_branch_imm, branch_target_offset)"""
    cond = w >> 28
    rflag = cond != 14
    rn, rd, rs, rm = w >> 16 & 15, w >> 12 & 15, w >> 8 & 15, w & 15
    S = bool(w >> 20 & 1)
    if cond == 15:
        if (w >> 25 & 7) == 5:              # BLX imm
            return [Uop(wr=(14,))], PD, True, None
        return [Uop()], NONE, False, None    # PLD etc.
    t = w >> 25 & 7
    if t in (0, 1):
        if t == 0 and (w & 0x0FC000F0) == 0x00000090:          # MUL/MLA
            # (MUL: Rd is bits 19:16, the accumulator Rn bits 15:12)
            u2 = Uop(rd=(rd,) if w >> 21 & 1 else (), wr=(rn,), sflags=S, chain=True)
            return [Uop(rd=(rs, rm), rflags=rflag), u2], NONE, False, None
        if t == 0 and (w & 0x0F8000F0) == 0x00800090:          # long multiply
            acc = bool(w >> 21 & 1)
            return [Uop(rd=(rs, rm), rflags=rflag),
                    Uop(rd=(rd,) if acc else (), wr=(rd,), chain=True),
                    Uop(rd=(rn,) if acc else (), wr=(rn,), sflags=S, chain=True)], NONE, False, None
        if t == 0 and (w & 0x0FB00FF0) == 0x01000090:          # SWP
            return [Uop(rd=(rn,), rflags=rflag),
                    Uop(rd=(rn, rm), wr=(rd,), wkind=LOAD, chain=True)], NONE, False, None
        if t == 0 and (w & 0x0FFFFFD0) == 0x012FFF10:          # BX / BLX reg
            return [Uop(rd=(rm,), wr=(14,) if w >> 5 & 1 else (), rflags=rflag)], WB, False, None
        if t == 0 and (w & 0x0FFF0FF0) == 0x016F0F10:          # CLZ
            return [Uop(rd=(rm,), wr=(rd,), rflags=rflag)], NONE, False, None
        if t == 0 and (w & 0x0F900FF0) == 0x01000050:          # QADD etc.
            return [Uop(rd=(rn, rm), wr=(rd,), rflags=rflag)], NONE, False, None
        if t == 0 and (w & 0x0F900090) == 0x01000080:          # SMLAxy family
            op = w >> 21 & 3
            hi, lo = w >> 16 & 15, w >> 12 & 15
            if op == 2:                                        # SMLALxy
                return [Uop(rd=(rs, rm), rflags=rflag), Uop(rd=(lo,), wr=(lo,), chain=True),
                        Uop(rd=(hi,), wr=(hi,), chain=True)], NONE, False, None
            acc = op == 0 or (op == 1 and not (w >> 5 & 1))
            return [Uop(rd=(rs, rm), rflags=rflag),
                    Uop(rd=(lo,) if acc else (), wr=(hi,), chain=True)], NONE, False, None
        if t == 0 and (w & 0x0E000090) == 0x00000090 and (w >> 5 & 3):   # halfword / LDRD
            L, P, Wb, I = w >> 20 & 1, w >> 24 & 1, w >> 21 & 1, w >> 22 & 1
            sh = w >> 5 & 3
            src = (rn,) if I else (rn, rm)
            wb = (not P) or Wb
            if L:
                us = []
                if wb:
                    us.append(Uop(rd=src, wr=(rn,), rflags=rflag))
                us.append(Uop(rd=src, wr=(rd,), wkind=LOAD, rflags=rflag, chain=wb))
                return us, (WB2 if rd == 15 else NONE), False, None
            if sh == 2:                                        # LDRD
                us = [Uop(rd=src, wr=(rn,) if wb else (), rflags=rflag),
                      Uop(rd=src, wr=(rd,), wkind=LOAD, chain=True),
                      Uop(rd=src, wr=((rd + 1) & 15,), wkind=LOAD, chain=True)]
                return us, NONE, False, None
            if sh == 3:                                        # STRD
                return [Uop(rd=src + (rd,), wr=(rn,) if wb else (), rflags=rflag),
                        Uop(rd=((rd + 1) & 15,), chain=True)], NONE, False, None
            return [Uop(rd=src + (rd,), wr=(rn,) if wb else (), rflags=rflag)], NONE, False, None
        if t == 0 and (w & 0x0FBF0FFF) == 0x010F0000:          # MRS
            return [Uop(wr=(rd,), rflags=True)], NONE, False, None
        if (t == 0 and (w & 0x0FB0FFF0) == 0x0120F000) or (t == 1 and (w & 0x0FB0F000) == 0x0320F000):
            spsr = w >> 22 & 1                                 # MSR
            return [Uop(rd=(rm,) if t == 0 else (), sflags=True, rflags=rflag)], \
                (NONE if spsr else WB), False, None
        # data processing
        op = w >> 21 & 15
        rds = []
        if op not in (13, 15):
            rds.append(rn)
        regshift = t == 0 and (w >> 4 & 1)
        if t == 0:
            rds.append(rm)
        rf = rflag or op in (5, 6, 7) or (t == 0 and not regshift and (w >> 5 & 3) == 3 and (w >> 7 & 31) == 0)
        wr = () if op in (8, 9, 10, 11) else (rd,)
        last = Uop(rd=tuple(rds), wr=wr, rflags=rf, sflags=S or op in (8, 9, 10, 11))
        red = WB if (wr == (15,)) else NONE
        if regshift:
            last.chain = True
            return [Uop(rd=(rs,), rflags=rflag), last], red, False, None
        return [last], red, False, None
    if t in (2, 3):                                            # LDR/STR
        if t == 3 and (w >> 4 & 1):
            return [Uop()], E3, False, None                     # undefined
        L, P, Wb = w >> 20 & 1, w >> 24 & 1, w >> 21 & 1
        src = (rn,) if t == 2 else (rn, rm)
        wb = (not P) or Wb
        if L:
            us = []
            if wb:
                us.append(Uop(rd=src, wr=(rn,), rflags=rflag))
            us.append(Uop(rd=src, wr=(rd,), wkind=LOAD, rflags=rflag, chain=wb))
            return us, (WB2 if rd == 15 else NONE), False, None
        return [Uop(rd=src + (rd,), wr=(rn,) if wb else (), rflags=rflag)], NONE, False, None
    if t == 4:                                                 # LDM/STM
        L, Wb = w >> 20 & 1, w >> 21 & 1
        lst = regs(w & 0xFFFF)
        us = [Uop(rd=(rn,), wr=(rn,) if Wb else (), rflags=rflag)]
        for r in lst:
            us.append(Uop(wr=(r,), wkind=LOAD, chain=True) if L else Uop(rd=(r,), chain=True))
        return us, (WB2 if L and 15 in lst else NONE), False, None
    if t == 5:                                                 # B / BL
        off = ((w & 0xFFFFFF) ^ 0x800000) - 0x800000
        return [Uop(wr=(14,) if w >> 24 & 1 else (), rflags=rflag)], NONE, True, off * 4 + 8
    if t == 6:
        return [Uop(rd=(rn,), rflags=rflag)], NONE, False, None
    if w >> 24 & 1:                                            # SWI
        return [Uop(rflags=rflag)], E3, False, None
    if w >> 4 & 1 and w >> 20 & 1:                             # MRC
        return [Uop(wr=(rd,), wkind=LOAD, rflags=rflag)], NONE, False, None
    return [Uop(rd=(rd,), rflags=rflag)], NONE, False, None    # MCR / CDP


def dec_thumb(h):
    top = h >> 11
    r0, r3, r6, r8 = h & 7, h >> 3 & 7, h >> 6 & 7, h >> 8 & 7
    if top < 3:                                                # shift imm
        return [Uop(rd=(r3,), wr=(r0,), sflags=True)], NONE, False, None
    if top == 3:                                               # add/sub
        return [Uop(rd=(r3,) if h >> 10 & 1 else (r3, r6), wr=(r0,), sflags=True)], NONE, False, None
    if top < 8:                                                # mov/cmp/add/sub imm8
        op = top & 3
        return [Uop(rd=() if op == 0 else (r8,), wr=() if op == 1 else (r8,), sflags=True)], NONE, False, None
    if (h >> 10) == 0x10:                                      # ALU
        op = h >> 6 & 15
        if op in (2, 3, 4, 7):                                 # shift by register
            return [Uop(rd=(r3,)), Uop(rd=(r0,), wr=(r0,), sflags=True, rflags=True, chain=True)], NONE, False, None
        if op == 13:                                           # MUL
            return [Uop(rd=(r0, r3)), Uop(wr=(r0,), sflags=True, chain=True)], NONE, False, None
        rds = (r3,) if op in (9, 15) else (r0, r3)
        wr = () if op in (8, 10, 11) else (r0,)
        return [Uop(rd=rds, wr=wr, sflags=True, rflags=op in (5, 6))], NONE, False, None
    if (h >> 10) == 0x11:                                      # hi register ops / BX
        op = h >> 8 & 3
        rd = r0 | (h >> 4 & 8)
        rm = h >> 3 & 15
        if op == 3:
            return [Uop(rd=(rm,), wr=(14,) if h >> 7 & 1 else ())], WB, False, None
        if op == 1:
            return [Uop(rd=(rd, rm), sflags=True)], NONE, False, None
        u = Uop(rd=(rd, rm) if op == 0 else (rm,), wr=(rd,))
        return [u], (WB if rd == 15 else NONE), False, None
    if top == 9:                                               # LDR pc-relative
        return [Uop(wr=(r8,), wkind=LOAD)], NONE, False, None
    if (h >> 12) == 5:                                         # load/store register offset
        op = h >> 9 & 7
        if op in (0, 1, 2):
            return [Uop(rd=(r3, r6, r0))], NONE, False, None
        return [Uop(rd=(r3, r6), wr=(r0,), wkind=LOAD)], NONE, False, None
    if (h >> 13) == 3 or (h >> 12) == 8:                       # load/store imm5, halfword
        if h >> 11 & 1:
            return [Uop(rd=(r3,), wr=(r0,), wkind=LOAD)], NONE, False, None
        return [Uop(rd=(r3, r0))], NONE, False, None
    if (h >> 12) == 9:                                         # SP-relative
        if h >> 11 & 1:
            return [Uop(rd=(13,), wr=(r8,), wkind=LOAD)], NONE, False, None
        return [Uop(rd=(13, r8))], NONE, False, None
    if (h >> 12) == 10:                                        # ADD Rd, PC/SP
        return [Uop(rd=(13,) if h >> 11 & 1 else (), wr=(r8,))], NONE, False, None
    if (h >> 12) == 11:
        if (h >> 8) == 0xB0:                                   # ADD SP, imm
            return [Uop(rd=(13,), wr=(13,))], NONE, False, None
        if (h >> 9 & 0x7B) == 0x5A:                            # PUSH / POP
            pop = h >> 11 & 1
            lst = regs(h & 0xFF) + (((15 if pop else 14),) if h >> 8 & 1 else ())
            us = [Uop(rd=(13,), wr=(13,))]
            for r in lst:
                us.append(Uop(wr=(r,), wkind=LOAD, chain=True) if pop else Uop(rd=(r,), chain=True))
            return us, (WB2 if pop and 15 in lst else NONE), False, None
        return [Uop()], NONE, False, None
    if (h >> 12) == 12:                                        # LDMIA/STMIA
        lst = regs(h & 0xFF)
        L = h >> 11 & 1
        us = [Uop(rd=(r8,), wr=(r8,))]
        for r in lst:
            us.append(Uop(wr=(r,), wkind=LOAD, chain=True) if L else Uop(rd=(r,), chain=True))
        return us, NONE, False, None
    if (h >> 12) == 13:                                        # Bcc / SWI
        if r8 == 15:
            return [Uop()], E3, False, None
        off = ((h & 0xFF) ^ 0x80) - 0x80
        return [Uop(rflags=True)], NONE, True, off * 2 + 4
    if top == 28:                                              # B
        off = ((h & 0x7FF) ^ 0x400) - 0x400
        return [Uop()], NONE, True, off * 2 + 4
    if top == 30:                                              # BL prefix
        return [Uop(wr=(14,))], NONE, False, None
    if top in (29, 31):                                        # BL / BLX suffix
        return [Uop(rd=(14,), wr=(14,))], E3, False, None
    return [Uop()], NONE, False, None


def load_ops(path):
    recs = []
    for line in open(path):
        p = line.split()
        recs.append((int(p[0], 16), int(p[1], 16), int(p[2], 16), int(p[3]) if len(p) > 3 else 0))
    return recs


def load_melon(d, limit=None):
    trc = open(d + "/arm9.trc", "rb").read()
    op = open(d + "/arm9.op", "rb").read()
    n = len(op) // 4
    if limit:
        n = min(n, limit)
    irq = set()
    try:
        for line in open(d + "/irq9.txt"):
            irq.add(int(line.split()[0]))
    except FileNotFoundError:
        pass
    recs = []
    for i in range(n):
        pc, cpsr = struct.unpack_from("<II", trc, i * 68)
        w = struct.unpack_from("<I", op, i * 4)[0]
        recs.append((pc, w, cpsr, 0))
    return recs, irq


def run(recs, mode, irq=frozenset(), ldm_bypass=False, low_half=False, bp="static",
        fuse_bl=False, ideal=False):
    """Returns (cycles, instructions, uops, stats).

    bp: "static" (today: unconditional and backward branches taken),
        "bimodal:N" (N 2-bit counters indexed by pc, read in PD),
        "perfect" (direction always right; targets still found in PD).
    fuse_bl: PD redirects a Thumb BL/BLX suffix (keeping the prefix's offset).
    ideal: solo with every bypass (upper bound of any back-to-back design):
        ALU, flag and temporary results usable by the next uop, loads after 2.
    """
    ctr = {}
    nbp = int(bp.split(":")[1]) if bp.startswith("bimodal") else 0
    alu_d = 1 if ideal else 2
    ld_d = 3 if ideal else 4
    solo = mode == "solo"
    step = 1 if solo else 2
    # alt: F on even cycles, D on odd ones
    def fslot(c):
        return c if solo or c % 2 == 0 else c + 1

    def dslot(c):
        return c if solo or c % 2 == 1 else c + 1

    regw = [(-100, ALU)] * 16        # last writer: (D cycle, kind)
    flagw = -100
    prev_d = -100                    # D cycle of the previous uop
    fetches = []                     # fetch cycles of recent instructions
    ends = []                        # last-uop D cycles of recent instructions
    block = 0                        # earliest fetch (redirect)
    nuops = 0
    st = {"redir_pd": 0, "redir_e3": 0, "redir_wb": 0, "redir_wb2": 0, "stall": 0}
    prev_cpsr = recs[0][2]
    thumb = bool(prev_cpsr >> 5 & 1)
    n = len(recs)
    last_f = -100
    for i in range(n):
        pc, word, cpsr, _ = recs[i]
        flags = prev_cpsr
        if thumb:
            # testbench: the memory word; melonDS: the halfword in bits 15:0
            h = word & 0xFFFF if low_half or not pc & 2 else word >> 16
            uops, red, isb, boff = dec_thumb(h)
            size = 2
            cond = (h >> 8 & 15) if (h >> 12) == 13 else 14
        else:
            uops, red, isb, boff = dec_arm(word, flags)
            size = 4
            cond = word >> 28
        nxt = recs[i + 1][0] if i + 1 < n else pc + size
        exc = (i + 1) in irq         # melonDS: the IRQ's first record is at the vector
        taken = nxt != pc + size
        # branch prediction (PD): unconditional, or backward conditional
        if isb:
            pred = cond in (14, 15) or boff < 0 if not thumb else (cond == 14 or boff < 0)
            if cond not in (14, 15) and boff is not None:
                if bp == "perfect":
                    pred = taken
                elif nbp:
                    k = (pc >> 1) % nbp
                    v = ctr.get(k, 2 if boff < 0 else 1)
                    pred = v >= 2
                    ctr[k] = min(3, v + 1) if taken else max(0, v - 1)
            if pred and taken:
                red = PD
            elif pred != taken:
                red = E3
            else:
                red = NONE
        elif red == WB or red == WB2:
            if not cond_pass(cond, flags) and not thumb:
                red = NONE
        if fuse_bl and thumb and red == E3 and not exc and (word & 0xFFFF if low_half or not pc & 2 else word >> 16) >> 11 in (29, 31):
            red = PD
        if exc or (taken and red == NONE):
            red = E3                 # exception / unexplained discontinuity

        # ---- fetch
        c = fslot(max(block, last_f + step))
        while True:
            # instructions in the buffer at cycle c, plus fetches in flight
            inbuf = 0
            for j in range(len(fetches) - 1, max(-1, len(fetches) - 6), -1):
                if fetches[j] + 3 <= c <= ends[j]:
                    inbuf += 1
            if solo:
                fl = sum(1 for j in range(max(0, len(fetches) - 3), len(fetches)) if c - 2 <= fetches[j] < c)
                ok = inbuf + fl <= 3
            else:
                pv = 1 if fetches and fetches[-1] == c - 2 else 0
                ok = inbuf + pv <= 1
            if ok:
                break
            c = fslot(c + 1)
        f = c
        last_f = f

        # ---- D issue
        d = dslot(max(f + 3, (ends[-1] + 1) if ends else 0))
        first = True
        for u in uops:
            e = d if first else dslot(max(d, prev_d + 1))
            need = e
            for r in u.rd:
                wc, k = regw[r]
                need = max(need, wc + (ld_d if k == LOAD else alu_d))
            if u.rflags:
                need = max(need, flagw + alu_d)
            if u.chain and not ldm_bypass and not ideal:
                need = max(need, prev_d + 2)
            need = dslot(need)
            st["stall"] += need - e if solo else (need - e) // 2
            for r in u.wr:
                regw[r] = (need, u.wkind)
            if u.sflags:
                flagw = need
            prev_d = need
            d = need
            first = False
            nuops += 1
        end = prev_d
        fetches.append(f)
        ends.append(end)
        if len(fetches) > 16:
            del fetches[:8]
            del ends[:8]

        # ---- redirect
        if red == PD:
            block = f + 2 + (1 if solo else 2)
            st["redir_pd"] += 1
        elif red == E3:
            block = end + 3 + (1 if solo else 2)
            st["redir_e3"] += 1
        elif red == WB:
            block = end + 4 + 1
            st["redir_wb"] += 1
        elif red == WB2:
            block = end + 5 + (1 if solo else 2)
            st["redir_wb2"] += 1
        if (cpsr >> 5 & 1) != thumb:
            thumb = bool(cpsr >> 5 & 1)
        prev_cpsr = cpsr
    cycles = ends[-1] + 5
    return cycles, n, nuops, st


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ops")
    ap.add_argument("--melon")
    ap.add_argument("--limit", type=int)
    a = ap.parse_args()
    irq = frozenset()
    if a.ops:
        recs = load_ops(a.ops)
        rtl = recs[-1][3] - recs[0][3]
    else:
        recs, irq = load_melon(a.melon, a.limit)
        rtl = None
    lh = not a.ops
    rows = [("alt (today)", dict(mode="alt")),
            ("solo", dict(mode="solo")),
            ("solo + LDM bypass", dict(mode="solo", ldm_bypass=True)),
            ("solo ideal", dict(mode="solo", ideal=True)),
            ("alt + BL in PD", dict(mode="alt", fuse_bl=True)),
            ("alt + BL + bimodal256", dict(mode="alt", fuse_bl=True, bp="bimodal:256")),
            ("alt + BL + perfect", dict(mode="alt", fuse_bl=True, bp="perfect")),
            ("solo + LDM + BL + bim256", dict(mode="solo", ldm_bypass=True, fuse_bl=True,
                                               bp="bimodal:256"))]
    base = None
    for name, kw in rows:
        r = run(recs, irq=irq, low_half=lh, **kw)
        if base is None:
            base = r[0]
            n, nu = r[1], r[2]
            print(f"instructions {n}, uops {nu} ({nu / n:.2f} per instruction)")
            if rtl:
                print(f"{'RTL (today)':26s} {rtl:9d} cycles  {nu / rtl:.3f} uops/cycle")
        print(f"{name:26s} {r[0]:9d} cycles  {nu / r[0]:.3f} uops/cycle  "
              f"speedup {base / r[0]:.3f}x  {r[3]}")


if __name__ == "__main__":
    main()
