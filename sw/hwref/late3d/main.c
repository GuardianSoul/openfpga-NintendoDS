// late3d (docs/hw-reference.md "late3d"; coordinator and raster session):
// what a late 3D line shows. When the renderer hasn't finished a line by the
// time it is displayed, do its untouched pixels show the clear colour, the
// previous frame's line, or something else, and does the line show the
// polygons drawn so far (run 24)?
//
// Each test: frame P with clear colour blue (0x7C00) and no polygons, shown
// for 2 frames (the line buffers then hold blue). Then frame B: clear colour
// red (0x001F), N full-height quads 128 px wide in one half of the screen,
// colours green (first, farthest) to yellow (last, nearest), each nearer than
// the last; the other half has no polygon at all. The first two frames B is
// shown are captured (3D only) into VRAM D and C: late3d_<test>_f0.bin and
// _f1.bin (256x192 u16, RGB555 + bit 15). A late line's untouched half shows
// red (cleared), blue (an old line buffer) or something else; its loaded half
// shows how far drawing got. late3d.csv: test, n, side, polys, verts,
// rdlines_min, underflow.
//
// Hang-safe: geometry by gxp_put (bounded waits), bounded capture waits, each
// test's files written as it ends, and late3d_progress.txt ("V <version>",
// "start <test>", "done <test>"): a restart on the same card skips the tests
// that ended and the one that began without ending.
#include "../common/gxplay.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VERSION "late3d 1"
#define R_RDLINES REG16(0x04000320)
#define F1 4096

static void vtx(s32 px, s32 py, s32 z)   // pixel position (w = 1, identity projection)
{
	s32 x = (px - 128) * F1 / 128, y = (96 - py) * F1 / 96;
	gxp_put(0x23, ((u32)x & 0xFFFF) | ((u32)y << 16));
	gxp_put(0x23, (u32)z & 0xFFFF);
}

static void progress(const char* fmt, ...)
{
	if (!hw_fat_ok) return;
	FILE* f = fopen(HWREF_DIR "/late3d_progress.txt", "a");
	if (!f) return;
	va_list ap;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

#define MAXT 16
static char s_skip[MAXT][24];
static int s_nskip;
static bool s_resume;
static void load_progress(void)
{
	FILE* f = fopen(HWREF_DIR "/late3d_progress.txt", "r");
	if (!f) return;
	char line[96], open_t[24] = "";
	bool ours = false, all = false;
	while (fgets(line, sizeof line, f)) {
		char nm[24];
		if (!strncmp(line, "V " VERSION, 2 + strlen(VERSION))) ours = true;
		else if (!strncmp(line, "all done", 8)) all = true;
		else if (sscanf(line, "start %23s", nm) == 1) strcpy(open_t, nm);
		else if (sscanf(line, "done %23s", nm) == 1) { if (s_nskip < MAXT) strcpy(s_skip[s_nskip++], nm); open_t[0] = 0; }
	}
	fclose(f);
	if (!ours || all) { s_nskip = 0; return; }
	s_resume = true;
	if (open_t[0] && s_nskip < MAXT) strcpy(s_skip[s_nskip++], open_t);
}
static bool skipped(const char* t)
{
	for (int i = 0; i < s_nskip; i++) if (!strcmp(s_skip[i], t)) return true;
	return false;
}

static void clear(u16 colour)
{
	REG32(0x04000350) = colour | (31u << 16) | (63u << 24);   // alpha 31, polygon ID 63
	REG16(0x04000354) = 0x7FFF;
}

static u16 s_cap[256 * 192];

static void test(const char* name, int n, int x0, Buf* csv)
{
	if (skipped(name)) return;
	progress("start %s", name);
	iprintf("\x1b[6;0H%-12s n=%-4d       ", name, n);
	// frame P: blue, no polygons, shown for two frames
	clear(0x7C00);
	gxp_reset_geometry();
	gxp_swap(0);
	swiWaitForVBlank();
	swiWaitForVBlank();
	// frame B
	R_DISP3DCNT = (3 << 12);   // ack underflow/overflow
	clear(0x001F);
	gxp_reset_geometry();
	gxp_put(0x60, 0 | (0 << 8) | (255u << 16) | (191u << 24));
	gxp_put(0x2A, 0);
	for (int i = 0; i < n; i++) {
		s32 z = 0xE00 - (s32)((s64)i * 0x1C00 / n);   // nearer each time
		gxp_put(0x29, (31u << 16) | (3u << 6) | ((u32)(i & 63) << 24));
		gxp_put(0x20, (n > 1 ? i * 31 / (n - 1) : 0) | (31 << 5));   // green -> yellow
		gxp_put(0x40, 1);
		vtx(x0, 0, z); vtx(x0, 192, z); vtx(x0 + 128, 192, z); vtx(x0 + 128, 0, z);
	}
	gxp_put(0x41, 0);
	gxp_wait_idle();
	u32 rc = gxp_ramcount();
	gxp_swap(0);
	// the swap ran at this VBlank: capture the first frame shown, then the next
	gxp_capture_start(3);
	gxp_capture_finish(3, s_cap);
	char fn[48];
	snprintf(fn, sizeof fn, "late3d_%s_f0.bin", name);
	hw_write(fn, s_cap, sizeof s_cap);
	gxp_capture_start(2);
	gxp_capture_finish(2, s_cap);
	snprintf(fn, sizeof fn, "late3d_%s_f1.bin", name);
	hw_write(fn, s_cap, sizeof s_cap);
	u32 rdl = R_RDLINES & 63, und = (R_DISP3DCNT >> 12) & 1;
	buf_printf(csv, "%s,%d,%s,%lu,%lu,%lu,%lu,%lu\n", name, n, x0 ? "right" : "left", (unsigned long)(rc & 0xFFF),
	           (unsigned long)((rc >> 16) & 0x1FFF), (unsigned long)rdl, (unsigned long)und,
	           (unsigned long)gxp_timeouts);
	if (hw_fat_ok) {   // this test's row now
		FILE* f = fopen(HWREF_DIR "/late3d.csv", "a");
		if (f) { fwrite(csv->p, 1, csv->len, f); fclose(f); }
		free(csv->p);
		csv->p = NULL;
		csv->len = csv->cap = 0;
	}
	progress("done %s", name);
	// back to an empty frame
	gxp_reset_geometry();
	gxp_swap(0);
}

int main(void)
{
	hw_init(VERSION " - late 3D lines");
	gxp_console_on_h();
	iprintf(VERSION " - late 3D lines\n\n");
	videoSetMode(MODE_0_3D);
	glInit();
	REG32(0x04000010) = 0;
	R_VRAMCNT(2) = 0x80;   // C, D: LCDC, captures
	R_VRAMCNT(3) = 0x80;
	if (hw_fat_ok) load_progress();
	Buf csv = {0};
	if (!s_resume) {
		remove(HWREF_DIR "/late3d_progress.txt");
		progress("V " VERSION);
		buf_printf(&csv, "test,n,side,polys,verts,rdlines_min,underflow,timeouts\n");
		hw_write("late3d.csv", csv.p, csv.len);
		free(csv.p);
		csv.p = NULL;
		csv.len = csv.cap = 0;
	}
	// per line, n quads of 128 px cost about n * (8 + 128) ticks against 2,130
	// with a 43-line lead (run 24's fit): 8 renders on time, 24 runs late from
	// about line 80, 64 from about line 14, 192 from about line 4
	test("ctrl_n8_left", 8, 0, &csv);
	test("n24_left", 24, 0, &csv);
	test("n64_left", 64, 0, &csv);
	test("n192_left", 192, 0, &csv);
	test("n64_right", 64, 128, &csv);
	test("n192_right", 192, 128, &csv);
	progress("all done");
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\nframe P clear blue 0x7C00 no polygons (2 frames), then frame B clear red 0x001F with n"
	           " quads 128 px wide on the given side, colour i = RGB(31i/(n-1), 31, 0); f0/f1 = the first two frames B is"
	           " shown, 3D only, 256x192 u16\n", VERSION, __DATE__, __TIME__);
	buf_write(&info, "late3d_info.txt");
	hw_done();
}
