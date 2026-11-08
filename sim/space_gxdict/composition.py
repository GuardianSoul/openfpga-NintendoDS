#!/usr/bin/env python3
"""Composition check of gpu3d_gxrom_ufd against gpu3d_gxrom_uf (docs/space-gxdict.md).

Reads both modules from the generated rtl/gpu3d/gpu3d_gxrom_uf.sv (the index ROM rs, the dictionaries
rd0.., the a_q/a_tdx concatenations, the DISP table h_dx and the k_* constants, as the RTL has them)
and checks, for all 2048 PCs p, that each way gpu3d_gxeng selects dx_n gives the dictionaries the old
ROM's words ra[next]/rb[next]:
  sequential (NEXT, JC/JNC/DJNZ not taken): dx_s = rs[p] -> word p + 1
  jump (JMP, JC/JNC/DJNZ taken, CALL, DISP waiting): a_tdx of ra[p] -> word tgt(ra[p])
  call/return: the stack keeps CALL's dx_s = rs[p] beside p + 1 -> RET's word p + 1
  DISP dispatch: h_dx[h] -> word h (h 0..63); DPARAM/SUBV/SV1/RESET: k_* -> word at that pc
  hold (DISP with COLOR/TEXCOORD/NORMAL in the latches): dx_q = the indices of word p -> word p
and that t_imm (imt) is the same table. Also: no CALL target holds a RET (the return stack's M10K would
read the entry being written). --mutate shift|word applies the two mutants (index ROM shifted by one
entry, one dictionary word corrupted) to the parsed tables: the check must fail.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
mut = sys.argv[sys.argv.index('--mutate') + 1] if '--mutate' in sys.argv else None
text = (ROOT / 'rtl/gpu3d/gpu3d_gxrom_uf.sv').read_text()
old, new = text.split('\nmodule gpu3d_gxrom_ufd')
new = 'module gpu3d_gxrom_ufd' + new
H = lambda s: int(s, 16)
ra = {int(i): H(v) for i, v in re.findall(r"ra\[(\d+)\] = 70'h([0-9a-f]+);", old)}
rb = {int(i): H(v) for i, v in re.findall(r"rb\[(\d+)\] = 35'h([0-9a-f]+);", old)}
imt_o = {int(i): H(v) for i, v in re.findall(r"imt\[(\d+)\] = 32'h([0-9a-f]+);", old)}
imt_n = {int(i): H(v) for i, v in re.findall(r"imt\[(\d+)\] = 32'h([0-9a-f]+);", new)}
rs = {int(i): H(v) for i, v in re.findall(r"rs\[(\d+)\] = \d+'h([0-9a-f]+);", new)}
# the dictionaries rd0..rd{G-1} and their index fields in dx (the localparam line: "q<g> <bits> at <offset>")
G = int(re.search(r"localparam int G = (\d+), DW = (\d+);", new).group(1))
IX = {int(g): (int(b), int(o)) for g, b, o in re.findall(r"q(\d+) (\d+) at (\d+)", re.search(r"localparam int G = .*", new).group(0))}
rd = [{int(i): H(v) for i, v in re.findall(rf"rd{g}\[(\d+)\] = \d+'h([0-9a-f]+);", new)} for g in range(G)]
hdx = {int(i): H(v) for i, v in re.findall(r"6'd(\d+): h_dx = \d+'h([0-9a-f]+);", new)}
k = {n: H(v) for n, v in re.findall(r"assign k_(\w+) = \d+'h([0-9a-f]+);", new)}
assert len(ra) == len(rb) == len(rs) == 2048 and len(hdx) == 64 and len(IX) == G
assert all(len(rd[g]) == 1 << IX[g][0] for g in range(G))
assert imt_o == imt_n and len(imt_o) == 128


def cat(expr, srcs):
    """Evaluate a {q0[h:l], N'hC, ...} concatenation of the dictionaries' outputs srcs (MSB first)."""
    v = 0
    for part in [x.strip() for x in expr.split(',')]:
        m = re.fullmatch(r"q(\d+)\[(\d+)(?::(\d+))?\]", part)
        if m:
            h = int(m.group(2)); l = int(m.group(3) or h)
            v = (v << (h - l + 1)) | ((srcs[int(m.group(1))] >> l) & ((1 << (h - l + 1)) - 1))
        else:
            m = re.fullmatch(r"(\d+)'([hd])([0-9a-f]+)", part)
            v = (v << int(m.group(1))) | int(m.group(3), 16 if m.group(2) == 'h' else 10)
    return v


aq_e = re.search(r"assign a_q = \{(.*)\};", new).group(1)
bq_e = re.search(r"assign b_q1 = \{(.*)\};", new).group(1)
at_e = re.search(r"assign a_tdx = \{(.*)\};", new).group(1)
if mut == 'shift':                 # the index ROM shifted by one entry
    rs = {p: rs[(p + 1) % 2048] for p in range(2048)}
elif mut == 'word':                # one dictionary word corrupted (group 0 index 5, bit 3)
    rd[0][5] ^= 1 << 3


def word(dx):                      # what the dictionaries give at indices dx: (a_q, b_q, a_tdx)
    q = [rd[g][(dx >> IX[g][1]) & ((1 << IX[g][0]) - 1)] for g in range(G)]
    return cat(aq_e, q), cat(bq_e, q), cat(at_e, q)


J = {1, 2, 3, 4, 6, 7}             # NX JMP JC JNC CALL DISP DJNZ: take a_tgt
bad, n = [], {}


def check(kind, p, dx, q):
    n[kind] = n.get(kind, 0) + 1
    a, b, _ = word(dx)
    if (a, b) != (ra[q], rb[q]):
        bad.append((kind, p, q))


# the indices of word p, as dx_n gives them at each kind (induction from RESET)
cur = {}
for p in range(2048):
    cur[(p + 1) % 2048] = rs[p]
for p in range(2048):
    check('seq', p, rs[p], (p + 1) % 2048)
    check('hold', p, cur[p], p)
    a = ra[p]
    if a & 7 in J:
        check('jump', p, word(cur[p])[2], (a >> 3) & 0x7ff)
    if a & 7 == 4:                  # CALL: the stack keeps dx_s with p + 1; the RET returns to them
        check('call-ret', p, rs[p], (p + 1) % 2048)
        assert ra[(a >> 3) & 0x7ff] & 7 != 5, f'RET at the target of CALL {p:#x}'
for h in range(64):
    check('disp', h, hdx[h], h)
for name, pc in (('reset', 40), ('dparam', 38),
                 ('subv', int(re.search(r"assign k_subv = .*// pc 0x([0-9a-f]+)", new).group(1), 16)),
                 ('sv1', int(re.search(r"assign k_sv1 = .*// pc 0x([0-9a-f]+)", new).group(1), 16))):
    check(name, pc, k[name], pc)
print('checks', ' '.join(f'{x} {c}' for x, c in n.items()), '; t_imm table equal (128)')
if bad:
    print(f'FAIL: {len(bad)} wrong, first {bad[:3]}')
    sys.exit(1)
print('PASS: every next-address kind gives the old ROM\'s A and B word at every PC')
