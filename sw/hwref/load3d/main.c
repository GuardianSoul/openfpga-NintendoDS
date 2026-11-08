// load3d (docs/hw-reference.md "load3d"): the DS's 3D render throughput, for
// the raster session. A scene of N overlapping quads, each covering lines
// 0-191 and S pixels wide, each nearer than the last so every pixel of
// every quad is drawn: N polygons and N*S pixels per line. Two frames after
// its SWAP: RDLINES_COUNT (0x4000320, minimum buffered lines - 2 in the
// previous frame) and the DISP3DCNT underflow flag (bit 12). Variants at two
// loads: textured (formats 1-7, 8x8 and 256x256), translucent, AA, edge
// marking, fog, W-buffer. The heaviest untextured scenes are captured (3D
// only) to show what an overloaded frame looks like. melonDS returns 46 and
// never underflows (no render-time model).
// v2 (run 23 found the edge near 32 x 64): a finer grid N 8..256 x S 2..128,
// the variants at (32, 48) and (128, 4), just below it, and captures of a
// light control (16, 16), the edge (32, 64) and overloaded scenes
// (48, 64), (64, 64), (128, 16), (256, 4).
// v3 (raster session, to fit T_line = c + a*N + b*N*S): group A is its
// (N, S) list; group H the same load full height vs 8 lines tall from line
// 100 (cost per line covered or per polygon?); group R a ramp, quad i
// covering lines 2i..191 so line y has y/2 + 1 polygons, at S = 16, captured
// (where do lines go missing?).
// v4 (raster session, 2026-11-06; run 24 has v3's groups, so v4 runs only the
// new ones): group T, does the texel access pattern cost? 256x256 textures
// (direct and 4-bit) with each quad sampling its own rows and columns
// ("scattered", a different 32-byte block per pixel at S = 4) against the
// same texture with every quad sampling the same texels (run 24's group B),
// at and just below the edge; group P, does the polygon's shape cost?
// parallelograms (sloped edges, the same width per line) and each quad as
// two triangles (twice the polygons per line), against run 24's rectangles.
// Results are appended per case (load3d4.csv), so a hang keeps what ran.
#include "../common/gxplay.h"
#include <stdio.h>
#include <stdlib.h>

#define VERSION "load3d 4"
#define R_RDLINES REG16(0x04000320)
#define F1 4096

static void vtx(s32 px, s32 py, s32 z)   // pixel position (w = 1, identity projection)
{
	s32 x = (px - 128) * F1 / 128, y = (96 - py) * F1 / 96;
	gxp_put(0x23, ((u32)x & 0xFFFF) | ((u32)y << 16));
	gxp_put(0x23, (u32)z & 0xFFFF);
}

typedef struct { u32 disp3d, tex, attr, swap; } Var;

static void __attribute__((unused)) scene_y(int n, int s, const Var* v, int y0, int y1, bool ramp)
{
	gxp_reset_geometry();
	gxp_put(0x60, 0 | (0 << 8) | (255u << 16) | (191u << 24));
	gxp_put(0x2A, v->tex);
	gxp_put(0x2B, 0);
	int x0 = (256 - s) / 2;
	for (int i = 0; i < n; i++) {
		s32 z = 0xE00 - (s32)((s64)i * 0x1C00 / n);   // nearer each time
		gxp_put(0x29, v->attr | ((u32)(i & 63) << 24));
		gxp_put(0x20, (i * 37) & 0x7FFF);
		gxp_put(0x40, 1);
		int ya = ramp ? 2 * i : y0;
		gxp_put(0x22, 0); vtx(x0, ya, z);
		gxp_put(0x22, 0x0FFF0000u); vtx(x0, y1, z);
		gxp_put(0x22, 0x0FFF0FFF); vtx(x0 + s, y1, z);
		gxp_put(0x22, 0x00000FFF); vtx(x0 + s, ya, z);
	}
	gxp_put(0x41, 0);
}

// v4: N quads covering lines 0-191, S px wide; shape 0 rectangle, 1 parallelogram (top 32 px right of the bottom,
// edges sloped), 2 two triangles per quad; scatter: quad i samples its own region of the texture
static void scene4(int n, int s, int shape, bool scatter, const Var* v)
{
	gxp_reset_geometry();
	gxp_put(0x60, 0 | (0 << 8) | (255u << 16) | (191u << 24));
	gxp_put(0x2A, v->tex);
	gxp_put(0x2B, 0);
	int x0 = (256 - s) / 2;
	int dx = shape == 1 ? 16 : 0;              // top x0 + 16, bottom x0 - 16
	for (int i = 0; i < n; i++) {
		s32 z = 0xE00 - (s32)((s64)i * 0x1C00 / n);
		u32 so = scatter ? (u32)((i * 37) & 255) << 4 : 0, to = scatter ? (u32)((i * 91) & 255) << 4 : 0;
		u32 t00 = so | to << 16, t01 = so | (to + 0xFFF) << 16, t11 = (so + 0xFFF) | (to + 0xFFF) << 16, t10 = (so + 0xFFF) | to << 16;
		gxp_put(0x29, v->attr | ((u32)(i & 63) << 24));   // POLYGON_ATTR is latched at BEGIN_VTXS
		gxp_put(0x20, (i * 37) & 0x7FFF);
		gxp_put(0x40, shape == 2 ? 0 : 1);
		if (shape == 2) {
			gxp_put(0x22, t00); vtx(x0, 0, z);
			gxp_put(0x22, t01); vtx(x0, 192, z);
			gxp_put(0x22, t11); vtx(x0 + s, 192, z);
			gxp_put(0x22, t00); vtx(x0, 0, z);
			gxp_put(0x22, t11); vtx(x0 + s, 192, z);
			gxp_put(0x22, t10); vtx(x0 + s, 0, z);
		} else {
			gxp_put(0x22, t00); vtx(x0 + dx, 0, z);
			gxp_put(0x22, t01); vtx(x0 - dx, 192, z);
			gxp_put(0x22, t11); vtx(x0 - dx + s, 192, z);
			gxp_put(0x22, t10); vtx(x0 + dx + s, 0, z);
		}
	}
	gxp_put(0x41, 0);
}

int main(void)
{
	hw_init(VERSION " - 3D render load");
	gxp_console_on_h();
	iprintf(VERSION " - 3D render load\n\n");
	videoSetMode(MODE_0_3D);
	glInit();
	REG32(0x04000010) = 0;   // BG0HOFS/VOFS: BG0 is the 3D layer, and lat2d runs just before in hwref.nds
	// textures: A = slot 0 (any data), E = palette slots; D = capture
	R_VRAMCNT(0) = 0x80;
	for (int i = 0; i < 0x10000; i++) ((vu16*)0x06800000)[i] = (u16)(i * 2654435761u >> 16);
	R_VRAMCNT(0) = 0x83;
	R_VRAMCNT(4) = 0x80;
	for (int i = 0; i < 0x8000; i++) ((vu16*)0x06880000)[i] = (u16)(i * 40503u);
	R_VRAMCNT(4) = 0x83;
	R_VRAMCNT(3) = 0x80;
	for (int i = 0; i < 32; i++) REG16(0x04000380 + 2 * i) = i * 0x421;   // toon
	REG32(0x04000358) = 0x7C1F | (31 << 16);                               // fog colour
	for (int i = 0; i < 32; i += 4) REG32(0x04000360 + i) = 0x7F7F7F7F;   // fog table

	const u32 opaque = (31u << 16) | (3u << 6);
	u16* cap = malloc(256 * 192 * 2);
	int ncap = 0;
	// group A: the raster session's (N, S) points
	static const short pts[][2] __attribute__((unused)) = {
		{ 64, 1 }, { 96, 1 }, { 128, 1 }, { 160, 1 }, { 192, 1 }, { 224, 1 }, { 256, 1 }, { 320, 1 },
		{ 128, 4 }, { 144, 4 }, { 160, 4 }, { 176, 4 }, { 192, 4 }, { 224, 4 },
		{ 64, 16 }, { 72, 16 }, { 80, 16 }, { 88, 16 }, { 96, 16 }, { 112, 16 }, { 128, 16 },
		{ 16, 64 }, { 20, 64 }, { 24, 64 }, { 28, 64 }, { 32, 64 }, { 40, 64 }, { 48, 64 },
		{ 4, 256 }, { 6, 256 }, { 8, 256 }, { 12, 256 }, { 16, 256 }, { 24, 256 },
	};
	struct { const char* name; Var v; } vars[] __attribute__((unused)) = {
		{ "plain",       { 0, 0, opaque, 0 } },
		{ "tex1_8",      { 1, 1u << 26 | 0 << 20 | 0 << 23 | 3 << 16, opaque, 0 } },
		{ "tex2_8",      { 1, 2u << 26 | 3 << 16, opaque, 0 } },
		{ "tex3_8",      { 1, 3u << 26 | 3 << 16, opaque, 0 } },
		{ "tex4_8",      { 1, 4u << 26 | 3 << 16, opaque, 0 } },
		{ "tex5_8",      { 1, 5u << 26 | 3 << 16, opaque, 0 } },
		{ "tex6_8",      { 1, 6u << 26 | 3 << 16, opaque, 0 } },
		{ "tex7_8",      { 1, 7u << 26 | 3 << 16, opaque, 0 } },
		{ "tex7_256",    { 1, 7u << 26 | 5u << 20 | 5u << 23 | 3 << 16, opaque, 0 } },
		{ "tex3_256",    { 1, 3u << 26 | 5u << 20 | 5u << 23 | 3 << 16, opaque, 0 } },
		{ "tex5_256",    { 1, 5u << 26 | 5u << 20 | 5u << 23 | 3 << 16, opaque, 0 } },
		{ "translucent", { 8, 0, (16u << 16) | (3u << 6) | (1u << 11), 0 } },
		{ "aa",          { 16, 0, opaque, 0 } },
		{ "edge",        { 32, 0, opaque, 0 } },
		{ "fog",         { 128, 0, opaque | (1u << 15), 0 } },
		{ "wbuffer",     { 0, 0, opaque, 2 } },
		{ "toon",        { 0, 0, opaque | (2u << 4), 0 } },
	};
	// v4: group T (texel access pattern) and P (shape); run 24 has groups A, B, H and R
	static const short tpts[][2] = { { 160, 4 }, { 176, 4 }, { 192, 4 }, { 80, 16 }, { 88, 16 }, { 96, 16 }, { 32, 48 }, { 36, 48 } };
	static const short ppts[][2] = { { 160, 4 }, { 192, 4 }, { 80, 16 }, { 96, 16 }, { 96, 4 }, { 112, 4 } };
	const int ntp = sizeof tpts / sizeof tpts[0], npp = sizeof ppts / sizeof ppts[0];
	const Var vt7 = { 1, 7u << 26 | 5u << 20 | 5u << 23 | 3 << 16, opaque, 0 };
	const Var vt3 = { 1, 3u << 26 | 5u << 20 | 5u << 23 | 3 << 16, opaque, 0 };
	const Var vplain = { 0, 0, opaque, 0 };
	static const char hdr[] = "group,n,s,variant,rdlines_min,underflow,polys,verts\n";
	hw_write("load3d4.csv", hdr, sizeof hdr - 1);
	for (int c = 0; c < ntp * 3 + npp * 2; c++) {
		int n, s, shape = 0;
		bool scatter = false;
		const Var* v;
		const char* name;
		char g;
		if (c < ntp * 3) {
			g = 'T'; n = tpts[c / 3][0]; s = tpts[c / 3][1];
			int k = c % 3;
			v = k == 2 ? &vt3 : &vt7; scatter = k != 0;
			name = k == 0 ? "tex7_256_shared" : k == 1 ? "tex7_256_scatter" : "tex3_256_scatter";
		} else {
			int d = c - ntp * 3;
			g = 'P'; n = ppts[d / 2][0]; s = ppts[d / 2][1]; v = &vplain;
			shape = d % 2 ? 2 : 1;
			name = shape == 1 ? "parallelogram" : "triangles";
			if (shape == 1 && s == 4 && n < 160) continue;   // (96, 4), (112, 4): triangles only
		}
		gxp_swap(v->swap);
		R_DISP3DCNT = (v->disp3d & 0x0FFF) | (3 << 12);
		REG32(0x04000350) = 0 | (31 << 16) | (63u << 24);
		REG32(0x04000354) = 0x7FFF;
		scene4(n, s, shape, scatter, v);
		gxp_wait_idle();
		u32 rc = gxp_ramcount();
		gxp_swap(v->swap);
		swiWaitForVBlank();
		R_DISP3DCNT = (v->disp3d & 0x0FFF) | (1 << 12);
		swiWaitForVBlank();
		swiWaitForVBlank();
		u32 rdl = R_RDLINES & 63, und = (R_DISP3DCNT >> 12) & 1;
		char line[96];
		int len = snprintf(line, sizeof line, "%c,%d,%d,%s,%lu,%lu,%lu,%lu\n", g, n, s, name, (unsigned long)rdl,
		                   (unsigned long)und, (unsigned long)(rc & 0xFFF), (unsigned long)((rc >> 16) & 0x1FFF));
		hw_append("load3d4.csv", line, len);
		bool want = (g == 'T' && n == 80 && s == 16 && scatter && v == &vt7) || (g == 'P' && n == 80 && s == 16)
		            || (g == 'P' && n == 96 && s == 4);
		if (want && cap) {
			gxp_capture_start(3);
			gxp_capture_finish(3, cap);
			char fn[48];
			snprintf(fn, sizeof fn, "load3d4_%c_n%d_s%d_%s_3d.bin", g, n, s, name);
			hw_write(fn, cap, 256 * 192 * 2);
			ncap++;
		}
		iprintf("\x1b[4;0H%c %4d x %3d %-18s", g, n, s, name);
	}
	free(cap);
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\nN overlapping quads covering lines 0-191, S px wide, centred, each nearer;"
	           " rdlines_min = RDLINES_COUNT & 63 (min buffered lines - 2, previous frame), underflow = DISP3DCNT bit 12 over"
	           " one full frame; v4: groups T and P only (load3d4.csv, appended per case); %d captures (load3d4_*_3d.bin, 3D only)\n", VERSION, __DATE__, __TIME__, ncap);
	buf_write(&info, "load3d_info.txt");
	hw_done();
}
