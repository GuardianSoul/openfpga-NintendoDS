// sndcap v2: directed segments that pin the mixer's rounding, the 8-bit
// capture, the sample-timer phase and multi-channel saturation
// (docs/hw-reference.md "sndcap"). They run after the v1 set and its files,
// with v1's per-segment procedure (main.c run_segment): stop everything,
// prepare the test channels, channels 0..3 silent at the capture timer, one
// soundStart mask, one-shot capture of L and R, bounded wait.
//
// melonDS's ARM9 timing depends on code addresses, so the v1 segments only
// reproduce v1's start phases if everything they run stays where v1 put it.
// Hence: main.c compiles to v1's code (main is the first function in .text),
// this file's code and constant tables are in their own sections, which the
// linker places after all of v1's, it has no static variables (its state is
// on the heap), and it uses no library function v1 doesn't link.
#include "sndcap.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define V2CODE __attribute__((section(".sndcap_v2_text"), noinline))
#define V2CONST __attribute__((section(".sndcap_v2_rodata")))

#define CAP_TIMER 512
#define SND_CLOCK 16756991u
#define SENTINEL 0x5A5A5A5Au
#define GRID_N 1024                // one period of saw16 at timer 512
#define LONG_N 2048

#define SAW16_N 1024
#define SAW8_N 256
#define IMP_N 64                   // PCM16 impulse loop: 64 samples = 32 words
#define IMP_POS 5                  // the one non-zero sample
#define IMP_VAL 0x7FFF

#define NVOL 11
#define NDIV 4
#define NPAN 7
static const int k_gvol[NVOL] V2CONST = { 1, 2, 3, 5, 9, 17, 33, 64, 100, 126, 127 };
static const int k_gdiv[NDIV] V2CONST = { 1, 2, 4, 16 };     // SOUNDxCNT div field 0..3
static const int k_gpan[NPAN] V2CONST = { 0, 1, 63, 64, 65, 126, 127 };
static const int k_c8[6] V2CONST = { 2047, 1500, 1024, 508, 127, 64 };
static const int k_pt[5] V2CONST = { 512, 333, 513, 700, 1234 };
static const int k_sn[3] V2CONST = { 2, 4, 8 };
#define MAX_SEGS (NVOL * NDIV * NPAN + 32)

typedef struct {
	u8 ch, wave, pan, v7, div;       // SOUNDxCNT fields as written
	bool raw;                        // vol7/div through the raw set-volume command
	u16 vol, timer;                  // vol: calico 11-bit (when !raw)
} Voice2;

typedef struct {
	char name[24];
	u8 nv, capfmt;                   // capfmt 0 = 16, 1 = 8 (stored as s8 * 256)
	u32 nsamp, off;                  // samples per unit, offset in the pack
	Voice2 v[8];
	u32 done_cycles, unwritten[2];
	bool timeout, rawfail;
	int vmin[2], vmax[2], peak[2];
} Seg2;

typedef struct {
	s16 saw16[SAW16_N];
	s8 saw8[SAW8_N];
	s16 imp[IMP_N];
	u32 zero[8];
	Seg2 seg[MAX_SEGS];
	int nseg, ndropped, rawfails, timeouts;
	bool raw;
	vu16* credits;
	u32 run_cycles, pack_n;
	s16* pack[2];
	char dropped[512];
} State;

// ---- Raw channel volume ----
// calico's ARM9 API takes an 11-bit volume and encodes it as vol7 + divider
// on the ARM9 (<=127: /16; <512: v>>2, /4; <1024: v>>3, /2; else v>>4, /1);
// there is no public call that sets the fields directly. Its set-volume PXI
// command (soundChSetVolume: channel 6, command 8, argument ch | vol7 << 4 |
// div << 11) carries the raw fields, and calico's ARM7 writes them to
// SOUNDxCNT bits 0-6 and 8-9 unchanged. Sending it needs calico's PXI credit
// count (static s_soundPxiCredits), whose address is in soundInit's literal
// pool. raw_init checks soundInit against calico 1.2.0's code first; on any
// mismatch the grid uses the 11-bit API and drops what it can't express.
V2CODE static bool raw_init(State* g)
{
	const u32* f = (const u32*)((u32)soundInit & ~1u);
	if (f[0x00 / 4] != 0xe59f304c || f[0x14 / 4] != 0xe3a0e020 || f[0x1c / 4] != 0xe59fc034 ||
	    f[0x2c / 4] != 0xe1cce0b0 || f[0x44 / 4] != 0xe8bd4010 || f[0x60 / 4] != 0x00004046)
		return false;
	u32 a = f[0x58 / 4];
	if (a < 0x02000000 || a >= 0x02400000 || (a & 1)) return false;
	g->credits = (vu16*)a;
	return *g->credits <= 32;
}

// One credit, as calico's _soundPxiCheckCredits(1) (IRQs off through IME):
// returns the "request credits back" flag (1 when 3 or fewer are left), or
// -1 after 100 ms.
V2CODE static int raw_take_credit(State* g)
{
	u32 t0 = now32();
	for (;;) {
		u32 ime = REG_IME;
		REG_IME = 0;
		u16 c = *g->credits;
		if (c >= 1) {
			*g->credits = --c;
			REG_IME = ime;
			return c <= 3;
		}
		REG_IME = ime;
		if (now32() - t0 > 33514u * 100) return -1;
	}
}

V2CODE static bool raw_set_volume(State* g, int ch, int v7, int div)
{
	int req = raw_take_credit(g);
	if (req < 0) return false;
	u32 arg = (ch & 15) | (v7 & 127) << 4 | (div & 3) << 11;
	pxiSendPacket(0x206 | (u32)req << 13 | arg << 14);
	return true;
}

// calico's encoding of an 11-bit volume (soundPreparePcm).
V2CODE static void enc_vol(int vol, u8* v7, u8* div)
{
	if (vol <= 127)       { *v7 = vol; *div = 3; }
	else if (vol < 512)   { *v7 = (vol >> 2) & 127; *div = 2; }
	else if (vol < 1024)  { *v7 = (vol >> 3) & 127; *div = 1; }
	else if (vol < 2048)  { *v7 = (vol >> 4) & 127; *div = 0; }
	else                  { *v7 = 127; *div = 0; }
}

// The 11-bit calico volume that encodes (vol7, div), or -1.
V2CODE static int vol11(int v7, int div)
{
	switch (div) {
	case 3: return v7;
	case 2: return v7 >= 32 ? v7 << 2 : -1;
	case 1: return v7 >= 64 ? v7 << 3 : -1;
	default: return v7 >= 64 ? v7 << 4 : -1;
	}
}

// strlen isn't in v1's link (GCC would turn this loop into a call to it).
V2CODE __attribute__((optimize("no-tree-loop-distribute-patterns")))
static size_t str_len(const char* p)
{
	size_t n = 0;
	while (p[n]) n++;
	return n;
}

V2CODE static const char* wave_name(int w)
{
	return w == W_SAW16 ? "saw16" : w == W_SAW8 ? "saw8" : "impulse16";
}

#define W_IMP W_ADT   // v2's third wave (v2 has no ADPCM)

// ---- Segments ----
V2CODE static Seg2* seg(State* g, const char* name, u32 nsamp)
{
	Seg2* s = &g->seg[g->nseg++];
	memset(s, 0, sizeof *s);
	snprintf(s->name, sizeof s->name, "%s", name);
	s->nsamp = nsamp;
	return s;
}

V2CODE static void voice(Seg2* s, int ch, int wave, int vol, int pan, int timer)
{
	Voice2* v = &s->v[s->nv++];
	memset(v, 0, sizeof *v);
	v->ch = ch; v->wave = wave; v->vol = vol; v->pan = pan; v->timer = timer;
	enc_vol(vol, &v->v7, &v->div);
}

V2CODE static void build(State* g)
{
	char n[24];
	Seg2* s;
	// 1. Grid: vol7 x divider x pan, ch4 saw16 timer 512, one ramp period.
	for (int i = 0; i < NVOL; i++)
		for (int div = 0; div < NDIV; div++)
			for (int j = 0; j < NPAN; j++) {
				int v7 = k_gvol[i], pan = k_gpan[j], v11 = vol11(v7, div);
				if (!g->raw && v11 < 0) {
					size_t l = str_len(g->dropped);
					if (j == 0 && l + 16 < sizeof g->dropped)
						snprintf(g->dropped + l, sizeof g->dropped - l, " v%d_d%d", v7, k_gdiv[div]);
					g->ndropped++;
					continue;
				}
				snprintf(n, sizeof n, "grid_v%d_d%d_p%d", v7, k_gdiv[div], pan);
				s = seg(g, n, GRID_N);
				voice(s, 4, W_SAW16, g->raw ? 0 : v11, pan, 512);
				s->v[0].raw = g->raw;
				s->v[0].v7 = v7;
				s->v[0].div = div;
			}
	// 2. 8-bit capture of the same ramp (calico 11-bit volumes, pan 64).
	for (int i = 0; i < 6; i++) {
		snprintf(n, sizeof n, "cap8_%d", k_c8[i]);
		s = seg(g, n, GRID_N);
		s->capfmt = 1;
		voice(s, 4, W_SAW16, k_c8[i], 64, 512);
	}
	s = seg(g, "cap8_2047_p0", GRID_N);
	s->capfmt = 1;
	voice(s, 4, W_SAW16, 2047, 0, 512);
	// 3. Sample-timer phase: a 64-sample loop that is 0 except sample 5
	// (timer 512 is the control).
	for (int i = 0; i < 5; i++) {
		snprintf(n, sizeof n, "phase_t%d", k_pt[i]);
		voice(seg(g, n, LONG_N), 4, W_IMP, 2047, 64, k_pt[i]);
	}
	// 4. Saturation: 2, 4, 8 channels (ch4..) at full volume, pan 32 (L
	// 96/128, R 32/128). Channel k: saw16 (k even) or saw8 (k odd), timer
	// 512 << (k / 2).
	for (int i = 0; i < 3; i++) {
		snprintf(n, sizeof n, "sat_n%d", k_sn[i]);
		s = seg(g, n, LONG_N);
		for (int k = 0; k < k_sn[i]; k++)
			voice(s, 4 + k, k & 1 ? W_SAW8 : W_SAW16, 2047, 32, 512 << (k / 2));
	}
}

V2CODE static void make_samples(State* g)
{
	for (int i = 0; i < SAW16_N; i++)
		g->saw16[i] = (s16)(-32768 + i * 64 + ((i * 37) & 63));   // as v1
	for (int i = 0; i < SAW8_N; i++)
		g->saw8[i] = (s8)(i - 128);
	g->imp[IMP_POS] = IMP_VAL;
	armDCacheFlush(g, sizeof *g);
}

V2CODE static const void* wave_ptr(State* g, int w)
{
	return w == W_SAW16 ? (const void*)g->saw16 : w == W_SAW8 ? (const void*)g->saw8 : (const void*)g->imp;
}

V2CODE static u32 wave_len(int w)   // words
{
	return w == W_SAW16 ? SAW16_N / 2 : w == W_SAW8 ? SAW8_N / 4 : IMP_N / 2;
}

V2CODE static void progress(const char* fmt, ...)
{
	char line[128];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof line, fmt, ap);
	va_end(ap);
	if (!hw_fat_ok) return;
	FILE* f = fopen(HWREF_DIR "/sndcap_progress.txt", "a");
	if (f) { fputs(line, f); fputc('\n', f); fclose(f); }
}

V2CODE static void busy_wait(u32 cycles)
{
	u32 t0 = now32();
	while (now32() - t0 < cycles) {}
}

// One segment, as v1's run_segment, into its place in the pack.
V2CODE static bool run_segment(State* g, Seg2* s)
{
	const u32 ns = s->nsamp;
	u32 bytes = s->capfmt ? ns : ns * 2;
	u32* cap[2];
	s16* out[2];
	for (int u = 0; u < 2; u++) {
		out[u] = g->pack[u] + s->off;
		cap[u] = s->capfmt ? aligned_alloc(32, bytes) : (u32*)out[u];
		if (!cap[u]) return false;
		for (u32 i = 0; i < bytes / 4; i++) cap[u][i] = SENTINEL;
		armDCacheFlush(cap[u], bytes);
	}

	soundStop(0x3FFFF);
	soundSetMixerVolume(127);
	u32 used = 0;
	for (int i = 0; i < s->nv; i++) used |= 1u << s->v[i].ch;
	for (int c = 0; c < 4; c++)
		if (!(used & (1u << c)))
			soundPreparePcm(c, 0, 64, CAP_TIMER, SoundMode_Repeat, SoundFmt_Pcm16, g->zero, 0, 4);
	for (int i = 0; i < s->nv; i++) {
		const Voice2* v = &s->v[i];
		soundPreparePcm(v->ch, v->raw ? 0 : v->vol, v->pan, v->timer, SoundMode_Repeat,
		                v->wave == W_SAW8 ? SoundFmt_Pcm8 : SoundFmt_Pcm16, wave_ptr(g, v->wave), 0,
		                wave_len(v->wave));
		if (v->raw && !raw_set_volume(g, v->ch, v->v7, v->div))
			s->rawfail = true;   // the channel stays at volume 0
	}
	for (int u = 0; u < 2; u++)
		soundPrepareCap(u, SoundCapDst_ChBNormal, SoundCapSrc_Mixer, false,
		                s->capfmt ? SoundCapFmt_Pcm8 : SoundCapFmt_Pcm16, cap[u], bytes / 4);

	// Expected: ns capture periods of CAP_TIMER sound clocks (2 system
	// cycles each). Timeout: that plus 0.5 s.
	u32 expect = ns * CAP_TIMER * 2;
	u32 limit = expect + 16756991u;
	u32 t0 = now32();
	soundStart(used | 0xF | (3u << 16));
	vu32* last[2] = { &cap[0][bytes / 4 - 1], &cap[1][bytes / 4 - 1] };
	s->timeout = true;
	for (;;) {
		u32 t = now32() - t0;
		armDCacheInvalidate((void*)((u32)last[0] & ~31u), 32);
		armDCacheInvalidate((void*)((u32)last[1] & ~31u), 32);
		if (*last[0] != SENTINEL && *last[1] != SENTINEL) { s->done_cycles = t; s->timeout = false; break; }
		if (t > limit) { s->done_cycles = t; break; }
		busy_wait(33514);   // ~1 ms
	}
	soundStop(0x3FFFF);
	busy_wait(33514 * 2);   // 2 ms: the stop command reaches the ARM7
	for (int u = 0; u < 2; u++) {
		armDCacheInvalidate(cap[u], bytes);
		u32 un = 0;
		for (int i = bytes / 4 - 1; i >= 0 && cap[u][i] == SENTINEL; i--) un++;
		s->unwritten[u] = un;
		if (s->capfmt) {
			const s8* b = (const s8*)cap[u];
			for (u32 i = 0; i < ns; i++) out[u][i] = (s16)(b[i] * 256);
			free(cap[u]);
		}
		int mn = 32767, mx = -32768, pk = 0;
		for (u32 i = 0; i < ns; i++) {
			int x = out[u][i];
			if (x < mn) mn = x;
			if (x > mx) mx = x;
			if (x > pk) pk = x;
			if (-x > pk) pk = -x;
		}
		s->vmin[u] = mn; s->vmax[u] = mx; s->peak[u] = pk;
	}
	return true;
}

V2CODE static bool is_grid_block_start(const char* n)   // "grid_..._p0"
{
	size_t l = str_len(n);
	return l > 8 && n[0] == 'g' && n[4] == '_' && n[l - 3] == '_' && n[l - 2] == 'p' && n[l - 1] == '0';
}

V2CODE static bool run_all(State* g)
{
	make_samples(g);
	g->raw = raw_init(g);
	build(g);
	// All v2 captures go into one buffer per side, written as one file each
	// (hundreds of small files take far longer to write than the captures).
	for (int i = 0; i < g->nseg; i++) { g->seg[i].off = g->pack_n; g->pack_n += g->seg[i].nsamp; }
	for (int u = 0; u < 2; u++)
		if (!(g->pack[u] = aligned_alloc(32, g->pack_n * 2))) {
			hw_status("v2: OUT OF MEMORY (pack)");
			progress("v2: out of memory (pack)");
			g->nseg = 0;
			return false;
		}
	progress("v2: %d segments, grid volume %s", g->nseg, g->raw ? "raw" : "calico 11-bit");
	hw_status("v2: %d segments, grid vol %s", g->nseg, g->raw ? "raw" : "11-bit");

	u32 t_all = now32();
	for (int i = 0; i < g->nseg; i++) {
		Seg2* s = &g->seg[i];
		// One progress line per grid block of 7 pans (SD appends are slow).
		if (s->name[0] != 'g' || is_grid_block_start(s->name))
			progress("start %s", s->name);
		if (!run_segment(g, s)) { hw_status("OUT OF MEMORY at %s", s->name); g->nseg = i; break; }
		if (s->timeout) g->timeouts++;
		if (s->rawfail) g->rawfails++;
		iprintf("%-18.18s%6d%6d%s%s\n", s->name, s->peak[0], s->peak[1],
		        s->timeout ? " TO" : "", s->rawfail ? " RF" : "");
	}
	soundStop(0x3FFFF);
	g->run_cycles = now32() - t_all;
	progress("v2 captures done, timeouts=%d raw_fails=%d", g->timeouts, g->rawfails);
	return true;
}

// Info: appended to main.c's sndcap_info.txt.
V2CODE static void info(State* g, Buf* b)
{
	unsigned rate = (SND_CLOCK + CAP_TIMER / 2) / CAP_TIMER;
	buf_printf(b, "\nv2 segments (sndcap 2): stored in sndcap_v2_{L,R}.bin at the index's offset "
	           "(samples), samples= per segment. Procedure as v1; mixer volume 127, capture source "
	           "mixer, repeat mode, pnt 0\n");
	buf_printf(b, "v2 waves: saw16 and saw8 as v1; impulse16 = %d x s16, 0 except sample %d = %d\n",
	           IMP_N, IMP_POS, IMP_VAL);
	buf_printf(b, "v2 grid_vol: %s\n", g->raw
	           ? "raw (calico's set-volume PXI command with vol7/div, after preparing at volume 0)"
	           : "calico 11-bit (raw path unavailable: soundInit doesn't match calico 1.2.0)");
	buf_printf(b, "v2 grid_dropped %d:%s%s\n", g->ndropped, g->dropped, g->ndropped ? " (x 7 pans each)" : "");
	buf_printf(b, "v2 run_cycles %lu timeouts %d raw_fails %d\n\n", (unsigned long)g->run_cycles,
	           g->timeouts, g->rawfails);
	for (int i = 0; i < g->nseg; i++) {
		const Seg2* s = &g->seg[i];
		buf_printf(b, "segment %s cap_timer=%u rate_hz=%u cap_src=mixer cap_fmt=%s mixer_vol=127 "
		           "samples=%lu offset=%lu done_cycles=%lu timeout=%d raw_fail=%d unwritten_words=%lu,%lu "
		           "min=%d,%d max=%d,%d\n",
		           s->name, CAP_TIMER, rate, s->capfmt ? "pcm8" : "pcm16", (unsigned long)s->nsamp,
		           (unsigned long)s->off, (unsigned long)s->done_cycles, s->timeout, s->rawfail,
		           (unsigned long)s->unwritten[0], (unsigned long)s->unwritten[1],
		           s->vmin[0], s->vmin[1], s->vmax[0], s->vmax[1]);
		for (int k = 0; k < s->nv; k++) {
			const Voice2* v = &s->v[k];
			char vol[8];
			if (v->raw) snprintf(vol, sizeof vol, "raw");
			else snprintf(vol, sizeof vol, "%u", v->vol);
			buf_printf(b, "  ch=%u fmt=%s wave=%s mode=repeat vol=%s (vol7=%u div=%u) pan=%u timer=%u pnt=0 len=%lu\n",
			           v->ch, v->wave == W_SAW8 ? "pcm8" : "pcm16", wave_name(v->wave), vol, v->v7, v->div,
			           v->pan, v->timer, (unsigned long)wave_len(v->wave));
		}
	}
}

// Index for both sets: v1's rows (from main.c's segments, offset 0) and v2's.
// The parameter columns are the first test channel's, vol7/div as written to
// SOUNDxCNT (div 0=/1 1=/2 2=/4 3=/16).
V2CODE static void index_csv(State* g, Buf* b)
{
	buf_printf(b, "segment,file,offset,samples,rate_hz,cap_fmt,channels,ch,wave,vol7,div,pan,timer\n");
	for (int i = 0; i < s_nseg; i++) {
		const Seg* s = &s_seg[i];
		const Voice* v = &s->v[0];
		unsigned rate = (SND_CLOCK + s->captimer / 2) / s->captimer;
		u8 v7, div;
		enc_vol(v->vol, &v7, &div);
		const char* w = v->wave == W_PSG ? (v->ch >= 14 ? "noise" : "square")
		              : v->wave == W_SAW16 ? "saw16" : v->wave == W_SAW8 ? "saw8"
		              : v->wave == W_ADT ? "adpcm_tone" : "adpcm_rand";
		for (int u = 0; u < 2; u++)
			buf_printf(b, "%s,sndcap_%.23s_%c.bin,0,%d,%u,%s,%u,%u,%s,%u,%u,%u,%u\n", s->name, s->name,
			           u ? 'R' : 'L', 8192, rate, s->capfmt ? "pcm8" : "pcm16", s->nv, v->ch, w,
			           v7, div, v->pan, v->timer);
	}
	unsigned rate = (SND_CLOCK + CAP_TIMER / 2) / CAP_TIMER;
	for (int i = 0; i < g->nseg; i++) {
		const Seg2* s = &g->seg[i];
		const Voice2* v = &s->v[0];
		for (int u = 0; u < 2; u++)
			buf_printf(b, "%s,sndcap_v2_%c.bin,%lu,%lu,%u,%s,%u,%u,%s,%u,%u,%u,%u\n", s->name, u ? 'R' : 'L',
			           (unsigned long)s->off, (unsigned long)s->nsamp, rate, s->capfmt ? "pcm8" : "pcm16",
			           s->nv, v->ch, wave_name(v->wave), v->v7, v->div, v->pan, v->timer);
	}
}

V2CODE void sndcap_v2_main(void)
{
	State* g = aligned_alloc(32, (sizeof(State) + 31) & ~31u);
	if (!g) {
		hw_status("v2: OUT OF MEMORY");
		progress("v2: out of memory");
		hw_done();
	}
	memset(g, 0, sizeof *g);
	run_all(g);

	iprintf("writing v2 files...\n");
	if (g->nseg) {
		const Seg2* last = &g->seg[g->nseg - 1];
		for (int u = 0; u < 2; u++)
			hw_write(u ? "sndcap_v2_R.bin" : "sndcap_v2_L.bin", g->pack[u], (last->off + last->nsamp) * 2);
	}
	Buf idx = {0}, inf = {0};
	index_csv(g, &idx);
	buf_write(&idx, "sndcap_index.csv");
	info(g, &inf);
	FILE* f = hw_fat_ok ? fopen(HWREF_DIR "/sndcap_info.txt", "a") : NULL;
	bool ok = f && fwrite(inf.p ? inf.p : "", 1, inf.len, f) == inf.len;
	if (f && fclose(f) != 0) ok = false;
	if (ok) free(inf.p);
	else buf_write(&inf, "sndcap_info_v2.txt");   // reports a failure on screen
	progress("v2 files written");
	sndcap_v3_main(g);   // sndcap 2: hw_done()
}

// For v3: frees v2's state and captures (after they're written). After
// sndcap_v2_main, so v2's code keeps its addresses.
V2CODE void sndcap_v2_release(void* state)
{
	State* g = state;
	free(g->pack[0]);
	free(g->pack[1]);
	free(g);
}
