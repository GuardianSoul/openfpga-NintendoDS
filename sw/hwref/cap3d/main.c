// 3D capture reference. docs/hw-reference.md "cap3d".
//
// Each scene is submitted once and swapped in. Two frames later, display
// capture (DISPCAPCNT, source A, 256x192, into VRAM B) records the 3D layer
// alone, then the composited screen (3D on BG0 over BG1 and the backdrop).
// Both go to SD as raw little-endian RGB555 + bit 15 (256*192*2 bytes).
// Everything is deterministic: fixed geometry, fixed textures, and the same
// code (soft float included) on the DS and in the emulators.
#include "../common/hwref.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

#define VERSION "cap3d 3"
extern const unsigned char font8x8[64][8];

#define R_EDGE(i)     REG16(0x04000330 + 2 * (i))
#define R_ALPHAREF    REG16(0x04000340)
#define R_CLEARCOL    REG32(0x04000350)
#define R_CLEARDEPTH  REG16(0x04000354)
#define R_FOGCOLOR    REG32(0x04000358)
#define R_FOGOFFSET   REG16(0x0400035C)
#define R_FOGTABLE(i) REG8(0x04000360 + (i))
#define R_TOON(i)     REG16(0x04000380 + 2 * (i))
#define R_BG1CNT      REG16(0x0400000A)
#define R_BLDCNT      REG16(0x04000050)
#define R_BLDALPHA    REG16(0x04000052)

#define RGB(r, g, b) ((r) | ((g) << 5) | ((b) << 10))
#define PA_ALPHA(a) ((u32)(a) << 16)
#define PA_ID(i)    ((u32)(i) << 24)
#define PA_BOTH     (3u << 6)
#define PA_DEPTH_EQ (1u << 14)
#define PA_TRANS_DEPTH (1u << 11)

// Texture slot 0 (VRAM A) layout, byte offsets. Palettes in VRAM E.
enum { T_DIRECT = 0x0000, T_FONT = 0x2000, T_A3I5 = 0x2400, T_16 = 0x2800,
       T_256 = 0x2A00, T_A5I3 = 0x2E00 };
enum { P_FONT = 0x00, P_16 = 0x20, P_256 = 0x200, P_A3I5 = 0x400, P_A5I3 = 0x480 };

static u32 texparam(u32 off, int logs, int logt, int fmt, u32 flags)
{
	return (off >> 3) | ((u32)logs << 20) | ((u32)logt << 23) | ((u32)fmt << 26) | flags;
}
static void tex(u32 param, u32 palbyte, int fmt)
{
	GFX_TEX_FORMAT = param;
	GFX_PAL_FORMAT = fmt == 2 ? palbyte >> 3 : palbyte >> 4;
}
static void notex(void) { GFX_TEX_FORMAT = 0; }

static void make_textures(void)
{
	R_VRAMCNT(0) = 0x80;   // A: LCDC while writing
	R_VRAMCNT(4) = 0x80;   // E: LCDC
	// Built in RAM and copied with 16-bit writes: VRAM ignores byte writes.
	static u8 img[0x3000] __attribute__((aligned(4)));
	u16* t16 = (u16*)img;
	u8* t8 = img;
	memset(img, 0, sizeof img);
	// 64x64 direct colour: every texel distinct, bit 15 set.
	for (int v = 0; v < 64; v++)
		for (int u = 0; u < 64; u++)
			t16[(T_DIRECT >> 1) + v * 64 + u] =
				0x8000 | RGB(u >> 1, v >> 1, ((u ^ v) & 7) * 4 + ((u + v) & 3));
	// 128x32 font, 4 colours (0 transparent, 1 ink, 2 shadow).
	for (int g = 0; g < 64; g++)
		for (int y = 0; y < 8; y++)
			for (int x = 0; x < 8; x++) {
				bool ink = font8x8[g][y] & (0x80 >> x);
				bool sh = x && y && (font8x8[g][y - 1] & (0x80 >> (x - 1)));
				int c = ink ? 1 : sh ? 2 : 0;
				int tx = (g % 16) * 8 + x, ty = (g / 16) * 8 + y, idx = ty * 128 + tx;
				t8[T_FONT + idx / 4] |= c << ((idx & 3) * 2);
			}
	// 32x32 A3I5, 16-colour, 256-colour, A5I3.
	for (int v = 0; v < 32; v++)
		for (int u = 0; u < 32; u++) {
			int i = v * 32 + u;
			t8[T_A3I5 + i] = (u & 31) | ((v >> 2) << 5);
			if (!(u & 1)) t8[T_16 + i / 2] = ((u ^ v) & 15) | (((u + 1 + v) & 15) << 4);
			t8[T_256 + i] = (u * 8 + v) & 255;
			t8[T_A5I3 + i] = (u & 7) | ((v) << 3);
		}
	for (unsigned i = 0; i < sizeof img / 2; i++) ((vu16*)0x06800000)[i] = t16[i];
	vu16* pal = (vu16*)0x06880000;
	pal[P_FONT / 2 + 0] = 0;
	pal[P_FONT / 2 + 1] = RGB(31, 31, 31);
	pal[P_FONT / 2 + 2] = RGB(2, 2, 6);
	pal[P_FONT / 2 + 3] = RGB(31, 0, 0);
	for (int i = 0; i < 16; i++) pal[P_16 / 2 + i] = RGB(i * 2, 31 - i * 2, (i * 5) & 31);
	for (int i = 0; i < 256; i++) pal[P_256 / 2 + i] = RGB(i & 31, (i >> 3) & 31, 31 - (i & 31));
	for (int i = 0; i < 32; i++) pal[P_A3I5 / 2 + i] = RGB(i, 31 - i, 16);
	for (int i = 0; i < 8; i++) pal[P_A5I3 / 2 + i] = RGB(i * 4, 16, 31 - i * 4);
	R_VRAMCNT(0) = 0x83;   // A: texture slot 0
	R_VRAMCNT(4) = 0x83;   // E: texture palette slots 0-3
}

// BG1 behind the 3D layer: 4bpp tiles in VRAM D (main BG), a checker of two
// tiles with a diagonal stripe, so AA and translucency over 2D are visible.
static void make_bg(void)
{
	R_VRAMCNT(3) = 0x81;   // D: main BG at 0x06000000
	vu16* chr = (vu16*)0x06000000;     // char base 0
	vu16* map = (vu16*)0x06008000;     // screen base 16
	for (int t = 0; t < 2; t++)
		for (int y = 0; y < 8; y++)
			for (int x = 0; x < 8; x += 4) {
				u16 w = 0;
				for (int k = 0; k < 4; k++) {
					int px = x + k;
					int c = t ? 2 : 1;
					if (px == y || px == 7 - y) c = 3;
					w |= c << (k * 4);
				}
				chr[t * 16 + y * 2 + x / 4] = w;
			}
	for (int i = 0; i < 32 * 32; i++) map[i] = ((i % 32) + (i / 32)) & 1;
	vu16* bgpal = (vu16*)0x05000000;
	bgpal[0] = RGB(4, 0, 8);   // backdrop
	bgpal[1] = RGB(31, 24, 0);
	bgpal[2] = RGB(0, 12, 24);
	bgpal[3] = RGB(31, 31, 31);
	R_BG1CNT = (1 << 0) | (0 << 2) | (16 << 8);  // priority 1, char 0, screen 16, 4bpp 256x256
	R_BLDCNT = (1 << 0) | (1 << 9) | (1 << 13) | (1 << 6);
	R_BLDALPHA = 16;
}

// ---- geometry helpers -----------------------------------------------------

#define F(x) ((int)((x) * 4096))
static void v3(float x, float y, float z) { glVertex3v16(F(x), F(y), F(z)); }
static void col(int r, int g, int b) { glColor3b(r * 8 + 4, g * 8 + 4, b * 8 + 4); }
static void tc(int s, int t) { glTexCoord2t16(s << 4, t << 4); }
static void polyfmt(u32 a) { glPolyFmt(a); }

static void persp(void)
{
	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	gluPerspective(60, 256.0f / 192.0f, 0.1f, 40);
	glMatrixMode(GL_MODELVIEW);
	glLoadIdentity();
}
// Ortho: 1 unit = 32 pixels, origin top-left.
static void ortho(void)
{
	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	glOrthof32(0, inttof32(8), inttof32(6), 0, inttof32(-4), inttof32(4));
	glMatrixMode(GL_MODELVIEW);
	glLoadIdentity();
}
static void vpx(int x, int y, int z) { glVertex3v16(x * 128, y * 128, z); }

static void quad_px(int x0, int y0, int x1, int y1, int z)
{
	glBegin(GL_QUADS);
	vpx(x0, y0, z); vpx(x0, y1, z); vpx(x1, y1, z); vpx(x1, y0, z);
	glEnd();
}
static void textq_px(int x0, int y0, int w, int h, int s0, int t0, int s1, int t1)
{
	glBegin(GL_QUADS);
	tc(s0, t0); vpx(x0, y0, 0);
	tc(s0, t1); vpx(x0, y0 + h, 0);
	tc(s1, t1); vpx(x0 + w, y0 + h, 0);
	tc(s1, t0); vpx(x0 + w, y0, 0);
	glEnd();
}
static void text_px(int x, int y, int scale, const char* s)
{
	tex(texparam(T_FONT, 4, 2, 2, GL_TEXTURE_COLOR0_TRANSPARENT), P_FONT, 2);
	for (; *s; s++, x += 8 * scale) {
		int g = (*s >= 0x20 && *s < 0x60) ? *s - 0x20 : 0;
		int s0 = (g % 16) * 8, t0 = (g / 16) * 8;
		textq_px(x, y, 8 * scale, 8 * scale, s0, t0, s0 + 8, t0 + 8);
	}
}
// A unit quad in the XY plane, textured 0..n texels.
static void texquad(float s, int n)
{
	glBegin(GL_QUADS);
	tc(0, 0); v3(-s, s, 0);
	tc(0, n); v3(-s, -s, 0);
	tc(n, n); v3(s, -s, 0);
	tc(n, 0); v3(s, s, 0);
	glEnd();
}

// ---- scenes ----------------------------------------------------------------

typedef struct { const char* name; void (*fn)(void); u32 disp3d; u32 swap; bool bg1; } Scene;

static void sc_gouraud(void)
{
	persp();
	glTranslatef32(0, 0, F(-3));
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(1));
	glBegin(GL_TRIANGLES);
	col(31, 0, 0); v3(-1.6f, -1.1f, 0);
	col(0, 31, 0); v3(1.4f, -0.9f, 0);
	col(0, 0, 31); v3(-0.2f, 1.3f, 0);
	glEnd();
	// slivers: a fan of thin triangles
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(2));
	glBegin(GL_TRIANGLES);
	for (int i = 0; i < 12; i++) {
		float a = i * 0.13f, b = a + 0.02f;
		col(31, 31, i * 2); v3(1.0f, 1.0f, 0.2f);
		col(i * 2, 31, 31); v3(1.0f + 1.2f * cosf(a + 3.3f), 1.0f + 1.2f * sinf(a + 3.3f), 0.2f);
		v3(1.0f + 1.2f * cosf(b + 3.3f), 1.0f + 1.2f * sinf(b + 3.3f), 0.2f);
	}
	glEnd();
}

static int s_angle;
static void sc_tex_persp(void)
{
	persp();
	glTranslatef32(0, F(-0.3), F(-2.5));
	glRotateXi(degreesToAngle(-s_angle));
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(1));
	tex(texparam(T_DIRECT, 3, 3, 7, GL_TEXTURE_WRAP_S | GL_TEXTURE_WRAP_T), 0, 7);
	col(31, 31, 31);
	glBegin(GL_QUADS);
	tc(0, 0); v3(-2, 0, -2);
	tc(0, 256); v3(-2, 0, 2);
	tc(256, 256); v3(2, 0, 2);
	tc(256, 0); v3(2, 0, -2);
	glEnd();
}
static void sc_persp_00(void) { s_angle = 90; sc_tex_persp(); }
static void sc_persp_30(void) { s_angle = 60; sc_tex_persp(); }
static void sc_persp_60(void) { s_angle = 30; sc_tex_persp(); }
static void sc_persp_80(void) { s_angle = 10; sc_tex_persp(); }

static void sc_tex_seam(void)
{
	persp();
	glTranslatef32(0, 0, F(-3));
	glRotateYi(degreesToAngle(25));
	glRotateXi(degreesToAngle(-30));
	col(31, 31, 31);
	for (int j = 0; j < 4; j++)
		for (int i = 0; i < 4; i++) {
			polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(1 + j * 4 + i));
			u32 fl = (i & 1) ? (GL_TEXTURE_WRAP_S | GL_TEXTURE_FLIP_S) : 0;
			if (j & 1) fl |= GL_TEXTURE_WRAP_T | GL_TEXTURE_FLIP_T;
			tex(texparam(T_DIRECT, 3, 3, 7, fl), 0, 7);
			float x0 = -1.2f + i * 0.6f, y0 = -1.2f + j * 0.6f;
			glBegin(GL_QUADS);
			tc(0, 0); v3(x0, y0 + 0.6f, 0);
			tc(0, 64 + (j & 1) * 64); v3(x0, y0, 0);
			tc(64 + (i & 1) * 64, 64 + (j & 1) * 64); v3(x0 + 0.6f, y0, 0);
			tc(64 + (i & 1) * 64, 0); v3(x0 + 0.6f, y0 + 0.6f, 0);
			glEnd();
		}
}

static void sc_tex_formats(void)
{
	persp();
	glTranslatef32(0, 0, F(-2.4));
	struct { u32 off; int fmt; u32 pal; int logs; } t[6] = {
		{ T_A3I5, 1, P_A3I5, 2 }, { T_FONT, 2, P_FONT, 4 }, { T_16, 3, P_16, 2 },
		{ T_256, 4, P_256, 2 }, { T_A5I3, 6, P_A5I3, 2 }, { T_DIRECT, 7, 0, 3 },
	};
	col(31, 31, 31);
	for (int k = 0; k < 6; k++) {
		polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(1 + k));
		int logt = t[k].fmt == 2 ? 2 : t[k].logs;
		tex(texparam(t[k].off, t[k].logs, logt, t[k].fmt, 0), t[k].pal, t[k].fmt);
		glPushMatrix();
		glTranslatef32(F(-1.0f + (k % 3) * 1.0f), F(0.5f - (k / 3) * 1.0f), 0);
		glRotateZi(degreesToAngle(k * 7));
		int n = 8 << t[k].logs;
		glBegin(GL_QUADS);
		tc(0, 0); v3(-0.45f, 0.45f, 0);
		tc(0, 8 << logt); v3(-0.45f, -0.45f, 0);
		tc(n, 8 << logt); v3(0.45f, -0.45f, 0);
		tc(n, 0); v3(0.45f, 0.45f, 0);
		glEnd();
		glPopMatrix(1);
	}
}

static void sc_tex_blend(void)
{
	persp();
	glTranslatef32(0, 0, F(-2.4));
	static const u32 modes[4] = { 0 << 4, 1 << 4, 0 << 4, 1 << 4 };
	for (int k = 0; k < 4; k++) {
		polyfmt(PA_ALPHA(k < 2 ? 31 : 20) | PA_BOTH | PA_ID(1 + k) | modes[k]);
		if (k < 2) tex(texparam(T_DIRECT, 3, 3, 7, 0), 0, 7);
		else tex(texparam(T_A5I3, 2, 2, 6, 0), P_A5I3, 6);
		glPushMatrix();
		glTranslatef32(F(-0.75f + (k % 2) * 1.5f), F(0.55f - (k / 2) * 1.1f), 0);
		int n = k < 2 ? 64 : 32;
		glBegin(GL_QUADS);
		col(31, 0, 0); tc(0, 0); v3(-0.6f, 0.5f, 0);
		col(0, 31, 0); tc(0, n); v3(-0.6f, -0.5f, 0);
		col(0, 0, 31); tc(n, n); v3(0.6f, -0.5f, 0);
		col(31, 31, 0); tc(n, 0); v3(0.6f, 0.5f, 0);
		glEnd();
		glPopMatrix(1);
	}
}

static void depth_scene(void)
{
	persp();
	glTranslatef32(0, 0, F(-3));
	glRotateYi(degreesToAngle(35));
	notex();
	// A then B coplanar (B loses with the default less test)
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(1));
	col(31, 0, 0);
	glBegin(GL_QUADS); v3(-1.4f, 1, 0); v3(-1.4f, 0, 0); v3(0, 0, 0); v3(0, 1, 0); glEnd();
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(2));
	col(0, 31, 0);
	glBegin(GL_QUADS); v3(-1.0f, 1.2f, 0); v3(-1.0f, 0.2f, 0); v3(0.4f, 0.2f, 0); v3(0.4f, 1.2f, 0); glEnd();
	// C coplanar with the equal test (wins where depths tie)
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(3) | PA_DEPTH_EQ);
	col(0, 0, 31);
	glBegin(GL_QUADS); v3(-0.7f, 0.8f, 0); v3(-0.7f, -0.2f, 0); v3(0.7f, -0.2f, 0); v3(0.7f, 0.8f, 0); glEnd();
	// two interpenetrating planes at a shallow angle
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(4));
	col(31, 31, 0);
	glBegin(GL_QUADS); v3(-1.5f, -0.3f, -0.4f); v3(-1.5f, -1.3f, -0.4f); v3(1.5f, -1.3f, 0.4f); v3(1.5f, -0.3f, 0.4f); glEnd();
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(5));
	col(0, 31, 31);
	glBegin(GL_QUADS); v3(-1.5f, -0.3f, 0.35f); v3(-1.5f, -1.3f, 0.35f); v3(1.5f, -1.3f, -0.35f); v3(1.5f, -0.3f, -0.35f); glEnd();
	// far-away coplanar pair (depth precision)
	glTranslatef32(0, 0, F(-20));
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(6));
	col(31, 0, 31);
	glBegin(GL_QUADS); v3(2, 6, 0); v3(2, 2, 0); v3(8, 2, 0); v3(8, 6, 0); glEnd();
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(7) | PA_DEPTH_EQ);
	col(31, 31, 31);
	glBegin(GL_QUADS); v3(4, 7, 0); v3(4, 3, 0); v3(7, 3, 0); v3(7, 7, 0); glEnd();
}

static void aa_tris(bool translucent_bg)
{
	persp();
	glTranslatef32(0, 0, F(-3));
	notex();
	if (translucent_bg) {
		polyfmt(PA_ALPHA(14) | PA_BOTH | PA_ID(10));
		col(0, 20, 31);
		glBegin(GL_QUADS); v3(-1.8f, 0.4f, -0.5f); v3(-1.8f, -1.4f, -0.5f); v3(1.8f, -1.4f, -0.5f); v3(1.8f, 0.4f, -0.5f); glEnd();
	}
	for (int i = 0; i < 8; i++) {
		polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(1 + i));
		float a = i * 0.39f;
		float cx = -1.5f + (i % 4) * 1.0f, cy = 0.6f - (i / 4) * 1.2f;
		col(31, i * 4, 31 - i * 4);
		glBegin(GL_TRIANGLES);
		v3(cx + 0.45f * cosf(a), cy + 0.45f * sinf(a), 0);
		v3(cx + 0.45f * cosf(a + 2.2f), cy + 0.45f * sinf(a + 2.2f), 0);
		v3(cx + 0.45f * cosf(a + 4.0f), cy + 0.45f * sinf(a + 4.0f), 0);
		glEnd();
	}
	// translucent in front of opaque
	polyfmt(PA_ALPHA(18) | PA_BOTH | PA_ID(20));
	col(31, 31, 0);
	glBegin(GL_TRIANGLES); v3(-0.3f, 1.2f, 0.3f); v3(-1.2f, -0.2f, 0.3f); v3(0.9f, -0.5f, 0.3f); glEnd();
}
static void sc_aa_opaque(void) { aa_tris(false); }
static void sc_aa_translucent(void) { aa_tris(true); }

static void sc_ui_text(void)
{
	ortho();
	notex();
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(1));
	col(6, 6, 14);
	quad_px(8, 8, 248, 60, -64);
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(2));
	col(31, 31, 31);
	text_px(16, 16, 1, "HELLO 3D 0123456789");
	text_px(16, 28, 1, "ABCDEFGHIJKLMNOPQRSTUVWXYZ");
	text_px(16, 40, 2, "SCALE X2 !?");
	// translucent panels and 1-pixel shapes
	notex();
	for (int i = 0; i < 4; i++) {
		polyfmt(PA_ALPHA(8 + i * 6) | PA_BOTH | PA_ID(3 + i));
		col(31, i * 8, 0);
		quad_px(16 + i * 56, 72, 64 + i * 56, 120, 32);
	}
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(8));
	col(0, 31, 0);
	for (int i = 0; i < 16; i++) quad_px(16 + i * 14, 132, 17 + i * 14, 133, 16);  // 1x1
	col(31, 31, 0);
	glBegin(GL_TRIANGLES);   // lines: degenerate triangles
	for (int i = 0; i < 8; i++) { vpx(16 + i * 28, 140, 16); vpx(36 + i * 28, 180, 16); vpx(36 + i * 28, 180, 16); }
	glEnd();
	text_px(160, 150, 1, "UI TEXT");
}

static void fog_rows(void)
{
	persp();
	glTranslatef32(0, F(-0.6), F(-1.5));
	notex();
	for (int i = 0; i < 10; i++) {
		polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(1 + i) | POLY_FOG);
		col(31 - i * 3, i * 3, 16);
		float z = -i * 1.6f;
		float x = -1.6f + (i % 2) * 1.6f;
		glBegin(GL_QUADS); v3(x, 1.0f, z); v3(x, 0, z); v3(x + 1.5f, 0, z); v3(x + 1.5f, 1.0f, z); glEnd();
	}
	// one quad without the fog flag
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(30));
	col(31, 31, 31);
	glBegin(GL_QUADS); v3(1.2f, -0.2f, -8); v3(1.2f, -1.2f, -8); v3(2.4f, -1.2f, -8); v3(2.4f, -0.2f, -8); glEnd();
}

static void toon_scene(void)
{
	persp();
	glTranslatef32(0, 0, F(-3));
	notex();
	for (int i = 0; i < 3; i++) {
		polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(1 + i) | POLY_TOON_HIGHLIGHT);
		float x = -1.5f + i * 1.05f;
		glBegin(GL_QUADS);
		col(0, 0, 0); v3(x, 1, 0);
		col(i == 0 ? 31 : 0, i == 1 ? 31 : 0, i == 2 ? 31 : 0); v3(x, -1, 0);
		col(31, 31, 31); v3(x + 1, -1, 0);
		col(16, 8, 4); v3(x + 1, 1, 0);
		glEnd();
	}
	// textured with toon
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(5) | POLY_TOON_HIGHLIGHT);
	tex(texparam(T_DIRECT, 3, 3, 7, 0), 0, 7);
	glPushMatrix();
	glTranslatef32(F(1.7f), 0, 0);
	col(20, 10, 31);
	texquad(0.5f, 64);
	glPopMatrix(1);
}

static void sc_edge(void)
{
	persp();
	glTranslatef32(0, 0, F(-3));
	notex();
	for (int i = 0; i < 8; i++) {
		polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(i * 8 + (i & 1)));
		col(8 + i * 3, 31 - i * 3, 12);
		float x = -1.6f + (i % 4) * 0.8f, y = 0.9f - (i / 4) * 0.9f;
		glBegin(GL_QUADS); v3(x, y, -i * 0.05f); v3(x, y - 1.0f, -i * 0.05f); v3(x + 1.0f, y - 1.0f, -i * 0.05f); v3(x + 1.0f, y, -i * 0.05f); glEnd();
	}
	// same-ID neighbours (no edge between them)
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(40));
	col(31, 31, 31);
	glBegin(GL_QUADS); v3(-1.6f, -1.0f, 0.2f); v3(-1.6f, -1.4f, 0.2f); v3(0, -1.4f, 0.2f); v3(0, -1.0f, 0.2f); glEnd();
	glBegin(GL_QUADS); v3(0, -1.0f, 0.2f); v3(0, -1.4f, 0.2f); v3(1.6f, -1.4f, 0.2f); v3(1.6f, -1.0f, 0.2f); glEnd();
	// translucent over edges
	polyfmt(PA_ALPHA(12) | PA_BOTH | PA_ID(50));
	col(0, 0, 31);
	glBegin(GL_TRIANGLES); v3(0.2f, 1.3f, 0.4f); v3(-0.8f, -0.6f, 0.4f); v3(1.4f, -0.2f, 0.4f); glEnd();
}

static void sc_lighting(void)
{
	persp();
	glTranslatef32(0, 0, F(-3));
	glLight(0, RGB(31, 31, 31), floattov10(-0.5f), floattov10(-0.5f), floattov10(-0.7f));
	glLight(1, RGB(31, 8, 0), floattov10(0.8f), floattov10(0), floattov10(-0.5f));
	glMaterialf(GL_AMBIENT, RGB(4, 4, 6));
	glMaterialf(GL_DIFFUSE, RGB(24, 24, 24));
	glMaterialf(GL_SPECULAR, RGB(31, 31, 31));
	glMaterialf(GL_EMISSION, RGB(0, 0, 2));
	notex();
	polyfmt(PA_ALPHA(31) | POLY_CULL_BACK | PA_ID(1) | POLY_FORMAT_LIGHT0 | POLY_FORMAT_LIGHT1);
	const int N = 12;
	for (int j = 0; j < N; j++) {
		glBegin(GL_QUAD_STRIP);
		for (int i = 0; i <= N; i++) {
			for (int k = 1; k >= 0; k--) {
				float th = (j + k) * 3.14159265f / N, ph = i * 2 * 3.14159265f / N;
				float x = sinf(th) * cosf(ph), y = cosf(th), z = sinf(th) * sinf(ph);
				glNormal(NORMAL_PACK(floattov10(x * 0.99f), floattov10(y * 0.99f), floattov10(z * 0.99f)));
				v3(x * 1.1f, y * 1.1f, z * 1.1f);
			}
		}
		glEnd();
	}
}

static void sc_clip(void)
{
	persp();
	notex();
	// crosses the near plane
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(1));
	glBegin(GL_TRIANGLES);
	col(31, 0, 0); v3(-1, -0.5f, 0.5f);
	col(0, 31, 0); v3(1, -0.5f, -3);
	col(0, 0, 31); v3(-0.5f, 0.8f, -3);
	glEnd();
	// much larger than the screen
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(2));
	glBegin(GL_QUADS);
	col(31, 31, 0); v3(-7, 7, -6);
	col(0, 31, 31); v3(-7, -1.5f, -6);
	col(31, 0, 31); v3(7, -1.5f, -6);
	col(8, 8, 8); v3(7, 7, -6);
	glEnd();
	// crosses the far plane
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(3) | (1u << 12));
	col(31, 31, 31);
	glBegin(GL_TRIANGLES); v3(-1.5f, -2, -8); v3(0, -2, -60); v3(1.5f, -2, -8); glEnd();
}

static u32 s_shadow_cull = PA_BOTH;
static void sc_shadow(void)
{
	persp();
	glTranslatef32(0, 0, F(-3));
	glRotateYi(degreesToAngle(20));
	notex();
	// receiver: a wall at z = -0.5, the box crosses it (z -1.0 .. 0.0)
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(1));
	col(20, 20, 20);
	glBegin(GL_QUADS); v3(-1.8f, 1.2f, -0.5f); v3(-1.8f, -1.2f, -0.5f); v3(1.8f, -1.2f, -0.5f); v3(1.8f, 1.2f, -0.5f); glEnd();
	// mask pass (ID 0) then shadow pass (ID 5), both double-sided;
	// manual translucent sort keeps that order
	for (int pass = 0; pass < 2; pass++) {
		polyfmt(PA_ALPHA(20) | (pass ? s_shadow_cull : PA_BOTH) | POLY_SHADOW | PA_ID(pass ? 5 : 0));
		col(0, 0, 8);
		float x0 = -0.6f, x1 = 0.5f, y0 = -0.7f, y1 = 0.4f, z0 = -1.0f, z1 = 0.0f;
		float v[8][3] = { {x0,y0,z0},{x1,y0,z0},{x1,y1,z0},{x0,y1,z0},{x0,y0,z1},{x1,y0,z1},{x1,y1,z1},{x0,y1,z1} };
		static const u8 f[6][4] = { {0,1,2,3},{5,4,7,6},{4,0,3,7},{1,5,6,2},{3,2,6,7},{4,5,1,0} };
		glBegin(GL_QUADS);
		for (int k = 0; k < 6; k++)
			for (int m = 0; m < 4; m++) v3(v[f[k][m]][0], v[f[k][m]][1], v[f[k][m]][2]);
		glEnd();
	}
}

// The shadow pass with one face set only (one of the two is the front faces).
static void sc_shadow_6(void) { s_shadow_cull = 1u << 6; sc_shadow(); s_shadow_cull = PA_BOTH; }
static void sc_shadow_7(void) { s_shadow_cull = 1u << 7; sc_shadow(); s_shadow_cull = PA_BOTH; }

static void sc_alpha_test(void)
{
	persp();
	glTranslatef32(0, 0, F(-2.2));
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(1));
	tex(texparam(T_A5I3, 2, 2, 6, GL_TEXTURE_WRAP_S | GL_TEXTURE_WRAP_T), P_A5I3, 6);
	col(31, 31, 31);
	texquad(1.0f, 64);
	notex();
	polyfmt(PA_ALPHA(31) | PA_BOTH | PA_ID(2));
	col(31, 0, 0);
	glBegin(GL_TRIANGLES); v3(-1.4f, -1.2f, -0.5f); v3(1.4f, -1.2f, -0.5f); v3(0, 1.2f, -0.5f); glEnd();
}

static void sc_trans_sort(void)
{
	persp();
	glTranslatef32(0, 0, F(-3));
	notex();
	for (int i = 0; i < 5; i++) {
		polyfmt(PA_ALPHA(10 + i * 3) | PA_BOTH | PA_ID(1 + i) | (i & 1 ? PA_TRANS_DEPTH : 0));
		col(i & 1 ? 31 : 0, i & 2 ? 31 : 8, i & 4 ? 0 : 31);
		float z = (i % 3) * -0.4f, x = -1.2f + i * 0.45f, y = 0.8f - i * 0.3f;
		glBegin(GL_QUADS); v3(x, y, z); v3(x, y - 1.2f, z); v3(x + 1.2f, y - 1.2f, z); v3(x + 1.2f, y, z); glEnd();
	}
}

static const Scene s_scenes[] = {
	{ "gouraud",       sc_gouraud,       0 },
	{ "persp_00",      sc_persp_00,      GL_TEXTURE_2D },
	{ "persp_30",      sc_persp_30,      GL_TEXTURE_2D },
	{ "persp_60",      sc_persp_60,      GL_TEXTURE_2D },
	{ "persp_80",      sc_persp_80,      GL_TEXTURE_2D },
	{ "persp_80_wbuf", sc_persp_80,      GL_TEXTURE_2D, GL_WBUFFERING },
	{ "tex_seam",      sc_tex_seam,      GL_TEXTURE_2D },
	{ "tex_formats",   sc_tex_formats,   GL_TEXTURE_2D | GL_BLEND },
	{ "tex_blend",     sc_tex_blend,     GL_TEXTURE_2D | GL_BLEND },
	{ "depth_z",       depth_scene,      0 },
	{ "depth_w",       depth_scene,      0, GL_WBUFFERING },
	{ "aa_opaque",     sc_aa_opaque,     GL_ANTIALIAS | GL_BLEND },
	{ "aa_translucent", sc_aa_translucent, GL_ANTIALIAS | GL_BLEND },
	{ "aa_over_2d",    sc_aa_translucent, GL_ANTIALIAS | GL_BLEND, 0, true },
	{ "ui_text",       sc_ui_text,       GL_TEXTURE_2D | GL_BLEND | GL_ANTIALIAS, 0, true },
	{ "fog",           fog_rows,         GL_FOG | GL_BLEND | (2 << 8) },
	{ "fog_alpha_only", fog_rows,        GL_FOG | GL_FOG_ONLY_ALPHA | GL_BLEND | (2 << 8), 0, true },
	{ "toon",          toon_scene,       GL_TEXTURE_2D },
	{ "highlight",     toon_scene,       GL_TEXTURE_2D | GL_TOON_HIGHLIGHT },
	{ "edge_mark",     sc_edge,          GL_OUTLINE | GL_BLEND },
	{ "edge_mark_aa",  sc_edge,          GL_OUTLINE | GL_ANTIALIAS | GL_BLEND },
	{ "lighting",      sc_lighting,      0 },
	{ "clip",          sc_clip,          0 },
	{ "shadow",        sc_shadow,        GL_BLEND, GL_TRANS_MANUALSORT },
	{ "shadow_cull6",  sc_shadow_6,      GL_BLEND, GL_TRANS_MANUALSORT },
	{ "shadow_cull7",  sc_shadow_7,      GL_BLEND, GL_TRANS_MANUALSORT },
	{ "alpha_test",    sc_alpha_test,    GL_TEXTURE_2D | GL_ALPHA_TEST | GL_BLEND },
	{ "trans_sort_y",  sc_trans_sort,    GL_BLEND },
	{ "trans_sort_manual", sc_trans_sort, GL_BLEND, GL_TRANS_MANUALSORT },
};
#define NSCENES (int)(sizeof s_scenes / sizeof s_scenes[0])

static void render_regs(const Scene* s)
{
	R_DISP3DCNT = s->disp3d | GL_COLOR_UNDERFLOW | GL_POLY_OVERFLOW;
	// clear: dark grey, alpha 31 (0 over 2D), polygon ID 63, fog enabled
	u32 alpha = s->bg1 ? 0 : 31;
	R_CLEARCOL = RGB(3, 3, 5) | (1u << 15) | (alpha << 16) | (63u << 24);
	R_CLEARDEPTH = 0x7FFF;
	R_ALPHAREF = 12;
	R_FOGCOLOR = RGB(20, 22, 31) | (24u << 16);
	R_FOGOFFSET = 0x7A00;
	for (int i = 0; i < 32; i++) R_FOGTABLE(i) = i * 4 > 127 ? 127 : i * 4;
	for (int i = 0; i < 32; i++) R_TOON(i) = RGB(i < 10 ? 6 : i < 20 ? 18 : 31, i < 16 ? 4 : 24, (i * 3) & 31);
	for (int i = 0; i < 8; i++) R_EDGE(i) = RGB((i * 9) & 31, 31 - i * 4, (i * 13) & 31);
	R_DISPCNT = (R_DISPCNT & ~(1u << 9)) | (s->bg1 ? (1u << 9) : 0);
}

static u16 s_cap[256 * 192];

static void capture(int srcA, const char* name, const char* suffix)
{
	swiWaitForVBlank();
	R_DISPCAP = DCAP_ENABLE | DCAP_MODE(DCAP_MODE_A) | DCAP_SRC_A(srcA) |
	            DCAP_SIZE(DCAP_SIZE_256x192) | DCAP_OFFSET(0) | DCAP_BANK(DCAP_BANK_VRAM_B);
	while (R_DISPCAP & DCAP_ENABLE) {}
	memcpy(s_cap, (void*)0x06820000, sizeof s_cap);
	char fn[64];
	snprintf(fn, sizeof fn, "cap3d_%s_%s.bin", name, suffix);
	hw_write(fn, s_cap, sizeof s_cap);
}

int main(void)
{
	hw_init(VERSION " - 3D capture");
	videoSetMode(MODE_0_3D);
	glInit();
	R_VRAMCNT(1) = 0x80;   // B: LCDC, capture destination
	make_textures();
	make_bg();
	glViewport(0, 0, 255, 191);

	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\n", VERSION, __DATE__, __TIME__);
	buf_printf(&info, "format: 256x192 u16 LE, RGB555 + bit15; _3d = source A 3D only, _comp = BG0(3D)+BG1+backdrop\n");
	buf_printf(&info, "scene,disp3dcnt,swap,bg1,gxstat_after\n");
	for (int i = 0; i < NSCENES; i++) {
		const Scene* s = &s_scenes[i];
		iprintf("\x1b[8;0H%2d/%d %-22s", i + 1, NSCENES, s->name);
		render_regs(s);
		// The SWAP parameter (W-buffer, manual sort) applies to the polygons
		// submitted after that SWAP, so latch it first with an empty frame.
		// (cap3d 1/2 lacked this: their *_wbuf/depth_w/manual-sort scenes
		// used the previous scene's parameter.)
		glFlush(s->swap);
		swiWaitForVBlank();
		s->fn();
		glFlush(s->swap);
		swiWaitForVBlank();
		swiWaitForVBlank();
		capture(DCAP_SRC_A_3DONLY, s->name, "3d");
		capture(DCAP_SRC_A_COMPOSITED, s->name, "comp");
		buf_printf(&info, "%s,%04lx,%lu,%d,%08lx\n", s->name, (unsigned long)s->disp3d,
		           (unsigned long)s->swap, s->bg1, (unsigned long)R_GXSTAT);
	}
	buf_write(&info, "cap3d_info.txt");
	hw_done();
}
