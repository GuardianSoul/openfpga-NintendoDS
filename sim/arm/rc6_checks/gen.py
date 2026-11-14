#!/usr/bin/env python3
# random ARMv5TE program for differential testing of the ARM9 pipeline (traces of two configs must be equal)
import random, sys, os
DENSE = os.environ.get('DENSE') == '1'
UNAL = os.environ.get('UNAL') == '1'      # unaligned word LDR/STR offsets too (the ARM9 rotates the load)
seed = int(sys.argv[1]); n = int(sys.argv[2]) if len(sys.argv) > 2 else 1500
loops = int(sys.argv[3]) if len(sys.argv) > 3 else 3
R = random.Random(seed)
DR = ['r0','r1','r2','r3','r4','r5','r6','r7','r11','r12','r14']      # data registers (r8/r9 bases, r10 pointer, r13 loop)
SRC = DR + ['r8','r9']
CONDS = ['eq','ne','cs','cc','mi','pl','vs','vc','hi','ls','ge','lt','gt','le']
def cond():
    return R.choice(CONDS) if R.random() < 0.18 else ''
def reg(): return R.choice(DR)
def src(): return R.choice(SRC)
def imm_rot():
    return R.choice([R.randrange(256), R.randrange(256), (R.randrange(256) << (2*R.randrange(16))) & 0xFFFFFFFF])
def enc_imm():
    while True:
        v = imm_rot()
        for r in range(16):
            x = ((v << (2*r)) | (v >> (32 - 2*r))) & 0xFFFFFFFF if r else v
            if x < 256: return v
        # not encodable
        v = R.randrange(256)
        return v
def op2():
    k = R.random()
    if k < 0.3: return '#%d' % enc_imm()
    if k < 0.5: return src()
    if k < 0.8:
        t = R.choice(['lsl','lsr','asr','ror'])
        n = R.randrange(1, 32) if t in ('lsl','ror') else R.randrange(1, 33)
        return '%s, %s #%d' % (src(), t, n)
    if k < 0.9:
        t = R.choice(['lsl','lsr','asr','ror'])
        return '%s, %s %s' % (src(), t, reg())
    return '%s, rrx' % src()
DP = ['and','eor','sub','rsb','add','adc','sbc','rsc','tst','teq','cmp','cmn','orr','mov','bic','mvn']
def dp():
    o = R.choice(DP)
    s = 's' if (o in ('tst','teq','cmp','cmn') or R.random() < 0.3) else ''
    c = cond()
    if o in ('mov','mvn'): return '%s%s%s %s, %s' % (o, s, c, reg(), op2())
    if o in ('tst','teq','cmp','cmn'): return '%s%s %s, %s' % (o, c, src(), op2())
    return '%s%s%s %s, %s, %s' % (o, s, c, reg(), src(), op2())
def mul():
    k = R.random(); c = cond(); s = 's' if R.random() < 0.3 else ''
    a, b, d = R.sample(DR, 3)
    if k < 0.2: return 'mul%s%s %s, %s, %s' % (s, c, d, a, b)
    if k < 0.4: return 'mla%s%s %s, %s, %s, %s' % (s, c, d, a, b, R.choice(DR))
    lo, hi, m, r = R.sample(DR, 4)
    if k < 0.65: return '%s%s%s %s, %s, %s, %s' % (R.choice(['umull','smull','umlal','smlal']), s, c, lo, hi, m, r)
    if k < 0.8: return '%s%s %s, %s, %s' % (R.choice(['smulbb','smulbt','smultb','smultt','smulwb','smulwt']), c, d, a, b)
    if k < 0.9: return '%s%s %s, %s, %s, %s' % (R.choice(['smlabb','smlabt','smlatb','smlatt','smlawb','smlawt']), c, d, a, b, R.choice(DR))
    return '%s%s %s, %s, %s' % (R.choice(['qadd','qsub','qdadd','qdsub']), c, d, a, b)
def clz(): return 'clz%s %s, %s' % (cond(), reg(), src())
def off12(): return R.randrange(0, 64, 4) if DENSE else R.randrange(0, 0x1000, 4)
def mem():
    k = R.random(); c = cond(); base = R.choice(['r8','r9'])
    if k < 0.35:
        op = R.choice(['ldr','str','ldrb','strb'])
        if op in ('ldrb','strb'): off = R.randrange(0, 64) if DENSE else R.randrange(0, 0x1000)
        else:
            off = off12()
            if UNAL: off += R.randrange(4)
        return '%s%s %s, [%s, #%d]' % (op, c, reg(), base, off)
    if k < 0.5:
        # register offset (masked)
        op = R.choice(['ldr','str','ldrb','strb'])
        if DENSE: return 'and r10, %s, #%d\n    %s%s %s, [%s, r10]' % (src(), 63 if UNAL else 60, op, c, reg(), base)
        return 'mov r10, %s, lsl #20\n    mov r10, r10, lsr #18\n    %s%s %s, [%s, r10]' % (src(), op, c, reg(), base)
    if k < 0.62:
        op = R.choice(['ldrh','strh','ldrsh','ldrsb'])
        off = (R.randrange(0, 64, 2) if op != 'ldrsb' else R.randrange(64)) if DENSE else (R.randrange(0, 256, 2) if op != 'ldrsb' else R.randrange(256))
        if op == 'strh': return 'strh%s %s, [%s, #%d]' % (c, reg(), base, off)
        return '%s%s %s, [%s, #%d]' % (op, c, reg(), base, off)
    if k < 0.72:
        # pre/post indexed with writeback on r10
        o = R.choice(['ldr','str'])
        d = R.choice([4, 8, -4, -8, 16])
        form = R.choice(['pre','post'])
        pre = 'add r10, %s, #%d\n    ' % (base, (R.randrange(0, 0x20, 4) + 0x20) if DENSE else R.randrange(0, 0x3C0, 4) + 0x20)
        if form == 'pre': return pre + '%s%s %s, [r10, #%d]!' % (o, c, reg(), d)
        return pre + '%s%s %s, [r10], #%d' % (o, c, reg(), d)
    # LDM/STM
    regs = sorted(R.sample([0,1,2,3,4,5,6,7,11,12,14], R.randrange(1, 7)))
    lst = ','.join('r%d' % r for r in regs)
    mode = R.choice(['ia','ib','da','db'])
    wb = '!' if R.random() < 0.5 else ''
    op = R.choice(['ldm','stm'])
    pre = 'add r10, %s, #%d\n    ' % (base, R.randrange(0x20, 0x40, 4) if DENSE else R.randrange(0x40, 0x3C0, 4))
    return pre + '%s%s%s r10%s, {%s}' % (op, mode, c, wb, lst)
def br():
    k = R.randrange(1, 4)
    L = 'b%d' % R.randrange(10**9)
    body = '\n    '.join(gen_one() for _ in range(k))
    return 'b%s %s\n    %s\n%s:' % (R.choice(CONDS), L, body, L)
def gen_one():
    k = R.random()
    if DENSE:
        if k < 0.15: return dp()
        if k < 0.20: return mul()
        return mem()
    if k < 0.40: return dp()
    if k < 0.58: return mul()
    if k < 0.62: return clz()
    return mem()
out = []
out.append('.syntax unified\n.arm\n.global _start\n.equ EXIT, 0x0F000000\n.include "cp15.inc"\n_start:' + ('' if os.environ.get('NOCP') == '1' else '\n    CP15_REGIONS\n    CP15_ENABLE'))
BASES = {'0': ('0x02010000', '0x02018000'), 'tcm': ('0x0B000000', '0x00004000'), 'wt': ('0x02020000', '0x02018000'), 'mix': ('0x0B000100', '0x02020040'), 'mix2': ('0x0B000100', '0x00004000'), 'unc': ('0x02410000', '0x02418000'), 'bg': ('0x01000100', '0x01008000')}[os.environ.get('BASES', '0')]
out.append('    ldr r8, =%s\n    ldr r9, =%s\n    ldr r13, =%d' % (BASES[0], BASES[1], loops))
for r in DR: out.append('    ldr %s, =0x%08x' % (r, R.getrandbits(32)))
out.append('    b top\n.ltorg\ntop:')
for _ in range(n):
    out.append('    ' + (br() if R.random() < 0.06 else gen_one()))
out.append('    subs r13, r13, #1\n    bne top\n    ldr r2, =EXIT\n    mov r1, #0\n    str r1, [r2]\n    b .\n.ltorg')
print('\n'.join(out))
