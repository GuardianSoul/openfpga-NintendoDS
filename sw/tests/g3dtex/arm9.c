/* g3dtex.nds, ARM9: the 3D texture cache starts over when VRAMCNT changes.
   Bank B holds an 8x8 direct-colour texture (texture slot 1). It is written
   through LCDC, mapped as texture, drawn on a full-screen quad and the 3D
   screen captured into bank D; then bank B is mapped back to LCDC, the
   texels rewritten, mapped as texture again and drawn and captured again.
   Each capture's centre pixel must be that pass's texel colour: a cache
   that kept the first pass's block (no flush on the remap) shows red twice. */
#include "../common/con.h"
#include "../common/results.h"
#include "../common/ipc.h"

#define GX(o)          R32(0x04000400 + (o))
#define DISP3DCNT      R16(0x04000060)
#define DISPCAPCNT     R32(0x04000064)
#define CLEAR_COLOR    R32(0x04000350)
#define CLEAR_DEPTH    R16(0x04000354)
#define MTX_MODE       GX(0x040)
#define MTX_IDENTITY   GX(0x054)
#define COLOR          GX(0x080)
#define TEXCOORD       GX(0x088)
#define VTX_16         GX(0x08C)
#define POLYGON_ATTR   GX(0x0A4)
#define TEXIMAGE_PARAM GX(0x0A8)
#define BEGIN_VTXS     GX(0x100)
#define END_VTXS       GX(0x104)
#define SWAP_BUFFERS   GX(0x140)
#define VIEWPORT       GX(0x180)
#define LCDC_B         ((volatile u16 *)0x06820000)
#define LCDC_D         ((volatile u16 *)0x06860000)

static void vtx(s32 x, s32 y, s32 z)     /* 1.3.12 fixed point */
{
    VTX_16 = (u32)(x & 0xFFFF) | ((u32)y << 16);
    VTX_16 = (u32)(z & 0xFFFF);
}

static void scene(void)
{
    MTX_MODE = 0; MTX_IDENTITY = 0;
    MTX_MODE = 3; MTX_IDENTITY = 0;          /* texture */
    MTX_MODE = 2; MTX_IDENTITY = 0;
    POLYGON_ATTR = (31u << 16) | (3u << 6);  /* alpha 31, modulate, front and back */
    /* slot 1 (0x20000 / 8), repeat S and T, 8 x 8, direct colour */
    TEXIMAGE_PARAM = (0x20000u >> 3) | (3u << 16) | (7u << 26);
    BEGIN_VTXS = 1;                          /* quads */
    COLOR = 0x7FFF;                          /* white: the texel unchanged */
    TEXCOORD = 0;                    vtx(-4096, -4096, 0);
    TEXCOORD = 128u << 16;           vtx(-4096,  4095, 0);
    TEXCOORD = 128u | (128u << 16);  vtx( 4095,  4095, 0);
    TEXCOORD = 128u;                 vtx( 4095, -4096, 0);
    END_VTXS = 0;
}

/* the 3D screen of the next frame into bank D; the centre pixel's colour */
static u32 pass(u16 texel)
{
    VRAMCNT(1) = 0x80;                       /* B -> LCDC */
    for (int i = 0; i < 64; i++) LCDC_B[i] = texel;
    VRAMCNT(1) = 0x8B;                       /* B -> texture slot 1 */
    for (int f = 0; f < 3; f++) { scene(); SWAP_BUFFERS = 0; wait_vblank(); }
    /* bank D, 256 x 192, source A = 3D screen, capture source A */
    DISPCAPCNT = (1u << 31) | (1u << 24) | (3u << 20) | (3u << 16) | 16u;
    for (int f = 0; f < 3 && (DISPCAPCNT >> 31); f++) { scene(); SWAP_BUFFERS = 0; wait_vblank(); }
    return LCDC_D[96 * 256 + 128] & 0x7FFF;
}

int main(void)
{
    con_init();
    IPCFIFOCNT = FIFO_ENABLE | FIFO_ERROR | FIFO_SEND_CLEAR;
    POWCNT1 = 0x820F;
    res_begin("3D TEX REMAP", 2);
    DISP3DCNT = 1;                           /* texture mapping */
    CLEAR_COLOR = (31u << 16) | 0x03E0;
    CLEAR_DEPTH = 0x7FFF;
    VIEWPORT = (191u << 24) | (255u << 16);
    VRAMCNT(3) = 0x80;                       /* D -> LCDC (capture) */

    res_check(0, "FIRST", pass(0x801F), 0x001F);   /* red */
    res_check(1, "REMAP", pass(0xFC00), 0x7C00);   /* blue */
    res_finish();
    for (;;) wait_vblank();
}
