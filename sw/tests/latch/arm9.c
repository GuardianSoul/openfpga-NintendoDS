/* latch.nds, ARM9: a BG layer enabled mid-frame shows three lines later on
   the DS (hwref run 22, lat2d; melonDS: two), counted from the line the write
   lands in, up to that line's end (run 23 bgon_fine: 1,530 to 2,139 ticks
   all give line 99), not from HBlank. Every frame BG0 (solid red, left half)
   and BG1 (solid green, right half) are turned off in VBlank; BG0 is turned
   on early in line 96 and BG1 after line 96's HBlank, over a blue backdrop.
   On the DS both first show on line 99. The picture is compared with the
   census melonDS, which carries the DS rule
   (tools/melonds-census/ds-rules-2d.patch). */
#include "../common/con.h"
#include "../common/results.h"
#include "../common/ipc.h"

#define BG0CNT_A2      R16(0x04000008)
#define BG1CNT_A2      R16(0x0400000A)
#define VRAMCNT_A      R8(0x04000240)
#define PAL_A          ((volatile u16 *)0x05000000)
#define BG_VRAM        ((volatile u32 *)0x06000000)

int main(void)
{
    con_init();
    IPCFIFOCNT = FIFO_ENABLE | FIFO_ERROR | FIFO_SEND_CLEAR;
    POWCNT1 = 0x820F;
    res_begin("LAYER LATCH", 1);
    VRAMCNT_A = 0x81;                        /* bank A: engine A BG at 0x06000000 */
    for (int i = 0; i < 8; i++) {            /* char base 2 (0x8000), clear of con's map and tiles */
        BG_VRAM[0x2000 + i] = 0x11111111;    /* tile 0: colour 1 */
        BG_VRAM[0x2008 + i] = 0;             /* tile 1: transparent */
        BG_VRAM[0x2010 + i] = 0x22222222;    /* tile 2: colour 2 */
    }
    for (int i = 0; i < 512; i++) {          /* maps at 0x800 (BG0) and 0x1000 (BG1), two entries a word */
        int right = (i & 15) >= 8;
        BG_VRAM[0x200 + i] = right ? 0x00010001 : 0;
        BG_VRAM[0x400 + i] = right ? 0x00020002 : 0x00010001;
    }
    BG0CNT_A2 = 1u << 8 | 2u << 2;          /* char base 2, map base 1 (0x800), 4bpp */
    BG1CNT_A2 = 2u << 8 | 2u << 2;          /* char base 2, map base 2 (0x1000) */
    PAL_A[0] = 0x7C00;                       /* backdrop blue */
    PAL_A[1] = 0x001F;                       /* red */
    PAL_A[2] = 0x03E0;                       /* green */
    res_check(0, "BG0CNT", BG0CNT_A2, 0x108);
    res_finish();
    for (;;) {
        wait_vblank();
        DISPCNT_A = 0x00010000;              /* mode 0, BG0 and BG1 off */
        while (VCOUNT != 96) ;
        DISPCNT_A = 0x00010100;              /* BG0 on, early in line 96 */
        while (!(DISPSTAT & 2)) ;
        DISPCNT_A = 0x00010300;              /* BG1 on, after line 96's HBlank */
    }
}
