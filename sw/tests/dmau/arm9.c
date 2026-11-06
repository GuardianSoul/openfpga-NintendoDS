/* dmau.nds, ARM9: DMA3 32-bit units from main RAM to VRAM and palette, as
   the core's one-request units and their read-ahead move them
   (docs/phase2-integration.md "DMA read-ahead"): runs across several
   16-byte quads from different word offsets, a decrementing destination,
   and a run over words the CPU rewrote after a run that read near them. */
#include "../common/con.h"
#include "../common/results.h"
#include "../common/ipc.h"

#define DMA_DST_DEC (1u << 21)
#define VRAM_E      0x06880000u     /* bank E through LCDC */
#define PAL_OBJ_A   0x05000200u     /* OBJ palette A (the console uses the BG palettes) */

static u32 src[80];

static void dma3(const volatile void *s, u32 d, u32 ctl)
{
    DMA_SAD(3) = (u32)s;
    DMA_DAD(3) = d;
    DMA_CNT(3) = ctl | DMA_ENABLE;
    while (DMA_CNT(3) & DMA_ENABLE)
        ;
}

/* order-sensitive: each word weighted by its place */
static u32 wsum(const volatile u32 *p, int n)
{
    u32 s = 0;
    for (int i = 0; i < n; i++)
        s += p[i] * (u32)(2 * i + 1);
    return s;
}

int main(void)
{
    con_init();
    res_begin("DMA UNITS", 4);
    for (int i = 0; i < 80; i++)
        src[i] = 0x9E3779B9u * (u32)(i + 7) ^ (u32)i << 24;
    VRAMCNT(4) = 0x80;                                  /* E -> LCDC */
    volatile u32 *ve = (volatile u32 *)VRAM_E;
    for (int i = 0; i < 80; i++) ve[i] = 0;

    /* 0: 61 words from word 1 to VRAM */
    dma3(&src[1], VRAM_E + 4, DMA_32BIT | 61);
    res_check(0, "DMAVRAM", wsum(ve + 1, 61), wsum(src + 1, 61));

    /* 1: words just past that run, rewritten by the CPU, then moved */
    src[62] ^= 0x5A5A5A5Au; src[63] ^= 0xA5A5A5A5u; src[64] += 0x01020304u;
    dma3(&src[62], VRAM_E + 0x100, DMA_32BIT | 3);
    res_check(1, "DMASTALE", wsum(ve + 0x40, 3), wsum(src + 62, 3));

    /* 2: 64 words from word 2 to OBJ palette A */
    dma3(&src[2], PAL_OBJ_A, DMA_32BIT | 64);
    res_check(2, "DMAPAL", wsum((volatile u32 *)PAL_OBJ_A, 64), wsum(src + 2, 64));

    /* 3: 13 words from word 3 to VRAM, the destination decrementing */
    dma3(&src[3], VRAM_E + 0x200 + 12 * 4, DMA_32BIT | DMA_DST_DEC | 13);
    u32 rs = 0;
    for (int i = 0; i < 13; i++)
        rs += ve[0x80 + 12 - i] * (u32)(2 * i + 1);
    res_check(3, "DMADEC", rs, wsum(src + 3, 13));
    res_finish();
    for (;;)
        ;
}
