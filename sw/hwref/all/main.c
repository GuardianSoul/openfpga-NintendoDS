// hwref.nds: the hardware-reference programs in one launch (docs/hw-reference.md).
// A menu picks what runs: by default only the steps not yet run on the DS
// (NEW_STEPS), or the full run, or one program.
// Each program is built unchanged with its main() renamed and its symbols
// made local (Makefile), then called in turn; hw_done() returns here. gxtime
// skips its hang-suspect phase in this mode (gxtime.nds still has it).
#include "../common/hwref.h"
#include <stdio.h>
#include <string.h>

int hwref_main_memtime(void);
int hwref_main_gxtime(void);
int hwref_main_cap3d(void);
int hwref_main_rules3d(void);
int hwref_main_sndcap(void);
int hwref_main_rand3d(void);
int hwref_main_replay3d(void);
int hwref_main_gxcount(void);
int hwref_main_dmacpu(void);
int hwref_main_cputime(void);
int hwref_main_lat2d(void);
int hwref_main_load3d(void);
int hwref_main_vramcnt(void);
int hwref_main_gxburst(void);
int hwref_main_sndq(void);
int hwref_main_late3d(void);
int hwref_main_tmcnt(void);
int hwref_main_wbuf(void);
int hwref_main_cacheorg(void);
int hwref_main_openq(void);
int hwref_main_dmaslip(void);
int hwref_main_gxlatency(void);
int hwref_main_rdtimeline(void);

// secs: expected time on the DS, shown in the menu; new_secs in "new only".
// first: runs before the others (a step that can't hang, ahead of riskier ones).
static const struct { const char* name; int (*fn)(void); int secs, new_secs; bool first; } s_steps[] = {
#ifdef HWREF_SPEED_TRIP
	{ "late3d_v2", hwref_main_late3d, 5, 5, true },
	{ "gxlatency_v4", hwref_main_gxlatency, 180, 180, false },
	{ "rdtimeline_v1", hwref_main_rdtimeline, 3, 3, true },
#else
	{ "memtime", hwref_main_memtime, 2 },
	{ "gxtime",  hwref_main_gxtime, 15 },
	{ "cap3d",   hwref_main_cap3d, 15 },
	{ "rules3d", hwref_main_rules3d, 20, 4 },
	// replay3d and rand3d need megabytes of heap and free it all again;
	// sndcap keeps its last buffers, so it runs last.
	{ "replay3d", hwref_main_replay3d, 25, 15 },
	{ "rand3d",  hwref_main_rand3d, 200 },
	{ "sndcap",  hwref_main_sndcap, 40 },
	// gxcount has quad strips, which once hung the DS: last, so a hang
	// loses nothing else.
	{ "gxcount", hwref_main_gxcount, 3 },
	{ "dmacpu",  hwref_main_dmacpu, 3 },
	{ "cputime", hwref_main_cputime, 3 },
	{ "lat2d",   hwref_main_lat2d, 20, 10 },
	{ "load3d",  hwref_main_load3d, 8 },
	{ "vramcnt", hwref_main_vramcnt, 2 },
	{ "gxburst", hwref_main_gxburst, 120, 30 },
	{ "sndq",    hwref_main_sndq, 5 },
	{ "late3d",  hwref_main_late3d, 5 },
	{ "tmcnt",   hwref_main_tmcnt, 1 },
	{ "wbuf",    hwref_main_wbuf, 1, 0, true },   // fixed code only: ahead of memtime v2's GX part
	{ "cacheorg", hwref_main_cacheorg, 1 },
	{ "dmaslip", hwref_main_dmaslip, 6 },
	// openq writes CP15 and the abort vector: last
	{ "openq",   hwref_main_openq, 1 },
#endif
};

#ifdef HWREF_SPEED_TRIP
#define ALL_PROGRESS HWREF_DIR "/hwref_speed_progress.txt"
#else
#define ALL_PROGRESS HWREF_DIR "/hwref_all_progress.txt"
#endif

static void log_line(const char* s)
{
	if (!hw_fat_ok) return;
	FILE* f = fopen(ALL_PROGRESS, "a");
	if (f) { fputs(s, f); fputc('\n', f); fclose(f); }
}

// The steps not yet run on the DS (the menu's default): update with each
// staged batch. Bit i = s_steps[i].
#ifdef HWREF_SPEED_TRIP
#define NEW_STEPS 7u // only late3d v2 restart, GX v4 and three new raster timelines
#else
#define NEW_STEPS (1u << 19)   // legacy menu; never shipped for the speed trip
#endif

#ifdef HWREF_SPEED_TRIP
static u32 completed_steps(int n)
{
	FILE* f=fopen(ALL_PROGRESS,"rb");
	if(!f)return 0;
	u32 done=0;char line[96],name[64];
	while(fgets(line,sizeof line,f))
		if(sscanf(line,"done %63s",name)==1)
			for(int i=0;i<n;i++)if(!strcmp(name,s_steps[i].name))done|=1u<<i;
	fclose(f);return done;
}
#endif

static int secs_of(u32 mask, bool new_only)
{
	int t = 0;
	for (int i = 0; i < (int)(sizeof s_steps / sizeof s_steps[0]); i++)
		if (mask >> i & 1) t += new_only && s_steps[i].new_secs ? s_steps[i].new_secs : s_steps[i].secs;
	return t;
}

static void fmt_time(char* b, int secs)
{
	if (secs < 90) sprintf(b, "about %d s", secs);
	else sprintf(b, "about %d min", (secs + 30) / 60);
}

// New only (default, starts by itself after 10 s), full run, or one
// program. Up/Down choose, Left/Right pick the program, A starts.
static u32 menu(int n)
{
	int sel = 0, prog = 0, frames = 600;
	bool touched = false;
	for (;;) {
		char t0[32], t1[32], t2[32];
		fmt_time(t0, secs_of(NEW_STEPS, true));
		fmt_time(t1, secs_of((1u << n) - 1, false));
		fmt_time(t2, s_steps[prog].secs);
		iprintf("\x1b[2J" "hwref - DS hardware reference\n\n");
		iprintf("%c New only (", sel == 0 ? '>' : ' ');
		for (int i = 0, first = 1; i < n; i++)
			if (NEW_STEPS >> i & 1) { iprintf("%s%s", first ? "" : ", ", s_steps[i].name); first = 0; }
		iprintf(")\n    %s\n", t0);
		iprintf("%c Full run, all %d programs\n    %s\n", sel == 1 ? '>' : ' ', n, t1);
		iprintf("%c One program: < %s >\n    %s\n\n", sel == 2 ? '>' : ' ', s_steps[prog].name, t2);
		iprintf("Up/Down choose, Left/Right\nprogram, A start\n");
		if (!touched) iprintf("\nNew only starts in %d s", (frames + 59) / 60);
		swiWaitForVBlank();
		scanKeys();
		u32 k = keysDown();
		if (k) touched = true;
		if (k & KEY_UP) sel = (sel + 2) % 3;
		if (k & KEY_DOWN) sel = (sel + 1) % 3;
		if (k & KEY_LEFT) { prog = (prog + n - 1) % n; sel = 2; }
		if (k & KEY_RIGHT) { prog = (prog + 1) % n; sel = 2; }
		if ((k & KEY_A) || (!touched && --frames <= 0)) {
			hw_new_only = sel == 0;
			return sel == 0 ? NEW_STEPS : sel == 1 ? (1u << n) - 1 : 1u << prog;
		}
	}
}

int main(void)
{
	static jmp_buf jb;
	hw_chain = &jb;
	int n = sizeof s_steps / sizeof s_steps[0];
	hw_init("hwref - all programs");
#ifndef HWREF_SPEED_TRIP
	remove(ALL_PROGRESS);
#endif
#ifdef HWREF_STEPS   // debugging (and melonDS runs): a bit mask of the steps, no menu
	u32 run = HWREF_STEPS;
#else
	u32 run = menu(n);
#endif
#ifdef HWREF_SPEED_TRIP
	// Re-enter an interrupted program: its own case journal skips the hung
	// case. Completed programs remain untouched, even on repeated launches.
	run &= ~completed_steps(n);
#endif
	{
		char line[48];
		snprintf(line, sizeof line, "steps %02lx", (unsigned long)run);
		log_line(line);
	}
	for (volatile int j = 0; j < 2 * n; j++) {
		char line[64];
		int i = j % n;
		if (!(run >> i & 1) || s_steps[i].first != (j < n)) continue;
		if (!setjmp(jb)) {
			snprintf(line, sizeof line, "start %s", s_steps[i].name);
			log_line(line);
			s_steps[i].fn();
		}
		snprintf(line, sizeof line, "done  %s", s_steps[i].name);
		log_line(line);
		swiWaitForVBlank();
	}
	hw_chain = NULL;
	consoleDemoInit();
	iprintf("hwref - all programs\n\n");
	for (int i = 0; i < n; i++)
		if (run >> i & 1) iprintf("  %s: done\n", s_steps[i].name);
	log_line("all done");
	hw_done();
}
