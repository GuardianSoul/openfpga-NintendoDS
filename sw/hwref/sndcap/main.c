// Sound mixer reference: records the DS mixer with the sound capture units.
// docs/hw-reference.md "sndcap".
//
// Each segment stops everything, prepares its test channels (4..15, or 0/2
// for the channel-source test), keeps channels 0..3 at the capture timer
// with silent looping zero samples at volume 0 (so the capture timer is set
// whichever channel drives it: GBATEK says 1/3, calico's comment says 0/2),
// then starts the channels and both capture units in one soundStart mask.
// Capture unit 0 records the left mixer, unit 1 the right, one-shot, into
// main RAM. The wait for the end of the capture is bounded by the TM0+TM1
// clock. All captures stay in RAM and are written at the end.
//
// v2 (v2.c) runs its directed segments after this v1 set: main ends in
// sndcap_v2_main instead of hw_done. Apart from that call this file compiles
// to v1's code, at v1's addresses, so the v1 segments keep v1's timing and
// start phases in melonDS (docs/hw-reference.md "sndcap").
#include "sndcap.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VERSION "sndcap 3"   // same length as v1's

#define NSAMP 8192                 // samples per capture unit and segment
#define CAP_TIMER 512              // = one mixer step (1024 system cycles)
#define SND_CLOCK 16756991u        // SYSTEM_CLOCK / 2
#define SENTINEL 0x5A5A5A5Au
#define MAX_SEGS 64

// ---- Sample data (main RAM, 32-byte aligned so cache ops stay inside) ----
#define SAW16_N 1024               // PCM16 saw: 1024 samples = 512 words
#define SAW8_N 256                 // PCM8 saw: 256 samples = 64 words
#define ADT_DATA 256               // ADPCM tone: data words after the header
#define ADR_DATA 64                // ADPCM random: data words
static s16 s_saw16[SAW16_N] __attribute__((aligned(32)));
static s8 s_saw8[SAW8_N] __attribute__((aligned(32)));
static u32 s_adpcm_tone[1 + ADT_DATA] __attribute__((aligned(32)));
static u32 s_adpcm_rand[1 + ADR_DATA] __attribute__((aligned(32)));
static u32 s_zero[8] __attribute__((aligned(32)));

// melonDS SPU.cpp's tables (the standard IMA-ADPCM ones).
static const s8 k_idx[8] = { -1, -1, -1, -1, 2, 4, 6, 8 };
static const u16 k_step[89] = {
	0x0007, 0x0008, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x000E,
	0x0010, 0x0011, 0x0013, 0x0015, 0x0017, 0x0019, 0x001C, 0x001F,
	0x0022, 0x0025, 0x0029, 0x002D, 0x0032, 0x0037, 0x003C, 0x0042,
	0x0049, 0x0050, 0x0058, 0x0061, 0x006B, 0x0076, 0x0082, 0x008F,
	0x009D, 0x00AD, 0x00BE, 0x00D1, 0x00E6, 0x00FD, 0x0117, 0x0133,
	0x0151, 0x0173, 0x0198, 0x01C1, 0x01EE, 0x0220, 0x0256, 0x0292,
	0x02D4, 0x031C, 0x036C, 0x03C3, 0x0424, 0x048E, 0x0502, 0x0583,
	0x0610, 0x06AB, 0x0756, 0x0812, 0x08E0, 0x09C3, 0x0ABD, 0x0BD0,
	0x0CFF, 0x0E4C, 0x0FBA, 0x114C, 0x1307, 0x14EE, 0x1706, 0x1954,
	0x1BDC, 0x1EA5, 0x21B6, 0x2515, 0x28CA, 0x2CDF, 0x315B, 0x364B,
	0x3BB9, 0x41B2, 0x4844, 0x4F7E, 0x5771, 0x602F, 0x69CE, 0x7462,
	0x7FFF,
};

// One DS ADPCM decode step (GBATEK / melonDS: clamp to +-0x7FFF).
static void adpcm_step(int* val, int* idx, int nib)
{
	int s = k_step[*idx], d = s >> 3;
	if (nib & 1) d += s >> 2;
	if (nib & 2) d += s >> 1;
	if (nib & 4) d += s;
	if (nib & 8) { *val -= d; if (*val < -0x7FFF) *val = -0x7FFF; }
	else         { *val += d; if (*val > 0x7FFF) *val = 0x7FFF; }
	*idx += k_idx[nib & 7];
	if (*idx < 0) *idx = 0;
	if (*idx > 88) *idx = 88;
}

static int tri(int i)   // triangle, period 256 samples, +-20000
{
	int p = i & 255;
	return p < 128 ? -20000 + p * 312 : 20000 - (p - 128) * 312;
}

static void make_samples(void)
{
	for (int i = 0; i < SAW16_N; i++)
		s_saw16[i] = (s16)(-32768 + i * 64 + ((i * 37) & 63));   // every LSB pattern
	for (int i = 0; i < SAW8_N; i++)
		s_saw8[i] = (s8)(i - 128);
	// ADPCM tone: the triangle, greedily encoded (nibble with the least
	// error, lowest on ties). Header: value 0, index 0.
	int val = 0, idx = 0;
	s_adpcm_tone[0] = 0;
	u8* b = (u8*)&s_adpcm_tone[1];
	for (int n = 0; n < ADT_DATA * 8; n++) {
		int best = 0, berr = 1 << 30;
		for (int k = 0; k < 16; k++) {
			int v = val, x = idx;
			adpcm_step(&v, &x, k);
			int e = abs(v - tri(n));
			if (e < berr) { berr = e; best = k; }
		}
		adpcm_step(&val, &idx, best);
		if (n & 1) b[n >> 1] |= best << 4;
		else       b[n >> 1] = best;
	}
	// ADPCM random: LCG nibbles (a random walk that hits the clamps).
	// Header: value 0x1234, index 40.
	s_adpcm_rand[0] = 0x1234 | (40u << 16);
	u32 x = 0x2468ACE1u;
	for (int w = 0; w < ADR_DATA; w++) {
		u32 word = 0;
		for (int k = 0; k < 8; k++) { x = x * 1103515245u + 12345u; word |= (x >> 28) << (k * 4); }
		s_adpcm_rand[1 + w] = word;
	}
	armDCacheFlush(s_saw16, sizeof s_saw16);
	armDCacheFlush(s_saw8, sizeof s_saw8);
	armDCacheFlush(s_adpcm_tone, sizeof s_adpcm_tone);
	armDCacheFlush(s_adpcm_rand, sizeof s_adpcm_rand);
	armDCacheFlush(s_zero, sizeof s_zero);
}

// ---- Segments ----
static const char* const k_wave[] = { "saw16", "saw8", "adpcm_tone", "adpcm_rand", "psg" };
static const char* const k_mode[] = { "manual", "repeat", "oneshot" };
static const char* const k_fmt[] = { "pcm8", "pcm16", "adpcm", "psg" };

Seg s_seg[MAX_SEGS];   // read by v2.c for the index
int s_nseg;

static Seg* seg(const char* name)
{
	Seg* s = &s_seg[s_nseg++];
	memset(s, 0, sizeof *s);
	snprintf(s->name, sizeof s->name, "%s", name);
	s->mixvol = 127;
	s->captimer = CAP_TIMER;
	return s;
}

static void voice(Seg* s, int ch, int wave, int vol, int pan, int timer)
{
	Voice* v = &s->v[s->nv++];
	memset(v, 0, sizeof *v);
	v->ch = ch; v->wave = wave; v->vol = vol; v->pan = pan; v->timer = timer;
	v->mode = SoundMode_Repeat;
	switch (wave) {
	case W_SAW16: v->pnt = 0; v->len = SAW16_N / 2; break;
	case W_SAW8:  v->pnt = 0; v->len = SAW8_N / 4; break;
	case W_ADT:   v->pnt = 1 + ADT_DATA / 2; v->len = ADT_DATA / 2; break;
	case W_ADR:   v->pnt = 1; v->len = ADR_DATA; break;
	}
}

static void build_segments(void)
{
	static const int vols[] = { 2047, 1024, 127, 1 };
	static const int pans[] = { 0, 64, 127 };
	char n[24];
	Seg* s;
	// 1. PCM16 volume x pan
	for (unsigned i = 0; i < 4; i++)
		for (unsigned j = 0; j < 3; j++) {
			snprintf(n, sizeof n, "pcm16_v%d_p%d", vols[i], pans[j]);
			voice(seg(n), 4, W_SAW16, vols[i], pans[j], 512);
		}
	// 2. Volume divider: calico's 11-bit volume = vol7 << (4 - shift) with
	// the divider chosen from the range (<=127: /16, <512: /4, <1024: /2).
	static const int dvols[] = { 64, 127, 128, 508, 512, 1016, 1500, 2032 };
	for (unsigned i = 0; i < 8; i++) {
		snprintf(n, sizeof n, "voldiv_v%d", dvols[i]);
		voice(seg(n), 4, W_SAW16, dvols[i], 64, 512);
	}
	// 3. PCM8, ADPCM, loop points and one-shot
	voice(seg("pcm8"), 4, W_SAW8, 2047, 64, 512);
	s = seg("pcm8_loop");            // loop over the upper 3/4 of the ramp
	voice(s, 4, W_SAW8, 2047, 64, 512);
	s->v[0].pnt = 16; s->v[0].len = 48;
	s = seg("pcm16_oneshot");        // 1024 samples, then the channel stops
	voice(s, 4, W_SAW16, 2047, 64, 512);
	s->v[0].mode = SoundMode_OneShot;
	voice(seg("adpcm_tone"), 4, W_ADT, 2047, 64, 512);   // loop from mid-stream
	s = seg("adpcm_tone_pnt1");      // loop right after the header
	voice(s, 4, W_ADT, 2047, 64, 512);
	s->v[0].pnt = 1; s->v[0].len = ADT_DATA;
	s = seg("adpcm_oneshot");
	voice(s, 4, W_ADT, 2047, 64, 512);
	s->v[0].mode = SoundMode_OneShot;
	voice(seg("adpcm_rand"), 4, W_ADR, 2047, 64, 512);
	voice(seg("adpcm_rand_t700"), 4, W_ADR, 2047, 64, 700);
	// 4. PSG square, each duty (channels 8..13), and noise
	for (int d = 0; d < 8; d++) {
		snprintf(n, sizeof n, "psg_duty%d", d);
		s = seg(n);
		voice(s, 8 + d % 6, W_PSG, 2047, 64, 2048);
		s->v[0].duty = d;
	}
	voice(seg("noise14_t512"), 14, W_PSG, 2047, 64, 512);
	voice(seg("noise15_t1500"), 15, W_PSG, 2047, 64, 1500);
	// 5. Saturation: many channels at full volume
	for (int k = 0; k < 2; k++) {
		s = seg(k ? "sat_all_p0" : "sat_all_p64");
		int pan = k ? 0 : 64;
		for (int c = 4; c < 8; c++) voice(s, c, W_SAW16, 2047, pan, 512);
		for (int c = 8; c < 14; c++) { voice(s, c, W_PSG, 2047, pan, 2048); s->v[s->nv - 1].duty = 3; }
		voice(s, 14, W_PSG, 2047, pan, 512);
		voice(s, 15, W_PSG, 2047, pan, 777);
	}
	s = seg("sat_4saw_p64");
	for (int c = 4; c < 8; c++) voice(s, c, W_SAW16, 2047, 64, 512);
	// 6. Master volume (melonDS captures before it)
	static const int mv[] = { 127, 64, 1 };
	for (int i = 0; i < 3; i++) {
		snprintf(n, sizeof n, "mixvol%d", mv[i]);
		s = seg(n);
		voice(s, 4, W_SAW16, 2047, 64, 512);
		s->mixvol = mv[i];
	}
	// 7. Sample timers that don't match the capture timer
	static const int rt[] = { 333, 513, 700, 1234 };
	for (int i = 0; i < 4; i++) {
		snprintf(n, sizeof n, "rate_t%d", rt[i]);
		voice(seg(n), 4, W_SAW16, 2047, 64, rt[i]);
	}
	s = seg("cap_t700");             // capture slower than the mixer
	voice(s, 4, W_SAW16, 2047, 64, 512);
	s->captimer = 700;
	s = seg("cap_pcm8");             // 8-bit capture (written as s16 << 8)
	voice(s, 4, W_SAW16, 2047, 64, 512);
	s->capfmt = 1;
	// 8. Capture source = channel 0 / 2 (melonDS ignores it), and the same
	// channels captured from the mixer as the control.
	for (int k = 0; k < 2; k++) {
		s = seg(k ? "capsrc_cha" : "capsrc_mixer");
		voice(s, 0, W_SAW16, 2047, 0, 512);
		voice(s, 2, W_SAW8, 2047, 127, 512);
		voice(s, 8, W_PSG, 1024, 64, 2048);
		s->v[2].duty = 3;
		s->capsrc = k;
	}
}

static const void* wave_ptr(int w)
{
	switch (w) {
	case W_SAW16: return s_saw16;
	case W_SAW8:  return s_saw8;
	case W_ADT:   return s_adpcm_tone;
	case W_ADR:   return s_adpcm_rand;
	}
	return NULL;
}

static int wave_fmt(int w)
{
	switch (w) {
	case W_SAW16: return SoundFmt_Pcm16;
	case W_SAW8:  return SoundFmt_Pcm8;
	case W_ADT: case W_ADR: return SoundFmt_ImaAdpcm;
	}
	return SoundFmt_Psg;
}

// calico's 11-bit volume as written to SOUNDxCNT (soundPreparePcm).
static void enc_vol(int vol, int* v7, int* div)
{
	if (vol <= 127)       { *v7 = vol; *div = 3; }
	else if (vol < 512)   { *v7 = (vol >> 2) & 127; *div = 2; }
	else if (vol < 1024)  { *v7 = (vol >> 3) & 127; *div = 1; }
	else if (vol < 2048)  { *v7 = (vol >> 4) & 127; *div = 0; }
	else                  { *v7 = 127; *div = 0; }
}

static void progress(const char* fmt, ...)
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

static void fname(char fn[48], const Seg* s, int u)
{
	snprintf(fn, 48, "sndcap_%.23s_%c.bin", s->name, u ? 'R' : 'L');
}

static u32 s_wait_after;   // bounded settle wait after stop, cycles

static void busy_wait(u32 cycles)
{
	u32 t0 = now32();
	while (now32() - t0 < cycles) {}
}

static bool run_segment(Seg* s)
{
	u32 bytes = s->capfmt ? NSAMP : NSAMP * 2;
	u32* cap[2];
	for (int u = 0; u < 2; u++) {
		cap[u] = aligned_alloc(32, bytes);
		s->out[u] = s->capfmt ? aligned_alloc(32, NSAMP * 2) : (s16*)cap[u];
		if (!cap[u] || !s->out[u]) return false;
		for (u32 i = 0; i < bytes / 4; i++) cap[u][i] = SENTINEL;
		armDCacheFlush(cap[u], bytes);
	}

	soundStop(0x3FFFF);
	soundSetMixerVolume(s->mixvol);
	u32 used = 0;
	for (int i = 0; i < s->nv; i++) used |= 1u << s->v[i].ch;
	for (int c = 0; c < 4; c++)
		if (!(used & (1u << c)))
			soundPreparePcm(c, 0, 64, s->captimer, SoundMode_Repeat, SoundFmt_Pcm16, s_zero, 0, 4);
	for (int i = 0; i < s->nv; i++) {
		const Voice* v = &s->v[i];
		if (v->wave == W_PSG)
			soundPreparePsg(v->ch, v->vol, v->pan, v->timer, (SoundDuty)v->duty);
		else
			soundPreparePcm(v->ch, v->vol, v->pan, v->timer, (SoundMode)v->mode,
			                (SoundFmt)wave_fmt(v->wave), wave_ptr(v->wave), v->pnt, v->len);
	}
	for (int u = 0; u < 2; u++)
		soundPrepareCap(u, SoundCapDst_ChBNormal, s->capsrc ? SoundCapSrc_ChA : SoundCapSrc_Mixer,
		                false, s->capfmt ? SoundCapFmt_Pcm8 : SoundCapFmt_Pcm16, cap[u], bytes / 4);

	// Expected: NSAMP capture periods of captimer sound clocks (2 system
	// cycles each). Timeout: that plus 0.5 s.
	u32 expect = (u32)NSAMP * s->captimer * 2;
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
	busy_wait(s_wait_after);
	for (int u = 0; u < 2; u++) {
		armDCacheInvalidate(cap[u], bytes);
		u32 un = 0;
		for (int i = bytes / 4 - 1; i >= 0 && cap[u][i] == SENTINEL; i--) un++;
		s->unwritten[u] = un;
		if (s->capfmt) {
			const s8* b = (const s8*)cap[u];
			for (int i = 0; i < NSAMP; i++) s->out[u][i] = (s16)(b[i] * 256);
			free(cap[u]);
		}
		int mn = 32767, mx = -32768, pk = 0;
		for (int i = 0; i < NSAMP; i++) {
			int x = s->out[u][i];
			if (x < mn) mn = x;
			if (x > mx) mx = x;
			if (abs(x) > pk) pk = abs(x);
		}
		s->vmin[u] = mn; s->vmax[u] = mx; s->peak[u] = pk;
	}
	return true;
}

int main(void)
{
	hw_init(VERSION " - sound capture");
	if (hw_fat_ok) remove(HWREF_DIR "/sndcap_progress.txt");
	soundInit();
	soundPowerOn();
	soundSetMixerConfig(SoundOutSrc_Mixer, SoundOutSrc_Mixer, false, false);
	soundSetMixerVolume(127);
	s_wait_after = 33514 * 2;   // 2 ms: the stop command reaches the ARM7
	busy_wait(33514 * 20);      // 20 ms after power-on
	make_samples();
	build_segments();
	progress("%s start, %d segments", VERSION, s_nseg);
	hw_status("%d segments, %d samples each", s_nseg, NSAMP);

	u32 t_all = now32();
	int timeouts = 0;
	for (int i = 0; i < s_nseg; i++) {
		Seg* s = &s_seg[i];
		progress("start %s", s->name);
		if (!run_segment(s)) { hw_status("OUT OF MEMORY at %s", s->name); s_nseg = i; break; }
		if (s->timeout) timeouts++;
		iprintf("%2d %-15s%5d %5d%s\n", i + 1, s->name, s->peak[0], s->peak[1], s->timeout ? " TO" : "");
	}
	soundStop(0x3FFFF);
	u32 t_run = now32() - t_all;
	progress("captures done, timeouts=%d", timeouts);

	Buf info = {0}, idx = {0};
	buf_printf(&info, "%s\nbuilt %s %s\n", VERSION, __DATE__, __TIME__);
	buf_printf(&info, "samples_per_capture %d\nsound_clock %u Hz (capture rate = sound_clock / cap_timer)\n", NSAMP, SND_CLOCK);
	buf_printf(&info, "capture: unit 0 = L, unit 1 = R, one-shot, files raw s16 LE (pcm8 capture written as s8 * 256)\n");
	buf_printf(&info, "silent: channels 0..3 not used by a segment play %s at volume 0, timer = cap_timer, repeat, 4 words\n", "zeros");
	buf_printf(&info, "waves: saw16 = %d x s16 (-32768 + i*64 + ((i*37)&63)); saw8 = %d x s8 (i-128); "
	           "adpcm_tone = header 0/idx 0 + %d words, greedy encoding of a +-20000 triangle, period 256; "
	           "adpcm_rand = header 0x1234/idx 40 + %d words of LCG nibbles\n", SAW16_N, SAW8_N, ADT_DATA, ADR_DATA);
	buf_printf(&info, "vol: calico 11-bit, written as vol7 + divider (div 0=/1 1=/2 2=/4 3=/16)\n");
	buf_printf(&info, "run_cycles %lu timeouts %d\n\n", (unsigned long)t_run, timeouts);
	buf_printf(&idx, "segment,file,rate_hz,samples\n");
	for (int i = 0; i < s_nseg; i++) {
		Seg* s = &s_seg[i];
		unsigned rate = (SND_CLOCK + s->captimer / 2) / s->captimer;
		buf_printf(&info, "segment %s cap_timer=%u rate_hz=%u cap_src=%s cap_fmt=%s mixer_vol=%u "
		           "done_cycles=%lu timeout=%d unwritten_words=%lu,%lu min=%d,%d max=%d,%d\n",
		           s->name, s->captimer, rate, s->capsrc ? "cha" : "mixer", s->capfmt ? "pcm8" : "pcm16",
		           s->mixvol, (unsigned long)s->done_cycles, s->timeout,
		           (unsigned long)s->unwritten[0], (unsigned long)s->unwritten[1],
		           s->vmin[0], s->vmin[1], s->vmax[0], s->vmax[1]);
		for (int k = 0; k < s->nv; k++) {
			const Voice* v = &s->v[k];
			int v7, div;
			enc_vol(v->vol, &v7, &div);
			if (v->wave == W_PSG)
				buf_printf(&info, "  ch=%u fmt=%s vol=%u (vol7=%d div=%d) pan=%u timer=%u duty=%u\n",
				           v->ch, v->ch >= 14 ? "noise" : "square", v->vol, v7, div, v->pan, v->timer, v->duty);
			else
				buf_printf(&info, "  ch=%u fmt=%s wave=%s mode=%s vol=%u (vol7=%d div=%d) pan=%u timer=%u pnt=%u len=%lu\n",
				           v->ch, k_fmt[wave_fmt(v->wave)], k_wave[v->wave], k_mode[v->mode], v->vol, v7, div,
				           v->pan, v->timer, v->pnt, (unsigned long)v->len);
		}
		for (int u = 0; u < 2; u++) {
			char fn[48];
			fname(fn, s, u);
			buf_printf(&idx, "%s,%s,%u,%d\n", s->name, fn, rate, NSAMP);
		}
	}
	iprintf("writing files...\n");
	for (int i = 0; i < s_nseg; i++)
		for (int u = 0; u < 2; u++) {
			char fn[48];
			fname(fn, &s_seg[i], u);
			hw_write(fn, s_seg[i].out[u], NSAMP * 2);
		}
	buf_write(&idx, "sndcap_index.csv");
	buf_write(&info, "sndcap_info.txt");
	progress("files written");
	sndcap_v2_main();   // v1: hw_done()
}
