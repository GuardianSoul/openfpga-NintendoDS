/* cputime.nds (sw/tests build, no calico): the hwref cputime probe for tb_ds
   (docs/hw-reference.md "cputime"; sw/hwref/cputime/main.c is the calico
   build that ran on the DS). Same 28 rows, same order, results in the
   result block (value = ARM9 cycles per op x 100).

   crt0 leaves the MPU and caches off, so main() sets up calico's MPU layout
   (memtime logged it on the DS): main RAM cached with the write buffer
   (C=1 B=1), I/O and VRAM/palette/OAM uncached, DTCM (here at 0x0B000000)
   and the BIOS. Then the I-cache and D-cache are on, as under calico.
   IRQs are off (crt0). TM0+TM1 cascade at 33.5 MHz; 1 tick = 2 ARM9 cycles.
   Each kernel repeats 64 ops per loop iteration, differential n1/n2, best
   of 5; kernels run from main RAM with the I-cache warm. */
#include "../common/con.h"
#include "../common/results.h"

#define K __attribute__((target("arm"), noinline, aligned(32)))
#define REP64(s) ".rept 64\n" s "\n.endr\n"
#define LOOP(setup, body, ...) \
    __asm__ volatile(setup "1:\n" REP64(body) "subs %0, %0, #1\nbne 1b\n" : "+r"(n) : "r"(p) : __VA_ARGS__); return n;

K static u32 k_nop(u32 n, u32 p)       { LOOP("", "mov r0, r0", "r0", "cc") }
K static u32 k_add_dep(u32 n, u32 p)   { LOOP("mov r0, #0\nmov r1, #1\n", "add r0, r0, r1", "r0", "r1", "cc") }
K static u32 k_add_indep(u32 n, u32 p) { LOOP("mov r1, #1\nmov r2, #2\n", "add r3, r1, r2", "r1", "r2", "r3", "cc") }
K static u32 k_add_shift(u32 n, u32 p) { LOOP("mov r1, #1\nmov r2, #2\nmov r4, #3\n", "add r3, r1, r2, lsl r4", "r1", "r2", "r3", "r4", "cc") }
K static u32 k_b_taken(u32 n, u32 p)   { LOOP("", "b 2f\n2:", "cc") }
K static u32 k_b_not(u32 n, u32 p)
{
    __asm__ volatile("1:\n" REP64("cmp r0, r0\nbne 9f") "subs %0, %0, #1\nbne 1b\n9:\n" : "+r"(n) : "r"(p) : "r0", "cc");
    return n;
}
K static u32 k_mul(u32 n, u32 p)       { LOOP("mov r1, #3\nmov r2, #5\n", "mul r3, r1, r2", "r1", "r2", "r3", "cc") }
K static u32 k_mul_dep(u32 n, u32 p)   { LOOP("mov r0, #3\nmov r1, #5\n", "mul r0, r1, r0", "r0", "r1", "cc") }
K static u32 k_mla(u32 n, u32 p)       { LOOP("mov r1, #3\nmov r2, #5\nmov r4, #7\n", "mla r3, r1, r2, r4", "r1", "r2", "r3", "r4", "cc") }
K static u32 k_smull(u32 n, u32 p)     { LOOP("mov r1, #3\nmov r2, #5\n", "smull r3, r4, r1, r2", "r1", "r2", "r3", "r4", "cc") }
K static u32 k_smulxy(u32 n, u32 p)    { LOOP("mov r1, #3\nmov r2, #5\n", "smulbb r3, r1, r2", "r1", "r2", "r3", "cc") }
K static u32 k_ld_use(u32 n, u32 p)    { LOOP("", "ldr r0, [%1]\nadd r1, r0, #1", "r0", "r1", "cc") }
K static u32 k_ld_nouse(u32 n, u32 p)  { LOOP("", "ldr r0, [%1]\nadd r1, r2, #1", "r0", "r1", "r2", "cc") }
K static u32 k_str(u32 n, u32 p)       { LOOP("mov r0, #0\n", "str r0, [%1]", "r0", "cc", "memory") }
K static u32 k_str_nop4(u32 n, u32 p)  { LOOP("mov r0, #0\n", "str r0, [%1]\nmov r1, r1\nmov r1, r1\nmov r1, r1\nmov r1, r1", "r0", "r1", "cc", "memory") }
K static u32 k_strh(u32 n, u32 p)      { LOOP("mov r0, #0\n", "strh r0, [%1]", "r0", "cc", "memory") }
K static u32 k_ld_line(u32 n, u32 p)
{
    __asm__ volatile("mov r1, %1\n1:\n" REP64("ldr r0, [r1], #32") "subs %0, %0, #1\nbne 1b\n"
                     : "+r"(n) : "r"(p) : "r0", "r1", "cc", "memory");
    return n;
}
K static u32 k_ld_w0w7(u32 n, u32 p)
{
    __asm__ volatile("mov r1, %1\n1:\n" REP64("ldr r0, [r1]\nldr r2, [r1, #28]\nadd r1, r1, #32")
                     "subs %0, %0, #1\nbne 1b\n" : "+r"(n) : "r"(p) : "r0", "r1", "r2", "cc", "memory");
    return n;
}
K static u32 k_ld_w7w0(u32 n, u32 p)
{
    __asm__ volatile("mov r1, %1\n1:\n" REP64("ldr r0, [r1, #28]\nldr r2, [r1]\nadd r1, r1, #32")
                     "subs %0, %0, #1\nbne 1b\n" : "+r"(n) : "r"(p) : "r0", "r1", "r2", "cc", "memory");
    return n;
}
__attribute__((target("thumb"), noinline, aligned(32))) static u32 k_thumb_add(u32 n, u32 p)
{
    __asm__ volatile(".syntax unified\nmovs r0, #0\nmovs r1, #1\n1:\n" REP64("adds r0, r0, r1") "subs %0, %0, #1\nbne 1b\n"
                     : "+l"(n) : "l"(p) : "r0", "r1", "cc");
    return n;
}
__attribute__((target("thumb"), noinline, aligned(32))) static u32 k_thumb_b(u32 n, u32 p)
{
    __asm__ volatile(".syntax unified\n1:\n" REP64("b 2f\n2:") "subs %0, %0, #1\nbne 1b\n" : "+l"(n) : "l"(p) : "cc");
    return n;
}

typedef u32 (*Kern)(u32 n, u32 p);

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

static u8 s_main[0x24000] __attribute__((aligned(32)));
static u8 s_other[0x4000] __attribute__((aligned(32)));
#define DTCM_DATA 0x0B001000u   /* DTCM (crt0: 0x0B000000, 16 KiB; stacks at the top) */

/* D-cache clean+invalidate by set/way: 4 KiB, 4 ways, 32-byte lines */
static void dc_flush_all(void)
{
    for (u32 way = 0; way < 4; way++)
        for (u32 i = 0; i < 32; i++)
            __asm__ volatile("mcr p15, 0, %0, c7, c14, 2" :: "r"((way << 30) | (i << 5)));
    __asm__ volatile("mcr p15, 0, %0, c7, c10, 4" :: "r"(0));
}

static void mpu_like_calico(void)
{
    /* regions: base | (log2(size) - 1) << 1 | enable */
    static const u32 reg[8] = {
        0x04000033,   /* 0: I/O, VRAM, palette, OAM: 64 MiB, uncached */
        0x0200002B,   /* 1: main RAM 4 MiB: cached, write buffer */
        0x0B00001B,   /* 2: DTCM area 16 KiB */
        0xFFFF001D,   /* 3: BIOS 32 KiB (high vectors), I-cached */
        0x00000031,   /* 4: ITCM mirror, 0..32 MiB */
        0, 0, 0,
    };
    __asm__ volatile("mcr p15, 0, %0, c6, c0, 0" :: "r"(reg[0]));
    __asm__ volatile("mcr p15, 0, %0, c6, c1, 0" :: "r"(reg[1]));
    __asm__ volatile("mcr p15, 0, %0, c6, c2, 0" :: "r"(reg[2]));
    __asm__ volatile("mcr p15, 0, %0, c6, c3, 0" :: "r"(reg[3]));
    __asm__ volatile("mcr p15, 0, %0, c6, c4, 0" :: "r"(reg[4]));
    __asm__ volatile("mcr p15, 0, %0, c6, c5, 0" :: "r"(reg[5]));
    __asm__ volatile("mcr p15, 0, %0, c6, c6, 0" :: "r"(reg[6]));
    __asm__ volatile("mcr p15, 0, %0, c6, c7, 0" :: "r"(reg[7]));
    __asm__ volatile("mcr p15, 0, %0, c2, c0, 0" :: "r"(0x02));        /* D-cacheable: region 1 */
    __asm__ volatile("mcr p15, 0, %0, c2, c0, 1" :: "r"(0x0A));        /* I-cacheable: regions 1, 3 */
    __asm__ volatile("mcr p15, 0, %0, c3, c0, 0" :: "r"(0x02));        /* write buffer: region 1 */
    __asm__ volatile("mcr p15, 0, %0, c5, c0, 2" :: "r"(0x00036333));  /* data: rw rw rw ro rw */
    __asm__ volatile("mcr p15, 0, %0, c5, c0, 3" :: "r"(0x00036330));  /* code: none, rw, rw, ro, rw */
    __asm__ volatile("mcr p15, 0, %0, c7, c5, 0" :: "r"(0));           /* invalidate I-cache */
    __asm__ volatile("mcr p15, 0, %0, c7, c6, 0" :: "r"(0));           /* invalidate D-cache */
    u32 c;
    __asm__ volatile("mrc p15, 0, %0, c1, c0, 0" : "=r"(c));
    c |= (1u << 0) | (1u << 2) | (1u << 12) | (1u << 14);              /* MPU, D-cache, I-cache, round-robin */
    __asm__ volatile("mcr p15, 0, %0, c1, c0, 0" :: "r"(c));
}

enum { PREP_NONE, PREP_CLEAN, PREP_DIRTY };

static void prep(int kind)
{
    dc_flush_all();
    if (kind == PREP_CLEAN) for (u32 i = 0; i < 0x2000; i += 32) (void)*(volatile u32 *)(s_other + i);
    if (kind == PREP_DIRTY) for (u32 i = 0; i < 0x2000; i += 32) *(volatile u32 *)(s_other + i) = i;
}

static u32 run(Kern k, u32 n, u32 p, int pk)
{
    u32 best = ~0u;
    for (int r = 0; r < 6; r++) {
        prep(pk);
        k(1, p);   /* warms the kernel's I-cache lines */
        if (pk != PREP_NONE) prep(pk);
        u32 t0 = now32();
        k(n, p);
        u32 t = now32() - t0;
        if (r && t < best) best = t;
    }
    return best;
}

enum { AT_DTCM, AT_MAIN, AT_VRAM, AT_MAIN_LINES };
typedef struct { const char *name; Kern k; int where; int prep; u32 n1, n2; } Row;

int main(void)
{
    con_init();
    mpu_like_calico();
    TM0C = 0; TM1C = 0; TM0D = 0; TM1D = 0;
    TM1C = (1 << 7) | (1 << 2);   /* enable, cascade */
    TM0C = (1 << 7);              /* enable, F/1 */
    R8(0x04000241) = 0x80;        /* VRAM B: LCDC */
    static const Row rows[] = {
        { "NOP",      k_nop,        AT_DTCM, PREP_NONE, 16, 64 },
        { "ADDDEP",   k_add_dep,    AT_DTCM, PREP_NONE, 16, 64 },
        { "ADDINDEP", k_add_indep,  AT_DTCM, PREP_NONE, 16, 64 },
        { "ADDSHIFT", k_add_shift,  AT_DTCM, PREP_NONE, 16, 64 },
        { "BTAKEN",   k_b_taken,    AT_DTCM, PREP_NONE, 16, 64 },
        { "BNOT",     k_b_not,      AT_DTCM, PREP_NONE, 16, 64 },
        { "MUL",      k_mul,        AT_DTCM, PREP_NONE, 16, 64 },
        { "MULDEP",   k_mul_dep,    AT_DTCM, PREP_NONE, 16, 64 },
        { "MLA",      k_mla,        AT_DTCM, PREP_NONE, 16, 64 },
        { "SMULL",    k_smull,      AT_DTCM, PREP_NONE, 16, 64 },
        { "SMULBB",   k_smulxy,     AT_DTCM, PREP_NONE, 16, 64 },
        { "THADD",    k_thumb_add,  AT_DTCM, PREP_NONE, 16, 64 },
        { "THB",      k_thumb_b,    AT_DTCM, PREP_NONE, 16, 64 },
        { "LDUSEDT",  k_ld_use,     AT_DTCM, PREP_NONE, 16, 64 },
        { "LDNUSEDT", k_ld_nouse,   AT_DTCM, PREP_NONE, 16, 64 },
        { "LDUSEMN",  k_ld_use,     AT_MAIN, PREP_NONE, 16, 64 },
        { "STRVRAM",  k_str,        AT_VRAM, PREP_NONE, 16, 64 },
        { "STRVNOP4", k_str_nop4,   AT_VRAM, PREP_NONE, 16, 64 },
        { "STRHVRAM", k_strh,       AT_VRAM, PREP_NONE, 16, 64 },
        { "STRMAIN",  k_str,        AT_MAIN, PREP_NONE, 16, 64 },
        { "MISSCLN",  k_ld_line,    AT_MAIN_LINES, PREP_CLEAN, 8, 32 },
        { "MISSDRTY", k_ld_line,    AT_MAIN_LINES, PREP_DIRTY, 8, 32 },
        { "FILLW0",   k_ld_line,    AT_MAIN_LINES, PREP_CLEAN, 8, 32 },
        { "FILLW3",   k_ld_line,    AT_MAIN_LINES + 3, PREP_CLEAN, 8, 32 },
        { "FILLW4",   k_ld_line,    AT_MAIN_LINES + 4, PREP_CLEAN, 8, 32 },
        { "FILLW7",   k_ld_line,    AT_MAIN_LINES + 7, PREP_CLEAN, 8, 32 },
        { "FILLW0W7", k_ld_w0w7,    AT_MAIN_LINES, PREP_CLEAN, 8, 32 },
        { "FILLW7W0", k_ld_w7w0,    AT_MAIN_LINES, PREP_CLEAN, 8, 32 },
    };
    const int nrows = sizeof rows / sizeof rows[0];
    res_begin("CPUTIME", nrows);
    for (int i = 0; i < nrows; i++) {
        const Row *r = &rows[i];
        u32 p = r->where == AT_DTCM ? DTCM_DATA : r->where == AT_VRAM ? 0x06820000u
              : r->where == AT_MAIN ? (u32)s_main : (u32)s_main + 0x1000 + 4 * (u32)(r->where - AT_MAIN_LINES);
        u32 t1 = run(r->k, r->n1, p, r->prep), t2 = run(r->k, r->n2, p, r->prep);
        u32 c = (t2 - t1) * 200 / ((r->n2 - r->n1) * 64);   /* ARM9 cycles x 100 */
        res_record(i, r->name, c, 1);
    }
    res_finish();
    for (;;)
        ;
}
