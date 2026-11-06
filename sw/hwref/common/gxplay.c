// Geometry-stream playback and 3D-only capture: see gxplay.h.
#include "gxplay.h"
#include <string.h>

#define R_ALPHAREF   REG16(0x04000340)
#define R_CLEARCOL   REG32(0x04000350)
#define R_CLEARDEPTH REG32(0x04000354)
#define R_FOGCOLOR   REG32(0x04000358)
#define R_FOGOFFSET  REG16(0x0400035C)

u32 gxp_timeouts;

static u32 rd32(const u8* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((u32)p[3] << 24); }

void gxp_parse_regs(GxpRegs* r, const u8* p)
{
	r->frame = rd32(p); r->polys = rd32(p + 4); r->verts = rd32(p + 8);
	r->dispcnt = rd32(p + 12); r->flushattr = rd32(p + 16);
	r->alpharef = p[20];
	for (int i = 0; i < 32; i++) r->toon[i] = p[21 + 2 * i] | (p[22 + 2 * i] << 8);
	for (int i = 0; i < 8; i++) r->edge[i] = p[85 + 2 * i] | (p[86 + 2 * i] << 8);
	r->fogcolor = rd32(p + 101); r->fogoffset = rd32(p + 105);
	memcpy(r->fog, p + 109, 32);
	r->clear1 = rd32(p + 141); r->clear2 = rd32(p + 145);
}

void gxp_set_regs(const GxpRegs* r)
{
	R_DISP3DCNT = (r->dispcnt & 0x4FFF) | (3 << 12);   // also ack underflow/overflow
	R_ALPHAREF = r->alpharef;
	for (int i = 0; i < 32; i++) REG16(0x04000380 + 2 * i) = r->toon[i];
	for (int i = 0; i < 8; i++) REG16(0x04000330 + 2 * i) = r->edge[i];
	R_FOGCOLOR = r->fogcolor;
	R_FOGOFFSET = r->fogoffset;
	for (int i = 0; i < 32; i += 4)
		REG32(0x04000360 + i) = r->fog[i] | (r->fog[i + 1] << 8) | (r->fog[i + 2] << 16) | ((u32)r->fog[i + 3] << 24);
	R_CLEARCOL = r->clear1;
	R_CLEARDEPTH = r->clear2;
}

bool gxp_valid_cmd(u8 c)
{
	return (c >= 0x10 && c <= 0x1C) || (c >= 0x20 && c <= 0x2B) || (c >= 0x30 && c <= 0x34) ||
	       c == 0x40 || c == 0x41 || c == 0x50 || c == 0x60 || (c >= 0x70 && c <= 0x72);
}

bool gxp_put(u8 cmd, u32 param)
{
	// A port write to a full FIFO stalls the bus until there is room, which
	// never comes if the engine locked up: wait here instead, bounded.
	for (u32 i = 0; GXSTAT_LEVEL(R_GXSTAT) >= 248; i++)
		if (i > 4000000) { gxp_timeouts++; return false; }
	*GXPORT(cmd) = param;
	return true;
}

bool gxp_wait_idle(void)
{
	for (u32 i = 0; R_GXSTAT & GXSTAT_BUSY; i++)
		if (i > 8000000) { gxp_timeouts++; return false; }
	return true;
}

bool gxp_swap(u32 attr)
{
	if (!gxp_put(0x50, attr)) return false;
	return gxp_wait_idle();   // busy until the swap runs at VBlank
}

void gxp_reset_geometry(void)
{
	gxp_wait_idle();
	REG16(0x04000610) = 0x7FFF;   // DISP_1DOT_DEPTH: not in the trace; melonDS's reset value
	// libnds's glResetMatrixStack(), with its wait bounded: on the DS a stuck
	// engine (gxburst v3.1) can hold the matrix-stack busy bit forever.
	for (u32 i = 0; R_GXSTAT & (1u << 14); i++) {
		R_GXSTAT |= 1u << 15;   // clear push/pop errors, or the busy bit never clears
		if (i > 8000000) { gxp_timeouts++; break; }
	}
	if (R_GXSTAT & (1u << 13)) { gxp_put(0x10, 0); gxp_put(0x12, 1); }
	gxp_put(0x10, 2);
	gxp_put(0x12, (R_GXSTAT >> 8) & 0x1F);
	for (int m = 0; m < 4; m++) { gxp_put(0x10, m); gxp_put(0x15, 0); }
	gxp_put(0x10, 0);
	gxp_wait_idle();
}

void gxp_console_on_h(void)
{
	videoSetModeSub(MODE_0_2D);
	vramSetBankH(VRAM_H_SUB_BG);
	consoleInit(NULL, 0, BgType_Text4bpp, BgSize_T_256x256, 15, 0, false, true);
}

void gxp_capture_start(int bank)
{
	R_DISPCAP = DCAP_ENABLE | DCAP_MODE(DCAP_MODE_A) | DCAP_SRC_A(DCAP_SRC_A_3DONLY) |
	            DCAP_SIZE(DCAP_SIZE_256x192) | DCAP_BANK(bank);
}

bool gxp_capture_done(void) { return !(R_DISPCAP & DCAP_ENABLE); }

void gxp_capture_finish(int bank, u16* dst)
{
	for (u32 i = 0; !gxp_capture_done() && i < 20000000; i++) {}
	const u32* src = (const u32*)(0x06800000 + bank * 0x20000);
	u32* d = (u32*)dst;
	for (int i = 0; i < 256 * 192 / 2; i++) d[i] = src[i];
}
