#!/usr/bin/env python3
"""Design A study, milestone 1: pack the assembled microcode into 2-lane bundles inside basic blocks
(docs/geometry-engine.md "faster engine study") and weigh the result by measured execution counts.

  bundle.py PROF.txt [PROF.txt ...]

PROF.txt: tb_geom --prof-dump (address, executions; 4095 = idle).

Machine: two ALU lanes, each with its own R (an ALU op of lane L writes R[L]; a reader names the
lane), one MAC, one divider start, one output, one register-file write, four register-file reads,
one index-register op and one branch per bundle. Dependencies come from asm.py's hazard model
(effects(): register file, accumulator, flags, divider, outputs, sort tables, with their latencies)
plus R: an R operand is ready one bundle after its producer, an issue-time R read (SETX, LCR, BIT)
two. A lane's R cannot be overwritten while it has readers not yet placed. Branches stay last.
Hazard-padding NOPs are dropped (the schedule keeps the latencies); the divider and output wait
loops keep their measured executions.
"""
import os, sys, collections, contextlib, io
os.environ.setdefault('GX_USORT', '1')
sys.path.insert(0, os.path.dirname(__file__))
with contextlib.redirect_stdout(io.StringIO()):
    import ucode as U
import asm
E = asm.E
P = U.P_
P.assemble()
AT = P.at
XS, YS, AOP, X, NX, C = E['XS'], E['YS'], E['AOP'], E['X'], E['NX'], E['C']


def alu_op(f):
    return not (f.get('aop', AOP['PASSX']) == AOP['PASSX'] and f.get('xs', XS['R']) == XS['R'] and 'ys' not in f)


def reads_r(f):
    if f.get('xop') in (X['SETX'], X['LCR']) or (f.get('nx') in (NX['JC'], NX['JNC']) and f.get('cond') == C['BIT']):
        return 2
    a = alu_op(f)
    if a and (f.get('xs') == XS['R'] or f.get('ys') == YS['R']):
        return 1
    if f.get('acc') and (f.get('ma') == E['MA']['R'] or f.get('mb') == E['MB']['R']):
        return 1
    if not a and (f.get('we') or 'out' in f):
        return 1                        # writes or outputs the R it passes
    return 0


def rf_reads(f):
    n = 0
    xs, ys, acc = f.get('xs', 0), f.get('ys', 0), f.get('acc', 0)
    nop = not alu_op(f)
    if (xs == XS['QA'] and not nop) or (acc and f.get('ma', 0) == E['MA']['QA']):
        n += 1
    if (ys == YS['QB'] and not nop) or (acc and f.get('mb', 0) == E['MB']['QB']) or (f.get('div', 0) and ys == YS['QB']):
        n += 1
    return n


def is_wait(a, f):
    return f.get('nx') in (NX['JC'], NX['JNC']) and f.get('cond') in (C['DBUSY'], C['OBUSY']) \
        and P.resolve(f['tgt']) == a and not alu_op(f) and not f.get('we') and not f.get('acc')


def is_empty(f):
    keys = set(f) - {'nh', 'xs', 'aop'}
    return not alu_op(f) and not keys


def blocks():
    targets = set()
    for a, it in AT.items():
        f = it.f
        if 'tgt' in f:
            targets.add(P.resolve(f['tgt']))
        if f.get('nx') == NX['CALL']:
            targets.add(a + 1)
    targets |= set(range(0, 39))
    cur = []
    for a in sorted(AT):
        if a in targets and cur:
            yield cur; cur = []
        cur.append(a)
        if AT[a].f.get('nx', 0) != NX['NEXT'] or is_wait(a, AT[a].f):
            yield cur; cur = []
    if cur:
        yield cur


def schedule(addrs, lanes=2, rdports=4):
    """bundles for one basic block"""
    ins = [a for a in addrs if not is_empty(AT[a].f)]
    if not ins:
        return 0
    eff = {a: asm.Prog.effects(AT[a]) for a in ins}
    place = {}
    use = collections.defaultdict(collections.Counter)
    lane_last = {}                      # lane -> (producer addr, bundle)
    lane_of = {}
    pending = collections.Counter()     # producer -> readers not yet placed
    producer = {}
    last_prod = None
    for a in ins:                       # R producers in program order
        f = AT[a].f
        if reads_r(f):
            producer[a] = last_prod
            if last_prod is not None:
                pending[last_prod] += 1
        if alu_op(f):
            last_prod = a
    ctrl_at = 0
    for idx, a in enumerate(ins):
        f = AT[a].f
        reads, writes = eff[a]
        t = 0
        for b in ins[:idx]:
            rb, wb = eff[b]
            for wk, lat in wb:
                if any(asm.Prog.conflict(r, wk) for r in reads):
                    t = max(t, place[b] + lat)
                if any(asm.Prog.conflict(w2, wk) or asm.Prog.conflict(wk, w2) for w2, _ in writes):
                    t = max(t, place[b] + 1)
            for r in rb:
                if any(asm.Prog.conflict(r, w2) for w2, _ in writes):
                    t = max(t, place[b])
        rr = reads_r(f)
        p = producer.get(a)
        if rr and p is not None:
            t = max(t, place[p] + rr)
        isctrl = f.get('nx', 0) != NX['NEXT']
        if isctrl:
            t = max(t, max(place.values(), default=0))
        alu = alu_op(f)
        nr = rf_reads(f)
        while True:
            u = use[t]
            ok = u['rd'] + nr <= rdports and (not f.get('we') or u['we'] < 1) and (not f.get('acc') or u['mac'] < 1) \
                and (not f.get('div') or u['div'] < 1) and ('out' not in f or u['out'] < 1) \
                and (not f.get('xop') or u['xop'] < 1) and (not isctrl or u['br'] < 1)
            lane = None
            if ok and rr and p is not None:
                # the producer's lane must still hold its R at t (no other writer in it since)
                lp = lane_of.get(p)
                if lp is not None and lane_last.get(lp, (None, -1))[0] != p:
                    t = place[p] + 1        # overwritten: R would have to be re-read; force order
            if ok and alu:
                for L in range(lanes):
                    cur = lane_last.get(L)
                    if u[('alu', L)] == 0 and (cur is None or pending[cur[0]] == 0 or cur[1] < t and pending[cur[0]] == (1 if producer.get(a) == cur[0] else 0)):
                        lane = L
                        break
                ok = lane is not None
            if ok:
                break
            t += 1
        place[a] = t
        u = use[t]
        u['rd'] += nr
        if f.get('we'): u['we'] += 1
        if f.get('acc'): u['mac'] += 1
        if f.get('div'): u['div'] += 1
        if 'out' in f: u['out'] += 1
        if f.get('xop'): u['xop'] += 1
        if isctrl: u['br'] += 1
        if rr and p is not None:
            pending[p] -= 1
        if alu:
            u[('alu', lane)] += 1
            lane_of[a] = lane
            lane_last[lane] = (a, t)
    return max(place.values()) + 1


def main():
    blks = list(blocks())
    newlen = {}
    for b in blks:
        newlen[b[0]] = schedule(b)
    for path in sys.argv[1:]:
        cnt = collections.Counter()
        for line in open(path):
            a, n = map(int, line.split())
            cnt[a] = n
        busy = sum(n for a, n in cnt.items() if a != 4095)
        new = 0
        old = 0
        for b in blks:
            e = cnt.get(b[0], 0)
            if not e:
                continue
            if len(b) == 1 and is_wait(b[0], AT[b[0]].f):
                new += e; old += e
                continue
            new += e * newlen[b[0]]
            old += e * len(b)
        print(f'{os.path.basename(path)}: measured busy {busy}, block model today {old}, 2-lane bundles {new}, x{old / new:.2f}')


if __name__ == '__main__':
    main()


# ---------------------------------------------------------------- milestone 1b: superblocks
# A superblock follows unconditional flow (fall-through, JMP, CALL into the routine, RET back to a
# known call site) from a head and ends at a conditional branch, DISP, DJNZ, a wait loop or a RET
# whose call site it doesn't know. Its CALL/JMP/RET disappear (layout, inlining); the scheduler
# packs it as one block. Heads: where a superblock can start dynamically.

def is_cond_end(a, f):
    nx = f.get('nx', 0)
    return nx in (NX['JC'], NX['JNC'], NX['DJNZ'], NX['DISP']) or is_wait(a, f)


def superblock(h, limit=96):
    path, stack, a = [], [], h
    while a in AT and len(path) < limit:
        f = AT[a].f
        path.append(a)
        nx = f.get('nx', 0)
        if is_cond_end(a, f):
            break
        if nx == NX['JMP']:
            a = P.resolve(f['tgt'])
        elif nx == NX['CALL']:
            stack.append(a + 1); a = P.resolve(f['tgt'])
        elif nx == NX['RET']:
            if not stack:
                break
            a = stack.pop()
        else:
            a = a + 1
    return path


def schedule_sb(path, lanes=2, rdports=4):
    """bundles for a superblock: its CALL/JMP/RET (not the final branch) carry no branch"""
    saved = {}
    for a in path[:-1]:
        f = AT[a].f
        if f.get('nx', 0) in (NX['JMP'], NX['CALL'], NX['RET']):
            saved[a] = (f.get('nx'), f.get('tgt'))
            f.pop('nx'); f.pop('tgt', None)
    try:
        # the same address can occur twice (a loop body inlined twice): schedule a copy list
        return schedule_list(path, lanes, rdports)
    finally:
        for a, (nx, tgt) in saved.items():
            AT[a].f['nx'] = nx
            if tgt is not None:
                AT[a].f['tgt'] = tgt


def schedule_list(path, lanes, rdports):
    seen = set()
    if len(set(path)) == len(path):
        return schedule(path, lanes, rdports)
    # repeated addresses: schedule the first occurrence's prefix and the rest separately (rare)
    cut = next(i for i, a in enumerate(path) if a in seen or seen.add(a))
    return schedule(path[:cut], lanes, rdports) + schedule(path[cut:], lanes, rdports)


def trace_starts(pct_path):
    """superblock starts in a --pct trace (call stack tracked), and wait-loop cycles"""
    import struct
    b = open(pct_path, 'rb').read()
    n = len(b) // 8
    v = struct.unpack(f'<{4 * n}H', b)
    starts = collections.Counter()
    waits = 0
    stack = []
    new = True
    prev = None
    for i in range(n):
        a = v[4 * i]
        if a not in AT:
            continue
        f = AT[a].f
        if prev == a and is_wait(a, f):
            waits += 1
            continue
        prev = a
        if new:
            starts[a] += 1
            new = False
        nx = f.get('nx', 0)
        if is_cond_end(a, f):
            new = True
        elif nx == NX['CALL']:
            stack.append(a + 1)
        elif nx == NX['RET']:
            if stack:
                stack.pop()
            else:
                new = True
    return starts, waits, n


def main_sb(paths):
    cache = {}
    for pct in paths:
        starts, waits, busy = trace_starts(pct)
        cyc = waits
        for h, e in starts.items():
            if h not in cache:
                sb = superblock(h)
                cache[h] = (schedule_sb(sb, 2, 4), schedule_sb(sb, 1, 2), len(sb))
            cyc += e * cache[h][0]
        print(f'{os.path.basename(pct)}: busy {busy}, superblocks 2-lane {cyc}, x{busy / cyc:.2f}')
    # control store: every superblock that occurs, scheduled once
    print(f'control store: {sum(c[0] for c in cache.values())} bundles for {len(cache)} superblocks seen '
          f'(today {len(AT)} words)')
