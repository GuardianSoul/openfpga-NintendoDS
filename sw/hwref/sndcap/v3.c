// sndcap v3: timing-free DC data (docs/hw-reference.md "sndcap"), for the
// sound session. Each segment plays a staircase of constant plateaus (each
// value held for 64 samples, sample timer = capture timer), so a fit can use
// plateau interiors only and the capture lag and phase don't matter.
//   dc_v<vol7>_d<div>_p<pan>   256 cells: ch0 alone, raw vol7/divider
//   dc2_<k>                    16 pairs: ch0 and ch2 together, directed
//                              values (dc2_values): per-channel rounding
//                              before the sum, or once after it
//   dc2r_<k>                   8 pairs: ch0 and ch2, plain staircases
//   lag_t<timer>, lag_ch0_t512 silence, then a step at a known sample
// Runs after v2 (sndcap_v2_main ends here), with v1's per-segment procedure.
// Same layout rules as v2.c: code and tables in their own sections (placed
// after v2's), no static variables, no library function v1 doesn't link, so
// v1 and v2 keep their code addresses and their melonDS timing. The helpers
// below repeat v2.c's instead of sharing them for the same reason.
#include "sndcap.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char __heap_start_ntr[];   // calico's linker script: where the heap starts

#define V3CODE __attribute__((section(".sndcap_v3_text"), noinline))
#define V3CONST __attribute__((section(".sndcap_v3_rodata")))
// String literals in V3CONST too: in .rodata they'd grow the .main output
// section and move v2's code.
#define L(str) ({ static const char l_[] V3CONST = str; l_; })

#define CAP_TIMER 512
#define SND_CLOCK 16756991u
#define SENTINEL 0x5A5A5A5Au

#define PLAT 64                    // samples per plateau
#define NFIX 24
#define NRND 8                     // 4 positive, 4 negative, per segment
#define NPLAT (NFIX + NRND)        // 32 plateaus
#define STAIR_N (NPLAT * PLAT)     // 2048 samples = 1024 words, looped
#define DC_N (STAIR_N + 32)        // capture: one loop + lag margin
#define LAG_ZERO 256               // lag probe: 256 zero samples, then
#define LAG_VAL 0x4000             // 256 samples of this, looped
#define LAG_N 1024

static const int k_vol[8] V3CONST = { 1, 2, 3, 63, 64, 100, 126, 127 };
static const int k_div[4] V3CONST = { 1, 2, 4, 16 };      // SOUNDxCNT div field 0..3
static const int k_pan[8] V3CONST = { 0, 1, 2, 63, 64, 65, 126, 127 };
static const int k_fix[NFIX] V3CONST = {
	0, 1, -1, 2, -2, 3, -3, 0x7F, -0x7F, 0x80, -0x80, 0x81, -0x81, 0xFF, -0xFF,
	0x100, -0x100, 0x3FFF, -0x3FFF, 0x4001, -0x4001, 0x7FFF, -0x7FFF, -0x8000,
};
static const int k_lagt[4] V3CONST = { 512, 513, 700, 1234 };
#define NDC (8 * 4 * 8)
#define NDC2 16
#define NDC2R 8
#define MAX_SEGS (NDC + NDC2 + NDC2R + 8)
static const int k_odd[8] V3CONST = { 1, 3, 5, 9, 17, 33, 63, 101 };   // odd vol7 (not 127: -> 128)
static const int k_oddpan[4] V3CONST = { 1, 31, 63, 97 };             // odd L and R factors

typedef struct {
	u8 ch, v7, div, pan;
	u16 timer, pnt, len;             // pnt/len in words
	u8 buf;                          // 0 = stairs A, 1 = stairs B, 2 = lag step
	u8 kind;                         // values: 0 staircase (seed=), 1 directed pairs, 2 directed fallback (LCG)
	u32 seed;                        // staircase: random values' seed
	s16 val[NPLAT];                  // stairs: plateau values in order
} Voice3;

typedef struct {
	char name[24];
	u8 nv;
	u32 nsamp, off;
	Voice3 v[2];
	u32 done_cycles, unwritten[2];
	bool timeout, rawfail;
	int vmin[2], vmax[2];
} Seg3;

typedef struct {
	s16 stairs[2][STAIR_N];          // ch0 / ch2 buffers, refilled per segment
	s16 lag[2 * LAG_ZERO];
	u32 zero[8];
	Seg3 seg[MAX_SEGS];
	int nseg, rawfails, timeouts;
	bool raw;
	vu16* credits;
	u32 run_cycles, pack_n;
	s16* pack[2];
} State3;

// ---- Raw channel volume (as v2.c: calico's set-volume PXI command) ----
V3CODE static bool raw_init(State3* g)
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

V3CODE static int raw_take_credit(State3* g)
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

V3CODE static bool raw_set_volume(State3* g, int ch, int v7, int div)
{
	int req = raw_take_credit(g);
	if (req < 0) return false;
	u32 arg = (ch & 15) | (v7 & 127) << 4 | (div & 3) << 11;
	pxiSendPacket(0x206 | (u32)req << 13 | arg << 14);
	return true;
}

// The 11-bit calico volume for (vol7, div), or -1 (the fallback without raw).
V3CODE static int vol11(int v7, int div)
{
	if (div == 3) return v7;   // (no switch: its table would go to .rodata)
	if (div == 2) return v7 >= 32 ? v7 << 2 : -1;
	return v7 >= 64 ? v7 << (div == 1 ? 3 : 4) : -1;
}

V3CODE static void progress(const char* fmt, ...)
{
	char line[128];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof line, fmt, ap);
	va_end(ap);
	if (!hw_fat_ok) return;
	FILE* f = fopen(L(HWREF_DIR "/sndcap_progress.txt"), L("a"));
	if (f) { fputs(line, f); fputc('\n', f); fclose(f); }
}

V3CODE static void busy_wait(u32 cycles)
{
	u32 t0 = now32();
	while (now32() - t0 < cycles) {}
}

// ---- Segments ----
// Plateau values: the fixed list, then 4 positive and 4 negative LCG values
// (1..0x7FFF), alternating; `rot` rotates the order (ch2 in dc2 plays the
// list rotated, so the pairs differ).
V3CODE static void stairs_values(Voice3* v, u32 seed, int rot)
{
	s16 tmp[NPLAT];
	for (int i = 0; i < NFIX; i++) tmp[i] = k_fix[i];
	u32 x = seed;
	for (int i = 0; i < NRND; i++) {
		x = x * 1103515245u + 12345u;
		int r = (x >> 16) & 0x7FFF;
		if (!r) r = 1;
		tmp[NFIX + i] = i & 1 ? -r : r;
	}
	for (int i = 0; i < NPLAT; i++) v->val[i] = tmp[(i + rot) % NPLAT];
	v->seed = seed;
}

// Inverse of an odd number modulo 2^32 (Newton).
V3CODE static u32 inv_odd(u32 a)
{
	u32 x = a;   // correct to 3 bits
	for (int i = 0; i < 5; i++) x *= 2 - a * x;
	return x;
}

// Directed two-channel pairs. With A = a * vol_a * fac_a and B = b * vol_b *
// fac_b (the products before any drop) and N = 14 + divider bits (the bits
// every pipeline drops in total), pick positive a, b with A = B = -1 mod 2^k
// and floor(A / 2^k) + floor(B / 2^k) + 1 = 0 mod 2^(N-k). Then dropping k
// bits per channel before the sum and dropping them after it give results
// that differ by one at the capture: the plateau shows on which side of the
// sum the rounding sits, for k = 1..min(15, N-1). Odd plateaus are the
// negated pair. The construction targets one side's factors (L, or R if
// `right`); the other side gets whatever follows. Falls back to LCG values
// when no k down to 1 has a solution within 512 tries (directed_fallback in
// the info file).
V3CODE static void dc2_values(Seg3* s, int right)
{
	Voice3* va = &s->v[0];
	Voice3* vb = &s->v[1];
	int fa = right ? va->pan : 128 - va->pan, fb = right ? vb->pan : 128 - vb->pan;
	int n = 14 + (va->div == 3 ? 4 : va->div);   // div field 0..3 = /1 /2 /4 /16 = 0 1 2 4 bits
	u32 ga = (u32)va->v7 * fa, gb = (u32)vb->v7 * fb, ib = inv_odd(gb);
	u32 maskn = (1u << n) - 1, x = 12345u + s->v[0].v7 * 77u + s->v[1].pan;
	va->kind = vb->kind = 1;
	int kmax = n - 1 < 15 ? n - 1 : 15;
	for (int p = 0; p < NPLAT / 2; p++) {
		int a = 0, b = 0;
		// k = 1 + p mod kmax; large k leave few candidates for a, so a k
		// without a solution falls back to the next smaller one.
		for (int k = 1 + p % kmax; k >= 1 && !b; k--) {
			u32 mk = (1u << k) - 1;
			u32 ra = (0u - inv_odd(ga)) & mk;   // a = ra mod 2^k makes A = -1 mod 2^k
			for (int t = 0; t < 512 && !b; t++) {
				x = x * 1103515245u + 12345u;
				u32 cand = (ra + ((x >> 8) << k)) & 0x7FFF;
				if (cand == 0) continue;
				u32 A = cand * ga;
				u32 c = (0u - 1u - (A >> k)) & (maskn >> k);
				u32 bb = ((((c + 1) << k) - 1) * ib) & maskn;   // b mod 2^n
				if (bb >= 1 && bb <= 0x7FFF) { a = cand; b = bb; }
			}
		}
		if (!b) {   // fallback
			x = x * 1103515245u + 12345u; a = 1 + ((x >> 16) & 0x7FFE);
			x = x * 1103515245u + 12345u; b = 1 + ((x >> 16) & 0x7FFE);
			va->kind = vb->kind = 2;
		}
		va->val[2 * p] = a;  vb->val[2 * p] = b;
		va->val[2 * p + 1] = -a;  vb->val[2 * p + 1] = -b;
	}
}

V3CODE static Seg3* seg(State3* g, const char* name, u32 nsamp)
{
	Seg3* s = &g->seg[g->nseg++];
	memset(s, 0, sizeof *s);
	snprintf(s->name, sizeof s->name, L("%s"), name);
	s->nsamp = nsamp;
	return s;
}

V3CODE static Voice3* voice(Seg3* s, int ch, int v7, int div, int pan, int timer, int buf)
{
	Voice3* v = &s->v[s->nv++];
	memset(v, 0, sizeof *v);
	v->ch = ch; v->v7 = v7; v->div = div; v->pan = pan; v->timer = timer; v->buf = buf;
	if (buf == 2) { v->pnt = LAG_ZERO / 2; v->len = LAG_ZERO / 2; }
	else { v->pnt = 0; v->len = STAIR_N / 2; }
	return v;
}

V3CODE static void build(State3* g)
{
	char n[24];
	Seg3* s;
	// 1. DC grid: ch0 alone, 256 cells.
	for (int i = 0; i < 8; i++)
		for (int d = 0; d < 4; d++)
			for (int j = 0; j < 8; j++) {
				int v7 = k_vol[i], pan = k_pan[j];
				if (!g->raw && vol11(v7, d) < 0) continue;   // fallback only
				snprintf(n, sizeof n, L("dc_v%d_d%d_p%d"), v7, k_div[d], pan);
				s = seg(g, n, DC_N);
				stairs_values(voice(s, 0, v7, d, pan, CAP_TIMER, 0), 1 + g->nseg, 0);
			}
	// 2a. Two channels, directed: ch0 + ch2, odd vol7 and pan factors, the
	// same divider; value pairs from dc2_values.
	for (int k = 0; k < NDC2; k++) {
		int d = k % 4, va = k_odd[k % 8], vb = k_odd[(3 * k + 5) % 8];
		int pa = k_oddpan[k % 4], pb = k_oddpan[(k + 2) % 4];
		if (!g->raw && (vol11(va, d) < 0 || vol11(vb, d) < 0)) continue;
		snprintf(n, sizeof n, L("dc2_%d"), k);
		s = seg(g, n, DC_N);
		voice(s, 0, va, d, pa, CAP_TIMER, 0);
		voice(s, 2, vb, d, pb, CAP_TIMER, 1);
		dc2_values(s, k & 1);
	}
	// 2b. Two channels, staircases: ch0 (stairs A) + ch2 (stairs B: other
	// order and random values), each with its own vol7/divider/pan.
	for (int k = 0; k < NDC2R; k++) {
		int va = k_vol[k % 8], da = k % 4, pa = k_pan[(3 * k + 1) % 8];
		int vb = k_vol[(5 * k + 3) % 8], db = (k / 4 + 1 + k) % 4, pb = k_pan[(5 * k + 6) % 8];
		if (!g->raw && (vol11(va, da) < 0 || vol11(vb, db) < 0)) continue;
		snprintf(n, sizeof n, L("dc2r_%d"), k);
		s = seg(g, n, DC_N);
		stairs_values(voice(s, 0, va, da, pa, CAP_TIMER, 0), 1000 + k, 0);
		stairs_values(voice(s, 2, vb, db, pb, CAP_TIMER, 1), 2000 + k, 13);
	}
	// 3. Lag probe: 256 zero samples, then LAG_VAL (looped), vol 127 /1,
	// pan 64. On ch4 at each timer (the capture-timer channels 0..3 stay at
	// 512), and on ch0 at 512.
	for (int i = 0; i < 4; i++) {
		snprintf(n, sizeof n, L("lag_t%d"), k_lagt[i]);
		voice(seg(g, n, LAG_N), 4, 127, 0, 64, k_lagt[i], 2);
	}
	voice(seg(g, L("lag_ch0_t512"), LAG_N), 0, 127, 0, 64, CAP_TIMER, 2);
}

V3CODE static void fill_stairs(s16* b, const Voice3* v)
{
	for (int p = 0; p < NPLAT; p++)
		for (int i = 0; i < PLAT; i++) b[p * PLAT + i] = v->val[p];
	armDCacheFlush(b, STAIR_N * 2);
}

V3CODE static const void* voice_buf(State3* g, const Voice3* v)
{
	return v->buf == 2 ? (const void*)g->lag : (const void*)g->stairs[v->buf];
}

// One segment, as v1's run_segment, into its place in the pack.
V3CODE static bool run_segment(State3* g, Seg3* s)
{
	const u32 ns = s->nsamp, bytes = ns * 2;
	u32* cap[2];
	for (int u = 0; u < 2; u++) {
		cap[u] = (u32*)(g->pack[u] + s->off);
		for (u32 i = 0; i < bytes / 4; i++) cap[u][i] = SENTINEL;
		armDCacheFlush(cap[u], bytes);
	}

	soundStop(0x3FFFF);
	for (int i = 0; i < s->nv; i++)
		if (s->v[i].buf < 2) fill_stairs(g->stairs[s->v[i].buf], &s->v[i]);   // the last segment stopped
	soundSetMixerVolume(127);
	u32 used = 0;
	for (int i = 0; i < s->nv; i++) used |= 1u << s->v[i].ch;
	for (int c = 0; c < 4; c++)
		if (!(used & (1u << c)))
			soundPreparePcm(c, 0, 64, CAP_TIMER, SoundMode_Repeat, SoundFmt_Pcm16, g->zero, 0, 4);
	for (int i = 0; i < s->nv; i++) {
		const Voice3* v = &s->v[i];
		soundPreparePcm(v->ch, g->raw ? 0 : vol11(v->v7, v->div), v->pan, v->timer, SoundMode_Repeat,
		                SoundFmt_Pcm16, voice_buf(g, v), v->pnt, v->len);
		if (g->raw && !raw_set_volume(g, v->ch, v->v7, v->div))
			s->rawfail = true;   // the channel stays at volume 0
	}
	for (int u = 0; u < 2; u++)
		soundPrepareCap(u, SoundCapDst_ChBNormal, SoundCapSrc_Mixer, false, SoundCapFmt_Pcm16,
		                cap[u], bytes / 4);

	u32 limit = ns * CAP_TIMER * 2 + 16756991u;   // expected + 0.5 s
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
		const s16* o = g->pack[u] + s->off;
		int mn = 32767, mx = -32768;
		for (u32 i = 0; i < ns; i++) {
			if (o[i] < mn) mn = o[i];
			if (o[i] > mx) mx = o[i];
		}
		s->vmin[u] = mn; s->vmax[u] = mx;
	}
	return true;
}

V3CODE static void run_all(State3* g)
{
	for (int i = 0; i < LAG_ZERO; i++) g->lag[LAG_ZERO + i] = LAG_VAL;
	armDCacheFlush(g, sizeof *g);
	g->raw = raw_init(g);
	build(g);
	for (int i = 0; i < g->nseg; i++) { g->seg[i].off = g->pack_n; g->pack_n += g->seg[i].nsamp; }
	for (int u = 0; u < 2; u++)
		if (!(g->pack[u] = aligned_alloc(32, g->pack_n * 2))) {
			hw_status(L("v3: OUT OF MEMORY (pack)"));
			progress(L("v3: out of memory (pack)"));
			g->nseg = 0;
			return;
		}
	progress(L("v3: %d segments, volume %s"), g->nseg, g->raw ? L("raw") : L("calico 11-bit"));
	hw_status(L("v3: %d segments, vol %s"), g->nseg, g->raw ? L("raw") : L("11-bit"));

	u32 t_all = now32();
	for (int i = 0; i < g->nseg; i++) {
		Seg3* s = &g->seg[i];
		// One progress line per 8 pans of the grid (SD appends are slow).
		if (s->name[1] != 'c' || s->name[2] != '_' || s->v[0].pan == 0)
			progress(L("start %s"), s->name);
		run_segment(g, s);
		if (s->timeout) g->timeouts++;
		if (s->rawfail) g->rawfails++;
		iprintf(L("%-18.18s%6d%6d%s%s\n"), s->name, s->vmin[0], s->vmax[1],
		        s->timeout ? L(" TO") : L(""), s->rawfail ? L(" RF") : L(""));
	}
	soundStop(0x3FFFF);
	g->run_cycles = now32() - t_all;
	progress(L("v3 captures done, timeouts=%d raw_fails=%d"), g->timeouts, g->rawfails);
}

V3CODE static void info(State3* g, Buf* b)
{
	unsigned rate = (SND_CLOCK + CAP_TIMER / 2) / CAP_TIMER;
	buf_printf(b, L("\nv3 segments (sndcap 3): DC staircases, stored in sndcap_v3_{L,R}.bin at the index's "
	           "offset (samples). Procedure as v1; mixer volume 127, capture source mixer, 16-bit, repeat "
	           "mode; channels 0..3 not playing are silent at the capture timer\n"));
	buf_printf(b, L("v3 stairs: %d plateaus of %d samples (values= in order, buffer looped from pnt 0, "
	           "%d words); values = %d fixed, then 4 positive / 4 negative LCG values (x = x*1103515245 + "
	           "12345, (x >> 16) & 0x7FFF, 0 -> 1, from seed=) alternating; ch2 of dc2r plays its list "
	           "rotated by 13. dc2_*: directed pairs (v3.c dc2_values): plateau 2p is (a, b) > 0 with "
	           "a*vol_a*fac_a = b*vol_b*fac_b = -1 mod 2^k and a carry to the capture bit, k = 1 + p mod "
	           "min(15, 13 + divider bits), plateau 2p+1 is (-a, -b); targets L (even k) or R (odd k)\n"),
	           NPLAT, PLAT, STAIR_N / 2, NFIX);
	buf_printf(b, L("v3 lag: %d zero samples, then %d (pnt %d, len %d words), vol7 127 div 0 pan 64\n"),
	           LAG_ZERO, LAG_VAL, LAG_ZERO / 2, LAG_ZERO / 2);
	buf_printf(b, L("v3 vol: %s\n"), g->raw ? L("raw (as v2)") : L("calico 11-bit (raw unavailable; unexpressible cells dropped)"));
	u32 hs = (u32)__heap_start_ntr;
	buf_printf(b, L("v3 layout: heap start 0x%08lx, %s (sndcap 2: 0x030 mod 0x1000)\n"), (unsigned long)hs,
	           (hs & 0xFFF) == 0x030 ? L("ok") : L("MOVED, recompute V3_PAD"));
	buf_printf(b, L("v3 run_cycles %lu timeouts %d raw_fails %d\n\n"), (unsigned long)g->run_cycles,
	           g->timeouts, g->rawfails);
	for (int i = 0; i < g->nseg; i++) {
		const Seg3* s = &g->seg[i];
		buf_printf(b, L("segment %s cap_timer=%u rate_hz=%u cap_src=mixer cap_fmt=pcm16 mixer_vol=127 "
		           "samples=%lu offset=%lu done_cycles=%lu timeout=%d raw_fail=%d unwritten_words=%lu,%lu "
		           "min=%d,%d max=%d,%d\n"),
		           s->name, CAP_TIMER, rate, (unsigned long)s->nsamp, (unsigned long)s->off,
		           (unsigned long)s->done_cycles, s->timeout, s->rawfail,
		           (unsigned long)s->unwritten[0], (unsigned long)s->unwritten[1],
		           s->vmin[0], s->vmin[1], s->vmax[0], s->vmax[1]);
		for (int k = 0; k < s->nv; k++) {
			const Voice3* v = &s->v[k];
			buf_printf(b, L("  ch=%u fmt=pcm16 wave=%s mode=repeat vol=%s (vol7=%u div=%u) pan=%u timer=%u "
			           "pnt=%u len=%u"), v->ch, v->buf == 2 ? L("lag_step") : L("dc_stairs"),
			           g->raw ? L("raw") : L("11bit"), v->v7, v->div, v->pan, v->timer, v->pnt, v->len);
			if (v->buf < 2) {
				if (v->kind == 0) buf_printf(b, L(" plateau=%d stairs seed=%lu values="), PLAT, (unsigned long)v->seed);
				else buf_printf(b, L(" plateau=%d %s values="), PLAT, v->kind == 1 ? L("directed") : L("directed_fallback"));
				for (int p = 0; p < NPLAT; p++) buf_printf(b, p ? L(",%d") : L("%d"), v->val[p]);
			}
			buf_printf(b, L("\n"));
		}
	}
}

V3CODE static void index_rows(State3* g, Buf* b)
{
	unsigned rate = (SND_CLOCK + CAP_TIMER / 2) / CAP_TIMER;
	for (int i = 0; i < g->nseg; i++) {
		const Seg3* s = &g->seg[i];
		const Voice3* v = &s->v[0];
		for (int u = 0; u < 2; u++)
			buf_printf(b, L("%s,sndcap_v3_%c.bin,%lu,%lu,%u,pcm16,%u,%u,%s,%u,%u,%u,%u\n"), s->name, u ? 'R' : 'L',
			           (unsigned long)s->off, (unsigned long)s->nsamp, rate, s->nv, v->ch,
			           v->buf == 2 ? L("lag_step") : L("dc_stairs"), v->v7, v->div, v->pan, v->timer);
	}
}

// Appends a buffer to a file in /hwref; on failure writes it as `alt`
// (hw_write reports the failure on screen).
V3CODE static void append(Buf* b, const char* name, const char* alt)
{
	char path[64];
	snprintf(path, sizeof path, L(HWREF_DIR "/%s"), name);
	FILE* f = hw_fat_ok ? fopen(path, L("a")) : NULL;
	bool ok = f && fwrite(b->p ? b->p : L(""), 1, b->len, f) == b->len;
	if (f && fclose(f) != 0) ok = false;
	if (ok) { free(b->p); b->p = NULL; b->len = b->cap = 0; }
	else buf_write(b, alt);
}

// Layout pads. The v1 and v2 segments' melonDS timing depends on where the
// data and the heap start, not only on the code addresses (moving the heap
// start by 0x40 changes sat_n4 and sat_n8 of v2). v3's code goes between v2's
// code and the data, and its string literals and tables between the data and
// the bss. These pads make both moves multiples of 4 KiB: .main.rw stays at
// 0x0d0 and the heap start at 0x030 modulo 4 KiB, as in sndcap 2 (0x020280d0,
// 0x02030030). After changing this file run sw/hwref/sndcap/v3pad.py, which
// recomputes them, then the equivalence check. The info file's "v3 layout"
// line shows the heap start the build had.
#define V3_PAD 0xce0
#define V3_PAD_RO 0x6d0
#define V3_STR_(x) #x
#define V3_STR(x) V3_STR_(x)
__asm__(".section .sndcap_v3_text,\"ax\",%progbits\n\t.space " V3_STR(V3_PAD) "\n\t.previous");
__asm__(".section .sndcap_v3_rodata,\"a\",%progbits\n\t.space " V3_STR(V3_PAD_RO) "\n\t.previous");
V3CODE void sndcap_v3_main(void* v2state)
{
	// The v1 and v2 captures are written: free them for v3's pack.
	sndcap_v2_release(v2state);
	for (int i = 0; i < s_nseg; i++)
		for (int u = 0; u < 2; u++) { free(s_seg[i].out[u]); s_seg[i].out[u] = NULL; }
	State3* g = aligned_alloc(32, (sizeof(State3) + 31) & ~31u);
	if (!g) {
		hw_status(L("v3: OUT OF MEMORY"));
		progress(L("v3: out of memory"));
		hw_done();
	}
	memset(g, 0, sizeof *g);
	run_all(g);

	iprintf(L("writing v3 files...\n"));
	if (g->nseg) {
		const Seg3* last = &g->seg[g->nseg - 1];
		for (int u = 0; u < 2; u++)
			hw_write(u ? L("sndcap_v3_R.bin") : L("sndcap_v3_L.bin"), g->pack[u], (last->off + last->nsamp) * 2);
	}
	Buf idx = {0}, inf = {0};
	index_rows(g, &idx);
	append(&idx, L("sndcap_index.csv"), L("sndcap_index_v3.csv"));
	info(g, &inf);
	append(&inf, L("sndcap_info.txt"), L("sndcap_info_v3.txt"));
	progress(L("v3 files written"));
	hw_done();
}
