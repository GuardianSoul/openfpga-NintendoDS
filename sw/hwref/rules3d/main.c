// 3D rule-pinning captures. docs/hw-reference.md "rules3d".
//
// Each panel varies one parameter in a grid so a rendering rule can be read
// off the pixels:
// - "flat" projection: x' = x, y' = y, z' = z, w' = 3. A vertex lands exactly on
//   a chosen screen position (1/16 pixel), and depth = z / 3.
// - "persp" projection: w' = z, z' = z / 2. Vertices at whole pixels with w in
//   multiples of 3/32.
// Textures encode their own coordinates (R = s, G = t), the toon table its
// index, and AA coverage shows as brightness over a black backdrop. Captures
// as cap3d: DISPCAPCNT source A, 256x192, raw u16 LE.
#include "../common/hwref.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

#define VERSION "rules3d 18"

#define R_CLEARCOL    REG32(0x04000350)
#define R_CLEARDEPTH  REG16(0x04000354)
#define R_TOON(i)     REG16(0x04000380 + 2 * (i))
#define R_EDGE(i)     REG16(0x04000330 + 2 * (i))
#define R_BLDCNT      REG16(0x04000050)
#define R_BLDALPHA    REG16(0x04000052)
#define RGB(r, g, b) ((r) | ((g) << 5) | ((b) << 10))
#define PA(alpha, id) (((u32)(alpha) << 16) | ((u32)(id) << 24) | (3u << 6))
#define PA_DECAL      (1u << 4)
#define PA_TOON       (2u << 4)
#define PA_SHADOW     (3u << 4)
#define PA_DEPTH_EQ   (1u << 14)

static inline void gx(u32 cmd, u32 v) { *GXPORT(cmd) = v; }

// ---- projections and exact vertices ----------------------------------------

static void load44(const s32* m)
{
	for (int i = 0; i < 16; i++) gx(0x16, m[i]);
}
static void proj(bool persp)
{
	static const s32 flat[16] = { 0x1000,0,0,0, 0,0x1000,0,0, 0,0,0x1000,0, 0,0,0,0x3000 };
	static const s32 per[16]  = { 0x1000,0,0,0, 0,0x1000,0,0, 0,0,0x800,0x1000, 0,0,0,0 };
	gx(0x10, 0);
	load44(persp ? per : flat);
	gx(0x10, 2);
	gx(0x15, 0);
	gx(0x10, 3);
	gx(0x15, 0);
	gx(0x10, 2);
}
static void vraw(s32 x, s32 y, s32 z)
{
	gx(0x23, ((u32)x & 0xFFFF) | ((u32)y << 16));
	gx(0x23, (u32)z & 0xFFFF);
}
// flat mode: (px16, py16) in 1/16 pixels from the top-left, depth z (4.12)
static void vf(int px16, int py16, s32 z)
{
	vraw((px16 - 2048) * 6, (1536 - py16) * 8, z);
}
static void vfp(int px, int py, s32 z) { vf(px * 16, py * 16, z); }
// persp mode: whole pixels, w in 4.12 (multiples of 384 are exact)
static void vp(int px, int py, s32 w)
{
	vraw((s32)((s64)(px - 128) * w / 128), (s32)((s64)(96 - py) * w / 96), w);
}
static void col(int r, int g, int b) { gx(0x20, RGB(r, g, b)); }
static void tc(s32 s16, s32 t16) { gx(0x22, ((u32)s16 & 0xFFFF) | ((u32)t16 << 16)); }
static void begin(int t) { gx(0x40, t); }
static void end(void) { gx(0x41, 0); }
static void attr(u32 a) { gx(0x29, a); }
static void teximg(u32 p) { gx(0x2A, p); }

static void quadf(int x0, int y0, int x1, int y1, s32 z)
{
	begin(1);
	vfp(x0, y0, z); vfp(x0, y1, z); vfp(x1, y1, z); vfp(x1, y0, z);
}

// ---- textures --------------------------------------------------------------

// 32x32 direct colour at slot 0 offset 0: R = s, G = t, B = 16.
#define TEX32(fl) ((0) | (2u << 20) | (2u << 23) | (7u << 26) | (fl))
#define REP_S (1u << 16)
#define REP_T (1u << 17)
#define FLIP_S (1u << 18)
#define FLIP_T (1u << 19)

static void make_texture(void)
{
	static u16 img[32 * 32];
	for (int t = 0; t < 32; t++)
		for (int s = 0; s < 32; s++) img[t * 32 + s] = 0x8000 | RGB(s, t, 16);
	R_VRAMCNT(0) = 0x80;
	for (int i = 0; i < 32 * 32; i++) ((vu16*)0x06800000)[i] = img[i];
	R_VRAMCNT(0) = 0x83;
}

// ---- panels ----------------------------------------------------------------

// Horizontal Gouraud spans: 24 bands of 8 lines; widths and offsets vary,
// R 0->31, G 31->0, B 7->9 across each band.
static const int s_w[24] = { 1, 2, 3, 4, 5, 7, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65, 100, 127, 128, 129, 200, 240, 255, 256 };
static void p_span(void)
{
	proj(false);
	attr(PA(31, 1));
	for (int i = 0; i < 24; i++) {
		int x0 = (i * 5) % 7, x1 = x0 + s_w[i];
		if (x1 > 256) { x0 = 0; x1 = 256; }
		int y0 = i * 8, y1 = y0 + 7;
		begin(1);
		col(0, 31, 7); vfp(x0, y0, 0); vfp(x0, y1, 0);
		col(31, 0, 9); vfp(x1, y1, 0); vfp(x1, y0, 0);
	}
}
// Vertical Gouraud: 32 columns of 8 pixels, heights 1..192, colours top to bottom.
static void p_vert(void)
{
	proj(false);
	attr(PA(31, 1));
	for (int j = 0; j < 32; j++) {
		int h = j < 24 ? s_w[j] * 3 / 4 + 1 : 192 - (31 - j) * 7;
		if (h > 192) h = 192;
		int x0 = j * 8, y0 = (j * 3) % 5;
		if (y0 + h > 192) y0 = 192 - h;
		begin(1);
		col(0, 31, 7); vfp(x0, y0, 0); col(31, 0, 9); vfp(x0, y0 + h, 0);
		vfp(x0 + 7, y0 + h, 0); col(0, 31, 7); vfp(x0 + 7, y0, 0);
	}
}
// General triangles with RGB corners, including slim and sub-pixel ones.
static void p_tris(bool toon)
{
	proj(false);
	attr(PA(31, 1) | (toon ? PA_TOON : 0));
	static const s16 t[][6] = {
		{ 4, 4, 120, 10, 30, 90 }, { 130, 4, 252, 60, 140, 92 }, { 4, 100, 60, 188, 124, 120 },
		{ 136, 100, 250, 104, 138, 188 }, { 70, 20, 74, 180, 72, 100 }, { 200, 120, 252, 186, 160, 186 },
	};
	for (unsigned k = 0; k < sizeof t / sizeof t[0]; k++) {
		begin(0);
		col(31, 0, 0); vf(t[k][0] * 16 + k * 3, t[k][1] * 16 + k * 5, 0);
		col(0, 31, 0); vf(t[k][2] * 16 + k * 7, t[k][3] * 16, 0);
		col(0, 0, 31); vf(t[k][4] * 16, t[k][5] * 16 + k * 11, 0);
	}
}
static void p_tris_gouraud(void) { p_tris(false); }
static void p_tris_toon(void) { p_tris(true); }
// Toon index from red: spans with red 0->31 at various widths, toon mode.
static void p_toon_span(void)
{
	proj(false);
	attr(PA(31, 1) | PA_TOON);
	for (int i = 0; i < 24; i++) {
		int x0 = (i * 5) % 7, x1 = x0 + s_w[i];
		if (x1 > 256) { x0 = 0; x1 = 256; }
		begin(1);
		col(0, 0, 0); vfp(x0, i * 8, 0); vfp(x0, i * 8 + 7, 0);
		col(31, 31, 31); vfp(x1, i * 8 + 7, 0); vfp(x1, i * 8, 0);
	}
}

// Perspective texture sampling: 12 bands, left/right w ratio and s range vary;
// decal mode so the texel colour comes out unchanged.
static void p_persp_tex(void)
{
	proj(true);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	static const struct { s16 wl, wr; s16 s0, s1; } b[12] = {
		{ 8, 8, 0, 32 }, { 8, 8, 0, 96 }, { 4, 8, 0, 32 }, { 8, 4, 0, 32 }, { 2, 16, 0, 64 }, { 16, 2, 0, 64 },
		{ 1, 16, 0, 128 }, { 16, 1, -16, 48 }, { 6, 10, 3, 61 }, { 3, 15, -40, 40 }, { 12, 13, 0, 255 }, { 5, 7, 31, 33 },
	};
	for (int i = 0; i < 12; i++) {
		s32 wl = b[i].wl * 1536, wr = b[i].wr * 1536;   // 1536 = 4 * 384: 0.375 .. 6.0
		int y0 = i * 16, y1 = y0 + 15;
		begin(1);
		tc(b[i].s0 * 16, 0);  vp(0, y0, wl);
		tc(b[i].s0 * 16, 32 * 16); vp(0, y1, wl);
		tc(b[i].s1 * 16, 32 * 16); vp(256, y1, wr);
		tc(b[i].s1 * 16, 0);  vp(256, y0, wr);
	}
}
// Same along t (vertical), 16 columns.
static void p_persp_tex_t(void)
{
	proj(true);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T | FLIP_T));
	for (int j = 0; j < 16; j++) {
		s32 wt = (1 + (j & 3) * 3) * 1536, wb = (1 + ((j >> 2) & 3) * 3) * 1536;
		int x0 = j * 16, x1 = x0 + 15;
		int t1 = 32 + j * 13;
		begin(1);
		tc(0, 0); vp(x0, 0, wt);
		tc(0, t1 * 16); vp(x0, 192, wb);
		tc(32 * 16, t1 * 16); vp(x1, 192, wb);
		tc(32 * 16, 0); vp(x1, 0, wt);
	}
}
// Linear (w equal) sampling at boundaries: fractional texcoords, negative,
// clamp, repeat and flip, in 16 bands.
static void p_tex_linear(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	for (int i = 0; i < 16; i++) {
		static const u32 fl[4] = { 0, REP_S | REP_T, REP_S | FLIP_S | REP_T, REP_S | REP_T | FLIP_T };
		teximg(TEX32(fl[i & 3]));
		s32 s0 = -64 + i * 7, s1 = s0 + 32 * 16 + (i * 37) % 300;   // 1/16 texels
		int y0 = i * 12, y1 = y0 + 11;
		begin(1);
		tc(s0, 0); vfp(0, y0, 0);
		tc(s0, 12 * 16); vfp(0, y1, 0);
		tc(s1 * 3, 12 * 16); vfp(256, y1, 0);
		tc(s1 * 3, 0); vfp(256, y0, 0);
	}
}

// AA coverage: white triangles with one sloped edge, slopes k/16 and
// sub-pixel offsets, distinct IDs, over a black backdrop with clear alpha 0.
static void p_aa(void)
{
	proj(false);
	col(31, 31, 31);
	int id = 1;
	for (int r = 0; r < 6; r++)
		for (int c = 0; c < 8; c++) {
			int k = r * 8 + c;               // slope index 0..47
			int x0 = c * 32 + 4, y0 = r * 32 + 2;
			int dx16 = k * 6, off = (k * 5) % 16;   // horizontal run over 28 lines
			attr(PA(31, id++ & 63));
			begin(0);
			vf(x0 * 16 + off, y0 * 16, 0);
			vf(x0 * 16 + off + dx16, (y0 + 28) * 16, 0);
			vf((x0 + 24) * 16, (y0 + 14) * 16 + off, 0);
		}
}

// Lines: zero-width triangles (v1 repeated) at many slopes, colour along them.
static void p_lines(void)
{
	proj(false);
	attr(PA(31, 1));
	for (int i = 0; i < 40; i++) {
		int cx = 16 + (i % 8) * 30, cy = 16 + (i / 8) * 36;
		float a = i * 0.157f;
		int ex = cx + (int)(14 * cosf(a)), ey = cy + (int)(14 * sinf(a));
		begin(0);
		col(31, 0, 0); vfp(cx, cy, 0);
		col(0, 31, 31); vfp(ex, ey, 0); vfp(ex, ey, 0);
	}
	// sub-pixel endpoints, long lines
	for (int i = 0; i < 6; i++) {
		begin(0);
		col(31, 31, 0); vf(8 * 16 + i * 3, (184 - i) * 16, 0);
		col(0, 31, 0); vf(248 * 16 - i * 5, (184 - i * 6) * 16 + i, 0); vf(248 * 16 - i * 5, (184 - i * 6) * 16 + i, 0);
	}
}

// Colours inside polygons clipped by the screen edges.
static void p_clip(void)
{
	proj(false);
	attr(PA(31, 1));
	static const s16 t[][6] = {
		{ -100, 10, 90, 40, 20, 90 }, { 160, -60, 300, 30, 200, 90 }, { 30, 120, 120, 260, -40, 220 },
		{ 150, 110, 400, 150, 170, 300 }, { -150, -150, 400, 96, -150, 340 },
	};
	for (unsigned k = 0; k < sizeof t / sizeof t[0]; k++) {
		attr(PA(31, 1 + k));
		begin(0);
		col(31, 0, (k * 5) & 31); vfp(t[k][0], t[k][1], -0x100 * k);
		col(0, 31, 0); vfp(t[k][2], t[k][3], -0x100 * k);
		col(0, (k * 7) & 31, 31); vfp(t[k][4], t[k][5], -0x100 * k);
	}
}
// Near-plane clipping in a standard perspective (not pixel-exact).
static void p_clip_near(void)
{
	gx(0x10, 0);
	gx(0x15, 0);
	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	gluPerspective(60, 256.0f / 192.0f, 0.5f, 20);
	gx(0x10, 2);
	gx(0x15, 0);
	for (int k = 0; k < 4; k++) {
		attr(PA(31, 1 + k));
		float x = -1.2f + k * 0.8f;
		begin(0);
		col(31, 0, 0); vraw((s32)(x * 4096), -2048, (s32)(-(0.1f + k * 0.15f) * 4096));
		col(0, 31, 0); vraw((s32)((x + 0.7f) * 4096), -2048, -4 * 4096);
		col(0, 0, 31); vraw((s32)(x * 4096), 2048, -4 * 4096);
	}
}

// Depth ties: sloped planes drawn twice with different triangulations (red
// first, then green with the less test / blue with the equal test).
static s32 plane_z(int k, int px, int py)
{
	// z (4.12) over the screen for slope set k
	static const s16 ax[6] = { 0, 3, 17, -9, 41, 1 }, ay[6] = { 5, 0, -13, 22, 7, 1 };
	return ax[k] * (px - 128) + ay[k] * (py - 96);
}
static void plane_tri(int k, int x0, int y0, int x1, int y1, int x2, int y2)
{
	begin(0);
	vfp(x0, y0, plane_z(k, x0, y0)); vfp(x1, y1, plane_z(k, x1, y1)); vfp(x2, y2, plane_z(k, x2, y2));
}
static void p_depth(void)
{
	proj(false);
	for (int k = 0; k < 6; k++) {
		int x0 = (k % 3) * 85 + 2, y0 = (k / 3) * 96 + 2, x1 = x0 + 80, y1 = y0 + 90;
		attr(PA(31, 1));
		col(31, 0, 0);
		plane_tri(k, x0, y0, x0, y1, x1, y1);
		plane_tri(k, x0, y0, x1, y1, x1, y0);
		attr(PA(31, 2));
		col(0, 31, 0);   // other diagonal
		plane_tri(k, x0, y0, x0, y1, x1, y0);
		plane_tri(k, x0, y1, x1, y1, x1, y0);
		attr(PA(31, 3) | PA_DEPTH_EQ);
		col(0, 0, 31);   // a smaller triangle in the same plane
		plane_tri(k, x0 + 20, y0 + 20, x0 + 20, y1 - 10, x1 - 10, y0 + 40);
	}
}
// The same in W-buffer mode: persp projection, w varying across each plane.
static void p_depth_w(void)
{
	proj(true);
	for (int k = 0; k < 6; k++) {
		int x0 = (k % 3) * 85 + 2, y0 = (k / 3) * 96 + 2, x1 = x0 + 80, y1 = y0 + 90;
		s32 wa = (2 + k) * 1536, wb = (3 + (k * 5) % 7) * 1536, wc = (1 + (k * 3) % 8) * 1536;
		// w is affine in (x, y) on the plane through the 3 corners a=(x0,y0), b=(x0,y1), c=(x1,y0)
		s32 wd = wb + wc - wa;   // (x1,y1)
		attr(PA(31, 1)); col(31, 0, 0);
		begin(0); vp(x0, y0, wa); vp(x0, y1, wb); vp(x1, y1, wd);
		begin(0); vp(x0, y0, wa); vp(x1, y1, wd); vp(x1, y0, wc);
		attr(PA(31, 2)); col(0, 31, 0);
		begin(0); vp(x0, y0, wa); vp(x0, y1, wb); vp(x1, y0, wc);
		begin(0); vp(x0, y1, wb); vp(x1, y1, wd); vp(x1, y0, wc);
	}
}

// Shadow mask rules: 8 volumes over a wall (depth 0), each a front quad
// (z = -1, nearer) and a back quad (z = +1, behind the wall); which quads go
// into the mask (ID 0) and shadow (ID 5) passes varies. Manual sort keeps the
// submission order.
static void p_shadow(void)
{
	proj(false);
	attr(PA(31, 1));
	col(16, 16, 16);
	quadf(0, 0, 256, 192, 0);
	enum { F = 1, B = 2, BF = 4 };   // front, back, back then front
	static const u8 mask[8] = { B, B | F, B, B | F, B, 0, F, B };
	static const u8 shad[8] = { F, F, BF, B | F, B, F, F, F };
	for (int v = 0; v < 8; v++) {
		int x0 = (v % 4) * 64 + 8, y0 = (v / 4) * 96 + 16, x1 = x0 + 48, y1 = y0 + 64;
		col(0, 0, 12);
		if (mask[v] & B) { attr(PA(16, 0) | PA_SHADOW); quadf(x0, y0, x1, y1, 0x1000); }
		if (mask[v] & F) { attr(PA(16, 0) | PA_SHADOW); quadf(x0, y0, x1, y1, -0x1000); }
		u32 sid = v == 7 ? 1 : 5;   // v7: shadow ID equal to the wall's
		if (shad[v] & BF) {
			attr(PA(16, sid) | PA_SHADOW); quadf(x0, y0, x1, y1, 0x1000);
			attr(PA(16, sid) | PA_SHADOW); quadf(x0, y0, x1, y1, -0x1000);
		}
		if (shad[v] & B) { attr(PA(16, sid) | PA_SHADOW); quadf(x0, y0, x1, y1, 0x1000); }
		if (shad[v] & F) { attr(PA(16, sid) | PA_SHADOW); quadf(x0, y0, x1, y1, -0x1000); }
	}
}

// Pixel coverage of axis-aligned and sub-pixel quads (fill rules).
static void p_fill(void)
{
	proj(false);
	attr(PA(31, 1));
	for (int i = 0; i < 64; i++) {
		int x = (i % 16) * 16 + 2, y = (i / 16) * 16 + 2;
		int o = i % 16;   // sub-pixel offset 0..15/16
		col(31, (i * 3) & 31, o * 2);
		begin(1);
		vf(x * 16 + o, y * 16 + o, 0); vf(x * 16 + o, (y + 5) * 16 + o, 0);
		vf((x + 5) * 16 + o, (y + 5) * 16 + o, 0); vf((x + 5) * 16 + o, y * 16 + o, 0);
	}
	for (int i = 0; i < 16; i++) {   // 1-pixel and sub-pixel quads
		int x = i * 16 + 4, y = 140;
		col(0, 31, 31);
		begin(1);
		vf(x * 16, y * 16, 0); vf(x * 16, y * 16 + i + 1, 0);
		vf(x * 16 + i + 1, y * 16 + i + 1, 0); vf(x * 16 + i + 1, y * 16, 0);
	}
}


// ---- v2: directed panels -----------------------------------------------------

// Toon index / highlight along Y: 32 columns, red 0 -> 31 top to bottom over
// heights 1..192 (the edge (Y) interpolation of the index).
static void p_toon_vert(void)
{
	proj(false);
	attr(PA(31, 1) | PA_TOON);
	for (int j = 0; j < 32; j++) {
		int h = j < 24 ? s_w[j] * 3 / 4 + 1 : 192 - (31 - j) * 7;
		if (h > 192) h = 192;
		int x0 = j * 8, y0 = (j * 3) % 5;
		if (y0 + h > 192) y0 = 192 - h;
		begin(1);
		col(0, 0, 0); vfp(x0, y0, 0); col(31, 31, 31); vfp(x0, y0 + h, 0);
		vfp(x0 + 7, y0 + h, 0); col(0, 0, 0); vfp(x0 + 7, y0, 0);
	}
}
// Toon along sloped edges: triangles with red only changing along their left
// edge (0 at the top vertex, 31 at the bottom), other vertex grey 16.
static void p_toon_edges(void)
{
	proj(false);
	attr(PA(31, 1) | PA_TOON);
	for (int k = 0; k < 16; k++) {
		int x0 = (k % 8) * 32 + 2, y0 = (k / 8) * 96 + 2;
		int dx = (k * 5) % 24, h = 40 + k * 3;
		begin(0);
		col(0, 0, 0); vf(x0 * 16 + k, y0 * 16, 0);
		col(31, 31, 31); vf((x0 + dx) * 16, (y0 + h) * 16 + k, 0);
		col(16, 16, 16); vf((x0 + 28) * 16, (y0 + h / 2) * 16, 0);
	}
}

// AA coverage on long edges. X-major: 24 bands, each a quad whose top edge
// drops dy/16 pixels over the full width, from a sub-pixel start.
static void p_aa_x(void)
{
	proj(false);
	col(31, 31, 31);
	for (int i = 0; i < 24; i++) {
		int y0 = i * 8 + 1, dy16 = 1 + i * 5, off = (i * 7) % 16;
		attr(PA(31, (i + 1) & 63));
		begin(1);
		vf(0, y0 * 16 + off, 0); vf(0, (y0 + 7) * 16, 0);
		vf(256 * 16, (y0 + 7) * 16, 0); vf(256 * 16, y0 * 16 + off + dy16, 0);
	}
}
// Y-major: 16 parallelograms 16 pixels apart; both side edges move dx/16
// pixels (0..5.6) over the full height, from a sub-pixel start.
static void p_aa_y(void)
{
	proj(false);
	col(31, 31, 31);
	for (int j = 0; j < 16; j++) {
		int x0 = j * 16 + 2, dx16 = j * 6, off = (j * 5) % 16;
		attr(PA(31, (j + 1) & 63));
		begin(1);
		vf(x0 * 16 + off, 0, 0); vf(x0 * 16 + off + dx16, 192 * 16, 0);
		vf((x0 + 7) * 16 + dx16, 192 * 16, 0); vf((x0 + 7) * 16, 0, 0);
	}
}

// Depth ties, 12 planes (3x4 grid), slopes from shallow to steep, two
// triangulations (red, then green with the less test).
static void p_depth2(void)
{
	proj(false);
	static const s16 ax[12] = { 1, 2, 7, 16, 33, 64, -1, -5, -29, 0, 13, 45 };
	static const s16 ay[12] = { 0, 1, 3, -2, 9, 17, 4, -11, 21, 77, -50, 3 };
	for (int k = 0; k < 12; k++) {
		int x0 = (k % 4) * 64 + 2, y0 = (k / 4) * 64 + 2, x1 = x0 + 60, y1 = y0 + 60;
		#define PZ(px, py) (ax[k] * ((px) - 128) + ay[k] * ((py) - 96))
		attr(PA(31, 1)); col(31, 0, 0);
		begin(0); vfp(x0, y0, PZ(x0, y0)); vfp(x0, y1, PZ(x0, y1)); vfp(x1, y1, PZ(x1, y1));
		begin(0); vfp(x0, y0, PZ(x0, y0)); vfp(x1, y1, PZ(x1, y1)); vfp(x1, y0, PZ(x1, y0));
		attr(PA(31, 2)); col(0, 31, 0);
		begin(0); vfp(x0, y0, PZ(x0, y0)); vfp(x0, y1, PZ(x0, y1)); vfp(x1, y0, PZ(x1, y0));
		begin(0); vfp(x0, y1, PZ(x0, y1)); vfp(x1, y1, PZ(x1, y1)); vfp(x1, y0, PZ(x1, y0));
		#undef PZ
	}
}

// Clipping by the left screen edge: 8 triangles cut 1..128 pixels; red only
// changes along the clipped edges (outside vertex red 31, inside 0).
static void p_clip_dir(void)
{
	proj(false);
	for (int k = 0; k < 8; k++) {
		int cut = 1 << k, y0 = k * 24 + 2;
		attr(PA(31, 1 + k));
		begin(0);
		col(31, 0, 0); vfp(-cut, y0 + 10, 0);
		col(0, 0, 0); vfp(60 + k * 20, y0, 0);
		col(0, 0, 0); vfp(60 + k * 20, y0 + 21, 0);
	}
}

// Interpolation method (divide per pixel vs per-span reciprocal, precision):
// linear-mode spans with huge texcoord ranges. The repeating 32-texel
// texture shows (s >> 4) & 31 in red, so each pixel reads the interpolated s
// to one texel, and factor errors of a few units move texel boundaries.
static void p_tex_big_x(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int i = 0; i < 24; i++) {
		s32 s0 = -32768 + i * 1237, s1 = 32767 - i * 2011;   // 1/16 texels
		int x0 = (i * 3) % 5, x1 = 256 - (i * 7) % 9;
		int y0 = i * 8, y1 = y0 + 7;
		if (i & 1) { s32 t = s0; s0 = s1; s1 = t; }
		begin(1);
		tc(s0, i * 16); vfp(x0, y0, 0);
		tc(s0, i * 16); vfp(x0, y1, 0);
		tc(s1, i * 16); vfp(x1, y1, 0);
		tc(s1, i * 16); vfp(x1, y0, 0);
	}
}
// The same along Y (edge interpolation): 16 columns, t over huge ranges.
static void p_tex_big_y(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int j = 0; j < 16; j++) {
		s32 t0 = -32768 + j * 3001, t1 = 32767 - j * 1733;
		int x0 = j * 16, x1 = x0 + 15, y0 = (j * 3) % 7, y1 = 192 - (j * 5) % 11;
		if (j & 1) { s32 t = t0; t0 = t1; t1 = t; }
		begin(1);
		tc(j * 16, t0); vfp(x0, y0, 0);
		tc(j * 16, t1); vfp(x0, y1, 0);
		tc(j * 16, t1); vfp(x1, y1, 0);
		tc(j * 16, t0); vfp(x1, y0, 0);
	}
}
// melonDS's linear-mode condition (equal w with bits 0-6 clear): spans whose
// w are equal or nearly equal, with and without low bits set, huge s range.
static void p_tex_nearlin(void)
{
	proj(true);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	static const s16 dw[12] = { 0, 0, 1, 2, 64, 127, 128, 129, 256, 0, 1, -1 };
	static const s16 lo[12] = { 0, 1, 0, 0, 0, 0, 0, 0, 0, 0x40, 0x7F, 0x80 };
	for (int i = 0; i < 12; i++) {
		s32 wl = 12288 + lo[i], wr = wl + dw[i];
		int y0 = i * 16, y1 = y0 + 15;
		begin(1);
		tc(-32768 + i * 999, i * 32); vp(0, y0, wl);
		tc(-32768 + i * 999, i * 32); vp(0, y1, wl);
		tc(32767 - i * 777, i * 32); vp(256, y1, wr);
		tc(32767 - i * 777, i * 32); vp(256, y0, wr);
	}
}

// Y-edge linear interpolation with sloped edges: 16 parallelograms whose
// left and right edges lean by dx, t over huge ranges down the edge; the
// span is constant in t, so each pixel reads the edge-interpolated t.
static void p_tex_big_yslant(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int j = 0; j < 16; j++) {
		s32 t0 = 32767 - j * 2777, t1 = -32768 + j * 1511;
		int dx = (j % 4) * 5 - 7, x0 = j * 16 + 8, y0 = j % 3, y1 = 191 - (j * 7) % 13;
		if (j & 2) { s32 t = t0; t0 = t1; t1 = t; }
		begin(1);
		tc(j * 16, t0); vfp(x0, y0, 0);
		tc(j * 16, t1); vfp(x0 + dx, y1, 0);
		tc(j * 16, t1); vfp(x0 + dx + 6, y1, 0);
		tc(j * 16, t0); vfp(x0 + 6, y0, 0);
	}
}
// Colour down tall edges: 32 columns, R 0->31 (or 31->0), G the other way,
// heights 191 with sub-pixel starts.
static void p_col_big_y(void)
{
	proj(false);
	attr(PA(31, 1));
	for (int j = 0; j < 32; j++) {
		int x0 = j * 8, y016 = (j * 5) % 16, y116 = 191 * 16 - (j * 3) % 16;
		int up = j & 1;
		begin(1);
		col(up ? 31 : 0, up ? 0 : 31, j); vf(x0 * 16, y016, 0);
		col(up ? 0 : 31, up ? 31 : 0, 31 - j); vf(x0 * 16, y116, 0);
		vf((x0 + 7) * 16, y116, 0);
		col(up ? 31 : 0, up ? 0 : 31, j); vf((x0 + 7) * 16, y016, 0);
	}
}
// Z along Y: 32 tall columns; each a plane with a large z change down the
// column (|dz| up to ~5.8 of the +-3 range), drawn as two triangulations
// (red, then green with the less test) and a third triangle (blue, equal).
static void p_depth_y(void)
{
	proj(false);
	for (int j = 0; j < 32; j++) {
		int x0 = j * 8, x1 = x0 + 7, y0 = 0, y1 = 191;
		s32 za = -0x2E00 + j * 37, zb = 0x2E00 - j * 311;    // top, bottom
		s32 zc = za + (j - 16) * 9, zd = zb + (j - 16) * 9;  // right side
		attr(PA(31, 1)); col(31, 0, 0);
		begin(0); vfp(x0, y0, za); vfp(x0, y1, zb); vfp(x1, y1, zd);
		begin(0); vfp(x0, y0, za); vfp(x1, y1, zd); vfp(x1, y0, zc);
		attr(PA(31, 2)); col(0, 31, 0);
		begin(0); vfp(x0, y0, za); vfp(x0, y1, zb); vfp(x1, y0, zc);
		begin(0); vfp(x0, y1, zb); vfp(x1, y1, zd); vfp(x1, y0, zc);
	}
}
// Interpenetrating steep planes along Y: pairs crossing at shallow angles.
static void p_depth_ycross(void)
{
	proj(false);
	for (int j = 0; j < 16; j++) {
		int x0 = j * 16 + 1, x1 = x0 + 14;
		s32 a0 = -0x2800, a1 = 0x2800, b0 = 0x2800 - j * 3, b1 = -0x2800 + j * 5;
		attr(PA(31, 1)); col(31, 0, 0);
		begin(1); vfp(x0, 0, a0); vfp(x0, 191, a1); vfp(x1, 191, a1); vfp(x1, 0, a0);
		attr(PA(31, 2)); col(0, 31, 0);
		begin(1); vfp(x0, 0, b0); vfp(x0, 191, b1); vfp(x1, 191, b1); vfp(x1, 0, b0);
	}
}
// W-buffer along Y: persp mode, w varies down 16 tall columns, two
// triangulations.
static void p_depth_yw(void)
{
	proj(true);
	for (int j = 0; j < 16; j++) {
		int x0 = j * 16 + 1, x1 = x0 + 14;
		s32 wt = (1 + (j & 3)) * 1536, wb = (2 + ((j >> 2) * 3)) * 1536;
		attr(PA(31, 1)); col(31, 0, 0);
		begin(0); vp(x0, 0, wt); vp(x0, 191, wb); vp(x1, 191, wb);
		begin(0); vp(x0, 0, wt); vp(x1, 191, wb); vp(x1, 0, wt);
		attr(PA(31, 2)); col(0, 31, 0);
		begin(0); vp(x0, 0, wt); vp(x0, 191, wb); vp(x1, 0, wt);
		begin(0); vp(x0, 191, wb); vp(x1, 191, wb); vp(x1, 0, wt);
	}
}

// ---- v3 ---------------------------------------------------------------------

// Perspective factor along Y on edges with equal or near-equal w whose low
// bits are set (melonDS: 9-bit factor, w0n = w0 >> 1 etc.): 16 columns, t over
// huge ranges down the column, top/bottom w per column.
static void p_persp_y_w(void)
{
	proj(true);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	static const s16 lo[16] = { 0, 1, 3, 0x41, 0x7F, 0, 1, 0, 0x40, 0x7E, 0x7F, 2, 0, 0x55, 0x2A, 0x7F };
	static const s16 dw[16] = { 0, 0, 0, 0, 0, 1, 1, 2, 0, 0, 1, 2, 128, 0, 0, -1 };
	for (int j = 0; j < 16; j++) {
		s32 wt = 12288 + lo[j], wb = wt + dw[j];
		s32 t0 = -30000 + j * 1999, t1 = 30000 - j * 1234;
		int x0 = j * 16, x1 = x0 + 15;
		begin(1);
		tc(j * 16, t0); vp(x0, 0, wt);
		tc(j * 16, t1); vp(x0, 192, wb);
		tc(j * 16, t1); vp(x1, 192, wb);
		tc(j * 16, t0); vp(x1, 0, wt);
	}
}
// Equal-w quads with low w bits set, texcoords varying in both s and t
// (the cap3d persp_00 case: a camera-facing textured plane), 4 per screen.
static void p_persp_eqw(void)
{
	proj(true);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	static const s16 lo[4] = { 0x01, 0x23, 0x41, 0x7F };
	for (int q = 0; q < 4; q++) {
		s32 w = 12288 + lo[q] + q * 384;
		int x0 = (q & 1) * 128, y0 = (q >> 1) * 96;
		s32 a = -20000 + q * 777, b = 20000 - q * 555;
		begin(1);
		tc(a, a); vp(x0, y0, w);
		tc(a, b); vp(x0, y0 + 96, w);
		tc(b, b); vp(x0 + 128, y0 + 96, w);
		tc(b, a); vp(x0 + 128, y0, w);
	}
}
// Depth along X with sub-pixel span ends: 24 bands, each two triangulations
// of a plane sloped in X only, whose left/right edges lean (sub-pixel
// positions every line).
static void p_depth_x(void)
{
	proj(false);
	for (int i = 0; i < 24; i++) {
		int y0 = i * 8, y1 = y0 + 8;
		int lean = (i % 6) * 5 - 12;                 // 1/16 px per line
		int xl0 = 8 * 16 + i * 3, xl1 = xl0 + lean * 8;
		int xr0 = 248 * 16 - i * 7, xr1 = xr0 - lean * 8;
		s32 zl = -0x2C00 + i * 211, zr = 0x2C00 - i * 397;
		attr(PA(31, 1)); col(31, 0, 0);
		begin(0); vf(xl0, y0 * 16, zl); vf(xl1, y1 * 16, zl); vf(xr1, y1 * 16, zr);
		begin(0); vf(xl0, y0 * 16, zl); vf(xr1, y1 * 16, zr); vf(xr0, y0 * 16, zr);
		attr(PA(31, 2)); col(0, 31, 0);
		begin(0); vf(xl0, y0 * 16, zl); vf(xl1, y1 * 16, zl); vf(xr0, y0 * 16, zr);
		begin(0); vf(xl1, y1 * 16, zl); vf(xr1, y1 * 16, zr); vf(xr0, y0 * 16, zr);
	}
}
// W-buffer along Y, finer: 32 columns with w top/bottom pairs and two
// triangulations.
static void p_depth_yw2(void)
{
	proj(true);
	for (int j = 0; j < 32; j++) {
		int x0 = j * 8, x1 = x0 + 7;
		s32 wt = (1 + (j % 8)) * 1536 + (j & 1) * 384, wb = (2 + (j / 8) * 4) * 1536 + (j & 2) * 192;
		attr(PA(31, 1)); col(31, 0, 0);
		begin(0); vp(x0, 0, wt); vp(x0, 192, wb); vp(x1, 192, wb);
		begin(0); vp(x0, 0, wt); vp(x1, 192, wb); vp(x1, 0, wt);
		attr(PA(31, 2)); col(0, 31, 0);
		begin(0); vp(x0, 0, wt); vp(x0, 192, wb); vp(x1, 0, wt);
		begin(0); vp(x0, 192, wb); vp(x1, 192, wb); vp(x1, 0, wt);
	}
}
// AA coverage on short edges: 8x8 grid of small triangles, one sloped edge
// each; slope k/8 (x per y) and sub-pixel start (k*3)%16, over black.
static void p_aa_short(void)
{
	proj(false);
	col(31, 31, 31);
	for (int k = 0; k < 96; k++) {
		int cx = (k % 12) * 21 + 4, cy = (k / 12) * 24 + 2;
		int dx16 = (k % 24) * 4 - 40, off = (k * 3) % 16, h = 6 + (k / 24) * 4;
		attr(PA(31, (k % 62) + 1));
		begin(0);
		vf(cx * 16 + off, cy * 16 + (k * 5) % 16, 0);
		vf(cx * 16 + off + dx16 * h / 8, (cy + h) * 16, 0);
		vf((cx + 12) * 16, (cy + h / 2) * 16 + off, 0);
	}
}

// ---- v4 (raster session's requests) ------------------------------------------

// AA coverage on X-major edges: 48 fans, slope 1.5..40 px per line, 1-3 line
// edges at sub-pixel starts, left and right edges, ascending and descending.
static void p_aa_xfan(void)
{
	proj(false);
	col(31, 31, 31);
	for (int k = 0; k < 48; k++) {
		int cx = (k % 6) * 42 + 1, cy = (k / 6) * 24 + 1;
		int lines = 1 + k % 3;                         // X-major edge height in lines
		int run = 2 + (k * 7) % 39;                    // 2 .. 40 px: slopes 0.7 .. 40 px per line
		int off = (k * 7) % 16, offy = (k * 5) % 16;
		attr(PA(31, (k % 62) + 1));
		begin(0);
		if (k & 1) {   // the edge goes down to the right, the triangle below it
			vf(cx * 16 + off, cy * 16 + offy, 0);
			vf((cx + run) * 16, (cy + lines) * 16 + offy, 0);
			vf(cx * 16 + off, (cy + lines + 6) * 16, 0);
		} else {       // mirrored: down to the left
			vf((cx + run) * 16 + off, cy * 16 + offy, 0);
			vf((cx + run) * 16 + off, (cy + lines + 6) * 16, 0);
			vf(cx * 16, (cy + lines) * 16 + offy, 0);
		}
	}
}
// Short X-major slivers: triangles 1-3 lines tall and 8-40 px long, over black.
static void p_aa_sliver(void)
{
	proj(false);
	col(31, 31, 31);
	for (int k = 0; k < 64; k++) {
		int cx = (k % 4) * 64 + 4, cy = (k / 4) * 12 + 2;
		int h16 = 16 + (k % 3) * 16 + (k * 3) % 8, len = 8 + (k * 5) % 33;
		int off = (k * 11) % 16;
		attr(PA(31, (k % 62) + 1));
		begin(0);
		if (k & 1) { vf(cx * 16 + off, cy * 16, 0); vf((cx + len) * 16, cy * 16 + h16, 0); vf(cx * 16, cy * 16 + h16, 0); }
		else       { vf(cx * 16, cy * 16 + off, 0); vf((cx + len) * 16 + off, cy * 16, 0); vf(cx * 16, cy * 16 + h16, 0); }
	}
}

// Perspective X factor boundaries with large w: projection w' = 2z, x' = 2x,
// y' = 2y, so w reaches 0xFFFF while vertices stay in VTX_16 range.
static void proj2(void)
{
	static const s32 m[16] = { 0x2000,0,0,0, 0,0x2000,0,0, 0,0,0x800,0x2000, 0,0,0,0 };
	gx(0x10, 0); load44(m);
	gx(0x10, 2); gx(0x15, 0); gx(0x10, 3); gx(0x15, 0); gx(0x10, 2);
}
static void vp2(int px, int py, s32 w)   // w = clip w (4.12), vertex z = w / 2
{
	vraw((s32)((s64)(px - 128) * w / 256), (s32)((s64)(96 - py) * w / 192), w / 2);
}
static void p_persp_xbig(void)
{
	proj2();
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	static const u16 wl[24] = { 0xFFFF, 0xFFFE, 0xF001, 0x8001, 0xFFFF, 0x4000, 0xC3A1, 0xFFF0,
	                            0x7FFF, 0x8000, 0xFFFF, 0x9999, 0x1001, 0xE00F, 0xFFFF, 0x5555,
	                            0xAAAA, 0xFFFF, 0x3333, 0xFEDC, 0x8421, 0xF0F0, 0x0F0F, 0xFFFF };
	static const u16 wr[24] = { 0x8000, 0xFFFF, 0xF000, 0x8000, 0x0101, 0xFFFF, 0x3A1C, 0xFFF1,
	                            0xFFFF, 0x7FFF, 0x5555, 0x6666, 0xFFFF, 0x0E00, 0x2000, 0xAAAA,
	                            0x5555, 0x0FFF, 0xCCCC, 0xCDEF, 0x1248, 0x0F0F, 0xF0F0, 0x7000 };
	for (int i = 0; i < 24; i++) {
		int y0 = i * 8, y1 = y0 + 7;
		s32 s0 = -16000 + i * 701, s1 = 16000 - i * 409;
		begin(1);
		tc(s0, i * 16); vp2(0, y0, wl[i]);
		tc(s0, i * 16); vp2(0, y1, wl[i]);
		tc(s1, i * 16); vp2(256, y1, wr[i]);
		tc(s1, i * 16); vp2(256, y0, wr[i]);
	}
}

// Clipping interpolation. Side planes, exact mapping: textured (huge
// texcoord ranges) and coloured triangles crossing each screen edge by
// fractional amounts.
static void p_clip_tex_side(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int k = 0; k < 16; k++) {
		int side = k & 3, d16 = 16 + k * 37;           // how far outside, 1/16 px
		int c = 20 + (k / 4) * 50;
		begin(0);
		if (side == 0) { tc(-30000, 0); vf(-d16, c * 16, 0); tc(20000, 5000); vf(60 * 16, (c - 20) * 16 + k, 0); tc(9000, -20000); vf(60 * 16, (c + 20) * 16, 0); }
		if (side == 1) { tc(30000, 100); vf(256 * 16 + d16, c * 16, 0); tc(-20000, 6000); vf(196 * 16, (c - 20) * 16 + k, 0); tc(-9000, -21000); vf(196 * 16, (c + 20) * 16, 0); }
		if (side == 2) { tc(-25000, -30000); vf((c + 30) * 16, -d16, 0); tc(15000, 20000); vf((c + 10) * 16 + k, 40 * 16, 0); tc(-5000, 25000); vf((c + 50) * 16, 40 * 16, 0); }
		if (side == 3) { tc(25000, 30000); vf((c + 30) * 16, 192 * 16 + d16, 0); tc(-15000, -20000); vf((c + 10) * 16 + k, 152 * 16, 0); tc(5000, -25000); vf((c + 50) * 16, 152 * 16, 0); }
	}
}
// Near and far planes (standard perspective): textured + coloured triangles
// crossing the near plane at several depths, and the far plane with far-plane
// clipping on (attribute bit 12).
static void p_clip_tex_nf(void)
{
	gx(0x10, 0); gx(0x15, 0);
	glMatrixMode(GL_PROJECTION); glLoadIdentity();
	gluPerspective(60, 256.0f / 192.0f, 0.5f, 6);
	gx(0x10, 2); gx(0x15, 0);
	teximg(TEX32(REP_S | REP_T));
	for (int k = 0; k < 8; k++) {
		bool far = k >= 4;
		attr(PA(31, 1 + k) | (far ? (1u << 12) : 0));
		float x = -1.4f + (k % 4) * 0.75f;
		float zn = far ? -(5.5f + k * 0.1f) : -(0.3f + k * 0.07f);
		float zf = far ? -9.0f : -3.0f;
		begin(0);
		col(31, 0, 0);  tc(-20000, 0);     vraw((s32)(x * 4096), (s32)(-0.4f * 4096), (s32)(zn * 4096));
		col(0, 31, 0);  tc(20000, 3000);   vraw((s32)((x + 0.6f) * 4096), (s32)(-0.4f * 4096), (s32)(zf * 4096));
		col(0, 0, 31);  tc(1000, -25000);  vraw((s32)(x * 4096), (s32)(0.5f * 4096), (s32)(zf * 4096));
	}
}

// Clip-factor probes (geometry session): 24 triangles per panel, one vertex
// outside one plane, huge S/T spans so the clipped vertices' texcoords show
// the factor's precision; the in/out distances vary so the factor is
// non-dyadic and its denominator spans 0x40 .. 0x8000.
static const s16 s_cin[24]  = { 16, 48, 80, 160, 333, 512, 700, 999, 1300, 2047, 3001, 4000,
                                5, 9, 27, 61, 123, 250, 555, 777, 1111, 1700, 2900, 3700 };
static const s16 s_cout[24] = { 3, 70, 13, 900, 11, 4000, 333, 1, 2222, 99, 5000, 777,
                                1234, 3, 99, 7, 2500, 63, 1, 4321, 33, 1500, 200, 2 };
// left plane, flat (affine): inside vertices at x = c_in px, outside at -c_out/16 px
static void p_clip_fac_x(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int k = 0; k < 24; k++) {
		int y = k * 8 + 1, in16 = s_cin[k] % 3000 + 16, out16 = s_cout[k];
		begin(0);
		tc(-32767 + k * 97, 32767 - k * 131); vf(-out16, y * 16 + 48, 0);
		tc(32767 - k * 53, -32767 + k * 71); vf(in16, y * 16, 0);
		tc(30000, 30000); vf(in16, y * 16 + 112, 0);
	}
}
// top plane, flat
static void p_clip_fac_y(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int k = 0; k < 24; k++) {
		int x = k * 10 + 2, in16 = s_cin[k] % 3000 + 16, out16 = s_cout[k];
		begin(0);
		tc(32767 - k * 97, -32767 + k * 131); vf(x * 16 + 64, -out16, 0);
		tc(-32767 + k * 53, 32767 - k * 71); vf(x * 16, in16, 0);
		tc(-30000, -30000); vf(x * 16 + 144, in16, 0);
	}
}
// left plane, perspective: the inside and outside vertices have different w
static void p_clip_fac_xp(void)
{
	proj(true);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int k = 0; k < 24; k++) {
		int y = k * 8 + 1;
		s32 win = 0x0400 + k * 0x2A1, wout = 0x7FFF - k * 0x31F;
		int out = 1 + s_cout[k] % 40;   // px outside
		begin(0);
		tc(-32767 + k * 97, 32767 - k * 131); vp(-out, y + 3, wout);
		tc(32767 - k * 53, -32767 + k * 71); vp(1 + s_cin[k] % 60, y, win);
		tc(30000, 30000); vp(1 + s_cin[k] % 60, y + 7, win);
	}
}
// near plane: projection w' = z, z' = 2z - 3, so the near plane is at w = 1;
// one vertex at w 0.06 .. 0.93 (outside), two at w 1.06 .. 2.93 (inside)
static void p_clip_fac_near(void)
{
	static const s32 m[16] = { 0x1000,0,0,0, 0,0x1000,0,0, 0,0,0x2000,0x1000, 0,0,-0x3000,0 };
	gx(0x10, 0); load44(m);
	gx(0x10, 2); gx(0x15, 0); gx(0x10, 3); gx(0x15, 0); gx(0x10, 2);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int k = 0; k < 24; k++) {
		int cx = (k % 6) * 42 + 4, cy = (k / 6) * 48 + 4;
		s32 win = 0x1100 + k * 0x14D, wout = 0x100 + (s_cout[k] * 7) % 0xE00;   // win 1.06 .. 2.93 (far plane at w = 3)
		begin(0);
		tc(-32767 + k * 97, 32767 - k * 131); vp(cx + 20, cy + 40, wout);
		tc(32767 - k * 53, -32767 + k * 71); vp(cx, cy, win);
		tc(30000, 30000); vp(cx + 36, cy, win);
	}
}

// v15, raster + geometry sessions: the clip_fac_* geometry, untextured
// Gouraud, so the clipped vertices' colours show the clip factor's
// precision for colour (the `clip` residual: red 1-2 LSB low in stripes).
// The outside vertex is (31, 1, 0), both inside vertices (0, 0, 31); odd k
// swap them. Per channel the deltas are 31 and 1, so the clipped colour
// sits near an integer boundary for many factors.
static void cc_out(int k) { if (k & 1) col(0, 0, 31); else col(31, 1, 0); }
static void cc_in(int k)  { if (k & 1) col(31, 1, 0); else col(0, 0, 31); }
static void p_clip_col_x(void)
{
	proj(false);
	attr(PA(31, 1));
	for (int k = 0; k < 24; k++) {
		int y = k * 8 + 1, in16 = s_cin[k] % 3000 + 16, out16 = s_cout[k];
		begin(0);
		cc_out(k); vf(-out16, y * 16 + 48, 0);
		cc_in(k);  vf(in16, y * 16, 0);
		cc_in(k);  vf(in16, y * 16 + 112, 0);
	}
}
static void p_clip_col_y(void)
{
	proj(false);
	attr(PA(31, 1));
	for (int k = 0; k < 24; k++) {
		int x = k * 10 + 2, in16 = s_cin[k] % 3000 + 16, out16 = s_cout[k];
		begin(0);
		cc_out(k); vf(x * 16 + 64, -out16, 0);
		cc_in(k);  vf(x * 16, in16, 0);
		cc_in(k);  vf(x * 16 + 144, in16, 0);
	}
}
static void p_clip_col_xp(void)
{
	proj(true);
	attr(PA(31, 1));
	for (int k = 0; k < 24; k++) {
		int y = k * 8 + 1;
		s32 win = 0x0400 + k * 0x2A1, wout = 0x7FFF - k * 0x31F;
		int out = 1 + s_cout[k] % 40;
		begin(0);
		cc_out(k); vp(-out, y + 3, wout);
		cc_in(k);  vp(1 + s_cin[k] % 60, y, win);
		cc_in(k);  vp(1 + s_cin[k] % 60, y + 7, win);
	}
}
static void p_clip_col_near(void)
{
	static const s32 m[16] = { 0x1000,0,0,0, 0,0x1000,0,0, 0,0,0x2000,0x1000, 0,0,-0x3000,0 };
	gx(0x10, 0); load44(m);
	gx(0x10, 2); gx(0x15, 0); gx(0x10, 3); gx(0x15, 0); gx(0x10, 2);
	attr(PA(31, 1));
	for (int k = 0; k < 24; k++) {
		int cx = (k % 6) * 42 + 4, cy = (k / 6) * 48 + 4;
		s32 win = 0x1100 + k * 0x14D, wout = 0x100 + (s_cout[k] * 7) % 0xE00;
		begin(0);
		cc_out(k); vp(cx + 20, cy + 40, wout);
		cc_in(k);  vp(cx, cy, win);
		cc_in(k);  vp(cx + 36, cy, win);
	}
}

// ---- v5 (geometry session: position vs attributes at the clip plane) ---------

// (1) Coverage only: the clip_fac_x / clip_fac_near geometry, flat white.
static void p_clip_cov_x(void)
{
	proj(false);
	attr(PA(31, 1));
	col(31, 31, 31);
	for (int k = 0; k < 24; k++) {
		int y = k * 8 + 1, in16 = s_cin[k] % 3000 + 16, out16 = s_cout[k];
		begin(0); vf(-out16, y * 16 + 48, 0); vf(in16, y * 16, 0); vf(in16, y * 16 + 112, 0);
	}
}
static void p_clip_cov_near(void)
{
	static const s32 m[16] = { 0x1000,0,0,0, 0,0x1000,0,0, 0,0,0x2000,0x1000, 0,0,-0x3000,0 };
	gx(0x10, 0); load44(m);
	gx(0x10, 2); gx(0x15, 0); gx(0x10, 3); gx(0x15, 0); gx(0x10, 2);
	attr(PA(31, 1));
	col(31, 31, 31);
	for (int k = 0; k < 24; k++) {
		int cx = (k % 6) * 42 + 4, cy = (k / 6) * 48 + 4;
		s32 win = 0x1100 + k * 0x14D, wout = 0x100 + (s_cout[k] * 7) % 0xE00;
		begin(0); vp(cx + 20, cy + 40, wout); vp(cx, cy, win); vp(cx + 36, cy, win);
	}
}
// (2) Attributes constant at the inside vertices, different only at the
// outside one; equal w (flat) and very different w (persp).
static void p_clip_attr_flat(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int k = 0; k < 24; k++) {
		int y = k * 8 + 1, in16 = s_cin[k] % 3000 + 16, out16 = s_cout[k];
		begin(0);
		tc(-32767 + k * 97, 32767 - k * 131); vf(-out16, y * 16 + 48, 0);
		tc(4000, 4000); vf(in16, y * 16, 0);
		tc(4000, 4000); vf(in16, y * 16 + 112, 0);
	}
}
static void p_clip_attr_persp(void)
{
	proj(true);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int k = 0; k < 24; k++) {
		int y = k * 8 + 1;
		s32 win = 0x0400 + k * 0x2A1, wout = 0x7FFF - k * 0x31F;
		int out = 1 + s_cout[k] % 40;
		begin(0);
		tc(-32767 + k * 97, 32767 - k * 131); vp(-out, y + 3, wout);
		tc(4000, 4000); vp(1 + s_cin[k] % 60, y, win);
		tc(4000, 4000); vp(1 + s_cin[k] % 60, y + 7, win);
	}
}
// (3) Dyadic vs non-dyadic clip factors (left plane, flat): inside vertex
// a px right of the plane, outside b px left; factor a / (a + b).
static void p_clip_dyadic(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	static const u8 ab[24][2] = { {16,16},{8,24},{24,8},{32,32},{4,12},{12,4},{64,64},{2,6},
	                              {16,48},{48,16},{1,1},{3,1},{5,10},{7,14},{1,2},{2,1},
	                              {3,4},{5,7},{11,13},{9,7},{17,19},{1,6},{6,1},{13,31} };
	for (int k = 0; k < 24; k++) {
		int a = ab[k][0], b = ab[k][1], y = k * 8 + 1;
		begin(0);
		tc(-20000 + k * 64, 20000 - k * 32); vfp(-b, y + 3, 0);
		tc(20000, -20000); vfp(a, y, 0);
		tc(20000, -20000 + 512); vfp(a, y + 7, 0);
	}
}
// (4) Clipped vs pre-clipped by hand: left half, triangles clipped by the
// left plane at factor 1/2 (outside vertex at -a, inside at +a, even
// texcoords so the clipped values are exact); right half, the same
// polygons translated 128 px and supplied already clipped (quads).
static void p_clip_vs_preclip(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int k = 0; k < 24; k++) {
		int a = 4 + (k % 8) * 8, y0 = k * 8 + 1;   // outside (-a, y0+4), inside (a, y0), (a, y0+7)
		s32 so = -16000 + k * 512, si = 16000 - k * 256, to = k * 1024, ti0 = 0, ti1 = 2048;
		// clipped
		begin(0);
		tc(so, to); vf(-a * 16, (y0 + 4) * 16, 0);
		tc(si, ti0); vf(a * 16, y0 * 16, 0);
		tc(si, ti1); vf(a * 16, (y0 + 7) * 16, 0);
		// pre-clipped: plane points at x = 0 are the midpoints of the two clipped edges
		begin(1);
		tc((so + si) / 2, (to + ti0) / 2); vf(128 * 16, (y0 * 2 + 4) * 8, 0);
		tc((so + si) / 2, (to + ti1) / 2); vf(128 * 16, (y0 * 2 + 11) * 8, 0);
		tc(si, ti1); vf((128 + a) * 16, (y0 + 7) * 16, 0);
		tc(si, ti0); vf((128 + a) * 16, y0 * 16, 0);
	}
}

// ---- v6 ---------------------------------------------------------------------

// Sub-pixel vertex positions without clipping: 24 bands of quads whose four
// vertices sit at 1/16-pixel offsets in x and y (different per corner and
// band), huge texcoord ranges (texel shows (s >> 4) & 31, (t >> 4) & 31).
static void p_subpix_tex(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int i = 0; i < 24; i++) {
		int y0 = i * 8 + 1, ox = i % 16, oy = (i * 7) % 16;
		begin(1);
		tc(-30000 + i * 311, -20000 + i * 97); vf(2 * 16 + ox, y0 * 16 + oy, 0);
		tc(-30000 + i * 311, 20000 - i * 53); vf(3 * 16 + 15 - ox, (y0 + 6) * 16 + 15 - oy, 0);
		tc(30000 - i * 211, 20000 - i * 53); vf(250 * 16 + oy, (y0 + 6) * 16 + ox, 0);
		tc(30000 - i * 211, -20000 + i * 97); vf(251 * 16 + 15 - oy, y0 * 16 + 15 - ox, 0);
	}
}
// The same with vertex colours (full-range ramps), untextured.
static void p_subpix_col(void)
{
	proj(false);
	attr(PA(31, 1));
	for (int i = 0; i < 24; i++) {
		int y0 = i * 8 + 1, ox = i % 16, oy = (i * 7) % 16;
		begin(1);
		col(0, 31, i); vf(2 * 16 + ox, y0 * 16 + oy, 0);
		col(0, 0, 31 - i); vf(3 * 16 + 15 - ox, (y0 + 6) * 16 + 15 - oy, 0);
		col(31, 0, i); vf(250 * 16 + oy, (y0 + 6) * 16 + ox, 0);
		col(31, 31, 31 - i); vf(251 * 16 + 15 - oy, y0 * 16 + 15 - ox, 0);
	}
}
// W-buffer depth ties with w >= 0x8000 along X (projection w' = 2z): 12
// bands, each a plane drawn as two triangulations (red, then green, less).
static void p_wbuf_big(void)
{
	proj2();
	static const u16 wa[12] = { 0xFFFE, 0xF000, 0x8000, 0xC000, 0xFFFE, 0x9000, 0xE000, 0x8800, 0xFFFE, 0xA000, 0xD000, 0x8000 };
	static const u16 wb[12] = { 0x2000, 0x8000, 0xFFFE, 0x4000, 0x8002, 0x1000, 0xE002, 0xFFFE, 0x0400, 0x7FFE, 0x3000, 0x8002 };
	for (int i = 0; i < 12; i++) {
		int y0 = i * 16, y1 = y0 + 15;
		s32 w0 = wa[i], w1 = wb[i];
		attr(PA(31, 1)); col(31, 0, 0);
		begin(0); vp2(0, y0, w0); vp2(0, y1, w0); vp2(256, y1, w1);
		begin(0); vp2(0, y0, w0); vp2(256, y1, w1); vp2(256, y0, w1);
		attr(PA(31, 2)); col(0, 31, 0);
		begin(0); vp2(0, y0, w0); vp2(0, y1, w0); vp2(256, y0, w1);
		begin(0); vp2(0, y1, w0); vp2(256, y1, w1); vp2(256, y0, w1);
	}
}

// Raster-session probes (melonDS: whole-pixel FinalPosition by truncating
// division; X-major negative-side edges set up on y0-1; span ends from edge
// X; slope from a reciprocal, special case ylen == xlen).
// (1) One small textured quad at x and y offsets 0..15/16, 16 copies per
// row; rows on both halves of the screen.
static void p_subpix_step(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int r = 0; r < 12; r++) {
		int y0 = r * 16 + 2;
		for (int o = 0; o < 16; o++) {
			int x0 = o * 16 + 2;
			int ox = (r & 1) ? o : 0, oy = (r & 1) ? 0 : o;
			if (r >= 8) { ox = o; oy = o; }
			begin(1);
			tc(0, 0);          vf(x0 * 16 + ox, y0 * 16 + oy, 0);
			tc(0, 9 * 256);    vf(x0 * 16 + ox, (y0 + 9) * 16 + oy, 0);
			tc(9 * 256, 9 * 256); vf((x0 + 9) * 16 + ox, (y0 + 9) * 16 + oy, 0);
			tc(9 * 256, 0);    vf((x0 + 9) * 16 + ox, y0 * 16 + oy, 0);
		}
	}
}
// (2) Edge attributes: triangles whose colour changes only along one edge,
// steep (y-major) and shallow (x-major), on the left and the right side,
// edges going down-left and down-right.
static void p_edge_attr(void)
{
	proj(false);
	attr(PA(31, 1));
	for (int k = 0; k < 32; k++) {
		int cx = (k % 8) * 32 + 2, cy = (k / 8) * 48 + 2;
		bool xmajor = k & 1, right = k & 2, leanl = k & 4;
		int dx = xmajor ? 26 : 5 + (k % 5), dy = xmajor ? 4 + (k % 3) : 40;
		int ax = leanl ? cx + dx : cx, bx = leanl ? cx : cx + dx;   // the coloured edge: a (top) -> b (bottom)
		begin(0);
		col(0, 0, 0); vfp(ax, cy, 0);
		col(31, 31, 31); vfp(bx, cy + dy, 0);
		col(0, 0, 0);   // third vertex on the other side of the edge
		if (right) vfp(leanl ? cx - 0 : cx, cy + dy, 0), (void)0; else vfp(leanl ? cx + dx : cx + dx, cy + dy + 2, 0);
	}
}
// (3) Short spans with wide ranges: thin triangles 2..9 px wide, colour 0..31
// and texcoord over thousands of texels across the span.
static void p_span_short(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int k = 0; k < 48; k++) {
		int cx = (k % 12) * 21 + 2, cy = (k / 12) * 48 + 2, w = 2 + k % 8;
		begin(0);
		tc(-30000 + k * 333, 0); vf(cx * 16 + (k * 5) % 16, cy * 16, 0);
		tc(30000 - k * 777, 0); vf((cx + w) * 16 + (k * 3) % 16, (cy + 20) * 16, 0);
		tc(-30000 + k * 333, 20000); vf(cx * 16, (cy + 40) * 16 + k % 16, 0);
	}
}
// (4) Edge slopes. Wide: melonDS's TODO case (x 169, y 33) and its
// neighbours, one per row, edges down-right and down-left. Square: ylen ==
// xlen (melonDS special case) at several sizes. Big: one 191 x 191.
static void slope_tri(int x0, int y0, int xl, int yl, bool left, int c)
{
	col(31, c & 31, 0);
	begin(0);
	if (!left) { vfp(x0, y0, 0); vfp(x0 + xl, y0 + yl, 0); vfp(x0, y0 + yl, 0); }
	else       { vfp(x0 + xl, y0, 0); vfp(x0 + xl, y0 + yl, 0); vfp(x0, y0 + yl, 0); }
}
static void p_slope_wide(void)
{
	proj(false);
	attr(PA(31, 1));
	static const u8 xy[5][2] = { {169,33},{168,33},{170,33},{169,32},{169,34} };
	for (int k = 0; k < 5; k++) slope_tri(2 + (k & 1) * 60, k * 38 + 1, xy[k][0], xy[k][1], k & 1, k * 7);
}
static void p_slope_square(void)
{
	proj(false);
	attr(PA(31, 1));
	slope_tri(1, 1, 33, 33, false, 0);  slope_tri(40, 1, 64, 64, true, 9);  slope_tri(110, 1, 100, 100, false, 18);
	slope_tri(1, 110, 1, 1, false, 3); slope_tri(10, 110, 2, 2, true, 6); slope_tri(20, 110, 7, 7, false, 12);
	slope_tri(40, 110, 64, 64, false, 21); slope_tri(120, 104, 81, 81, true, 27);
}
static void p_slope_big(void)
{
	proj(false);
	attr(PA(31, 1));
	slope_tri(30, 0, 191, 191, false, 0);
}

// ---- v7: Y-major AA coverage (raster session) --------------------------------
// One white triangle per cell over black (clear alpha 0, distinct IDs): the
// measured edge runs 40 lines; its total x run is dx16 / 16 px, leaning left
// or right; it is the triangle's left or right side; its start x steps
// through the 16 sub-pixel phases.
static void aa_y_cell(int cx, int cy, int dx16, int phase, bool lean_left, bool edge_is_left, int id)
{
	int ex0 = (cx + 10) * 16 + phase, ey0 = cy * 16, ey1 = (cy + 40) * 16;
	int ex1 = lean_left ? ex0 - dx16 : ex0 + dx16;
	int mid = (ex0 > ex1 ? ex0 : ex1);
	int far = edge_is_left ? mid + 10 * 16 : (ex0 < ex1 ? ex0 : ex1) - 10 * 16;
	attr(PA(31, id));
	begin(0);
	vf(ex0, ey0, 0); vf(ex1, ey1, 0); vf(far, (cy + 20) * 16, 0);
}
// slopes 1/16 .. 1 px per line on 24-line edges (dx 1.5 .. 24 px), 48-px
// cells, 20 per panel; panel b repeats with the other phases
static void aa_yfan_cell(int cx, int cy, int dx16, int phase, bool lean_left, bool edge_is_left, int id)
{
	int ex0 = (lean_left ? cx + 34 : cx + 8) * 16 + phase, ey0 = cy * 16, ey1 = (cy + 24) * 16;
	int ex1 = lean_left ? ex0 - dx16 : ex0 + dx16;
	int far = edge_is_left ? (ex0 > ex1 ? ex0 : ex1) + 8 * 16 : (ex0 < ex1 ? ex0 : ex1) - 8 * 16;
	if (far < cx * 16) far = cx * 16;
	if (far > (cx + 47) * 16) far = (cx + 47) * 16;
	attr(PA(31, id));
	begin(0);
	vf(ex0, ey0, 0); vf(ex1, ey1, 0); vf(far, (cy + 12) * 16, 0);
}
static void aa_yfan(int part)
{
	proj(false);
	col(31, 31, 31);
	for (int k = 0; k < 20; k++) {
		int kk = k + part * 20;
		int cx = (k % 5) * 51, cy = (k / 5) * 48 + 2;
		int dx16 = 24 + (kk * 379) % 361;    // 1.5 .. 24 px over 24 lines
		aa_yfan_cell(cx, cy, dx16, (kk * 3 + part * 8) % 16, kk & 1, (kk >> 1) & 1, (kk % 62) + 1);
	}
}
static void p_aa_yfan(void) { aa_yfan(0); }
static void p_aa_yfan_b(void) { aa_yfan(1); }
// near-vertical: dx 1/16 .. 2 px over 40 lines (Increment small, not 0)
static void p_aa_yvert(void)
{
	proj(false);
	col(31, 31, 31);
	for (int k = 0; k < 32; k++) {
		int cx = (k % 8) * 32, cy = (k / 8) * 48 + 2;
		int dx16 = 1 + (k * 7) % 32;          // 1/16 .. 2 px total
		aa_y_cell(cx, cy, dx16, (k * 5) % 16, k & 1, (k >> 1) & 1, (k % 62) + 1);
	}
}

// Exact-multiple spans at growing ranges (DS_LIN17 conflict): span length L
// (odd, 3 .. 25 px) with s rising by exactly 16*m texels per pixel (m from 1
// to ~150), so every pixel's exact s is an integer multiple; ranges from
// small up to ~60000 units. Rows: X spans; panel tex_exact_y: Y spans.
static void p_tex_exact(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int i = 0; i < 24; i++) {
		for (int c = 0; c < 4; c++) {
			int L = 3 + ((i + c * 5) % 12) * 2, m = 1 + (i * 4 + c * 37) % 150 ;
			if (L * 256 * m > 65000) m = 65000 / (L * 256);
			int x0 = c * 64 + 1, y0 = i * 8;
			s32 s0 = -32768 + (i * 911 + c * 4093) % 4096 * 16, s1 = s0 + L * 256 * m;
			if (s1 > 32767) { s1 = 32767 - ((32767 - s0) % (L * 256)); }
			begin(1);
			tc(s0, 0); vfp(x0, y0, 0); tc(s0, 0); vfp(x0, y0 + 7, 0);
			tc(s1, 0); vfp(x0 + L, y0 + 7, 0); tc(s1, 0); vfp(x0 + L, y0, 0);
		}
	}
}
static void p_tex_exact_y(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int j = 0; j < 32; j++) {
		for (int r = 0; r < 3; r++) {
			int L = 3 + ((j + r * 7) % 12) * 2, m = 1 + (j * 5 + r * 41) % 150;
			if (L * 256 * m > 65000) m = 65000 / (L * 256);
			int x0 = j * 8, y0 = r * 64 + 1;
			s32 t0 = -32768 + (j * 577 + r * 2111) % 4096 * 16, t1 = t0 + L * 256 * m;
			if (t1 > 32767) { t1 = 32767 - ((32767 - t0) % (L * 256)); }
			begin(1);
			tc(0, t0); vfp(x0, y0, 0); tc(0, t1); vfp(x0, y0 + L, 0);
			tc(0, t1); vfp(x0 + 7, y0 + L, 0); tc(0, t0); vfp(x0 + 7, y0, 0);
		}
	}
}

// ---- v8: long spans with large ranges (DS_TEXRND residual) -------------------
// X: 24 rows, span length L = 64 .. 255, range d = 16K .. 65K; even rows an
// exact multiple (16*m texel units per pixel), odd rows the same plus a
// non-multiple remainder. Y: 24 columns, L = 64 .. 191.
static s32 long_d(int L, int i)
{
	int m = 16384 / (16 * L) + (i * 7) % (65535 / (16 * L) - 16384 / (16 * L) + 1);
	if (m < 1) m = 1;
	s32 d = L * 16 * m;
	if (i & 1) d += (L * (3 + i % 5)) / 7;     // non-multiple
	if (d > 65535) d = 65535;
	return d;
}
static void p_tex_long(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int i = 0; i < 24; i++) {
		int L = 64 + (i * 83) % 192, y0 = i * 8;
		s32 d = long_d(L, i), s0 = -32768 + (i * 37 % 16) * 16;
		if (i & 2) s0 = 32767 - d + 1 - (i % 3) * 16;   // some descending-free offsets near the top end
		begin(1);
		tc(s0, 0); vfp(0, y0, 0); tc(s0, 0); vfp(0, y0 + 7, 0);
		tc(s0 + d, 0); vfp(L, y0 + 7, 0); tc(s0 + d, 0); vfp(L, y0, 0);
	}
}
static void p_tex_long_desc(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int i = 0; i < 24; i++) {
		int L = 64 + (i * 83) % 192, y0 = i * 8;
		s32 d = long_d(L, i + 1), s1 = 32767 - (i * 53 % 16) * 16;
		begin(1);
		tc(s1, 0); vfp(0, y0, 0); tc(s1, 0); vfp(0, y0 + 7, 0);
		tc(s1 - d, 0); vfp(L, y0 + 7, 0); tc(s1 - d, 0); vfp(L, y0, 0);
	}
}
static void p_tex_long_y(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int j = 0; j < 32; j++) {
		int L = 64 + (j * 61) % 128, x0 = j * 8;
		s32 d = long_d(L, j), t0 = (j & 4) ? 32767 - d + 1 : -32768 + (j * 29 % 16) * 16;
		bool desc = j & 8;
		begin(1);
		tc(0, desc ? t0 + d : t0); vfp(x0, 0, 0);
		tc(0, desc ? t0 : t0 + d); vfp(x0, L, 0);
		tc(0, desc ? t0 : t0 + d); vfp(x0 + 7, L, 0);
		tc(0, desc ? t0 + d : t0); vfp(x0 + 7, 0, 0);
	}
}

// ---- v9: endpoint sub-texel bits (raster session) -----------------------------
// Exact-multiple spans at fixed (L, d), start texcoord low bits swept 0..15.
// 4 configs x 16 sweeps = 64 spans: 32 rows of 6 px, 2 spans per row (x 0 and
// 128); configs: (L 105, s0 ~ +2400), (L 105, s0 ~ -30000), (L 63, s0 ~
// +10000), (L 117, s0 ~ -20000), each with d an exact multiple of 16 * L.
static const struct { u8 L; s16 base; u8 m; } s_lb[4] = { {105, 2400, 18}, {105, -30000, 30}, {63, 10000, 22}, {117, -20000, 28} };
static void p_tex_lowbits(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	for (int n = 0; n < 64; n++) {
		int cfg = n / 16, sw = n % 16, L = s_lb[cfg].L;
		s32 s0 = s_lb[cfg].base + sw, d = L * 16 * s_lb[cfg].m;
		int x0 = (n & 1) * 128, y0 = (n / 2) * 6;
		begin(1);
		tc(s0, 0); vfp(x0, y0, 0); tc(s0, 0); vfp(x0, y0 + 5, 0);
		tc(s0 + d, 0); vfp(x0 + L, y0 + 5, 0); tc(s0 + d, 0); vfp(x0 + L, y0, 0);
	}
}
// Y: the same with t, 32 columns of 8 px, 2 spans per column (y 0 and 96);
// L capped at 90 to fit.
static void p_tex_lowbits_y(void)
{
	proj(false);
	attr(PA(31, 1) | PA_DECAL);
	teximg(TEX32(REP_S | REP_T));
	static const struct { u8 L; s16 base; u8 m; } c[4] = { {89, 2400, 21}, {89, -30000, 36}, {63, 10000, 22}, {75, -20000, 40} };
	for (int n = 0; n < 64; n++) {
		int cfg = n / 16, sw = n % 16, L = c[cfg].L;
		s32 t0 = c[cfg].base + sw, d = L * 16 * c[cfg].m;
		int x0 = (n / 2) * 8, y0 = (n & 1) * 96;
		begin(1);
		tc(0, t0); vfp(x0, y0, 0); tc(0, t0 + d); vfp(x0, y0 + L, 0);
		tc(0, t0 + d); vfp(x0 + 7, y0 + L, 0); tc(0, t0); vfp(x0 + 7, y0, 0);
	}
}

// ---- v10: depth tie rules (raster session) -------------------------------------
// (a) wbuf_big's quads with both triangulations wound the same way (the
// second set reversed), separating melonDS's front/back tie-break.
static void p_wbuf_same(void)
{
	proj2();
	static const u16 wa[12] = { 0xFFFE, 0xF000, 0x8000, 0xC000, 0xFFFE, 0x9000, 0xE000, 0x8800, 0xFFFE, 0xA000, 0xD000, 0x8000 };
	static const u16 wb[12] = { 0x2000, 0x8000, 0xFFFE, 0x4000, 0x8002, 0x1000, 0xE002, 0xFFFE, 0x0400, 0x7FFE, 0x3000, 0x8002 };
	for (int i = 0; i < 12; i++) {
		int y0 = i * 16, y1 = y0 + 15;
		s32 w0 = wa[i], w1 = wb[i];
		attr(PA(31, 1)); col(31, 0, 0);
		begin(0); vp2(0, y0, w0); vp2(0, y1, w0); vp2(256, y1, w1);
		begin(0); vp2(0, y0, w0); vp2(256, y1, w1); vp2(256, y0, w1);
		attr(PA(31, 2)); col(0, 31, 0);
		begin(0); vp2(0, y0, w0); vp2(256, y0, w1); vp2(0, y1, w0);
		begin(0); vp2(0, y1, w0); vp2(256, y0, w1); vp2(256, y1, w1);
	}
}
// v11, raster session: the facing combinations of the w >= 0x8000 depth
// ties (both faces rendered). The melonDS blog (2018-10-27) says "less"
// accepts equal depth for a front-facing polygon over opaque back-facing
// pixels. tie_facing shows that zbuf_same's red triangles face front and its
// green ones back, so: zbuf_big = red front, green front; zbuf_same = red
// front, green back; rev_red reverses red (back, back); rev_both reverses
// both (red back, green front).
static void ties_facing(bool rev_red, bool rev_green)
{
	proj2();
	static const u16 wa[12] = { 0xFFFE, 0xF000, 0x8000, 0xC000, 0xFFFE, 0x9000, 0xE000, 0x8800, 0xFFFE, 0xA000, 0xD000, 0x8000 };
	static const u16 wb[12] = { 0x2000, 0x8000, 0xFFFE, 0x4000, 0x8002, 0x1000, 0xE002, 0xFFFE, 0x0400, 0x7FFE, 0x3000, 0x8002 };
	for (int i = 0; i < 12; i++) {
		int y0 = i * 16, y1 = y0 + 15;
		s32 w0 = wa[i], w1 = wb[i];
		attr(PA(31, 1)); col(31, 0, 0);
		if (!rev_red) {
			begin(0); vp2(0, y0, w0); vp2(0, y1, w0); vp2(256, y1, w1);
			begin(0); vp2(0, y0, w0); vp2(256, y1, w1); vp2(256, y0, w1);
		} else {
			begin(0); vp2(0, y0, w0); vp2(256, y1, w1); vp2(0, y1, w0);
			begin(0); vp2(0, y0, w0); vp2(256, y0, w1); vp2(256, y1, w1);
		}
		attr(PA(31, 2)); col(0, 31, 0);
		if (!rev_green) {
			begin(0); vp2(0, y0, w0); vp2(256, y0, w1); vp2(0, y1, w0);
			begin(0); vp2(0, y1, w0); vp2(256, y0, w1); vp2(256, y1, w1);
		} else {
			begin(0); vp2(0, y0, w0); vp2(0, y1, w0); vp2(256, y0, w1);
			begin(0); vp2(0, y1, w0); vp2(256, y1, w1); vp2(256, y0, w1);
		}
	}
}
static void p_ties_rev_red(void) { ties_facing(true, false); }
static void p_ties_rev_both(void) { ties_facing(true, true); }
// Which way zbuf_same's triangulations face: top half red's, bottom half
// green's, each drawn with front faces only (attr bit 7). melonDS: red
// shows, green doesn't.
static void p_tie_facing(void)
{
	proj2();
	gx(0x29, (31u << 16) | (1u << 24) | (1u << 7)); col(31, 0, 0);
	begin(0); vp2(0, 0, 0x4000); vp2(0, 95, 0x4000); vp2(256, 95, 0x4000);
	begin(0); vp2(0, 0, 0x4000); vp2(256, 95, 0x4000); vp2(256, 0, 0x4000);
	gx(0x29, (31u << 16) | (2u << 24) | (1u << 7)); col(0, 31, 0);
	begin(0); vp2(0, 96, 0x4000); vp2(256, 96, 0x4000); vp2(0, 191, 0x4000);
	begin(0); vp2(0, 191, 0x4000); vp2(256, 96, 0x4000); vp2(256, 191, 0x4000);
}
// depth_x with 1-line polygons: each band's only line is also its last, the
// line where depth_x's misses are (raster session, run 14).
static void p_depth_x1(void)
{
	proj(false);
	for (int i = 0; i < 24; i++) {
		int y0 = i * 8, y1 = y0 + 1;
		int lean = (i % 6) * 5 - 12;
		int xl0 = 8 * 16 + i * 3, xl1 = xl0 + lean;
		int xr0 = 248 * 16 - i * 7, xr1 = xr0 - lean;
		s32 zl = -0x2C00 + i * 211, zr = 0x2C00 - i * 397;
		attr(PA(31, 1)); col(31, 0, 0);
		begin(0); vf(xl0, y0 * 16, zl); vf(xl1, y1 * 16, zl); vf(xr1, y1 * 16, zr);
		begin(0); vf(xl0, y0 * 16, zl); vf(xr1, y1 * 16, zr); vf(xr0, y0 * 16, zr);
		attr(PA(31, 2)); col(0, 31, 0);
		begin(0); vf(xl0, y0 * 16, zl); vf(xl1, y1 * 16, zl); vf(xr0, y0 * 16, zr);
		begin(0); vf(xl1, y1 * 16, zl); vf(xr1, y1 * 16, zr); vf(xr0, y0 * 16, zr);
	}
}
// v12, raster session: the window of the facing rule (DS_ZFACE: front over
// back passes on z <= dst + 0x200, back over front needs z < dst - 0x200;
// GBATEK's depth-equal test has the same 0x200 tolerance). 12 bands; red is
// a flat quad at z0, green a quad whose depth ramps along X from z0 + a to
// z0 + b, so each column has its own separation. Z-buffer: identity
// projection (w = 1), one z unit = 0x800 in 24-bit depth; (a, b) = (-1, +1)
// (16 per pixel), (0, +1) and (-1, 0) (8 per pixel). W-buffer: proj2, red at
// w0, green from w0 + a to w0 + b with (a, b) = (-16, +16), (0, +16),
// (-16, 0) (1/4096 units). red_back: red faces back and green front (front
// over back), else the reverse.
static void tri_w(bool front, int x0, int y0, int x1, int y1, s32 dl, s32 dr, bool wbuf)
{
	// (x0, y0)-(x1, y1) quad, depth dl on the left, dr on the right; with
	// screen y down, (x0,y0),(x0,y1),(x1,y1) faces front (tie_facing).
	#define V(px, py, d) (wbuf ? vp2(px, py, d) : vraw((s32)((s64)((px) - 128) * 0x1000 / 128), (s32)((s64)(96 - (py)) * 0x1000 / 96), d))
	if (front) {
		begin(0); V(x0, y0, dl); V(x0, y1, dl); V(x1, y1, dr);
		begin(0); V(x0, y0, dl); V(x1, y1, dr); V(x1, y0, dr);
	} else {
		begin(0); V(x0, y0, dl); V(x1, y1, dr); V(x0, y1, dl);
		begin(0); V(x0, y0, dl); V(x1, y0, dr); V(x1, y1, dr);
	}
	#undef V
}
static void depth_window(bool red_back, bool wbuf)
{
	if (wbuf) proj2();
	else {
		s32 m[16] = { 0x1000,0,0,0, 0,0x1000,0,0, 0,0,0x1000,0, 0,0,0,0x1000 };
		gx(0x10, 0); load44(m);
		gx(0x10, 2); gx(0x15, 0); gx(0x10, 3); gx(0x15, 0); gx(0x10, 2);
	}
	static const s8 ra[3] = { -1, 0, -1 }, rb[3] = { 1, 1, 0 };
	for (int i = 0; i < 12; i++) {
		int y0 = i * 16 + 1, y1 = y0 + 14, t = i % 3;
		s32 d0 = wbuf ? 0x2000 + (i / 3) * 0x2800 + i * 7 : -40 + i * 7;
		s32 k = wbuf ? 16 : 1;
		attr(PA(31, 1)); col(31, 0, 0);
		tri_w(!red_back, 0, y0, 256, y1, d0, d0, wbuf);
		attr(PA(31, 2)); col(0, 31, 0);
		tri_w(red_back, 0, y0, 256, y1, d0 + ra[t] * k, d0 + rb[t] * k, wbuf);
	}
}
static void p_zwin_front_over_back(void) { depth_window(true, false); }
static void p_zwin_back_over_front(void) { depth_window(false, false); }
static void p_wwin_front_over_back(void) { depth_window(true, true); }
static void p_wwin_back_over_front(void) { depth_window(false, true); }
// zbuf_big's bands 9 and 10 alone (w 0xA000 / 0x7FFE and 0xD000 / 0x3000),
// both triangulations front-facing: run 15's same-facing residual sits there.
static void p_zbuf_big_b910(void)
{
	proj2();
	static const u16 wa[12] = { 0xFFFE, 0xF000, 0x8000, 0xC000, 0xFFFE, 0x9000, 0xE000, 0x8800, 0xFFFE, 0xA000, 0xD000, 0x8000 };
	static const u16 wb[12] = { 0x2000, 0x8000, 0xFFFE, 0x4000, 0x8002, 0x1000, 0xE002, 0xFFFE, 0x0400, 0x7FFE, 0x3000, 0x8002 };
	for (int i = 9; i <= 10; i++) {
		int y0 = i * 16, y1 = y0 + 15;
		s32 w0 = wa[i], w1 = wb[i];
		attr(PA(31, 1)); col(31, 0, 0);
		begin(0); vp2(0, y0, w0); vp2(0, y1, w0); vp2(256, y1, w1);
		begin(0); vp2(0, y0, w0); vp2(256, y1, w1); vp2(256, y0, w1);
		attr(PA(31, 2)); col(0, 31, 0);
		begin(0); vp2(0, y0, w0); vp2(0, y1, w0); vp2(256, y0, w1);
		begin(0); vp2(0, y1, w0); vp2(256, y1, w1); vp2(256, y0, w1);
	}
}
// v13, raster session: where interpolated Z itself differs from DS_LINZ. A
// flat plane at z0 drawn twice through different vertex sets: red with one
// diagonal, then green with the other, less test (zplane_less) or equal
// test (zplane_eq). Exact interpolation gives no green with less and all
// green with equal. 16x12 cells of 16x16 px; rows 0-3 w = 1, 4-7 w = 2,
// 8-11 w = 3 (identity projection, w' = w); in each, cell (k, col) has
// z0 = -2048 + (16k + col) * 64 (4.12).
static void zplane(bool eq)
{
	for (int g = 0; g < 3; g++) {
		s32 w = (g + 1) * 0x1000;
		s32 m[16] = { 0x1000,0,0,0, 0,0x1000,0,0, 0,0,0x1000,0, 0,0,0,w };
		gx(0x10, 0); load44(m);
		gx(0x10, 2); gx(0x15, 0); gx(0x10, 3); gx(0x15, 0); gx(0x10, 2);
		#define VQ(px, py, z) vraw((s32)((s64)((px) - 128) * w / 128), (s32)((s64)(96 - (py)) * w / 96), z)
		for (int k = 0; k < 4; k++)
			for (int c = 0; c < 16; c++) {
				int x0 = c * 16, y0 = (g * 4 + k) * 16, x1 = x0 + 16, y1 = y0 + 16;
				s32 z = -2048 + (16 * k + c) * 64;
				attr(PA(31, 1)); col(31, 0, 0);
				begin(0); VQ(x0, y0, z); VQ(x0, y1, z); VQ(x1, y1, z);
				begin(0); VQ(x0, y0, z); VQ(x1, y1, z); VQ(x1, y0, z);
				attr(PA(31, 2) | (eq ? PA_DEPTH_EQ : 0)); col(0, 31, 0);
				begin(0); VQ(x0, y0, z); VQ(x0, y1, z); VQ(x1, y0, z);
				begin(0); VQ(x0, y1, z); VQ(x1, y1, z); VQ(x1, y0, z);
			}
		#undef VQ
	}
}
static void p_zplane_less(void) { zplane(false); }
static void p_zplane_eq(void) { zplane(true); }
// v14, raster session: the size of the DS's Z offset at zplane_less's
// corner (a 1-px span at a triangle's top vertex). zcorner: zplane's quads
// with green raised by d z units, less test; rows 0-3 w = 16 (0x80 per unit
// in 24-bit depth), d = 0..3; rows 4-11 w = 32 (0x40 per unit), d = 1..8;
// columns z0 = -1024 + 128 * col. The d where the corner stops winning
// bounds the offset. ztip: red flat quads, then green triangles at the same
// z whose top vertex (rows 0-5) or bottom vertex (rows 6-11) makes a 1-px
// span; rows alternate w = 1 and w = 16, less test.
// v16: the projection scales x and y by w (m[0] = m[5] = m[15] = w) and the
// vertices stay in -1..1. v14/v15 scaled the vertex coordinates by w, which
// overflows VTX_16 at w = 16 and 32 (geometry session): run 20's zcorner
// and ztip w = 16 rows drew wrapped shapes.
static void identity_w(s32 w)
{
	s32 m[16] = { w,0,0,0, 0,w,0,0, 0,0,0x1000,0, 0,0,0,w };
	gx(0x10, 0); load44(m);
	gx(0x10, 2); gx(0x15, 0); gx(0x10, 3); gx(0x15, 0); gx(0x10, 2);
}
#define VQW(w, px, py, z) vraw((s32)((s64)((px) - 128) * 0x1000 / 128), (s32)((s64)(96 - (py)) * 0x1000 / 96), z)
static void p_zcorner(void)
{
	for (int r = 0; r < 12; r++) {
		s32 w = r < 4 ? 16 * 0x1000 : 32 * 0x1000, d = r < 4 ? r : r - 3;
		identity_w(w);
		for (int c = 0; c < 16; c++) {
			int x0 = c * 16, y0 = r * 16, x1 = x0 + 16, y1 = y0 + 16;
			s32 z = -1024 + 128 * c;
			attr(PA(31, 1)); col(31, 0, 0);
			begin(0); VQW(w, x0, y0, z); VQW(w, x0, y1, z); VQW(w, x1, y1, z);
			begin(0); VQW(w, x0, y0, z); VQW(w, x1, y1, z); VQW(w, x1, y0, z);
			attr(PA(31, 2)); col(0, 31, 0);
			begin(0); VQW(w, x0, y0, z + d); VQW(w, x0, y1, z + d); VQW(w, x1, y0, z + d);
			begin(0); VQW(w, x0, y1, z + d); VQW(w, x1, y1, z + d); VQW(w, x1, y0, z + d);
		}
	}
}
static void p_ztip(void)
{
	for (int r = 0; r < 12; r++) {
		s32 w = (r & 1) ? 16 * 0x1000 : 0x1000;
		bool top = r < 6;
		identity_w(w);
		for (int c = 0; c < 16; c++) {
			int x0 = c * 16, y0 = r * 16, x1 = x0 + 16, y1 = y0 + 16, xm = x0 + 4 + (c % 8);
			s32 z = -512 + 64 * c + 16 * r;
			attr(PA(31, 1)); col(31, 0, 0);
			begin(0); VQW(w, x0, y0, z); VQW(w, x0, y1, z); VQW(w, x1, y1, z);
			begin(0); VQW(w, x0, y0, z); VQW(w, x1, y1, z); VQW(w, x1, y0, z);
			attr(PA(31, 2)); col(0, 31, 0);
			if (top) { begin(0); VQW(w, xm, y0 + 2, z); VQW(w, x0 + 2, y1 - 2, z); VQW(w, x1 - 2, y1 - 2, z); }
			else     { begin(0); VQW(w, x0 + 2, y0 + 2, z); VQW(w, xm, y1 - 2, z); VQW(w, x1 - 2, y0 + 2, z); }
		}
	}
}
#undef VQW
// (b) Vertex Z rounding vs the tie test: 16x12 cells of 16x16 px; red quad
// at z1, then green at z2 = z1 + 1 (even rows) or z1 - 1 (odd rows), 4.12
// units, less test. Green shows where depth(z2) < depth(z1) after rounding.
// w = 1 (depth step 4 per z unit, no rounding) and w = 3 (z * 4 / 3, rounds).
static void zsweep(int w12)
{
	s32 m[16] = { 0x1000,0,0,0, 0,0x1000,0,0, 0,0,0x1000,0, 0,0,0,w12 };
	gx(0x10, 0); load44(m);
	gx(0x10, 2); gx(0x15, 0); gx(0x10, 3); gx(0x15, 0); gx(0x10, 2);
	for (int c = 0; c < 192; c++) {
		int cx = (c % 16) * 16, cy = (c / 16) * 16;
		s32 z1 = -96 + c * 1 + ((c / 16) & 1 ? 0 : 0), z2 = ((c / 16) & 1) ? z1 - 1 : z1 + 1;
		s32 w = w12;
		#define VQ(px, py, z) vraw((s32)((s64)((px) - 128) * w / 128), (s32)((s64)(96 - (py)) * w / 96), z)
		attr(PA(31, 1)); col(31, 0, 0);
		begin(1); VQ(cx + 1, cy + 1, z1); VQ(cx + 1, cy + 15, z1); VQ(cx + 15, cy + 15, z1); VQ(cx + 15, cy + 1, z1);
		attr(PA(31, 2)); col(0, 31, 0);
		begin(1); VQ(cx + 1, cy + 1, z2); VQ(cx + 1, cy + 15, z2); VQ(cx + 15, cy + 15, z2); VQ(cx + 15, cy + 1, z2);
		#undef VQ
	}
}
static void p_zsweep_w1(void) { zsweep(0x1000); }
static void p_zsweep_w3(void) { zsweep(0x3000); }

// v17, 0.3 renderer session (raster Q4): fog density precision, the
// >= 127 -> 128 clamp and small-Z fog alpha. A full-screen stack of 192
// one-line strips, strip k on line k, flat Z, untextured opaque green
// (0x03E0, alpha 31, polygon ID 1, fog bit set). w = 4.0 with an identity
// projection, so one Z step (4.12) is 0x200 in the 24-bit depth buffer:
// depth = (z + 0x3FFF) * 0x200. Fog colour 0x7C1F, fog alpha 20, the
// table below. Sub-panels (FOG_OFFSET, shift, target depth of strip k):
//   a 0x4000, 0,  0x700000 + k * 0x15555
//   b 0x4000, 4,  0x7F0000 + k * 0x1555
//   c 0x4000, 10, 0x7FFC00 + k * 0x200
//   d 0x0000, 0,  k * 0x400
// The programmed z per strip and its depth go to rules3d_fog_sweep.csv.
static const u8 s_fogtab[32] = { 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60, 64, 68, 72, 76,
                                 80, 84, 88, 92, 120, 124, 125, 126, 127, 127, 126, 127 };
static Buf s_fogcsv;
static void fog_sweep(char sub, u32 offset, u32 d0, u32 dk, u8 t0)
{
	u8 tab[32];
	memcpy(tab, s_fogtab, 32);
	tab[0] = t0;
	for (int i = 0; i < 32; i += 4)   // 32-bit writes: 3D registers may ignore byte writes
		REG32(0x04000360 + i) = tab[i] | tab[i + 1] << 8 | tab[i + 2] << 16 | (u32)tab[i + 3] << 24;
	REG32(0x04000358) = 0x7C1F | (20u << 16);
	REG16(0x0400035C) = offset;
	const s32 w = 0x4000;
	s32 m[16] = { 0x1000,0,0,0, 0,0x1000,0,0, 0,0,0x1000,0, 0,0,0,w };
	gx(0x10, 0); load44(m);
	gx(0x10, 2); gx(0x15, 0); gx(0x10, 3); gx(0x15, 0); gx(0x10, 2);
	attr(PA(31, 1) | (1u << 15));
	col(0, 31, 0);
	#define VQ(px, py, z) vraw((s32)((s64)((px) - 128) * w / 128), (s32)((s64)(96 - (py)) * w / 96), z)
	for (int k = 0; k < 192; k++) {
		u32 target = d0 + (u32)k * dk;
		if (target > 0xFFFFFF) target = 0xFFFFFF;
		s32 z = (s32)(target / 0x200) - 0x3FFF;
		if (z > 0x4000) z = 0x4000;
		if (z < -0x4000) z = -0x4000;
		s32 depth = (z + 0x3FFF) * 0x200;
		if (depth < 0) depth = 0;
		buf_printf(&s_fogcsv, "%c,%d,%06lx,%d,%d,%06lx\n", sub, k, (unsigned long)target, (int)z, (int)w,
		           (unsigned long)depth);
		begin(1); VQ(0, k, z); VQ(0, k + 1, z); VQ(256, k + 1, z); VQ(256, k, z);
	}
	#undef VQ
}
static void p_fog_a(void) { fog_sweep('a', 0x4000, 0x700000, 0x15555, 0); }
static void p_fog_b(void) { fog_sweep('b', 0x4000, 0x7F0000, 0x1555, 0); }
static void p_fog_c(void) { fog_sweep('c', 0x4000, 0x7FFC00, 0x200, 0); }
static void p_fog_d(void) { fog_sweep('d', 0x0000, 0, 0x400, 0); }
// v18 (run 30: d stayed in entry 0, density 0): d with T[0] = 64
static void p_fog_d2(void) { fog_sweep('D', 0x0000, 0, 0x400, 64); }
typedef struct { const char* name; void (*fn)(void); u32 disp3d; u32 swap; bool aa_bg; } Panel;
static const Panel s_panels[] = {
	{ "fill",         p_fill,         0 },
	{ "span",         p_span,         0 },
	{ "vert",         p_vert,         0 },
	{ "tris",         p_tris_gouraud, 0 },
	{ "tris_toon",    p_tris_toon,    0 },
	{ "tris_hilite",  p_tris_toon,    GL_TOON_HIGHLIGHT },
	{ "toon_span",    p_toon_span,    0 },
	{ "hilite_span",  p_toon_span,    GL_TOON_HIGHLIGHT },
	{ "persp_s",      p_persp_tex,    GL_TEXTURE_2D },
	{ "persp_t",      p_persp_tex_t,  GL_TEXTURE_2D },
	{ "persp_s_wbuf", p_persp_tex,    GL_TEXTURE_2D, GL_WBUFFERING },
	{ "tex_linear",   p_tex_linear,   GL_TEXTURE_2D },
	{ "aa",           p_aa,           GL_ANTIALIAS, 0, true },
	{ "aa_blend",     p_aa,           GL_ANTIALIAS | GL_BLEND, 0, true },
	{ "lines",        p_lines,        0 },
	{ "lines_aa",     p_lines,        GL_ANTIALIAS, 0, true },
	{ "clip",         p_clip,         0 },
	{ "clip_near",    p_clip_near,    0 },
	{ "depth",        p_depth,        0 },
	{ "depth_wbuf",   p_depth_w,      0, GL_WBUFFERING },
	{ "shadow",       p_shadow,       GL_BLEND, GL_TRANS_MANUALSORT },
	// v2
	{ "toon_vert",    p_toon_vert,    0 },
	{ "hilite_vert",  p_toon_vert,    GL_TOON_HIGHLIGHT },
	{ "toon_edges",   p_toon_edges,   0 },
	{ "hilite_edges", p_toon_edges,   GL_TOON_HIGHLIGHT },
	{ "aa_x",         p_aa_x,         GL_ANTIALIAS, 0, true },
	{ "aa_y",         p_aa_y,         GL_ANTIALIAS, 0, true },
	{ "depth2",       p_depth2,       0 },
	{ "clip_dir",     p_clip_dir,     0 },
	{ "tex_big_x",    p_tex_big_x,    GL_TEXTURE_2D },
	{ "tex_big_y",    p_tex_big_y,    GL_TEXTURE_2D },
	{ "tex_nearlin",  p_tex_nearlin,  GL_TEXTURE_2D },
	{ "tex_big_yslant", p_tex_big_yslant, GL_TEXTURE_2D },
	{ "col_big_y",    p_col_big_y,    0 },
	{ "depth_y",      p_depth_y,      0 },
	{ "depth_ycross", p_depth_ycross, 0 },
	{ "depth_yw",     p_depth_yw,     0, GL_WBUFFERING },
	// v3
	{ "persp_y_w",    p_persp_y_w,    GL_TEXTURE_2D },
	{ "persp_eqw",    p_persp_eqw,    GL_TEXTURE_2D },
	{ "depth_x",      p_depth_x,      0 },
	{ "depth_yw2",    p_depth_yw2,    0, GL_WBUFFERING },
	{ "aa_short",     p_aa_short,     GL_ANTIALIAS, 0, true },
	// v4
	{ "aa_xfan",      p_aa_xfan,      GL_ANTIALIAS, 0, true },
	{ "aa_sliver",    p_aa_sliver,    GL_ANTIALIAS, 0, true },
	{ "persp_xbig",   p_persp_xbig,   GL_TEXTURE_2D },
	{ "clip_tex_side", p_clip_tex_side, GL_TEXTURE_2D },
	{ "clip_tex_nf",  p_clip_tex_nf,  GL_TEXTURE_2D },
	{ "clip_fac_x",   p_clip_fac_x,   GL_TEXTURE_2D },
	{ "clip_fac_y",   p_clip_fac_y,   GL_TEXTURE_2D },
	{ "clip_fac_xp",  p_clip_fac_xp,  GL_TEXTURE_2D },
	{ "clip_fac_near", p_clip_fac_near, GL_TEXTURE_2D },
	// v5
	{ "clip_cov_x",   p_clip_cov_x,   0 },
	{ "clip_cov_near", p_clip_cov_near, 0 },
	{ "clip_attr_flat", p_clip_attr_flat, GL_TEXTURE_2D },
	{ "clip_attr_persp", p_clip_attr_persp, GL_TEXTURE_2D },
	{ "clip_dyadic",  p_clip_dyadic,  GL_TEXTURE_2D },
	{ "clip_vs_preclip", p_clip_vs_preclip, GL_TEXTURE_2D },
	// v6
	{ "subpix_tex",   p_subpix_tex,   GL_TEXTURE_2D },
	{ "subpix_col",   p_subpix_col,   0 },
	{ "wbuf_big",     p_wbuf_big,     0, GL_WBUFFERING },
	{ "zbuf_big",     p_wbuf_big,     0 },
	{ "subpix_step",  p_subpix_step,  GL_TEXTURE_2D },
	{ "edge_attr",    p_edge_attr,    0 },
	{ "span_short",   p_span_short,   GL_TEXTURE_2D },
	{ "slope_wide",   p_slope_wide,   0 },
	{ "slope_square", p_slope_square, 0 },
	{ "slope_big",    p_slope_big,    0 },
	// v7
	{ "aa_yfan",      p_aa_yfan,      GL_ANTIALIAS, 0, true },
	{ "aa_yfan_b",    p_aa_yfan_b,    GL_ANTIALIAS, 0, true },
	{ "aa_yvert",     p_aa_yvert,     GL_ANTIALIAS, 0, true },
	{ "tex_exact",    p_tex_exact,    GL_TEXTURE_2D },
	{ "tex_exact_y",  p_tex_exact_y,  GL_TEXTURE_2D },
	// v8
	{ "tex_long",     p_tex_long,     GL_TEXTURE_2D },
	{ "tex_long_desc", p_tex_long_desc, GL_TEXTURE_2D },
	{ "tex_long_y",   p_tex_long_y,   GL_TEXTURE_2D },
	// v9
	{ "tex_lowbits",  p_tex_lowbits,  GL_TEXTURE_2D },
	{ "tex_lowbits_y", p_tex_lowbits_y, GL_TEXTURE_2D },
	// v10
	{ "zbuf_same",    p_wbuf_same,    0 },
	{ "wbuf_same",    p_wbuf_same,    0, GL_WBUFFERING },
	{ "zbuf_back_back",  p_ties_rev_red,  0 },
	{ "zbuf_back_front", p_ties_rev_both, 0 },
	{ "wbuf_back_back",  p_ties_rev_red,  0, GL_WBUFFERING },
	{ "wbuf_back_front", p_ties_rev_both, 0, GL_WBUFFERING },
	{ "tie_facing",     p_tie_facing,     0 },
	{ "depth_x1",       p_depth_x1,       0 },
	{ "zsweep_w1",    p_zsweep_w1,    0 },
	{ "zsweep_w3",    p_zsweep_w3,    0 },
	{ "zwin_front_over_back", p_zwin_front_over_back, 0 },
	{ "zwin_back_over_front", p_zwin_back_over_front, 0 },
	{ "wwin_front_over_back", p_wwin_front_over_back, 0, GL_WBUFFERING },
	{ "wwin_back_over_front", p_wwin_back_over_front, 0, GL_WBUFFERING },
	{ "zbuf_big_b910",        p_zbuf_big_b910,        0 },
	{ "zplane_less",          p_zplane_less,          0 },
	{ "zplane_eq",            p_zplane_eq,            0 },
	{ "zcorner",              p_zcorner,              0 },
	{ "ztip",                 p_ztip,                 0 },
	{ "clip_col_x",           p_clip_col_x,           0 },
	{ "clip_col_y",           p_clip_col_y,           0 },
	{ "clip_col_xp",          p_clip_col_xp,          0 },
	{ "clip_col_near",        p_clip_col_near,        0 },
	// v17: fog on (bit 7), alpha blend (bit 3), shift in bits 8-11
	{ "fog_sweep_a",          p_fog_a,                0x0088 },
	{ "fog_sweep_b",          p_fog_b,                0x0488 },
	{ "fog_sweep_c",          p_fog_c,                0x0A88 },
	{ "fog_sweep_d",          p_fog_d,                0x0088 },
	{ "fog_sweep_d2",         p_fog_d2,               0x0088 },
};
#define NPANELS (int)(sizeof s_panels / sizeof s_panels[0])

static u16 s_cap[256 * 192];

static void capture(int srcA, const char* name, const char* suffix)
{
	swiWaitForVBlank();
	R_DISPCAP = DCAP_ENABLE | DCAP_MODE(DCAP_MODE_A) | DCAP_SRC_A(srcA) |
	            DCAP_SIZE(DCAP_SIZE_256x192) | DCAP_BANK(DCAP_BANK_VRAM_B);
	for (u32 i = 0; (R_DISPCAP & DCAP_ENABLE) && i < 20000000; i++) {}
	memcpy(s_cap, (void*)0x06820000, sizeof s_cap);
	char fn[64];
	snprintf(fn, sizeof fn, "rules3d_%s_%s.bin", name, suffix);
	hw_write(fn, s_cap, sizeof s_cap);
}

int main(void)
{
	hw_init(VERSION " - 3D rules");
	videoSetMode(MODE_0_3D);
	glInit();
	R_VRAMCNT(1) = 0x80;   // B: LCDC, capture destination
	make_texture();
	gx(0x60, 0 | (0 << 8) | (255 << 16) | (191u << 24));
	((vu16*)0x05000000)[0] = 0;               // black backdrop
	R_BLDCNT = (1 << 0) | (1 << 13) | (1 << 6);   // 3D over the backdrop
	R_BLDALPHA = 16;
	for (int i = 0; i < 32; i++) R_TOON(i) = RGB(i, 31 - i, (i * 7) & 31);   // encodes the index

	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\n", VERSION, __DATE__, __TIME__);
	buf_printf(&info, "format: 256x192 u16 LE, RGB555 + bit15; _3d = 3D only, _comp = 3D over the black backdrop\n");
	buf_printf(&info, "toon table: entry i = RGB(i, 31-i, (i*7)&31); texture: 32x32, texel (s,t) = RGB(s, t, 16)\n");
	buf_printf(&info, "panel,disp3dcnt,swap,clear_alpha0,gxstat\n");
	buf_printf(&s_fogcsv, "sub,strip,target_depth,z,w,depth\n");
	// Panels from here on aren't captured on the DS yet (update per batch).
	int first_new = 0;
	for (int i = 0; i < NPANELS; i++)
		if (!strcmp(s_panels[i].name, "fog_sweep_d2")) first_new = i;   // v18: fog_sweep_d2
	for (int i = hw_new_only ? first_new : 0; i < NPANELS; i++) {
		const Panel* p = &s_panels[i];
		iprintf("\x1b[8;0H%2d/%d %-16s", i + 1, NPANELS, p->name);
		R_DISP3DCNT = p->disp3d | GL_COLOR_UNDERFLOW | GL_POLY_OVERFLOW;
		bool fogp = !strncmp(p->name, "fog_sweep", 9);
		R_CLEARCOL = RGB(0, 0, 0) | ((p->aa_bg ? 0u : 31u) << 16) | ((fogp ? 0u : 63u) << 24) | (fogp ? 1u << 15 : 0);
		R_CLEARDEPTH = 0x7FFF;
		gx(0x2A, 0);
		// The SWAP parameter (W-buffer, manual sort) applies to the polygons
		// submitted after that SWAP, so latch it first with an empty frame.
		gx(0x50, p->swap);
		swiWaitForVBlank();
		p->fn();
		end();
		gx(0x50, p->swap);
		swiWaitForVBlank();
		swiWaitForVBlank();
		capture(DCAP_SRC_A_3DONLY, p->name, "3d");
		if (p->aa_bg) capture(DCAP_SRC_A_COMPOSITED, p->name, "comp");
		if (fogp) {   // 3D over a white backdrop: the blend shows the 3D alpha per line
			((vu16*)0x05000000)[0] = 0x7FFF;
			capture(DCAP_SRC_A_COMPOSITED, p->name, "comp_white");
			((vu16*)0x05000000)[0] = 0;
		}
		buf_printf(&info, "%s,%04lx,%lu,%d,%08lx\n", p->name, (unsigned long)p->disp3d,
		           (unsigned long)p->swap, p->aa_bg, (unsigned long)R_GXSTAT);
	}
	buf_write(&info, "rules3d_info.txt");
	if (s_fogcsv.len) buf_write(&s_fogcsv, "rules3d_fog_sweep.csv");
	hw_done();
}
