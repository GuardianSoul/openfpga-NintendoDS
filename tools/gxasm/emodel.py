#!/usr/bin/env python3
"""Geometry engine design study: trace-driven schedule of the executed microinstructions
under other machine configurations (docs/geometry-engine.md "faster engine study").

  emodel.py TRACE.pct [TRACE.pct ...]

TRACE.pct: tb_geom --pct, the busy cycles' {upc, xr1, xr2, xr3} (u16 each).
"""
import os, sys, struct, collections
sys.path.insert(0, os.path.dirname(__file__))
os.environ['GX_USORT'] = '1'
import contextlib, io
with contextlib.redirect_stdout(io.StringIO()):
    import ucode as U
P = U.P_
P.assemble()
AT = P.at

XS_R, XS_ACCX, XS_Q = 1, 2, 4
YS_R = 1
AOP_PASSX = 14
NX_JC, NX_JNC, NX_CALL, NX_RET, NX_DISP, NX_DJNZ = 2, 3, 4, 5, 6, 7
C_DBUSY, C_OBUSY = 8, 9
DQB_BITS = {0: 10, 1: 16, 2: 32, 3: 64}


def decode(a):
    f = AT[a].f
    d = {}
    xs, ys, aop = f.get('xs', XS_R), f.get('ys', 3), f.get('aop', AOP_PASSX)
    nopalu = xs == XS_R and aop == AOP_PASSX and 'ys' not in f
    d['alu'] = not nopalu
    d['rdR'] = (xs == XS_R or ys == YS_R) and d['alu'] or f.get('xop') in (1, 4) or f.get('cond') == 4 \
        or (f.get('acc', 0) and (f.get('ma') == 1 or f.get('mb') == 1)) or (f.get('we') and nopalu) or ('out' in f and nopalu)
    d['ra'] = (f['ra'], f.get('rax', 0)) if 'ra' in f and (xs == 0 or f.get('acc', 0)) else None
    d['rb'] = (f['rb'], f.get('rbx', 0)) if 'rb' in f and (ys == 0 or f.get('acc', 0) or 'div' in f) else None
    d['we'] = (f['wa'], f.get('wx', 0)) if f.get('we') else None
    d['fl'] = bool(f.get('fl'))
    d['rdfl'] = f.get('nx') in (NX_JC, NX_JNC) and f.get('cond', 15) <= 3
    d['acc'] = f.get('acc', 0)
    d['raccx'] = xs == XS_ACCX and d['alu']
    d['rq'] = xs == XS_Q and d['alu']
    d['div'] = DQB_BITS[f.get('dqb', 0)] if f.get('div') else 0
    d['out'] = 'out' in f
    d['xop'] = f.get('xop', 0)
    d['xarg'] = f.get('xarg', 0)
    d['nx'] = f.get('nx', 0)
    d['cond'] = f.get('cond', 15)
    d['wait'] = d['nx'] in (NX_JC, NX_JNC) and d['cond'] in (C_DBUSY, C_OBUSY) and f.get('tgt') in (a, AT[a].labels[0] if AT[a].labels else None) \
        and not d['alu'] and d['we'] is None and not d['acc']
    d['empty'] = not (d['alu'] or d['we'] or d['acc'] or d['div'] or d['out'] or d['xop'] or d['nx'] or d['rdfl'])
    return d


DEC = {a: decode(a) for a in AT}


def addr(base_idx, xr):
    b, k = base_idx
    return (b + (xr[k - 1] if k else 0)) & 0x7FF


def schedule(trace, alus=1, macs=1, vec=1, rdports=2, wports=1, win=1, lat_rf=3, lat_fl=2, lat_acc=3,
             div_pipe=False, div_scale=1.0, pack_free=False, spec=False):
    """issue cycle per kept dynamic instruction; returns the schedule length"""
    ready = collections.defaultdict(int)      # resource name -> cycle its value is ready
    use = collections.defaultdict(lambda: collections.Counter())
    hist = collections.deque()                # issue cycles of the last `win` instructions
    barrier = 0
    last = 0
    div_free = 0
    macrun = 0
    for pc, xr in trace:
        d = DEC.get(pc)
        if d is None or d['empty'] or d['wait']:
            continue
        t = barrier
        if win and len(hist) >= win:
            t = max(t, hist[0])
        if d['rdR']: t = max(t, ready['R'])
        for p in ('ra', 'rb'):
            if d[p]: t = max(t, ready[('rf', addr(d[p], xr))])
        if d['rdfl']: t = max(t, ready['fl'])
        if d['raccx']: t = max(t, ready['accx'])
        if d['acc'] and d['acc'] != 1: t = max(t, ready['acc'])
        if d['rq']: t = max(t, ready['q'])
        for k in (1, 2, 3):
            if (d['ra'] and d['ra'][1] == k) or (d['rb'] and d['rb'][1] == k) or (d['we'] and d['we'][1] == k):
                t = max(t, ready[('x', k)])
        if d['xop'] == 1 or d['xop'] == 4: t = max(t, ready['R'])
        if d['div'] and not div_pipe: t = max(t, div_free)
        # MAC chains: up to `vec` consecutive accumulate steps share one vector op
        mac_slot = False
        if d['acc']:
            if d['acc'] == 1 or macrun % vec == 0: mac_slot = True
            macrun = 0 if d['acc'] == 1 else macrun + 1
        reads = (1 if d['ra'] else 0) + (1 if d['rb'] else 0)
        while True:
            u = use[t]
            ok = (not d['alu'] or u['alu'] < alus) and (not mac_slot or u['mac'] < macs) and u['rd'] + reads <= rdports \
                and (not d['we'] or u['wr'] < wports) and (not d['out'] or pack_free or u['out'] < 1) and (not d['nx'] or u['br'] < 1)
            if ok: break
            t += 1
        u = use[t]
        if d['alu']: u['alu'] += 1
        if mac_slot: u['mac'] += 1
        u['rd'] += reads
        if d['we']: u['wr'] += 1
        if d['out']: u['out'] += 1
        if d['nx']: u['br'] += 1
        if d['alu']: ready['R'] = t + 1
        if d['fl']: ready['fl'] = t + lat_fl
        if d['we']: ready[('rf', addr(d['we'], xr))] = t + lat_rf
        if d['acc']: ready['acc'] = t + 1; ready['accx'] = t + lat_acc
        if d['div']:
            ready['q'] = t + int(d['div'] * div_scale) + 2
            div_free = t + 1 if div_pipe else ready['q']
        if d['xop'] in (1, 2, 6, 7): ready[('x', d['xarg'] & 3)] = t + 1
        if d['nx'] in (NX_JC, NX_JNC, NX_DJNZ, NX_DISP, NX_RET) and not spec:
            barrier = t + 1
        hist.append(t)
        if len(hist) > win: hist.popleft()
        last = max(last, t)
    return last + 1


def load(path):
    b = open(path, 'rb').read()
    n = len(b) // 8
    v = struct.unpack(f'<{4 * n}H', b)
    return [(v[4 * i], (v[4 * i + 1], v[4 * i + 2], v[4 * i + 3])) for i in range(n)]


CONFIGS = [
    ('model of today (1 ALU, 1 MAC, 2 RF ports, in order)', dict()),
    ('+ radix-4 divider', dict(div_scale=0.5)),
    ('vec4 MAC + pipelined divider, in order', dict(vec=4, div_pipe=True)),
    ('2 ALU, vec4 MAC, 4 RF ports, window 8, div pipe, pack free', dict(alus=2, vec=4, rdports=4, wports=2, win=8, div_pipe=True, pack_free=True)),
    ('3 ALU, vec4 MAC, 6 RF ports, window 16, div pipe, pack free', dict(alus=3, vec=4, rdports=6, wports=3, win=16, div_pipe=True, pack_free=True)),
    ('4 ALU, vec4 MAC, 8 RF ports, window 32, div pipe, pack free, spec', dict(alus=4, vec=4, rdports=8, wports=4, win=32, div_pipe=True, pack_free=True, spec=True)),
]

if __name__ == '__main__':
    for path in sys.argv[1:]:
        tr = load(path)
        name = os.path.basename(path)
        print(f'{name}: {len(tr)} busy cycles measured')
        for lab, cfg in CONFIGS:
            n = schedule(tr, **cfg)
            print(f'   {n:9d}  x{len(tr) / n:4.2f}  {lab}')
