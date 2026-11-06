/* win.nds, ARM9: window 0 with X1 > X2 (it wraps: inside is x >= X1 or
   x < X2) and window 1 plain, so both WINxH fields and the wrap flag reach
   the picture. BG0 (red) shows only inside WIN0, BG1 (green) only inside
   WIN1, over a blue backdrop. WIN0H wraps in the top half and is plain
   (30..219) from a write early in line 96. The picture is compared with the
   census melonDS. */
#include "../common/con.h"
#include "../common/results.h"
#include "../common/ipc.h"

#define BG0CNT_A2      R16(0x04000008)
#define BG1CNT_A2      R16(0x0400000A)
#define WIN0H_A        R16(0x04000040)
#define WIN1H_A        R16(0x04000042)
#define WIN0V_A        R16(0x04000044)
#define WIN1V_A        R16(0x04000046)
#define WININ_A        R16(0x04000048)
#define WINOUT_A       R16(0x0400004A)
#define VRAMCNT_A      R8(0x04000240)
#define PAL_A          ((volatile u16 *)0x05000000)
#define BG_VRAM        ((volatile u32 *)0x06000000)

int main(void)
{
    con_init();
    IPCFIFOCNT = FIFO_ENABLE | FIFO_ERROR | FIFO_SEND_CLEAR;
    POWCNT1 = 0x820F;
    res_begin("WINDOW X", 1);
    VRAMCNT_A = 0x81;
    for (int i = 0; i < 8; i++) {            /* char base 2 (0x8000), clear of con's map and tiles */
        BG_VRAM[0x2000 + i] = 0x11111111;    /* tile 0: colour 1 */
        BG_VRAM[0x2008 + i] = 0x22222222;    /* tile 1: colour 2 */
    }
    for (int i = 0; i < 512; i++) {          /* maps at 0x800 (BG0: tile 0) and 0x1000 (BG1: tile 1) */
        BG_VRAM[0x200 + i] = 0;
        BG_VRAM[0x400 + i] = 0x00010001;
    }
    BG0CNT_A2 = 1u << 8 | 2u << 2 | 1;       /* priority 1 */
    BG1CNT_A2 = 2u << 8 | 2u << 2;           /* priority 0 */
    PAL_A[0] = 0x7C00;                       /* backdrop blue */
    PAL_A[1] = 0x001F;                       /* red */
    PAL_A[2] = 0x03E0;                       /* green */
    WIN0V_A = (0 << 8) | 192;                /* lines 0..191 */
    WIN1V_A = (40 << 8) | 150;               /* lines 40..149 */
    WIN1H_A = (100 << 8) | 140;              /* x 100..139 */
    WININ_A = 0x0201;                        /* WIN0: BG0, WIN1: BG1 */
    WINOUT_A = 0x0000;                       /* outside: backdrop */
    DISPCNT_A = 0x00016300;                  /* mode 0, BG0+BG1, WIN0+WIN1 */
    res_check(0, "WININ", WININ_A, 0x0201);
    res_finish();
    for (;;) {
        wait_vblank();
        WIN0H_A = (200 << 8) | 56;           /* X1 200 > X2 56: wraps */
        while (VCOUNT != 96) ;
        WIN0H_A = (30 << 8) | 220;           /* plain, x 30..219 */
    }
}
