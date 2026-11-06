/* plane.nds, ARM9: the 3D layer's rear plane with no polygons (what a
   3D-off core shows: rtl/ds/nds_g3d_plane.sv, docs/compat.md). A 256x256
   bitmap with varying alpha goes into VRAM bank C, mapped as texture slot 2;
   DISP3DCNT bit 14 selects it as the rear plane, CLRIMAGE_OFFSET moves it
   and BG0HOFS scrolls the layer left (transparent at the right edge), over
   a green backdrop. The picture is compared with melonDS's
   (tools/ds-tests/plane.md5). */
#include "../common/con.h"
#include "../common/results.h"
#include "../common/ipc.h"

#define DISP3DCNT      R16(0x04000060)
#define CLEAR_COLOR    R32(0x04000350)
#define CLRIMAGE_OFS   R16(0x04000356)
#define BG0HOFS_A      R16(0x04000010)
#define VRAMCNT_C      R8(0x04000242)
#define PAL_A          ((volatile u16 *)0x05000000)
#define LCDC_C         ((volatile u16 *)0x06840000)

int main(void)
{
    con_init();
    IPCFIFOCNT = FIFO_ENABLE | FIFO_ERROR | FIFO_SEND_CLEAR;
    POWCNT1 = 0x820F;                        /* LCDs, 2D A, render, geometry, 2D B, A on top */
    res_begin("REAR PLANE", 1);
    VRAMCNT_C = 0x80;                        /* LCDC */
    for (u32 y = 0; y < 256; y++)
        for (u32 x = 0; x < 256; x++)
            LCDC_C[y * 256 + x] = (u16)(((x * 3 + y * 5) & 0x7FFF) | ((((x >> 4) ^ (y >> 3)) & 1) << 15));
    VRAMCNT_C = 0x80 | (2 << 3) | 3;         /* 3D texture slot 2 */
    CLEAR_COLOR = (31u << 16) | 0x7C1F;      /* (not shown: bitmap mode) */
    CLRIMAGE_OFS = (11u << 8) | 37u;         /* x 37, y 11 */
    DISP3DCNT = 1u << 14;                    /* rear-plane bitmap */
    BG0HOFS_A = 16;                          /* layer shifted left by 16 */
    PAL_A[0] = 0x03E0;                       /* backdrop green */
    res_check(0, "DISP3DCNT", DISP3DCNT & 0x4000, 0x4000);
    res_finish();
    DISPCNT_A = 0x00010108;                  /* mode 0, BG0 on, BG0 = 3D */
    for (;;) wait_vblank();
}
