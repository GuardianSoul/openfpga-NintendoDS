/* unitmem.nds (sw/tests build, no calico): ARM9 memory and DMA timing per
   unit, the rows of hwref memtime v2 (docs/hw-reference.md "memtime"; DS
   values in run 35) for the core's scorecard (docs/unit-scorecard.md).
   Values: system cycles (33.5 MHz, TM0 F/1 + TM1 cascade) per access x 100,
   differential over N1/N2 loop iterations, best of 5 after a warm-up.
   MPU as calico (cputime): main RAM C1B1; plus region 5 over an 8 KiB
   main-RAM buffer, C0B0 (uncached), and region 6 over ITCM data at 0x01000000.
   Kernels run from main RAM with the I-cache warm (memtime: from ITCM; a
   warm I-cache issues at the same rate on the DS). IRQs off (crt0). */
#include "../common/con.h"
#include "../common/results.h"

#define K __attribute__((target("arm"), noinline, aligned(32)))
#define TM0D  R16(0x04000100)
#define TM0C  R16(0x04000102)
#define TM1D  R16(0x04000104)
#define TM1C  R16(0x04000106)
static inline u32 now32(void)
{
    u16 h = TM1D, l = TM0D, h2 = TM1D;
    if (h != h2) { l = TM0D; h = h2; }
    return ((u32)h << 16) | l;
}

typedef void (*Kern)(u32 b, u32 it);

/* 64 accesses per iteration at b + 4i (SEQ) or b + 32i (miss, base advancing
   2 KiB an iteration), 16 LDM/STM of 8 words at b + 32i */
#define SEQ64(op) ".set i, 0\n.rept 64\n" op " r0, [r1, #i]\n.set i, i + 4\n.endr\n"
#define L32x64(op) ".set i, 0\n.rept 64\n" op " r0, [r1, #i]\n.set i, i + 32\n.endr\n"
#define BODY(pre, body, post) \
    __asm__ volatile("mov r1, %0\nmov r2, %1\nmov r0, #0\n" pre "1:\n" body post "subs r2, r2, #1\nbne 1b\n" \
                     :: "r"(b), "r"(it) : "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r8", "r9", "r10", "r12", "cc", "memory")
K static void k_ldr(u32 b, u32 it)   { BODY("", SEQ64("ldr"), ""); }
K static void k_str(u32 b, u32 it)   { BODY("", SEQ64("str"), ""); }
K static void k_strh(u32 b, u32 it)  { BODY("", SEQ64("strh"), ""); }
K static void k_ldm(u32 b, u32 it)   { BODY("", "mov r12, r1\n.rept 16\nldmia r12!, {r0, r3-r6, r8-r10}\n.endr\n", ""); }
K static void k_stm(u32 b, u32 it)   { BODY("", "mov r12, r1\n.rept 16\nstmia r12!, {r0, r3-r6, r8-r10}\n.endr\n", ""); }
K static void k_ldr_miss(u32 b, u32 it) { BODY("", L32x64("ldr"), "add r1, r1, #2048\n"); }
K static void k_str_miss(u32 b, u32 it) { BODY("", L32x64("str"), "add r1, r1, #2048\n"); }
K static void k_raw(u32 b, u32 it)   /* STR then LDR of the same word, 32 pairs at stride 32 */
{
    BODY("", ".set i, 0\n.rept 32\nstr r0, [r1, #i]\nldr r3, [r1, #i]\n.set i, i + 32\n.endr\n", "");
}
K static void k_fix(u32 b, u32 it)   { BODY("", ".rept 64\nldr r0, [r1]\n.endr\n", ""); }
K static void k_fixs(u32 b, u32 it)  { BODY("", ".rept 64\nstr r0, [r1]\n.endr\n", ""); }

/* NOP sled: entry at sled + 4 (1024 - n) runs n NOPs */
__attribute__((target("arm"), naked, aligned(32))) static void sled(void)
{
    __asm__ volatile(".rept 1024\nmov r0, r0\n.endr\nbx lr\n");
}

static u8 s_main[0x24000] __attribute__((aligned(32)));
static u8 s_unc[0x2000] __attribute__((aligned(0x2000)));   /* region 5: C0B0 */
#define DTCM_DATA 0x0B001000u
#define ITCM_DATA 0x01004000u   /* ITCM mirror (crt0: ITCM at 0, 32 MiB field) */

static void dc_flush_all(void)
{
    for (u32 way = 0; way < 4; way++)
        for (u32 i = 0; i < 32; i++)
            __asm__ volatile("mcr p15, 0, %0, c7, c14, 2" :: "r"((way << 30) | (i << 5)));
    __asm__ volatile("mcr p15, 0, %0, c7, c10, 4" :: "r"(0));
}
static void ic_inval(void) { __asm__ volatile("mcr p15, 0, %0, c7, c5, 0" :: "r"(0)); }

static void mpu_setup(void)
{
    static const u32 reg[8] = {
        0x04000033,   /* 0: I/O, VRAM, palette, OAM: 64 MiB, uncached */
        0x0200002B,   /* 1: main RAM 4 MiB: cached, write buffer */
        0x0B00001B,   /* 2: DTCM area 16 KiB */
        0xFFFF001D,   /* 3: BIOS 32 KiB, I-cached */
        0x00000031,   /* 4: ITCM mirror, 0..32 MiB */
        0,            /* 5: s_unc, set below */
        0, 0,
    };
    for (int i = 0; i < 8; i++) {
        u32 v = i == 5 ? ((u32)s_unc | (12u << 1) | 1u) : reg[i];
        switch (i) {
        case 0: __asm__ volatile("mcr p15, 0, %0, c6, c0, 0" :: "r"(v)); break;
        case 1: __asm__ volatile("mcr p15, 0, %0, c6, c1, 0" :: "r"(v)); break;
        case 2: __asm__ volatile("mcr p15, 0, %0, c6, c2, 0" :: "r"(v)); break;
        case 3: __asm__ volatile("mcr p15, 0, %0, c6, c3, 0" :: "r"(v)); break;
        case 4: __asm__ volatile("mcr p15, 0, %0, c6, c4, 0" :: "r"(v)); break;
        case 5: __asm__ volatile("mcr p15, 0, %0, c6, c5, 0" :: "r"(v)); break;
        case 6: __asm__ volatile("mcr p15, 0, %0, c6, c6, 0" :: "r"(v)); break;
        case 7: __asm__ volatile("mcr p15, 0, %0, c6, c7, 0" :: "r"(v)); break;
        }
    }
    __asm__ volatile("mcr p15, 0, %0, c2, c0, 0" :: "r"(0x02));        /* D-cacheable: region 1 */
    __asm__ volatile("mcr p15, 0, %0, c2, c0, 1" :: "r"(0x0A));        /* I-cacheable: regions 1, 3 */
    __asm__ volatile("mcr p15, 0, %0, c3, c0, 0" :: "r"(0x02));        /* write buffer: region 1 */
    __asm__ volatile("mcr p15, 0, %0, c5, c0, 2" :: "r"(0x00336333));  /* data: rw rw rw ro rw rw */
    __asm__ volatile("mcr p15, 0, %0, c5, c0, 3" :: "r"(0x00036330));
    ic_inval();
    __asm__ volatile("mcr p15, 0, %0, c7, c6, 0" :: "r"(0));
    u32 c;
    __asm__ volatile("mrc p15, 0, %0, c1, c0, 0" : "=r"(c));
    c |= (1u << 0) | (1u << 2) | (1u << 12) | (1u << 14);
    __asm__ volatile("mcr p15, 0, %0, c1, c0, 0" :: "r"(c));
}

#define REPS 5
static u32 time_k(Kern k, u32 b, u32 it, int flush)
{
    u32 best = ~0u;
    for (int r = 0; r <= REPS; r++) {
        k(b, 1);                    /* the kernel's lines into the I-cache */
        if (flush) dc_flush_all();
        u32 t0 = now32();
        k(b, it);
        u32 t = now32() - t0;
        if (r && t < best) best = t;
    }
    return best;
}
static u32 per_x100(u32 t1, u32 t2, u32 d) { return ((t2 - t1) * 100 + d / 2) / d; }   /* t2 - t1 < 40M */

static u32 sled_time(u32 n, int cold)
{
    void (*f)(void) = (void (*)(void))((u32)sled + 4 * (1024 - n));
    u32 best = ~0u;
    for (int r = 0; r <= REPS; r++) {
        f();
        if (cold) ic_inval();
        u32 t0 = now32();
        f();
        u32 t = now32() - t0;
        if (r && t < best) best = t;
    }
    return best;
}

static int gx_idle(void)
{
    for (u32 i = 0; i < 2000000; i++) {
        u32 st = R32(0x04000600);
        if (!(st & (1u << 27)) && ((st >> 16) & 0x1FF) == 0) return 1;
    }
    return 0;
}

static u32 s_dma_timeouts;
static int s_gxok = 1;
static u32 dma_time(u32 src, u32 dst, u32 cnt, int gx)   /* gx: the engine idle and empty before each run (memtime) */
{
    u32 best = ~0u;
    for (int r = 0; r <= REPS; r++) {
        if (gx && !(s_gxok = s_gxok && gx_idle())) return 0;
        R32(0x040000D4) = src;
        R32(0x040000D8) = dst;
        u32 t0 = now32();
        R32(0x040000DC) = cnt | (1u << 31);
        u32 i = 0;
        while ((R32(0x040000DC) & (1u << 31)) && ++i < 1000000) {}
        u32 t = now32() - t0;
        if (i >= 1000000) s_dma_timeouts++;
        if (r && t < best) best = t;
    }
    return best;
}
typedef struct { const char *name; Kern k; u32 base; int flush; u32 per; } Row;
#define N1 4
#define N2 16

int main(void)
{
    con_init();
    mpu_setup();
    TM0C = 0; TM1C = 0; TM0D = 0; TM1D = 0;
    TM1C = (1 << 7) | (1 << 2);
    TM0C = (1 << 7);
    R8(0x04000241) = 0x80;                       /* VRAM B: LCDC */
    POWCNT1 = POWCNT1 | (1u << 2) | (1u << 3);   /* 3D render + geometry on */
    u32 m = (u32)s_main;
    const Row rows[] = {
        { "LDRDTCM",  k_ldr,      DTCM_DATA, 0, 64 },   /* DS 54 */
        { "LDM8DTCM", k_ldm,      DTCM_DATA, 0, 16 },   /* 416 */
        { "STM8DTCM", k_stm,      DTCM_DATA, 0, 16 },   /* 416 */
        { "LDRITCM",  k_ldr,      ITCM_DATA, 0, 64 },   /* 104 */
        { "LDRHIT",   k_ldr,      m,         0, 64 },   /* 54 */
        { "LDM8HIT",  k_ldm,      m,         0, 16 },   /* 416 */
        { "STRHIT",   k_str,      m,         0, 64 },   /* 103 */
        { "STM8HIT",  k_stm,      m,         0, 16 },   /* 419 */
        { "LDRMISS",  k_ldr_miss, m + 0x1000, 1, 64 },  /* 2300 */
        { "STRMISS",  k_str_miss, m + 0x1000, 1, 64 },  /* 900 */
        { "LDRUNC",   k_ldr,      (u32)s_unc, 0, 64 },  /* 903 */
        { "STRUNC",   k_str,      (u32)s_unc, 0, 64 },  /* 900 */
        { "LDM8UNC",  k_ldm,      (u32)s_unc, 0, 16 },  /* 2313 */
        { "LDRVRAM",  k_ldr,      0x06820000, 0, 64 },  /* 503 */
        { "STRVRAM",  k_str,      0x06820000, 0, 64 },  /* 503 */
        { "STRHVRAM", k_strh,     0x06820000, 0, 64 },  /* 403 */
        { "LDRPAL",   k_ldr,      0x05000000, 0, 64 },  /* 571 */
        { "STRPAL",   k_str,      0x05000000, 0, 64 },  /* 570 */
        { "LDROAM",   k_ldr,      0x07000000, 0, 64 },  /* 403 */
        { "LDRIO",    k_fix,      0x04000004, 0, 64 },  /* 403 (DISPSTAT) */
        { "STRIO",    k_fixs,     0x04000010, 0, 64 },  /* 403 (BG0OFS) */
        { "STRLDR",   k_raw,      m,         0, 32 },   /* 3300 per pair */
    };
    const int nk = sizeof rows / sizeof rows[0];
    res_begin("UNITMEM", nk + 10);
    for (int i = 0; i < nk; i++) {
        const Row *r = &rows[i];
        u32 t1 = time_k(r->k, r->base, N1, r->flush), t2 = time_k(r->k, r->base, N2, r->flush);
        res_record(i, r->name, per_x100(t1, t2, (N2 - N1) * r->per), 1);
    }
    int j = nk;
    /* instruction fetch per NOP: warm (DS 208), cold (288) */
    res_record(j++, "IFWARM", per_x100(sled_time(256, 0), sled_time(1024, 0), 768), 1);
    res_record(j++, "IFCOLD", per_x100(sled_time(256, 1), sled_time(1024, 1), 768), 1);
    /* DMA3 immediate, 32-bit, system cycles per unit */
    for (u32 i = 0; i < 0x4000; i += 4) *(volatile u32 *)(m + 0x10000 + i) = 0x15151515u;   /* MTX_IDENTITY x 4 */
    dc_flush_all();
    u32 src = m + 0x10000, dst = m + 0x18000;
    static const struct { const char *name; u32 s, d, flags, n1, n2; } dm[] = {
        { "DMAMM",   0, 1, 0, 256, 1024 },                       /* main->main 1800 */
        { "DMAMV",   0, 0x06820000, 0, 256, 1024 },              /* main->VRAM 315 */
        { "DMAVM",   0x06820000, 1, 0, 256, 1024 },              /* VRAM->main 408 */
        { "DMAMPAL", 0, 0x05000000, 0, 64, 256 },                /* main->palette 320 */
        { "DMAMIO",  0, 0x04000010, 2u << 21, 256, 1024 },       /* main->I/O fixed 207 */
        { "DMAGXP",  0, 0x04000454, 2u << 21, 32, 128 },         /* main->GX port 208 */
        { "DMAGXF",  0, 0x04000400, 2u << 21, 8, 40 },           /* main->GXFIFO 4 cmds/word 500 */
    };
    for (int k = 0; k < (int)(sizeof dm / sizeof dm[0]); k++) {
        u32 s = dm[k].s ? dm[k].s : src, d = dm[k].d == 1 ? dst : dm[k].d;
        u32 cnt = (1u << 26) | dm[k].flags;
        int gx = d == 0x04000454 || d == 0x04000400;
        u32 t1 = dma_time(s, d, cnt | dm[k].n1, gx);
        u32 t2 = dma_time(s, d, cnt | dm[k].n2, gx);
        if (gx) s_gxok = s_gxok && gx_idle();
        int ok = !s_dma_timeouts && s_gxok;
        res_record(j++, dm[k].name, ok ? per_x100(t1, t2, dm[k].n2 - dm[k].n1) : 0, ok);
    }
    res_record(j++, "TIMEOUTS", s_dma_timeouts + (s_gxok ? 0 : 1000), !s_dma_timeouts && s_gxok);
    res_finish();
    for (;;)
        ;
}
