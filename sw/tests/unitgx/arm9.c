/* unitgx.nds (sw/tests build, no calico): geometry-engine cost per command
   body, the bodies of hwref gxtime (docs/hw-reference.md "gxtime"; DS values
   in run 8, gxtime_summary.csv) for the core's scorecard
   (docs/unit-scorecard.md). Values: system cycles per body x 100.
   v3: n bodies, packed four commands a header, go to GXFIFO by DMA3
   (immediate, destination fixed); D(n) = from the DMA start to its end.
   n is 1,200 and 2,400 FIFO entries' worth, far past the FIFO (256) and the
   core's geometry store (511 entries), so the DMA is held back at the
   engine's own pace; per body = (D(n2) - D(n1)) / (n2 - n1), and the entries
   still queued at the DMA's end cancel. After each run END + SWAP (one frame)
   empties the polygon list. The ARM7 is halted (arm7.c).
   v1 (a BOX_TEST prefix with CPU writes) and v2 (bodies behind a SWAP, timed
   to GXSTAT idle, as gxtime) measured the core's CPU-visible timing model
   (GX_CHEAP) instead of its engine: its GXSTAT busy follows the model, and
   the engine shows only when the store fills (geometry-engine.md). */
#include "../common/con.h"
#include "../common/results.h"

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
#define GXSTAT R32(0x04000600)
#define BUSY (1u << 27)
#define LEVEL(s) (((s) >> 16) & 0x1FF)

#define E 0xFFFFFFFFu
#define XY(x, y) (((u32)(x) & 0xFFFF) | ((u32)(y) << 16))
#define P10(x, y, z) (((u32)(x) & 0x3FF) | (((u32)(y) & 0x3FF) << 10) | (((u32)(z) & 0x3FF) << 20))
#define ID44 0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0, 0x1000
#define ID43 0x1000, 0, 0, 0, 0x1000, 0, 0, 0, 0x1000, 0, 0, 0
#define ID33 0x1000, 0, 0, 0, 0x1000, 0, 0, 0, 0x1000
#define Q 0x400
#define V16(x, y, z) 0x23, XY(x, y), (u32)(z)
#define TRI V16(0, 0, 0), V16(Q, 0, 0), V16(0, Q, 0)
#define NRM 0x21, P10(0, 0, -511)
#define L(...) (const u32[]){ __VA_ARGS__, E }
#define NONE ((const u32 *)0)

static u32 nparams(u32 c)
{
    switch (c) {
    case 0x16: case 0x18: return 16;
    case 0x17: case 0x19: return 12;
    case 0x1A: return 9;
    case 0x1B: case 0x1C: case 0x70: return 3;
    case 0x23: case 0x71: return 2;
    case 0x11: case 0x15: case 0x41: return 0;
    default: return 1;
    }
}
/* a list: command, its parameters, ...; returns the FIFO entries */
static u32 entries(const u32 *l)
{
    u32 n = 0;
    for (; *l != E; l += 1 + nparams(*l)) n += nparams(*l) ? nparams(*l) : 1;
    return n;
}
static void put(const u32 *l)
{
    for (; *l != E; l += 1 + nparams(*l)) {
        volatile u32 *port = (volatile u32 *)(0x04000400 + 4 * *l);
        u32 np = nparams(*l);
        if (!np) *port = 0;
        for (u32 i = 0; i < np; i++) *port = l[1 + i];
    }
}

static u32 s_timeouts;
static int idle(void)
{
    for (u32 i = 0; i < 4000000; i++) if (!(GXSTAT & BUSY) && LEVEL(GXSTAT) == 0) return 1;
    s_timeouts++;
    return 0;
}

/* gxtime's reset state (S0) */
static const u32 S0[] = {
    0x41, 0x10, 0, 0x15, 0x10, 3, 0x15, 0x10, 2, 0x15,
    0x60, 0 | (0 << 8) | (255 << 16) | (191u << 24),
    0x29, 0x001F00C0, 0x2A, 0, 0x2B, 0, 0x20, 0x7FFF,
    0x30, 0x7FFF | (0x2108u << 16), 0x31, 0,
    0x32, P10(0, 0, -511) | (0u << 30), 0x32, P10(0, -511, 0) | (1u << 30),
    0x32, P10(-511, 0, 0) | (2u << 30), 0x32, P10(300, 300, -300) | (3u << 30),
    0x33, 0x7FFF | (0u << 30), 0x33, 0x001F | (1u << 30),
    0x33, 0x03E0 | (2u << 30), 0x33, 0x7C00 | (3u << 30),
    E,
};

typedef struct { const char *name; const u32 *setup, *prefix, *body; } T;

/* a command list packed for GXFIFO: four commands a header, then their
   parameters (unused header bytes NOP) */
static u32 s_stream[3200] __attribute__((aligned(32)));
static u32 pack(const u32 *body, u32 n)
{
    u32 w = 0, hdr = 0, k = 0, par[64], np = 0;
    for (u32 b = 0; b < n; b++)
        for (const u32 *l = body; *l != E; l += 1 + nparams(*l)) {
            if (k == 0) { hdr = w++; s_stream[hdr] = 0; }
            s_stream[hdr] |= *l << (8 * k);
            for (u32 i = 0; i < nparams(*l); i++) par[np++] = l[1 + i];
            if (++k == 4) {
                for (u32 i = 0; i < np; i++) s_stream[w++] = par[i];
                k = 0;
                np = 0;
            }
        }
    for (u32 i = 0; i < np; i++) s_stream[w++] = par[i];
    return w;
}

static u32 run(const T *t, u32 n, int *ok)
{
    u32 words = pack(t->body, n);
    __asm__ volatile("" ::: "memory");
    if (!idle()) { *ok = 0; return 0; }
    put(S0);
    if (t->setup) put(t->setup);
    if (t->prefix) put(t->prefix);
    R32(0x040000D4) = (u32)s_stream;
    R32(0x040000D8) = 0x04000400;
    u32 t0 = now32();
    R32(0x040000DC) = words | (1u << 26) | (2u << 21) | (1u << 31);   /* 32-bit, destination fixed, immediate */
    u32 i = 0;
    while ((R32(0x040000DC) & (1u << 31)) && ++i < 20000000) {}
    u32 d = now32() - t0;
    if (i >= 20000000) { s_timeouts++; *ok = 0; }
    put((const u32[]){ 0x41, 0x50, 0, E });   /* END, SWAP_BUFFERS: the polygon list empties at VBlank */
    if (!idle()) *ok = 0;
    return d;
}

int main(void)
{
    con_init();
    TM0C = 0; TM1C = 0; TM0D = 0; TM1D = 0;
    TM1C = (1 << 7) | (1 << 2);
    TM0C = (1 << 7);
    POWCNT1 = 0x820F;
    R16(0x04000060) = 0;   /* DISP3DCNT */
    const T tests[] = {   /* compound literals: on the (DTCM) stack */
        /* DS run 8 (system cycles x 100 per body) in the comment */
        { "MULT44M2", NONE, NONE, L(0x18, ID44) },                    /* 6475 */
        { "LOAD44",   NONE, NONE, L(0x16, ID44) },                    /* 3425 */
        { "TRIV16",   NONE, L(0x40, 0), L(TRI) },                     /* 2770 */
        { "TRIOFF",   NONE, L(0x40, 0), L(V16(0x2000, 0, 0), V16(0x2400, 0, 0), V16(0x2000, Q, 0)) },   /* 1980 */
        { "TRIXCLIP", NONE, L(0x40, 0), L(V16(0xE00, 0, 0), V16(0x1400, 0, 0), V16(0xE00, Q, 0)) },     /* 10810 */
        { "TRINRML4", L(0x29, 0x001F00CF), L(0x40, 0), L(NRM, V16(0, 0, 0), NRM, V16(Q, 0, 0), NRM, V16(0, Q, 0)) },   /* 2970 */
        { "NORMALL0", NONE, L(0x40, 0), L(NRM) },                     /* 900 */
        { "NORMALL1", L(0x29, 0x001F00C1), L(0x40, 0), L(NRM) },      /* 900 */
        { "NORMALL4", L(0x29, 0x001F00CF), L(0x40, 0), L(NRM) },      /* 1206 */
        { "TEXCOORD", NONE, NONE, L(0x22, 0) },                       /* 75 */
        { "COLOR",    NONE, NONE, L(0x20, 0x1234) },                  /* 75 */
        { "BEGINEND", NONE, NONE, L(0x40, 0, 0x41) },                 /* 187 */
    };
    const int nt = sizeof tests / sizeof tests[0];
    res_begin("UNITGX", nt + 1);
    for (int i = 0; i < nt; i++) {
        const T *t = &tests[i];
        u32 e = entries(t->body), n1 = 1200 / e, n2 = 2400 / e;
        int ok = 1;
        u32 d1 = run(t, n1, &ok), d2 = run(t, n2, &ok);
        u32 v = ok && d2 > d1 ? ((d2 - d1) * 100 + (n2 - n1) / 2) / (n2 - n1) : 0;
        res_record(i, t->name, v, ok);
        put((const u32[]){ 0x41, E });   /* END: no list stays open */
    }
    res_record(nt, "TIMEOUTS", s_timeouts, !s_timeouts);
    res_finish();
    for (;;)
        ;
}
