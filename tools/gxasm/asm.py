"""Microcode assembler for the geometry engine (docs/geometry-engine.md).

The microcode is written in Python (ucode.py) as instructions built from
field helpers:

    I(ra(POS + 1), mac("ADD", "QA", "QB"), rb(CLIP + 4, 1))

Every helper returns a dict of fields; I() merges them, checking that no
field is set twice to different values. Code is laid out in blocks: org()
starts a block at a fixed address (the handler table, the reset entry), the
last block holds everything else. Labels are resolved after layout.

Pipeline latencies (isa.py) are checked over the control-flow graph; where
a reader comes too early, NOPs are inserted before it. A NOP passes R
through (R = R), so a forwarded R survives padding. Instructions in a
fixed-address table block cannot be padded; a hazard there is an error.

Hazards checked (writer -> reader, minimum distance):
  register file write -> read of the same word (or any word, if either side
      is indexed) ........................................ 3
  accumulator (MAC) -> ACCX operand or divider start ...... 3
  accumulator -> A63/AZ/NFIT conditions ................... 5
  ALU flags -> Z/N/C/LT conditions ........................ 2
  divider start -> DBUSY condition ........................ 2
  PUSHH/PUSHV -> OBUSY condition, O0..O3 writes ........... 3
  MRES -> MREQ condition .................................. 3
  USORT: RB -> SBL/SCT operand or COMMIT, RP -> SYB ......... 2
  USORT: RP -> SNX (registered after the RAM) .............. 3
SETX, LCR and BIT read R at issue, which is the result of the instruction
two before; the instruction just before them must pass R (a NOP), so that
padding keeps the value. An R operand (stage O) is the result of the
instruction just before.
"""
import isa

_A = isa.offsets(isa.SLICE_A)
_B = isa.offsets(isa.SLICE_B_IMM)   # encode() packs the 24-bit immediate; emit() stores its index
E = {k: {n: i for i, n in enumerate(v)} for k, v in isa.ENUMS.items()}
SMOP = {n: i for i, n in enumerate(isa.SM)}

LAT_RF, LAT_ACC, LAT_ACCF, LAT_FL, LAT_DIV, LAT_PO, LAT_MR, LAT_SM = 3, 3, 5, 2, 2, 3, 3, 2
PARAM_BASE = 0x080                     # gpu3d_gxeng.sv PARAM


class Ins:
    def __init__(self, fields, where, pad=True, scope=None, xr=None):
        self.f = fields
        self.where = where
        self.pad = pad                 # NOPs may be inserted before it
        self.labels = []
        self.scope = scope             # nh() ignores pending writes of the same scope
        self.xr = xr or {}             # index register -> (lo, hi): the values it can hold


def _nop_fields():
    return {"xs": E["XS"]["R"], "aop": E["AOP"]["PASSX"]}


def _is_nop(f):
    keys = set(f) - {"xs", "aop", "ys"}
    return not keys and f.get("xs") == E["XS"]["R"] and f.get("aop") == E["AOP"]["PASSX"]


def _passes_r(f):
    """the instruction's result is R itself, with no other effect on R's users"""
    return f.get("xs", 0) == E["XS"]["R"] and f.get("aop", 0) == E["AOP"]["PASSX"]


class Prog:
    def __init__(self):
        self.blocks = []               # [addr, [Ins]]
        self.cur = None
        self.pending_labels = []
        self.labels = {}
        self.fixed = False
        self.scope = None
        self.xr = {}
        self.precise_ret = False       # a RET returns only to the call sites of routines that reach it

    def org(self, a, fixed=True):
        self.cur = [a, [], fixed]
        self.blocks.append(self.cur)

    def label(self, name):
        if name in self.labels or name in self.pending_labels:
            raise ValueError(f"label {name} twice")
        self.pending_labels.append(name)

    def ins(self, *parts, where=""):
        f = {}
        for p in parts:
            for k, v in p.items():
                if k in f and f[k] != v:
                    raise ValueError(f"{where}: field {k} set to {f[k]} and {v}")
                f[k] = v
        if "aop" not in f and "xs" not in f and "ys" not in f:
            f.update(_nop_fields())        # no ALU operation: pass R through
        it = Ins(f, where, pad=not self.cur[2], scope=self.scope, xr=dict(self.xr))
        it.labels = self.pending_labels
        self.pending_labels = []
        self.cur[1].append(it)

    # ------------------------------------------------------------ layout
    def layout(self):
        self.addr = {}
        self.labels = {}
        seq = []
        for a, ins, _ in self.blocks:
            for i, it in enumerate(ins):
                if a + i in self.addr.values():
                    raise ValueError(f"address {a + i:#x} used twice ({it.where})")
                self.addr[id(it)] = a + i
                for l in it.labels:
                    self.labels[l] = a + i
                seq.append(it)
        self.at = {self.addr[id(it)]: it for it in seq}
        return seq

    def resolve(self, v):
        if isinstance(v, str):
            if v not in self.labels:
                raise ValueError(f"undefined label {v}")
            return self.labels[v]
        return v

    # ------------------------------------------------------------ hazards
    def succ(self, a, it, ret_sites, table):
        f = it.f
        nx = f.get("nx", 0)
        n = E["NX"]
        s = []
        if nx in (n["NEXT"], n["JC"], n["JNC"], n["DJNZ"]):
            s.append(a + 1)
        if nx in (n["JMP"], n["JC"], n["JNC"], n["CALL"], n["DJNZ"]):
            s.append(self.resolve(f["tgt"]))
        if nx == n["RET"]:
            s += ret_sites.get(a, []) if isinstance(ret_sites, dict) else ret_sites
        if nx == n["DISP"]:
            s += table + [self.resolve(f["tgt"])] + [self.resolve(l) for l in DISP_ENTRY]
        return [x for x in s if x in self.at]

    @staticmethod
    def rf_key(addr, x, xr, n=1):
        """("RF", lo, hi): the words an access can touch"""
        if not x:
            return ("RF", addr, addr + n)
        if x in xr:
            lo, hi = xr[x]
            return ("RF", lo + addr, hi + addr + n - 1)
        return ("RF", 0, 4096)

    @classmethod
    def effects(cls, it):
        """(reads, writes): reads are resource keys; writes are (key, latency)"""
        f, xr = it.f, it.xr
        reads, writes = [], []
        xs, ys = f.get("xs", 0), f.get("ys", 0)
        acc = f.get("acc", 0)
        nop = f.get("aop") == E["AOP"]["PASSX"] and xs == E["XS"]["R"]
        usesA = (xs == E["XS"]["QA"] and not nop) or (acc and f.get("ma", 0) == E["MA"]["QA"])
        usesB = (ys == E["YS"]["QB"] and not nop) or (acc and f.get("mb", 0) == E["MB"]["QB"]) or \
            (f.get("div", 0) and ys == E["YS"]["QB"])
        if f.get("xop") == E["X"]["SETXI"]:
            usesA = False
        if usesA:
            reads.append(cls.rf_key(f.get("ra", 0), f.get("rax", 0), xr))
        if usesB:
            reads.append(cls.rf_key(f.get("rb", 0), f.get("rbx", 0), xr))
        if xs == E["XS"]["ACCX"] or f.get("div", 0):
            reads.append(("ACC",))
        smop = f.get("xsh") if f.get("out", 0) == E["O"]["KEY"] else None
        if "ATR" in E["XS"] and xs == E["XS"]["ATR"] and f.get("xsh") == PU_XSH:
            pass                                                    # PU: the polygon unit's registers (no word)
        elif "ATR" in E["XS"] and xs == E["XS"]["ATR"]:
            # FF: an attribute latch, written with its register-file word (no later than the word itself)
            assert smop is None, "ATR uses the xsh field"
            reads.append(cls.rf_key(ATR_ADDR[f["xsh"]], 0, xr))
        vacc = "VLD" in E["ACC"] and acc in (E["ACC"]["VLD"], E["ACC"]["VADD"], E["ACC"]["VLDT"])
        if "VXR" in E["XS"] and xs == E["XS"]["VXR"]:
            assert smop is None, "VXR uses the xsh field"
            reads.append(("VACC",))
        if vacc:
            for a in VM_ADDR:                                       # the lanes' copies, written with the words
                reads.append(cls.rf_key(a, 0, xr))
            if f.get("mb") == E["MB"]["MB3"]:
                for a in CURV_ADDR:
                    reads.append(cls.rf_key(a, 0, xr))
        if xs in (E["XS"]["SBL"], E["XS"]["SYB"]):
            # gpu3d_gxeng: SBL and SYB join R at the result select, past the ALU (#677)
            assert f.get("aop", 0) == E["AOP"]["PASSX"], "SBL/SYB only with PASSX"
        if xs in (E["XS"]["SBL"], E["XS"]["SCT"]) or smop == SMOP["COMMIT"]:
            reads.append(("SB",))
        if xs == E["XS"]["SYB"]:
            reads.append(("SP",))
        if xs == E["XS"]["SNX"]:
            reads.append(("SPN",))             # SNX: a register after nx_q (gpu3d_gxeng, timing): one more
        c = f.get("cond")
        nx = f.get("nx", 0)
        if nx in (E["NX"]["JC"], E["NX"]["JNC"]) and c is not None:
            if c in (E["C"]["Z"], E["C"]["N"], E["C"]["C"], E["C"]["LT"]):
                reads.append(("FL",))
            if c in (E["C"]["A63"], E["C"]["AZ"], E["C"]["NFIT"]):
                reads.append(("ACCF",))
            if c == E["C"]["DBUSY"]:
                reads.append(("DIV",))
            if c == E["C"]["OBUSY"]:
                reads.append(("PO",))
            if c == E["C"]["MREQ"]:
                reads.append(("MR",))
        if f.get("out", 0) in (E["O"]["O0"], E["O"]["O1"], E["O"]["O2"], E["O"]["O3"]):
            reads.append(("PO",))
        if f.get("we"):
            writes.append((cls.rf_key(f.get("wa", 0), f.get("wx", 0), xr), LAT_RF))
        if nx == E["NX"]["DISP"]:
            writes.append((("RF", PARAM_BASE, PARAM_BASE + 32), LAT_RF))     # a collected parameter
        if acc and vacc:
            writes.append((("VACC",), LAT_ACC))
            writes.append((("ACC",), LAT_ACC))         # lane 0 is the scalar MAC's accumulator
            writes.append((("ACCF",), LAT_ACCF))
        elif acc:
            writes.append((("ACC",), LAT_ACC))
            writes.append((("ACCF",), LAT_ACCF))
        if f.get("fl"):
            writes.append((("FL",), LAT_FL))
        if f.get("div", 0):
            writes.append((("DIV",), LAT_DIV))
        if f.get("out", 0) in (E["O"]["PUSHH"], E["O"]["PUSHV"]):
            writes.append((("PO",), LAT_PO))
        if f.get("out", 0) == E["O"]["MRES"]:
            writes.append((("MR",), LAT_MR))
        if smop == SMOP["RB"]:
            writes.append((("SB",), LAT_SM))
        if smop == SMOP["RP"]:
            writes.append((("SP",), LAT_SM))
            writes.append((("SPN",), LAT_SM + 1))
        return reads, writes

    @staticmethod
    def conflict(r, w):
        if r[0] != w[0]:
            return False
        if r[0] != "RF":
            return True
        return r[1] < w[2] and w[1] < r[2]

    def check(self):
        """returns {addr: nops needed before it}"""
        table = list(range(0, 39))
        ret_sites = []
        for a, it in self.at.items():
            if it.f.get("nx", 0) == E["NX"]["CALL"]:
                ret_sites.append(a + 1)
        if self.precise_ret:
            # the RETs each call target reaches without entering another call (a nested call continues
            # at its return site); each RET returns to the sites of the calls that reach it
            rs = {}
            for c in [a for a, it in self.at.items() if it.f.get("nx", 0) == E["NX"]["CALL"]]:
                t = self.resolve(self.at[c].f["tgt"])
                seen, work = set(), [t]
                while work:
                    a = work.pop()
                    if a in seen or a not in self.at:
                        continue
                    seen.add(a)
                    it = self.at[a]
                    nx = it.f.get("nx", 0)
                    if nx == E["NX"]["RET"]:
                        rs.setdefault(a, []).append(c + 1)
                    elif nx == E["NX"]["CALL"]:
                        work.append(a + 1)
                    else:
                        work += self.succ(a, it, [], table)
            ret_sites = rs
        state = {a: None for a in self.at}
        entry = self.resolve("RESET")
        state[entry] = {}
        work = [entry]
        need = {}
        while work:
            a = work.pop()
            st = state[a]
            it = self.at[a]
            reads, writes = self.effects(it)
            nh = it.f.get("nh")
            worst = 0
            for r in reads:
                for (wk, sc), rem in st.items():
                    if rem > 0 and self.conflict(r, wk):
                        if nh and sc is not None and sc == it.scope:
                            continue
                        worst = max(worst, rem)
            if worst:
                need[a] = max(need.get(a, 0), worst)
            # after issue (as if padded)
            nst = {k: rem - 1 - worst for k, rem in st.items() if rem - 1 - worst > 0}
            for wk, lat in writes:
                k = (wk, it.scope)
                nst[k] = max(nst.get(k, 0), lat - 1)
            for s_ in self.succ(a, it, ret_sites, table):
                old = state[s_]
                if old is None:
                    state[s_] = dict(nst)
                    work.append(s_)
                else:
                    merged = dict(old)
                    ch = False
                    for k, rem in nst.items():
                        if rem > merged.get(k, 0):
                            merged[k] = rem
                            ch = True
                    if ch:
                        state[s_] = merged
                        work.append(s_)
        self.reached = {a for a, s_ in state.items() if s_ is not None}
        return need

    @staticmethod
    def reads_r_at_issue(f):
        return f.get("xop") in (E["X"]["SETX"], E["X"]["LCR"]) or \
            (f.get("nx") in (E["NX"]["JC"], E["NX"]["JNC"]) and f.get("cond") == E["C"]["BIT"])

    def assemble(self):
        for _ in range(50):
            self.layout()
            need = self.check()
            if not need:
                return
            for blk in self.blocks:
                a0, ins, fixed = blk
                out = []
                for i, it in enumerate(ins):
                    k = need.get(a0 + i, 0)
                    if k:
                        if fixed:
                            raise ValueError(f"{it.where}: hazard in a fixed block needs {k} NOPs")
                        if self.reads_r_at_issue(it.f) and i and not _passes_r(ins[i - 1].f):
                            raise ValueError(f"{it.where}: padding would change the R it reads at issue")
                        pad = [Ins(_nop_fields(), it.where + " (pad)") for _ in range(k)]
                        pad[0].labels, it.labels = it.labels, []
                        out += pad
                    out.append(it)
                blk[1] = out
        raise ValueError("hazard padding does not converge")

    # ------------------------------------------------------------ encoding
    def encode(self, it):
        a = b = 0
        f = dict(it.f)
        f.pop("nh", None)
        if f.get("nx") == E["NX"]["DISP"]:
            # DISP writes a collected parameter: R = P
            for k in ("we", "wa", "wx", "acc", "out", "div"):
                if f.get(k, 0):
                    raise ValueError(f"{it.where}: DISP cannot also use {k}")
            f["xs"] = E["XS"]["P"]
            f["aop"] = E["AOP"]["PASSX"]
        for k, v in f.items():
            v = self.resolve(v)
            if k in _A:
                o, w = _A[k]
                if v < 0 or v >= (1 << w):
                    raise ValueError(f"{it.where}: {k}={v} out of range")
                a |= v << o
            elif k in _B:
                o, w = _B[k]
                if k == "imm":
                    v &= (1 << w) - 1
                if v < 0 or v >= (1 << w):
                    raise ValueError(f"{it.where}: {k}={v} out of range")
                b |= v << o
            else:
                raise ValueError(f"{it.where}: unknown field {k}")
        return a, b

    def emit(self, path, depth=1024, module="gpu3d_gxrom"):
        self.assemble()
        aw, bw = isa.width(isa.SLICE_A), isa.width(isa.SLICE_B)
        if max(self.at) >= depth:
            raise ValueError(f"control store overflow ({max(self.at) + 1} > {depth})")
        ab = (depth - 1).bit_length()
        nop_a, nop_b = self.encode(Ins(_nop_fields(), "nop"))
        words = [self.encode(self.at[adr]) if adr in self.at else (nop_a, nop_b) for adr in range(depth)]
        # slice B keeps an index into the table of the image's distinct operands (the immediate with its
        # mode applied, isa.imx) and the divider fields as one code (isa.DV): isa.SLICE_B
        SB = isa.offsets(isa.SLICE_B)

        def fld(v, o, w):
            return (v >> o) & ((1 << w) - 1)

        def opd(b):
            return isa.imx(fld(b, *_B["imm"]), fld(b, *_B["im"]))
        tab = sorted({opd(b) for _, b in words})
        if len(tab) > 1 << isa.IMI_W:
            raise ValueError(f"{len(tab)} distinct immediates, more than the {1 << isa.IMI_W} a {isa.IMI_W}-bit index selects")
        tix = {v: i for i, v in enumerate(tab)}
        dvx = {p: i for i, p in enumerate(isa.DV)}

        def pack(b):
            c = 0
            for n, (o, w) in SB.items():
                if n == "imi":
                    v = tix[opd(b)]
                elif n == "dv":
                    dq = (fld(b, *_B["div"]), fld(b, *_B["dqb"]) if fld(b, *_B["div"]) else 0)
                    if dq not in dvx:
                        raise ValueError(f"divider fields {dq} not in isa.DV")
                    v = dvx[dq]
                else:
                    v = fld(b, *_B[n])
                c |= v << o
            return c

        def view(b):       # what the engine uses of an assembled word: the fields, the operand, the divider pair
            return ({n: fld(b, *_B[n]) for n in SB if n in _B}, opd(b),
                    (fld(b, *_B["div"]), fld(b, *_B["dqb"]) if fld(b, *_B["div"]) else 0))

        def unpack(c):     # the engine's view of a stored word: the index looked up (t_imm), the code decoded
            return ({n: fld(c, *SB[n]) for n in SB if n in _B}, tab[fld(c, *SB["imi"])], isa.DV[fld(c, *SB["dv"])])
        # static proof: every stored word gives the engine what the assembled word gives it, field by field
        for adr, (_, b) in enumerate(words):
            c = pack(b)
            if c >> bw or unpack(c) != view(b):
                raise AssertionError(f"slice B packing: word {adr:#x} does not round-trip")
        self.imm_tab = tab
        lines = ["// Generated by tools/gxasm (ucode.py): geometry engine control store.",
                 "// B2: b_q a second clock later (an M10K output register) for a stage the user would register;",
                 "// b_p: the word b_q takes at the next clock (B2), for decodes registered beside b_q.",
                 f"// Slice B's immediate is an index (B_IMI) into this image's {len(tab)} distinct 32-bit operands",
                 "// (the immediate with its mode applied): t_imm = the operand of index t_idx, read at the clock",
                 "// (an M10K ROM; t_idx from b_p, so t_imm is b_q's operand), beside slice B's output register.",
                 f"// tools/gxasm checked all {depth} words: the stored word gives the engine the assembled word's view.",
                 f"module {module} #(parameter bit B2 = 1'b0) (",
                 "    input  logic        clk,",
                 "    input  logic [10:0] a_addr,",
                 f"    output logic [{aw - 1}:0] a_q,",
                 "    input  logic [10:0] b_addr,",
                 f"    output logic [{bw - 1}:0] b_q,",
                 f"    output logic [{bw - 1}:0] b_p,",
                 f"    input  logic [{isa.IMI_W - 1}:0] t_idx,",
                 f"    output logic [{isa.IMX_W - 1}:0] t_imm",
                 ");",
                 f"    logic [{aw - 1}:0] ra [0:{depth - 1}];",
                 f"    logic [{bw - 1}:0] rb [0:{depth - 1}];",
                 f"    logic [{bw - 1}:0] b_q1;",
                 "    initial begin"]
        for adr, (a, b) in enumerate(words):
            lines.append(f"        ra[{adr}] = {aw}'h{a:0{(aw + 3) // 4}x}; rb[{adr}] = {bw}'h{pack(b):0{(bw + 3) // 4}x};")
        lines += ["    end",
                  "    always_ff @(posedge clk) begin",
                  f"        a_q <= ra[a_addr[{ab - 1}:0]];",
                  f"        b_q1 <= rb[b_addr[{ab - 1}:0]];",
                  "    end",
                  "    generate if (B2) begin : g_b2",
                  "        always_ff @(posedge clk) b_q <= b_q1;",
                  "    end else begin : g_b1",
                  "        assign b_q = b_q1;",
                  "    end endgenerate",
                  "    assign b_p = b_q1;",
                  "    // the operand table: a ROM read at t_idx, one M10K (the engine takes t_imm with b_q)",
                  f"    (* romstyle = \"M10K\", rom_style = \"block\" *) logic [{isa.IMX_W - 1}:0] imt [0:{(1 << isa.IMI_W) - 1}];",
                  "    initial begin"]
        for i in range(1 << isa.IMI_W):
            lines.append(f"        imt[{i}] = {isa.IMX_W}'h{(tab[i] if i < len(tab) else 0):08x};")
        lines += ["    end",
                  "    always_ff @(posedge clk) t_imm <= imt[t_idx];",
                  "endmodule"]
        open(path, "w").write("\n".join(lines) + "\n")
        return len(self.at), sum(1 for it in self.at.values() if it.where.endswith("(pad)"))


# ---------------------------------------------------------------- helpers
def _e(kind, name):
    return E[kind][name] if isinstance(name, str) else name


def jmp(t):            return {"nx": E["NX"]["JMP"], "tgt": t}
def call(t):           return {"nx": E["NX"]["CALL"], "tgt": t}
def ret():             return {"nx": E["NX"]["RET"]}
def disp(t):           return {"nx": E["NX"]["DISP"], "tgt": t}
def djnz(t):           return {"nx": E["NX"]["DJNZ"], "tgt": t}


def jc(c, t, bit=None):
    f = {"nx": E["NX"]["JC"], "tgt": t, "cond": _e("C", c)}
    if bit is not None:
        f["xarg"] = bit
    return f


def jnc(c, t, bit=None):
    f = {"nx": E["NX"]["JNC"], "tgt": t, "cond": _e("C", c)}
    if bit is not None:
        f["xarg"] = bit
    return f


def ra(addr, x=0):
    """port A reads addr + index register x (1..3)"""
    return {"ra": addr, "rax": x}


def rb(addr, x=0):
    return {"rb": addr, "rbx": x}


def w(addr, x=0):
    """write R to addr + index register x (stage M)"""
    return {"we": 1, "wa": addr, "wx": x}


_SH = {0: "S0", 9: "S9", 12: "S12", 21: "S21", 32: "S32"}


def _imm(v):
    """an immediate: sign/zero-extended 24 bits, or 24 bits << 8"""
    v &= 0xFFFFFFFF
    s = v - (1 << 32) if v & 0x80000000 else v
    if -(1 << 23) <= s < (1 << 23):
        return {"imm": s & 0xFFFFFF, "im": E["IM"]["SX"]}
    if v < (1 << 24):
        return {"imm": v, "im": E["IM"]["ZX"]}
    if v & 0xFF == 0:
        return {"imm": v >> 8, "im": E["IM"]["SH8"]}
    raise ValueError(f"immediate {v:#x} not encodable")


# FF: the register-file words the attribute latches mirror, by latch index (set by ucode.py)
ATR_ADDR = []
# PU (FF with LUNIT): XS = ATR with this xsh reads the polygon unit's register named by the immediate
PU_XSH = 7
# labels a DISP may jump to besides the handler table (gpu3d_gxeng's dispatcher: FF's vertex entries)
DISP_ENTRY = []
# FF: the register-file words the vector MAC's lanes mirror (clip and texture matrix, RawTexCoords) and
# CurVertex (its latch, MB3) (set by ucode.py)
VM_ADDR = []
CURV_ADDR = []


def vxr(lane):
    """X operand: vector MAC lane lane's sum >> 12 (FF)"""
    return ("VXR", lane)


def vmac(kind, b):
    """vector MAC (FF): kind VLD (row 0), VLDT (row 4) or VADD (the next row); each lane c adds
    row[c] * b, b: QB, an int (16-bit signed) or MB3 (CurVertex by row, then 0x1000)"""
    f = {"acc": _e("ACC", kind), "ma": E["MA"]["R"]}
    if isinstance(b, int):
        f["mb"] = E["MB"]["IMM"]
        f.update(_imm(b))
    else:
        f["mb"] = _e("MB", b)
    return f


def atr(addr):
    """X operand: the attribute latch of register-file word addr (FF)"""
    return ("ATR", ATR_ADDR.index(addr))


def op(aop, x="QA", y="ZERO", fl=False, sh=None):
    """ALU: R = x aop y. x: QA R ACCX P Q ZDOT MSEL, or atr(addr); y: QB R ZERO or an int"""
    if isinstance(x, tuple):
        f = {"aop": _e("AOP", aop), "xs": E["XS"][x[0]], "xsh": x[1]}
    else:
        f = {"aop": _e("AOP", aop), "xs": _e("XS", x)}
    if x == "ACCX":
        f["xsh"] = _e("XSH", _SH[sh or 0])
    if isinstance(y, int):
        f["ys"] = E["YS"]["IMM"]
        f.update(_imm(y))
    else:
        f["ys"] = _e("YS", y)
    if fl:
        f["fl"] = 1
    return f


def mac(acc, a="QA", b="QB"):
    """accumulate a * b: acc LD ADD SUB ADDM; a: QA R; b: QB R or an int"""
    f = {"acc": _e("ACC", acc), "ma": _e("MA", a)}
    if isinstance(b, int):
        f["mb"] = E["MB"]["IMM"]
        f.update(_imm(b))
    else:
        f["mb"] = _e("MB", b)
    return f


def divs(kind, qb):
    """start the divider: the accumulator (D64) or its low 32 bits (D32) over the ALU's Y operand"""
    return {"div": _e("DIV", kind), "dqb": isa.DQB[qb]}


def out(name):         return {"out": _e("O", name)}
def sm(name):          return {"out": E["O"]["KEY"], "xsh": SMOP[name]}   # USORT sort-table operation
def setx(k):           return {"xop": E["X"]["SETX"], "xarg": k}
def setxi(k, v):       return {"xop": E["X"]["SETXI"], "xarg": k, "ra": v}
def addx(k, d):        return {"xop": E["X"]["ADDX"], "xarg": k | ((d & 0x3F) << 2)}
def movx(k, j):        return {"xop": E["X"]["MOVX"], "xarg": k | (j << 2)}
def lci(n):            return {"xop": E["X"]["LCI"], "xarg": n}
def lcr():             return {"xop": E["X"]["LCR"]}
def dirty(v):          return {"xop": E["X"]["DIRTY"], "xarg": v}
def nh():              return {"nh": 1}
