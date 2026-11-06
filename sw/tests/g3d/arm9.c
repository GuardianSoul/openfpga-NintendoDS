/* g3d.nds, ARM9: the 3D engine in the whole system. Two flat-colored
   triangles are sent through the geometry registers every frame (identity
   matrices, VTX_16) and swapped; engine A shows them on BG0 (3D). Checks
   read back the geometry engine's polygon and vertex counts (RAM_COUNT)
   after a swap; the picture is for comparing frames with melonDS. */
#include "../common/con.h"
#include "../common/results.h"
#include "../common/ipc.h"

#define GX(o)          R32(0x04000400 + (o))
#define DISP3DCNT      R16(0x04000060)
#define CLEAR_COLOR    R32(0x04000350)
#define CLEAR_DEPTH    R16(0x04000354)
#define RAM_COUNT      R32(0x04000604)
#define MTX_MODE       GX(0x040)
#define MTX_IDENTITY   GX(0x054)
#define COLOR          GX(0x080)
#define VTX_16         GX(0x08C)
#define POLYGON_ATTR   GX(0x0A4)
#define BEGIN_VTXS     GX(0x100)
#define END_VTXS       GX(0x104)
#define SWAP_BUFFERS   GX(0x140)
#define VIEWPORT       GX(0x180)

static void vtx(s32 x, s32 y, s32 z)     /* 1.3.12 fixed point */
{
    VTX_16 = (u32)(x & 0xFFFF) | ((u32)y << 16);
    VTX_16 = (u32)(z & 0xFFFF);
}

static void scene(void)
{
    MTX_MODE = 0; MTX_IDENTITY = 0;          /* projection */
    MTX_MODE = 2; MTX_IDENTITY = 0;          /* position and vector */
    POLYGON_ATTR = (31u << 16) | (3u << 6);  /* alpha 31, front and back */
    BEGIN_VTXS = 0;                          /* triangles */
    COLOR = 0x001F;                          /* red */
    vtx(-3072, -2048, 0); vtx(0, 3072, 0); vtx(-512, -3072, 0);
    COLOR = 0x7C00;                          /* blue */
    vtx(512, 2048, 0); vtx(3584, 3072, 0); vtx(3072, -2560, 0);
    END_VTXS = 0;
}

int main(void)
{
    con_init();
    IPCFIFOCNT = FIFO_ENABLE | FIFO_ERROR | FIFO_SEND_CLEAR;
    POWCNT1 = 0x820F;                        /* LCDs, 2D A, render, geometry, 2D B, A on top */
    res_begin("3D ENGINE", 2);
    DISP3DCNT = 0;
    CLEAR_COLOR = (31u << 16) | 0x03E0;      /* opaque green */
    CLEAR_DEPTH = 0x7FFF;
    VIEWPORT = (191u << 24) | (255u << 16);  /* 0,0 - 255,191 */

    /* 0, 1: the counts of the frame being submitted, read before its swap
       (RAM_COUNT starts over at each swap): 2 polygons, 6 vertices */
    for (int f = 0; f < 3; f++) { scene(); SWAP_BUFFERS = 0; wait_vblank(); }
    scene();
    for (volatile int d = 0; d < 2000; d++) ;   /* the FIFO drains */
    u32 rc = RAM_COUNT;
    SWAP_BUFFERS = 0;
    res_check(0, "POLYGONS", rc & 0xFFF, 2);
    res_check(1, "VERTICES", (rc >> 16) & 0x1FFF, 6);
    res_finish();

    DISPCNT_A = 0x00010108;                  /* mode 0, BG0 on, BG0 = 3D */
    for (;;) { wait_vblank(); scene(); SWAP_BUFFERS = 0; }
}
