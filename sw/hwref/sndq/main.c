// sndq (docs/hw-reference.md "sndq"; sound session): four mixer/capture
// questions, with sndcap's per-segment procedure (calico's sound API; test
// channels prepared, channels 0..3 not under test silent at the capture
// timer, everything started in one soundStart mask, one-shot captures of L
// and R, bounded wait):
//   s1_cap8:   8-bit capture rounding. Channel 4 plays a PCM16 staircase of
//              160 levels, 32 samples each (64 over the full range, then
//              v-1, v, v+1 around 32 multiples of 256), vol 127 div 0, pan
//              64, timer 512 = capture timer; unit 0 captures 8-bit, unit 1
//              16-bit (the reference).
//   s2_lag_t<T>: capture start phase. Channel 4: 256 zero samples, then
//              0x4000 (looped); channel timer T, capture timer 512, 16-bit.
//   s3_sat_<n><+|->: n channels (0..n-1) of PCM16 DC +32767 or -32768, vol
//              127 div 0, pan 64, timer 512; master volume 127, SOUNDBIAS as
//              calico leaves it; 16-bit capture of the mixer.
//   s4_src_<case>: unit 0 captures channel 0 (SNDCAPxCNT bit 1), unit 1 the
//              right mixer; channel 0 DC 0x4000, channel 1 DC 0x1234 at full
//              volume. Cases: vol 64 div 0 pan 0, vol 64 div 0 pan 127, vol
//              127 div 0 pan 64, vol 64 div 2 pan 64.
// v2 (run 30 hung at s2_lag_t520's start; S1 pinned by the sound session):
// order S3, S4, S2 (15 timers 520-2048), S1; resumable (load_progress).
// v3 (run 31: S3 and S4 measured; every S2 segment whose capture buffer
// isn't a whole number of cache lines hung the DS, see seg()): S2 first,
// buffers in whole cache lines, the progress file versioned.
// Files sndq_<seg>_{L,R}.bin: raw captures (8-bit units as s8), and
// sndq_index.csv: segment, unit, format, samples, unwritten, timeout.
#include "../common/hwref.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VERSION "sndq 3"
#define CAP_TIMER 512
#define SENTINEL 0x5A5A5A5Au
#define NLEV 160
#define LEVN 32
#define VOL(v7, div) ((div) == 0 ? (v7) << 4 : (div) == 1 ? (v7) << 3 : (div) == 2 ? (v7) << 2 : (v7))   // calico's 11-bit volume

static s16 s_stair[NLEV * LEVN] __attribute__((aligned(32)));
static s16 s_step[512] __attribute__((aligned(32)));
static s16 s_dcp[8] __attribute__((aligned(32))), s_dcn[8] __attribute__((aligned(32)));
static s16 s_dc4000[8] __attribute__((aligned(32))), s_dc1234[8] __attribute__((aligned(32)));
static u32 s_zero[8] __attribute__((aligned(32)));
static int s_lev[NLEV];

typedef struct { u8 ch, pan; u16 vol, timer; const void* data; u16 pnt, len; } V;   // pnt/len in words

static void progress(const char* fmt, ...)
{
	if (!hw_fat_ok) return;
	char line[128];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof line, fmt, ap);
	va_end(ap);
	FILE* f = fopen(HWREF_DIR "/sndq_progress.txt", "a");
	if (f) { fputs(line, f); fputc('\n', f); fclose(f); }
}

static void busy_wait(u32 cycles) { u32 t0 = now32(); while (now32() - t0 < cycles) {} }

// v2: resumable. sndq_progress.txt gets "start <seg>" and "done <seg>"; a
// start that finds the file without "all done" skips every segment that
// ended and the one that began without ending (a hang inside calico's sound
// calls, which can't be bounded from here), and appends to sndq_index.csv.
#define MAXSKIP 64
static char s_skip[MAXSKIP][24];
static int s_nskip;
static bool s_resume;
static bool skipped(const char* name)
{
	for (int i = 0; i < s_nskip; i++) if (!strcmp(s_skip[i], name)) return true;
	return false;
}
static void load_progress(void)
{
	FILE* f = fopen(HWREF_DIR "/sndq_progress.txt", "r");
	if (!f) return;
	char line[96], open_seg[24] = "";
	bool all = false, ours = false;
	while (fgets(line, sizeof line, f)) {
		char nm[24];
		if (!strncmp(line, "V " VERSION, 2 + strlen(VERSION))) ours = true;   // another version's file starts afresh
		if (!strncmp(line, "all done", 8)) all = true;
		else if (sscanf(line, "start %23s", nm) == 1) strcpy(open_seg, nm);
		else if (sscanf(line, "done %23s", nm) == 1) {
			if (s_nskip < MAXSKIP) strcpy(s_skip[s_nskip++], nm);
			open_seg[0] = 0;
		}
	}
	fclose(f);
	if (all || !ours) { s_nskip = 0; return; }
	s_resume = true;
	if (open_seg[0] && s_nskip < MAXSKIP) strcpy(s_skip[s_nskip++], open_seg);
}

static void seg(const char* name, const V* v, int nv, int fmt0, int src0, u32 nsamp, Buf* idx)
{
	if (skipped(name)) return;
	progress("start %s", name);
	u32 bytes[2] = { fmt0 ? nsamp : nsamp * 2, nsamp * 2 };
	u32* cap[2];
	for (int u = 0; u < 2; u++) {
		// whole cache lines: the end-of-capture check invalidates the line of
		// the last word, which must not hold anything else (run 31: a buffer
		// ending mid-line lost the heap's dirty data and hung the DS)
		cap[u] = aligned_alloc(32, (bytes[u] + 31) & ~31u);
		if (!cap[u]) { buf_printf(idx, "%s,%d,out of memory\n", name, u); return; }
		for (u32 i = 0; i < bytes[u] / 4; i++) cap[u][i] = SENTINEL;
		armDCacheFlush(cap[u], bytes[u]);
	}
	soundStop(0x3FFFF);
	soundSetMixerVolume(127);
	u32 used = 0;
	for (int i = 0; i < nv; i++) used |= 1u << v[i].ch;
	for (int c = 0; c < 4; c++)
		if (!(used & (1u << c)))
			soundPreparePcm(c, 0, 64, CAP_TIMER, SoundMode_Repeat, SoundFmt_Pcm16, s_zero, 0, 4);
	for (int i = 0; i < nv; i++)
		soundPreparePcm(v[i].ch, v[i].vol, v[i].pan, v[i].timer, SoundMode_Repeat, SoundFmt_Pcm16, v[i].data,
		                v[i].pnt, v[i].len);
	soundPrepareCap(0, SoundCapDst_ChBNormal, src0 ? SoundCapSrc_ChA : SoundCapSrc_Mixer, false,
	                fmt0 ? SoundCapFmt_Pcm8 : SoundCapFmt_Pcm16, cap[0], bytes[0] / 4);
	soundPrepareCap(1, SoundCapDst_ChBNormal, SoundCapSrc_Mixer, false, SoundCapFmt_Pcm16, cap[1], bytes[1] / 4);
	u32 limit = nsamp * CAP_TIMER * 2 + 16756991u;
	u32 t0 = now32();
	soundStart(used | 0xF | (3u << 16));
	bool timeout = true;
	for (;;) {
		armDCacheInvalidate((void*)((u32)&cap[0][bytes[0] / 4 - 1] & ~31u), 32);
		armDCacheInvalidate((void*)((u32)&cap[1][bytes[1] / 4 - 1] & ~31u), 32);
		if (cap[0][bytes[0] / 4 - 1] != SENTINEL && cap[1][bytes[1] / 4 - 1] != SENTINEL) { timeout = false; break; }
		if (now32() - t0 > limit) break;
		busy_wait(33514);
	}
	soundStop(0x3FFFF);
	busy_wait(33514 * 2);
	for (int u = 0; u < 2; u++) {
		armDCacheInvalidate(cap[u], bytes[u]);
		u32 un = 0;
		for (int i = bytes[u] / 4 - 1; i >= 0 && cap[u][i] == SENTINEL; i--) un++;
		char fn[48];
		snprintf(fn, sizeof fn, "sndq_%s_%c.bin", name, u ? 'R' : 'L');
		hw_write(fn, cap[u], bytes[u]);
		buf_printf(idx, "%s,%d,%s,%lu,%lu,%d\n", name, u, u == 0 && fmt0 ? "s8" : "s16", (unsigned long)nsamp,
		           (unsigned long)un, timeout);
		free(cap[u]);
	}
	progress("done %s", name);
	if (hw_fat_ok && idx->len) {   // append this segment's index rows now
		FILE* f = fopen(HWREF_DIR "/sndq_index.csv", "a");
		if (f) { fwrite(idx->p, 1, idx->len, f); fclose(f); }
		free(idx->p);
		idx->p = NULL;
		idx->len = idx->cap = 0;
	}
	iprintf("%-16s%s\n", name, timeout ? " TIMEOUT" : "");
}

int main(void)
{
	hw_init(VERSION " - sound questions");
	if (hw_fat_ok) load_progress();
	if (hw_fat_ok && !s_resume) { remove(HWREF_DIR "/sndq_progress.txt"); progress("V " VERSION); }
	soundInit();
	soundPowerOn();
	soundSetMixerConfig(SoundOutSrc_Mixer, SoundOutSrc_Mixer, false, false);
	soundSetMixerVolume(127);
	busy_wait(33514 * 20);

	int n = 0;
	for (int i = 0; i < 64; i++) s_lev[n++] = -32768 + i * 1040;
	for (int i = 0; i < 32; i++) {
		int m = -32768 + 256 + i * 2048;
		s_lev[n++] = m - 1; s_lev[n++] = m; s_lev[n++] = m + 1;
	}
	for (int l = 0; l < NLEV; l++) for (int k = 0; k < LEVN; k++) s_stair[l * LEVN + k] = (s16)s_lev[l];
	for (int i = 0; i < 512; i++) s_step[i] = i < 256 ? 0 : 0x4000;
	for (int i = 0; i < 8; i++) { s_dcp[i] = 32767; s_dcn[i] = -32768; s_dc4000[i] = 0x4000; s_dc1234[i] = 0x1234; }
	armDCacheFlush(s_stair, sizeof s_stair);
	armDCacheFlush(s_step, sizeof s_step);
	armDCacheFlush(s_dcp, 16); armDCacheFlush(s_dcn, 16); armDCacheFlush(s_dc4000, 16); armDCacheFlush(s_dc1234, 16);
	armDCacheFlush(s_zero, 32);

	Buf idx = {0}, lev = {0};
	if (!s_resume) {
		buf_printf(&idx, "segment,unit,format,samples,unwritten_words,timeout\n");
		buf_write(&idx, "sndq_index.csv");
	}
	buf_printf(&lev, "level_index,pcm16\n");
	for (int l = 0; l < NLEV; l++) buf_printf(&lev, "%d,%d\n", l, s_lev[l]);
	buf_write(&lev, "sndq_s1_levels.csv");

	// S2
	static const u16 lagt[] = { 520, 540, 560, 600, 640, 700, 768, 800, 900, 1000, 1024, 1100, 1234, 1500, 2048 };   // v2: denser 512-1234 (512/513 in run 30)
	for (unsigned i = 0; i < sizeof lagt / sizeof lagt[0]; i++) {
		V v = { 4, 64, VOL(127, 0), lagt[i], s_step, 128, 128 };   // 128 words of zeros, then loop the 0x4000 half
		char nm[24];
		snprintf(nm, sizeof nm, "s2_lag_t%u", lagt[i]);
		seg(nm, &v, 1, 0, 0, 256 * lagt[i] / CAP_TIMER + 256, &idx);
	}
	// S3
	static const u8 nch[] = { 2, 4, 8, 12, 16 };
	for (unsigned i = 0; i < sizeof nch; i++)
		for (int neg = 0; neg < 2; neg++) {
			V v[16];
			for (int c = 0; c < nch[i]; c++) v[c] = (V){ c, 64, VOL(127, 0), CAP_TIMER, neg ? s_dcn : s_dcp, 0, 4 };
			char nm[24];
			snprintf(nm, sizeof nm, "s3_sat_%u%c", nch[i], neg ? '-' : '+');
			seg(nm, v, nch[i], 0, 0, 256, &idx);
		}
	// S4
	static const struct { const char* name; u8 v7, div, pan; } s4[] = {
		{ "s4_src_v64_p0", 64, 0, 0 }, { "s4_src_v64_p127", 64, 0, 127 }, { "s4_src_v127_p64", 127, 0, 64 },
		{ "s4_src_v64d2_p64", 64, 2, 64 },
	};
	for (unsigned i = 0; i < sizeof s4 / sizeof s4[0]; i++) {
		V v[2] = { { 0, s4[i].pan, VOL(s4[i].v7, s4[i].div), CAP_TIMER, s_dc4000, 0, 4 },
		           { 1, 64, VOL(127, 0), CAP_TIMER, s_dc1234, 0, 4 } };
		seg(s4[i].name, v, 2, 0, 1, 256, &idx);
	}
	// S1
	{ V v = { 4, 64, VOL(127, 0), CAP_TIMER, s_stair, 0, NLEV * LEVN / 2 };
	  seg("s1_cap8", &v, 1, 1, 0, NLEV * LEVN + 256, &idx); }
	soundStop(0x3FFFF);
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\ncapture timer %d; channel vol as calico 11-bit (127 div 0 = 2032);"
	           " master volume 127; channels 0..3 not under test silent at the capture timer\n",
	           VERSION, __DATE__, __TIME__, CAP_TIMER);
	buf_write(&info, "sndq_info.txt");
	progress("all done");
	hw_done();
}
