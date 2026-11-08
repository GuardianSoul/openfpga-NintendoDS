// swapline v1: when a POWCNT1 bit 15 (display swap) write takes effect.
// Visual probe: software can't read which engine a physical screen shows
// (display capture always takes engine A), so the maintainer reports what each screen
// shows. Engine A: red backdrop, "ENGINE A" on every row; engine B: blue
// backdrop, "ENGINE B". Each step runs until A is pressed (or about 12 s) and logs
// the VCOUNT read right after each write, so the result says where the
// writes landed. melonDS applies the bit per scanline; the core (nds_video)
// latches it at DS line 0 for the whole frame.
//   1 hold1   bit 15 = 1 all the time: A (red) on top, B (blue) below (control)
//   2 hold0   bit 15 = 0: B on top, A below (control)
//   3 line96  1 from line 96, 0 from VBlank (line 192). Per line: each screen
//             splits in the middle (top screen: B over A). Latched at line 0:
//             top all B. Latched at the frame's end: top all A
//   4 line0   1 from line 0, 0 from VBlank. Per line: top all A (its first
//             row may be B). Latched at line 0: all A or all B, steady
//   5 toggle  flipped at every VBlank: both screens flicker A/B (the
//             dual-screen 3D games' pattern; the control for the flicker)
// Hang-safe: no new hardware path (POWCNT1 writes, VCOUNT polls bounded to
// two frames, the key read); per-step results; a rerun skips finished steps.
#include "../common/hwref.h"
#include <stdio.h>
#include <string.h>

#define PROG "swapline_progress.txt"
#define FRAME_CYC 560190u                       // 263 lines x 2,130 cycles (33.5 MHz)

static PrintConsole s_top;
static PrintConsole* s_bot;                     // hw_init's console (engine B)

// waits until VCOUNT == line, at most two frames; false on a timeout
static bool wait_line(u16 line)
{
	u32 t0 = now32();
	while (R_VCOUNT != line) if (now32() - t0 > 2 * FRAME_CYC) return false;
	return true;
}

static void set_swap(int on)
{
	if (on) R_POWCNT1 |= 1u << 15; else R_POWCNT1 &= ~(1u << 15);
}

// on_line: the line bit 15 is set (-1: hold, -2: flip at every VBlank); off_line: the line it is cleared
typedef struct { const char* key; const char* what; int on_line, off_line, hold; } Step;
static const Step s_steps[] = {
	{ "hold1",  "hold 1: A top, B bottom",   -1,  -1,  1 },
	{ "hold0",  "hold 0: B top, A bottom",   -1,  -1,  0 },
	{ "line96", "1 at line 96, 0 at VBlank", 96, 192, -1 },
	{ "line0",  "1 at line 0, 0 at VBlank",   0, 192, -1 },
	{ "toggle", "flip at every VBlank",      -2, 192, -1 },
};

static void run(int n, const Step* s)
{
	char buf[160];
	if (hw_fat_ok && !hw_step_begin(PROG, s->key)) return;   // no SD (melonDS check): every step runs, unrecorded
	consoleSelect(&s_top);
	consoleClear();
	for (int r = 0; r < 23; r++) iprintf("ENGINE A  ENGINE A  ENGINE A\n");
	consoleSelect(s_bot);
	consoleClear();
	for (int r = 0; r < 19; r++) iprintf("ENGINE B  ENGINE B  ENGINE B\n");
	iprintf("step %d/5 %s\n%s\nlook at both screens, then A\n", n, s->key, s->what);
	int frames = 0, on_min = 999, on_max = -1, off_min = 999, off_max = -1, timeouts = 0, flip = 0;
	u32 t0 = now32();
	while (frames < 1200 && now32() - t0 < 700u * FRAME_CYC) {      // about 12 s (700 frames of cycles) unless A
		if (s->hold >= 0) {
			set_swap(s->hold);
			if (!wait_line(192)) timeouts++;
		} else if (s->on_line == -2) {
			if (!wait_line(192)) timeouts++;
			set_swap(flip ^= 1);
			int v = R_VCOUNT; if (v < off_min) off_min = v; if (v > off_max) off_max = v;
		} else {
			if (!wait_line(s->on_line)) timeouts++;
			set_swap(1);
			int v = R_VCOUNT; if (v < on_min) on_min = v; if (v > on_max) on_max = v;
			if (!wait_line(s->off_line)) timeouts++;
			set_swap(0);
			v = R_VCOUNT; if (v < off_min) off_min = v; if (v > off_max) off_max = v;
		}
		frames++;
		scanKeys();
		if (frames > 30 && (keysDown() & KEY_A)) break;
		if (!wait_line(193)) timeouts++;                              // one pass per frame
	}
	set_swap(1);
	snprintf(buf, sizeof buf, "%s,%d,%d,%d,%d,%d,%d\n", s->key, frames, on_min, on_max, off_min, off_max, timeouts);
	hw_append("swapline.csv", buf, strlen(buf));
	if (hw_fat_ok) hw_step_done(PROG, s->key);
}

int main(void)
{
	hw_init("hwref swapline v1: POWCNT1 bit 15 timing");
	// engine A: a text console on the main engine, red backdrop; engine B: hw_init's console, blue
	videoSetMode(MODE_0_2D);
	vramSetBankA(VRAM_A_MAIN_BG);
	s_bot = consoleSelect(&s_top);              // (consoleInit makes its console the current one)
	consoleInit(&s_top, 0, BgType_Text4bpp, BgSize_T_256x256, 31, 0, true, true);
	consoleSelect(s_bot);
	BG_PALETTE[0] = RGB15(31, 0, 0);
	BG_PALETTE_SUB[0] = RGB15(0, 0, 31);
	hw_csv_header("swapline.csv", "step,frames,on_vcount_min,on_vcount_max,off_vcount_min,off_vcount_max,timeouts\n");
	for (int i = 0; i < 5; i++) run(i + 1, &s_steps[i]);
	set_swap(1);
	consoleSelect(s_bot);
	consoleClear();
	iprintf("swapline done: results in\n%s/swapline.csv\n", HWREF_DIR);
	hw_done();
}
