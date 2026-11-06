#!/usr/bin/env python3
"""Assembler for nds_wifi_mc's microcode (rtl/ds/nds_wifi_mc.sv, docs/wifi.md).

    sim/ds/wifi_mc_asm.py [--check]   rewrites the generated sections of rtl/ds/nds_wifi_mc.sv
                                      (--check: fail if they are out of date)

The engine has a 16-bit accumulator T, one return address, and the register
file, which also holds the state nds_wifi.sv keeps in flops for the power
logic and W_CmdCount (docs/wifi.md "nds_wifi_mc"). Instructions:

    RD r            the register file's read address; Q is register r two clocks later
    RDL r [m]       T = register r & m (three clocks)
    WR r [s [m]]    register r = s & m (s: T unless given)
    LD/LDP s [m]    T = s & m (LDP also answers it: the halfword's read data)
    ADD/AND/OR/XOR/ANDN s [m]   T = T op (s & m) (ANDN: T & ~(s & m)); ADD sets C
    BR c L, BT b L, BF b L      branch on a condition, or on T bit b set / clear
    CALL L, RET     one return address
    MEM k           an SDRAM access; reads load T
    SPC x [s [m]]   flop operations, with s & m

Sources s: IMM (the mask itself: LD IMM 5 is T = 5), Q, W (the halfword's
write value), T, IF, IE, RND (W_Random, advancing), BBFIX (the baseband's
fixed value for W's index). r: a register
0x000-0x3FE, or IX, the access's register. A trailing '!' ends the halfword
(the next halfword or wf_ack) or the timer step. Each routine does one
melonDS action (Wifi.cpp's Read/Write/USTimer/MSTimer/SetIRQ14/
UpdatePowerStatus) in melonDS's order, as nds_wifi.sv's states do.

The dispatch table maps (write, register 0x000-0x3FE) to a routine; RAM,
0x2000-0x3FFF, 0x400-0xFFF and ignored accesses are dispatched by logic.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
RTL = ROOT / 'rtl/ds/nds_wifi_mc.sv'

OPS = ['NOP', 'RD', 'RDL', 'WR', 'LD', 'LDP', 'ADD', 'AND', 'OR', 'XOR', 'ANDN', 'BR', 'BT', 'BF', 'CALL', 'RET',
       'MEM', 'SPC']
SRCS = ['IMM', 'Q', 'W', 'T', 'IF', 'IE', 'RND', 'BBFIX']
CONDS = ['ALWAYS', 'Z', 'NZ', 'C', 'NC', 'QZ', 'NOTMS', 'BLOCK', 'BBW', 'BBR', 'BBRO', 'NOTPB']
SPCS = ['IFOR', 'IFANDN', 'IE', 'PWUS', 'BLOCK_SET_W', 'BLOCK_CLR', 'USP', 'K268']
MEMS = ['CPU', 'BBW', 'BBR', 'RFWL', 'RFWH', 'RFRL', 'RFRH']

# W_ModeReset's defaults: bit 14 (in this order), then bit 13
DEF14 = [(0x008, 0), (0x00A, 0), (0x018, 0), (0x01A, 0), (0x01C, 0), (0x020, 0), (0x022, 0), (0x024, 0),
         (0x028, 0), (0x02A, 0), (0x02C, 0x0707), (0x02E, 0), (0x050, 0x4000), (0x052, 0x4800), (0x084, 0),
         (0x0BC, 0x0001), (0x0D0, 0x0401), (0x0D4, 0x0001), (0x0E0, 0x0008), (0x0EC, 0x3F03), (0x194, 0),
         (0x198, 0), (0x1A2, 0x0001), (0x224, 0x0003), (0x230, 0x0047), (0x006, 0)]
DEF13 = [(0x056, 0), (0x0C0, 0), (0x0C4, 0), (0x1A4, 0), (0x278, 0x000F)]

MASKED = {0x028: 0x000F, 0x02A: 0x07FF, 0x030: 0xFF0E, 0x058: 0x1FFE, 0x062: 0x1FFE, 0x068: 0x1FFE,
          0x074: 0x1FFE, 0x056: 0x0FFF, 0x05A: 0x0FFF, 0x05C: 0x0FFF, 0x064: 0x0FFF, 0x06C: 0x0FFF,
          0x076: 0x0FFF, 0x0B4: 0x0000, 0x184: 0x413F, 0x0E8: 0x0001}
READ_ONLY = [0x000, 0x034, 0x044, 0x054, 0x098, 0x0B0, 0x0B6, 0x0B8, 0x15C, 0x15E, 0x180, 0x19C, 0x1A8,
             0x1AC, 0x1C4, 0x210, 0x214, 0x268]

# State in register-file slots the CPU cannot write (or whose writes go elsewhere):
#   0x034 W_TRXPower, 0x03C W_PowerState, 0x048 W_PowerDownCtrl, 0x214 W_RFStatus, 0x19C W_RFPins
#   (read there; W_RFPins as melonDS's SetStatus sets it, 0 until the first status);
#   0x118 W_CmdCount's tens and 0x21C its remainder; 0x15E the power-up's 8 us steps left;
#   0x044 UpdatePowerStatus's argument (0, 1 on, 2 off); 0x180 the prescaler's residual (below)
P = """
; ---- CPU accesses (one halfword each; IX is its register, W its write value)
; (0 is the dispatch table's "H_RD / H_WR", so no routine starts there)
H_ZERO:  NOP !
H_NEXT:  NOP !
H_FF:    LDP IMM 0xFFFF !
H_MEM:   LD W
         MEM CPU
         LDP T !
H_RD:    LDP Q !
H_RDBC:  LDP Q 0x0003 !
H_RDB6:  LDP Q 0x001F !
H_RDCS:  LDP Q
         WR IX IMM 0 !
H_RIF:   LDP IF !
H_RIE:   LDP IE !
H_RRND:  LDP RND !
; W_CmdCount reads (n + 9) / 10: tens + (remainder != 0)
H_RCMD:  LD Q
         RD 0x21C
         NOP
         BR QZ RCMD_P
         ADD IMM 0x0001
RCMD_P:  LDP T !
H_RZERO: LDP IMM 0 !
H_WR:    LD W
         WR IX !
{masked}
H_W010:  SPC IFANDN W !
H_W21C:  SPC IFOR W 0xFBFF !
H_W012:  LD W
         WR IX
         SPC IE W !
H_W036:  LD W 0x0003
         WR IX
         SPC PWUS !
H_W040:  LD W 0x8001
         WR IX
         CALL POW0
         NOP !
H_W118:  LD W
         WR IX
         WR 0x21C IMM 0 !
H_W0F0:  LD W 0xFC00
         WR IX
         SPC BLOCK_SET_W !
; W_TXReqReset / W_TXReqSet on W_TXReqRead (TXReqSet's FireTX: not modelled)
H_W0AC:  RDL 0x0B0
         ANDN W
         WR 0x0B0 !
H_W0AE:  RDL 0x0B0
         OR W
         WR 0x0B0 !
; W_PowerState in power mode 3
H_W03C:  RDL 0x006 0x0007
         XOR IMM 0x0003
         BR NZ H_NEXT
         RDL 0x03C 0x0300
         OR W 0x0003
         BF 9 W03C_N9
         BT 8 W03C_A
         AND IMM 0xFFFE
         BR ALWAYS W03C_W
W03C_A:  AND IMM 0xFFFD
         BR ALWAYS W03C_W
W03C_N9: AND IMM 0xFEFD
W03C_W:  WR 0x03C
         CALL POW0
         NOP !
; W_ModeWEP, W_PowerTX, W_PowerDownCtrl: with W_PowerTX bit 1, W_PowerDownCtrl
; follows the power mode (1: | 2, 2: 3)
H_W006:  LD W 0x007F
         WR IX
         RDL 0x038
         BF 1 H_NEXT
         LD W 0x0007
         XOR IMM 0x0003
         BR Z PDCM
         RDL 0x03C 0x0300
         WR 0x03C
         BR ALWAYS PDCM
H_W038:  LD W 0x0003
         WR IX
         BF 1 H_NEXT
         BR ALWAYS PDCM
H_W048:  LD W 0x0003
         WR IX
         RDL 0x038
         BF 1 PDCP
PDCM:    RDL 0x006 0x0007
         XOR IMM 0x0001
         BR NZ PDCM2
         RDL 0x048
         OR IMM 0x0002
         WR 0x048
         BR ALWAYS PDCP
PDCM2:   XOR IMM 0x0003
         BR NZ PDCP
         WR 0x048 IMM 0x0003
PDCP:    CALL POW0
         NOP !
; bit 1: a forced IRQ14, with the enable before this write (melonDS)
H_W0EA:  LD Q
         BF 0 W0EA_N
         LD W
         BF 1 W0EA_N
         LD W 0x0001
         WR IX
         CALL I14_BODY
         NOP !
W0EA_N:  LD W 0x0001
         WR IX !
; W_ModeReset: W_PowerState etc. on a change of bit 0, then the defaults
H_W004:  LD Q
         XOR W 0x0001
         BR Z W004_D
         LD W 0x0001
         WR IX
         WR 0x27C IMM 0x000A
         BF 0 W004_P
         WR 0x27C IMM 0x0005
W004_P:  CALL POW0
W004_D:  LD W 0x0001
         WR IX
         LD W
         BF 14 W004_13
{def14}
W004_13: BF 13 H_NEXT
{def13}
; W_BBCnt: 0x5xxx writes W_BBWrite's byte, 0x6xxx reads into W_BBRead
H_W158:  LD W
         WR IX
         BR BBW W158_W
         BR BBR W158_R
         WR 0x15C IMM 0 !
W158_W:  RDL 0x15A 0x00FF
         MEM BBW
         WR 0x15C IMM 0 !
W158_R:  BR BBRO W158_F
         MEM BBR
         WR 0x15C !
W158_F:  LD BBFIX
         WR 0x15C !
; W_RFData2: bit 7 reads into W_RFData1/2, else writes W_RFData1 and bits 1:0
H_W17C:  LD W
         WR IX
         BT 7 W17C_R
         RDL 0x17E
         MEM RFWL
         LD W 0x0003
         MEM RFWH
         NOP !
W17C_R:  MEM RFRL
         WR 0x17E
         MEM RFRH
         OR W 0xFFFC
         WR 0x17C !

; ---- the 8 us step (USTimer). First the prescaler: nds_wifi.sv's + 1e6 a tick and a step at
; 268,111,856 give steps 268 or 269 ticks apart: 268 when the residual after the step (/ 16) is
; at least 6,991. The residual after the next step: r - 6991 or r + 55509; then that step's interval.
T_STEP:  RDL 0x180
         ADD IMM 0xE4B1
         BR C T_K
         ADD IMM 0xF424
T_K:     WR 0x180
         ADD IMM 0xE4B1
         SPC K268
; the power-up's end
         RDL 0x15E
         BR Z T_U
         ADD IMM 0xFFFF
         WR 0x15E
         BR NZ T_U
         WR 0x03C IMM 0
         WR 0x214 IMM 1
         WR 0x19C IMM 0x0084
         CALL POW0
; the microsecond counter + 8
T_U:     RDL 0x0E8
         BF 0 T_D0
         RDL 0x0F8
         ADD IMM 0x0008
         WR 0x0F8
         SPC USP
         BR NC T_B0
         RDL 0x0FA
         ADD IMM 0x0001
         WR 0x0FA
         BR NC T_B0
         RDL 0x0FC
         ADD IMM 0x0001
         WR 0x0FC
         BR NC T_B0
         RDL 0x0FE
         ADD IMM 0x0001
         WR 0x0FE
; W_PreBeacon (IRQ15, and the wake-up with W_PowerTX bit 0): T = BeaconCount1, Q = PreBeacon
T_B0:    RDL 0x0EA
         BF 0 T_M0
         RD 0x11C
         RD 0x110
         LD Q
         BR NOTPB T_M0
         SPC IFOR IMM 0x8000
         RDL 0x038
         BF 0 T_M0
         CALL POW_ON
; the 1 ms timer (MSTimer): USCount[63:10] == USCompare[63:10]
T_M0:    BR NOTMS T_D0
         RDL 0x0EA
         BF 0 T_BCR
         RD 0x0F8
         RD 0x0F0
         LD Q 0xFC00
         XOR Q 0xFC00
         BR NZ T_BCR
         RD 0x0FA
         RD 0x0F2
         LD Q
         XOR Q
         BR NZ T_BCR
         RD 0x0FC
         RD 0x0F4
         LD Q
         XOR Q
         BR NZ T_BCR
         RD 0x0FE
         RD 0x0F6
         LD Q
         XOR Q
         BR NZ T_BCR
         SPC BLOCK_CLR
         CALL I14R
; BeaconCount1 - 1, IRQ14 at 0
T_BCR:   RDL 0x11C
         BR Z T_BZR
         ADD IMM 0xFFFF
         WR 0x11C
         BR NZ T_BZR
         CALL I14B
; BeaconCount1 == 0: = BeaconInterval
T_BZR:   RDL 0x11C
         BR NZ T_D1
         RDL 0x08C
         WR 0x11C
; BeaconCount2 - 1, IRQ13 at 0 (and in power mode 0 without W_PowerTX bit 1, a power-down)
T_D1:    RDL 0x134
         BR Z T_D0
         ADD IMM 0xFFFF
         WR 0x134
         BR NZ T_D0
         SPC IFOR IMM 0x2000
         RDL 0x006 0x0007
         BR NZ T_D0
         RDL 0x038
         BT 1 T_D0
         CALL POW_OFF
; W_CmdCount - 8 us (10 q + r: r >= 8: r - 8; q = 0: r = 0; else 10 (q - 1) + r + 2)
T_D0:    RDL 0x0EE
         BF 0 T_CF
         RDL 0x21C
         ADD IMM 0xFFF8
         BR C T_CR
         RDL 0x118
         BR Z T_CZ
         ADD IMM 0xFFFF
         WR 0x118
         RDL 0x21C
         ADD IMM 0x0002
         WR 0x21C
         BR ALWAYS T_CF
T_CR:    WR 0x21C
         BR ALWAYS T_CF
T_CZ:    WR 0x21C IMM 0
; W_ContentFree - 8, not below 0
T_CF:    RDL 0x10C
         BR Z T_END
         ADD IMM 0xFFF8
         BR NC T_CF0
         WR 0x10C !
T_CF0:   WR 0x10C IMM 0 !
T_END:   NOP !

; ---- SetIRQ14: BeaconCount1 = BeaconInterval (not the forced one), then IRQ14 if allowed
I14B:    RDL 0x08C
         WR 0x11C
         BR BLOCK I14_RET
         RDL 0x0EA
         BF 0 I14_RET
         BR ALWAYS I14_BODY
I14R:    RDL 0x08C
         WR 0x11C
         RDL 0x0EA
         BF 0 I14_RET
I14_BODY: SPC IFOR IMM 0x4000
         WR 0x134 IMM 0xFFFF
         RDL 0x0B0 0xFFF2
         WR 0x0B0
; ListenCount: if 0, = ListenInterval; then - 1
         RDL 0x088
         BR NZ I14_L
         RDL 0x08E
I14_L:   ADD IMM 0xFFFF
         WR 0x088
I14_RET: RET

; ---- UpdatePowerStatus (0, 1 on, 2 off): req = 0, 3 or cur = {!PowerState bit 9, TRXPower == 1}
POW_ON:  WR 0x044 IMM 1
         BR ALWAYS POW
POW_OFF: WR 0x044 IMM 2
         BR ALWAYS POW
POW0:    WR 0x044 IMM 0
POW:     RDL 0x040
         BF 15 P_NF
         BT 0 P_REQ0
         BR ALWAYS P_REQ3
P_NF:    RDL 0x004
         BF 0 P_REQ0
         RDL 0x044
         BT 0 P_REQ3
         BT 1 P_OFF
         RDL 0x03C
         BF 9 P_N9
         BT 1 P_REQ3
         BR ALWAYS P_NONE
P_N9:    BT 0 P_OFF
P_NONE:  RDL 0x048
         BT 1 P_REQ3
         RET
; off (unless PowerDownCtrl bit 0): req = PowerDownCtrl != 0 ? 3 : 0
P_OFF:   RDL 0x048
         BT 1 P_REQ3
         BT 0 P_RET
         BR ALWAYS P_REQ0
; req 3, cur != 3: the transceiver on (status 1); PowerState bit 8; from off, the 2048 us power-up and IRQ11
P_REQ3:  RDL 0x034
         BF 0 P3_C0
         RDL 0x03C
         BF 9 P_RET
         BR ALWAYS P3_HI
P3_C0:   WR 0x034 IMM 1
         WR 0x214 IMM 1
         WR 0x19C IMM 0x0084
P3_HI:   RDL 0x03C
         OR IMM 0x0100
         WR 0x03C
         BF 9 P_RET
         RDL 0x15E
         BR NZ P_RET
         WR 0x15E IMM 256
         SPC IFOR IMM 0x0800
         RET
; req 0, cur != 0: the transceiver off (status 9), PowerState bits 0 and 8 clear, bit 9 set
P_REQ0:  RDL 0x034
         BT 0 P0_GO
         RDL 0x03C
         BT 9 P_RET
P0_GO:   WR 0x034 IMM 0
         WR 0x214 IMM 9
         WR 0x19C IMM 0x0004
         RDL 0x03C 0x0202
         OR IMM 0x0200
         WR 0x03C
         WR 0x15E IMM 0
P_RET:   RET
"""

# dispatch: register -> routine, for reads and writes (others: H_RD / H_WR)
READS = {0x010: 'H_RIF', 0x012: 'H_RIE', 0x044: 'H_RRND', 0x118: 'H_RCMD', 0x15E: 'H_RZERO', 0x180: 'H_RZERO',
         0x21C: 'H_RZERO', 0x0BC: 'H_RDBC', 0x0B6: 'H_RDB6'}
READS.update({r: 'H_RDCS' for r in range(0x1D0, 0x1E0, 2)})
WRITES = {r: 'H_NEXT' for r in READ_ONLY + [0x060, 0x070]}
WRITES.update({0x010: 'H_W010', 0x21C: 'H_W21C', 0x012: 'H_W012', 0x004: 'H_W004', 0x006: 'H_W006',
               0x036: 'H_W036', 0x038: 'H_W038', 0x03C: 'H_W03C', 0x040: 'H_W040', 0x048: 'H_W048',
               0x0EA: 'H_W0EA', 0x0F0: 'H_W0F0', 0x0AC: 'H_W0AC', 0x0AE: 'H_W0AE', 0x118: 'H_W118',
               0x158: 'H_W158', 0x17C: 'H_W17C'})
WRITES.update({r: f'H_M{m:04X}' for r, m in MASKED.items()})
# entries the hardware dispatch uses
ENTRIES = ['H_NEXT', 'H_FF', 'H_MEM', 'H_RD', 'H_WR', 'T_STEP']


def source():
    masked = []
    for m in sorted(set(MASKED.values())):
        masked += [f'H_M{m:04X}: LD W 0x{m:04X}', '         WR IX !']
    def14 = [f'         WR 0x{r:03X} IMM 0x{v:04X}' for r, v in DEF14]
    def13 = [f'         WR 0x{r:03X} IMM 0x{v:04X}' for r, v in DEF13]
    def13[-1] += ' !'
    s = P.replace('{masked}', '\n'.join(masked)).replace('{def14}', '\n'.join(def14))
    return s.replace('{def13}', '\n'.join(def13))


def assemble(text):
    prog, labels = [], {}
    for raw in text.splitlines():
        ln = raw.split(';')[0].strip()
        if not ln:
            continue
        m = re.match(r'^(\w+):\s*(.*)$', ln)
        if m:
            assert m.group(1) not in labels, m.group(1)
            labels[m.group(1)] = len(prog)
            ln = m.group(2).strip()
            if not ln:
                continue
        nx = ln.endswith('!')
        prog.append((ln.rstrip('!').split(), nx, ln))
    words = []
    for parts, nx, src in prog:
        op, args = parts[0], parts[1:]
        assert op in OPS, src
        c, ax, a, imm = 0, 0, 0, 0xFFFF

        def reg(x):
            nonlocal ax, a
            if x == 'IX':
                ax = 1
            else:
                r = int(x, 0)
                assert r < 0x400 and r % 2 == 0, src
                a = r >> 1

        def operand(xs, default='T'):
            # c = the source, imm = its mask (IMM: the value)
            nonlocal c, imm
            s = xs[0] if xs else default
            c = SRCS.index(s)
            if len(xs) > 1:
                imm = int(xs[1], 0) & 0xFFFF
            assert s != 'IMM' or len(xs) == 2, src
        if op in ('RD', 'RDL'):
            reg(args[0])
            if len(args) > 1:
                imm = int(args[1], 0)
        elif op == 'WR':
            reg(args[0]); operand(args[1:])
        elif op in ('LD', 'LDP', 'ADD', 'AND', 'OR', 'XOR', 'ANDN'):
            operand(args)
        elif op == 'BR':
            c = CONDS.index(args[0]); a = labels[args[1]]
        elif op in ('BT', 'BF'):
            c = int(args[0]); a = labels[args[1]]
            assert c < 16, src
        elif op == 'CALL':
            a = labels[args[0]]
        elif op == 'SPC':
            a = SPCS.index(args[0])
            operand(args[1:], 'IMM') if len(args) > 1 else None
        elif op == 'MEM':
            c = MEMS.index(args[0])
        else:
            assert not args, src
        assert not (nx and op in ('BR', 'BT', 'BF', 'CALL', 'RET', 'MEM', 'RD', 'RDL')), src
        words.append((OPS.index(op), int(nx), c, ax, a, imm, src))
    # the register file reads an RD's address in the next clock: no write to it there
    for i, w in enumerate(words[:-1]):
        n = words[i + 1]
        if w[0] == OPS.index('RD') and n[0] == OPS.index('WR'):
            assert (w[3], w[4]) != (n[3], n[4]), f'write after RD of the same register: {w[6]}'
    return words, labels


def generated(words, labels):
    params = [f'// {len(words)} instructions; encoding {{op[4:0], nx, c[4:0], ax, a[8:0], imm[15:0]}}']
    for pre, names in (('O', OPS), ('S', SRCS), ('C', CONDS), ('X', SPCS), ('M', MEMS)):
        w = 9 if pre == 'X' else 5
        params.append(' '.join(f"localparam logic [{w - 1}:0] {pre}_{n} = {w}'d{i};" for i, n in enumerate(names)))
    # the hardware dispatch's entries, and every routine (wifi_test.py's mutants find theirs here)
    names = ENTRIES + sorted(n for n in labels if n.startswith('H_') and n not in ENTRIES)
    params.append(' '.join(f"localparam logic [8:0] E_{n} = 9'd{labels[n]};" for n in names))
    rom = ['    always_ff @(posedge clk) begin',
           '        case (pc_n)']
    for i, (op, nx, c, ax, a, imm, src) in enumerate(words):
        rom.append(f"            9'd{i}: ins <= {{5'd{op}, 1'b{nx}, 5'd{c}, 1'b{ax}, 9'h{a:03X}, 16'h{imm:04X}}};"
                   f"   // {src}")
    rom += ["            default: ins <= 37'd0;", '        endcase', '    end']
    # (an initialised array: Quartus 25.1's synthesis fails with an internal error, VRFX
    # vrfx_sgate.cpp line 7864, on this table as a sparse case statement, #388)
    disp = ['    (* romstyle = "M10K" *) logic [8:0] dtab [0:1023];',
            '    initial begin',
            "        for (int i = 0; i < 1024; i++) dtab[i] = 9'd0;            // H_RD / H_WR"]
    for we, tab in ((0, READS), (1, WRITES)):
        for r in sorted(tab):
            disp.append(f"        dtab[10'h{we << 9 | r >> 1:03X}] = 9'd{labels[tab[r]]};"
                        f"   // {'W' if we else 'R'} {r:03X} {tab[r]}")
    assert labels['H_ZERO'] == 0 and 0 not in [labels[n] for n in list(READS.values()) + list(WRITES.values())]
    disp += ['    end', '    always_ff @(posedge clk) dt_q <= dtab[dt_a];']
    return '\n'.join(params), '\n'.join(rom + [''] + disp)


def main():
    words, labels = assemble(source())
    assert len(words) <= 512, len(words)
    params, roms = generated(words, labels)
    s = RTL.read_text()
    for tag, body in (('PARAMS', params), ('ROMS', roms)):
        b, e = f'// ---- BEGIN GENERATED {tag} (sim/ds/wifi_mc_asm.py)\n', f'// ---- END GENERATED {tag}\n'
        i, j = s.index(b) + len(b), s.index(e)
        s = s[:i] + body + '\n' + s[j:]
    if '--check' in sys.argv:
        sys.exit(0 if s == RTL.read_text() else 'nds_wifi_mc.sv: generated sections out of date')
    RTL.write_text(s)
    print(f'{len(words)} instructions -> {RTL.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
