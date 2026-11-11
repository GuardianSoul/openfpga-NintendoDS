/* affdma.nds, ARM9: affine reference points written while the display
   sequencer steps them (Q_POST in nds_disp). Mode 2: BG2's X/Y come from an
   HBlank DMA table (a wave), BG3's X from a CPU loop that writes it all the
   time (VCOUNT-dependent), over a blue backdrop, BG3 above BG2 with half its
   tiles transparent. The CPU loop's writes race the line latch, so a few
   lines differ from melonDS by timing (23 rows); tools/ds-tests/affdma.md5
   is the core's own frame (main 77267d2), a regression check for the
   sequencer/CPU write path (nds_disp_refs' queue). */
#include "../common/con.h"
#include "../common/results.h"
#include "../common/ipc.h"

#define BG2CNT_A   R16(0x0400000C)
#define BG3CNT_A   R16(0x0400000E)
#define BG2PA_A    R16(0x04000020)
#define BG2PB_A    R16(0x04000022)
#define BG2PC_A    R16(0x04000024)
#define BG2PD_A    R16(0x04000026)
#define BG2X_A     R32(0x04000028)
#define BG2Y_A     R32(0x0400002C)
#define BG3PA_A    R16(0x04000030)
#define BG3PB_A    R16(0x04000032)
#define BG3PC_A    R16(0x04000034)
#define BG3PD_A    R16(0x04000036)
#define BG3X_A     R32(0x04000038)
#define BG3Y_A     R32(0x0400003C)
#define VRAMCNT_A  R8(0x04000240)
#define PAL_A      ((volatile u16 *)0x05000000)
#define BG_VRAM    ((volatile u32 *)0x06000000)
#define DMA_HBLANK (2u << 27)
#define DMA_DST_RELOAD (3u << 21)

static u32 tab[193 * 2];

int main(void)
{
    con_init();
    IPCFIFOCNT = FIFO_ENABLE | FIFO_ERROR | FIFO_SEND_CLEAR;
    POWCNT1 = 0x820F;
    res_begin("AFFINE DMA", 1);
    VRAMCNT_A = 0x81;
    /* 8bpp tiles at char base 2 (0x8000): tile k solid colour k (tile 0 transparent) */
    for (int k = 0; k < 16; k++)
        for (int i = 0; i < 16; i++) BG_VRAM[0x2000 + k * 16 + i] = (u32)k * 0x01010101u;
    /* 16x16-tile maps: BG2 at 0x800 (all tiles 1..15), BG3 at 0x1000 (every other tile 0) */
    for (int i = 0; i < 64; i++) {
        u32 w2 = 0, w3 = 0;
        for (int b = 0; b < 4; b++) {
            int n = i * 4 + b, x = n & 15, y = n >> 4;
            w2 |= (u32)(((x + y) % 15) + 1) << (8 * b);
            w3 |= (u32)(((x ^ y) & 1) ? ((x * 3 + y) % 15) + 1 : 0) << (8 * b);
        }
        BG_VRAM[0x200 + i] = w2;
        BG_VRAM[0x400 + i] = w3;
    }
    for (int i = 1; i < 16; i++) PAL_A[i] = (u16)((i * 2) | ((31 - i * 2) << 5) | ((i & 3) << 13));
    PAL_A[0] = 0x7C00;
    BG2CNT_A = 1u << 8 | 2u << 2 | 1u << 13 | 1;    /* map 1, char 2, wrap, 128x128, priority 1 */
    BG3CNT_A = 2u << 8 | 2u << 2 | 1u << 13;         /* map 2, char 2, wrap, priority 0 */
    BG2PA_A = 0x100; BG2PB_A = 0; BG2PC_A = 0; BG2PD_A = 0x100;
    BG3PA_A = 0x0C0; BG3PB_A = 0x010; BG3PC_A = 0x020; BG3PD_A = 0x0E0;
    for (int y = 0; y < 193; y++) {
        int w = (y * 7) & 63; if (w > 31) w = 63 - w;
        tab[2 * y] = (u32)(w * 3) << 8;
        tab[2 * y + 1] = (u32)(y + (w >> 2)) << 8;
    }
    DISPCNT_A = 0x00010C02;                          /* mode 2, BG2 + BG3 */
    res_check(0, "BG2CNT", BG2CNT_A, 0x2109);
    res_finish();
    for (;;) {
        wait_vblank();
        DMA_CNT(0) = 0;
        BG2X_A = tab[0]; BG2Y_A = tab[1];
        DMA_SAD(0) = (u32)&tab[2];
        DMA_DAD(0) = 0x04000028;
        DMA_CNT(0) = DMA_ENABLE | DMA_HBLANK | DMA_REPEAT | DMA_32BIT | DMA_DST_RELOAD | 2;
        while (VCOUNT != 0) ;
        for (;;) {
            /* Use one VCOUNT sample for the condition and the write value. */
            u32 line = VCOUNT;
            if (line >= 191) break;
            BG3X_A = (line * 5) << 8;
        }
    }
}
