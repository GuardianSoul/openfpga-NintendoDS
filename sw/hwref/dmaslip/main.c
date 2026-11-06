// dmaslip (docs/hw-reference.md "dmaslip"; integration session): does an
// ARM9 main-RAM access that is not to the DMA's destination wait for a whole
// running ARM9 DMA, or slip in between its units? Run 22 (dmacpu collide)
// only measured accesses to the destination, which wait for the whole DMA.
// The case that matters is main RAM -> GX FIFO (MKDS); the core blocks the
// ARM9 for the whole DMA.
//
// A trial (run.itcm.c): TM0/TM1 read, DMA3 started (immediate, 32-bit), n
// delay loops in ITCM (they run during the DMA), the access, l work loops in
// ITCM, TM0/TM1 read. The work loops (≈30,000 system cycles) outlast every
// DMA here, so the final timer read never waits for the DMA itself:
//   slips in:  time ≈ the same trial without a DMA, plus a few units
//   waits:     time ≈ that plus the DMA's remaining length (falling with n)
// Accesses (kind):
//   none       no access (the baseline)
//   dfill      a D-cache line fill from a cleaned + invalidated main-RAM line
//   uncached   a load from main RAM under MPU region 3, C=0 B=0
//   srcfill    a D-cache line fill from the DMA source's last line (not yet
//              read by the DMA at small n)
//   ifill      a BLX to a cold I-cache line of main RAM (BX LR)
//   ustore     a store to main RAM under region 3, C=0 B=0 (unbuffered)
//   ioread     a load from DISPCNT (I/O)
// DMA routes: nodma; main_main 512 words (destination a separate buffer);
// main_vram 2,048 words to VRAM A (LCDC); gxfifo 2,048 words of 0 (packed
// NOP headers: one NOP each, the engine never blocks) to 0x04000400, last.
// Each kind and delay (target 0, 50, 500, 2,000, 6,000, 14,000 system cycles)
// runs 8 timed trials, then 4 flagged ones that also read DMA3CNT right
// after the access (busy = how many saw bit 31 still set; that read is I/O,
// so it may wait itself: compare with ioread). dma_len rows: no delay or
// work loops, so the timer read lands when an I/O read can (the DMA's end if
// I/O waits). dmaslip.csv:
// route,kind,n_target,n_loops,l_loops,flag,trials,min,max,avg_x100,busy.
//
// Hang-safe: bounded waits only (DMA end, GX idle), the GX FIFO gets NOPs
// only and must be idle and empty before every GX trial (a timeout ends the
// gxfifo step with a timeout row); each route's rows are written as it ends;
// dmaslip_progress.txt ("V <version>", "start <route>", "done <route>"): a
// restart on the same card skips the routes that ended and the one that
// began without ending.
#include "dmaslip.h"
#include <malloc.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VERSION "dmaslip 1"
#define WORDS 2048
#define RG 3
#define DMA_ON (1u << 31)
#define DMA_32 (1u << 26)
#define DMA_DFIX (2u << 21)

static u32* s_src;    // WORDS, cached main RAM, zeros (the GX NOPs)
static u32* s_dst;    // main_main's destination
static u8* s_dbuf;    // 4 KiB cached: dfill lines
static u8* s_ubuf;    // 4 KiB under region 3, uncached
static u32* s_code;   // 4 KiB of BX LR: ifill lines
static u32 s_rg_saved, s_dc_saved, s_wb_saved, s_dp_saved;
static u32 s_cpl_x100;   // system cycles per delay loop x 100
static Buf s_csv;
static u32 s_gx_timeouts;

static bool region_set(void)
{
	s_rg_saved = armMpuGetRegion(RG);
	if (s_rg_saved & 1) return false;   // in use
	s_dc_saved = armMpuGetDCacheConfig();
	s_wb_saved = armMpuGetWrBufConfig();
	s_dp_saved = armMpuGetDataPerm();
	ArmIrqState st = armIrqLockByPsr();
	armDCacheFlushAll();
	armMpuSetRegionDataPerm(RG, CP15_PU_PERM_RW);
	armMpuSetRegionDCacheEnable(RG, 0);
	armMpuSetRegionWrBufEnable(RG, 0);
	armMpuSetRegion(RG, armMpuDefineRegion((uptr)s_ubuf, CP15_PU_4K));
	armIrqUnlockByPsr(st);
	return true;
}
static void region_restore(void)
{
	ArmIrqState st = armIrqLockByPsr();
	armDCacheFlushAll();
	armMpuSetRegion(RG, s_rg_saved);
	armMpuSetDCacheConfig(s_dc_saved);
	armMpuSetWrBufConfig(s_wb_saved);
	armMpuSetDataPerm(s_dp_saved);
	armIrqUnlockByPsr(st);
}

static bool gx_idle(void)
{
	for (u32 i = 0; i < 2000000; i++) {
		u32 st = R_GXSTAT;
		if (!(st & GXSTAT_BUSY) && GXSTAT_LEVEL(st) == 0) return true;
	}
	s_gx_timeouts++;
	return false;
}

typedef struct { const char* name; u32 dst, ctl; bool gx; } Route;
typedef struct { const char* name; u32 kind, prep; } Kind;
static const Kind s_kinds[] = {
	{ "none", K_NONE, P_NONE }, { "dfill", K_LOAD, P_DLINE }, { "uncached", K_LOAD, P_NONE },
	{ "srcfill", K_LOAD, P_DLINE }, { "ifill", K_CALL, P_ILINE }, { "ustore", K_STORE, P_NONE },
	{ "ioread", K_LOAD, P_NONE },
};
#define NKIND (int)(sizeof s_kinds / sizeof s_kinds[0])
static const u16 s_targets[] = { 0, 50, 500, 2000, 6000, 14000 };
#define NT (int)(sizeof s_targets / sizeof s_targets[0])
#define L_TARGET 30000   // outlasts the GX DMA even at 3x the DS's 5 cycles a word

static u32 loops(u32 cyc) { return cyc ? (cyc * 100 + s_cpl_x100 / 2) / s_cpl_x100 : 0; }

static u32 addr_of(int k, u32 words, u32 trial)
{
	u32 line = (trial & 63) * 32;   // a different line each trial
	switch (k) {
	case 1: return (u32)s_dbuf + line;
	case 2: case 5: return (u32)s_ubuf + line;
	case 3: return (u32)&s_src[words - 8];
	case 4: return (u32)s_code + line;
	case 6: return 0x04000000;
	}
	return 0;
}

// one configuration: a warm-up trial, then trials; false: GX timeout
static bool config(const Route* r, int k, u32 n, u32 l, u32 flag, u32 trials, const char* label, unsigned ntarget)
{
	u32 words = r->ctl ? (r->ctl & 0xFFFF ? r->ctl & 0xFFFF : 0x10000) : WORDS;
	u32 mn = ~0u, mx = 0, sum = 0, busy = 0;
	for (u32 i = 0; i <= trials; i++) {
		if (r->gx && !gx_idle()) {
			buf_printf(&s_csv, "%s,%s,%u,%lu,%lu,%lu,timeout,0,0,0,0\n", r->name, label, ntarget, (unsigned long)n,
			           (unsigned long)l, (unsigned long)flag);
			return false;
		}
		DsTrial t = { (u32)s_src, r->dst, r->ctl, s_kinds[k].kind, s_kinds[k].prep, addr_of(k, words, i), n, l, flag };
		u32 c;
		ArmIrqState st = armIrqLockByPsr();
		u32 v = ds_trial(&t, &c);
		armIrqUnlockByPsr(st);
		if (!i) continue;   // warm-up
		if (v < mn) mn = v;
		if (v > mx) mx = v;
		sum += v;
		busy += (c >> 31) & 1;
	}
	buf_printf(&s_csv, "%s,%s,%u,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu\n", r->name, label, ntarget, (unsigned long)n, (unsigned long)l,
	           (unsigned long)flag, (unsigned long)trials, (unsigned long)mn, (unsigned long)mx,
	           (unsigned long)(sum * 100 / trials), (unsigned long)busy);
	return true;
}

static void route(const Route* r)
{
	u32 l = loops(L_TARGET);
	bool ok = true;
	for (u32 f = 0; f < 2 && ok; f++) ok = config(r, 0, 0, 0, f, f ? 4 : 8, "dma_len", 0);
	for (int k = 0; k < NKIND && ok; k++)
		for (int j = 0; j < NT && ok; j++)
			for (u32 f = 0; f < 2 && ok; f++)
				ok = config(r, k, loops(s_targets[j]), l, f, f ? 4 : 8, s_kinds[k].name, s_targets[j]);
	if (r->gx) gx_idle();
}

static void progress(const char* fmt, ...)
{
	if (!hw_fat_ok) return;
	FILE* f = fopen(HWREF_DIR "/dmaslip_progress.txt", "a");
	if (!f) return;
	va_list ap;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

#define NROUTE 4
static char s_skip[NROUTE + 1][16];
static int s_nskip;
static bool s_resume;
static void load_progress(void)
{
	FILE* f = fopen(HWREF_DIR "/dmaslip_progress.txt", "r");
	if (!f) return;
	char line[96], open_t[16] = "";
	bool ours = false, all = false;
	while (fgets(line, sizeof line, f)) {
		char nm[16];
		if (!strncmp(line, "V " VERSION, 2 + strlen(VERSION))) ours = true;
		else if (!strncmp(line, "all done", 8)) all = true;
		else if (sscanf(line, "start %15s", nm) == 1) strcpy(open_t, nm);
		else if (sscanf(line, "done %15s", nm) == 1) { if (s_nskip < NROUTE) strcpy(s_skip[s_nskip++], nm); open_t[0] = 0; }
	}
	fclose(f);
	if (!ours || all) { s_nskip = 0; return; }
	s_resume = true;
	if (open_t[0] && s_nskip <= NROUTE) strcpy(s_skip[s_nskip++], open_t);
}
static bool skipped(const char* t)
{
	for (int i = 0; i < s_nskip; i++) if (!strcmp(s_skip[i], t)) return true;
	return false;
}

int main(void)
{
	hw_init(VERSION " - ARM9 access during DMA");
	iprintf(VERSION " - ARM9 access\nduring a DMA\n\n");
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\n", VERSION, __DATE__, __TIME__);
	s_src = memalign(32, WORDS * 4);
	s_dst = memalign(32, WORDS * 4);
	s_dbuf = memalign(32, 4096);
	s_ubuf = memalign(4096, 4096);
	s_code = memalign(32, 4096);
	bool ok = s_src && s_dst && s_dbuf && s_ubuf && s_code;
	if (ok) {
		memset(s_src, 0, WORDS * 4);
		memset(s_dst, 0, WORDS * 4);
		memset(s_dbuf, 0x5A, 4096);
		memset(s_ubuf, 0x5A, 4096);
		for (int i = 0; i < 1024; i++) s_code[i] = 0xE12FFF1E;   // bx lr
		armDCacheFlushAll();
		armICacheInvalidateAll();
		ok = region_set();
	}
	if (ok) {
		u8 vramcnt_a = R_VRAMCNT(0);
		u16 powcnt = R_POWCNT1;
		R_VRAMCNT(0) = 0x80;   // A: LCDC
		ArmIrqState st = armIrqLockByPsr();
		u32 cal = ds_spin_cal(20000);
		armIrqUnlockByPsr(st);
		s_cpl_x100 = cal / 200;
		if (s_cpl_x100 < 50) s_cpl_x100 = 50;
		buf_printf(&info, "delay loop: 20000 loops %lu system cycles (%lu.%02lu each); work loops %lu\n", (unsigned long)cal,
		           (unsigned long)s_cpl_x100 / 100, (unsigned long)s_cpl_x100 % 100, (unsigned long)loops(L_TARGET));
		if (hw_fat_ok) load_progress();
		if (!s_resume) {
			remove(HWREF_DIR "/dmaslip_progress.txt");
			progress("V " VERSION);
			Buf h = {0};
			buf_printf(&h, "route,kind,n_target,n_loops,l_loops,flag,trials,min,max,avg_x100,busy\n");
			buf_write(&h, "dmaslip.csv");
		}
		const Route rs[NROUTE] = {
			{ "nodma", 0, 0, false },
			{ "main_main", (u32)s_dst, DMA_ON | DMA_32 | 512, false },
			{ "main_vram", 0x06800000, DMA_ON | DMA_32 | WORDS, false },
			{ "gxfifo", 0x04000400, DMA_ON | DMA_32 | DMA_DFIX | WORDS, true },
		};
		for (int i = 0; i < NROUTE; i++) {
			if (skipped(rs[i].name)) continue;
			progress("start %s", rs[i].name);
			iprintf("\x1b[6;0H%-12s", rs[i].name);
			if (rs[i].gx) R_POWCNT1 = powcnt | (1u << 2) | (1u << 3);   // 3D rendering and geometry on
			route(&rs[i]);
			if (rs[i].gx) R_POWCNT1 = powcnt;
			if (hw_fat_ok) {
				FILE* f = fopen(HWREF_DIR "/dmaslip.csv", "a");
				if (f) { fwrite(s_csv.p, 1, s_csv.len, f); fclose(f); }
			}
			free(s_csv.p);
			s_csv = (Buf){0};
			progress("done %s", rs[i].name);
		}
		progress("all done");
		R_VRAMCNT(0) = vramcnt_a;
		region_restore();
	}
	buf_printf(&info, "buffers src %08lx dst %08lx dbuf %08lx ubuf %08lx code %08lx; gx timeouts %lu%s\n",
	           (unsigned long)(u32)s_src, (unsigned long)(u32)s_dst, (unsigned long)(u32)s_dbuf, (unsigned long)(u32)s_ubuf,
	           (unsigned long)(u32)s_code, (unsigned long)s_gx_timeouts, ok ? "" : " NOT RUN (no buffer or region 3 in use)");
	buf_write(&info, "dmaslip_info.txt");
	free(s_src); free(s_dst); free(s_dbuf); free(s_ubuf); free(s_code);
	hw_done();
}
