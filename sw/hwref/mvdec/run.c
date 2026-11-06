/* mvdec: the shared run loop (run.h). ARM state; no library calls. */
#include "run.h"

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;

#define R16(a) (*(volatile u16 *)(a))
#define R32(a) (*(volatile u32 *)(a))
#define VCOUNT R16(0x04000006)

#define BLOB_MAGIC0 0x4344564Du     /* "MVDC" */
#define BLOB_MAGIC1 0x4C4C4143u     /* "CALL" */

/* The blob (little endian), written by tools/hwref/mkmvdec.py */
typedef struct {
    u32 magic[2], version, ncalls, frame0, line0;
    kcp15_t cp15;
    u8 vramcnt[9], pad[3];
    u32 nio;                    /* then nio x {addr, value, bytes}: the display set-up */
} blob_hdr;
typedef struct { u32 func, r0, r1, r2, r3, sp, frame, line, game_ticks, game_cksum, ck_addr, ck_len, nruns; } blob_call;

static inline u32 now32(void)
{
    u16 h = R16(0x04000104), l = R16(0x04000100), h2 = R16(0x04000104);
    if (h != h2) { l = R16(0x04000100); h = h2; }
    return ((u32)h << 16) | l;
}

static void caches_flush(void)
{
    /* clean and invalidate the 4 KiB 4-way D-cache by set/way, drain, invalidate the I-cache */
    for (u32 way = 0; way < 4; way++)
        for (u32 set = 0; set < 32; set++)
            __asm__ volatile("mcr p15, 0, %0, c7, c14, 2" :: "r"((way << 30) | (set << 5)));
    __asm__ volatile("mcr p15, 0, %0, c7, c10, 4\n mcr p15, 0, %0, c7, c5, 0" :: "r"(0) : "memory");
}

void mvdec_cp15_save(kcp15_t *c)
{
    __asm__ volatile("mrc p15, 0, %0, c1, c0, 0\n mrc p15, 0, %1, c9, c1, 0\n mrc p15, 0, %2, c9, c1, 1"
                     : "=r"(c->control), "=r"(c->dtcm), "=r"(c->itcm));
    __asm__ volatile("mrc p15, 0, %0, c2, c0, 1\n mrc p15, 0, %1, c2, c0, 0\n mrc p15, 0, %2, c3, c0, 0\n"
                     "mrc p15, 0, %3, c5, c0, 3\n mrc p15, 0, %4, c5, c0, 2"
                     : "=r"(c->code_c), "=r"(c->data_c), "=r"(c->wbuf), "=r"(c->code_ap), "=r"(c->data_ap));
    __asm__ volatile("mrc p15, 0, %0, c6, c0, 0\n mrc p15, 0, %1, c6, c1, 0\n"
                     "mrc p15, 0, %2, c6, c2, 0\n mrc p15, 0, %3, c6, c3, 0"
                     : "=r"(c->region[0]), "=r"(c->region[1]), "=r"(c->region[2]), "=r"(c->region[3]));
    __asm__ volatile("mrc p15, 0, %0, c6, c4, 0\n mrc p15, 0, %1, c6, c5, 0\n"
                     "mrc p15, 0, %2, c6, c6, 0\n mrc p15, 0, %3, c6, c7, 0"
                     : "=r"(c->region[4]), "=r"(c->region[5]), "=r"(c->region[6]), "=r"(c->region[7]));
}

void mvdec_cp15_load(const kcp15_t *h)
{
    u32 c;
    __asm__ volatile("mrc p15, 0, %0, c1, c0, 0" : "=r"(c));
    caches_flush();
    __asm__ volatile("mcr p15, 0, %0, c1, c0, 0" :: "r"(c & ~0x1005u));   /* MPU, D, I off */
    __asm__ volatile(
        "mcr p15, 0, %0, c6, c0, 0\n mcr p15, 0, %1, c6, c1, 0\n"
        "mcr p15, 0, %2, c6, c2, 0\n mcr p15, 0, %3, c6, c3, 0\n"
        :: "r"(h->region[0]), "r"(h->region[1]), "r"(h->region[2]), "r"(h->region[3]));
    __asm__ volatile(
        "mcr p15, 0, %0, c6, c4, 0\n mcr p15, 0, %1, c6, c5, 0\n"
        "mcr p15, 0, %2, c6, c6, 0\n mcr p15, 0, %3, c6, c7, 0\n"
        :: "r"(h->region[4]), "r"(h->region[5]), "r"(h->region[6]), "r"(h->region[7]));
    __asm__ volatile(
        "mcr p15, 0, %0, c2, c0, 0\n mcr p15, 0, %1, c2, c0, 1\n mcr p15, 0, %2, c3, c0, 0\n"
        "mcr p15, 0, %3, c5, c0, 2\n mcr p15, 0, %4, c5, c0, 3\n"
        :: "r"(h->data_c), "r"(h->code_c), "r"(h->wbuf), "r"(h->data_ap), "r"(h->code_ap));
    __asm__ volatile("mcr p15, 0, %0, c9, c1, 0\n mcr p15, 0, %1, c9, c1, 1" :: "r"(h->dtcm), "r"(h->itcm));
    __asm__ volatile("mcr p15, 0, %0, c7, c5, 0\n mcr p15, 0, %0, c7, c6, 0" :: "r"(0));
    __asm__ volatile("mcr p15, 0, %0, c1, c0, 0" :: "r"(h->control) : "memory");
}

static void copy8(u32 dst, const u8 *src, u32 n)
{
    volatile u8 *d = (volatile u8 *)dst;
    for (u32 i = 0; i < n; i++) d[i] = src[i];
}

static void copy32(u32 dst, const u8 *src, u32 n)
{
    volatile u32 *d = (volatile u32 *)dst;
    const u32 *s = (const u32 *)src;
    for (u32 i = 0; i < n / 4; i++) d[i] = s[i];
}

/* Calls the game function with the game's SP; restores ours. */
__attribute__((naked, target("arm"), noinline))
static u32 call_game(u32 fn, const u32 *regs, u32 sp)   /* regs: r0-r3 */
{
    __asm__ volatile(
        "push {r4-r11, lr}\n"
        "ldr r4, =saved_sp\n"
        "str sp, [r4]\n"
        "mov sp, r2\n"
        "mov r12, r0\n"
        "ldm r1, {r0-r3}\n"
        "blx r12\n"
        "ldr r4, =saved_sp\n"
        "ldr sp, [r4]\n"
        "pop {r4-r11, lr}\n"
        "bx lr\n"
        ".pool\n");
}
u32 saved_sp;
int mvdec_flush_each = 1;

/* the census's sampled checksum (tools/melonds-census, --snap-pcs) */
static u32 cksum(u32 base, u32 len)
{
    u32 h = 0;
    for (u32 i = 0; i < len; i += 64) h = h * 31 + R32(base + i);
    return h;
}

static int run(const u8 *blob, kres_t *res, int max)
{
    const blob_hdr *h = (const blob_hdr *)blob;
    if (h->magic[0] != BLOB_MAGIC0 || h->magic[1] != BLOB_MAGIC1 || h->version != 2) return -1;
    if ((int)h->ncalls > max) return -2;
    const u8 *p = blob + sizeof(blob_hdr);

    for (u32 i = 0; i < h->nio; i++, p += 12)
    {
        u32 a = ((const u32 *)p)[0], v = ((const u32 *)p)[1];
        if (((const u32 *)p)[2] == 4) R32(a) = v;
        else R16(a) = v;
    }
    for (int i = 0; i < 9; i++)     /* A-G, then H and I after WRAMCNT */
        *(volatile u8 *)(0x04000240 + i + (i >= 7)) = h->vramcnt[i];
    mvdec_cp15_load(&h->cp15);
    copy32(0x01FF8000, p, 0x8000);              /* the game's ITCM (base 0, mirrored) */
    p += 0x8000;
    copy32(h->cp15.dtcm & ~0xFFFu, p, 0x4000);      /* the game's DTCM */
    p += 0x4000;

    /* TM0+TM1 from 0 at the start of the first call's line */
    R32(0x04000100) = 0;
    R32(0x04000104) = 0;
    u32 l0 = h->line0;
    while (VCOUNT == l0) ;
    while (VCOUNT != l0) ;
    R32(0x04000104) = 0x00840000;               /* TM1 cascade, on */
    R32(0x04000100) = 0x00800000;               /* TM0 F/1, on */

    for (u32 c = 0; c < h->ncalls; c++)
    {
        const blob_call *bc = (const blob_call *)p;
        p += sizeof(blob_call);
        for (u32 r = 0; r < bc->nruns; r++)
        {
            u32 addr = ((const u32 *)p)[0], n = ((const u32 *)p)[1];
            copy8(addr, p + 8, n);
            p += 8 + ((n + 3) & ~3u);
        }
        if (mvdec_flush_each) caches_flush();
        kres_t *o = &res[c];
        o->func = bc->func;
        o->target = ((bc->frame - h->frame0) * MV_LINES + bc->line - l0) * MV_TICKS_PER_LINE;
        o->game_ticks = bc->game_ticks;
        o->game_cksum = bc->game_cksum;
        while (now32() < o->target) ;
        o->vc0 = VCOUNT;
        o->start = now32();
        call_game(bc->func, &bc->r0, bc->sp);
        o->end = now32();
        o->vc1 = VCOUNT;
        o->cksum = bc->ck_len ? cksum(bc->ck_addr, bc->ck_len) : 0;
    }
    caches_flush();
    return h->ncalls;
}

__attribute__((naked, target("arm"), noinline))
static int on_stack(int (*fn)(const u8 *, kres_t *, int), const u8 *blob, kres_t *res, int max, void *sp_top)
{
    __asm__ volatile(
        "push {r4, lr}\n"
        "ldr r12, [sp, #8]\n"         /* sp_top */
        "mov r4, sp\n"
        "mov sp, r12\n"
        "mov r12, r0\n"
        "mov r0, r1\n"
        "mov r1, r2\n"
        "mov r2, r3\n"
        "blx r12\n"
        "mov sp, r4\n"
        "pop {r4, lr}\n"
        "bx lr\n");
}

/* Runs on the main RAM stack: the caller's DTCM (and its stack) is saved,
   replaced by the game's and put back. */
static kcp15_t caller;
static u8 *save_area;
static int run_saved(const u8 *blob, kres_t *res, int max)
{
    mvdec_cp15_save(&caller);
    u32 dtcm = caller.dtcm & ~0xFFFu;
    copy32((u32)save_area, (const u8 *)0x01FF8000, 0x8000);
    copy32((u32)save_area + 0x8000, (const u8 *)dtcm, 0x4000);
    int n = run(blob, res, max);
    mvdec_cp15_load(&caller);
    copy32(0x01FF8000, save_area, 0x8000);
    copy32(dtcm, save_area + 0x8000, 0x4000);
    __asm__ volatile("mcr p15, 0, %0, c7, c5, 0" :: "r"(0) : "memory");   /* the ITCM code is back */
    return n;
}

int mvdec_run(const u8 *blob, kres_t *res, int max, u8 *save, void *stack_top)
{
    u32 ime = R32(0x04000208);
    R32(0x04000208) = 0;
    save_area = save;
    int n = on_stack(run_saved, blob, res, max, stack_top);
    R32(0x04000208) = ime;
    return n;
}
