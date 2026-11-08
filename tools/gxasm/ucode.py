"""Geometry engine microcode (docs/geometry-engine.md), after melonDS's
GPU3D.cpp. Run `python3 tools/gxasm/ucode.py` to regenerate
rtl/gpu3d/gpu3d_gxu_pkg.sv and rtl/gpu3d/gpu3d_gxrom.sv.

The engine is scalar (gpu3d_gxeng.sv): every state melonDS keeps is a
register-file word here. The assembler (asm.py) checks latencies and pads
with NOPs; nh() marks reads that a routine has scheduled against its own
writes (software pipelining), in the routine's scope().

Conventions:
  - R (the ALU result) is an operand of the next instruction; SETX/LCR/BIT
    read R at issue, the result of the instruction two before, with a NOP
    (or a branch) in between;
  - a MAC at i is visible to ACCX and the divider from i+3 until the next
    MAC lands (one cycle after it would be visible); accumulator flags from
    i+5;
  - X1..X3 are index registers; loop counters that the ALU needs live in
    the register file.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import isa
from asm import *

P_ = Prog()
# USORT (gpu3d_gxeng): the polygon sort in microcode (SORT below) instead of gpu3d_gxsort; its own control
# store image, gpu3d_gxrom_us.sv
USORT = os.environ.get("GX_USORT") == "1"
# LUNIT (gpu3d_gxeng, with USORT): the lighting unit gpu3d_gxlight; its own image, gpu3d_gxrom_ul.sv
LUNIT = os.environ.get("GX_LUNIT") == "1"
assert USORT or not LUNIT
# VFIN (gpu3d_gxeng, with LUNIT): the vertex-finish unit gpu3d_gxvfin (final colour, beat words W1-W3 and
# the bounds of VPV's vertices); its own image, gpu3d_gxrom_uv.sv
VFIN = int(os.environ.get("GX_VFIN") or 0)   # 2: VFIN-lite, the colour and beat words only (BVX stays here)
assert LUNIT or not VFIN
# FF (gpu3d_gxeng FF, with USORT, LUNIT and VFIN 1): the geometry redesign (docs/geometry-redesign.md): attribute
# latches beside the register file (CURCOL, TEXC, RAWTC), read with XS = ATR; the dispatcher takes COLOR and
# texture-mode-0 TEXCOORD into them in the DISP clock. Its own image, gpu3d_gxrom_uf.sv
FF = os.environ.get("GX_FF") == "1"
assert USORT and LUNIT and VFIN == 2 or not FF
# PU (FF with LUNIT; docs/geometry-redesign.md "Polygon unit"): gpu3d_gxeng's
# polygon unit keeps VertexNumInPoly, the slot order (TempVertexBuffer), NumConsecutivePolygons' parity and
# the outcodes of the slot groups. The dispatcher enters the transform with X1 = the vertex's slot group; the
# transform's last instruction steps the unit (jc PSTEP), which on a completed polygon latches its slots,
# rotates them and sets X1..X3 to its first three vertices. The cull follows at once; the unit's trivial
# reject (PTRIV) joins it, and the list words (LA, LN, CS, OCM, SA) are written only for polygons the cull
# keeps
PU = FF and LUNIT
FF_VM = True
P_.precise_ret = USORT                 # asm.py: the USORT image takes the exact return sites (fewer hazard NOPs)


def I(*parts):
    f = sys._getframe(1)
    while f.f_code.co_filename == __file__ and f.f_code.co_name not in ("<module>",) and f.f_back and \
            f.f_back.f_code.co_filename == __file__ and f.f_code.co_name in ("setx_from", "copy16", "nops", "waitd", "waito"):
        f = f.f_back
    P_.ins(*parts, where=f"ucode.py:{f.f_lineno}")


def L(name):
    P_.label(name)


_n = [0]


def u(stem):
    _n[0] += 1
    return f"{stem}_{_n[0]}"


def scope(name):
    P_.scope = name


def xrange(k, lo=None, hi=None):
    """index register k holds values in [lo, hi) from here on (None: unknown);
    the hazard check uses it for the register-file words an access can touch"""
    if lo is None:
        P_.xr.pop(k, None)
    else:
        P_.xr[k] = (lo, hi)


def xclear():
    P_.xr.clear()


def nops(k):
    for _ in range(k):
        I()


def waitd():
    lb = u("wd")
    L(lb)
    I(jc("DBUSY", lb))


def waito():
    lb = u("wo")
    L(lb)
    I(jc("OBUSY", lb))


def d1():
    """the end of a handler: FF dispatches here (an instruction with no other effect, or an idempotent one:
    the dispatch stays on it while the hardware takes COLOR, TEXCOORD or NORMAL); else through D1"""
    return disp(NOENT) if FF else jmp("D1")


def ld(a, x=0, fl=False):
    """R = RF[a + Xx] (port A)"""
    return (ra(a, x), op("PASSX", "QA", fl=fl))


def ldb(a, x=0, fl=False):
    """R = RF[a + Xx] (port B)"""
    return (rb(a, x), op("OR", "ZERO", "QB", fl=fl))


def li(v, fl=False):
    return op("OR", "ZERO", v, fl=fl)


def setx_from(a, k, ax=0):
    """X[k] = RF[a + X[ax]]"""
    I(*ld(a, ax))
    I()
    I(setx(k))


# ---------------------------------------------------------------- RF layout
PROJ, POS, VEC, TEX, CLIP, IDENT, TMP = 0x000, 0x010, 0x020, 0x030, 0x040, 0x050, 0x060
PARAM, PR3, PROJST, TEXST = 0x080, 0x0A0, 0x0B0, 0x0C0
LIGHT = 0x100                          # 16 words per light
LDIR, LRECIP, LCOL, LDL, LSL, LAL = 0, 3, 4, 7, 10, 13
SHIN = 0x180                           # 128 bytes, one per word
GRP = 0x200                            # 32 vertex groups of 16 words
POSST, VECST = 0x400, 0x600
# vertex group words: Position[0..3], Color[0..2], W24 = Position[3] & 0xFFFFFF
# (from the viewport on), TexCoords[0..1], FinalPosition x/y, the vertex
# beat's pre-packed colour/texcoord words W1..W3, FinalZ (before the
# viewport the outcode flags)
G_P, G_C, G_W, G_T, G_FX, G_FY, G_W1, G_W2, G_W3, G_FZ = 0, 4, 7, 8, 10, 11, 12, 13, 14, 15
NSLOTGRP = 8                           # groups 0..7: slots; 8..31: clipping (16..31 for the box test)
assert PARAM == PARAM_BASE


def grp(g):
    return GRP + 16 * g


class Alloc:
    def __init__(self, *ranges):
        self.free = [list(r) for r in ranges]

    def __call__(self, n=1):
        for r in self.free:
            if r[1] - r[0] >= n:
                a = r[0]
                r[0] += n
                return a
        raise ValueError("out of variable space")


V = Alloc((0x0D0, 0x100), (0x140, 0x180), (0x070, 0x080), (0x278, 0x280))
MMODE, PMODE, PATTR, CATTR, TEXP, TEXM, TEXPAL, PSP = (V() for _ in range(8))
VNIP, NCONS, VLIM, VRST, ROT, FATTR, NP, NV = (V() for _ in range(8))
CURSLOT, USETAB, TRT, TRA, LSREUSE, CS, LN, OCANY = (V() for _ in range(8))
OCFAR, POOL, FACING, KT, KB, WOR, DEG, WSL = (V() for _ in range(8))
WSR, LI, LCNT, ATT, NUM, NNUM, DEN, KSH = (V() for _ in range(8))
ZWAIT, ZX, ZY, TS, DV, IDXB, WS, ZM = (V() for _ in range(8))
KIND, SRCM, ROWS, VECOK, SRCB, DSTB, SG, SGM = (V() for _ in range(8))
CURV, CURCOL, RAWTC, TEXC, NRM, NT = V(3), V(3), V(2), V(2), V(3), V(3)
# FF: the attribute latches by index (gpu3d_gxeng at_*); the dispatcher writes them without these words, so
# every reader of a latched word reads the latch (XS = ATR)
ATR_ADDR.extend([CURCOL, CURCOL + 1, CURCOL + 2, TEXC, TEXC + 1])
# FF: the vector MAC's lanes: CLIP + 4 row + lane (rows 0-3), TEX + 4 k + lane (lanes 0, 1: rows 4-6),
# RawTexCoords << 12 (lanes 0, 1: row 7) (gpu3d_gxeng g_vx); CurVertex's latch (MB3)
VM_ADDR.extend(list(range(CLIP, CLIP + 16)) + [TEX + 4 * k + c for k in range(3) for c in range(2)] + [RAWTC, RAWTC + 1])
CURV_ADDR.extend([CURV, CURV + 1, CURV + 2])
# PU: the polygon unit's registers (XS = ATR, xsh PU_XSH, the register's index as the immediate; gpu3d_gxeng pu_q)
PU_LA, PU_LN, PU_CS, PU_OCM, PU_SA, PU_NCONS, PU_CUR = 0, 4, 5, 6, 7, 8, 9


def pu(k, fl=False):
    """R = the polygon unit's register k (PU)"""
    return op("PASSX", ("ATR", PU_XSH), k, fl=fl)
MDIF, MAMB9, MSPE, MEMI, VB = V(3), V(3), V(3), V(3), V(3)
VP = V(4)                              # Viewport[0], [3], [4], [5]
VP0, VP3, VP4, VP5 = VP, VP + 1, VP + 2, VP + 3
SLOT = V(6)                            # TempVertexBuffer[0..3], reuse 0/1: group bases
LA, LB = V(10), V(10)                  # clip lists (group bases)
LDD, LSH = V(4), V(4)                  # per light: diffdot, shine level
POSTEST = V(6)                         # POS_TEST results, then VEC_TEST (reads of 0x620..)
VECTEST = POSTEST + 4
T = TMP                                # temporaries outside the matrix products
SN, SK, SO, SUM = T + 8, T + 9, T + 10, T + 11   # USORT: the sort's (at a swap, between commands)
T2 = PR3                               # more temporaries (REALIGN rewrites all of PR3)
BOXV = grp(6)                          # box test: 8 corners of (x, y, z), then x0 y0 z0 x1 y1 z1
BOXC = BOXV + 24

NOENT = "NOENT"

# ======================================================================
# handler table (hidx in gpu3d_gxeng.sv)
# ======================================================================
HT = {0x00: 0}
for c in range(0x10, 0x1D): HT[c] = c - 0x10 + 1
for c in range(0x20, 0x2C): HT[c] = c - 0x20 + 14
for c in range(0x30, 0x35): HT[c] = c - 0x30 + 26
HT[0x40], HT[0x41], HT[0x50], HT[0x60] = 31, 32, 33, 34
for c in range(0x70, 0x73): HT[c] = c - 0x70 + 35


def table(c, *parts):
    P_.org(HT[c])
    I(*parts)


table(0x00, disp(NOENT))
table(0x10, op("AND", "P", 3), w(MMODE), jmp("D1"))
table(0x11, jmp("PUSH"))
table(0x12, jmp("POP"))
table(0x13, jmp("STORE"))
table(0x14, jmp("RESTORE"))
# FF: handlers whose first instruction reads no register-file word start in their table slot (a fixed block:
# no padding), saving the jump: the MATOP entries and the vertex commands that take their parameter as P
MATOPS = {0x15: ("IDENTH", 0, "IDENT", 4, 1), 0x16: ("LOAD44", 0, "PARAM", 4, 1), 0x18: ("MUL44", 1, "PARAM", 4, 1),
          0x1B: ("SCALE", 2, None, 4, 0), 0x1C: ("TRANS", 3, None, 4, 1)}


MDIRECT = True                         # FF: these commands' own handlers (mdisp) instead of MATOP's decode


def matop_val(kind, src=0, rows=4, vecok=1):
    return kind | rows << 2 | vecok << 5 | src << 6


def tab_matop(c):
    n, kind, src, rows, vecok = MATOPS[c]
    if FF and MDIRECT:
        table(c, jmp(n + "F"))
    elif FF:
        table(c, li(matop_val(kind, {"IDENT": IDENT, "PARAM": PARAM, None: 0}[src], rows, vecok)), w(KIND), jmp("MATOP"))
    else:
        table(c, jmp(n))


tab_matop(0x15)
tab_matop(0x16)
table(0x17, jmp("LOAD43"))
tab_matop(0x18)
table(0x19, jmp("MUL43"))
table(0x1A, jmp("MUL33"))
tab_matop(0x1B)
tab_matop(0x1C)
table(0x20, jmp("COLOR"))
table(0x21, jmp("NORMAL"))
table(0x22, jmp("TEXCOORD"))
table(0x23, jmp("VTX16"))
if FF:
    table(0x24, op("SHL", "P", 22), jmp("VTX10b"))
    table(0x25, op("SX16", "P"), w(CURV), jmp("VTXXYb"))
    table(0x26, op("SX16", "P"), w(CURV), jmp("VTXXZb"))
    table(0x27, op("SX16", "P"), w(CURV + 1), jmp("VTXYZb"))
    table(0x28, op("SHL", "P", 22), jmp("VTXDIFFb"))
else:
    table(0x24, jmp("VTX10"))
    table(0x25, jmp("VTXXY"))
    table(0x26, jmp("VTXXZ"))
    table(0x27, jmp("VTXYZ"))
    table(0x28, jmp("VTXDIFF"))
table(0x29, op("PASSX", "P"), w(PATTR), jmp("D1"))
table(0x2A, jmp("TEXPARAM"))
table(0x2B, op("AND", "P", 0x1FFF), w(TEXPAL), jmp("D1"))
table(0x30, jmp("DIFAMB"))
table(0x31, jmp("SPEEMI"))
table(0x32, jmp("LIGHTVEC"))
table(0x33, jmp("LIGHTCOL"))
table(0x34, jmp("SHININESS"))
table(0x40, jmp("BEGIN"))
table(0x41, disp(NOENT))
table(0x50, op("AND", "P", 3), w(FATTR), jmp("SWAP"))
table(0x60, jmp("VIEWPORT"))
table(0x70, jmp("BOXTEST"))
table(0x71, jmp("POSTEST"))
table(0x72, jmp("VECTEST"))
for k in range(38):
    if k not in HT.values():
        P_.org(k)
        I(disp(NOENT))                 # commands without a handler
P_.org(38)                             # DISP after absorbing a parameter (gpu3d_gxeng.sv)
I(disp(NOENT))

# ======================================================================
# reset (40): clear the register file, identity matrices, constants
# ======================================================================
P_.org(40, fixed=False)
L("RESET")
I(li(0), setxi(1, 0))
I(lci(0))
I(call("RCLR"))
I(lci(0))
I(call("RCLR"))
I(li(0x1000), setxi(1, 0))
I(lci(4))
L("RSTI")
for m in (IDENT, PROJ, POS, VEC, TEX):
    I(w(m, 1))
I(addx(1, 5), djnz("RSTI"))
I(li(0xFFF))
for k in range(3):
    I(w(CURCOL + k))
I(li(3), w(VLIM))
for k in range(6):
    I(li(grp(k)), w(SLOT + k))
I(li(grp(0)), w(CURSLOT))
if USORT:
    # every sort-table entry gets the tag before the reset value of gpu3d_gxeng's (the prefix pass writes
    # all of CT, re-tagging all of BL), then the tag flips without so_done
    I(call("SPRE"))
    I(li(0x100FF), call("SRETAG"))
    I(li(0), sm("SOD"))
I(dirty(1), jmp(NOENT))
L("RCLR")                              # 1,024 words of the register file
for k in range(16):
    I(w(k, 1))
I(addx(1, 16), djnz("RCLR"))
I(ret())

L(NOENT)
I(jc("MREQ", "MMIO"))
L("D1")
I(disp(NOENT))

# ======================================================================
# register-file reads: 0x640 clip matrix (sel 0..15), 0x680 vector matrix
# (16..24), 0x620 POS_TEST (25..28), 0x630 VEC_TEST (29, 30)
# ======================================================================
L("MMIO")
I(jnc("DIRTY", "MM2"))
I(call("CLIPUPD"))
L("MM2")
I(op("SUB", "MSEL", 16, fl=True))
I(op("SUB", "MSEL", 25))
I(jc("LT", "MMCLIP"))
I(op("SUB", "R", 0, fl=True))          # sel - 25
I()
I(jnc("LT", "MMTEST"))
I(op("SUB", "MSEL", 16), w(T))        # k = sel - 16
I(op("SLT", "R", 3), w(T + 1))         # k < 3
I(op("SUB", "MSEL", 16))
I(op("SLT", "R", 6))                   # k < 6
I(rb(T + 1), op("ADD", "R", "QB"))
I(op("RSUB", "R", 2))                  # row = k / 3
I(rb(T), op("ADD", "R", "QB"))         # vector matrix word 4 row + k % 3 = k + row
I(op("ADD", "R", VEC))
I()
I(setx(1))
I(*ld(0, 1), out("MRES"), jmp("MMEND"))
L("MMCLIP")
I(op("PASSX", "MSEL"))
I()
I(setx(1))
I(*ld(CLIP, 1), out("MRES"), jmp("MMEND"))
L("MMTEST")
I()
I(setx(1))
I(*ld(POSTEST, 1), out("MRES"))
L("MMEND")
nops(2)                                # MRES -> MREQ (the idle loop stays two instructions)
I(jmp(NOENT))

# ======================================================================
# matrices
# ======================================================================
# copy 16 (COPY16) or the first 12 (COPY12) words from X1 to X2
scope("copy")
L("COPY16")
for k in range(15, -1, -1):
    if k == 11:
        L("COPY12")
    I(*ld(k, 1), w(k, 2), nh())
I(ret())
scope(None)

# X3 = X1 * X2 for rows LC..1 (melonDS's m = s*m with s = X1, m = X2);
# 4 MACs per element, the element extracted 3 after its last MAC (the accumulator as of clock t - 3 is
# read at t). Rows run back to back: a row's last element is extracted at the next row's clock 2, which
# also moves X3 on; the first row is peeled, and the last row's element follows its MACs (MREND)
def mrow(prev_last, last):
    for c in range(4):
        for k in range(4):
            parts = [ra(k, 1), rb(4 * k + c, 2), mac("LD" if k == 0 else "ADD", "QA", "QB"), nh()]
            if c >= 1 and k == 2:
                parts += [op("PASSX", "ACCX", sh=12), w(c - 1, 3)]
            if c == 0 and k == 2 and prev_last:
                parts += [op("PASSX", "ACCX", sh=12), w(3, 3), addx(3, 4)]
            if c == 3 and k == 3:
                parts += [addx(1, 4), *last]
            I(*parts)


def mrend():
    nops(2)
    I(op("PASSX", "ACCX", sh=12), w(3, 3), nh())
    I(ret())


scope("mrows")
L("MROWS")
mrow(False, (djnz("MRL"),))            # one row (LC 1): falls through to its end
mrend()
L("MRL")
mrow(True, (djnz("MRL"),))
mrend()
scope(None)

# clip matrix = Pos * Proj (melonDS: ClipMatrix = Proj, then Mult4x4 by Pos)
L("CLIPUPD")
I(setxi(1, POS))
I(setxi(2, PROJ))
I(setxi(3, CLIP))
I(lci(4), call("MROWS"))
I(dirty(0), ret())


def mode_dispatch(l0, l3, l2=None):
    """MMODE 0 -> l0, 3 -> l3, 2 -> l2 (when given); mode 1 (and 2) fall through"""
    I(*ld(MMODE))
    I()
    m23 = u("m23")
    I(jc("BIT", m23, bit=1))
    I(jnc("BIT", l0, bit=0))
    m1 = u("m1")
    I(jmp(m1))
    L(m23)
    I(jc("BIT", l3, bit=0))
    if l2:
        I(jmp(l2))
    L(m1)


def copy16(src, dst, n=16):
    I(setxi(1, src))
    I(setxi(2, dst), call("COPY16" if n == 16 else "COPY12"))


# push: proj/tex -> their one stack entry; pos+vec -> stack[PSP & 31], PSP + 1
L("PUSH")
mode_dispatch("PU0", "PU3")
I(*ld(PSP))
I(op("AND", "R", 0x1F))
I(op("SHL", "R", 4), w(T))
I(op("ADD", "R", POSST))
I()
I(setx(2))
I(setxi(1, POS), call("COPY16"))
I(*ld(T))
I(op("ADD", "R", VECST))
I()
I(setx(2))
I(setxi(1, VEC), call("COPY16"))
I(*ld(PSP))
I(op("ADD", "R", 1))
I(op("AND", "R", 0x3F), w(PSP), jmp("D1"))
L("PU0")
copy16(PROJ, PROJST)
I(d1())
L("PU3")
copy16(TEX, TEXST)
I(d1())

# pop: PSP -= sx6(param), pos+vec <- stack[PSP & 31]
L("POP")
mode_dispatch("PO0", "PO3")
I(op("SHL", "P", 26))
I(op("SAR", "R", 26))
I(rb(PSP), op("RSUB", "R", "QB"))      # PSP - offset
I(op("AND", "R", 0x3F), w(PSP))
L("POPK")                              # R = stack index
I(op("AND", "R", 0x1F))
if FF:
    # both entries' addresses first (a setx reads R two back)
    I(op("SHL", "R", 4))
    I(op("ADD", "R", POSST))
    I(op("ADD", "R", VECST - POSST), w(T))
    I(setx(1))                         # X1 = POSST + 16 index
    I(setxi(2, POS), call("COPY16"))
    I(*ld(T))
    I(setxi(2, VEC))
    I(setx(1), call("COPY16"))         # X1 = VECST + 16 index
else:
    I(op("SHL", "R", 4), w(T))
    I(op("ADD", "R", POSST))
    I()
    I(setx(1))
    I(setxi(2, POS), call("COPY16"))
    I(*ld(T))
    I(op("ADD", "R", VECST))
    I()
    I(setx(1))
    I(setxi(2, VEC), call("COPY16"))
L("DIRTYD")
I(dirty(1), d1())                      # dirty(1) again when the dispatch stays is harmless
L("PO0")
copy16(PROJST, PROJ)
I(jmp("DIRTYD"))
L("PO3")
copy16(TEXST, TEX)
I(d1())

L("STORE")
mode_dispatch("ST0", "ST3")
I(op("AND", "P", 0x1F))
I(op("SHL", "R", 4), w(T))
I(op("ADD", "R", POSST))
I()
I(setx(2))
I(setxi(1, POS), call("COPY16"))
I(*ld(T))
I(op("ADD", "R", VECST))
I()
I(setx(2))
I(setxi(1, VEC), call("COPY16"))
I(d1())
L("ST0")
copy16(PROJ, PROJST)
I(d1())
L("ST3")
copy16(TEX, TEXST)
I(d1())

L("RESTORE")
mode_dispatch("RE0", "RE3")
I(op("AND", "P", 0x1F), jmp("POPK"))
L("RE0")
copy16(PROJST, PROJ)
I(jmp("DIRTYD"))
L("RE3")
copy16(TEXST, TEX)
I(d1())


# 4x3 parameters -> PR3 (s[3r+c] in row r; column 3 zero, PR3[15] = 0x1000); FF: LD43 writes them into X2
if not FF:
    L("REALIGN")
    for k in range(12):
        I(*ld(PARAM + k), w(PR3 + 4 * (k // 3) + k % 3))
    I(li(0), w(PR3 + 3))
    I(w(PR3 + 7))
    I(w(PR3 + 11))
    I(li(0x1000), w(PR3 + 15), ret())
else:
    xclear()
    xrange(2, PROJ, TEX + 1)           # PROJ, POS, VEC or TEX
    L("LD43")
    for k in range(12):
        I(*ld(PARAM + k), w(4 * (k // 3) + k % 3, 2))
    I(li(0), w(3, 2))
    I(w(7, 2))
    I(w(11, 2))
    I(li(0x1000), w(15, 2), ret())


# matrix commands: KIND 0 copy SRCM, 1 multiply by SRCM (ROWS rows), 2 scale,
# 3 translate; on the mode's matrix, and the vector matrix in mode 2 when VECOK
def matop(name, kind, src=0, rows=4, vecok=1, realign=False):
    if FF and name in [v_[0] for v_ in MATOPS.values()]:
        return                         # in its table slot
    L(name)
    if realign:
        I(call("REALIGN"))
    I(li(kind | rows << 2 | vecok << 5 | src << 6), w(KIND), jmp("MATOP"))


matop("IDENTH", 0, IDENT)
matop("LOAD44", 0, PARAM)
if not FF:
    matop("LOAD43", 0, PR3, realign=True)
matop("MUL44", 1, PARAM, 4)
if not FF:
    matop("MUL43", 1, PR3, 4, realign=True)
    matop("MUL33", 1, PR3, 3, realign=True)
matop("SCALE", 2, vecok=0)
matop("TRANS", 3)

if not (FF and MDIRECT):
    L("MATOP")
    I(ra(KIND), op("SHR", "QA", 6), w(SRCM))
    I(ra(KIND), op("SHR", "QA", 2))
    I(op("AND", "R", 7), w(ROWS))
    I(ra(KIND), op("SHR", "QA", 5), w(VECOK))
    I(*ld(MMODE))
    I()
    I(jc("BIT", "MO23", bit=1))
    I(jnc("BIT", "MO0", bit=0))
    I(setxi(2, POS), call("DOTGT"))
    I(jmp("DIRTYD"))
    L("MO0")
    I(setxi(2, PROJ), call("DOTGT"))
    I(jmp("DIRTYD"))
    L("MO23")
    I(jc("BIT", "MO3", bit=0))
    I(setxi(2, POS), call("DOTGT"))
    I(*ld(VECOK))
    I()
    I(jnc("BIT", "DIRTYD", bit=0))
    I(setxi(2, VEC), call("DOTGT"))
    I(jmp("DIRTYD"))
    L("MO3")
    I(setxi(2, TEX), call("DOTGT"))
    I(d1())

    # one target matrix in X2
    L("DOTGT")
    I(*ld(KIND))
    I()
    I(jc("BIT", "DOT23", bit=1))
    I(jc("BIT", "DOTM", bit=0))
    setx_from(SRCM, 1)
    I(jmp("COPY16"))
    L("DOTM")
    setx_from(SRCM, 1)
    I(setxi(3, TMP))
    I(*ld(ROWS))
    I()
    I(lcr(), call("MROWS"))
    I(setxi(1, TMP))
    I(ra(ROWS), op("SUB", "QA", 3, fl=True))
    I()
    I(jc("Z", "COPY12"))
    I(jmp("COPY16"))
    L("DOT23")
    I(jc("BIT", "TRANSM", bit=0))
    I(jmp("SCALEM"))


if FF:
    # FF: MTX_MULT_4x3 and 3x3 from the parameters (X1 = PARAM, s[3r + k]): s's column 3 is (0, 0, 0, 0x1000)
    # (REALIGN's), so an element of rows 0-2 is 3 MACs and of row 3 (4x3) 3 plus m[3][c] * 0x1000, the same
    # sums; MP43 is row 3, then MP33 rows 0-2 into X3 (TMP), each element extracted 3 after its last MAC.
    # Entered at MP33, the stream's first extraction (row 3's last element, into TMP + 15) is a stale word
    # MUL33 never copies back
    scope("mp")
    ins = []
    ext = []
    for r in (3, 0, 1, 2):
        if r == 0:
            mp33_at = len(ins)
        for c in range(4):
            for k in range(3):
                ins.append([ra(3 * r + k, 1), rb(4 * k + c, 2), mac("LD" if k == 0 else "ADD", "QA", "QB"), nh()])
            if r == 3:
                ins.append([ra(12 + c, 2), mac("ADD", "QA", 0x1000), nh()])
            ext.append((len(ins) - 1 + 3, 4 * r + c))
    while len(ins) < max(a_ for a_, _ in ext) + 1:
        ins.append([nh()])
    for a_, e_ in ext:
        ins[a_] += [op("PASSX", "ACCX", sh=12), w(e_, 3)]
    ins[-1] += [ret()]
    for i_, parts in enumerate(ins):
        if i_ == 0:
            L("MP43")
        if i_ == mp33_at:
            L("MP33")
        I(*parts)
    scope(None)

    def mulp(name, rows4, load=False):
        """MTX_MULT_4x3 / 3x3 (MTX_LOAD_4x3: load) on the mode's matrix (and the vector matrix in mode 2), as
        MATOP's kinds 1 and 0"""
        L(name)
        m23, m0, m3 = u("p23"), u("p0"), u("p3")

        def tgt(m):
            if load:
                I(setxi(2, m), call("LD43"))
                return
            I(setxi(2, m))
            I(setxi(1, PARAM))
            I(setxi(3, TMP), call("MP43" if rows4 else "MP33"))
            I(setxi(1, TMP), call("COPY16" if rows4 else "COPY12"))
        I(*ld(MMODE))
        I()
        I(jc("BIT", m23, bit=1))
        I(jnc("BIT", m0, bit=0))
        tgt(POS)
        I(jmp("DIRTYD"))
        L(m0)
        tgt(PROJ)
        I(jmp("DIRTYD"))
        L(m23)
        I(jc("BIT", m3, bit=0))
        tgt(POS)
        tgt(VEC)
        I(jmp("DIRTYD"))
        L(m3)
        tgt(TEX)
        if load:
            nops(2)                    # LD43's last TEX words before a dispatch (the transform reads TEX's lanes)
        I(d1())

    def mdisp(name, tgt, vec):
        """a matrix command on the mode's matrix (and the vector matrix in mode 2 when vec), as MATOP: tgt(m)
        emits the work on matrix m"""
        L(name)
        m23, m0, m3 = u("q23"), u("q0"), u("q3")
        I(*ld(MMODE))
        I()
        I(jc("BIT", m23, bit=1))
        I(jnc("BIT", m0, bit=0))
        tgt(POS)
        I(jmp("DIRTYD"))
        L(m0)
        tgt(PROJ)
        I(jmp("DIRTYD"))
        L(m23)
        I(jc("BIT", m3, bit=0))
        tgt(POS)
        if vec:
            tgt(VEC)
        I(jmp("DIRTYD"))
        L(m3)
        tgt(TEX)
        nops(2)                        # its last TEX words before a dispatch (the transform reads TEX's lanes)
        I(d1())

    def t_call(r):
        return lambda m: I(setxi(2, m), call(r))

    def t_copy(src):
        def f(m):
            I(setxi(1, src))
            I(setxi(2, m), call("COPY16"))
        return f

    def t_mul44(m):
        I(setxi(2, m))
        I(setxi(1, PARAM))
        I(setxi(3, TMP))
        I(lci(4), call("MROWS"))
        I(setxi(1, TMP), call("COPY16"))

    xclear()
    mulp("MUL43", True)
    mulp("MUL33", False)
    mulp("LOAD43", True, load=True)
    mdisp("SCALEF", t_call("SCALEM"), False)
    mdisp("TRANSF", t_call("TRANSM"), True)
    mdisp("IDENTHF", t_copy(IDENT), True)
    mdisp("LOAD44F", t_copy(PARAM), True)
    mdisp("MUL44F", t_mul44, True)


L("SCALEM")
if True:
    """rows 0..2 of X2: m[4r+c] = (s[r] m[4r+c]) >> 12"""
    scope("scale")
    for e in range(15):
        parts = [nh()]
        if e < 12:
            parts += [ra(PARAM + e // 4), rb(e, 2), mac("LD", "QA", "QB")]
        if e >= 3:
            parts += [op("PASSX", "ACCX", sh=12), w(e - 3, 2)]
        I(*parts)
    scope(None)
    I(ret())


L("TRANSM")
if True:
    """X2: m[12+c] = (0x1000 m[12+c] + sum_k s[k] m[4k+c]) >> 12"""
    scope("trans")
    for c in range(4):
        I(ra(12 + c, 2), mac("LD", "QA", 0x1000), nh())
        for k in range(3):
            parts = [ra(PARAM + k), rb(4 * k + c, 2), mac("ADD", "QA", "QB"), nh()]
            if c >= 1 and k == 1:       # 3 after the last MAC of c - 1
                parts += [op("PASSX", "ACCX", sh=12), w(12 + c - 1, 2)]
            I(*parts)
    I()
    I()
    I(op("PASSX", "ACCX", sh=12), w(15, 2), nh())
    scope(None)
    I(ret())



# ======================================================================
# colour, texture coordinates, polygon attributes, viewport, swap
# ======================================================================
L("COLOR")
for k, sh in enumerate((12, 7, 2)):
    I(op("SHL", "P", sh))
    I(op("AND", "R", 0x1F000))
    I(op("OR", "R", 0xFFF), w(CURCOL + k), *((jmp("D1"),) if k == 2 else ()))

# TexCoords = RawTexCoords, or in mode 1 (Raw0 T0 + Raw1 T4 + T8 + T12) >> 12
L("TEXCOORD")
I(op("SX16", "P"), w(RAWTC))
I(op("SAR", "P", 16), w(RAWTC + 1))
I(ra(TEXM), op("SUB", "QA", 1, fl=True))
I(op("SX16", "P"), w(TEXC))
I(op("SAR", "P", 16), w(TEXC + 1), jnc("Z", "D1"))
# the two products back to back: the accumulator as of clock t - 3 is read at t, so c = 0's sum
# (MACs 0..3) is read at 6 while c = 1's MACs (4..7) run, and c = 1's at 10
scope("tc1")
ins = [[nh()] for _ in range(12)]
for c in range(2):
    b = 4 * c
    ins[b] += [ra(RAWTC), rb(TEX + c), mac("LD", "QA", "QB")]
    ins[b + 1] += [ra(RAWTC + 1), rb(TEX + 4 + c), mac("ADD", "QA", "QB")]
    ins[b + 2] += [ra(TEX + 8 + c), mac("ADD", "QA", 1)]
    ins[b + 3] += [ra(TEX + 12 + c), mac("ADD", "QA", 1)]
    ins[b + 6] += [op("PASSX", "ACCX", sh=12)]
    ins[b + 7] += [op("SX16", "R"), w(TEXC + c)] + ([jmp("D1")] if c == 1 else [])
for parts in ins:
    I(*parts)
scope(None)

# translucent texture formats 1 and 6
L("TEXPARAM")
I(op("PASSX", "P"), w(TEXP))
I(op("SHR", "P", 30), w(TEXM))
I(op("SHR", "P", 26))
I(op("AND", "R", 7))
I(op("XOR", "R", 1), w(T))             # f ^ 1
I(op("XOR", "R", 7))                   # f ^ 6
I(op("SLT", "R", 1), w(T + 1))         # f == 6
I(ra(T), op("SLT", "QA", 1))           # f == 1
I(rb(T + 1), op("OR", "R", "QB"), w(TRT), jmp("D1"))

# BEGIN_VTXS: PolygonMode, VertexNumInPoly 0, no last strip polygon,
# CurPolygonAttr = PolygonAttr; translucent polygon alpha 1..30
L("BEGIN")
I(op("AND", "P", 3), w(PMODE))
I(op("AND", "R", 1))
I(op("ADD", "R", 3), w(VLIM))          # 3, 4, 3, 4
I(op("AND", "P", 2), w(VRST))          # 0, 0, 2, 2
I(li(0), w(VNIP))
I(w(NCONS))
I(w(LSREUSE))
I(*ld(SLOT), w(CURSLOT))
I(*ld(PATTR), w(CATTR))
I(op("SHR", "R", 16))
I(op("AND", "R", 0x1F), w(T))          # alpha
I(op("SLT", "R", 31), w(T + 1))        # alpha < 31
I(rb(T), op("SLT", "ZERO", "QB"))      # 0 < alpha
I(rb(T + 1), op("AND", "R", "QB"), w(TRA), jmp("D1"))

L("VIEWPORT")
I(op("AND", "P", 0xFF), w(VP0))                # x0
I(op("SHR", "P", 16))
I(op("AND", "R", 0xFF))                        # x1
I(rb(VP0), op("SUB", "R", "QB"))
I(op("ADD", "R", 1))
I(op("AND", "R", 0x1FF), w(VP4))               # width
I(op("SHR", "P", 24))
I(op("RSUB", "R", 191))
I(op("AND", "R", 0xFF), w(VP3))                # (191 - y1) & 0xFF
I(op("SHR", "P", 8))
I(op("AND", "R", 0xFF))
I(op("RSUB", "R", 191))
I(op("AND", "R", 0xFF))                        # (191 - y0) & 0xFF
I(rb(VP3), op("SUB", "R", "QB"))
I(op("ADD", "R", 1))
I(op("AND", "R", 0xFF), w(VP5), jmp("D1"))     # height

L("SWAP")
I(jnc("SWAPGO", "SWAP"))
I(*ld(FATTR), out("SWAP"))
if not USORT:
    I(li(0), out("NPNV"), w(NP))
    I(w(NV), jmp("D1"))
else:
    I(*ld(NP), w(SN))
    I(li(0), out("NPNV"), w(NP))
    I(w(NV))
    I(w(SUM))
    I(call("SPRE"))
    # a late swap (the store still draws the last frame from its order/Y tables) waits for that frame to
    # finish, as the DS keeps rendering the old list until the swap's VBlank (else the store abandons it)
    L("SWWAIT")
    I(jc("SDRAW", "SWWAIT"))
    I(li(0x100FF), call("SWALK"))
    I(*ld(FATTR))
    I()
    I(jnc("BIT", "SW3", bit=0))
    # manual sort: translucent polygons by index, from the last position (SUM: all polygons) down; they
    # take every position the walk gave the translucent buckets
    L("SMAN")
    I(ra(SN), op("SUB", "QA", 1, fl=True), w(SN), sm("RP"))
    I()
    I(jc("N", "SW3"), op("PASSX", "SYB", fl=True))
    I(ra(SUM), op("SUB", "QA", 1))
    I(jnc("N", "SMAN"))
    I(w(SUM), sm("SOW"), jmp("SMAN"))
    L("SW3")
    I(li(1), sm("SOD"), jmp("D1"))

# ======================================================================
# USORT: the polygon sort (gpu3d_gxsort's, in gpu3d_gxeng's sort tables).
# At commit polygon i goes to the front of the list of bucket {t, ytop}
# (BL: head; NX: next) and is counted in bucket {t, ybot} (CT). At the
# swap, CT becomes inclusive prefix sums (each bucket's end), then the
# {t, ytop} buckets are walked from the last down, each list from its last
# polygon, and every polygon takes the position below its {t, ybot}
# bucket's end: the order is (ybot, ytop, index), as gpu3d_gxsort's, filled
# from the top. Manual sort: translucent polygons by index after the
# opaque ones. Bucket and count entries carry a tag that flips at each sort
# instead of being cleared; the walk re-tags every bucket.
# ======================================================================
if USORT:
    # SPRE: CT[b] = {tag, counts of buckets 0..b} for the 512 buckets (K steps through {t, ybot} = K[16], K[15:8])
    L("SPRE")
    I(li(0), w(SK))
    I(li(8), w(SO))
    L("SPO")
    I(lci(0))
    L("SPI")
    I(*ld(SK), sm("RB"))
    I(op("ADD", "R", 0x100), w(SK))
    I(rb(SUM), op("ADD", "SCT", "QB"), w(SUM), sm("WCT"))
    I(djnz("SPI"))
    I(ra(SO), op("SUB", "QA", 1, fl=True), w(SO))
    I()
    I(jnc("Z", "SPO"))
    I(ret())

    # SWALK: the 512 buckets {t, ytop} from R = 0x100FF down (K[16], K[7:0]); each re-tagged
    L("SWALK")
    I(w(SK))
    I(li(8), w(SO))
    L("SWO")
    I(lci(0))
    L("SWB")
    I(*ld(SK), sm("RB"))
    I(op("SUB", "R", 1), w(SK), sm("WBL"))
    I(op("PASSX", "SBL", fl=True), sm("RP"))       # the head (the bucket's last polygon); -1: empty
    I()
    I(jc("N", "SWN"))
    L("SWE")
    I(op("PASSX", "SYB"), sm("RB"))                # its {t, ybot} bucket
    I(op("PASSX", "SNX", fl=True))
    I(op("SUB", "SCT", 1), sm("SOW"))              # the position below the bucket's end
    I(op("PASSX", "SNX"), sm("RP"))
    I(jnc("N", "SWE"))
    L("SWN")
    I(djnz("SWB"))
    I(ra(SO), op("SUB", "QA", 1, fl=True), w(SO))
    I()
    I(jnc("Z", "SWO"))
    I(ret())

    # SRETAG: re-tag the 512 buckets {t, ytop} from R = 0x100FF down
    L("SRETAG")
    I(w(SK))
    I(li(8), w(SO))
    L("SRO")
    I(*ld(SK), lci(0))
    L("SRB")
    I(sm("RB"))
    I(op("SUB", "R", 1), w(SK), sm("WBL"), djnz("SRB"))
    I(ra(SO), op("SUB", "QA", 1, fl=True), w(SO))
    I()
    I(jnc("Z", "SRO"))
    I(ret())

# ======================================================================
# vertices (SubmitVertex)
# ======================================================================
L("VTX16")
I(ra(PARAM), op("SX16", "QA"), w(CURV))        # ExecParams[0], [1]: the PARAM words
I(ra(PARAM), op("SAR", "QA", 16), w(CURV + 1))
I(ra(PARAM + 1), op("SX16", "QA"), w(CURV + 2), jmp("SUBV"))
if not FF:
    L("VTX10")
    I(op("SHL", "P", 22))
L("VTX10b")
I(op("SAR", "R", 16), w(CURV))
I(op("SHL", "P", 12))
I(op("AND", "R", 0xFFC00000))
I(op("SAR", "R", 16), w(CURV + 1))
I(op("SHL", "P", 2))
I(op("AND", "R", 0xFFC00000))
I(op("SAR", "R", 16), w(CURV + 2), jmp("SUBV"))
if not FF:
    L("VTXXY")
    I(op("SX16", "P"), w(CURV))
L("VTXXYb")
I(op("SAR", "P", 16), w(CURV + 1), jmp("SUBV"))
if not FF:
    L("VTXXZ")
    I(op("SX16", "P"), w(CURV))
L("VTXXZb")
I(op("SAR", "P", 16), w(CURV + 2), jmp("SUBV"))
if not FF:
    L("VTXYZ")
    I(op("SX16", "P"), w(CURV + 1))
L("VTXYZb")
I(op("SAR", "P", 16), w(CURV + 2), jmp("SUBV"))
if not FF:
    L("VTXDIFF")
for k, sh in enumerate((22, 12, 2)):
    if k or not FF:
        I(op("SHL", "P", sh))
    if k == 0:
        L("VTXDIFFb")
    I(op("SAR", "R", 22))
    I(rb(CURV + k), op("ADD", "R", "QB"))
    I(op("SX16", "R"), w(CURV + k), *((jmp("SUBV"),) if k == 2 else ()))


def xf_ins(xg, tex):
    """Position = (CurVertex, 1) * clip matrix into group X[xg], with the
    colour and the texture coordinates (tex: texture coordinate mode 3).
    16 MACs, one per cycle; the Position words leave 3 after their last
    MAC, the colour copies use port B in the cycles of the w-term MACs."""
    scope(u("xf"))
    ins = [[nh()] for _ in range(29 if tex else 19)]
    for c in range(4):
        for k in range(4):
            i = 4 * c + k
            if k < 3:
                ins[i] += [ra(CURV + k), rb(CLIP + 4 * k + c), mac("LD" if k == 0 else "ADD", "QA", "QB")]
            else:
                ins[i] += [ra(CLIP + 12 + c), mac("ADD", "QA", 0x1000)]
                if c < 3:
                    ins[i] += ([op("PASSX", atr(CURCOL + c))] if FF else [rb(CURCOL + c), op("OR", "ZERO", "QB")]) + \
                              [w(G_C + c, xg)]
        ins[4 * c + 6] += [op("PASSX", "ACCX", sh=12), w(G_P + c, xg), out("VPOS")]
    if tex:
        # ((x T[c] + y T[4+c] + z T[8+c]) >> 24) + RawTexCoords[c], as s16:
        # one accumulation of Raw << 24 and the three products
        for c in range(2):
            b = 16 + 4 * c
            if FF and FF_VM:
                # RawTexCoords from its latch through R (ins[15] and ins[19] have no ALU operation)
                ins[b - 1] += [op("PASSX", atr(RAWTC + c))]
                ins[b] += [mac("LD", "R", 1 << 24)]
            else:
                ins[b] += [ra(RAWTC + c), mac("LD", "QA", 1 << 24)]
            for k in range(3):
                ins[b + 1 + k] += [ra(CURV + k), rb(TEX + 4 * k + c), mac("ADD", "QA", "QB")]
            ins[b + 6] += [op("PASSX", "ACCX", sh=12)]      # acc >> 24 as s16: bits 24..39 of acc
            ins[b + 7] += [op("SHR", "R", 12)]              # are bits 12..27 of this word
            ins[b + 8] += [op("SX16", "R"), w(G_T + c, xg)]
    else:
        for c in range(2):
            ins[15 + c] += ([op("PASSX", atr(TEXC + c))] if FF else [rb(TEXC + c), op("OR", "ZERO", "QB")]) + \
                           [w(G_T + c, xg)]
    return ins


def xf_ff(xg, tex):
    """FF: the transform on the vector MAC: four steps (clip-matrix rows times CurVertex x, y, z from its
    latch, then 0x1000; MB3), the lanes read out 3 after the last step as Position x, y, z, w, the colour
    and TexCoords copies from the attribute latches in the free ALU slots. tex (texture coordinate mode
    3): a second pass from row 4 (lanes 0 and 1: the texture matrix's columns times x, y, z, then
    RawTexCoords << 12 times 0x1000), read as bits 24..39 (xf_ins's acc >> 24 as s16)"""
    n = 15 if tex else 10
    ins = [[] for _ in range(n)]
    for k in range(4):
        ins[k] += [vmac("VLD" if k == 0 else "VADD", "MB3")]
    for k in range(3):
        ins[k] += [op("PASSX", atr(CURCOL + k)), w(G_C + k, xg)]
    for c in range(4):
        ins[6 + c] += [op("PASSX", vxr(c)), w(G_P + c, xg), out("VPOS")]
    if not tex:
        for c in range(2):
            ins[3 + c] += [op("PASSX", atr(TEXC + c)), w(G_T + c, xg)]
        return ins
    # hand-scheduled (nh): VLDT at 7 changes what the lanes read from 10 on (a lane read at t sees its
    # sum as of t - 3), after Position's last read at 9
    for i in range(3, n):
        ins[i] += [nh()]
    for k in range(4):
        ins[7 + k] += [vmac("VLDT" if k == 0 else "VADD", "MB3")]
    for c in range(2):
        ins[13 + c] += [op("PASSX", vxr(4 + c)), w(G_T + c, xg)]
    return ins


def transform_both(xg):
    """both variants, sharing their first words (the flags of the texture mode test stay set)"""
    a, b = (xf_ff(xg, False), xf_ff(xg, True)) if FF and FF_VM else (xf_ins(xg, False), xf_ins(xg, True))
    sh = 3 if FF and FF_VM else 15
    assert a[:sh] == b[:sh]
    if PU:
        # the texture mode from TEXM's latch (TEX3); the early-start window opens once the transform has
        # read CURCOL (instructions 0-2: VADV's dirty(2)); the last instruction steps the polygon unit and
        # goes to the polygon (SUBP) when it completes one, else to the next command
        for v in (a, b):
            v[3] = v[3] + [dirty(2)]
            v[-1] = v[-1] + [jc("PSTEP", "SUBP")]
    if FF and FF_VM and PU and LUNIT:
        # FF: the lighting unit may still work on this vertex's colour when the transform starts (SUBV no
        # longer waits): TexCoords first (the texture variant writes G_T again at its end), CURCOL after a
        # LBUSY test at the second step (a busy unit: LTW waits, then the rest as below); the early-start
        # window (dirty(2)) after the CURCOL reads
        for v in (a, b):
            for k in range(3):
                v[k] = [p_ for p_ in v[k] if not (isinstance(p_, dict) and p_.get("wa") == G_C + k)]
                v[k] = [p_ for p_ in v[k] if not (isinstance(p_, dict) and p_.get("xs") == E["XS"]["ATR"])]
            v[3] = [p_ for p_ in v[3] if p_ != dirty(2)]
        def strip_alu(parts):
            return [p_ for p_ in parts if not (isinstance(p_, dict) and ("aop" in p_ or "wa" in p_))]
        a = [list(x) for x in a]
        b = [list(x) for x in b]
        for v in (a, b):
            v[3] = strip_alu(v[3]) if v is a else v[3]
            v[4] = strip_alu(v[4]) if v is a else v[4]
        for v in (a, b):
            v[0] += [op("PASSX", atr(TEXC)), w(G_T, xg)]
            v[1] += [op("PASSX", atr(TEXC + 1)), w(G_T + 1, xg)]
            v[2] += [op("PASSX", atr(CURCOL)), w(G_C, xg)]
            v[3] += [op("PASSX", atr(CURCOL + 1)), w(G_C + 1, xg)]
            v[4] += [op("PASSX", atr(CURCOL + 2)), w(G_C + 2, xg)]
            v[5] += [dirty(2)]
        scope(u("xf"))
        I(*a[0])
        I(*a[1], jc("LBUSY", "LTW"))
        for i in range(2, len(a)):
            I(*a[i], *((jc("TEX3", "SV3"),) if i == 2 else ()))
        I(disp(NOENT))
        L("SV3")
        for parts in b[3:]:
            I(*parts)
        I(disp(NOENT))
        L("LTW")                       # the lighting unit's colour: wait, then as from the third step
        I(jc("LBUSY", "LTW"))
        for i in range(2, len(a)):
            I(*a[i], *((jc("TEX3", "SV3"),) if i == 2 else ()))
        I(disp(NOENT))
        scope(None)
        return
    scope(u("xf"))
    for i, parts in enumerate(a):
        I(*parts, *((jc("TEX3" if PU else "Z", "SV3"),) if i == sh - 1 else ()))
    I(disp(NOENT) if PU else jmp("VADV"))
    L("SV3")
    for parts in b[sh:]:
        I(*parts)
    if PU:
        I(disp(NOENT))
    scope(None)


xclear()
xrange(1, GRP, GRP + 512 - 16)
xrange(2, 0, 6)              # SVNEXT: the slot number
L("SUBV")
if PU and LUNIT:
    # the dispatcher set X1 to the vertex's slot group, and goes straight to SV1 when nothing waits (the
    # lighting unit idle, the clip matrix clean, no TEXM write in flight); here R takes it while the
    # lighting unit finishes, again after CLIPUPD (which took X1)
    I(pu(PU_CUR), *(() if FF and FF_VM else (jc("LBUSY", "SUBV"),)))   # CURCOL from the lighting unit (FF: in the transform)
    I(jnc("DIRTY", "SVPU"))
    I(call("CLIPUPD"))
    I(pu(PU_CUR))
    I()
    L("SVPU")
    I(setx(1))
    L("SV1")
    DISP_ENTRY.extend(["SUBV", "SV1"])
elif PU:
    I(jnc("DIRTY", "SVPU"))
    I(call("CLIPUPD"))
    L("SVPU")
    I(pu(PU_CUR))
    I()
    I(setx(1))
    L("SV1")
    DISP_ENTRY.extend(["SUBV", "SV1"])
else:
    if LUNIT:
        I(jc("LBUSY", "SUBV"))         # CURCOL from the lighting unit
    I(jnc("DIRTY", "SVPU"))
    I(call("CLIPUPD"))
    L("SVPU")
    L("SV1")
    I(*ld(CURSLOT))
    I(ra(TEXM), op("SUB", "QA", 3, fl=True))
    I(setx(1))
transform_both(1)

# VertexNumInPoly: a polygon when it reaches VLIM (3 or 4), then VRST (0 or 2)
# X2 = the new VertexNumInPoly and CURSLOT = SLOT[X2] while the comparison's flags settle; a completed
# polygon (falling through) sets CURSLOT again after its rotation (SVNEXT)
def vadv_svsub():
    """VertexNumInPoly and the slot rotation in microcode (without the polygon unit)"""
    L("VADV")
    # LUNIT: dirty(2) opens the early-start window (dirty unchanged): the transform has read CURCOL, and nothing
    # from here to the next DISP writes what the lighting unit reads, so gpu3d_gxeng may start it on a NORMAL
    # at the FIFO head now (docs/geometry-engine.md "Early start")
    I(ra(VNIP), op("ADD", "QA", 1), w(VNIP), *((dirty(2),) if LUNIT else ()))
    I()
    I(rb(VLIM), op("SUB", "R", "QB", fl=True), setx(2))
    I(*ld(SLOT, 2), w(CURSLOT))
    I(jnc("Z", "D1"))

    L("SVSUB")
    # each primitive kind has its own SUBP call, rotation and CURSLOT load: VertexNumInPoly restarts at
    # VRST (0 for separate polygons, 2 for strips), so the next vertex's slot is SLOT[0] or SLOT[2]
    I(*ld(VRST), w(VNIP))
    I(*ld(PMODE))
    I()
    I(jnc("BIT", "SVL", bit=1))            # triangles, quads: no rotation
    I(jc("BIT", "SVQ", bit=0))
    # triangle strip: NumConsecutivePolygons odd: swap TempVertexBuffer[0]/[1]
    # first, then [1] = [2]; even: [0] = [1], [1] = [2] after the polygon
    I(ra(NCONS), op("XOR", "QA", 1), w(NCONS))
    I()
    I(jnc("BIT", "SVTO", bit=0))           # now even: it was odd
    I(call("SUBP"))
    # [0] <- [1] <- [2] <- [0]
    I(*ld(SLOT), w(T))
    I(*ld(SLOT + 1), w(SLOT))
    I(*ld(SLOT + 2), w(SLOT + 1))
    I(*ld(T), w(SLOT + 2))
    I(w(CURSLOT), jmp("D1"))               # R = the new SLOT[2]
    scope("swap")
    L("SVTO")
    I(ra(SLOT), op("PASSX", "QA"), w(SLOT + 1))
    I(rb(SLOT + 1), op("OR", "ZERO", "QB"), w(SLOT), nh())
    I(call("SUBP"))
    # swap [1]/[2]
    I(ra(SLOT + 1), op("PASSX", "QA"), w(SLOT + 2))
    I(rb(SLOT + 2), op("OR", "ZERO", "QB"), w(SLOT + 1), nh())
    I(*ld(SLOT + 2), w(CURSLOT), jmp("D1"))
    L("SVQ")
    # quad strip: swap [2]/[3] first, then [0] = [3], [1] = [2]
    I(ra(SLOT + 2), op("PASSX", "QA"), w(SLOT + 3))
    I(rb(SLOT + 3), op("OR", "ZERO", "QB"), w(SLOT + 2), nh())
    I(call("SUBP"))
    # swap [0]/[3] and [1]/[2]
    I(ra(SLOT), op("PASSX", "QA"), w(SLOT + 3))
    I(rb(SLOT + 3), op("OR", "ZERO", "QB"), w(SLOT), nh())
    I(ra(SLOT + 1), op("PASSX", "QA"), w(SLOT + 2))
    I(rb(SLOT + 2), op("OR", "ZERO", "QB"), w(SLOT + 1), nh())
    I(*ld(SLOT + 2), w(CURSLOT), jmp("D1"))
    scope(None)
    L("SVL")
    I(call("SUBP"))
    I(*ld(SLOT), w(CURSLOT), jmp("D1"))


if not PU:
    vadv_svsub()

# ======================================================================
# polygon submission (SubmitPolygon)
# ======================================================================
D0Y, D2W, D0W, D2Y, D2X, D0X, NX, NY, NZ = (T + k for k in range(9))

xclear()
xrange(1, GRP, GRP + 512 - 16)
xrange(2, GRP, GRP + 512 - 16)
xrange(3, GRP, GRP + 512 - 16)
# FF: SubmitPolygon starts with the outcodes (CULLOK) and rejects a polygon wholly outside one plane before
# the cull (CR4); the cull (SUBPC) then continues at CR5. Exact: such a polygon is rejected after the cull too
# (DOCLIP's trivial reject, or the cull itself), with the same outcome, and the cull reads nothing CULLOK writes
if PU:
    # the polygon unit completed a polygon at the transform's last instruction (PSTEP) and set X1..X3 to
    # its slots 0..2 (as SVSUB would before calling SUBP); the polygon's RET comes back here
    L("SUBP")
    I(call("SUBPC"))
    I(disp(NOENT))
    L("SUBPC")
else:
    L("SUBPC" if FF else "SUBP")
    I(*ld(SLOT))
    I(*ld(SLOT + 1))
    I(setx(1), *ld(SLOT + 2))              # setx reads R two back: SLOT[0], then [1], then [2]
    I(setx(2))
    I(setx(3))
# d0 = v0 - v1, d2 = v2 - v1 (x, y, w), 32-bit
for dst, xv, comp in ((D0Y, 1, 1), (D2W, 3, 3), (D0W, 1, 3), (D2Y, 3, 1), (D2X, 3, 0), (D0X, 1, 0)):
    I(ra(comp, xv), rb(comp, 2), op("SUB", "QA", "QB"), w(dst))
# normal X = d0y d2w - d0w d2y, Y = d0w d2x - d0x d2w, Z = d0x d2y - d0y d2x;
# each must fit in s32 (else CULLBIG shifts them), then
# dot = v1x X + v1y Y + v1w Z. Cycles after the first MAC (c0):
#   X: MACs 0, 1; low word at 4; fit checked at 6
#   Y: MACs 2, 3; low word at 6; fit at 8
#   Z: MACs 4, 5; low word at 8; fit at 10; dot MACs 8, 9, 11; flags at 16
scope("cull")
OCM, SA = OCANY, T2 + 4                 # (as below: the outcode mask of the list; the trivial-reject AND)
# PU: the polygon unit's list words (CR5's) LA and LN go to the register file in the cull's free ALU and write
# slots before its first NFIT branch (CULLBIG rejoins at CULLDOT), OCM in CULLDOT's flag wait (the outcode unit
# has written the last vertex's by then); a rejected polygon's are never read (the box test sets its own)
PUC = PU and FF                        # the list words in the cull's free slots
I(ra(D0Y), rb(D2W), mac("LD", "QA", "QB"))                                    # 0
# PU: wholly outside one plane (clipstart 0): rejected, as CR4 does before the cull (the outcomes agree: such a
# polygon is rejected after the cull too), and before its first NFIT branch. The last vertex's outcodes are
# written 10 clocks after the step (gpu3d_gxeng checks that the outcode unit is idle here)
I(ra(D0W), rb(D2Y), mac("SUB", "QA", "QB"), *((jc("PTRIV", "PREJ"),) if PU else ()))   # 1
I(ra(D0W), rb(D2X), mac("LD", "QA", "QB"))                                    # 2
I(ra(D0X), rb(D2W), mac("SUB", "QA", "QB"))                                   # 3
I(ra(D0X), rb(D2Y), mac("LD", "QA", "QB"), op("PASSX", "ACCX"), w(NX), nh())  # 4
I(ra(D0Y), rb(D2X), mac("SUB", "QA", "QB"), nh())                             # 5
I(op("PASSX", "ACCX"), w(NY), jc("NFIT", "CULLBIG"), nh())                    # 6
I(nh(), *((pu(PU_LA), w(LA)) if PUC else ()))                                 # 7
I(ra(0, 2), rb(NX), mac("LD", "QA", "QB"), op("PASSX", "ACCX"), w(NZ),
  jc("NFIT", "CULLBIG"), nh())                                                # 8
I(ra(1, 2), rb(NY), mac("ADD", "QA", "QB"), nh(), *((pu(PU_LA + 1), w(LA + 1)) if PUC else ()))   # 9
I(jc("NFIT", "CULLBIG"), nh(), *((pu(PU_LA + 2), w(LA + 2)) if PUC else ()))  # 10
I(ra(3, 2), rb(NZ), mac("ADD", "QA", "QB"), nh(), *((pu(PU_LA + 3), w(LA + 3)) if PUC else ()))   # 11
scope(None)
L("CULLDOT")
if PUC:
    I(pu(PU_LN), w(LN))
    I()
    I(pu(PU_OCM, fl=True), w(OCM))     # CR5's Z test (CS and SA there: the box test's clip reads the last kept polygon's)
    I(*ld(CATTR))
else:
    I(*ld(CATTR))
    I()
    I()
    I()
I(jc("AZ", "CFACE"))                   # dot == 0: facing, kept
I(jc("A63", "CNEG"))
I(jnc("BIT", "PREJ", bit=6))           # dot > 0: needs attr bit 6
I(li(0), w(FACING), jmp("CR5" if FF else "CULLOK"))
L("CNEG")
I(jnc("BIT", "PREJ", bit=7))           # dot < 0: needs attr bit 7
L("CFACE")
I(li(1), w(FACING), jmp("CR5" if FF else "CULLOK"))

# the polygon is not submitted: no last strip polygon; outcome "rejected"
L("PREJ")
I(li(1), out("OC"))
I(li(0), w(LSREUSE), ret())

# normals that do not fit in s32: shift all three right by 4 until they do
# (k = smallest multiple of 4 with every (n >> k) in s32), with 64-bit values
NXL, NYL, NZL, NXH, NYH, NZH, TOR = (T + 9 + k for k in range(7))
SGN, MH, K32, PT = T2, T2 + 1, T2 + 2, T2 + 3
L("CULLBIG")
# component c's MACs at 3c, 3c + 1; the accumulator as of cycle t - 3 is read at t, so with no MAC at
# 3c + 2 it holds c for two reads, 3c + 4 (low word) and 3c + 5 (high)
scope("cbig")
ins = [[nh()] for _ in range(12)]
if PUC:                                # the list words the cull's later slots would have taken
    for k, i_ in enumerate((0, 1, 2, 3)):
        ins[i_] += [pu(PU_LA + k), w(LA + k)]
for c, (a0, b0, a1, b1, lo, hi) in enumerate(((D0Y, D2W, D0W, D2Y, NXL, NXH),
                                              (D0W, D2X, D0X, D2W, NYL, NYH),
                                              (D0X, D2Y, D0Y, D2X, NZL, NZH))):
    ins[3 * c] += [ra(a0), rb(b0), mac("LD", "QA", "QB")]
    ins[3 * c + 1] += [ra(a1), rb(b1), mac("SUB", "QA", "QB")]
    ins[3 * c + 4] += [op("PASSX", "ACCX"), w(lo)]
    ins[3 * c + 5] += [op("PASSX", "ACCX", sh=32), w(hi)]
for parts in ins:
    I(*parts)
scope(None)
# t = m >> 31 with m = n ^ (n >> 63) (so m >= 0), by MABS per component; k = smallest multiple of 4 with
# (t_x | t_y | t_z) >> k == 0 (at most 32), by K4; n >> k (low 32 bits) by FSH
I(ra(NXL), rb(NXH), op("MABS", "QA", "QB"), w(SGN))
I(ra(NYL), rb(NYH), op("MABS", "QA", "QB"), w(MH))
I(ra(NZL), rb(NZH), op("MABS", "QA", "QB"))
I(rb(SGN), op("OR", "R", "QB"))
I(rb(MH), op("OR", "R", "QB"))
I(op("K4", "R"))
for lo, hi, dst in ((NXL, NXH, NX), (NYL, NYH, NY), (NZL, NZH, NZ)):
    I(ra(lo), rb(hi), op("FSH", "QA", "QB"), w(dst))
L("CBKDOT")
I(ra(0, 2), rb(NX), mac("LD", "QA", "QB"))
I(ra(1, 2), rb(NY), mac("ADD", "QA", "QB"))
I(ra(3, 2), rb(NZ), mac("ADD", "QA", "QB"), jmp("CULLDOT"))



TRIVM = 0x3B                            # planes the trivial reject tests (not z > w)
OCM, NEWV = OCANY, OCFAR                # outcode mask of the list; new vertices this plane
OCNW, CUR, IDX, BOXF = V(), V(), V(), V()
# trivial reject (the final-colour temporaries are free until the clip is done)
SA = T2 + 4
CLPV = T + 8                            # COMMIT: the polygon was clipped and DSR is set


# outcodes of the vertex in X1 into OCM: bits x>w y>w z>w x<-w y<-w z<-w
xclear()
xrange(1, GRP, GRP + 512 - 16)
scope("ocv")
L("OCV")
I(ra(3, 1), op("RSUB", "QA", 0), w(OCNW))
I(ra(3, 1), rb(0, 1), op("SLT", "QA", "QB"))
I(ra(3, 1), rb(1, 1), op("SLT", "QA", "QB"), mac("LD", "R", 1))
I(ra(3, 1), rb(2, 1), op("SLT", "QA", "QB"), mac("ADD", "R", 2))
I(ra(0, 1), rb(OCNW), op("SLT", "QA", "QB"), mac("ADD", "R", 4))
I(ra(1, 1), rb(OCNW), op("SLT", "QA", "QB"), mac("ADD", "R", 8))
I(ra(2, 1), rb(OCNW), op("SLT", "QA", "QB"), mac("ADD", "R", 16))
I(mac("ADD", "R", 32))
nops(2)
I(rb(OCM), op("OR", "ACCX", "QB"), w(OCM), ret())
scope(None)

# The outcodes of a vertex the transform made come from the hardware outcode unit (gpu3d_gxeng.sv),
# read by group (X1): VOCW the plain bits (as OCV), VOCS the strong ones, comp - w >= 7 or -w - comp >= 7
# (never z > w), 0 unless every coordinate is inside +-2^29. A polygon whose vertices all have one strong
# bit is clipped to nothing: melonDS interpolates a clipped vertex as vin + trunc(d * num / den), the
# truncation is monotone, so a pass over another component loses nothing and a pass over the same one
# (y+ then y-: the component is overwritten by +-w') at most two units, and at most six passes come
# before the last plane; the range keeps melonDS's s32 differences and factors from wrapping.
L("OCVH")
I(rb(OCM), op("OR", "VOCW", "QB"), w(OCM))
I(rb(SA), op("AND", "VOCS", "QB"), w(SA), ret())

# for strips: two original vertices shared with the last strip polygon
# (copied into slots 4, 5 when it was committed) start the vertex list
xclear()
xrange(1, GRP, GRP + 512 - 16)
xrange(2, LA, LA + 10)       # list_loop: the list entry
# The vertices' outcodes (OCVH inline): X1 = the vertex group, its outcodes readable two clocks after the
# setx and held while X1 is; the next vertex's slot is loaded meanwhile (setx reads R two back)
def ocvh_inline(last=()):
    I(rb(SA), op("AND", "VOCS", "QB"), w(SA))
    I(rb(OCM), op("OR", "VOCW", "QB"), w(OCM), *last)       # R = OCM (CR4)


def cullok():
    """the vertex list, its outcodes and (FF) the trivial reject, from the slots (without the polygon unit)"""
    if FF:
        L("SUBP")
    L("CULLOK")
    I(li(0), w(OCM))
    I(li(0x3F), w(SA))
    I(li(grp(NSLOTGRP)), w(POOL))          # clipping takes new vertices from here: moved = clipped (COMMIT)
    I(*ld(LSREUSE))
    I(li(0), w(CS))
    I(jc("BIT", "CR2", bit=0))
    I(*ld(SLOT), w(LA))
    I()
    I(setx(1))                             # X1 = SLOT[0]
    I(*ld(SLOT + 1), w(LA + 1))
    I(rb(OCM), op("OR", "VOCW", "QB"), w(OCM))
    I(rb(SA), op("AND", "VOCS", "QB"), w(SA), setx(1))      # X1 = SLOT[1]
    I()
    ocvh_inline((jmp("CR3"),))
    L("CR2")
    I(li(2), w(CS))
    I(*ld(SLOT + 4), w(LA))
    I(*ld(SLOT + 5), w(LA + 1))
    L("CR3")
    I(*ld(SLOT + 2), w(LA + 2))
    I(*ld(VLIM), w(LN))
    I(op("SUB", "R", 4, fl=True), setx(1))  # Z: a quad (VLIM 4); X1 = SLOT[2]
    I(*ld(SLOT + 3), w(LA + 3))
    I(rb(SA), op("AND", "VOCS", "QB"), w(SA))
    I(rb(OCM), op("OR", "VOCW", "QB"), w(OCM), setx(1))     # X1 = SLOT[3]; R = OCM (CR4)
    I(jnc("Z", "CR4"))
    ocvh_inline()
    L("CR4")
    if FF:
        I(*ld(CS, fl=True))
        I()
        I(jnc("Z", "SUBPC"))                   # clipstart 2: no trivial reject, the cull first
        I(ra(SA), op("AND", "QA", TRIVM, fl=True))
        I()
        I(jnc("Z", "PREJ"))                    # wholly outside one plane: rejected (DOCLIP's test), no cull
        I(jmp("SUBPC"))
        L("CR5")
        I(*ld(OCM, fl=True))
    else:
        I(op("OR", "R", 0, fl=True))       # R = OCM from the last outcode pair


if PU:
    # a polygon the cull keeps: its list words from the polygon unit (CULLOK's: LA, LN, CS, POOL, SA, and OCM
    # in R for the tests below)
    L("CR5")
    if PUC:
        I(li(grp(NSLOTGRP)), w(POOL))      # LA, LN, OCM at the cull (CULLDOT); the flags are OCM's
        I(pu(PU_CS), w(CS))
        I(pu(PU_SA), w(SA))
        I(*ld(OCM))                        # R = OCM for the far-plane bit below
    else:
        for k in range(4):
            I(pu(PU_LA + k), w(LA + k))
        I(pu(PU_LN), w(LN))
        I(pu(PU_CS), w(CS))
        I(li(grp(NSLOTGRP)), w(POOL))
        I(pu(PU_SA), w(SA))
        I(pu(PU_OCM, fl=True), w(OCM))
else:
    cullok()
I()
I(jc("Z", "NOCLIP"))
I(jnc("BIT", "DOCLIP", bit=2))         # nothing beyond the far plane
I(*ld(CS, fl=True))
I(*ld(CATTR))
I(jc("Z", "FARCK"))
# clipstart 2: melonDS runs the far-plane rule inside the clipper, which then keeps the reused pair (a polygon
# of 2 vertices); the DS (DSR bit 1, gpu3d_gxeng DS_FARREJ; hwref rand3d run 16) rejects it as for clipstart 0
I(jnc("DSR", "DOCLIP", bit=1))
L("FARCK")
I(jnc("BIT", "PREJ", bit=12))
L("DOCLIP")
# every vertex outside one plane by more than the clip's rounding: the clip is empty, as for LN == 0
# after it; not for clipstart 2, which keeps its first two vertices
I(*ld(CS, fl=True))
I()
I(jnc("Z", "NOTRIV"))
I(ra(SA), op("AND", "QA", TRIVM, fl=True))
I()
I(jnc("Z", "PREJ"))
L("NOTRIV")
I(li(grp(NSLOTGRP)), w(POOL))
I(li(1), w(ATT))
I(call("CLIP"))
I(*ld(T2 + 13))                        # FARF (defined with the clipper below)
I()
I(jc("BIT", "PREJ", bit=1))            # the clip ran out of pool groups
I(*ld(LN, fl=True))
I()
I(jc("Z", "PREJ"))
# polygon/vertex RAM overflow
if FF:
    L("NOCLIP")
    # as below: the zero-dot test first, then two copies of the overflow tests (a jc reads the newest flags or R
    # made at least two instructions before it, so no other flag write between)
    I(op("XOR", "ZDOT", 0xFFFFFF, fl=True))
    I(*ld(NP))
    I(op("SUB", "R", 2048, fl=True), jnc("Z", "NCZ"))         # the zero-dot rule may still reject it: NCZ
    I(ra(NV), rb(LN), op("ADD", "QA", "QB"))
    I(op("SUB", "R", 6145, fl=True), jnc("LT", "POVF"))        # NP >= 2048
    I(ra(LN), op("XOR", "QA", 4))
    I(op("SLT", "R", 1), jnc("LT", "POVF"))                    # NV + LN > 6144; LN == 4
    I(op("SHL", "R", 1), out("OC"))                            # the outcome now
    I(li(0), w(ZWAIT), jmp("VPORT"))
    L("NCZ")
    I(ra(NV), rb(LN), op("ADD", "QA", "QB"))
    I(op("SUB", "R", 6145, fl=True), jnc("LT", "POVF"))
    I(*ld(CATTR))
    I(li(1), w(ZWAIT), jnc("LT", "POVF"))
    I(jnc("BIT", "VPORT", bit=13))
    I(*ld(LN))
    I(op("XOR", "R", 4))
    I(op("SLT", "R", 1))
    I(op("SHL", "R", 1), out("OC"))
    I(li(0), w(ZWAIT), jmp("VPORT"))
if not FF:
    L("NOCLIP")
    I(*ld(NP))
    I(op("SUB", "R", 2048, fl=True))
    I(ra(NV), rb(LN), op("ADD", "QA", "QB"))
    I(jnc("LT", "POVF"))                   # NP >= 2048
    I(op("SUB", "R", 6145, fl=True))
    I()
    I(jnc("LT", "POVF"))                   # NV + LN > 6144
    # the outcome now, unless the zero-dot rule may still reject it
    I(op("XOR", "ZDOT", 0xFFFFFF, fl=True))
    I(*ld(CATTR))
    I(jc("Z", "OCNOW"))
    I(li(1), w(ZWAIT))
    I(jnc("BIT", "VPORT", bit=13))
    L("OCNOW")
    I(li(0), w(ZWAIT))
    I(*ld(LN))                             # OCACC inline
    I(op("XOR", "R", 4))
    I(op("SLT", "R", 1))
    I(op("SHL", "R", 1), out("OC"), jmp("VPORT"))
L("POVF")
I(out("OVF"), jmp("PREJ"))

# outcome "submitted", quad when it has 4 vertices
L("OCACC")
I(*ld(LN))
I(op("XOR", "R", 4))
I(op("SLT", "R", 1))                   # LN == 4
I(op("SHL", "R", 1), out("OC"), ret())


def bvx():
    I(call("BVX"))


# bounds of the vertex in X1, list index IDX (IDXB = 15 - IDX):
# KT = min(y << 4 | i), KB = max(y << 13 | x << 4 | 15 - i), WOR |= w, DEG |= w == 0
L("BVX")
if True:
    I(ra(G_FY, 1), op("SHL", "QA", 4))
    I(rb(IDX), op("OR", "R", "QB"))
    I(rb(KT), op("MIN", "R", "QB"), w(KT))
    I(ra(G_FY, 1), op("SHL", "QA", 9))
    I(rb(G_FX, 1), op("OR", "R", "QB"))
    I(op("SHL", "R", 4))
    I(rb(IDXB), op("OR", "R", "QB"))
    I(rb(KB), op("MAX", "R", "QB"), w(KB))
    I(ra(G_W, 1), rb(WOR), op("OR", "QA", "QB"), w(WOR))
    I(ra(G_W, 1), op("SLT", "QA", 1))
    I(rb(DEG), op("OR", "R", "QB"), w(DEG), ret())


def list_loop(start_var, body, skip, count=True):
    """for list entries start_var..LN-1: X1 = the vertex (X2 points at it), IDX/IDXB counted"""
    lb = u("ll")
    if count:
        I(ra(start_var), op("RSUB", "QA", 15), w(IDXB))
    I(ra(start_var), op("ADD", "QA", LA))
    I(ra(start_var), op("PASSX", "QA"), *((w(IDX),) if count else ()))
    I(setx(2))                         # X2 = LA + start
    I(ra(LN), rb(start_var), op("SUB", "QA", "QB", fl=True))
    I()
    I(jc("Z", skip))
    I(lcr())                           # LC = LN - start
    L(lb)
    I(*ld(0, 2))
    I()
    I(setx(1))
    body()
    if count:
        I(ra(IDX), op("ADD", "QA", 1), w(IDX), addx(2, 1))
        I(ra(IDXB), op("SUB", "QA", 1), w(IDXB), djnz(lb))
    else:
        I(addx(2, 1), djnz(lb))


# ---- screen coordinates, Z, final colour and bounds of the new vertices
# (clipstart..LN-1); bounds only for the reused ones
if FF:
    # the reused pair's bounds (list entries 0, 1: IDX 0 and 1), then the loop's IDX/IDXB for CS = 2
    L("VPRU")
    I(li(0), w(IDX))
    I(li(15), w(IDXB))
    setx_from(LA, 1)
    bvx()
    I(li(1), w(IDX))
    I(li(14), w(IDXB))
    setx_from(LA + 1, 1)
    bvx()
    I(li(2), w(IDX))
    I(li(13), w(IDXB))
    I(li(LA + 2), jmp("VPRUB"))         # R = LA + CS for VPRUB's setx
L("VPORT")
if FF:
    # FF: the bounds' start values, the list's IDX/IDXB from CS, vp_ff's prologue and the W-buffer choice in one
    # pass (a jc on R's bit or the flags reads them two instructions after they are made); the reused pair's
    # bounds (CS = 2) in VPRU
    I(li(192 << 4), w(KT))
    I(li(15), w(KB))
    I(li(0), w(WOR))
    I(w(DEG))
    I(ra(CS), op("PASSX", "QA"), w(IDX))
    I(ra(CS), op("RSUB", "QA", 15), w(IDXB))
    I(ra(CS), op("ADD", "QA", LA), jc("BIT", "VPRU", bit=1))   # R two back: CS
    L("VPRUB")
    I(ra(LN), rb(CS), op("SUB", "QA", "QB", fl=True))
    I(setx(2), *ld(FATTR))             # X2 = LA + CS
    I(lcr(), jc("Z", "VPDONE"))        # LC = LN - CS
    I(*ld(0, 2), jc("BIT", "VPNW", bit=1))   # the first new vertex (X1 in vp_ff); W-buffering (FATTR bit 1)
if VFIN == 1:
    I(jc("VBUSY", "VPORT"))       # the last polygon's bounds are written
if not FF:
    I(li(192 << 4), w(KT))
    I(li(15), w(KB))
    I(li(0), w(WOR))
    I(w(DEG))
    I(w(IDX))
    I(*ld(CS))
    I(li(15), w(IDXB))
    I(jnc("BIT", "VPNEW", bit=1))
    setx_from(LA, 1)
    bvx()
    I(li(1), w(IDX))
    I(li(14), w(IDXB))
    setx_from(LA + 1, 1)
    bvx()
if not FF:
    L("VPNEW")
    list_loop(CS, lambda: I(call("VPV")), "VPDONE")
    I(jmp("VPDONE"))


# FinalColor = Color >> 12, then (c << 4) + 0xF unless 0; the record's 9 bits
def fcol(c, dst):
    I(ra(G_C + c, 1), op("SAR", "QA", 12, fl=True))
    I(op("SHL", "R", 4))
    s_ = u("fc")
    I(jc("Z", s_))
    I(op("OR", "R", 15))
    L(s_)
    I(op("AND", "R", 0x1FF), w(dst))


FC = T2 + 4                            # 3 words
VPT = T2 + 7                           # posX, posY, den
PK = T2 + 10                           # packing temporaries (4)


def pack_words():
    """beat words with the colour and texture coordinates:
    W1 = r << 25, W2 = r >> 7 | g << 2 | b << 11 | s << 20,
    W3 = (s & 0xFFFF | t << 16) >> 12"""
    I(ra(FC), op("SHL", "QA", 25), w(G_W1, 1))
    I(ra(FC + 1), op("SHL", "QA", 2), w(PK))
    I(ra(FC + 2), op("SHL", "QA", 11), w(PK + 1))
    I(ra(G_T, 1), op("SHL", "QA", 20), w(PK + 2))
    I(ra(G_T, 1), op("AND", "QA", 0xFFFF), w(PK + 3))
    I(ra(FC), op("SHR", "QA", 7))
    I(rb(PK), op("OR", "R", "QB"))
    I(rb(PK + 1), op("OR", "R", "QB"))
    I(rb(PK + 2), op("OR", "R", "QB"), w(G_W2, 1))
    I(ra(G_T + 1, 1), op("SHL", "QA", 16))
    I(rb(PK + 3), op("OR", "R", "QB"))
    I(op("SHR", "R", 12), w(G_W3, 1))


# viewport transform of the vertex in X1 (melonDS: W to 24 bits; the
# divisions through a 32-bit divider, halved when W > 0xFFFF), Z, colour,
# bounds; the colour, packing and bounds work runs during the divisions
VPS, VPZK, VPKB = PK, PK + 1, PK + 2  # FF viewport: W > 0xFFFF (the halving shift), the Z factor, KB's low bits


def vp_ff(wbuf):
    """FF: the viewport loop over the new vertices CS..LN-1 (list_loop's X2, IDX, IDXB, LC), VPV's results
    bit for bit with the bounds inline (VFIN-lite's BVX), scheduled around the divider: X, Y, then Z
    (not when W-buffering), each started as the last one ends, everything else in their waits; the
    next vertex is loaded during Z's (X3 keeps this one for its G_FZ write). The colour and texture
    coordinate words are read on idle ports after the G_W write (gpu3d_gxvfin)."""
    I()                                # VPORT's prologue (X2, LC, IDX, IDXB) loaded R with the first vertex
    I(setx(1))
    top, w0, vz = u("vpf"), u("vpw0"), u("vpz")
    # nh: the checker takes X-relative words as ranges; these three read words of their own vertex that
    # the loop's writes (G_FX, G_FY, the last vertex's G_FZ through X3) never are
    scope(top)
    L(top)
    I(jc("VARM", top))                 # the last vertex's words are written; arms the unit for G_W
    I(ra(G_P + 3, 1), op("AND", "QA", 0xFFFFFF, fl=True), w(G_W, 1), movx(3, 1), nh())
    I(ra(G_T, 1), rb(G_C, 1), op("SHR", "R", 16))
    I(ra(G_C + 1, 1), rb(G_C + 2, 1), op("MIN", "R", 1), w(VPS), jc("Z", w0))     # W > 0xFFFF: halved
    I(ra(G_W, 1), rb(G_P + 0, 1), op("ADD", "QA", "QB"), w(VPT))                  # posX = x + w
    I(ra(G_W, 1), rb(G_P + 1, 1), op("SUB", "QA", "QB"), w(VPT + 1))              # posY = w - y
    I(ra(G_W, 1), rb(VPS), op("SHR", "QA", "QB"))
    I(ra(G_T + 1, 1), op("SHL", "R", 1), w(VPT + 2))                              # den = (w >> s) << 1
    I(ra(VPT), rb(VPS), op("SHR", "QA", "QB"))
    I(rb(VP4), mac("LD", "R", "QB"))                                              # posX * Viewport[4]
    I(ra(VPT + 1), rb(VPS), op("SHR", "QA", "QB"), w(VPT + 1))
    if not wbuf:
        I(ra(G_P + 2, 1), op("SAR", "QA", 31), w(ZM))                             # z < 0
    I(rb(VPT + 2), op("PASSX", "R", "QB"), divs("D32", 10))                       # X
    if not wbuf:
        I(ra(VPT + 1), rb(VP5), mac("LD", "QA", "QB"), op("SHL", "R", 15))        # posY * Viewport[5]
        I(op("OR", "R", 0x4000), w(VPZK))                                        # +-0x4000: |z| * 0x4000
    else:
        I(ra(VPT + 1), rb(VP5), mac("LD", "QA", "QB"))
    I(ra(G_W, 1), rb(WOR), op("OR", "QA", "QB"), w(WOR))
    I(ra(G_W, 1), op("SLT", "QA", 1))
    I(rb(DEG), op("OR", "R", "QB"), w(DEG))
    waitd()
    I(rb(VPT + 2), op("PASSX", "Q", "QB"), divs("D32", 10))                       # Y; R = X's quotient
    I(rb(VP0), op("ADD", "R", "QB"))
    I(op("AND", "R", 0x1FF), w(G_FX, 1))
    if not wbuf:
        I(ra(G_P + 2, 1), rb(VPZK), mac("LD", "QA", "QB"), op("SHL", "R", 4), nh())
    else:
        I(op("SHL", "R", 4))
    I(rb(IDXB), op("OR", "R", "QB"), w(VPKB))                                    # x << 4 | 15 - i
    waitd()
    if not wbuf:
        I(rb(G_W, 1), op("PASSX", "Q", "QB"), divs("D64", 16), nh())              # Z; R = Y's quotient
        I(rb(VP3), op("ADD", "R", "QB"))
    else:
        I(rb(VP3), op("ADD", "Q", "QB"))
    I(op("AND", "R", 0xFF), w(G_FY, 1))
    I(op("SHL", "R", 13))
    I(rb(VPKB), op("OR", "R", "QB"))
    I(rb(KB), op("MAX", "R", "QB"), w(KB))                                       # KB = max(y << 13 | x << 4 | 15 - i)
    I(ra(G_FY, 1), op("SHL", "QA", 4))
    I(rb(IDX), op("OR", "R", "QB"))
    I(rb(KT), op("MIN", "R", "QB"), w(KT))                                       # KT = min(y << 4 | i)
    tail = u("vpt")
    L(tail)
    I(ra(IDX), op("ADD", "QA", 1), w(IDX), addx(2, 1))
    I(ra(IDXB), op("SUB", "QA", 1), w(IDXB))
    I(*ld(0, 2))                       # the next vertex (past the last one: a list word, unused)
    I()
    I(setx(1))
    if not wbuf:
        waitd()
        # Z = ((z * 0x4000) / w + 0x3FFF) * 0x200 as s32, clamped
        I(rb(ZM), op("XOR", "Q", "QB"))
        I(rb(ZM), op("SUB", "R", "QB"))
        I(op("ADD", "R", 0x3FFF))
        I(op("SHL", "R", 9))
        I(op("MAX", "R", 0))
        I(op("MIN", "R", 0xFFFFFF), w(G_FZ, 3), djnz(top))
    else:
        I(djnz(top))
    I(jmp("VPDONE"))
    scope(None)
    L(w0)                              # w == 0: position 0, Z 0x7FFE00 (as VPV's VPW0)
    I(li(0), ra(G_T + 1, 1), w(G_FX, 1))
    I(w(G_FY, 1))
    I(li(0x7FFE00), w(G_FZ, 1))
    I(call("BVX"))
    I(jmp(tail) if wbuf else jmp(vz))
    if not wbuf:
        # the Z path's tail without a division in flight
        L(vz)
        I(ra(IDX), op("ADD", "QA", 1), w(IDX), addx(2, 1))
        I(ra(IDXB), op("SUB", "QA", 1), w(IDXB))
        I(*ld(0, 2))
        I()
        I(setx(1), djnz(top))
        I(jmp("VPDONE"))


if FF:
    xclear()
    xrange(1, GRP, GRP + 512 - 16)
    xrange(2, LA, LA + 11)             # list_loop: the list entry (one past the last at the end)
    xrange(3, GRP, GRP + 512 - 16)
    vp_ff(False)
    L("VPNW")
    vp_ff(True)
elif VFIN:
    # gpu3d_gxvfin does the colour, the beat words and the new vertex's bounds from this traffic: armed by
    # the VARM wait, the G_W write starts it, the colour and texture coordinate words are read on idle ports (both paths),
    # the G_FY write gives the bounds. It takes one vertex at a time.
    L("VPV")
    I(jc("VARM", "VPV"))               # waits for the last vertex, then arms the unit for the G_W write below
    I(ra(G_P + 3, 1), op("AND", "QA", 0xFFFFFF, fl=True), w(G_W, 1))
    I(rb(G_P + 1, 1), ra(G_C, 1), op("SUB", "R", "QB"), w(VPT + 1))         # posY = w - y
    I(ra(G_P + 3, 1), rb(G_C + 1, 1), op("AND", "QA", 0xFFFFFF), jc("Z", "VPW0"))
    I(rb(G_P + 0, 1), ra(G_C + 2, 1), op("ADD", "R", "QB"), w(VPT))         # posX = x + w
    I(ra(G_P + 3, 1), rb(G_T, 1), op("AND", "QA", 0xFFFFFF))
    I(ra(G_T + 1, 1), op("SUB", "R", 0x10000, fl=True))                    # C: w <= 0xFFFF
    I(ra(G_W, 1), op("SHL", "QA", 1), w(VPT + 2))                          # den = w << 1
    I(jc("C", "VPDEN"))
    I(ra(VPT), op("SHR", "QA", 1), w(VPT))
    I(ra(VPT + 1), op("SHR", "QA", 1), w(VPT + 1))
    I(ra(G_W, 1), op("BIC", "QA", 1), w(VPT + 2))                          # (w >> 1) << 1
    L("VPDEN")
    I(ra(VPT), rb(VP4), mac("LD", "QA", "QB"))                            # posX * Viewport[4], mod 2^32
    I(ra(G_P + 2, 1), op("SAR", "QA", 31), w(ZM))                         # z < 0
    I(rb(VPT + 2), op("OR", "ZERO", "QB"), divs("D32", 10))
    I(ra(VPT + 1), rb(VP5), mac("LD", "QA", "QB"))                        # posY * Viewport[5]
    waitd()
    I(rb(VP0), op("ADD", "Q", "QB"))
    I(op("AND", "R", 0x1FF), w(G_FX, 1))
    I(rb(VPT + 2), op("OR", "ZERO", "QB"), divs("D32", 10))
    waitd()
    I(rb(VP3), op("ADD", "Q", "QB"))
    I(op("AND", "R", 0xFF), w(G_FY, 1))
    I(*ld(FATTR))
    I()
    I(jc("BIT", "VPBND", bit=1))
    I(*ld(ZM))
    I()
    I(jc("BIT", "VPZN", bit=0))
    I(ra(G_P + 2, 1), mac("LD", "QA", 0x4000), jmp("VPZD"))
    L("VPZN")
    I(ra(G_P + 2, 1), mac("LD", "QA", -0x4000))
    L("VPZD")
    I(rb(G_W, 1), op("OR", "ZERO", "QB"), divs("D64", 16))
    if VFIN == 2:
        bvx()                          # VFIN-lite: the bounds stay in microcode
    waitd()
    I(rb(ZM), op("XOR", "Q", "QB"))
    I(rb(ZM), op("SUB", "R", "QB"))
    I(op("ADD", "R", 0x3FFF))
    I(op("SHL", "R", 9))
    I(op("MAX", "R", 0))
    I(op("MIN", "R", 0xFFFFFF), w(G_FZ, 1), ret())
    L("VPBND")
    I(jmp("BVX") if VFIN == 2 else ret())
    L("VPW0")                          # w == 0: position 0, Z 0x7FFE00
    I(li(0), ra(G_C + 2, 1), rb(G_T, 1), w(G_FX, 1))
    I(ra(G_T + 1, 1), w(G_FY, 1))
    if VFIN == 2:
        I(li(0x7FFE00), w(G_FZ, 1))
        I(jmp("BVX"))
    else:
        I(li(0x7FFE00), w(G_FZ, 1), ret())
else:
    L("VPV")
    I(ra(G_P + 3, 1), op("AND", "QA", 0xFFFFFF, fl=True), w(G_W, 1))
    I(rb(G_P + 1, 1), op("SUB", "R", "QB"), w(VPT + 1))           # posY = w - y
    I(ra(G_P + 3, 1), op("AND", "QA", 0xFFFFFF), jc("Z", "VPW0"))
    I(rb(G_P + 0, 1), op("ADD", "R", "QB"), w(VPT))               # posX = x + w
    I(ra(G_P + 3, 1), op("AND", "QA", 0xFFFFFF))
    I(op("SUB", "R", 0x10000, fl=True))                           # C: w <= 0xFFFF
    I(ra(G_W, 1), op("SHL", "QA", 1), w(VPT + 2))                  # den = w << 1
    I(jc("C", "VPDEN"))
    I(ra(VPT), op("SHR", "QA", 1), w(VPT))
    I(ra(VPT + 1), op("SHR", "QA", 1), w(VPT + 1))
    I(ra(G_W, 1), op("BIC", "QA", 1), w(VPT + 2))                  # (w >> 1) << 1
    L("VPDEN")
    I(ra(VPT), rb(VP4), mac("LD", "QA", "QB"))                    # posX * Viewport[4], mod 2^32
    I(ra(G_P + 2, 1), op("SAR", "QA", 31), w(ZM))                 # z < 0
    I(rb(VPT + 2), op("OR", "ZERO", "QB"), divs("D32", 10))
    I(ra(VPT + 1), rb(VP5), mac("LD", "QA", "QB"))                # posY * Viewport[5]
    I(call("COL01"))
    waitd()
    I(rb(VP0), op("ADD", "Q", "QB"))
    I(op("AND", "R", 0x1FF), w(G_FX, 1))
    I(rb(VPT + 2), op("OR", "ZERO", "QB"), divs("D32", 10))
    I(call("COL2PK"))
    waitd()
    I(rb(VP3), op("ADD", "Q", "QB"))
    I(op("AND", "R", 0xFF), w(G_FY, 1))
    # Z = ((z * 0x4000) / w + 0x3FFF) * 0x200 as s32, clamped (W-buffering: later)
    I(*ld(FATTR))
    I()
    I(jc("BIT", "VPBND", bit=1))
    I(*ld(ZM))
    I()
    I(jc("BIT", "VPZN", bit=0))
    I(ra(G_P + 2, 1), mac("LD", "QA", 0x4000), jmp("VPZD"))
    L("VPZN")
    I(ra(G_P + 2, 1), mac("LD", "QA", -0x4000))
    L("VPZD")
    I(rb(G_W, 1), op("OR", "ZERO", "QB"), divs("D64", 16))
    bvx()
    waitd()
    I(rb(ZM), op("XOR", "Q", "QB"))
    I(rb(ZM), op("SUB", "R", "QB"))
    I(op("ADD", "R", 0x3FFF))
    I(op("SHL", "R", 9))
    I(op("MAX", "R", 0))
    I(op("MIN", "R", 0xFFFFFF), w(G_FZ, 1), ret())
    L("VPBND")
    I(jmp("BVX"))
    L("VPW0")                              # w == 0: position 0, Z 0x7FFE00
    I(li(0), w(G_FX, 1))
    I(w(G_FY, 1))
    I(li(0x7FFE00), w(G_FZ, 1))
    I(call("COL01"))
    I(call("COL2PK"))
    I(jmp("BVX"))

# the final colour and the pre-packed beat words, in two parts (FF: gpu3d_gxvfin's)
if not FF:
    L("COL01")
    fcol(0, FC)
    fcol(1, FC + 1)
    I(ret())
    L("COL2PK")
    fcol(2, FC + 2)
    pack_words()
    I(ret())

# ---- zero-dot rule: rejected when every vertex has the first one's screen
# position and a W beyond DISP_1DOT_DEPTH (only when the outcome waited)
L("VPDONE")
I(*ld(ZWAIT))
I()
I(jnc("BIT", "BOUNDS", bit=0))
setx_from(LA, 1)
I(*ld(G_FX, 1), w(ZX))
I(*ld(G_FY, 1), w(ZY))
I(li(0), w(LI))
L("ZDL")
I(ra(LI), rb(LN), op("SUB", "QA", "QB", fl=True))
I()
I(jnc("LT", "PREJ"))                   # zero dot and all behind
I(ra(LI), op("ADD", "QA", LA))
I()
I(setx(2))
setx_from(0, 1, 2)
I(ra(G_FX, 1), rb(ZX), op("SUB", "QA", "QB", fl=True))
I()
I(jnc("Z", "ZDACC"))
I(ra(G_FY, 1), rb(ZY), op("SUB", "QA", "QB", fl=True))
I()
I(jnc("Z", "ZDACC"))
I(rb(G_W, 1), op("SLT", "ZDOT", "QB"))                        # limit < w
I()
I(jnc("BIT", "ZDACC", bit=0))
I(ra(LI), op("ADD", "QA", 1), w(LI), jmp("ZDL"))
L("ZDACC")
I(call("OCACC"))

# ---- W size (a multiple of 4 covering every W), YBottom > 192 degenerate
L("BOUNDS")
if VFIN:
    I(jc("VBUSY", "BOUNDS"))      # the bounds and beat words are in the register file
# K4: the smallest multiple of 4 with WOR >> k == 0 (WOR < 2^24, so k <= 24); it also sets kreg,
# which only CULLBIG's FSH reads, after its own K4
I(ra(WOR), op("K4", "QA"), w(WS))
HV = T2 + 14                           # 2 words
if FF and USORT:
    # FF: as below, one R chain for word 3's fields, the header's MACs on free ports; T+1 = ybot << 3 |
    # facing << 11 | wbuffer << 12 | degenerate << 13 = ((deg << 2 | wb << 1 | facing) << 8 | ybot) << 3
    L("WSD")
    I(op("RSUB", "R", 16))
    I(op("MAX", "R", 0), w(WSL))       # left shift 16 - wsize
    I(ra(WS), op("SUB", "QA", 16))
    I(op("MAX", "R", 0), w(WSR))       # right shift wsize - 16
    I(ra(KB), op("SHR", "QA", 13), w(HV))                  # YBottom
    I(op("SLT", "R", 193))
    I(op("XOR", "R", 1))
    I(rb(DEG), op("OR", "R", "QB"), w(DEG))
    I(op("SHL", "R", 2))
    I(rb(FATTR), op("OR", "R", "QB"))
    I(op("BIC", "R", 1))               # FATTR bit 1: W-buffering
    I(rb(FACING), op("OR", "R", "QB"))
    I(op("SHL", "R", 8))
    I(rb(HV), op("OR", "R", "QB"))
    I(op("SHL", "R", 3), w(T + 1))
    I(ra(KT), op("SHR", "QA", 4), w(HV + 1))               # YTop
    I(ra(TRT), rb(TRA), op("OR", "QA", "QB"))
    I(op("SHL", "R", 8))
    I(rb(HV), op("OR", "R", "QB"), ra(TEXPAL), mac("LD", "QA", 1))
    I(op("SHL", "R", 8))
    # the key reads its buckets; count it in {t, ybot}; NumPolygons to the front of {t, ytop}
    I(rb(HV + 1), op("OR", "R", "QB"), w(T), sm("RB"), ra(LN), mac("ADD", "QA", 1 << 13))
    I(ra(KT), op("AND", "QA", 15), w(T + 2))               # VTop
    I(op("ADD", "SCT", 1), sm("WCT"))
    I(ra(KB), op("AND", "QA", 15), sm("COMMIT"))
    I(op("RSUB", "R", 15), w(T + 3))                       # VBottom
    scope("hdrf")
    I(ra(HV + 1), mac("ADD", "QA", 1 << 25))
    I(ra(T + 1), mac("ADD", "QA", 1 << 30))
    I(ra(T + 2), mac("ADD", "QA", 1 << 17))
    I(ra(T + 3), mac("ADD", "QA", 1 << 21))
    waito()
    I(*ld(CATTR), out("O0"))
    I(*ld(TEXP), out("O1"))
    I(op("PASSX", "ACCX"), out("O2"))
    I(op("PASSX", "ACCX", sh=32), out("O3"))
    I(out("PUSHH"), *ld(FATTR))
    scope(None)
else:
    L("WSD")
    I(op("RSUB", "R", 16))
    I(op("MAX", "R", 0), w(WSL))           # left shift 16 - wsize
    I(ra(WS), op("SUB", "QA", 16))
    I(op("MAX", "R", 0), w(WSR))           # right shift wsize - 16
    I(ra(KB), op("SHR", "QA", 13))
    I(op("SLT", "R", 193))
    I(op("XOR", "R", 1))
    I(rb(DEG), op("OR", "R", "QB"), w(DEG))

    # ---- sort key, header beat
    I(ra(KB), op("SHR", "QA", 13), w(HV))                  # YBottom
    I(ra(KT), op("SHR", "QA", 4), w(HV + 1))               # YTop
    I(ra(TRT), rb(TRA), op("OR", "QA", "QB"))
    I(op("SHL", "R", 16), w(T))
    I(ra(HV), op("SHL", "QA", 8))
    I(rb(HV + 1), op("OR", "R", "QB"))
    if not USORT:
        I(rb(T), op("OR", "R", "QB"), w(T))
        L("KEYW")
        I(jc("SORTBUSY", "KEYW"))
        I(*ld(T), out("KEY"))
    # word 2: texpal | n << 13 | vtop << 17 | vbot << 21 | ytop << 25;
    # word 3: ytop >> 7 | ybot << 1 | facing << 9 | wbuffer << 10 | degenerate << 11
    if not USORT:
        I(ra(HV), op("SHL", "QA", 3), w(T + 1))
        I(ra(FACING), op("SHL", "QA", 11))
    else:
        # USORT: the key reads its buckets; count it in {t, ybot}; NumPolygons to the front of {t, ytop}
        I(rb(T), op("OR", "R", "QB"), w(T), sm("RB"))
        I(ra(HV), op("SHL", "QA", 3), w(T + 1))
        I(op("ADD", "SCT", 1), sm("WCT"))
        I(ra(FACING), op("SHL", "QA", 11), sm("COMMIT"))
    I(rb(T + 1), op("OR", "R", "QB"), w(T + 1))
    I(ra(FATTR), op("AND", "QA", 2))
    I(op("SHL", "R", 11))
    I(rb(T + 1), op("OR", "R", "QB"), w(T + 1))
    I(ra(DEG), op("SHL", "QA", 13))
    I(rb(T + 1), op("OR", "R", "QB"), w(T + 1))
    I(ra(KT), op("AND", "QA", 15), w(T + 2))               # VTop
    I(ra(KB), op("AND", "QA", 15))
    I(op("RSUB", "R", 15), w(T + 3))                       # VBottom
    scope("hdr")
    I(ra(TEXPAL), mac("LD", "QA", 1))
    I(ra(LN), mac("ADD", "QA", 1 << 13))
    I(ra(T + 2), mac("ADD", "QA", 1 << 17))
    I(ra(T + 3), mac("ADD", "QA", 1 << 21))
    I(ra(HV + 1), mac("ADD", "QA", 1 << 25))
    I(ra(T + 1), mac("ADD", "QA", 1 << 30))
    waito()
    I(*ld(CATTR), out("O0"))
    I(*ld(TEXP), out("O1"))
    I(op("PASSX", "ACCX"), out("O2"))
    I(op("PASSX", "ACCX", sh=32), out("O3"))
    I(out("PUSHH"))
    scope(None)


# ---- vertex beats: FinalW = W normalized to 16 bits; Z, or W-buffering's
# shifted W; word 0 = x | y << 9 | z << 17, word 1 = z >> 15 | w << 9 | W1
Z0 = V()                               # never written: 0


def beat(wbuf):
    if wbuf:
        I(ra(G_W, 1), rb(WSR), op("SHR", "QA", "QB"))
        I(rb(WSR), op("SHL", "R", "QB"), ra(G_FX, 1), mac("LD", "QA", 1))   # z = (W >> s) << s
        I(mac("ADD", "R", 1 << 17))
        I(ra(G_FY, 1), mac("ADD", "QA", 1 << 9))
        I(ra(G_W, 1), rb(WSL), op("SHL", "QA", "QB"))
        I(rb(WSR), op("SHR", "R", "QB"))
        I(op("SHL", "R", 11))
        I(mac("ADD", "R", 1 << 30))
    else:
        I(ra(G_W, 1), rb(WSL), op("SHL", "QA", "QB"))
        I(rb(WSR), op("SHR", "R", "QB"), ra(G_FX, 1), mac("LD", "QA", 1))
        I(op("SHL", "R", 11))
        I(mac("ADD", "R", 1 << 30))
        I(ra(G_FY, 1), mac("ADD", "QA", 1 << 9))
        I(ra(G_FZ, 1), mac("ADD", "QA", 1 << 17))
    waito()
    I(op("PASSX", "ACCX"), out("O0"))
    I(rb(G_W1, 1), op("OR", "ACCX", "QB", sh=32), out("O1"))
    I(*ld(G_W2, 1), out("O2"))
    I(*ld(G_W3, 1), out("O3"))
    I(out("PUSHV"))


def beats_ff(wbuf):
    """FF: the vertex beats of list entries 0..LN-1 (LN >= 3), each loading the next entry's group into X3
    while it works (X1 takes it with the push)"""
    lb = u("bt")
    I(rb(LN), op("OR", "ZERO", "QB"), setxi(2, LA))
    I(*ld(LA))
    I(lcr())                           # LC = LN
    I(setx(1))                         # X1 = list entry 0
    L(lb)
    if wbuf:
        I(ra(G_W, 1), rb(WSR), op("SHR", "QA", "QB"))
        I(rb(WSR), op("SHL", "R", "QB"), ra(G_FX, 1), mac("LD", "QA", 1))  # z = (W >> s) << s
        I(mac("ADD", "R", 1 << 17), ra(G_W, 1), rb(WSL), op("SHL", "QA", "QB"))
        I(rb(WSR), op("SHR", "R", "QB"), ra(G_FY, 1), mac("ADD", "QA", 1 << 9))
        I(op("SHL", "R", 11))
        I(mac("ADD", "R", 1 << 30), ra(1, 2), op("PASSX", "QA"))
        I()
    else:
        # word 1 = z >> 15 | FinalW << 9 | W1: FinalW << 9 | W1 by the ALU (BW1), the MACs only x, y << 9,
        # z << 17 (no carries between them); the output wait three after the last beat's push
        BW1 = PK + 3
        I(ra(G_W, 1), rb(WSL), op("SHL", "QA", "QB"))
        I(rb(WSR), op("SHR", "R", "QB"), ra(G_FX, 1), mac("LD", "QA", 1))
        I(op("SHL", "R", 9))
        waito()
        I(rb(G_W1, 1), op("OR", "R", "QB"), w(BW1), ra(G_FY, 1), mac("ADD", "QA", 1 << 9))
        I(rb(G_W2, 1), op("OR", "ZERO", "QB"), out("O2"), ra(G_FZ, 1), mac("ADD", "QA", 1 << 17))
        I(ra(1, 2), op("PASSX", "QA"))                                    # the next entry's group
        I(rb(G_W3, 1), op("OR", "ZERO", "QB"), out("O3"))
        I(op("PASSX", "ACCX"), out("O0"), setx(3))
        I(rb(BW1), op("OR", "ACCX", "QB", sh=32), out("O1"), addx(2, 1))
        I(out("PUSHV"), movx(1, 3), djnz(lb))
        I(jmp("COMMIT"))
        return
    I(setx(3))
    waito()
    I(op("PASSX", "ACCX"), out("O0"), addx(2, 1))
    I(rb(G_W1, 1), op("OR", "ACCX", "QB", sh=32), out("O1"))
    I(*ld(G_W2, 1), out("O2"))
    I(*ld(G_W3, 1), out("O3"))
    I(out("PUSHV"), movx(1, 3), djnz(lb))
    I(jmp("COMMIT"))


if not (FF and USORT):
    I(*ld(FATTR))
I()
I(jc("BIT", "OVWBL", bit=1))
if FF:
    xclear()
    xrange(1, GRP, GRP + 512 - 16)
    xrange(2, LA, LA + 11)
    xrange(3, GRP, GRP + 512 - 16)
    beats_ff(False)
    L("OVWBL")
    beats_ff(True)
else:
    list_loop(Z0, lambda: beat(False), "COMMIT", count=not FF)
    I(jmp("COMMIT"))
    L("OVWBL")
    list_loop(Z0, lambda: beat(True), "COMMIT", count=not FF)

# ---- commit: NumPolygons, NumVertices (+2 copies of reused vertices when the
# polygon has a different vertex count than the last one); the next strip
# polygon's reusable vertices
xclear()
xrange(1, GRP, GRP + 512 - 16)
xrange(2, GRP, GRP + 512 - 16)
L("COMMIT")
# DS (DSR): a clipped polygon (the clip took new vertices) shares no vertices: CLPV = 1
I(li(0), w(CLPV))
I(jnc("DSR", "CMV0", bit=0))
I(ra(POOL), op("SUB", "QA", grp(NSLOTGRP)))
I(op("SLT", "ZERO", "R"), w(CLPV))
L("CMV0")
I(ra(NP), op("ADD", "QA", 1), w(NP))
I(ra(LN), rb(CS), op("SUB", "QA", "QB"), w(T))
I(ra(LN), rb(VLIM), op("XOR", "QA", "QB"))
I(op("SLT", "ZERO", "R"))              # LN != VLIM (R >= 0)
I(rb(CLPV), op("OR", "R", "QB"))       # or, on the DS, clipped
I(op("RSUB", "R", 0))
I(rb(CS), op("AND", "R", "QB"))        # CS == 2 and LN != VLIM: 2
I(rb(T), op("ADD", "R", "QB"))
I(rb(NV), op("ADD", "R", "QB"), w(NV))
I(op("SHL", "R", 16))
I(rb(NP), op("OR", "R", "QB"), out("NPNV"))
I(li(0), w(LSREUSE))
I(*ld(PMODE))
I()
I(jnc("BIT", "CMEND", bit=1))
# DS (DSR, gpu3d_gxeng DS_STRIPCLIP; hwref runs 15-19): a polygon that was clipped at all is stored as a
# separate polygon, so the next strip polygon shares nothing with it (melonDS shares when the clip left
# lastpolyverts vertices and both shared ones are original)
I(ra(CLPV), op("OR", "QA", 0, fl=True))
I()
I(jnc("Z", "CMEND"))
# reusable: n == lastpolyverts and both vertices unclipped (slot groups)
I(ra(LN), rb(VLIM), op("SUB", "QA", "QB", fl=True))
I()
I(jnc("Z", "CMEND"))
I(*ld(PMODE))
I()
I(jc("BIT", "CMQ", bit=0))
I(*((pu(PU_NCONS),) if PU else ld(NCONS)))   # PU: NumConsecutivePolygons' parity in the polygon unit
I()
I(jnc("BIT", "CME", bit=0))
I(*ld(LA + 2), w(T))                   # (2, 1)
I(*ld(LA + 1), w(T + 1), jmp("CMC"))
L("CME")
I(*ld(LA), w(T))                       # (0, 2)
I(*ld(LA + 2), w(T + 1), jmp("CMC"))
L("CMQ")
I(*ld(LA + 3), w(T))                   # (3, 2)
I(*ld(LA + 2), w(T + 1))
L("CMC")
I(ra(T), op("SLT", "QA", grp(NSLOTGRP)), w(T + 2))
I(ra(T + 1), op("SLT", "QA", grp(NSLOTGRP)))
I(rb(T + 2), op("AND", "R", "QB"))
I()
I(jnc("BIT", "CMEND", bit=0))
if FF:
    I(*ld(T))
    I(*ld(SLOT + 4))
    I(setx(1))                         # R two back: T
    I(setx(2), call("COPYV"))          # R two back: SLOT[4]
    I(*ld(T + 1))
    I(*ld(SLOT + 5))
    I(setx(1))
    I(setx(2), call("COPYV"))
else:
    setx_from(T, 1)
    setx_from(SLOT + 4, 2)
    I(call("COPYV"))
    setx_from(T + 1, 1)
    setx_from(SLOT + 5, 2)
    I(call("COPYV"))
I(li(1), w(LSREUSE))
L("CMEND")
I(ret())

# a reused vertex: the 16 words, with Position[3] = W24
scope("copyv")
L("COPYV")
for k in range(16):
    I(*ld(G_W if k == 3 else k, 1), w(k, 2), nh())
I(ret())
scope(None)

# ======================================================================
# clipping (ClipPolygon): the list LA (LN entries) from CS; planes z, y, x,
# each as two halves (+: comp > w out, LA -> LB; -: comp < -w out, LB -> LA);
# with ATT the colours and texture coordinates are interpolated too, and
# the colours masked after each plane. The far plane (z > w without polygon
# attribute bit 12) ends the z plane with no vertices: the next planes then
# start from CS again (melonDS's ClipAgainstPlane returning 0).
# ======================================================================
xclear()
xrange(1, GRP, GRP + 512 - 16)
xrange(2, LA, GRP + 512)
xrange(3, LA, GRP + 512)
COMP, FARF, XB1, XB2 = T2 + 12, T2 + 13, T2 + 14, T2 + 15   # plane component; far plane hit (bit 1: the pool ran out, seg); group bases


def segc(off, sx16):
    """new[off] = in + (out - in) * num / den (64-bit, truncated)"""
    I(ra(off, 2), rb(off, 1), op("SUB", "QA", "QB"), w(DV))
    I(rb(NUM), op("XOR", "R", "QB"), w(TS))                   # product sign
    I()
    ng, dv, ad, st = u("sn"), u("sd"), u("sa"), u("st")
    I(jc("BIT", ng, bit=31))
    I(ra(DV), rb(NUM), mac("LD", "QA", "QB"), jmp(dv))
    L(ng)
    I(ra(DV), rb(NNUM), mac("LD", "QA", "QB"))
    L(dv)
    I(rb(DEN), op("OR", "ZERO", "QB"), divs("D64", 32))
    waitd()
    I(*ld(TS))
    I()
    I(jnc("BIT", ad, bit=31))
    I(rb(off, 1), op("RSUB", "Q", "QB"), jmp(st))           # in - q
    L(ad)
    I(rb(off, 1), op("ADD", "Q", "QB"))                       # in + q
    L(st)
    if sx16:
        I(op("SX16", "R"), w(off, 3))
    else:
        I(w(off, 3))


# ClipSegment's interpolation: X1 in (outside), X2 out (inside), X3 new;
# Position[comp] is interpolated too and then replaced by the caller. The
# words go in order (X1..X3 step by one): Position, then with ATT Color and
# (one word on) TexCoords, which are s16.
def segv_loop(n, sx16, nxt):
    lb = u("sv")
    I(lci(n))
    L(lb)
    segc(0, sx16)
    I(addx(1, 1))
    I(addx(2, 1))
    I(addx(3, 1), djnz(lb))


def segc_prep(off):
    """the accumulator = |(out - in) * num| for word off; TS = its sign (bit 31)"""
    I(ra(off, 2), rb(off, 1), op("SUB", "QA", "QB"), w(DV))
    I(rb(NUM), op("XOR", "R", "QB"), w(TS))                   # product sign
    I()
    ng, dv = u("sn"), u("sd")
    I(jc("BIT", ng, bit=31))
    I(ra(DV), rb(NUM), mac("LD", "QA", "QB"), jmp(dv))
    L(ng)
    I(ra(DV), rb(NNUM), mac("LD", "QA", "QB"))
    L(dv)


xrange(1, GRP, GRP + 512)
xrange(2, GRP, GRP + 512)
xrange(3, GRP, GRP + 512)
L("SEGV")
# Position, and with ATT Color (7 words in a row), software-pipelined: word j's subtract and multiply run
# under word j-1's divide (the divider holds its numerator), and word j-1 is finished under word j's.
# The quotient's sign is applied as (q ^ s) - s with s = TS >> 31 (SGM, the pending word's).
I(*ld(ATT))
I(lci(3))
I(jnc("BIT", "SGV4", bit=0))
I(lci(6))
L("SGV4")
segc_prep(0)
I(rb(DEN), op("OR", "ZERO", "QB"), divs("D64", 32))
I(ra(TS), op("SAR", "QA", 31), w(SGM))
L("SGVL")                              # X at the pending word j-1; word j at offset 1
segc_prep(1)
waitd()
I(rb(SGM), op("XOR", "Q", "QB"))
I(rb(DEN), op("PASSX", "R", "QB"), divs("D64", 32))          # word j's divide; R kept
I(rb(SGM), op("SUB", "R", "QB"), addx(2, 1))
I(rb(0, 1), op("ADD", "R", "QB"), w(0, 3))                   # in + q
I(ra(TS), op("SAR", "QA", 31), w(SGM), addx(1, 1))
I(addx(3, 1), djnz("SGVL"))
waitd()
I(rb(SGM), op("XOR", "Q", "QB"), addx(2, 1))
I(rb(SGM), op("SUB", "R", "QB"))
I(rb(0, 1), op("ADD", "R", "QB"), w(0, 3), addx(1, 1))
I(*ld(ATT), addx(3, 1))
I()
I(jnc("BIT", "SEGVR", bit=0))
# TexCoords (s16), one word on: not pipelined
I(addx(1, 1))
I(addx(2, 1))
I(addx(3, 1))
segv_loop(2, True, None)
L("SEGVR")
I(ret())


xrange(1, GRP, GRP + 512 - 16)
xrange(2, LA, GRP + 512)
xrange(3, LA, GRP + 512)
def x3_at(base_var):
    """X3 = RF[base_var] + COMP"""
    I(ra(base_var), rb(COMP), op("ADD", "QA", "QB"))
    I()
    I(setx(3))


def seg(sgn, name):
    """ClipSegment for the half-plane of sign sgn: X1 outside (XB1), X2
    inside (XB2); the new vertex at POOL, POOL += 16"""
    L(name)
    opn = "SUB" if sgn > 0 else "ADD"
    x3_at(XB2)
    I(ra(3, 2), rb(0, 3), op(opn, "QA", "QB"), w(T))       # w' - s comp'
    x3_at(XB1)
    I(ra(3, 1), rb(0, 3), op(opn, "QA", "QB"), w(NUM))     # num = w - s comp
    I()
    I(rb(T), op("SUB", "R", "QB", fl=True), w(DEN))         # den = num - (w' - s comp')
    I()
    pos = u("sg")
    I(jnc("N", pos))
    I(ra(NUM), op("RSUB", "QA", 0), w(NUM))
    I(ra(DEN), op("RSUB", "QA", 0), w(DEN))
    L(pos)
    I(ra(NUM), op("RSUB", "QA", 0), w(NNUM))
    # DS (DSR bit argument 2, gpu3d_gxeng DS_CLIPRED; hwref rules3d clip_col, run 21): red is interpolated
    # without the colour fill, from (c << 12) rather than (c << 12) | 0xFFF: both ends' red loses its low
    # 12 bits first (the outside vertex is dropped, and the inside one is masked and refilled with the
    # plane, CMASK). Not the result less 0xFFF: vertices new in the plane's first half are not refilled yet
    cr = u("cr")
    I(jnc("DSR", cr, bit=2))
    I(*ld(ATT))
    I()
    I(jnc("BIT", cr, bit=0))
    for xg in (1, 2):
        I(ra(G_C, xg), op("AND", "QA", 0xFFF))
        I(ra(G_C, xg), op("SUB", "QA", "R"), w(G_C, xg))
    L(cr)
    # the pool ends with group 31 (above it, 0x400, the position matrix stack): a clip that needs more (a box
    # face with corners far outside, pkw2-city: 17 new vertices from group 16) takes group 31 again and sets
    # FARF bit 1; the caller rejects the polygon, or counts the box face as inside
    pv = u("pv")
    I(ra(POOL), op("SUB", "QA", grp(32), fl=True))
    I()
    I(jc("LT", pv))
    I(li(grp(31)), w(POOL))
    I(*ld(FARF))
    I(op("OR", "R", 2), w(FARF))
    L(pv)
    setx_from(POOL, 3)
    I(ra(POOL), op("ADD", "QA", 16), w(POOL))
    I(call("SEGV"))
    setx_from(XB1, 1)
    # Position[comp] = s * Position[3]
    I(ra(POOL), op("SUB", "QA", 16))
    I()
    I(setx(3))
    I(ra(3, 3), op("RSUB", "QA", 0) if sgn < 0 else op("PASSX", "QA"), w(T))
    I(ra(POOL), op("SUB", "QA", 16))
    I(rb(COMP), op("ADD", "R", "QB"))
    I()
    I(setx(3))
    I(*ld(T), w(0, 3))
    I(li(1), w(NEWV))
    I(ra(POOL), op("SUB", "QA", 16))
    I()
    I(setx(1))
    I(jmp("OCV"))                      # its outcodes for the later planes (OCV returns)


seg(1, "SEGP")
seg(-1, "SEGN")


def outside(xg):
    """R = 1 when the vertex in X[xg] (its component word in X3) is outside
    the half-plane SG (1: comp > w, 0: comp < -w)"""
    tn, td = u("tn"), u("td")
    I(*ld(SG))
    I()
    I(jnc("BIT", tn, bit=0))
    I(ra(3, xg), rb(0, 3), op("SLT", "QA", "QB"), jmp(td))   # w < comp
    L(tn)
    I(ra(3, xg), op("RSUB", "QA", 0))
    I(ra(0, 3), op("SLT", "QA", "R"))                        # comp < -w
    L(td)


def vertex_x(xg, bvar):
    """X[xg] = list[R] (R: list index + base), its base to bvar; X3 = base + COMP"""
    I()
    I(setx(2))
    I(*ld(0, 2), w(bvar))
    I(rb(COMP), op("ADD", "R", "QB"))
    I(setx(xg))
    I(setx(3))


# ClipAgainstPlane, one half (sign SG): list SRCB (LN entries) -> DSTB, from CS
L("HALF")
setx_from(SRCB, 1)
setx_from(DSTB, 3)
I(*ld(0, 1), w(0, 3))                  # the first two (kept when clipstart is 2)
I(*ld(1, 1), w(1, 3))
I(*ld(CS), w(LI))
I(w(LCNT))
L("HT")
I(ra(LI), rb(LN), op("SUB", "QA", "QB", fl=True))
I()
I(jnc("LT", "HE"))
I(ra(LI), rb(SRCB), op("ADD", "QA", "QB"))
vertex_x(1, XB1)
outside(1)
I()
I(jc("BIT", "HO", bit=0))
I(ra(LCNT), rb(DSTB), op("ADD", "QA", "QB"))
I()
I(setx(3))
I(*ld(XB1), w(0, 3))
I(ra(LCNT), op("ADD", "QA", 1), w(LCNT), jmp("HN"))
L("HO")
I(*ld(SG))                             # the far plane: z > w without attribute bit 12
I(ra(COMP), op("SUB", "QA", 2, fl=True))
I(jnc("BIT", "HNF", bit=0))
I(*ld(CATTR))
I(jnc("Z", "HNF"))
I(jnc("BIT", "HFAR", bit=12))
L("HNF")
for side in (-1, 1):
    sk, ok = u("hs"), u("hk")
    if side < 0:                       # previous: i - 1, or n - 1
        I(ra(LI), op("SUB", "QA", 1, fl=True))
        I()
        I(jnc("N", ok))
        I(ra(LN), op("SUB", "QA", 1))
    else:                              # next: i + 1, or 0
        I(ra(LI), op("ADD", "QA", 1))
        I(rb(LN), op("SUB", "R", "QB", fl=True))
        I(ra(LI), op("ADD", "QA", 1))
        I(jnc("Z", ok))
        I(li(0))
    L(ok)
    I(rb(SRCB), op("ADD", "R", "QB"))
    vertex_x(2, XB2)
    outside(2)
    I()
    I(jc("BIT", sk, bit=0))            # the neighbour is outside too
    I(*ld(SG))
    I()
    sn = u("hsn")
    I(jnc("BIT", sn, bit=0))
    I(call("SEGP"))
    I(jmp(sn + "d"))
    L(sn)
    I(call("SEGN"))
    L(sn + "d")
    I(ra(LCNT), rb(DSTB), op("ADD", "QA", "QB"))
    I()
    I(setx(3))
    I(ra(POOL), op("SUB", "QA", 16), w(0, 3))
    I(ra(LCNT), op("ADD", "QA", 1), w(LCNT))
    setx_from(XB1, 1)                  # X1: the vertex again
    L(sk)
L("HN")
I(ra(LI), op("ADD", "QA", 1), w(LI), jmp("HT"))
L("HE")
I(*ld(LCNT), w(LN), ret())


L("HFAR")                              # ClipAgainstPlane returns 0
I(li(1), w(FARF), ret())

# planes z, y, x; a half-plane no vertex of the list is outside (OCM) would
# return the list unchanged, so it is skipped; the colour mask only changes
# vertices made in that plane (NEWV). The list ping-pongs between LA and LB.
def halfx(sg):
    I(li(sg), w(SG))
    I(*ld(CUR), w(SRCB))
    I(ra(CUR), op("RSUB", "QA", LA + LB), w(DSTB))     # the other list
    I(w(CUR), call("HALF"))


L("CLIP")
I(li(0), w(FARF))
I(li(LA), w(CUR))
for comp in (2, 1, 0):
    sk, sp, sm = u("cms"), u("cps"), u("cns")
    I(li(0), w(NEWV))
    I(li(comp), w(COMP))
    I(*ld(OCM))
    I()
    I(jnc("BIT", sp, bit=comp))
    halfx(1)
    if comp == 2:
        I(*ld(FARF))
        I()
        I(jc("BIT", "CLFAR", bit=0))
    L(sp)
    I(*ld(OCM))
    I()
    I(jnc("BIT", sm, bit=comp + 3))
    halfx(0)
    L(sm)
    I(ra(ATT), rb(NEWV), op("AND", "QA", "QB"))
    I()
    I(jnc("BIT", sk, bit=0))
    I(call("CMASK"))
    L(sk)
# the result back into LA
I(ra(CUR), op("SUB", "QA", LA, fl=True))
I()
I(jc("Z", "CLRET"))
I(ra(LN), op("SUB", "QA", 0, fl=True))
I()
I(jc("Z", "CLRET"))
xrange(1, LA, LB + 10)
setx_from(CUR, 1)
I(setxi(3, LA))
I(*ld(LN))
I()
I(lcr())
L("CLCP")
I(*ld(0, 1), w(0, 3))
I(addx(1, 1))
I(addx(3, 1), djnz("CLCP"))
L("CLRET")
I(ret())
xrange(1, GRP, GRP + 512 - 16)
# the far plane: the z plane returns no vertices, and every later plane then
# keeps only the first clipstart ones (the reused pair, unchanged): melonDS
# ends with LN = clipstart and the list as it came in
L("CLFAR")
I(li(LA), w(CUR))
I(*ld(CS), w(LN), ret())

# Color &= ~0xFFF; Color += 0xFFF for the list's vertices (list CUR)
L("CMASK")
I(*ld(LN, fl=True))
I()
I(jc("Z", "CMRET"))                    # an empty list (a DJNZ count of 0 would be 64)
setx_from(CUR, 2)
I(*ld(LN))
I()
I(lcr())
L("CML")
I(*ld(0, 2))
I()
I(setx(1))
for c in range(3):
    I(ra(G_C + c, 1), op("OR", "QA", 0xFFF), w(G_C + c, 1))
I(addx(2, 1), djnz("CML"))
L("CMRET")
I(ret())

xclear()
# ======================================================================
# tests
# ======================================================================
def xform_to(base, xg, src, sx=0):
    """base + X[xg] [0..3] = (src (+X[sx]) [0..2], 1) * clip matrix"""
    ins = [[nh()] for _ in range(19)]
    for c in range(4):
        for k in range(4):
            i = 4 * c + k
            if k < 3:
                ins[i] += [ra(src + k, sx), rb(CLIP + 4 * k + c), mac("LD" if k == 0 else "ADD", "QA", "QB")]
            else:
                ins[i] += [ra(CLIP + 12 + c), mac("ADD", "QA", 0x1000)]
        ins[4 * c + 6] += [op("PASSX", "ACCX", sh=12), w(base + c, xg)]
    return ins


L("POSTEST")
I(ra(PARAM), op("SX16", "QA"), w(CURV))
I(ra(PARAM), op("SAR", "QA", 16), w(CURV + 1))
I(ra(PARAM + 1), op("SX16", "QA"), w(CURV + 2))
I(jnc("DIRTY", "PT1"))
I(call("CLIPUPD"))
L("PT1")
scope("pt")
for parts in xform_to(POSTEST, 0, CURV):
    I(*parts)
scope(None)
I(out("TDONE"), jmp("D1"))

# VecTest: (normal * vector matrix) >> 9 as 16 bits, bit 12 extended to 15..12
L("VECTEST")
for k, sh in enumerate((22, 12, 2)):
    I(op("SHL", "P", sh))
    I(op("SAR", "R", 22), w(T + k))
scope("vt")
for c in range(3):
    for k in range(3):
        I(ra(T + k), rb(VEC + 4 * k + c), mac("LD" if k == 0 else "ADD", "QA", "QB"))
    nops(2)
    I(op("PASSX", "ACCX", sh=9), nh(), w(T + 4 + c))
    I(op("SHL", "R", 19))
    I(op("SAR", "R", 31))
    I(op("AND", "R", 0xF000))
    I(rb(T + 4 + c), op("OR", "R", "QB"))
    I(op("AND", "R", 0xFFFF), w(T + 8 + c))
scope(None)
I(ra(T + 9), op("SHL", "QA", 16))
I(rb(T + 8), op("OR", "R", "QB"), w(VECTEST))
I(*ld(T + 10), w(VECTEST + 1))
I(out("TDONE"), jmp("D1"))

# BoxTest: the 8 corners transformed, then the 6 faces clipped (positions only)
xclear()
xrange(1, GRP, GRP + 512 - 16)
xrange(2, BOXV, BOXV + 24)
L("BOXTEST")
I(jnc("DIRTY", "BT0"))
I(call("CLIPUPD"))
L("BT0")
X0, Y0, Z0, X1, Y1, Z1 = (BOXC + k for k in range(6))
I(ra(PARAM), op("SX16", "QA"), w(X0))
I(ra(PARAM), op("SAR", "QA", 16), w(Y0))
I(ra(PARAM + 1), op("SX16", "QA"), w(Z0))
I(ra(PARAM + 1), op("SAR", "QA", 16))
I(rb(X0), op("ADD", "R", "QB"))
I(op("SX16", "R"), w(X1))
I(ra(PARAM + 2), op("SX16", "QA"))
I(rb(Y0), op("ADD", "R", "QB"))
I(op("SX16", "R"), w(Y1))
I(ra(PARAM + 2), op("SAR", "QA", 16))
I(rb(Z0), op("ADD", "R", "QB"))
I(op("SX16", "R"), w(Z1))
CORNERS = ((X0, Y0, Z0), (X1, Y0, Z0), (X1, Y1, Z0), (X0, Y1, Z0),
           (X0, Y1, Z1), (X0, Y0, Z1), (X1, Y0, Z1), (X1, Y1, Z1))
for k, cxyz in enumerate(CORNERS):
    for j, src in enumerate(cxyz):
        I(*ld(src), w(BOXV + 3 * k + j))
I(setxi(1, grp(8)))
I(setxi(2, BOXV))
I(lci(8))
scope("btx")
L("BTX")
body = xform_to(0, 1, 0, 2)
body[16] += [addx(2, 3)]
body[18] += [addx(1, 16), djnz("BTX")]
for parts in body:
    I(*parts)
scope(None)
# the corners' outcodes (into their FinalZ word)
I(setxi(1, grp(8)))
I(lci(8))
L("BTOC")
I(li(0), w(OCM), call("OCV"))
I(*ld(OCM), w(G_FZ, 1))
I(addx(1, 16), djnz("BTOC"))
FACES = ((0, 1, 2, 3), (4, 5, 6, 7), (0, 3, 4, 5), (1, 2, 7, 6), (0, 1, 6, 5), (2, 3, 4, 7))
I(li(0), w(CS))
I(w(ATT))
for face in FACES:
    I(*ld(grp(8 + face[0]) + G_FZ))
    for c in face[1:]:
        I(rb(grp(8 + c) + G_FZ), op("OR", "R", "QB"))
    I(w(OCM))
    for j, c in enumerate(face):
        I(li(grp(8 + c)), w(LA + j))
    I(call("BFACE"))
    I(jc("BIT", "BTYES", bit=0))       # R: BFACE's last result
I(li(0), out("BOX"), jmp("BTEND"))
L("BTYES")
I(li(1), out("BOX"))
L("BTEND")
I(out("TDONE"), jmp("D1"))

# one face (corner groups in LA[0..3], their outcodes in OCM): BOXF = some
# part of it is inside (every corner inside: no clipping needed)
L("BFACE")
I(ra(OCM), op("OR", "QA", 0, fl=True))
I(li(1), w(BOXF))
I(jc("Z", "BFRET"))
I(li(4), w(LN))
I(li(grp(16)), w(POOL))
I(call("CLIP"))
I(*ld(FARF))
I()
I(jnc("BIT", "BFCLP", bit=1))
I(li(1), w(BOXF))                      # the clip ran out of pool groups: inside (the object is drawn); R = 1
I(jmp("BFRET"))
L("BFCLP")
I(rb(LN), op("SLT", "ZERO", "QB"), w(BOXF))   # R: the result, for the caller
L("BFRET")
I(ret())

# ======================================================================
# lighting (CalculateLighting)
# ======================================================================
xclear()
xrange(1, 0, 128)            # the shininess table index
xrange(2, LIGHT, LIGHT + 49)  # the light's block
xrange(3, 0, 4)              # the light number
L("NORMAL")
if LUNIT:
    # the lighting unit (gpu3d_gxlight) took the normal when it was popped: texture coordinate mode 2 only
    I(ra(TEXM), op("SUB", "QA", 2, fl=True))
    I()
    I(jnc("Z", "D1"))
for k, sh in enumerate((22, 12, 2)):
    I(op("SHL", "P", sh))
    I(op("SAR", "R", 22), w(NRM + k))
# texture coordinate mode 2: RawTexCoords + ((Normal * TexMatrix) >> 21), as s16
if not LUNIT:
    I(ra(TEXM), op("SUB", "QA", 2, fl=True))
    I()
    I(jnc("Z", "NM1"))
scope("ntex")
if FF and FF_VM:
    # on lanes 0 and 1 from row 4: the texture matrix's columns times the normal, then RawTexCoords << 12
    # times 512 (RawTexCoords << 21); bits 12..43 of a lane, >> 9 as s16, as below
    for k in range(3):
        I(rb(NRM + k), vmac("VLDT" if k == 0 else "VADD", "QB"))
    I(vmac("VADD", 512))
    for c in range(2):
        I(op("PASSX", vxr(c)))
        I(op("SHR", "R", 9))
        I(op("SX16", "R"), w(TEXC + c))
else:
    for c in range(2):
        I(ra(RAWTC + c), mac("LD", "QA", 1 << 21))
        for k in range(3):
            I(ra(NRM + k), rb(TEX + 4 * k + c), mac("ADD", "QA", "QB"))
        nops(2)
        I(op("PASSX", "ACCX", sh=12), nh())
        I(op("SHR", "R", 9))                # acc >> 21 as s16: bits 21..36 of acc are bits 9..24 of this word
        I(op("SX16", "R"), w(TEXC + c))
scope(None)
if LUNIT:
    I(d1())
else:
    L("NM1")
    # normaltrans = sx11(((Normal * VecMatrix) << 9) >> 21) (32-bit)
    scope("nt")
    ins = [[nh()] for _ in range(13)]
    for c in range(3):
        for k in range(3):
            ins[3 * c + k] += [ra(NRM + k), rb(VEC + 4 * k + c), mac("LD" if k == 0 else "ADD", "QA", "QB")]
        ins[3 * c + 5] += [op("PASSX", "ACCX", sh=12)]
        ins[3 * c + 6] += [op("SX11", "R"), w(NT + c)]
    for parts in ins[:-1]:
        I(*parts)
    I(*ins[-1])
    scope(None)
    # vtxbuff = MatEmission << 14
    for c in range(3):
        I(ra(MEMI + c), op("SHL", "QA", 14), w(VB + c))




    def light():
        """one light: X2 = its block, X3 = its index (LDD/LSH)"""
        neg, tab, p2 = "LNG", "LTB", "LP2"
        scope("ld")
        # dot = sum (LightDirection * normaltrans) >> 9, each product shifted
        I(ra(LDIR, 2), rb(NT), mac("LD", "QA", "QB"))
        I(ra(LDIR + 1, 2), rb(NT + 1), mac("LD", "QA", "QB"))
        I(ra(LDIR + 2, 2), rb(NT + 2), mac("LD", "QA", "QB"))
        I(op("PASSX", "ACCX", sh=9), nh())
        I(op("ADD", "ACCX", "R", sh=9), nh())
        I(op("ADD", "ACCX", "R", sh=9, fl=True), w(T), nh())
        scope(None)
        I(op("SX11", "R"), w(LDD, 3))                       # diffdot
        I(jc("Z", neg))
        I(jc("N", neg))
        # shine = ((sx11(dot + normaltrans[2])^2 >> 10 & 0x3FF) * SpecRecip >> 8) - 512, as s14, 0..0x1FF
        I(ra(T), rb(NT + 2), op("ADD", "QA", "QB"))
        I(op("SX11", "R"))
        I(mac("LD", "R", "R"))
        I(op("PASSX", "ACCX"))             # the square (>= 0, below 2^21)
        I(op("SHR", "R", 10))
        I(op("AND", "R", 0x3FF))
        I(rb(LRECIP, 2), mac("LD", "R", "QB"))
        I(op("PASSX", "ACCX"))             # dot * SpecRecip fits in 32 bits
        I(op("SAR", "R", 8))
        I(op("SUB", "R", 512))
        I(op("MAX", "R", 0))
        I(op("SHL", "R", 18))
        I(op("SAR", "R", 18))
        I(op("MAX", "R", 0))
        I(op("MIN", "R", 0x1FF), jmp(tab))
        L(neg)
        I(li(0), w(LDD, 3))
        L(tab)
        I(w(LSH, 3))
        I(*ld(USETAB))
        I()
        I(jnc("BIT", p2, bit=0))
        I(ra(LSH, 3), op("SHR", "QA", 2))
        I()
        I(setx(1))
        I(ra(SHIN, 1), op("SHL", "QA", 1), w(LSH, 3))
        L(p2)
        # vtxbuff += (DL * diffdot) & 0xFFFFF + SL * shine + AL
        scope("lp")
        ins = [[nh()] for _ in range(15)]
        for c in range(3):
            b = 4 * c
            ins[b] += [ra(VB + c), mac("LD", "QA", 1)]
            ins[b + 1] += [ra(LDL + c, 2), rb(LDD, 3), mac("ADDM", "QA", "QB")]
            ins[b + 2] += [ra(LSL + c, 2), rb(LSH, 3), mac("ADD", "QA", "QB")]
            ins[b + 3] += [ra(LAL + c, 2), mac("ADD", "QA", 1)]
            ins[b + 6] += [op("PASSX", "ACCX"), w(VB + c)]
        for parts in ins:
            I(*parts)
        scope(None)


    # the enabled lights only: R holds the polygon attribute (its bits 0-3) for each test; a disabled
    # light costs its one test, an enabled one two more and the call (LIGHT1 reloads R before returning)
    I(*ld(CATTR))
    I()
    for k in range(4):
        I(jnc("BIT", f"LLOOP{k + 1}" if k < 3 else "LSKIP", bit=k))
        I(setxi(2, LIGHT + 16 * k))
        I(setxi(3, k), call("LIGHT1"))
        if k < 3:
            L(f"LLOOP{k + 1}")
    L("LSKIP")
    # VertexColor = min(vtxbuff >> 14, 31)
    for c in range(3):
        I(ra(VB + c), op("SHR", "QA", 14))
        I(op("MIN", "R", 31))
        I(op("SHL", "R", 12))
        I(op("OR", "R", 0xFFF), w(CURCOL + c), *((jmp("D1"),) if c == 2 else ()))

    L("LIGHT1")
    light()
    I(*ld(CATTR))
    I(ret())


# materials and light colours: DL = MatDiffuse * LightColor, AL = (MatAmbient << 9) * LightColor,
# SL = MatSpecular * LightColor, per light
def products(srcs, lights):
    """(material base, light product offset) pairs, for the given lights"""
    scope(u("prod"))
    jobs = [(src + c, LIGHT + 16 * l + dst + c, LIGHT + 16 * l + LCOL + c)
            for src, dst in srcs for l in lights for c in range(3)]
    ins = [[nh()] for _ in range(len(jobs) + 3)]
    for i, (a, d, col) in enumerate(jobs):
        ins[i] += [ra(a), rb(col), mac("LD", "QA", "QB")]
        ins[i + 3] += [op("PASSX", "ACCX"), w(d)]
    for parts in ins:
        I(*parts)
    scope(None)


def fields5(base, sh0, tgt_shift=0):
    for c in range(3):
        I(op("SHR", "P", sh0 + 5 * c))
        I(op("AND", "R", 0x1F))
        if tgt_shift:
            I(op("SHL", "R", tgt_shift), w(base + c))
        else:
            I(w(base + c))


xclear()
L("DIFAMB")
fields5(MDIF, 0)
fields5(MAMB9, 16, 9)
I(op("SHR", "P", 15))
I()
I(jnc("BIT", "DA1", bit=0))
for c in range(3):                     # bit 15: VertexColor = MatDiffuse
    I(ra(MDIF + c), op("SHL", "QA", 12))
    I(op("OR", "R", 0xFFF), w(CURCOL + c))
L("DA1")
products(((MDIF, LDL), (MAMB9, LAL)), range(4))
I(d1())

L("SPEEMI")
fields5(MSPE, 0)
fields5(MEMI, 16)
I(op("SHR", "P", 15))
I(op("AND", "R", 1), w(USETAB))
products(((MSPE, LSL),), range(4))
I(d1())

xclear()
xrange(1, 0, 49)
L("LIGHTCOL")
I(op("SHR", "P", 26))
I(op("AND", "R", 0x30))                # 16 * light
I()
I(setx(1))
for c in range(3):
    I(op("SHR", "P", 5 * c))
    I(op("AND", "R", 0x1F), w(LIGHT + LCOL + c, 1))
scope("lcol")
jobs = [(src + c, dst + c, LCOL + c) for src, dst in ((MDIF, LDL), (MSPE, LSL), (MAMB9, LAL)) for c in range(3)]
ins = [[nh()] for _ in range(len(jobs) + 3)]
for i_, (a, d, col) in enumerate(jobs):
    ins[i_] += [ra(a), rb(LIGHT + col, 1), mac("LD", "QA", "QB")]
    ins[i_ + 3] += [op("PASSX", "ACCX"), w(LIGHT + d, 1)]
for parts in ins:
    I(*parts)
scope(None)
I(d1())

# LightDirection = sx11(-((dir * VecMatrix) >> 12)); SpecRecip = (1 << 18) / den,
# den = 512 - sx11(((dir * VecMatrix[col 2]) << 9) >> 21) (0: SpecRecip 0)
L("LIGHTVEC")
I(op("SHR", "P", 26))
I(op("AND", "R", 0x30))
I()
I(setx(1))
for k, sh in enumerate((22, 12, 2)):
    I(op("SHL", "P", sh))
    I(op("SAR", "R", 22), w(T + k))
scope("lv")
for c in range(3):
    for k in range(3):
        I(ra(T + k), rb(VEC + 4 * k + c), mac("LD" if k == 0 else "ADD", "QA", "QB"))
    nops(2)
    I(op("PASSX", "ACCX", sh=12), nh(), w(T + 3))
    I(op("RSUB", "R", 0))
    I(op("SX11", "R"), w(LIGHT + LDIR + c, 1))
scope(None)
I(ra(T + 3), op("SX11", "QA"))
I(op("RSUB", "R", 512, fl=True), w(DEN))
I()
I(jc("Z", "LV0"))
I(ra(DEN), op("SAR", "QA", 31), w(ZM))
I(li(1 << 18))
I(mac("LD", "R", 1))
I(ra(DEN), rb(ZM), op("XOR", "QA", "QB"))
I(rb(ZM), op("SUB", "R", "QB"), w(T + 4))
I(rb(T + 4), op("OR", "ZERO", "QB"), divs("D32", 32))
waitd()
I(rb(ZM), op("XOR", "Q", "QB"))
I(rb(ZM), op("SUB", "R", "QB"), w(LIGHT + LRECIP, 1), jmp("D1"))
L("LV0")
I(li(0), w(LIGHT + LRECIP, 1), jmp("D1"))

# shininess table: 32 parameters, bytes little-endian
xclear()
L("SHININESS")
I(setxi(1, PARAM))
I(setxi(2, SHIN))
I(lci(32))
L("SHL")
I(ra(0, 1), op("AND", "QA", 0xFF), w(0, 2))
I(ra(0, 1), op("SHR", "QA", 8))
I(op("AND", "R", 0xFF), w(1, 2))
I(ra(0, 1), op("SHR", "QA", 16))
I(op("AND", "R", 0xFF), w(2, 2))
I(ra(0, 1), op("SHR", "QA", 24), w(3, 2), addx(1, 1))
I(addx(2, 4), djnz("SHL"))
I(d1())


if __name__ == "__main__":
    root = os.path.join(os.path.dirname(__file__), "..", "..")
    # the lighting unit's register-file addresses, and the commands the engine may dispatch while it
    # works (gpu3d_gxeng LUNIT): none of them writes what it reads (NOP, TEXCOORD, the VTX commands,
    # POLYGON_ATTR, TEXIMAGE_PARAM, PLTT_BASE, END_VTXS)
    lu_safe = sum(1 << HT[c] for c in [0x00] + list(range(0x22, 0x2C)) + [0x41])
    lu = [f"    localparam logic [10:0] LU_A_{k} = 11'h{globals()[k]:03X};"
          for k in ("VEC", "CATTR", "USETAB", "MEMI", "CURCOL", "LIGHT", "SHIN")]
    lu += [f"    localparam int LU_{k} = {globals()[k]};" for k in ("LDIR", "LRECIP", "LDL", "LSL", "LAL")]
    lu += [f"    localparam logic [10:0] VF_A_{k} = 11'h{globals()[k]:03X};" for k in ("KT", "KB", "WOR", "DEG", "IDX", "IDXB")]
    lu += [f"    localparam int VF_{k} = {globals()[k]};" for k in ("G_C", "G_W", "G_T", "G_FX", "G_FY", "G_W1")]
    lu += [f"    localparam logic [10:0] FF_A_{k} = 11'h{globals()[k]:03X};" for k in ("CURCOL", "TEXC", "RAWTC", "TEXM", "CLIP", "TEX", "CURV")]
    if FF:
        P_.assemble()                  # SUBV's address in this image (the FF run writes the package last)
    lu += [f"    localparam logic [10:0] FF_A_SUBV = 11'h{P_.labels['SUBV'] if FF else 0:03X};"]
    # PU: the polygon unit's snooped words, the dispatcher's fast vertex entry and the trivial-reject planes
    lu += [f"    localparam logic [10:0] PU_A_{k} = 11'h{globals()[k]:03X};" for k in ("PMODE", "VNIP", "NCONS", "LSREUSE", "SLOT")]
    lu += [f"    localparam logic [10:0] PU_A_SV1 = 11'h{P_.labels['SV1'] if PU else 0:03X};",
           f"    localparam logic [5:0] PU_TRIVM = 6'h{TRIVM:02X};"]
    lu += [f"    localparam logic [5:0] FF_HCOLOR = 6'd{HT[0x20]};", f"    localparam logic [5:0] FF_HTEXC = 6'd{HT[0x22]};"]
    lu += [f"    localparam logic [5:0] FF_HV{k} = 6'd{HT[c]};" for k, c in (("16", 0x23), ("10", 0x24), ("XY", 0x25), ("XZ", 0x26), ("YZ", 0x27), ("DF", 0x28))]
    lu += [f"    localparam logic [63:0] LU_SAFE = 64'h{lu_safe:016X};",
           f"    localparam logic [5:0] LU_HNORMAL = 6'd{HT[0x21]};"]
    DICT_GROUPS = [[("A", f) for f in ("tgt", "ra", "rax", "rb", "wa", "we")] +
                   [("B", f) for f in ("xs", "ys", "aop", "ma", "xsh", "out", "dv")],
                   [("A", f) for f in ("nx", "cond", "rbx", "wx", "xop", "xarg")] +
                   [("B", f) for f in ("fl", "imi", "mb", "acc")]]
    isa.gen_pkg(os.path.join(root, "rtl/gpu3d/gpu3d_gxu_pkg.sv"), lu)
    us = "_uf" if FF else "_uw" if VFIN == 2 else "_uv" if VFIN else "_ul" if LUNIT else "_us" if USORT else ""
    n, pads = P_.emit(os.path.join(root, f"rtl/gpu3d/gpu3d_gxrom{us}.sv"), depth=int(os.environ.get("GX_DEPTH", 2048)),
                      module=f"gpu3d_gxrom{us}",
                      # FF: also as an index ROM plus dictionaries (gpu3d_gxrom_ufd, docs/space-gxdict.md) with
                      # the engine's fixed entry points (gpu3d_gxeng RESET, DPARAM, FF_A_SUBV, PU_A_SV1)
                      dict_pcs={"RESET": 40, "DPARAM": 38, "SUBV": P_.labels["SUBV"],
                                "SV1": P_.labels["SV1"]} if FF else None,
                      # the fields in two dictionaries by how often they vary together, not by slice
                      # (docs/geom-area-2.md): 1022 x 80 and 248 x 35 (8 + 1 M10K, 18 index bits) where
                      # A and B were 961 x 80 and 312 x 35 (8 + 2, 19)
                      dict_groups=DICT_GROUPS if FF else None)
    os.makedirs(os.path.join(root, "build/geom"), exist_ok=True)
    with open(os.path.join(root, f"build/geom/ucode{us}.labels"), "w") as f:
        for k, v in sorted(P_.labels.items(), key=lambda x: x[1]):
            f.write(f"{v} {k}\n")
    # register-file addresses for the test bench
    with open(os.path.join(root, "build/geom/ucode.h"), "w") as f:
        for k in ("IDENT", "CURV", "SLOT", "GRP", "PMODE", "MMODE", "CATTR", "VNIP", "NCONS", "LSREUSE",
                  "NP", "NV", "LA", "LN", "CS", "CURCOL", "TEXC"):
            f.write(f"#define RF_{k} {globals()[k]:#x}\n")
    print(f"{'FF: ' if FF else 'VFIN-lite: ' if VFIN == 2 else 'VFIN: ' if VFIN else 'LUNIT: ' if LUNIT else 'USORT: ' if USORT else ''}{n} microinstructions ({pads} hazard NOPs), last address {max(P_.at):#x}, {len(P_.imm_tab)} distinct immediates")
    if not FF and VFIN != 2:
        import subprocess
        subprocess.run([sys.executable, __file__], env=dict(os.environ, GX_USORT="1", GX_LUNIT="1" if USORT else "0",
                                                            GX_VFIN="2" if VFIN else "1" if LUNIT else "0",
                                                            GX_FF="0"), check=True)
    if VFIN == 2 and not FF:
        # last, so its package is the one left: the FF image, on the full VFIN chain
        import subprocess
        subprocess.run([sys.executable, __file__], env=dict(os.environ, GX_USORT="1", GX_LUNIT="1", GX_VFIN="2",
                                                            GX_FF="1"), check=True)
