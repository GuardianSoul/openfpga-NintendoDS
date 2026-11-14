// lim3d (docs/hw-reference.md "lim3d"): the 3D engine at its own limits, for the 3D-limits study (budget-3d "The
// DS's 3D limits"). Run 24/44 pinned the per-line cost (8.0 ticks a polygon + 0.99 a pixel, about 42.6 lines of
// lead) with loads spread over the whole frame, and run 16 the RAM counts. Open, and asked here:
//   - the lead later in the frame: a band of 8 lines at line 150 that needs more render time than the lead the frame
//     starts with (1,280 and 1,536 quads, 57 and 69 lines of time against 42.6 + 8): does the DS render it (the
//     lead grows over the empty lines above it) or underflow as at line 0 (the 48-line buffer caps it)?
//   - a full RAM on one line: 1,536 quads (6,144 vertices) and 2,048 triangles, 2 lines tall, so render time
//     (about 23 lines) is no limit: are they drawn, given the overflow flag is set at exactly full (run 16)?
//     And 2,100 triangles: which 2,048 are kept?
//   - the same at line 0, the frame spread, and the per-line front limit (160 thin quads full height) as controls.
// N polygons, w x h px, the i-th at x = 5i mod 248, nearer than the last and coloured (i * 37) & 0x7FFF, so a
// capture shows which polygons were drawn on each line. Per case, two frames after its SWAP: RAM_COUNT, the
// overflow flag (from the list), the underflow flag and RDLINES_COUNT over one frame, and a 3D capture.
// Hang-safe: every GX write and wait is bounded (gxplay; a case stops at its first timed-out write and the run ends
// after it, "gx_stuck"), each case is appended to lim3d.csv when it ends, and
// lim3d_progress.txt records "start"/"done" per case: a rerun after a hang skips the cases that ran and the one that
// hung (marked "hung").
#include "../common/gxplay.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VERSION "lim3d 1"
#define R_RDLINES REG16(0x04000320)
#define F1 4096
#define PROGRESS "lim3d_progress.txt"

static s32 fdiv(s32 a, s32 b) { return a >= 0 ? a / b : -((-a + b - 1) / b); }

// pixel position (w = 1, identity projection); y rounded down, so the viewport puts an edge at py on line py, not
// a fraction above it (a polygon h lines tall covers h lines)
static void vtx(s32 px, s32 py, s32 z)
{
	s32 x = (px - 128) * F1 / 128, y = fdiv((96 - py) * F1, 96);
	gxp_put(0x23, ((u32)x & 0xFFFF) | ((u32)y << 16));
	gxp_put(0x23, (u32)z & 0xFFFF);
}

typedef struct { short n, quad, w, h, y0, spread; const char* name; } Case;
static const Case s_cases[] = {
	{    2, 0, 64,  64,  64, 0, "control" },
	{  512, 1,  4,   8,   0, 0, "q512_y0_h8" },       // DS budget at line 7: 23 of 50.6 lines
	{ 1024, 1,  4,   8,   0, 0, "q1024_y0_h8" },      // 46 of 50.6: renders
	{ 1536, 1,  4,   8,   0, 0, "q1536_y0_h8" },      // 69: underflows from about line 5
	{ 1024, 1,  4,   8, 150, 0, "q1024_y150_h8" },
	{ 1280, 1,  4,   8, 150, 0, "q1280_y150_h8" },    // the lead question: 57 lines of time
	{ 1536, 1,  4,   8, 150, 0, "q1536_y150_h8" },    // 69
	{ 1536, 1,  4,   2, 150, 0, "q1536_y150_h2" },    // 6,144 vertices: vertex RAM full, 17 lines of time
	{ 2048, 0,  4,   2, 150, 0, "t2048_y150_h2" },    // both full, 23 lines
	{ 2100, 0,  4,   2, 150, 0, "t2100_y150_h2" },    // overflow: the first 2,048 kept?
	{ 2048, 0,  4,   2,   0, 0, "t2048_y0_h2" },
	{ 2048, 0,  4,   8,   0, 1, "t2048_spread" },     // y0 = 8 * (i mod 23): about 85 polygons a line
	{  160, 1,  4, 192,   0, 0, "q160_full" },        // 1,914 ticks a line: renders (run 24)
	{    2, 0, 64,  64,  64, 0, "control_end" },
};
#define NCASES (int)(sizeof s_cases / sizeof s_cases[0])

static void scene(const Case* c)
{
	gxp_reset_geometry();
	gxp_put(0x60, 0 | (0 << 8) | (255u << 16) | (191u << 24));
	gxp_put(0x2A, 0);
	gxp_put(0x40, c->quad ? 1 : 0);
	u32 t0 = gxp_timeouts;
	for (int i = 0; i < c->n && gxp_timeouts == t0; i++) {   // a stuck engine: stop, not 4M polls a write
		int x = (5 * i) % 248, y = c->spread ? 8 * (i % 23) : c->y0;
		s32 z = 0xE00 - (s32)((s64)i * 0x1C00 / (c->n + 1));   // nearer each time
		gxp_put(0x29, (31u << 16) | (3u << 6) | ((u32)(i & 63) << 24));
		gxp_put(0x20, (i * 37) & 0x7FFF);
		vtx(x, y, z); vtx(x, y + c->h, z); vtx(x + c->w, y + c->h, z);
		if (c->quad) vtx(x + c->w, y, z);
	}
	gxp_put(0x41, 0);
}

static void log_progress(const char* what, const char* name)
{
	char line[64];
	int len = snprintf(line, sizeof line, "%s %s\n", what, name);
	hw_append(PROGRESS, line, len);
}

// cases a previous run started (a hang stops before "done"): skipped, the hung one recorded once
static u32 seen_cases(void)
{
	u32 started = 0, done = 0;
	FILE* f = hw_fat_ok ? fopen(HWREF_DIR "/" PROGRESS, "rb") : NULL;
	if (!f) return 0;
	char line[96], what[16], name[64];
	while (fgets(line, sizeof line, f))
		if (sscanf(line, "%15s %63s", what, name) == 2)
			for (int c = 0; c < NCASES; c++)
				if (!strcmp(name, s_cases[c].name)) {
					if (!strcmp(what, "start")) started |= 1u << c;
					else done |= 1u << c;
				}
	fclose(f);
	for (int c = 0; c < NCASES; c++)
		if ((started & ~done) >> c & 1) log_progress("hung", s_cases[c].name);
	return started;
}

int main(void)
{
	hw_init(VERSION " - 3D limits");
	gxp_console_on_h();
	iprintf(VERSION " - 3D limits\n\n");
	videoSetMode(MODE_0_3D);
	glInit();
	REG32(0x04000010) = 0;   // BG0HOFS/VOFS: BG0 is the 3D layer
	R_VRAMCNT(3) = 0x80;     // D: capture
	u16* cap = malloc(256 * 192 * 2);
	u32 skip = seen_cases();
	if (!skip) {
		static const char hdr[] = "case,name,n,quad,w,h,y0,spread,polys,verts,overflow,rdlines_min,underflow,gx_timeouts\n";
		hw_write("lim3d.csv", hdr, sizeof hdr - 1);
	}
	int ncap = 0, nrun = 0;
	scene(&s_cases[0]);          // a first list after glInit counts nothing in melonDS: one unrecorded frame first
	gxp_wait_idle();
	gxp_swap(0);
	gxp_swap(0);
	for (int c = 0; c < NCASES; c++) {
		const Case* k = &s_cases[c];
		if (skip >> c & 1) continue;
		log_progress("start", k->name);
		iprintf("\x1b[4;0H%2d %-16s", c, k->name);
		u32 t0 = gxp_timeouts;
		gxp_swap(0);
		R_DISP3DCNT = 3 << 12;                       // ack underflow and overflow
		REG32(0x04000350) = 0 | (31 << 16) | (63u << 24);
		REG32(0x04000354) = 0x7FFF;
		scene(k);
		gxp_wait_idle();
		u32 rc = gxp_ramcount(), over = (R_DISP3DCNT >> 13) & 1;
		gxp_swap(0);
		swiWaitForVBlank();
		R_DISP3DCNT = 1 << 12;                       // ack underflow: the next frame's counts
		swiWaitForVBlank();
		swiWaitForVBlank();
		u32 rdl = R_RDLINES & 63, und = (R_DISP3DCNT >> 12) & 1;
		char line[160];
		int len = snprintf(line, sizeof line, "%d,%s,%d,%d,%d,%d,%d,%d,%lu,%lu,%lu,%lu,%lu,%lu\n", c, k->name, k->n,
		                   k->quad, k->w, k->h, k->y0, k->spread, (unsigned long)(rc & 0xFFF),
		                   (unsigned long)((rc >> 16) & 0x1FFF), (unsigned long)over, (unsigned long)rdl,
		                   (unsigned long)und, (unsigned long)(gxp_timeouts - t0));
		hw_append("lim3d.csv", line, len);
		if (cap) {
			gxp_capture_start(3);
			gxp_capture_finish(3, cap);
			char fn[48];
			snprintf(fn, sizeof fn, "lim3d_%s_3d.bin", k->name);
			hw_write(fn, cap, 256 * 192 * 2);
			ncap++;
		}
		log_progress("done", k->name);
		nrun++;
		if (gxp_timeouts != t0) { log_progress("gx_stuck", k->name); break; }   // the rest would only time out too
	}
	free(cap);
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\nN polygons w x h px at x = 5i mod 248, y0 (spread: 8 * (i mod 23)), each nearer,"
	           " colour (i * 37) & 0x7FFF; polys/verts = RAM_COUNT before the SWAP, overflow = DISP3DCNT bit 13 after the"
	           " list, rdlines_min = RDLINES_COUNT & 63 and underflow = bit 12 over the frame after; %d cases run this time,"
	           " %d captures (lim3d_<name>_3d.bin, 3D only); lim3d_progress.txt: start/done/hung per case\n",
	           VERSION, __DATE__, __TIME__, nrun, ncap);
	buf_write(&info, "lim3d_info.txt");
	hw_done();
}
