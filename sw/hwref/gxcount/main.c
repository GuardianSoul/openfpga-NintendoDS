// Polygon and vertex RAM counts (docs/hw-reference.md "gxcount"): small
// vertex lists, each followed by a read of RAM_COUNT (0x4000604) and the
// RAM overflow flag (DISP3DCNT bit 13) before its SWAP. Geometry session's
// probes (run 15: the DS stores more vertices than melonDS).
//
// GBATEK ("Clipping") says clipped strip polygons are converted to separate
// polygons, adding vertices, and that polygons fully outside aren't stored,
// except ones exactly one pixel below or right of the lower/right edges.
// It doesn't say whether the polygon after a clipped one shares again, what
// a culled polygon in a strip does, or which RAM limit comes first.
//
// Projection and matrices are identity (w = 1): clip x/y in -1..1 is the
// screen, x = 1 the right edge. Quad strips once hung the DS in gxtime, so
// they run last, with a progress line before each probe.
#include "../common/gxplay.h"
#include <stdio.h>
#include <string.h>

#define VERSION "gxcount 3"
#define F1 4096

static void vtx(s32 x, s32 y) { gxp_put(0x23, ((u32)x & 0xFFFF) | ((u32)y << 16)); gxp_put(0x23, 0); }

// Strip vertex i: columns 0.3 apart from x = -0.9, top (y = 0.5) and bottom
// (y = -0.5) alternating. `mod` moves one vertex: kind 'R' to x = 1.5 (right
// of the screen), 'B' to y = -1.5 (below), 'F' 0.6 left (folds the strip
// so the polygons around it change facing), 'O' to y = -3 (with its two
// neighbours: polygons fully below).
typedef struct { char kind; int j; } Mod;

static void strip_vtx(int i, Mod m)
{
	s32 x = -F1 * 9 / 10 + (i / 2) * (F1 * 3 / 10), y = (i & 1) ? -F1 / 2 : F1 / 2;
	if (m.kind == 'R' && i == m.j) x = F1 * 3 / 2;
	if (m.kind == 'B' && i == m.j) y = -F1 * 3 / 2;
	if (m.kind == 'F' && i == m.j) x -= F1 * 6 / 10;
	if (m.kind == 'O' && i >= m.j - 1 && i <= m.j + 1) y = -3 * F1;
	// v2 (DS_RULE_STRIPCLIP): the first quad's left pair (vertices 0, 1)
	// outside the left plane, so it clips to exactly 4 vertices with the
	// shared pair (2, 3) original ('L'); only vertex 0 outside, a corner cut
	// giving 5 ('C'); both just inside, no clipping ('N').
	if (m.kind == 'L' && i <= 1) x = -F1 * 3 / 2;
	if (m.kind == 'C' && i == 0) x = -F1 * 3 / 2;
	if (m.kind == 'N' && i <= 1) x = -F1 + F1 / 64;
	// 'M' mirrors 'L': the second quad's far pair (4, 5) right of the screen,
	// so the current polygon clips to exactly 4 (the rule's other half)
	if (m.kind == 'M' && i >= 4) x = F1 * 3 / 2;
	vtx(x, y);
}

static u32 s_attr;
static void strip(int type, int nvert, Mod m)
{
	gxp_put(0x29, s_attr);
	gxp_put(0x40, type);
	for (int i = 0; i < nvert; i++) strip_vtx(i, m);
	gxp_put(0x41, 0);
}

static Mod s_mod;
static int s_n;
static void p_tristrip(void) { strip(2, 8, s_mod); }    // 6 triangles
static void p_quadstrip(void) { strip(3, 8, s_mod); }   // 3 quads
static void p_quadstrip2(void) { strip(3, 6, s_mod); }  // 2 quads

// Separate triangles near the right and bottom edges: dx/dy in 1/4096 of
// clip space past the edge (1/128 is one pixel in x, 1/96 in y).
static s32 s_dx;
static void p_tri_right(void)
{
	gxp_put(0x29, s_attr);
	gxp_put(0x40, 0);
	vtx(F1 + s_dx, F1 / 4); vtx(F1 + s_dx, -F1 / 4); vtx(F1 + s_dx + F1 / 8, 0);
	gxp_put(0x41, 0);
}
static void p_tri_below(void)
{
	gxp_put(0x29, s_attr);
	gxp_put(0x40, 0);
	vtx(-F1 / 4, -F1 - s_dx); vtx(F1 / 4, -F1 - s_dx); vtx(0, -F1 - s_dx - F1 / 8);
	gxp_put(0x41, 0);
}

// RAM limits: s_n separate triangles (small, on screen) or crossing the
// right edge (4 vertices each after clipping), or one triangle strip of s_n
// polygons, or a strip whose every polygon crosses the right edge.
static void p_tris(bool clipped)
{
	gxp_put(0x29, s_attr);
	gxp_put(0x40, 0);
	for (int i = 0; i < s_n; i++) {
		s32 y = -F1 + F1 / 8 + (i % 100) * (F1 / 64), x = clipped ? F1 - F1 / 16 : -F1 + (i / 100) * (F1 / 16);
		vtx(x, y); vtx(x, y - F1 / 32); vtx(x + F1 / 8, y);
	}
	gxp_put(0x41, 0);
}
static void p_tris_vis(void) { p_tris(false); }
static void p_tris_clip(void) { p_tris(true); }
static void p_strip_long(bool clipped)
{
	gxp_put(0x29, s_attr);
	gxp_put(0x40, 2);
	for (int i = 0; i < s_n + 2; i++) {
		s32 x = clipped ? ((i & 1) ? F1 * 3 / 2 : F1 / 2) : -F1 + (i % 256) * (F1 / 128);
		s32 y = clipped ? -F1 + (i % 384) * (F1 / 192) : ((i & 1) ? -F1 / 8 : F1 / 8);
		vtx(x, y);
	}
	gxp_put(0x41, 0);
}
static void p_strip_vis(void) { p_strip_long(false); }
static void p_strip_clip(void) { p_strip_long(true); }

#define BOTH  ((31u << 16) | (3u << 6))   // opaque, both faces

// v3 "wstrip" (geometry session, rand3d runs 15-21): the DS breaks some tri
// strip sharing where a polygon's largest W crosses 0x8000 against the
// previous polygon's. Projection w' = 2z, x' = 2x, y' = 2y, z' = 0 (no
// clipping), so a vertex at z = W/2 has clip W. The strip's vertices sit
// at W = 0x7C00 except one: the dropped vertex v0 ("down": the first
// polygon's max W is 0x8000 + step, the next polygon's is below) or the new
// vertex ("up"). Parity "e": the crossing is between polygons 0 and 1; "o":
// a leading polygon first, so between 1 and 2. History: none, or one
// separate triangle at W 0x9000 ("h") or 0x6000 ("l") just before BEGIN.
// melonDS shares throughout (strip of n vertices stores n).
static void wvtx(s32 ndcx, s32 ndcy, s32 w)   // ndc in 4.12, w in 4.12
{
	s32 z = w / 2;
	s32 x = (s32)((s64)ndcx * z / 0x1000), y = (s32)((s64)ndcy * z / 0x1000);
	gxp_put(0x23, ((u32)x & 0xFFFF) | ((u32)y << 16));
	gxp_put(0x23, (u32)z & 0xFFFF);
}

static void wstrip(bool up, bool odd, char hist, s32 step)
{
	static const s32 m[16] = { 0x2000,0,0,0, 0,0x2000,0,0, 0,0,0,0x2000, 0,0,0,0 };
	gxp_put(0x10, 0);
	for (int i = 0; i < 16; i++) gxp_put(0x16, m[i]);
	gxp_put(0x10, 2);
	gxp_put(0x29, BOTH);
	if (hist) {
		s32 hw = hist == 'h' ? 0x9000 : 0x6000;
		gxp_put(0x40, 0);
		wvtx(-0xC00, 0xC00, hw); wvtx(-0xC00, 0x800, hw); wvtx(-0x800, 0xC00, hw);
		gxp_put(0x41, 0);
	}
	const s32 lo = 0x7C00, hi = 0x8000 + step;
	gxp_put(0x40, 2);
	int n = 0;
	if (odd) { wvtx(-0x800, 0x400, lo); n++; }
	// polygon A = (a0, a1, a2), polygon B = (a1, a2, a3); A's max W is a0's
	// when down, B's max is a3's when up
	wvtx(-0x400, 0x400, up ? lo : hi);
	wvtx(-0x400, -0x400, lo);
	wvtx(0x400, 0x400, lo);
	wvtx(0x400, -0x400, up ? hi : lo);
	(void)n;
	gxp_put(0x41, 0);
}


#define FRONT ((31u << 16) | (1u << 7))   // opaque, front faces only

typedef struct { const char* name; void (*fn)(void); u32 attr; Mod mod; s32 dx; int n; } Probe;
static const Probe s_probes[] = {
	// (1)-(3) triangle strips of 6 polygons: plain, one vertex right of the
	// screen, below it, polygons fully outside, folded (front faces only
	// culls the folded ones; both faces as the control)
	{ "ts_plain",   p_tristrip, BOTH,  { 0 } },
	{ "ts_r0",      p_tristrip, BOTH,  { 'R', 0 } },
	{ "ts_r2",      p_tristrip, BOTH,  { 'R', 2 } },
	{ "ts_r3",      p_tristrip, BOTH,  { 'R', 3 } },
	{ "ts_r5",      p_tristrip, BOTH,  { 'R', 5 } },
	{ "ts_r7",      p_tristrip, BOTH,  { 'R', 7 } },
	{ "ts_b2",      p_tristrip, BOTH,  { 'B', 2 } },
	{ "ts_b5",      p_tristrip, BOTH,  { 'B', 5 } },
	{ "ts_out3",    p_tristrip, BOTH,  { 'O', 3 } },
	{ "ts_out4",    p_tristrip, BOTH,  { 'O', 4 } },
	{ "ts_fold4",   p_tristrip, BOTH,  { 'F', 4 } },
	{ "ts_fold4_f", p_tristrip, FRONT, { 'F', 4 } },
	{ "ts_plain_f", p_tristrip, FRONT, { 0 } },
	// GBATEK's "accidentally stored" polygons: separate triangles on the
	// right and bottom edges (x = w is pixel 256), then 1/4096, 1/2, 1 and 2
	// pixels past them
	{ "tri_right_on", p_tri_right, BOTH, { 0 }, 0 },
	{ "tri_right_0",  p_tri_right, BOTH, { 0 }, 1 },
	{ "tri_right_h",  p_tri_right, BOTH, { 0 }, 16 },
	{ "tri_right_1",  p_tri_right, BOTH, { 0 }, 32 },
	{ "tri_right_2",  p_tri_right, BOTH, { 0 }, 64 },
	{ "tri_below_on", p_tri_below, BOTH, { 0 }, 0 },
	{ "tri_below_0",  p_tri_below, BOTH, { 0 }, 1 },
	{ "tri_below_h",  p_tri_below, BOTH, { 0 }, 21 },
	{ "tri_below_1",  p_tri_below, BOTH, { 0 }, 43 },
	{ "tri_below_2",  p_tri_below, BOTH, { 0 }, 86 },
	// (6) RAM limits: 2,048 polygons, 6,144 vertices
	{ "lim_tris_2040",  p_tris_vis,   BOTH, { 0 }, 0, 2040 },
	{ "lim_tris_2048",  p_tris_vis,   BOTH, { 0 }, 0, 2048 },
	{ "lim_tris_2049",  p_tris_vis,   BOTH, { 0 }, 0, 2049 },
	{ "lim_clip_1530",  p_tris_clip,  BOTH, { 0 }, 0, 1530 },
	{ "lim_clip_1536",  p_tris_clip,  BOTH, { 0 }, 0, 1536 },
	{ "lim_clip_1537",  p_tris_clip,  BOTH, { 0 }, 0, 1537 },
	{ "lim_strip_2048", p_strip_vis,  BOTH, { 0 }, 0, 2048 },
	{ "lim_strip_2050", p_strip_vis,  BOTH, { 0 }, 0, 2050 },
	{ "lim_sclip_1500", p_strip_clip, BOTH, { 0 }, 0, 1500 },
	{ "lim_sclip_2048", p_strip_clip, BOTH, { 0 }, 0, 2048 },
	// (4)-(5) quad strips of 3 quads, last (they once hung the DS)
	{ "qs_plain",   p_quadstrip, BOTH,  { 0 } },
	{ "qs_r0",      p_quadstrip, BOTH,  { 'R', 0 } },
	{ "qs_r3",      p_quadstrip, BOTH,  { 'R', 3 } },
	{ "qs_r4",      p_quadstrip, BOTH,  { 'R', 4 } },
	{ "qs_r7",      p_quadstrip, BOTH,  { 'R', 7 } },
	{ "qs_b5",      p_quadstrip, BOTH,  { 'B', 5 } },
	{ "qs_out3",    p_quadstrip, BOTH,  { 'O', 3 } },
	{ "qs_fold4",   p_quadstrip, BOTH,  { 'F', 4 } },
	{ "qs_fold4_f", p_quadstrip, FRONT, { 'F', 4 } },
	// v2: does the DS share with or into a quad clipped to exactly 4
	// vertices? melonDS: 6 (shares), DS_RULE_STRIPCLIP: 8
	{ "qs2_clip4",  p_quadstrip2, BOTH, { 'L', 0 } },
	{ "qs2_clip4b", p_quadstrip2, BOTH, { 'M', 0 } },
	{ "qs2_clip5",  p_quadstrip2, BOTH, { 'C', 0 } },
	{ "qs2_inside", p_quadstrip2, BOTH, { 'N', 0 } },
	{ "qs2_plain",  p_quadstrip2, BOTH, { 0 } },
};
#define NPROBES (int)(sizeof s_probes / sizeof s_probes[0])

static void progress(const char* name)
{
	FILE* f = fopen(HWREF_DIR "/gxcount_progress.txt", "a");
	if (f) { fprintf(f, "start %s\n", name); fclose(f); }
}

int main(void)
{
	hw_init(VERSION " - polygon/vertex RAM counts");
	videoSetMode(MODE_0_3D);
	glInit();
	remove(HWREF_DIR "/gxcount_progress.txt");
	gxp_reset_geometry();
	gxp_put(0x60, 0 | (0 << 8) | (255u << 16) | (191u << 24));
	gxp_put(0x2A, 0);
	gxp_put(0x20, 0x7FFF);
	gxp_swap(0);

	Buf csv = {0};
	buf_printf(&csv, "probe,polys,verts,overflow,gxstat,timeouts\n");
	for (int i = 0; i < NPROBES && !gxp_timeouts; i++) {
		const Probe* p = &s_probes[i];
		iprintf("\x1b[4;0H%2d/%d %-16s", i + 1, NPROBES, p->name);
		progress(p->name);
		s_attr = p->attr; s_mod = p->mod; s_dx = p->dx; s_n = p->n;
		R_DISP3DCNT = (R_DISP3DCNT & 0x4FFF) | (1 << 13);   // ack the overflow flag
		p->fn();
		gxp_wait_idle();
		u32 rc = gxp_ramcount();
		u32 ovf = (R_DISP3DCNT >> 13) & 1;
		u32 st = R_GXSTAT;
		gxp_swap(0);
		buf_printf(&csv, "%s,%lu,%lu,%lu,%08lx,%lu\n", p->name, (unsigned long)(rc & 0xFFF),
		           (unsigned long)((rc >> 16) & 0x1FFF), (unsigned long)ovf, (unsigned long)st,
		           (unsigned long)gxp_timeouts);
	}
	static const s32 steps[10] = { -2048, -1024, -256, -64, -16, 16, 64, 256, 1024, 2048 };
	static const char hists[3] = { 0, 'h', 'l' };
	for (int v = 0; v < 2 * 2 * 3 * 10 && !gxp_timeouts; v++) {
		bool up = v / 60, odd = (v / 30) & 1;
		char hist = hists[(v / 10) % 3];
		s32 st = steps[v % 10];
		char name[32];
		snprintf(name, sizeof name, "ws_%s_%c_%c_%ld", up ? "up" : "down", odd ? 'o' : 'e', hist ? hist : 'n', (long)st);
		if (v % 10 == 0) progress(name);
		R_DISP3DCNT = (R_DISP3DCNT & 0x4FFF) | (1 << 13);
		wstrip(up, odd, hist, st);
		gxp_wait_idle();
		u32 rc = gxp_ramcount();
		u32 ovf = (R_DISP3DCNT >> 13) & 1;
		u32 gst = R_GXSTAT;
		gxp_swap(0);
		buf_printf(&csv, "%s,%lu,%lu,%lu,%08lx,%lu\n", name, (unsigned long)(rc & 0xFFF),
		           (unsigned long)((rc >> 16) & 0x1FFF), (unsigned long)ovf, (unsigned long)gst,
		           (unsigned long)gxp_timeouts);
	}
	if (gxp_timeouts) buf_printf(&csv, "# stopped: geometry engine timeout\n");
	buf_write(&csv, "gxcount.csv");
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\nidentity matrices (w = 1); counts read before each SWAP; overflow = DISP3DCNT bit 13\n",
	           VERSION, __DATE__, __TIME__);
	buf_write(&info, "gxcount_info.txt");
	hw_done();
}
