/* sys.nds, ARM9: maths, DMA, timers, IPC, BIOS SWIs on both CPUs,
   WRAMCNT, VRAM bank mapping, palette/OAM, KEYINPUT. Expected values follow
   GBATEK; tools/ds-tests/README.md lists them. */
#include "../common/con.h"
#include "../common/results.h"
#include "../common/ipc.h"
#include "swi_data.h"

enum { CMD_SYNC = 1, CMD_FIFO_RX, CMD_FIFO_TX, CMD_SWI, CMD_WRAM, CMD_VRAM, CMD_DMA };

static u32 dma_src[64] = {1};
static u32 dma_dst[64];

static void div_run(u32 mode, u32 nl, u32 nh, u32 dl, u32 dh)
{
    DIVCNT = mode;
    DIV_NUMER_L = nl; DIV_NUMER_H = nh;
    DIV_DENOM_L = dl; DIV_DENOM_H = dh;
    while (DIVCNT & 0x8000)
        ;
}

static void dma3(const volatile void *src, volatile void *dst, u32 ctl)
{
    DMA_SAD(3) = (u32)src;
    DMA_DAD(3) = (u32)dst;
    DMA_CNT(3) = ctl | DMA_ENABLE;
    while (DMA_CNT(3) & DMA_ENABLE)
        ;
}

static u32 sum32(const volatile u32 *p, int n)
{
    u32 s = 0;
    for (int i = 0; i < n; i++)
        s += p[i];
    return s;
}

static u32 spin_until_tm(int t, u32 v)
{
    for (u32 i = 0; i < 2000000; i++)
        if (TM_CNT_L(t) >= v)
            return 1;
    return 0;
}

/* WRAM phase: the ARM7 sits in its .iwram loop and reads addresses for us */
static u32 a7_read(u32 addr)
{
    static u32 seq;
    MB->subaddr = addr;
    MB->sub = ++seq;
    WAIT_UNTIL(MB->suback == seq, 60);
    return MB->subval;
}

static const u32 lcdc_base[9] = {
    0x06800000, 0x06820000, 0x06840000, 0x06860000, 0x06880000,
    0x06890000, 0x06894000, 0x06898000, 0x068A0000,
};
enum { BA, BB, BC, BD, BE, BF, BG, BH, BI };

static int vram_map(int bank, u32 cnt, u32 addr, u32 k)
{
    u32 pat = 0xB0000000 | ((u32)bank << 16) | k;
    VRAMCNT(bank) = 0x80;
    R32(lcdc_base[bank] + 0x100) = pat;
    VRAMCNT(bank) = (u8)cnt;
    u32 got = R32(addr + 0x100);
    VRAMCNT(bank) = 0;
    return got == pat;
}

int main(void)
{
    con_init();
    IPCFIFOCNT = FIFO_ENABLE | FIFO_ERROR | FIFO_SEND_CLEAR;
    res_begin("SYS TEST", 32);
    int a7 = a7_wait_ready();
    con_puts(BOTTOM, 0, 0, a7 ? PAL_GREEN : PAL_RED, a7 ? "ARM7 READY" : "ARM7 NOT READY");

    /* ---- divider (GBATEK "DS Maths") */
    div_run(0, 1000, 0, 7, 0);
    res_check(0, "DIV32Q", DIV_RES_L, 142);
    div_run(0, (u32)-1000, 0, 7, 0);
    res_check(1, "DIV32R", DIV_REM_L, (u32)-6);
    div_run(1, 0x56789ABC, 0x1234, 0x1000, 0);
    res_check(2, "DIV64/32", DIV_RES_L, 0x23456789);
    div_run(2, 0xA9876550, 0xFFFFEDCB, 0x10, 0);       /* -0x123456789AB0 / 16 */
    res_check(3, "DIV64S", DIV_RES_L, 0xBA987655);
    div_run(0, 5, 0, 0, 0);                            /* divide by zero */
    u32 d0lo = DIV_RES_L, d0hi = DIV_RES_H, d0rem = DIV_REM_L, d0cnt = DIVCNT;
    res_check(4, "DIV0QLO", d0lo, 0xFFFFFFFF);         /* -1 for positive numer */
    res_check(5, "DIV0QHI", d0hi, 0);                  /* 32-bit mode: upper word not sign-extended */
    res_check(6, "DIV0REMF", d0rem | ((d0cnt & 0x4000) << 16), 0x40000005);

    SQRTCNT = 0; SQRT_PARAM_L = 1000000; SQRT_PARAM_H = 0;
    while (SQRTCNT & 0x8000) ;
    res_check(7, "SQRT32", SQRT_RESULT, 1000);
    SQRTCNT = 1; SQRT_PARAM_L = 0x00000001; SQRT_PARAM_H = 0xFFFFFFFE;
    while (SQRTCNT & 0x8000) ;
    res_check(8, "SQRT64", SQRT_RESULT, 0xFFFFFFFF);

    /* ---- DMA3 immediate: 32-bit copy, 16-bit copy, fill from DMA3FILL */
    for (int i = 0; i < 64; i++) { dma_src[i] = 0x9E3779B9u * (u32)(i + 1); dma_dst[i] = 0; }
    dma3(dma_src, dma_dst, DMA_32BIT | 64);
    res_check(9, "DMA32", sum32(dma_dst, 64), sum32(dma_src, 64));
    for (int i = 0; i < 64; i++) dma_dst[i] = 0;
    dma3(dma_src, dma_dst, 63);                        /* 63 halfwords */
    u32 s16 = 0, e16 = 0;
    for (int i = 0; i < 64; i++) {
        s16 += ((volatile u16 *)dma_dst)[i];
        e16 += i < 63 ? ((u16 *)dma_src)[i] : 0;
    }
    res_check(10, "DMA16", s16, e16);
    DMA_FILL(3) = 0xA5A55A5A;
    dma3(&DMA_FILL(3), dma_dst, DMA_32BIT | DMA_SRC_FIX | 64);
    res_check(11, "DMAFILL", sum32(dma_dst, 64), 0xA5A55A5Au * 64);

    /* ---- timers: cascade, stop, prescaler ratio */
    u32 tf = 0;
    TM_CNT_L(1) = 0; TM_CNT_H(1) = TM_ENABLE | TM_CASCADE;
    TM_CNT_L(0) = 0xFF00; TM_CNT_H(0) = TM_ENABLE;     /* overflow every 256 cycles */
    if (spin_until_tm(1, 50)) tf |= 1;
    TM_CNT_H(0) = 0;
    u32 a = TM_CNT_L(1);
    for (volatile int i = 0; i < 2000; i++) ;
    if (TM_CNT_L(1) == a) tf |= 2;
    TM_CNT_H(1) = 0;
    TM_CNT_L(2) = 0; TM_CNT_L(3) = 0;
    TM_CNT_H(2) = TM_ENABLE | 1;                       /* F/64 */
    TM_CNT_H(3) = TM_ENABLE | 3;                       /* F/1024 */
    spin_until_tm(3, 100);
    u32 t2 = TM_CNT_L(2), t3 = TM_CNT_L(3);
    TM_CNT_H(2) = 0; TM_CNT_H(3) = 0;
    if (t2 >= 15 * t3 && t2 <= 17 * t3 && t3 >= 100) tf |= 4;
    res_check(12, "TIMERS", tf, 7);

    /* ---- IPCSYNC handshake: we output 5, the ARM7 answers 10 */
    IPCSYNC = 5 << 8;
    a7_cmd(CMD_SYNC);
    WAIT_UNTIL((IPCSYNC & 0xF) == 0xA, 10);
    res_check(13, "IPCSYNC", ((IPCSYNC & 0xF) << 4) | MB->val[0], 0xA5);

    /* ---- IPC FIFO flags (GBATEK "DS Inter Process Communication") */
    res_check(14, "FIFOEMPT", IPCFIFOCNT & 0xC303, 0x8101);
    u32 wsum = 0;
    for (u32 i = 0; i < 16; i++) { IPCFIFOSEND = 0x1000 * i + 0x11; wsum += 0x1000 * i + 0x11; }
    u32 c1 = IPCFIFOCNT & 0xC303;
    IPCFIFOSEND = 0xDEADDEAD;                          /* 17th word: full -> error, dropped */
    u32 c2 = IPCFIFOCNT & 0xC303;
    IPCFIFOCNT = FIFO_ENABLE | FIFO_ERROR;
    res_check(15, "FIFOFULL", (c1 << 16) | c2, 0x8102C102);
    a7_cmd(CMD_FIFO_RX);
    res_check(16, "FIFO9TO7", MB->val[0], wsum);
    res_check(17, "FIFO7FLG", (MB->val[1] << 16) | MB->val[2], 0x82018101);
    a7_cmd(CMD_FIFO_TX);
    u32 c3 = IPCFIFOCNT & 0xC303, rsum = 0, esum = 0;
    for (u32 i = 0; i < 16; i++) { rsum += IPCFIFORECV; esum += 0xC0DE0000 + i * 0x111; }
    (void)IPCFIFORECV;                                 /* read when empty -> error */
    u32 c4 = IPCFIFOCNT & 0xC303;
    IPCFIFOCNT = FIFO_ENABLE | FIFO_ERROR;
    res_check(18, "FIFO7TO9", rsum, esum);
    res_check(19, "FIFO9FLG", (c3 << 16) | c4, 0x8201C101);

    /* ---- ARM9 BIOS SWIs */
    res_check(20, "SWI9DIV", (u32)swi_div(-1234, 10, 0, 0), (u32)-123);
    res_check(21, "SWI9SQRT", swi_sqrt(1000000), 1000);
    u32 want_cp = swi_copies(0), want_lz = swi_lz(0);
    res_check(22, "SWI9CPYS", swi_copies(1), want_cp);
    res_check(23, "SWI9LZ77", swi_lz(1), want_lz);

    /* ---- ARM7 BIOS SWIs */
    a7_cmd(CMD_SWI);
    res_check(24, "SWI7DIV", MB->val[0], (u32)-123);
    res_check(25, "SWI7SQRT", MB->val[1], 1000);
    res_check(26, "SWI7CPYS", MB->val[2], hash_bytes((const u8 *)&want_cp, 4, want_lz));
    res_check(27, "SWI7CRC", MB->val[3], crc16_sw(0xFFFF, (const u8 *)swi_src, 64));

    /* ---- WRAMCNT (GBATEK "DS Memory Control - WRAM"). The ARM7 runs from
       ARM7 WRAM while we move the shared blocks. Shared block offsets 0 and
       0x4000 may hold ARM7 code (ARM7 image at 0x037F8000): saved and put
       back before handing everything back (WRAMCNT = 3). */
    const u32 P0 = 0xA0A0A0A0, P1 = 0xB1B1B1B1;
    a7_cmd(CMD_WRAM);
    WRAMCNT = 0;                                       /* all 32K to the ARM9 */
    u32 s0 = R32(0x03000000), s1 = R32(0x03004000);
    R32(0x03000000) = P0;
    R32(0x03004000) = P1;
    WRAMCNT = 1;                                       /* ARM9: 2nd half, ARM7: 1st half */
    u32 w91 = R32(0x03000000), w71 = a7_read(0x03000000);
    WRAMCNT = 2;                                       /* ARM9: 1st half, ARM7: 2nd half */
    u32 w92 = R32(0x03000000), w72 = a7_read(0x03000000);
    WRAMCNT = 3;                                       /* all to the ARM7 */
    u32 w73a = a7_read(0x03000000), w73b = a7_read(0x03004000);
    WRAMCNT = 0;                                       /* ARM7 0x03000000 = ARM7 WRAM mirror */
    u32 w70 = a7_read(0x03000000), w70ref = a7_read(0x03800000);
    R32(0x03000000) = s0;
    R32(0x03004000) = s1;
    WRAMCNT = 3;
    MB->subaddr = 0; MB->sub = 0;                      /* leave the loop */
    WAIT_UNTIL(MB->ack == 0x5E, 60);
    res_check(28, "WRAMSPLT", (w91 & 0xFF) << 24 | (w71 & 0xFF) << 16 | (w92 & 0xFF) << 8 | (w72 & 0xFF),
              0xB1A0A0B1);
    res_check(29, "WRAM7", (u32)(w70 == w70ref) << 16 | (w73a & 0xFF) << 8 | (w73b & 0xFF), 0x1A0B1);

    /* ---- VRAM banks: write through LCDC, read through the mapped address */
    u32 vm = 0;
    vm |= vram_map(BB, 0x82, 0x06400000, 0) << 0;      /* B -> OBJ A */
    vm |= vram_map(BB, 0x89, 0x06020000, 1) << 1;      /* B -> BG A, offset 1 */
    vm |= vram_map(BD, 0x84, 0x06600000, 2) << 2;      /* D -> OBJ B */
    vm |= vram_map(BE, 0x82, 0x06400000, 3) << 3;      /* E -> OBJ A */
    vm |= vram_map(BF, 0x82, 0x06400000, 4) << 4;      /* F -> OBJ A */
    vm |= vram_map(BF, 0x8A, 0x06404000, 5) << 5;      /* F -> OBJ A, offset 1 */
    vm |= vram_map(BG, 0x9A, 0x06414000, 6) << 6;      /* G -> OBJ A, offset 3 */
    VRAMCNT(BC) = 0x80;                                /* C off the BG B slot for H */
    vm |= vram_map(BH, 0x81, 0x06200000, 7) << 7;      /* H -> BG B */
    vm |= vram_map(BI, 0x82, 0x06600000, 8) << 8;      /* I -> OBJ B */
    /* C and D to the ARM7 (0x06000000 / 0x06020000), VRAMSTAT = 3 */
    R32(lcdc_base[BC] + 0x1FFF0) = 0xC7C7C7C7;
    VRAMCNT(BD) = 0x80;
    R32(lcdc_base[BD] + 0x1FFF0) = 0xD7D7D7D7;
    VRAMCNT(BC) = 0x82;
    VRAMCNT(BD) = 0x8A;
    a7_cmd(CMD_VRAM);
    vm |= (u32)(MB->val[0] == 0xC7C7C7C7) << 9;
    vm |= (u32)(MB->val[1] == 0xD7D7D7D7) << 10;
    vm |= (MB->val[2] & 0xFF) << 16;
    VRAMCNT(BD) = 0;
    VRAMCNT(BC) = 0x84;
    res_check(30, "VRAMMAP", vm, 0x000307FF);

    /* ---- palette / OAM read-back, KEYINPUT (recorded, not judged) */
    u32 po = 0;
    R32(0x050001F8) = 0x12345678; po |= (R32(0x050001F8) == 0x12345678) << 0;  /* BG pal A */
    R32(0x050003F8) = 0x23456789; po |= (R32(0x050003F8) == 0x23456789) << 1;  /* OBJ pal A */
    R32(0x050005F8) = 0x3456789A; po |= (R32(0x050005F8) == 0x3456789A) << 2;  /* BG pal B */
    R32(0x070003F8) = 0x456789AB; po |= (R32(0x070003F8) == 0x456789AB) << 3;  /* OAM A */
    /* ARM7 WRAM (bit 4): rewritten by the ARM7's DMA after the ARM7 read it,
       read by DMA right after the ARM7 stored it, and code the ARM7 writes
       and runs twice */
    a7_cmd(CMD_DMA);
    u32 e0 = 0, e1 = 0;
    for (u32 i = 0; i < 8; i++) { e0 += 0x11110000 + i; e1 += 0x22220000 + i; }
    u32 e2 = 0;
    for (u32 i = 0; i < 8; i++) e2 += 0x33330000 + i;
    po |= (u32)(MB->val[0] == e0 && MB->val[1] == e1 && MB->val[2] == e2 && MB->val[3] == 0x12) << 4;
    u32 keys = KEYINPUT & 0x3FF;
    res_record(31, "PALOAMKY", keys << 16 | po, po == 0x1F);
    res_finish();

    con_printf(BOTTOM, 0, 1, PAL_WHITE, "KEYINPUT %03X", keys);
    for (;;)
        ;
}
