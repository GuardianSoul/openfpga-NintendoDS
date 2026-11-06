// gxburst (docs/hw-reference.md "gxburst"; coordinator and geometry session):
// how fast the DS drains real game frames sent by GX FIFO DMA. Our GX
// engine fell behind NSMB's display-list bursts and held the GX DMA
// (90-110K clocks of backpressure per frame); the DS's 256-entry FIFO never
// fills by our timing model.
//
// For each replay/list.txt frame (the replay3d files): the warm-up flushes
// rebuild the matrices by CPU writes as in replay3d, then the target
// flush's whole command list (without its SWAP and the test commands) goes
// by DMA1 in GX FIFO mode (start mode 7: 112 words whenever the FIFO is
// under half full), packed 4 commands to a word, from main RAM. A sampler
// (I-cache warm, samples in DTCM: the ARM9 keeps running during a DMA only
// from TCM or cache, run 22) reads GXSTAT and DMA1CNT until the engine is
// idle and the DMA done:
//   gxburst.csv: file, commands, words, entries, polys, verts (RAM_COUNT),
//     t_dma (DMA enable cleared), t_idle (GXSTAT busy cleared), max_level,
//     iters, iters_ge240 (FIFO level >= 240), timeouts
//   gxburst_tl.csv: file, t, level, dma: a sample every 1,024 ticks
// Times in system cycles (33.514 MHz; TM0+TM1) from the DMA start.
// v2 (run 28: the DS made more vertices than replay3d's CPU writes on 7 of
// 11 frames, with the same polygons): every frame by five deliveries,
// gxburst_modes.csv: file, mode, words, polys, verts, t_idle, max_level,
// timeouts; modes dma_packed4 (v1), dma_packed1 (one command per word),
// cpu_packed4 (the same words, CPU stores back to back), cpu_ports (each
// entry to its command port, back to back), cpu_polled (gxp_put, as
// replay3d). Where dma_packed4 and cpu_polled differ, a binary search on
// the prefix length finds the first command after which they differ:
// gxburst_bisect.csv: file, cmd_index, cmd, gxb_offset (its first 'C'
// record in the .gxb), the vertex counts of both before and after it.
// v3 (geometry session: is run 28's 1.15x over melonDS the DMA feed or the
// commands?): two more deliveries, cpu_burst (112 packed words at a time by
// LDM/STM from DTCM whenever the FIFO is under half, copied from main RAM
// while it isn't) and dma_vram (mode 7 DMA from VRAM A-D at LCDC instead
// of main RAM), cpu_stm (LDM/STM 8 words at a time from main RAM to
// GXFIFO, no waiting: a full FIFO holds the CPU), and min_level (the lowest
// FIFO level once it has filled, while the feed runs; 511: never filled or
// not sampled) for the DMA modes and cpu_burst.
// v3.1 (v3 hung on the DS after hgbattle, no output): every feed waits for
// room with a bound and recovers a stuck engine (timeouts column counts
// them), gxburst_progress.txt gets a line before each file, mode and bisect
// step, and the CSVs are appended after each file.
// v3.2 (v3.1 hung at hggold cpu_ports, after cpu_stm): the matrix-stack
// reset before each mode is bounded (gxplay.c), cpu_ports waits for room
// for a whole command, and each mode logs a progress line when it ends.
// v4 (v3.2: hggold's cpu_burst wedged the DS engine, no recovery, then
// cpu_stm hung the CPU): cpu_burst checks for room before each STM; the
// modes run in phases over all files (DMA, room-checked CPU, bisect, the
// rest), results are appended after each mode, and a hang is resumable
// (gxburst_state.txt, below).
// v7 (geometry session, after run 32): only the 28 rejection mixes r_*
// (tri strip / triangles x near, far, left, right, top, bottom, back-face
// culled x plain / TEXCOORD+NORMAL with 1 light) and two controls.
// v6 (geometry session, after run 30): only prefixes() for mkds and nsmb
// and the mix c_texcoord_t3 (texcoord transform mode 3) with three
// controls; the other phases and mixes were measured in run 30.
// v4.1 (run 29: after cpu_stm wedged the engine on hggold, every later mode
// ran into its timeouts, slowly, until the DS hung): the first recovery
// ends the run with a message to power-cycle the DS; the mode gets no E
// line, so the restart skips it as unsafe.
#include "../common/gxplay.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VERSION "gxburst 7"
#define REPLAY_DIR HWREF_DIR "/replay"
#define MAX_FILES 32
#define NSAMP 1024
#define PERIOD 1024
#define LIMIT 3000000u    // sampler iterations: a few seconds on the DS

static const u32 s_bank_size[9] = { 0x20000, 0x20000, 0x20000, 0x20000, 0x10000, 0x4000, 0x4000, 0x8000, 0x4000 };
static u32 s_samp[NSAMP] DTCM_BSS;

// v3.1: every wait is bounded. A stuck engine (on the DS after unfinished
// polygons, gxtime v4/v5) is recovered as gxtime does: FIFO cleared, then a
// geometry power cycle if it stays busy. s_stuck counts them per mode.
static u32 s_stuck;
static bool s_wedged;   // v4.1: after any recovery the engine is unreliable until a power-off (run 29)
static void recover(void)
{
	s_stuck++;
	s_wedged = true;
	REG32(0x040000C4) = 0;                    // DMA1 off
	R_GXSTAT = (1u << 29) | (1u << 15);
	if (R_GXSTAT & GXSTAT_BUSY) {
		R_POWCNT1 &= ~(1u << 3);
		for (volatile int i = 0; i < 1000; i++) {}
		R_POWCNT1 |= (1u << 3);
		R_GXSTAT = (1u << 29) | (1u << 15);
		for (u32 i = 0; i < 200000 && (R_GXSTAT & GXSTAT_BUSY); i++) {}
	}
}

// Waits (bounded) until the FIFO level is at most max; false after a recovery.
static inline bool room(u32 max)
{
	for (u32 i = 0; ((R_GXSTAT >> 16) & 0x1FF) > max; i++)
		if (i > 2000000) { recover(); return false; }
	return true;
}

static void progress(const char* fmt, ...)
{
	if (!hw_fat_ok) return;
	FILE* f = fopen(HWREF_DIR "/gxburst_progress.txt", "a");
	if (!f) return;
	va_list ap;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

// Appends a buffer to fat:/hwref/<name> and empties it (results survive a hang).
static void append(Buf* b, const char* name)
{
	if (hw_fat_ok && b->len) {
		char path[96];
		snprintf(path, sizeof path, HWREF_DIR "/%s", name);
		FILE* f = fopen(path, "a");
		if (f) { fwrite(b->p, 1, b->len, f); fclose(f); }
	}
	free(b->p);
	b->p = NULL;
	b->len = b->cap = 0;
}

// Parameters per command (GBATEK "DS 3D Geometry Commands").
static int params(u8 c)
{
	switch (c) {
	case 0x11: case 0x15: case 0x41: return 0;
	case 0x16: case 0x18: return 16;
	case 0x17: case 0x19: return 12;
	case 0x1A: return 9;
	case 0x1B: case 0x1C: case 0x70: return 3;
	case 0x23: case 0x71: return 2;
	case 0x34: return 32;
	default: return 1;
	}
}

static inline u32 rd32(const u8* p) { return p[0] | p[1] << 8 | p[2] << 16 | (u32)p[3] << 24; }

typedef struct { u32 t_dma, t_idle, max_level, iters, ge240, n, min_level; } Res;

// Main RAM, ARM, aligned: warmed into the I-cache before the timed run.
__attribute__((target("arm"), noinline, aligned(32)))
static void sample(const u32* src, u32 words, Res* r)
{
	u32 tdma = 0, tidle = 0, maxl = 0, it = 0, ge = 0, n = 0, next = 0, minl = 0x1FF, primed = 0;
	if (words) {
		REG32(0x040000BC) = (u32)src;
		REG32(0x040000C0) = 0x04000400;
		REG32(0x040000C4) = (1u << 31) | (1u << 26) | (7u << 27) | (2u << 21) | words;
	}
	u32 t0 = now32();
	for (;;) {
		u32 s = R_GXSTAT, d = REG32(0x040000C4) >> 31, t = now32() - t0, l = (s >> 16) & 0x1FF;
		it++;
		if (l > maxl) maxl = l;
		if (l >= 100) primed = 1;            // the minimum once the FIFO has filled, while the DMA runs
		if (primed && d && l < minl) minl = l;
		if (l >= 240) ge++;
		if (!d && !tdma) tdma = t | 1;
		if (t >= next && n < NSAMP) { s_samp[n++] = (t >> 1 & 0x3FFFFF) | l << 22 | d << 31; next += PERIOD; }
		if ((!(s & GXSTAT_BUSY) && !d) || it > LIMIT) { tidle = t; break; }
	}
	if (it > LIMIT) recover();
	r->t_dma = tdma;
	r->t_idle = tidle;
	r->max_level = maxl;
	r->iters = it;
	r->ge240 = ge;
	r->n = n;
	r->min_level = minl;
}

// v3 (geometry session): the same packed words by the CPU in DMA-like
// bursts. While the FIFO is at least half full, the next 112 words are
// copied from main RAM into DTCM; once it is under half, they go to
// GXFIFO by LDM/STM (GXFIFO repeats over 0x04000400-0x0400043F). min_level:
// the lowest level seen at a refill, once the FIFO has filled.
static u32 s_burst[112] DTCM_BSS __attribute__((aligned(32)));
__attribute__((target("arm"), noinline, aligned(32)))
static void cpu_burst(const u32* src, u32 words, Res* r)
{
	u32 minl = 0x1FF, primed = 0, i = 0;
	u32 t0 = now32();
	while (i < words) {
		u32 n = words - i < 112 ? words - i : 112;
		for (u32 j = 0; j < n; j++) s_burst[j] = src[i + j];
		for (u32 j = n; j < (n + 7) / 8 * 8; j++) s_burst[j] = 0;   // NOP words pad the last STM
		u32 l, w = 0;
		while ((l = (R_GXSTAT >> 16) & 0x1FF) >= 128 && ++w < 2000000) primed = 1;
		if (w >= 2000000) { recover(); break; }
		if (primed && l < minl) minl = l;
		u32* b = s_burst;
		for (u32 j = 0; j < n; j += 8, b += 8) {
			if (!room(224)) { i = words; break; }   // v4: never STM into a full FIFO (v3.2 wedged the DS engine)
			__asm__ volatile("ldm %0, {r2-r9}\n stm %1, {r2-r9}\n" :: "r"(b), "r"(0x04000400)
			                 : "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "memory");
		}
		if (i < words) i += n;
	}
	u32 it = 0;
	while ((R_GXSTAT & GXSTAT_BUSY) && ++it < LIMIT) ;
	r->t_idle = now32() - t0;
	if (it >= LIMIT) recover();
	r->min_level = minl;
}

// The file, parsed once: the target flush as commands (cmd, parameter
// index, count, the .gxb offset of its first entry).
typedef struct { u8 cmd, np; u16 pad; u32 p, off; } Cmd;
static u8* s_d;
static long s_len;
static size_t s_target;        // first record of the target flush
static Cmd* s_cmd;
static u32* s_par;
static u32 s_ncmd, s_swap, s_np;
static GxpRegs s_regs;         // the target flush's 'F' record
static u32* s_w;               // packed words for DMA / CPU-packed

static void warm(void)
{
	gxp_reset_geometry();
	gxp_timeouts = 0;
	GxpRegs r = {0};
	for (size_t i = 8; i < s_target && !gxp_timeouts;) {
		u8 t = s_d[i++];
		if (t == 'V') { i += 13; for (int b = 0; b < 9; b++) i += s_bank_size[b]; continue; }
		if (t == 'F') { i += GXP_FREC_SIZE; continue; }
		u8 c = s_d[i];
		u32 v = rd32(s_d + i + 1);
		i += 5;
		if (!gxp_valid_cmd(c) || (c >= 0x70 && c <= 0x72)) continue;
		if (c != 0x50) { gxp_put(c, v); continue; }
		if (i < (size_t)s_len && s_d[i] == 'F') { gxp_parse_regs(&r, s_d + i + 1); i += 1 + GXP_FREC_SIZE; }
		gxp_set_regs(&r);
		gxp_swap(v);
	}
	gxp_wait_idle();
	wait_vcount(200);   // after the previous swap's VBlank, well before the next
}

// Packs commands [0, k): per == 4 (as games) or 1 command per word.
// -DBISECT_TEST (melonDS check of the bisect): the packed words leave out
// the first VTX_16 from command 5000 on, which the bisect must then report.
static u32 pack(u32 k, int per)
{
	u32 nw = 0, skip = ~0u;
#ifdef BISECT_TEST
	for (u32 i = 5000; i < s_ncmd && skip == ~0u; i++) if (s_cmd[i].cmd == 0x23) skip = i;
#endif
	for (u32 i = 0; i < k;) {
		u32 h = nw++, cmds = 0;
		int n = 0;
		u32 first = i;
		for (; n < per && i < k; i++) {
			if (i == skip) continue;
			cmds |= (u32)s_cmd[i].cmd << (8 * n++);
		}
		s_w[h] = cmds;
		for (u32 j = first; j < i; j++)
			if (j != skip)
				for (u32 q = 0; q < s_cmd[j].np; q++) s_w[nw++] = s_par[s_cmd[j].p + q];
	}
	return nw;
}

enum { M_DMA4, M_DMA1, M_CPU_PACKED, M_CPU_BURST, M_DMA_VRAM, M_CPU_STM, M_CPU_PORTS, M_CPU_POLLED, M_N };
static const char* s_mode_name[M_N] = { "dma_packed4", "dma_packed1", "cpu_packed4", "cpu_burst", "dma_vram",
                                        "cpu_stm", "cpu_ports", "cpu_polled" };

// The packed words by LDM/STM, 8 at a time, straight from (cached) main RAM
// to GXFIFO; v3.1 checks for room (level <= 128) before every fourth STM instead of
// letting a full FIFO hold the CPU. words is rounded up; the words after the
// list are NOPs (0).
__attribute__((target("arm"), noinline, aligned(32)))
static void cpu_stm(const u32* src, u32 words)
{
	for (u32 n = (words + 7) / 8; n; n--, src += 8) {
		// v3.1: 32 words are at most 128 entries, so at level <= 128 four STMs never block
		if (!(n & 3) && !room(128)) return;
		__asm__ volatile("ldm %0, {r2-r9}\n stm %1, {r2-r9}\n" :: "r"(src), "r"(0x04000400)
		                 : "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "memory");
	}
}
#define VRAM_SRC ((u32*)0x06800000)   // banks A-D at LCDC: 512 KiB

// Commands [0, k) by `mode` after the warm-up; RAM_COUNT once idle.
static u32 run_mode(int mode, u32 k, Res* res)
{
	warm();
	u32 nw = mode <= M_CPU_STM ? pack(k, mode == M_DMA1 ? 1 : 4) : 0;
	for (u32 i = nw; i < (nw + 7) / 8 * 8; i++) s_w[i] = 0;
	DC_FlushRange(s_w, nw * 4 + 32);
	if (mode == M_DMA_VRAM) {
		for (int b = 0; b < 4; b++) R_VRAMCNT(b) = 0x80;
		for (u32 i = 0; i < nw; i++) VRAM_SRC[i] = s_w[i];
	}
	memset(res, 0, sizeof *res);
	res->min_level = 0x1FF;
	ArmIrqState st = armIrqLockByPsr();
	if (mode <= M_DMA1 || mode == M_DMA_VRAM) {
		sample(NULL, 0, res);       // warms the sampler's I-cache lines
		sample(mode == M_DMA_VRAM ? VRAM_SRC : s_w, nw, res);
	} else if (mode == M_CPU_BURST) {
		cpu_burst(s_w, 0, res);     // warms its I-cache lines
		cpu_burst(s_w, nw, res);
	} else {
		u32 t0 = now32();
		if (mode == M_CPU_PACKED)
			for (u32 i = 0; i < nw && room(252); i++) *(vu32*)0x04000400 = s_w[i];
		else if (mode == M_CPU_STM) {
			cpu_stm(s_w, 0);         // warms its I-cache lines
			cpu_stm(s_w, nw);
#ifdef WEDGE_TEST
			recover();               // melonDS check of the v4.1 stop path
#endif
		}
		else if (mode == M_CPU_PORTS)
			for (u32 i = 0; i < k; i++) {
				vu32* port = GXPORT(s_cmd[i].cmd);
				if (!room(256 - (s_cmd[i].np ? s_cmd[i].np : 1))) break;   // never block on a full FIFO
				if (!s_cmd[i].np) *port = 0;
				for (u32 q = 0; q < s_cmd[i].np; q++) *port = s_par[s_cmd[i].p + q];
			}
		armIrqUnlockByPsr(st);
		if (mode == M_CPU_POLLED)
			for (u32 i = 0; i < k; i++) {
				if (!s_cmd[i].np) gxp_put(s_cmd[i].cmd, 0);
				for (u32 q = 0; q < s_cmd[i].np; q++) gxp_put(s_cmd[i].cmd, s_par[s_cmd[i].p + q]);
			}
		if (!gxp_wait_idle()) recover();
		res->t_idle = now32() - t0;
		st = armIrqLockByPsr();
	}
	armIrqUnlockByPsr(st);
	u32 rc = gxp_ramcount();
	gxp_set_regs(&s_regs);
	gxp_swap(s_swap);
	return rc;
}

static bool parse(const char* name, Buf* csv)
{
	char path[128];
	snprintf(path, sizeof path, REPLAY_DIR "/%s", name);
	FILE* f = fopen(path, "rb");
	if (!f) { buf_printf(csv, "%s,open failed\n", name); return false; }
	fseek(f, 0, SEEK_END);
	s_len = ftell(f);
	fseek(f, 0, SEEK_SET);
	s_d = malloc(s_len);
	bool ok = s_d && fread(s_d, 1, s_len, f) == (size_t)s_len;
	fclose(f);
	if (!ok || s_len < 9 || memcmp(s_d, "NDSGX001", 8)) { buf_printf(csv, "%s,bad file\n", name); return false; }
	// the target is the last flush: its commands start after the previous flush's 'F' record
	int nflush = 0;
	size_t prev_end = 8;
	s_target = 8;
	u32 nent = 0;
	for (size_t i = 8; i < (size_t)s_len;) {
		u8 t = s_d[i++];
		if (t == 'C') { i += 5; nent++; }
		else if (t == 'F') { i += GXP_FREC_SIZE; nflush++; s_target = prev_end; prev_end = i; }
		else if (t == 'V') { i += 13; for (int b = 0; b < 9; b++) i += s_bank_size[b]; }
	}
	if (nflush < 1) { buf_printf(csv, "%s,no flush\n", name); return false; }
	nent = 0;   // the target flush's entries only
	for (size_t i = s_target; i < (size_t)s_len;) {
		u8 t = s_d[i++];
		if (t == 'C') { i += 5; nent++; }
		else if (t == 'F') i += GXP_FREC_SIZE;
		else if (t == 'V') { i += 13; for (int b = 0; b < 9; b++) i += s_bank_size[b]; }
	}
	s_cmd = malloc(nent * sizeof(Cmd));
	s_par = malloc(nent * 4);
	s_w = malloc(nent * 8 + 64);
	if (!s_cmd || !s_par || !s_w) { buf_printf(csv, "%s,out of memory\n", name); return false; }
	s_ncmd = 0;
	u32 npar = 0;
	for (size_t i = s_target; i < (size_t)s_len;) {
		u8 t = s_d[i++];
		if (t == 'V') { i += 13; for (int b = 0; b < 9; b++) i += s_bank_size[b]; continue; }
		if (t == 'F') { gxp_parse_regs(&s_regs, s_d + i); i += GXP_FREC_SIZE; continue; }
		u8 c = s_d[i];
		if (c == 0x50) { s_swap = rd32(s_d + i + 1); i += 5; continue; }
		if (!gxp_valid_cmd(c) || (c >= 0x70 && c <= 0x72)) { i += 5; continue; }
		int k = params(c), m = k ? k : 1;
		Cmd* cm = &s_cmd[s_ncmd++];
		cm->cmd = c;
		cm->np = 0;
		cm->p = npar;
		cm->off = i - 1;
		for (int j = 0; j < m; j++, i += 5) {   // one 'C' record per entry
			if (j) { if (s_d[i] != 'C' || s_d[i + 1] != c) break; i++; }
			if (j < k) { s_par[npar++] = rd32(s_d + i + 1); cm->np++; }
		}
	}
	return true;
}

static void release(void)
{
	free(s_d); free(s_cmd); free(s_par); free(s_w);
	s_d = NULL; s_cmd = NULL; s_par = NULL; s_w = NULL;
}

#define VERTS(rc) (((rc) >> 16) & 0x1FFF)

// v4: resumable. fat:/hwref/gxburst_state.txt gets "B <file> <mode>" before
// and "E <file> <mode> <verts>" after each mode (mode "bisect" too), and
// "DONE" at the end. A start that finds the state without DONE resumes: it
// keeps the CSVs, skips what ended, and treats a mode that began without
// ending (the DS hung in it) as unsafe for every remaining file. So after a
// hang the maintainer restarts the DS and the program, on the same card.
#define MAXF MAX_FILES
#define M_BISECT M_N
static int s_ended[MAXF][M_N + 1];     // 0 no, 1 + verts
static bool s_mix_ended[64], s_mix_unsafe[64];
static int mix_index(const char* m);
static bool s_unsafe[M_N + 1];
static char* s_names[MAXF];
static int s_nfiles;

static int file_index(const char* f) { for (int i = 0; i < s_nfiles; i++) if (!strcmp(s_names[i], f)) return i; return -1; }
static int mode_index(const char* m)
{
	if (!strcmp(m, "bisect")) return M_BISECT;
	for (int i = 0; i < M_N; i++) if (!strcmp(m, s_mode_name[i])) return i;
	return -1;
}
static const char* mode_str(int m) { return m == M_BISECT ? "bisect" : s_mode_name[m]; }

static void state(const char* fmt, ...)
{
	FILE* f = fopen(HWREF_DIR "/gxburst_state.txt", "a");
	if (!f) return;
	va_list ap;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

// True when a previous, unfinished run left a state to resume.
static bool load_state(void)
{
	FILE* f = fopen(HWREF_DIR "/gxburst_state.txt", "r");
	if (!f) return false;
	char line[128], fn[64], md[32], open_f[64] = "", open_m[32] = "";
	bool done = false, ours = false;
	unsigned long v;
	while (fgets(line, sizeof line, f)) {
		if (!strncmp(line, "V " VERSION, 2 + strlen(VERSION))) ours = true;   // a state from another version starts afresh
		if (!strncmp(line, "DONE", 4)) done = true;
		else if (sscanf(line, "B %63s %31s", fn, md) == 2) { strcpy(open_f, fn); strcpy(open_m, md); }
		else if (sscanf(line, "E %63s %31s %lu", fn, md, &v) == 3) {
			int fi = file_index(fn), mi = mode_index(md);
			if (fi >= 0 && mi >= 0) s_ended[fi][mi] = 1 + v;
			if (!strcmp(fn, "mix") && mix_index(md) >= 0) s_mix_ended[mix_index(md)] = true;
			open_f[0] = 0;
		}
	}
	fclose(f);
	if (done || !ours) {   // start afresh: forget what this file said
		memset(s_ended, 0, sizeof s_ended);
		memset(s_unsafe, 0, sizeof s_unsafe);
		memset(s_mix_ended, 0, sizeof s_mix_ended);
		memset(s_mix_unsafe, 0, sizeof s_mix_unsafe);
		return false;
	}
	if (open_f[0]) {
		if (!strcmp(open_f, "mix")) { if (mix_index(open_m) >= 0) s_mix_unsafe[mix_index(open_m)] = true; }
		else { int mi = mode_index(open_m); if (mi >= 0) s_unsafe[mi] = true; }
		state("H %s %s", open_f, open_m);   // hung here in the previous start
	}
	return true;
}

static void run_one(int fi, int m, Buf* csv, Buf* tl, Buf* modes)
{
	const char* name = s_names[fi];
	Res res;
	state("B %s %s", name, s_mode_name[m]);
	progress("%s %s", name, s_mode_name[m]);
	iprintf("\x1b[20;0H%-14.14s %-12s   ", name, s_mode_name[m]);
	s_stuck = 0;
	u32 rc = run_mode(m, s_ncmd, &res);
	progress("  done, t_idle %lu, verts %lu, recoveries %lu, gxp timeouts %lu", (unsigned long)res.t_idle,
	         (unsigned long)VERTS(rc), (unsigned long)s_stuck, (unsigned long)gxp_timeouts);
	u32 words = m <= M_CPU_STM ? pack(s_ncmd, m == M_DMA1 ? 1 : 4) : 0;
	buf_printf(modes, "%s,%s,%lu,%lu,%lu,%lu,%lu,%lu,%lu\n", name, s_mode_name[m], (unsigned long)words,
	           (unsigned long)(rc & 0xFFF), (unsigned long)VERTS(rc), (unsigned long)res.t_idle,
	           (unsigned long)res.max_level, (unsigned long)res.min_level, (unsigned long)(gxp_timeouts + s_stuck));
	if (m == M_DMA4) {
		u32 nw = pack(s_ncmd, 4), nent = 0;
		for (u32 i = 0; i < s_ncmd; i++) nent += s_cmd[i].np ? s_cmd[i].np : 1;
		buf_printf(csv, "%s,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu\n", name, (unsigned long)s_ncmd,
		           (unsigned long)nw, (unsigned long)nent, (unsigned long)(rc & 0xFFF),
		           (unsigned long)VERTS(rc), (unsigned long)res.t_dma, (unsigned long)res.t_idle,
		           (unsigned long)res.max_level, (unsigned long)res.iters, (unsigned long)res.ge240,
		           (unsigned long)gxp_timeouts);
		for (u32 k = 0; k < res.n; k++)
			buf_printf(tl, "%s,%lu,%lu,%lu\n", name, (unsigned long)((s_samp[k] & 0x3FFFFF) << 1),
			           (unsigned long)((s_samp[k] >> 22) & 0x1FF), (unsigned long)(s_samp[k] >> 31));
	}
	append(csv, "gxburst.csv");
	append(tl, "gxburst_tl.csv");
	append(modes, "gxburst_modes.csv");
	if (s_wedged) {   // no E line: a restart treats this mode as unsafe and skips it
		progress("  engine wedged in %s %s: stopping", name, s_mode_name[m]);
		iprintf("\x1b[20;0H3D engine stuck in %s.\nTurn the DS off and on, then\nstart this again: it resumes.\n", s_mode_name[m]);
		hw_done();
	}
	state("E %s %s %lu", name, s_mode_name[m], (unsigned long)VERTS(rc));
	s_ended[fi][m] = 1 + VERTS(rc);
}

// Bisect: the shortest prefix where the packed DMA's vertex count leaves
// the polled CPU writes' (counts are cumulative, so the first difference
// stays). lo agrees, hi differs.
static void bisect(int fi, Buf* bis)
{
	const char* name = s_names[fi];
	state("B %s bisect", name);
	u32 lo = 0, hi = s_ncmd;
	Res res;
	while (hi - lo > 1) {
		u32 mid = lo + (hi - lo) / 2;
		u32 a = run_mode(M_DMA4, mid, &res), b = run_mode(M_CPU_POLLED, mid, &res);
		if (VERTS(a) != VERTS(b)) hi = mid; else lo = mid;
		progress("%s bisect %lu-%lu", name, (unsigned long)lo, (unsigned long)hi);
		iprintf("\x1b[20;0H%-14.14s bisect %lu-%lu   ", name, (unsigned long)lo, (unsigned long)hi);
	}
	u32 a = run_mode(M_DMA4, hi, &res), b = run_mode(M_CPU_POLLED, hi, &res);
	u32 a0 = run_mode(M_DMA4, lo, &res), b0 = run_mode(M_CPU_POLLED, lo, &res);
	const Cmd* c = &s_cmd[hi - 1];
#ifdef BISECT_TEST
	{ u32 sk = 0; for (u32 i = 5000; i < s_ncmd; i++) if (s_cmd[i].cmd == 0x23) { sk = i; break; } buf_printf(bis, "skip %lu: ", (unsigned long)sk); }
#endif
	buf_printf(bis, "%s,%lu,%02x,%lu,%lu,%lu,%lu,%lu\n", name, (unsigned long)(hi - 1), c->cmd, (unsigned long)c->off,
	           (unsigned long)VERTS(a0), (unsigned long)VERTS(b0), (unsigned long)VERTS(a), (unsigned long)VERTS(b));
	append(bis, "gxburst_bisect.csv");
	state("E %s bisect 0", name);
	s_ended[fi][M_BISECT] = 1;
}

// ---- v5: geometry session's micro-mixes (docs/hw-reference.md "gxburst",
// v5). Each mix: the state set by polled CPU writes, then its body by DMA
// mode 7 packed 4 per word (as dma_packed4), timed to idle, 3 times, then a
// SWAP. Positions are on screen and unclipped unless stated: a zigzag of
// 64-vertex groups, projection and position identity, both faces drawn.
#define MIX_CMDS 8192
#define MIX_PARS 40000
static u32 s_setup[256][2];
static int s_nsetup;
static void su(u8 c, u32 v) { s_setup[s_nsetup][0] = c; s_setup[s_nsetup][1] = v; s_nsetup++; }
static void emit(u8 c, int n, const u32* p)
{
	Cmd* cm = &s_cmd[s_ncmd++];
	cm->cmd = c;
	cm->np = n;
	cm->p = s_np;
	cm->off = 0;
	for (int i = 0; i < n; i++) s_par[s_np++] = p[i];
}
static void e0(u8 c) { emit(c, 0, NULL); }
static void e1(u8 c, u32 a) { emit(c, 1, &a); }
static void e2(u8 c, u32 a, u32 b) { u32 p[2] = { a, b }; emit(c, 2, p); }
static void e3(u8 c, u32 a, u32 b, u32 d) { u32 p[3] = { a, b, d }; emit(c, 3, p); }
static void ident(u8 c, int n, int cols)   // identity matrix of n parameters, `cols` per row
{
	u32 p[16];
	for (int i = 0; i < n; i++) p[i] = (i / cols == i % cols) ? 0x1000 : 0;
	emit(c, n, p);
}
#define FX(v) ((s32)((v) * 4096.0f))
static inline u32 xy16(s32 a, s32 b) { return (a & 0xFFFF) | ((u32)b << 16); }
static void vtx16(s32 x, s32 y, s32 z) { e2(0x23, xy16(x, y), z & 0xFFFF); }

// zigzag: group j (BEGIN) of 64, vertex k; quad order for QUADS lists
static void zz(int j, int k, s32* x, s32* y)
{
	*x = FX(-0.9f + (k >> 1) * 0.028f);
	*y = FX(-0.9f + j * 0.075f + (k & 1) * 0.05f);
}
static bool s_tri_same_winding;   // v7 mixes only: a_tri keeps run 30's vertex order
static int quad_order(int k) { static const u8 o[4] = { 0, 1, 3, 2 }; return (k & ~3) | o[k & 3]; }

enum { ATTR_BOTH = 0x001F00C0 };
#ifndef R_CULL_FACE
#define R_CULL_FACE (1u << 7)   // the face drawn in the v7 cull mixes (bit 7 front, bit 6 back)
#endif
static void base_setup(u32 attr, u32 teximage)
{
	s_nsetup = 0;
	su(0x10, 0); su(0x15, 0);       // projection identity
	su(0x10, 3); su(0x15, 0);       // texture identity
	su(0x10, 2); su(0x15, 0);       // position + vector identity
	su(0x60, 0xBFFF0000);           // VIEWPORT 0,0-255,191
	su(0x29, attr);
	su(0x2A, teximage);
	su(0x30, 0x7FFF | 0x4210u << 16);   // DIF_AMB
	su(0x31, 0);
	for (u32 l = 0; l < 4; l++) {
		su(0x32, (0x100u << 20) | (l << 30) | (0x3C0u << 10));   // LIGHT_VECTOR, roughly toward the viewer
		su(0x33, 0x7FFF | (l << 30));
	}
}

// A/C/D/F1 style strip list: groups of 64 vertices, `prim` (0 tri, 1 quad,
// 2 tri strip, 3 quad strip); attrs before each vertex: bit 0 COLOR, 1
// TEXCOORD, 2 NORMAL. pos: 0 zigzag, 2 left plane, 3 two planes, 4 off screen.
static void strips(int prim, int groups, int attrs, int pos, int scale_every)
{
	for (int j = 0; j < groups; j++) {
		e1(0x40, prim);
		for (int k = 0; k < 64 - (prim == 0); k++) {
			int kk = prim == 1 ? quad_order(k) : k;
			// v7: separate triangles from the zigzag alternate their winding;
			// swap the last two vertices of every other one so all face the same way
			if (s_tri_same_winding && prim == 0 && ((k / 3) & 1) && k % 3) kk = k % 3 == 1 ? k + 1 : k - 1;
			s32 x, y;
			zz(j, kk, &x, &y);
			if (pos == 2) { x = FX((kk & 1) ? -0.8f : -1.2f); y = FX(-0.9f + j * 0.15f + (kk >> 1) * 0.0045f); }
			if (pos == 3) { x = FX((kk & 1) ? -0.8f : -1.2f); y = FX(((kk % 3) ? -0.8f : -1.2f) + (kk >> 1) * 0.001f); }
			s32 z = 0;
			if (pos == 4) x += FX(2.5f);       // right of the screen
			if (pos == 5) z = FX(-1.5f);       // v7: beyond the near plane (z < -w)
			if (pos == 6) z = FX(1.5f);        // beyond the far plane
			if (pos == 7) x -= FX(2.5f);       // left
			if (pos == 8) y += FX(2.5f);       // top
			if (pos == 9) y -= FX(2.5f);       // bottom
			if (attrs & 1) e1(0x20, 0x7FFF ^ (k * 0x421));
			if (attrs & 2) e1(0x22, ((k << 4) & 0xFFFF) | (u32)(j << 4) << 16);
			if (attrs & 4) e1(0x21, ((k & 15) * 8) | (0u << 10) | ((u32)(-507 & 0x3FF) << 20));
			vtx16(x, y, z);
			if (scale_every && (k % scale_every) == scale_every - 1) e3(0x1B, 0x1000, 0x1000, 0x1000);
		}
		e0(0x41);
	}
}

// B: a tri strip in another vertex format; the first vertex of each group is VTX_16
static void strips_fmt(u8 fmt)
{
	for (int j = 0; j < 24; j++) {
		e1(0x40, 2);
		s32 px = 0, py = 0;
		for (int k = 0; k < 64; k++) {
			s32 x, y;
			zz(j, k, &x, &y);
			if (fmt == 0x24) {   // VTX_10: 4.6, on a 1/64 grid
				s32 a = (-58 + (k >> 1) * 2), b = (-58 + j * 5 + (k & 1) * 3);
				e1(0x24, (a & 0x3FF) | (b & 0x3FF) << 10 | 0u << 20);
				continue;
			}
			if (!k) vtx16(fmt == 0x27 ? 0 : x, fmt == 0x26 ? 0 : (fmt == 0x27 ? y : y), fmt == 0x26 ? y : (fmt == 0x27 ? x : 0));
			else if (fmt == 0x25) e1(0x25, xy16(x, y));
			else if (fmt == 0x26) e1(0x26, xy16(x, y));       // x, z (z shown as screen y by the matrix)
			else if (fmt == 0x27) e1(0x27, xy16(y, x));       // y, z (z shown as screen x)
			else if (fmt == 0x28) e1(0x28, ((x - px) & 0x3FF) | ((y - py) & 0x3FF) << 10);
			px = x; py = y;
		}
		e0(0x41);
	}
}

static u32 lcg = 12345;
static u32 rnd(u32 n) { lcg = lcg * 1103515245 + 12345; return (lcg >> 16) % n; }

typedef struct { const char* name; } MixInfo;
static const char* s_mix_name[] = {
	"a_tri", "a_quad", "a_tstrip", "a_qstrip",
	"b_vtx10", "b_vtxxy", "b_vtxxz", "b_vtxyz", "b_vtxdiff",
	"c_color", "c_texcoord", "c_texcoord_t1", "c_normal_l0", "c_normal_l1", "c_normal_l2", "c_normal_l4",
	"c_normal_t2", "c_col_tex_nrm_l1", "c_texcoord_t3",
	"d_culled", "d_clip1", "d_clip2", "d_offscreen",
	"e_restore", "e_pushpop", "e_scale", "e_trans", "e_mult43", "e_mult44", "e_mult33", "e_load43_pos",
	"e_load43_proj", "e_identity",
	"f_scale_every8", "f_quads_beginend", "f_nsmb_mix",
	// v7 (geometry session): rejection, r_<prim>_<case>_<attrs>
#define RMIX(p) "r_" p "_near_plain", "r_" p "_near_tn", "r_" p "_far_plain", "r_" p "_far_tn", "r_" p "_left_plain", \
	"r_" p "_left_tn", "r_" p "_right_plain", "r_" p "_right_tn", "r_" p "_top_plain", "r_" p "_top_tn", \
	"r_" p "_bottom_plain", "r_" p "_bottom_tn", "r_" p "_cull_plain", "r_" p "_cull_tn"
	RMIX("tstrip"), RMIX("tri"),
};
#define NMIX ((int)(sizeof s_mix_name / sizeof s_mix_name[0]))
static int mix_index(const char* m) { for (int i = 0; i < NMIX; i++) if (!strcmp(m, s_mix_name[i])) return i; return -1; }

static void gen_mix(int id)
{
	s_ncmd = 0;
	s_np = 0;
	const char* n = s_mix_name[id];
	u32 tex7 = 7u << 26;   // direct-colour format, so texcoords are live
	if (n[0] == 'a') { base_setup(ATTR_BOTH, 0); strips(id, 24, 0, 0, 0); }
	else if (n[0] == 'b') {
		static const u8 f[5] = { 0x24, 0x25, 0x26, 0x27, 0x28 };
		u8 fmt = f[id - 4];
		base_setup(ATTR_BOTH, 0);
		if (fmt == 0x26 || fmt == 0x27) {   // the matrix maps the format's two coordinates to the screen
			su(0x10, 2);
			u32 m[12] = { 0 };
			if (fmt == 0x26) { m[0] = 0x1000; m[7] = 0x1000; m[5] = 0x1000; }   // x->x, z->y, y->z
			else { m[6] = 0x1000; m[4] = 0x1000; m[2] = 0x1000; }             // z->x, y->y, x->z
			for (int i = 0; i < 12; i++) su(0x17, m[i]);
		}
		strips_fmt(fmt);
	} else if (n[0] == 'c') {
		int k = id - 9;
		static const u32 lights[10] = { 0, 0, 0, 0, 1, 3, 15, 0, 1, 0 };
		static const int attrs[10] = { 1, 2, 2, 4, 4, 4, 4, 4, 7, 2 };
		u32 tex = k == 1 || k == 8 ? tex7 : k == 2 ? tex7 | 1u << 30 : k == 7 ? tex7 | 2u << 30
		        : k == 9 ? tex7 | 3u << 30 : 0;   // v6: c_texcoord_t3, texcoord from the vertex (mode 3)
		base_setup(ATTR_BOTH | lights[k], tex);
		strips(2, 24, attrs[k], 0, 0);
	} else if (n[0] == 'd') {
		int k = id - 19;
		base_setup(k == 0 ? 0x001F0000 : ATTR_BOTH, 0);
		strips(2, 12, 0, k == 0 ? 0 : k + 1, 0);
	} else if (n[0] == 'e') {
		int k = id - 23;
		base_setup(ATTR_BOTH, 0);
		for (u32 i = 0; i < 8; i++) su(0x13, i);   // MTX_STORE 0-7 for RESTORE (mode 2)
		if (k == 7) su(0x10, 1);                  // LOAD_4x3 in position mode
		if (k == 8) su(0x10, 0);                  // and in projection mode
		for (int i = 0; i < 500; i++) {
			if (k == 0) e1(0x14, i & 7);
			else if (k == 1) { if (i & 1) e1(0x12, 1); else e0(0x11); }
			else if (k == 2) e3(0x1B, 0x1000, 0x1000, 0x1000);
			else if (k == 3) e3(0x1C, 0, 0, 0);
			else if (k == 4) ident(0x19, 12, 3);
			else if (k == 5) ident(0x18, 16, 4);
			else if (k == 6) ident(0x1A, 9, 3);
			else if (k == 7 || k == 8) ident(0x17, 12, 3);
			else e0(0x15);
		}
	} else if (n[0] == 'r') {   // v7: 24 groups of 64 (tstrip) or 63 (tri) vertices, all rejected or culled
		int r = id - mix_index("r_tstrip_near_plain");
		int prim = r < 14 ? 2 : 0, c = (r % 14) / 2, tn = r & 1;
		static const int pos[7] = { 5, 6, 7, 4, 8, 9, 0 };
		// cull: only front faces drawn (the zigzag strips face back: checked in melonDS, 0 polygons)
		u32 a = c == 6 ? (0x001F0000 | R_CULL_FACE) : ATTR_BOTH;
		base_setup(a | (tn ? 1 : 0), tn ? tex7 : 0);
		s_tri_same_winding = true;
		strips(prim, 24, tn ? 6 : 0, pos[c], 0);
		s_tri_same_winding = false;
	} else if (!strcmp(n, "f_scale_every8")) { base_setup(ATTR_BOTH, 0); strips(2, 24, 0, 0, 8); }
	else if (!strcmp(n, "f_quads_beginend")) {
		base_setup(ATTR_BOTH, 0);
		for (int j = 0; j < 24; j++)
			for (int q = 0; q < 16; q++) {
				e1(0x40, 1);
				for (int k = q * 4; k < q * 4 + 4; k++) { s32 x, y; zz(j, quad_order(k), &x, &y); vtx16(x, y, 0); }
				e0(0x41);
			}
	} else {   // f_nsmb_mix: run 28's NSMB histogram at a quarter, as strips of 6-7 vertices
		base_setup(ATTR_BOTH | 1, tex7);
		lcg = 12345;
		int verts = 0;
		for (int g = 0; verts < 1144; g++) {
			if (rnd(687) < 256) e1(0x14, rnd(8));
			if (rnd(687) < 232) e3(0x1B, 0x1000, 0x1000, 0x1000);
			e1(0x40, 2);
			int nv = 6 + (g & 1);
			s32 px = 0, py = 0;
			for (int k = 0; k < nv; k++, verts++) {
				s32 x, y;
				zz(g % 24, (g * 7 + k) & 63, &x, &y);
				e1(0x22, ((k << 4) & 0xFFFF) | (u32)(g << 4) << 16);
				if (rnd(4576) < 1114) e1(0x20, 0x7FFF ^ (k * 0x421));
				if (rnd(4576) < 831) e1(0x21, ((k & 15) * 8) | ((u32)(-507 & 0x3FF) << 20));
				u32 r = rnd(4576);
				if (!k || r < 1830) vtx16(x, y, 0);
				else if (r < 1830 + 1180) e1(0x26, xy16(x, 0));
				else if (r < 1830 + 1180 + 1010) e1(0x25, xy16(x, y));
				else {
					s32 dx = x - px, dy = y - py;
					dx = dx > 511 ? 511 : dx < -511 ? -511 : dx;
					dy = dy > 511 ? 511 : dy < -511 ? -511 : dy;
					e1(0x28, (dx & 0x3FF) | (dy & 0x3FF) << 10);
				}
				px = x; py = y;
			}
			e0(0x41);
		}
	}
}

static void run_mix(int id, Buf* mixcsv)
{
	gen_mix(id);
	u32 nent = 0;
	for (u32 i = 0; i < s_ncmd; i++) nent += s_cmd[i].np ? s_cmd[i].np : 1;
	for (int rep = 0; rep < 3; rep++) {
		gxp_reset_geometry();
		gxp_timeouts = 0;
		s_stuck = 0;
		for (int i = 0; i < s_nsetup; i++) gxp_put(s_setup[i][0], s_setup[i][1]);
		if (!gxp_wait_idle()) recover();
		u32 nw = pack(s_ncmd, 4);
		for (u32 i = nw; i < (nw + 7) / 8 * 8; i++) s_w[i] = 0;
		DC_FlushRange(s_w, nw * 4 + 32);
		wait_vcount(200);
		Res res;
		memset(&res, 0, sizeof res);
		ArmIrqState st = armIrqLockByPsr();
		sample(NULL, 0, &res);
		sample(s_w, nw, &res);
		armIrqUnlockByPsr(st);
		u32 rc = gxp_ramcount();
		gxp_swap(0);
		buf_printf(mixcsv, "%s,%d,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu\n", s_mix_name[id], rep, (unsigned long)s_ncmd,
		           (unsigned long)nw, (unsigned long)nent, (unsigned long)(rc & 0xFFF), (unsigned long)VERTS(rc),
		           (unsigned long)res.t_dma, (unsigned long)res.t_idle, (unsigned long)res.max_level,
		           (unsigned long)res.min_level, (unsigned long)(gxp_timeouts + s_stuck));
		if (s_wedged) return;
	}
}

// v5: only the feeds that ran clean on the DS; the CPU STM feeds wedge
// the DS engine (run 29) and the rest were measured. The micro-mixes follow.
static const int s_phase[][4] = {
	{ M_DMA4, -1, -1, -1 },
	{ M_CPU_POLLED, -1, -1, -1 },
	{ M_BISECT, -1, -1, -1 },
};

// v6 (geometry session: mkds is 12 % slower on the DS than the fitted
// census): the target flush by DMA (as dma_packed4) cut just before a BEGIN
// at about 1/8, 2/8 .. 8/8 of its entries (the strip before a BEGIN is
// complete, so no dangling vertex), 3 times each: gxburst_prefix.csv.
static void prefixes(int fi, Buf* pcsv)
{
	const char* name = s_names[fi];
	u32 total = 0;
	for (u32 i = 0; i < s_ncmd; i++) total += s_cmd[i].np ? s_cmd[i].np : 1;
	for (int part = 1; part <= 8; part++) {
		u32 want = total * part / 8, k = s_ncmd, ent = 0, cut_ent = total;
		if (part < 8) {
			u32 best = 0, best_ent = 0;
			for (u32 i = 0, e = 0; i < s_ncmd && e <= want; e += s_cmd[i].np ? s_cmd[i].np : 1, i++)
				if (s_cmd[i].cmd == 0x40) { best = i; best_ent = e; }
			k = best;
			cut_ent = best_ent;
		}
		(void)ent;
		for (int rep = 0; rep < 3; rep++) {
			Res res;
			s_stuck = 0;
			u32 rc = run_mode(M_DMA4, k, &res);
			buf_printf(pcsv, "%s,%d,%lu,%lu,%d,%lu,%lu,%lu,%lu\n", name, part, (unsigned long)k, (unsigned long)cut_ent, rep,
			           (unsigned long)(rc & 0xFFF), (unsigned long)VERTS(rc), (unsigned long)res.t_idle,
			           (unsigned long)(gxp_timeouts + s_stuck));
			if (s_wedged) return;
		}
		iprintf("\x1b[20;0H%-14.14s prefix %d/8   ", name, part);
	}
}

static bool pending(int fi, int m)
{
	if (s_unsafe[m] || s_ended[fi][m]) return false;
	if (m != M_BISECT) return true;
	int a = s_ended[fi][M_DMA4], b = s_ended[fi][M_CPU_POLLED];
	return a && b && a != b && !s_unsafe[M_DMA4] && !s_unsafe[M_CPU_POLLED];
}

int main(void)
{
	hw_init(VERSION " - GX DMA bursts");
	gxp_console_on_h();
	iprintf(VERSION " - GX DMA bursts\n\n");
	videoSetMode(MODE_0_3D);
	glInit();
	char* names[MAX_FILES];
	int n = 0;
	FILE* lf = fopen(REPLAY_DIR "/list.txt", "r");
	if (lf) {
		char line[64];
		while (n < MAX_FILES && fgets(line, sizeof line, lf)) {
			size_t l = strcspn(line, "\r\n");
			line[l] = 0;
			if (l > 4 && !strcasecmp(line + l - 4, ".gxb")) names[n++] = strdup(line);
		}
		fclose(lf);
	}
	s_nfiles = n;
	for (int i = 0; i < n; i++) s_names[i] = names[i];
	Buf csv = {0}, tl = {0}, modes = {0}, bis = {0};
	bool resume = load_state();
	if (!resume) {
		remove(HWREF_DIR "/gxburst_state.txt");
		remove(HWREF_DIR "/gxburst_progress.txt");
		state("V " VERSION);
		buf_printf(&csv, "file,commands,words,entries,polys,verts,t_dma,t_idle,max_level,iters,iters_ge240,timeouts\n");
		buf_printf(&tl, "file,t,level,dma\n");
		buf_printf(&modes, "file,mode,words,polys,verts,t_idle,max_level,min_level,timeouts\n");
		buf_printf(&bis, "file,cmd_index,cmd,gxb_offset,verts_dma_before,verts_polled_before,verts_dma_after,verts_polled_after\n");
		buf_write(&csv, "gxburst.csv");             // headers; rows are appended after each mode
		buf_write(&tl, "gxburst_tl.csv");
		buf_write(&modes, "gxburst_modes.csv");
		buf_write(&bis, "gxburst_bisect.csv");
	} else {
		iprintf("resuming; skipped as unsafe:");
		for (int m = 0; m <= M_N; m++) if (s_unsafe[m]) iprintf(" %s", mode_str(m));
		iprintf("\n");
		progress("resume");
	}
	// v6: only the prefix bisect (mkds, nsmb) and the new mix with its controls
	Buf pcsv = {0};
	if (!resume) {
		buf_printf(&pcsv, "file,part,cmds,entries,rep,polys,verts,t_idle,timeouts\n");
		buf_write(&pcsv, "gxburst_prefix.csv");
	}
	for (int fi = 0; fi < n && 0; fi++) {   // v7: the prefixes ran in run 32
		if (strcmp(names[fi], "mkds.gxb") && strcmp(names[fi], "nsmb.gxb")) continue;
		if (s_ended[fi][M_BISECT] || s_unsafe[M_BISECT]) continue;   // "bisect" slot = the prefix runs
		state("B %s bisect", names[fi]);
		progress("prefix %s", names[fi]);
		if (parse(names[fi], &csv)) prefixes(fi, &pcsv);
		append(&pcsv, "gxburst_prefix.csv");
		release();
		if (s_wedged) {
			iprintf("\x1b[20;0H3D engine stuck.\nTurn the DS off and on, then\nstart this again: it resumes.\n");
			hw_done();
		}
		state("E %s bisect 0", names[fi]);
	}
	for (unsigned p = 0; p < 0; p++)
		for (int fi = 0; fi < n; fi++) {
			bool any = false;
			for (int k = 0; k < 4 && s_phase[p][k] >= 0; k++) any |= pending(fi, s_phase[p][k]);
			if (!any) continue;
			progress("phase %u %s", p, names[fi]);
			if (!parse(names[fi], &csv)) { append(&csv, "gxburst.csv"); release(); continue; }
			for (int k = 0; k < 4 && s_phase[p][k] >= 0; k++) {
				int m = s_phase[p][k];
				if (!pending(fi, m)) continue;
				if (m == M_BISECT) bisect(fi, &bis);
				else run_one(fi, m, &csv, &tl, &modes);
			}
			release();
		}
	// v5: the micro-mixes
	s_cmd = malloc(MIX_CMDS * sizeof(Cmd));
	s_par = malloc(MIX_PARS * 4);
	s_w = malloc(MIX_PARS * 4 + 64);
	Buf mixcsv = {0};
	if (!resume) {
		buf_printf(&mixcsv, "mix,rep,commands,words,entries,polys,verts,t_dma,t_idle,max_level,min_level,timeouts\n");
		buf_write(&mixcsv, "gxmix.csv");
	}
	for (int id = 0; id < NMIX && s_cmd && s_par && s_w; id++) {
		if (s_mix_ended[id] || s_mix_unsafe[id]) continue;
		// v7: the rejection mixes, with a_tstrip and d_offscreen as controls
		bool want = s_mix_name[id][0] == 'r' || !strcmp(s_mix_name[id], "a_tstrip") || !strcmp(s_mix_name[id], "d_offscreen");
		if (!want) continue;
		state("B mix %s", s_mix_name[id]);
		progress("mix %s", s_mix_name[id]);
		iprintf("\x1b[20;0Hmix %-24s", s_mix_name[id]);
		run_mix(id, &mixcsv);
		append(&mixcsv, "gxmix.csv");
		if (s_wedged) {
			progress("  engine wedged in mix %s: stopping", s_mix_name[id]);
			iprintf("\x1b[20;0H3D engine stuck in %s.\nTurn the DS off and on, then\nstart this again: it resumes.\n", s_mix_name[id]);
			hw_done();
		}
		state("E mix %s 0", s_mix_name[id]);
	}
	release();
	state("DONE");
	progress("done");
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt " __DATE__ " " __TIME__ "\n%d files; target flush of each by DMA1 GX FIFO mode, packed 4 commands per word;"
	           " times in system cycles from the DMA start; t_dma has bit 0 set\n", VERSION, n);
	buf_write(&info, "gxburst_info.txt");
	hw_done();
}
