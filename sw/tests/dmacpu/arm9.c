/* dmacpu.nds (sw/tests build, no calico): the hwref dmacpu probe's key rows
   for tb_ds (docs/hw-reference.md "dmacpu"; sw/hwref/dmacpu is the calico
   build that ran on the DS in run 22). Does the ARM9 run during an ARM9
   DMA (DMA3, 32-bit, immediate, 0x8000 words)? Values in the result block
   are TM0+TM1 ticks (33.5 MHz) from the DMA start until a timer read after
   a loop of K = 16000 reads (the read is I/O, so it waits for the DMA), or
   1/0 flags for the collision rows. Run 22 on the DS: the loop runs
   alongside from TCM or a warm cache (DMA + loop = DMA alone) and is halted
   with the cache off; uncached collisions wait for the whole DMA.

   main() sets up calico's MPU layout as sw/tests/cputime does. The ITCM
   loop is a position-independent routine copied to ITCM (address 0x1000);
   the measuring code runs from main RAM with the I-cache warm. */
#include "../common/con.h"
#include "../common/results.h"

#define TM0D  R16(0x04000100)
#define TM0C  R16(0x04000102)
#define TM1D  R16(0x04000104)
#define TM1C  R16(0x04000106)
#define DMA3S R32(0x040000D4)
#define DMA3D R32(0x040000D8)
#define DMA3C R32(0x040000DC)
#define WORDS 0x8000u
#define KLOOP 16000u
#define DTCM_DATA ((const volatile u32 *)0x0B001000u)

static inline u32 now32(void)
{
    u16 h = TM1D, l = TM0D, h2 = TM1D;
    if (h != h2) { l = TM0D; h = h2; }
    return ((u32)h << 16) | l;
}

typedef u32 (*LoopFn)(const volatile u32 *d, u32 k);

/* k reads of d[i & 7], summed: no stores. ARM, position-independent. */
__attribute__((target("arm"), naked, noinline, aligned(32))) static u32 loop_main(const volatile u32 *d, u32 k)
{
    __asm__ volatile(
        "mov r2, #0\n"
        "1: and r3, r1, #7\n"
        "ldr r3, [r0, r3, lsl #2]\n"
        "add r2, r2, r3\n"
        "subs r1, r1, #1\n"
        "bne 1b\n"
        "mov r0, r2\n"
        "bx lr\n");
}
#define LOOP_WORDS 8
#define ITCM_LOOP ((LoopFn)0x00001000u)

static u32 s_a[WORDS] __attribute__((aligned(32)));
static u32 s_b[WORDS] __attribute__((aligned(32)));
static u32 s_mdata[8] __attribute__((aligned(32)));

static void dc_flush_all(void)
{
    for (u32 way = 0; way < 4; way++)
        for (u32 i = 0; i < 32; i++)
            __asm__ volatile("mcr p15, 0, %0, c7, c14, 2" :: "r"((way << 30) | (i << 5)));
    __asm__ volatile("mcr p15, 0, %0, c7, c10, 4" :: "r"(0));
}
static inline u32 cp15_ctrl(void) { u32 v; __asm__ volatile("mrc p15, 0, %0, c1, c0, 0" : "=r"(v)); return v; }
static inline void cp15_set(u32 v) { __asm__ volatile("mcr p15, 0, %0, c1, c0, 0" :: "r"(v)); }

static void mpu_like_calico(void)   /* as sw/tests/cputime */
{
    __asm__ volatile("mcr p15, 0, %0, c6, c0, 0" :: "r"(0x04000033));
    __asm__ volatile("mcr p15, 0, %0, c6, c1, 0" :: "r"(0x0200002B));
    __asm__ volatile("mcr p15, 0, %0, c6, c2, 0" :: "r"(0x0B00001B));
    __asm__ volatile("mcr p15, 0, %0, c6, c3, 0" :: "r"(0xFFFF001D));
    __asm__ volatile("mcr p15, 0, %0, c6, c4, 0" :: "r"(0x00000031));
    __asm__ volatile("mcr p15, 0, %0, c6, c5, 0" :: "r"(0));
    __asm__ volatile("mcr p15, 0, %0, c6, c6, 0" :: "r"(0));
    __asm__ volatile("mcr p15, 0, %0, c6, c7, 0" :: "r"(0));
    __asm__ volatile("mcr p15, 0, %0, c2, c0, 0" :: "r"(0x02));
    __asm__ volatile("mcr p15, 0, %0, c2, c0, 1" :: "r"(0x0A));
    __asm__ volatile("mcr p15, 0, %0, c3, c0, 0" :: "r"(0x02));
    __asm__ volatile("mcr p15, 0, %0, c5, c0, 2" :: "r"(0x00036333));
    __asm__ volatile("mcr p15, 0, %0, c5, c0, 3" :: "r"(0x00036330));
    __asm__ volatile("mcr p15, 0, %0, c7, c5, 0" :: "r"(0));
    __asm__ volatile("mcr p15, 0, %0, c7, c6, 0" :: "r"(0));
    cp15_set(cp15_ctrl() | (1u << 0) | (1u << 2) | (1u << 12) | (1u << 14));
}

/* ticks from the DMA start to a timer read after the loop (words 0: loop
   alone; k 0: DMA alone); clear: CP15 control bits off around it */
static u32 measure(u32 src, u32 dst, u32 words, LoopFn fn, const volatile u32 *d, u32 k, u32 clear)
{
    u32 best = ~0u;
    for (int r = 0; r < 4; r++) {   /* r = 0 warms the caches */
        u32 ctrl = cp15_ctrl();
        if (clear) { if (clear & 4) dc_flush_all(); cp15_set(ctrl & ~clear); }
        DMA3S = src;
        DMA3D = dst;
        u32 t0 = now32();
        if (words) DMA3C = words | (1u << 31) | (1u << 26);
        if (k) (void)fn(d, k);
        u32 t = now32() - t0;
        for (u32 i = 0; (DMA3C & (1u << 31)) && i < 10000000; i++) ;
        if (clear) cp15_set(ctrl);
        if (r && t < best) best = t;
    }
    return best;
}

/* 1 if an uncached load from (store to) the destination right after the DMA
   start waited for the DMA, 0 if it got in before the DMA reached it */
static u32 collide(u32 *src, u32 *dst, int store)
{
    for (u32 i = 0; i < WORDS; i++) { src[i] = 0x55000000u | i; dst[i] = 0xAAAAAAAAu; }
    dc_flush_all();
    u32 ctrl = cp15_ctrl();
    cp15_set(ctrl & ~(1u << 2));
    volatile u32 *d = dst;
    u32 seen = 0;
    DMA3S = (u32)src;
    DMA3D = (u32)dst;
    DMA3C = WORDS | (1u << 31) | (1u << 26);
    if (store) d[0x6000] = 0xC0DE6000u;
    else seen = d[0x6000];
    for (u32 i = 0; (DMA3C & (1u << 31)) && i < 10000000; i++) ;
    cp15_set(ctrl);
    if (store) return d[0x6000] == 0xC0DE6000u;
    return seen == (0x55000000u | 0x6000);
}

int main(void)
{
    con_init();
    mpu_like_calico();
    TM0C = 0; TM1C = 0; TM0D = 0; TM1D = 0;
    TM1C = (1 << 7) | (1 << 2);
    TM0C = (1 << 7);
    R8(0x04000241) = 0x80;   /* VRAM B: LCDC (con_init uses A and C) */
    R8(0x04000243) = 0x80;   /* VRAM D: LCDC */
    const u32 *code = (const u32 *)(void *)loop_main;
    volatile u32 *itcm = (volatile u32 *)0x00001000u;
    for (int i = 0; i < LOOP_WORDS; i++) itcm[i] = code[i];
    __asm__ volatile("mcr p15, 0, %0, c7, c5, 0" :: "r"(0));   /* invalidate I-cache */
    for (int i = 0; i < 8; i++) { s_mdata[i] = i; ((volatile u32 *)DTCM_DATA)[i] = i; }

    const u32 ma = (u32)s_a, mb = (u32)s_b, va = 0x06820000u, vb = 0x06860000u;
    const LoopFn lm = (LoopFn)(void *)loop_main;
    res_begin("DMACPU", 16);
    res_record(0, "DMAMAIN",  measure(ma, mb, WORDS, ITCM_LOOP, DTCM_DATA, 0, 0), 1);
    res_record(1, "ITCMDTCM", measure(ma, mb, WORDS, ITCM_LOOP, DTCM_DATA, KLOOP, 0), 1);
    res_record(2, "LPITCM",   measure(ma, mb, 0, ITCM_LOOP, DTCM_DATA, KLOOP, 0), 1);
    res_record(3, "ITCMDCON", measure(ma, mb, WORDS, ITCM_LOOP, s_mdata, KLOOP, 0), 1);
    res_record(4, "MAINICON", measure(ma, mb, WORDS, lm, DTCM_DATA, KLOOP, 0), 1);
    res_record(5, "LPMAINIC", measure(ma, mb, 0, lm, DTCM_DATA, KLOOP, 0), 1);
    res_record(6, "ITCMDCOF", measure(ma, mb, WORDS, ITCM_LOOP, s_mdata, KLOOP, 1u << 2), 1);
    res_record(7, "LPDCOFF",  measure(ma, mb, 0, ITCM_LOOP, s_mdata, KLOOP, 1u << 2), 1);
    res_record(8, "MAINICOF", measure(ma, mb, WORDS, lm, DTCM_DATA, KLOOP, 1u << 12), 1);
    res_record(9, "LPICOFF",  measure(ma, mb, 0, lm, DTCM_DATA, KLOOP, 1u << 12), 1);
    res_record(10, "DMAVRAM", measure(va, vb, WORDS, ITCM_LOOP, DTCM_DATA, 0, 0), 1);
    res_record(11, "VRAMTCM", measure(va, vb, WORDS, ITCM_LOOP, DTCM_DATA, KLOOP, 0), 1);
    res_record(12, "COLLDMN", collide(s_a, s_b, 0), 1);
    res_record(13, "COLSTMN", collide(s_a, s_b, 1), 1);
    res_record(14, "COLLDVR", collide((u32 *)va, (u32 *)vb, 0), 1);
    res_record(15, "COLSTVR", collide((u32 *)va, (u32 *)vb, 1), 1);
    res_finish();
    for (;;)
        ;
}
