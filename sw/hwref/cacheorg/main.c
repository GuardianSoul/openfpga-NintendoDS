// cacheorg (docs/hw-reference.md "cacheorg"; coordinator, CPU session): the
// ARM946E-S cache organisation on the DS. MKDS's 30 fps is ARM9 cache bound,
// and the core is choosing its D/I cache ways: measure what the DS has.
//
// A 256 KiB main-RAM buffer (calico's region 1: C=1 B=1, I-cache on) filled
// with BX LR. A trial empties the cache, then the ITCM walker (run.itcm.c)
// touches a list of lines (D: LDR, I: BLX) and times the last access(es)
// with TM0 (system cycles). Hit or miss by a threshold halfway between the
// calibrated hit and miss times (at least 4 above a hit). Per cache (D, I) and CP15 c1 bit 14 (RR: 1
// round-robin, calico's and MKDS's setting; 0 random):
//   calib     hit (a line just loaded) and miss (after the empty)
//   grid      N lines at a stride S, then the first again: misses of that
//             access over the trials. Lines S = way size apart share a set:
//             the first misses once N > ways; at S = way size / 2 they spread
//             over two sets (2 x ways). S 256 B - 8 KiB, N 1-17.
//   inter     grid at S = 8 KiB with a line of another set (+32) after each:
//             a global round-robin counter (one per cache) skips a way per
//             extra fill, a per-set one doesn't
//   victim    4 lines of one set, a 5th, then line j (0-3): which was evicted
//   capacity  K KiB of consecutive lines, twice: system cycles per line of
//             the second pass (misses start above the cache size)
// cacheorg.csv: cache,rr,test,stride,n,j,trials,misses,min,max,avg_x100.
// cacheorg_info.txt: CP15 control, cache type (c0,c0,1) and TCM size.
//
// Hang-safe: no waits on hardware (fixed loops over fixed lists), the
// buffer is BX LR everywhere, so any line can be called; each step's rows
// written as it ends; cacheorg_progress.txt ("V <version>", "start <step>",
// "done <step>"): a restart on the same card skips the steps that ended and
// the one that began without ending. CP15 control is set back after each step.
#include "cacheorg.h"
#include <malloc.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VERSION "cacheorg 1"
#define BUFSZ (256 * 1024)
#define MAXL 512
static u32 s_list[MAXL] DTCM_BSS;
static u8* s_buf;   // 8 KiB aligned

// CP15 access needs ARM state (this file is Thumb)
#define ARMFN __attribute__((target("arm"), noinline))
#define MRC(r) ({ u32 v_; __asm__ __volatile__("mrc p15, 0, %0, " r : "=r"(v_)); v_; })
ARMFN static u32 ctrl_get(void) { return MRC("c1, c0, 0"); }
ARMFN static u32 cachetype_get(void) { return MRC("c0, c0, 1"); }
ARMFN static u32 tcmsize_get(void) { return MRC("c0, c0, 2"); }
ARMFN static void ctrl_set(u32 v) { __asm__ volatile("mcr p15, 0, %0, c1, c0, 0" :: "r"(v) : "memory"); }

static u32 trial(u32 n, u32 passes, u32 ntimed, int kind)
{
	ArmIrqState st = armIrqLockByPsr();
	u32 t = co_trial(s_list, n, passes, ntimed, kind);
	armIrqUnlockByPsr(st);
	return t;
}

typedef struct { u32 trials, misses, min, max, sum; } Stat;
static u32 s_thr;
static Stat repeat(u32 n, u32 passes, u32 ntimed, int kind, int trials)
{
	Stat s = { 0, 0, ~0u, 0, 0 };
	for (int i = 0; i < trials; i++) {
		u32 t = trial(n, passes, ntimed, kind);
		s.trials++;
		s.misses += t > s_thr;
		if (t < s.min) s.min = t;
		if (t > s.max) s.max = t;
		s.sum += t;
	}
	return s;
}

static Buf s_csv;
static const char* s_cache;
static int s_rr;
static void row(const char* test, u32 stride, u32 n, int j, Stat s, u32 per)
{
	buf_printf(&s_csv, "%s,%d,%s,%lu,%lu,%d,%lu,%lu,%lu,%lu,%lu\n", s_cache, s_rr, test, (unsigned long)stride,
	           (unsigned long)n, j, (unsigned long)s.trials, (unsigned long)s.misses, (unsigned long)s.min,
	           (unsigned long)s.max, (unsigned long)((u64)s.sum * 100 / (s.trials * per)));
}

static u32 A(u32 off) { return (u32)s_buf + off; }

static void step(int kind, int rr)
{
	s_cache = kind == CO_D ? "d" : "i";
	s_rr = rr;
	u32 saved = ctrl_get();
	ctrl_set(rr ? saved | (1u << 14) : saved & ~(1u << 14));
	// calibration: threshold halfway between hit and miss
	s_thr = ~0u;
	s_list[0] = A(0); s_list[1] = A(0);
	Stat hit = repeat(2, 1, 1, kind, 32);
	Stat miss = repeat(1, 1, 1, kind, 32);
	// at least 4 above a hit (melonDS: no miss cost, so nothing counts as a miss)
	s_thr = hit.min + (miss.min > hit.min + 8 ? (miss.min - hit.min) / 2 : 4);
	hit = repeat(2, 1, 1, kind, 32);
	miss = repeat(1, 1, 1, kind, 32);
	row("calib_hit", 0, 1, -1, hit, 1);
	row("calib_miss", 0, 1, -1, miss, 1);
	buf_printf(&s_csv, "%s,%d,threshold,0,0,-1,0,0,%lu,%lu,0\n", s_cache, rr, (unsigned long)s_thr, (unsigned long)s_thr);
	// grid
	static const u16 strides[] = { 256, 512, 1024, 2048, 4096, 8192 };
	for (unsigned k = 0; k < sizeof strides / sizeof strides[0]; k++)
		for (u32 n = 1; n <= 17; n++) {
			for (u32 i = 0; i < n; i++) s_list[i] = A(i * strides[k]);
			s_list[n] = A(0);
			row("grid", strides[k], n, -1, repeat(n + 1, 1, 1, kind, 16), 1);
		}
	// inter: a line of the next set after each
	for (u32 n = 1; n <= 10; n++) {
		for (u32 i = 0; i < n; i++) { s_list[2 * i] = A(i * 8192); s_list[2 * i + 1] = A(i * 8192 + 32); }
		s_list[2 * n] = A(0);
		row("inter", 8192, n, -1, repeat(2 * n + 1, 1, 1, kind, 32), 1);
	}
	// victim: lines 0-3, line 4, then line j (j = 4: the line just loaded)
	for (int j = 0; j <= 4; j++) {
		for (u32 i = 0; i < 5; i++) s_list[i] = A(i * 8192);
		s_list[5] = A(j * 8192);
		row("victim", 8192, 5, j, repeat(6, 1, 1, kind, 64), 1);
	}
	// capacity: K KiB of consecutive lines, the second pass timed (per line;
	// the misses column is unused)
	s_thr = ~0u;
	for (u32 kb = 1; kb <= 16; kb++) {
		u32 n = kb * 32;
		for (u32 i = 0; i < n; i++) s_list[i] = A(i * 32);
		row("capacity", 32, n, -1, repeat(n, 2, n, kind, 8), n);
	}
	ctrl_set(saved);
}

static void progress(const char* fmt, ...)
{
	if (!hw_fat_ok) return;
	FILE* f = fopen(HWREF_DIR "/cacheorg_progress.txt", "a");
	if (!f) return;
	va_list ap;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

#define NSTEP 4
static char s_skip[NSTEP + 1][16];
static int s_nskip;
static bool s_resume;
static void load_progress(void)
{
	FILE* f = fopen(HWREF_DIR "/cacheorg_progress.txt", "r");
	if (!f) return;
	char line[96], open_t[16] = "";
	bool ours = false, all = false;
	while (fgets(line, sizeof line, f)) {
		char nm[16];
		if (!strncmp(line, "V " VERSION, 2 + strlen(VERSION))) ours = true;
		else if (!strncmp(line, "all done", 8)) all = true;
		else if (sscanf(line, "start %15s", nm) == 1) strcpy(open_t, nm);
		else if (sscanf(line, "done %15s", nm) == 1) { if (s_nskip < NSTEP) strcpy(s_skip[s_nskip++], nm); open_t[0] = 0; }
	}
	fclose(f);
	if (!ours || all) { s_nskip = 0; return; }
	s_resume = true;
	if (open_t[0] && s_nskip <= NSTEP) strcpy(s_skip[s_nskip++], open_t);
}
static bool skipped(const char* t)
{
	for (int i = 0; i < s_nskip; i++) if (!strcmp(s_skip[i], t)) return true;
	return false;
}

int main(void)
{
	hw_init(VERSION " - ARM9 cache organisation");
	iprintf(VERSION " - ARM9 caches\n\n");
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\ncp15 control %08lx cache type %08lx tcm size %08lx\n", VERSION, __DATE__, __TIME__,
	           (unsigned long)ctrl_get(), (unsigned long)cachetype_get(), (unsigned long)tcmsize_get());
	buf_printf(&info, "dcache_config %08lx icache_config %08lx region1 %08lx\n", (unsigned long)armMpuGetDCacheConfig(),
	           (unsigned long)armMpuGetICacheConfig(), (unsigned long)armMpuGetRegion(1));
	s_buf = memalign(8192, BUFSZ);
	if (s_buf) {
		for (u32 i = 0; i < BUFSZ; i += 4) *(u32*)(s_buf + i) = 0xE12FFF1E;   // bx lr
		armDCacheFlushAll();
		armICacheInvalidateAll();
		if (hw_fat_ok) load_progress();
		if (!s_resume) {
			remove(HWREF_DIR "/cacheorg_progress.txt");
			progress("V " VERSION);
			Buf h = {0};
			buf_printf(&h, "cache,rr,test,stride,n,j,trials,misses,min,max,avg_x100\n");
			buf_write(&h, "cacheorg.csv");
		}
		static const struct { const char* name; int kind, rr; } st[NSTEP] = {
			{ "d_rr1", CO_D, 1 }, { "d_rr0", CO_D, 0 }, { "i_rr1", CO_I, 1 }, { "i_rr0", CO_I, 0 },
		};
		for (int k = 0; k < NSTEP; k++) {
			if (skipped(st[k].name)) continue;
			progress("start %s", st[k].name);
			iprintf("\x1b[6;0H%-12s", st[k].name);
			step(st[k].kind, st[k].rr);
			if (hw_fat_ok) {
				FILE* f = fopen(HWREF_DIR "/cacheorg.csv", "a");
				if (f) { fwrite(s_csv.p, 1, s_csv.len, f); fclose(f); }
			}
			free(s_csv.p);
			s_csv = (Buf){0};
			progress("done %s", st[k].name);
		}
		progress("all done");
	}
	buf_printf(&info, "buffer %08lx%s\n", (unsigned long)(u32)s_buf, s_buf ? "" : " NOT ALLOCATED: nothing run");
	buf_write(&info, "cacheorg_info.txt");
	hw_done();
}
