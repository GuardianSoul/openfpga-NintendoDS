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
#include "../common/gxplay.h"
#include <stdio.h>
#include <stdlib.h>

#define VERSION "load3d 3"
#define R_RDLINES REG16(0x04000320)
#define F1 4096

static void vtx(s32 px, s32 py, s32 z)   // pixel position (w = 1, identity projection)
{
	s32 x = (px - 128) * F1 / 128, y = (96 - py) * F1 / 96;
	gxp_put(0x23, ((u32)x & 0xFFFF) | ((u32)y << 16));
	gxp_put(0x23, (u32)z & 0xFFFF);
}

typedef struct { u32 disp3d, tex, attr, swap; } Var;

static void scene_y(int n, int s, const Var* v, int y0, int y1, bool ramp)
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
	Buf csv = {0};
	buf_printf(&csv, "group,n,s,variant,rdlines_min,underflow,polys,verts\n");
	u16* cap = malloc(256 * 192 * 2);
	int ncap = 0;
	// group A: the raster session's (N, S) points
	static const short pts[][2] = {
		{ 64, 1 }, { 96, 1 }, { 128, 1 }, { 160, 1 }, { 192, 1 }, { 224, 1 }, { 256, 1 }, { 320, 1 },
		{ 128, 4 }, { 144, 4 }, { 160, 4 }, { 176, 4 }, { 192, 4 }, { 224, 4 },
		{ 64, 16 }, { 72, 16 }, { 80, 16 }, { 88, 16 }, { 96, 16 }, { 112, 16 }, { 128, 16 },
		{ 16, 64 }, { 20, 64 }, { 24, 64 }, { 28, 64 }, { 32, 64 }, { 40, 64 }, { 48, 64 },
		{ 4, 256 }, { 6, 256 }, { 8, 256 }, { 12, 256 }, { 16, 256 }, { 24, 256 },
	};
	const int npts = sizeof pts / sizeof pts[0];
	static const int capn[] = { 16, 48, 224, 128, 24 }, caps[] = { 64, 64, 4, 16, 256 };   // (16, 64) is the control
	struct { const char* name; Var v; } vars[] = {
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
	const int nvars = sizeof vars / sizeof vars[0];
	// group A: the (N, S) points; B: every variant at (32, 48) and (128, 4);
	// H: (128, 4), (64, 16), (32, 64) full height then 8 lines tall; R: ramp
	static const short hpts[][2] = { { 128, 4 }, { 64, 16 }, { 32, 64 } };
	for (int g = 0; g < 4; g++) {
		int count = g == 0 ? npts : g == 1 ? nvars * 2 : g == 2 ? 6 : 1;
		for (int c = 0; c < count; c++) {
			int n, s, vi;
			bool shrt = false, ramp = false;
			if (g == 0) { n = pts[c][0]; s = pts[c][1]; vi = 0; }
			else if (g == 1) { vi = c / 2; n = c & 1 ? 128 : 32; s = c & 1 ? 4 : 48; }
			else if (g == 2) { n = hpts[c / 2][0]; s = hpts[c / 2][1]; vi = 0; shrt = c & 1; }
			else { n = 96; s = 16; vi = 0; ramp = true; }
			const Var* v = &vars[vi].v;
			gxp_swap(v->swap);   // latch the SWAP parameter with an empty list
			R_DISP3DCNT = (v->disp3d & 0x0FFF) | (3 << 12);   // ack underflow/overflow
			REG32(0x04000350) = 0 | (31 << 16) | (63u << 24);
			REG32(0x04000354) = 0x7FFF;
			scene_y(n, s, v, shrt ? 100 : 0, shrt ? 108 : 192, ramp);
			gxp_wait_idle();
			u32 rc = gxp_ramcount();
			gxp_swap(v->swap);
			swiWaitForVBlank();
			R_DISP3DCNT = (v->disp3d & 0x0FFF) | (1 << 12);   // clear underflow, then one full frame
			swiWaitForVBlank();
			swiWaitForVBlank();
			u32 rdl = R_RDLINES & 63, und = (R_DISP3DCNT >> 12) & 1;
			buf_printf(&csv, "%c,%d,%d,%s%s,%lu,%lu,%lu,%lu\n", "ABHR"[g], n, s, vars[vi].name,
			           shrt ? "_8lines" : ramp ? "_ramp" : "", (unsigned long)rdl,
			           (unsigned long)und, (unsigned long)(rc & 0xFFF), (unsigned long)((rc >> 16) & 0x1FFF));
			bool want = g == 3;
			for (int q = 0; q < 5; q++) want |= g == 0 && n == capn[q] && s == caps[q];
			if (want && cap) {
				gxp_capture_start(3);
				gxp_capture_finish(3, cap);
				char fn[40];
				if (g == 3) snprintf(fn, sizeof fn, "load3d_ramp_s%d_3d.bin", s);
				else snprintf(fn, sizeof fn, "load3d_n%d_s%d_3d.bin", n, s);
				hw_write(fn, cap, 256 * 192 * 2);
				ncap++;
			}
			iprintf("\x1b[4;0H%c %4d x %3d %-12s", "ABHR"[g], n, s, vars[vi].name);
		}
	}
	free(cap);
	buf_write(&csv, "load3d.csv");
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\nN overlapping quads covering lines 0-191, S px wide, centred, each nearer;"
	           " rdlines_min = RDLINES_COUNT & 63 (min buffered lines - 2, previous frame), underflow = DISP3DCNT bit 12 over"
	           " one full frame; %d captures (load3d_n<N>_s<S>_3d.bin, 3D only)\n", VERSION, __DATE__, __TIME__, ncap);
	buf_write(&info, "load3d_info.txt");
	hw_done();
}
