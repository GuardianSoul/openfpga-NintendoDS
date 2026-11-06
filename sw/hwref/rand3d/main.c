// Random-stimulus 3D corpus (docs/hw-reference.md "rand3d"): renders seeded
// random scenes (gen.c) and captures each one, 3D only. Scene i's seed is i,
// so melonDS (the same ROM) and the RTL (tools/hwref/rand3d_gx.c writes
// the same scenes as a census GX trace) render identical input.
//
// Per scene: the latch frame (gen.c r3d_latch: the stencil reset) and its
// SWAP latch the scene's SWAP parameter, the render registers are set, the geometry goes out, and its SWAP starts a capture
// of the next frame. Two frames per scene. Captures are run-length coded
// (tools/hwref/rand3d.py) and written in ~1 MiB files. The run stops
// after R3D_BUDGET seconds or R3D_SCENES scenes, whichever comes first.
#include "../common/gxplay.h"
#include "gen.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VERSION "rand3d 1"
#ifndef R3D_SCENES
#define R3D_SCENES 4096
#endif
#ifndef R3D_FIRST   // first scene: a later start checks that scenes are independent
#define R3D_FIRST 0
#endif
#ifndef R3D_BUDGET
#define R3D_BUDGET 200
#endif
#define CAP_BANK 2              // VRAM C
#define CHUNK (1024 * 1024)
#define REC_MAX (12 + 2 * (256 * 192 + 256 * 192 / 32768 * 2 + 4))

// On the heap while rand3d runs: as static data they'd shrink the heap for
// sndcap in hwref.nds, whose v2 text buffers then ran out (run 15).
static R3dEnt* s_ents;
static R3dEnt s_latch[64];
static int s_nlatch;
static u16* s_cap;

// Runs of 3+ equal pixels: 0x8000 | (n - 1), value. Literals: n - 1, then
// n values. n <= 32768.
static int rle(const u16* p, int n, u16* out)
{
	int o = 0, i = 0;
	while (i < n) {
		int j = i + 1;
		while (j < n && p[j] == p[i] && j - i < 32768) j++;
		if (j - i >= 3) { out[o++] = 0x8000 | (j - i - 1); out[o++] = p[i]; i = j; continue; }
		int s = i;
		while (i < n && i - s < 32768) {
			if (i + 2 < n && p[i] == p[i + 1] && p[i] == p[i + 2]) break;
			i++;
		}
		out[o++] = i - s - 1;
		memcpy(out + o, p + s, (i - s) * 2);
		o += i - s;
	}
	return o;
}

static void wr32(u8* p, u32 v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

static u8* s_out;
static size_t s_outlen;
static int s_files;

static void flush_out(void)
{
	if (!s_outlen) return;
	char fn[32];
	snprintf(fn, sizeof fn, "rand3d_%03d.bin", s_files++);
	hw_write(fn, s_out, s_outlen);
	s_outlen = 0;
}

static int add_capture(u32 idx)
{
	if (s_outlen + REC_MAX > CHUNK) flush_out();
	u8* rec = s_out + s_outlen;
	int n = rle(s_cap, 256 * 192, (u16*)(rec + 12));
	memcpy(rec, "R3DC", 4);
	wr32(rec + 4, idx);
	wr32(rec + 8, n * 2);
	s_outlen += 12 + n * 2;
	return n * 2;
}

// Codes s_cap as scene `scene` and logs it.
static void log_scene(Buf* csv, u32 scene, u32 rc, int n, u32 gxstat)
{
	int bytes = add_capture(scene);
	buf_printf(csv, "%lu,%lu,%lu,%d,%08lx,%d\n", (unsigned long)scene, (unsigned long)(rc & 0xFFF),
	           (unsigned long)((rc >> 16) & 0x1FFF), n, (unsigned long)gxstat, bytes);
}

static void set_regs(const R3dRegs* g)
{
	GxpRegs r;
	r.dispcnt = g->dispcnt; r.flushattr = g->flushattr; r.alpharef = g->alpharef;
	memcpy(r.toon, g->toon, sizeof r.toon);
	memcpy(r.edge, g->edge, sizeof r.edge);
	r.fogcolor = g->fogcolor; r.fogoffset = g->fogoffset;
	memcpy(r.fog, g->fog, sizeof r.fog);
	r.clear1 = g->clear1; r.clear2 = g->clear2;
	gxp_set_regs(&r);
}

static void copy_bank(u32 lcdc, const u8* src, u32 len)
{
	vu32* d = (vu32*)lcdc;
	const u32* s = (const u32*)src;
	for (u32 i = 0; i < len / 4; i++) d[i] = s[i];
}

int main(void)
{
	hw_init(VERSION " - random 3D scenes");
	gxp_console_on_h();
	iprintf(VERSION " - random 3D scenes\n\n");
	videoSetMode(MODE_0_3D);
	glInit();
	gxp_reset_geometry();

	u8* a = malloc(0x20000), *b = malloc(0x20000), *e = malloc(0x10000);
	s_out = malloc(CHUNK);
	s_ents = malloc(R3D_MAX_ENTS * sizeof *s_ents);
	s_cap = malloc(256 * 192 * 2);
	if (!a || !b || !e || !s_out || !s_ents || !s_cap) {
		free(a); free(b); free(e); free(s_out); free(s_ents); free(s_cap);
		Buf info = {0};
		buf_printf(&info, "%s\nOUT OF MEMORY\n", VERSION);
		buf_write(&info, "rand3d_info.txt");
		iprintf("OUT OF MEMORY\n");
		hw_done();
	}
	r3d_vram(a, b, e);
	R_VRAMCNT(0) = 0x80; R_VRAMCNT(1) = 0x80; R_VRAMCNT(4) = 0x80;
	copy_bank(0x06800000, a, 0x20000);
	copy_bank(0x06820000, b, 0x20000);
	copy_bank(0x06880000, e, 0x10000);
	free(a); free(b); free(e);
	R_VRAMCNT(0) = 0x83;   // A: texture slot 0
	R_VRAMCNT(1) = 0x8B;   // B: texture slot 1
	R_VRAMCNT(2) = 0x80;   // C: LCDC, capture
	R_VRAMCNT(3) = 0x00;
	R_VRAMCNT(4) = 0x83;   // E: texture palette slots 0-3
	R_VRAMCNT(5) = 0x00;   // F, G off: an earlier program (replay3d) may have
	R_VRAMCNT(6) = 0x00;   // mapped them over palette slots 0-1

	Buf csv = {0};
	buf_printf(&csv, "scene,polys,verts,entries,gxstat,rle_bytes\n");
	s_nlatch = r3d_latch(s_latch, 64);
	u64 elapsed = 0;
	u32 t0 = now32();
	u32 done = 0;
	// Scene k's capture is copied out in the VBlank of scene k+1's latch, and
	// coded while scene k+1's capture runs, keeping two frames per scene.
	typedef struct { u32 scene, rc, gxstat; int n; } Info;
	Info cur = {0}, pend = {0};
	bool have = false;
	R3dRegs g;
	while (done < R3D_SCENES && elapsed < (u64)R3D_BUDGET * 33513982u && !gxp_timeouts) {
		int n = r3d_scene(R3D_FIRST + done, &g, s_ents, R3D_MAX_ENTS);
		for (int i = 0; i < s_nlatch; i++) gxp_put(s_latch[i].cmd, s_latch[i].param);
		gxp_swap(g.flushattr);   // latch; also the VBlank that ends the last capture
		if (done) { gxp_capture_finish(CAP_BANK, s_cap); pend = cur; have = true; }
		set_regs(&g);
		for (int i = 0; i < n - 1; i++) gxp_put(s_ents[i].cmd, s_ents[i].param);
		gxp_wait_idle();
		cur.scene = R3D_FIRST + done;
		cur.rc = gxp_ramcount();
		cur.n = n;
		gxp_swap(s_ents[n - 1].param);
		gxp_capture_start(CAP_BANK);
		cur.gxstat = R_GXSTAT;
		if (have) log_scene(&csv, pend.scene, pend.rc, pend.n, pend.gxstat);
		have = false;
		done++;
		u32 t = now32();
		elapsed += t - t0;
		t0 = t;
		if (done % 64 == 0) iprintf("\x1b[4;0Hscene %lu, %lus  ", (unsigned long)done, (unsigned long)(elapsed / 33513982u));
	}
	if (done) {
		gxp_capture_finish(CAP_BANK, s_cap);
		log_scene(&csv, cur.scene, cur.rc, cur.n, cur.gxstat);
	}
	flush_out();
	buf_write(&csv, "rand3d_scenes.csv");

	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\ngenerator version %d\n", VERSION, __DATE__, __TIME__, R3D_VERSION);
	buf_printf(&info, "scenes %lu (limit %d, budget %d s), seconds %lu, files %d, timeouts %lu\n",
	           (unsigned long)done, R3D_SCENES, R3D_BUDGET, (unsigned long)(elapsed / 33513982u), s_files,
	           (unsigned long)gxp_timeouts);
	buf_printf(&info, "format: records 'R3DC' u32 scene u32 bytes, then 256x192 u16 RLE (tools/hwref/rand3d.py)\n");
	buf_write(&info, "rand3d_info.txt");
	iprintf("\x1b[4;0Hscene %lu done      \n", (unsigned long)done);
	free(s_out);
	free(s_ents);
	free(s_cap);
	hw_done();
}
