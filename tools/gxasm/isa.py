"""Geometry engine microword layout (docs/geometry-engine.md).

Single source of truth for rtl/gpu3d/gpu3d_gxu_pkg.sv (generated) and the
microcode assembler. The engine is scalar: one ALU, one multiply-accumulate
unit, a register file of 2048 words with two read ports. Two control-store
slices, read one cycle apart:

  A  issue stage I: sequencer, register-file read and write addresses,
     index-register and loop-counter operations
  B  operand stage O: operand selection, ALU, MAC operands, divider start,
     outputs; the write and output fields act one stage later (M), with the
     ALU result R.

Pipeline: I (addresses) -> O (operands, ALU -> R) -> M (R -> register file,
outputs; product) -> A (accumulator). Latencies the assembler enforces:
  - R is an operand of the next instruction;
  - a register-file word written by instruction i is readable by i+3;
  - the accumulator after a MAC at i is readable (ACCX, divider) by i+3,
    its flags (A63, AZ, NFIT) by i+5;
  - ALU flags and R are conditions (and SETX/LCR sources) for i+2;
  - an index register set at i addresses i+1 (SETX takes R, SETXI the
    constant in the port-A address field, ADDX adds a signed step).
"""

# (name, width) in LSB-first order
SLICE_A = [
    ("nx", 3), ("tgt", 11), ("cond", 5),
    ("ra", 11), ("rax", 2),
    ("rb", 11), ("rbx", 2),
    ("wa", 11), ("wx", 2), ("we", 1),
    ("xop", 3), ("xarg", 8),
]
# SLICE_B_IMM: slice B as the assembler encodes it, with the 24-bit immediate. The control store
# keeps SLICE_B: the immediate and its mode (imm, im) replaced by IMI_W bits, an index into the
# image's table of its distinct 32-bit operands as the engine sees them (IMX: im applied; gpu3d_gxrom*
# t_idx/t_imm, a ROM read beside the slice's output register), and the divider fields (div, dqb) by
# one DV_W-bit code (DV below).
IMM_W, IMI_W, IMX_W, DV_W = 24, 7, 32, 3
SLICE_B_IMM = [
    ("xs", 4), ("ys", 2), ("aop", 5), ("fl", 1),
    ("imm", IMM_W), ("im", 2),
    ("ma", 1), ("mb", 2), ("acc", 3), ("xsh", 3),
    ("out", 4), ("div", 2), ("dqb", 2),
]
SLICE_B = [("xs", 4), ("ys", 2), ("aop", 5), ("fl", 1), ("imi", IMI_W),
           ("ma", 1), ("mb", 2), ("acc", 3), ("xsh", 3), ("out", 4), ("dv", DV_W)]
assert [f for f in SLICE_B if f[0] not in ("imi", "dv")] == [f for f in SLICE_B_IMM if f[0] not in ("imm", "im", "div", "dqb")]

ENUMS = {
    # sequencer
    "NX": ["NEXT", "JMP", "JC", "JNC", "CALL", "RET", "DISP", "DJNZ"],
    "C": ["Z", "N", "C", "LT", "BIT", "A63", "AZ", "NFIT",
          "DBUSY", "OBUSY", "MREQ", "SWAPGO", "SORTBUSY", "DIRTY", "DSR", "ALWAYS",
          "LBUSY",                                             # LBUSY: the lighting unit (gpu3d_gxlight) is busy
          "VBUSY",                                             # VBUSY: the vertex-finish unit (gpu3d_gxvfin) is busy
          "VARM",                                              # VARM: as VBUSY; a jc on it that falls through arms the unit for the next G_W write
          "SDRAW",                                             # SDRAW: the polygon store is still drawing a frame from its on-chip lists (nds_g3d_store f_live)
          # PU (gpu3d_gxeng FF with LUNIT, GX_FAST): the polygon unit
          "PSTEP",                                             # PSTEP: the vertex step; true when it completes a polygon (side effect: the unit steps)
          "PTRIV",                                             # PTRIV: the polygon is wholly outside one plane (clipstart 0; trivial reject)
          "TEX3"],                                             # TEX3: texture coordinate mode 3 (TEXM's latch)
    # index / loop operations (issue stage)
    "X": ["NOP", "SETX", "ADDX", "LCI", "LCR", "DIRTY", "MOVX", "SETXI"],
    # ALU operand X, Y
    "XS": ["QA", "R", "ACCX", "P", "Q", "ZDOT", "MSEL", "ZERO", "VOCW", "VOCS",
           "SBL", "SCT", "SNX", "SYB",    # USORT: sort-table read data (below)
           "ATR",                         # FF: an attribute latch (gpu3d_gxeng), its index in the xsh field
           "VXR"],                        # FF: a vector MAC lane's sum: xsh 0-3 bits 12..43 of lane xsh,
                                          # 4-7 bits 24..39 sign-extended of lane xsh - 4
    "YS": ["QB", "R", "IMM", "ZERO"],
    # immediate: sign- or zero-extended 24 bits, or shifted left by 8
    "IM": ["SX", "ZX", "SH8", "IM3"],
    # ALU
    "AOP": ["ADD", "SUB", "RSUB", "AND", "OR", "XOR", "SHL", "SHR",
            "SAR", "SX16", "SX11", "MAX", "MIN", "BIC", "PASSX", "SLT",
            "MABS", "K4", "FSH"],
    # MAC operands: MA from QA or R; MB from QB, R or the immediate
    "MA": ["QA", "R"],
    "MB": ["QB", "R", "IMM", "MB3"],     # MB3 (FF, vector MAC): CurVertex x, y, z by row, then 0x1000
    # accumulate
    # VLD, VADD, VLDT (FF): the vector MAC's four lanes; VLD starts at row 0 (the clip matrix), VLDT at row 4
    # (the texture matrix's columns, then RawTexCoords << 12), VADD takes the next row; times MB
    "ACC": ["NONE", "LD", "ADD", "SUB", "ADDM", "VLD", "VADD", "VLDT"],
    # accumulator extraction (ACCX = acc >> shift, low 32 bits)
    "XSH": ["S0", "S9", "S12", "S21", "S32"],      # S9, S12, S32 one-hot (gpu3d_gxeng selects by bit)
    # outputs, with this instruction's R (stage M)
    "O": ["NONE", "O0", "O1", "O2", "O3", "PUSHH", "PUSHV", "KEY",
          "NPNV", "OC", "SWAP", "BOX", "TDONE", "MRES", "OVF", "VPOS"],
    # divider: start with the accumulator (or its low 32 bits) over Y
    "DIV": ["NONE", "D64", "D32", "D3"],
}

# USORT (gpu3d_gxeng): the polygon sort in microcode. A sort-table operation
# is out = KEY with the operation in the xsh field (it cannot use ACCX), at
# stage M with R:
#   RB      read the bucket tables: BL at {R[16], R[7:0]} (= {t, ytop} of a
#           key), CT at {R[16], R[15:8]} ({t, ybot}); their write addresses
#           become those
#   RP      read the polygon tables NX, YB at R[10:0]; the polygon address
#           (so_idx) becomes R[10:0]
#   COMMIT  polygon np (the engine's count) goes to the front of its {t, ytop}
#           list: NX[np] = the bucket's head (0x7FF: none), BL = {tag, np},
#           YB[np] = the CT address
#   WCT     CT = {tag, R}
#   SOW     so_pos = R, so_idx = the polygon address; CT = {tag, R}
#   WBL     BL = {tag, np} (re-tags a bucket)
#   SOD     flip the tag; so_done if R[0]
# Read data, XS SBL SCT SYB, from the second instruction after the read (SNX: the third, a register after the RAM)
# until the next read of that table: SBL the head (-1 for another tag's
# bucket), SCT the count (0 for another tag), SNX the next polygon (-1: the
# end), SYB {t, ybot} at bits 16, 15:8 (an RB address) and t also at bit 31.
SM = ["RB", "RP", "COMMIT", "WCT", "SOW", "WBL", "SOD"]

DQB = {10: 0, 16: 1, 32: 2, 64: 3}
# DV: the (div, dqb) pairs a word may use, by code (gpu3d_gxeng decodes it): none, D64 with 10/16/32/64
# quotient bits, D32 with 10/16/32 (D3 and D32 with 64 bits unused)
DV = [(0, 0), (1, 0), (1, 1), (1, 2), (1, 3), (2, 0), (2, 1), (2, 2)]


def imx(imm, im):
    """the 32-bit operand of a 24-bit immediate in mode im (gpu3d_gxeng's imm: SX, ZX, SH8; IM3 as SX)"""
    if im == 1:
        return imm
    if im == 2:
        return (imm << 8) & 0xFFFFFFFF
    return imm | (0xFF000000 if imm & 0x800000 else 0)


def width(sl):
    return sum(w for _, w in sl)


def offsets(sl):
    o, r = 0, {}
    for n, w in sl:
        r[n] = (o, w)
        o += w
    return r


# The GX FIFO entry's command byte as the front stores it: {multi-parameter, 0, handler index}.
# The engine dispatches on the index (the handler table, ucode.py HT) and takes CmdNumParams from it
# (a function of the index for every command byte), so no command decode lies between the entry RAM
# and the control-store address (#519: gxfront u_ent -> gxrom address).
GX_FUNCS = """\
    // command -> handler entry 0..37 (entry 0: NOP and unknown commands; ucode.py HT)
    function automatic [5:0] gx_hidx(input [7:0] c);
        if (c >= 8'h10 && c <= 8'h1C)      gx_hidx = 6'(c - 8'h10 + 8'd1);    //  1..13
        else if (c >= 8'h20 && c <= 8'h2B) gx_hidx = 6'(c - 8'h20 + 8'd14);   // 14..25
        else if (c >= 8'h30 && c <= 8'h34) gx_hidx = 6'(c - 8'h30 + 8'd26);   // 26..30
        else if (c == 8'h40 || c == 8'h41) gx_hidx = 6'(c - 8'h40 + 8'd31);   // 31..32
        else if (c == 8'h50)               gx_hidx = 6'd33;
        else if (c == 8'h60)               gx_hidx = 6'd34;
        else if (c >= 8'h70 && c <= 8'h72) gx_hidx = 6'(c - 8'h70 + 8'd35);   // 35..37
        else                               gx_hidx = 6'd0;
    endfunction
    // CmdNumParams by handler entry
    function automatic [5:0] gx_np(input [5:0] i);
        case (i)
            6'd7, 6'd9:            gx_np = 6'd16;   // 16h, 18h
            6'd8, 6'd10:           gx_np = 6'd12;   // 17h, 19h
            6'd11:                 gx_np = 6'd9;    // 1Ah
            6'd12, 6'd13, 6'd35:   gx_np = 6'd3;    // 1Bh, 1Ch, 70h
            6'd17, 6'd36:          gx_np = 6'd2;    // 23h, 71h
            6'd30:                 gx_np = 6'd32;   // 34h
            default:               gx_np = 6'd0;
        endcase
    endfunction
    function automatic [7:0] gx_ecode(input [7:0] c);
        gx_ecode = {gx_np(gx_hidx(c)) != 6'd0, 1'b0, gx_hidx(c)};
    endfunction"""


def gen_pkg(path, extra=()):
    out = ["// Generated by tools/gxasm/isa.py: geometry engine microword layout.",
           "package gpu3d_gxu_pkg;"]
    for tag, sl in (("A", SLICE_A), ("B", SLICE_B)):
        out.append(f"    localparam int {tag}_W = {width(sl)};")
        for n, (o, w) in offsets(sl).items():
            out.append(f"    localparam int {tag}_{n.upper()}_LO = {o}, {tag}_{n.upper()}_W = {w};")
    out.append(f"    localparam int IMX_W = {IMX_W};   // the operand a B_IMI index selects (gpu3d_gxrom* t_imm)")
    for e, names in list(ENUMS.items()) + [("SM", SM)]:
        for i, n in enumerate(names):
            out.append(f"    localparam int {e}_{n} = {i};")
    out += list(extra)
    out.append(GX_FUNCS)
    out.append("endpackage")
    open(path, "w").write("\n".join(out) + "\n")


if __name__ == "__main__":
    import sys
    gen_pkg(sys.argv[1])
