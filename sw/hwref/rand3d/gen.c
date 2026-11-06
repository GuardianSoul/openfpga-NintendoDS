// Seeded random 3D scenes: see gen.h. Every scene sets the whole geometry
// state it uses (matrices, lights, material, attributes), so scenes are
// independent of each other and of what ran before. Quad strips and the
// test commands are left out: quad strips and BOX_TEST inside a vertex list
// have locked up the DS (gxtime, docs/hw-reference.md).
#include "gen.h"

typedef struct { uint32_t s; } Rng;

static uint32_t next(Rng* r)   // splitmix32
{
	uint32_t z = (r->s += 0x9E3779B9u);
	z = (z ^ (z >> 16)) * 0x85EBCA6Bu;
	z = (z ^ (z >> 13)) * 0xC2B2AE35u;
	return z ^ (z >> 16);
}
static uint32_t rnd(Rng* r, uint32_t n) { return (uint32_t)(((uint64_t)next(r) * n) >> 32); }
static int32_t range(Rng* r, int32_t lo, int32_t hi) { return lo + (int32_t)rnd(r, (uint32_t)(hi - lo + 1)); }
static int pct(Rng* r, uint32_t p) { return rnd(r, 100) < p; }

typedef struct { R3dEnt* e; int n, max; } Out;

static void put(Out* o, uint8_t cmd, uint32_t param)
{
	if (o->n < o->max) { o->e[o->n].cmd = cmd; o->e[o->n].param = param; o->n++; }
}

#define F1 4096   // 1.0 in 4.12

static void load44(Out* o, const int32_t* m) { for (int i = 0; i < 16; i++) put(o, 0x16, (uint32_t)m[i]); }
static void load43(Out* o, const int32_t* m) { for (int i = 0; i < 12; i++) put(o, 0x17, (uint32_t)m[i]); }

static uint32_t s10(int32_t v) { return (uint32_t)v & 0x3FF; }
static uint32_t s16(int32_t v) { return (uint32_t)v & 0xFFFF; }

static void projection(Rng* r, Out* o, int* persp)
{
	int32_t m[16] = {0};
	*persp = pct(r, 75);
	if (*persp) {
		int64_t n = range(r, 205, 4096), f = n + range(r, 1 * F1, 40 * F1);
		m[0] = range(r, F1 * 3 / 4, 2 * F1);
		m[5] = range(r, F1 * 3 / 4, 2 * F1);
		m[10] = (int32_t)(-((f + n) * F1) / (f - n));
		m[11] = -F1;
		m[14] = (int32_t)(-(2 * f * n) / (f - n));
		if (pct(r, 15)) { m[8] = range(r, -F1 / 2, F1 / 2); m[9] = range(r, -F1 / 2, F1 / 2); }   // off-centre
	} else {
		m[0] = range(r, F1 / 4, F1 / 2);
		m[5] = range(r, F1 / 4, F1 / 2);
		m[10] = -range(r, F1 / 16, F1 / 4);
		m[12] = range(r, -F1 / 4, F1 / 4);
		m[13] = range(r, -F1 / 4, F1 / 4);
		m[14] = range(r, -F1 / 4, F1 / 4);
		m[15] = F1;
	}
	put(o, 0x10, 0);
	load44(o, m);
}

static void modelview(Rng* r, Out* o, int persp)
{
	int32_t m[12];
	for (int i = 0; i < 9; i++) m[i] = range(r, -F1, F1);
	if (pct(r, 75)) {   // mostly axis-aligned, less shear
		for (int i = 0; i < 9; i++) m[i] /= 4;
		m[0] += F1; m[4] += F1; m[8] += F1;
	}
	m[9] = range(r, -F1, F1);
	m[10] = range(r, -F1, F1);
	m[11] = persp ? -range(r, F1 * 3 / 2, 6 * F1) : range(r, -F1 / 2, F1 / 2);
	put(o, 0x10, 2);
	load43(o, m);
}

static uint32_t texparam(Rng* r)
{
	static const uint8_t bpp[8] = { 0, 8, 2, 4, 8, 2, 8, 16 };
	uint32_t fmt = 1 + rnd(r, 7);
	uint32_t ss = pct(r, 85) ? rnd(r, 5) : rnd(r, 8), ts = pct(r, 85) ? rnd(r, 5) : rnd(r, 8);
	uint32_t limit = fmt == 5 ? 0x20000 : 0x40000;   // 4x4: slot 0, index data in slot 1
	for (;;) {
		uint32_t bytes = ((8u << ss) * (8u << ts) * bpp[fmt]) / 8;
		if (bytes <= limit) {
			uint32_t addr = rnd(r, (limit - bytes) / 8 + 1);
			uint32_t p = addr | (rnd(r, 16) << 16) | (ss << 20) | (ts << 23) | (fmt << 26);
			if (pct(r, 30)) p |= 1u << 29;   // colour 0 transparent
			uint32_t gen = rnd(r, 10);
			p |= (uint32_t)(gen < 6 ? 0 : gen < 8 ? 1 : gen < 9 ? 2 : 3) << 30;
			return p;
		}
		if (ss > ts) ss--; else ts--;
	}
}

static uint32_t polyattr(Rng* r)
{
	uint32_t a = rnd(r, 16);   // lights
	uint32_t m = rnd(r, 20);
	a |= (m < 10 ? 0u : m < 13 ? 1u : m < 18 ? 2u : 3u) << 4;
	a |= (pct(r, 70) ? 3u : 1u + rnd(r, 3)) << 6;   // back / front
	if (pct(r, 30)) a |= 1u << 11;   // translucent depth update
	if (pct(r, 30)) a |= 1u << 12;   // far-plane intersecting
	if (pct(r, 30)) a |= 1u << 13;   // 1-dot
	if (pct(r, 15)) a |= 1u << 14;   // depth equal
	if (pct(r, 50)) a |= 1u << 15;   // fog
	uint32_t alpha = pct(r, 50) ? 31 : pct(r, 10) ? 0 : 1 + rnd(r, 30);
	a |= alpha << 16;
	a |= (pct(r, 50) ? rnd(r, 4) : rnd(r, 64)) << 24;
	return a;
}

// One vertex near centre (cx, cy, cz), within +-sz (4.12), in one of the
// six vertex formats. VTX_XY/XZ/YZ keep the previous vertex's other
// coordinate and VTX_DIFF moves it slightly, so those stay near too.
static void vertex(Rng* r, Out* o, const int32_t* c, int32_t sz, int first)
{
	int32_t x = c[0] + range(r, -sz, sz), y = c[1] + range(r, -sz, sz), z = c[2] + range(r, -sz, sz);
	uint32_t k = rnd(r, 100);
	if (k < 50 || first) { put(o, 0x23, s16(x) | (s16(y) << 16)); put(o, 0x23, s16(z)); }
	else if (k < 65) put(o, 0x24, s10(x >> 6) | (s10(y >> 6) << 10) | (s10(z >> 6) << 20));
	else if (k < 75) put(o, 0x25, s16(x) | (s16(y) << 16));
	else if (k < 83) put(o, 0x26, s16(x) | (s16(z) << 16));
	else if (k < 90) put(o, 0x27, s16(y) | (s16(z) << 16));
	else put(o, 0x28, s10(range(r, -512, 511)) | (s10(range(r, -512, 511)) << 10) | (s10(range(r, -512, 511)) << 20));
}

int r3d_scene(uint32_t idx, R3dRegs* g, R3dEnt* ents, int max)
{
	Rng rr = { idx * 0x632BE5ABu + 0x5EED0001u };
	Rng* r = &rr;
	Out o = { ents, 0, max };

	// ---- render registers
	uint32_t d = 0;
	if (pct(r, 90)) d |= 1;          // textures
	if (pct(r, 40)) d |= 2;          // highlight shading instead of toon
	if (pct(r, 25)) d |= 4;          // alpha test
	if (pct(r, 70)) d |= 8;          // alpha blending
	if (pct(r, 30)) d |= 16;         // anti-aliasing
	if (pct(r, 25)) d |= 32;         // edge marking
	if (pct(r, 30)) { d |= 128 | (rnd(r, 16) << 8); if (pct(r, 30)) d |= 64; }   // fog
	g->dispcnt = d;
	g->flushattr = (pct(r, 20) ? 1u : 0u) | (pct(r, 35) ? 2u : 0u);
	g->alpharef = (uint8_t)rnd(r, 16);
	for (int i = 0; i < 32; i++) g->toon[i] = (uint16_t)rnd(r, 0x8000);
	for (int i = 0; i < 8; i++) g->edge[i] = (uint16_t)rnd(r, 0x8000);
	g->fogcolor = rnd(r, 0x8000) | (rnd(r, 32) << 16);
	g->fogoffset = rnd(r, 0x8000);
	uint32_t f = 0;
	for (int i = 0; i < 32; i++) {
		if (pct(r, 20)) f = rnd(r, 128); else f += rnd(r, 9);
		if (f > 127) f = 127;
		g->fog[i] = (uint8_t)f;
	}
	uint32_t ca = pct(r, 40) ? 31 : pct(r, 40) ? 0 : rnd(r, 32);
	g->clear1 = rnd(r, 0x8000) | (ca << 16) | (rnd(r, 64) << 24);
	g->clear2 = pct(r, 60) ? 0x7FFF : pct(r, 80) ? 0x6000 + rnd(r, 0x2000) : rnd(r, 0x8000);   // a low clear depth hides everything

	// ---- geometry state
	int persp;
	projection(r, &o, &persp);
	put(&o, 0x10, 3);
	if (pct(r, 50)) put(&o, 0x15, 0);
	else { int32_t m[16]; for (int i = 0; i < 16; i++) m[i] = range(r, -4 * F1, 4 * F1); load44(&o, m); }
	modelview(r, &o, persp);
	for (uint32_t l = 0; l < 4; l++) {
		put(&o, 0x32, s10(range(r, -512, 511)) | (s10(range(r, -512, 511)) << 10) | (s10(range(r, -512, 511)) << 20) | (l << 30));
		put(&o, 0x33, rnd(r, 0x8000) | (l << 30));
	}
	put(&o, 0x30, next(r) & 0xFFFFFFFFu);
	put(&o, 0x31, next(r));
	if (pct(r, 30)) for (int i = 0; i < 32; i++) put(&o, 0x34, next(r));
	else for (uint32_t i = 0; i < 32; i++) put(&o, 0x34, (8 * i) * 0x01010101u + 0x03020100u * 2);   // ramp 0..255
	if (pct(r, 85)) put(&o, 0x60, 0 | (0 << 8) | (255u << 16) | (191u << 24));
	else {
		uint32_t x1 = rnd(r, 200), y1 = rnd(r, 150);
		put(&o, 0x60, x1 | (y1 << 8) | ((x1 + 1 + rnd(r, 255 - x1)) << 16) | ((y1 + 1 + rnd(r, 191 - y1)) << 24));
	}
	put(&o, 0x20, rnd(r, 0x8000));
	put(&o, 0x21, 0);
	put(&o, 0x22, 0);

	// ---- polygons
	int groups = 2 + (int)rnd(r, pct(r, 20) ? 24 : 10);
	for (int gi = 0; gi < groups && o.n < max - 300; gi++) {
		if (gi && pct(r, 50)) modelview(r, &o, persp);
		put(&o, 0x29, polyattr(r));
		put(&o, 0x2A, pct(r, 85) ? texparam(r) : 0);
		put(&o, 0x2B, rnd(r, 0xFF0));
		uint32_t type = rnd(r, 10) < 4 ? 0 : rnd(r, 2) ? 1 : 2;
		int prims = 1 + (int)rnd(r, 8);
		int verts = type == 0 ? 3 * prims : type == 1 ? 4 * prims : prims + 2;
		int32_t R = range(r, F1 / 2, F1 * 3 / 2);     // where the group's primitives sit
		int32_t sz = pct(r, 50) ? range(r, F1 / 16, F1 / 2) : range(r, F1 / 2, 2 * F1);   // how big they are
		int32_t c[3];
		int lit = pct(r, 50);
		int tcrange = pct(r, 70) ? 16 * 256 : 32767;
		put(&o, 0x40, type);
		for (int v = 0; v < verts; v++) {
			if (type != 2 ? v % (type == 0 ? 3 : 4) == 0 : v == 0)   // new centre per primitive (strips: one)
				for (int i = 0; i < 3; i++) c[i] = range(r, -R, R);
			if (pct(r, 70)) put(&o, 0x20, rnd(r, 0x8000));
			if (pct(r, lit ? 70 : 5)) put(&o, 0x21, s10(range(r, -512, 511)) | (s10(range(r, -512, 511)) << 10) | (s10(range(r, -512, 511)) << 20));
			if (pct(r, 80)) put(&o, 0x22, s16(range(r, -tcrange, tcrange)) | (s16(range(r, -tcrange, tcrange)) << 16));
			vertex(r, &o, c, sz, v == 0);
		}
		if (pct(r, 50)) put(&o, 0x41, 0);
	}
	put(&o, 0x50, g->flushattr);
	return o.n;
}

int r3d_latch(R3dEnt* ents, int max)
{
	static const int32_t id[16] = { F1, 0, 0, 0, 0, F1, 0, 0, 0, 0, F1, 0, 0, 0, 0, F1 };
	Out o = { ents, 0, max };
	put(&o, 0x10, 0);
	load44(&o, id);
	put(&o, 0x10, 3);
	put(&o, 0x15, 0);
	put(&o, 0x10, 2);
	put(&o, 0x15, 0);
	put(&o, 0x60, 0 | (0 << 8) | (255u << 16) | (191u << 24));
	put(&o, 0x2A, 0);
	put(&o, 0x20, 0x7FFF);
	// A translucent triangle near the top-left corner (polygon ID 63), so the
	// mask after it follows a non-mask polygon and clears the stencil.
	put(&o, 0x29, (3u << 6) | (16u << 16) | (63u << 24));
	put(&o, 0x40, 0);
	put(&o, 0x23, s16(-F1) | (s16(F1) << 16)); put(&o, 0x23, 0);
	put(&o, 0x23, s16(-F1 + F1 / 16) | (s16(F1) << 16)); put(&o, 0x23, 0);
	put(&o, 0x23, s16(-F1) | (s16(F1 - F1 / 16) << 16)); put(&o, 0x23, 0);
	// The full-screen shadow mask (ID 0) at depth near 0: it passes the depth
	// test everywhere, so it sets no stencil bits.
	put(&o, 0x29, (3u << 4) | (3u << 6) | (16u << 16));
	put(&o, 0x40, 1);
	int32_t z = -F1 + F1 / 64;
	put(&o, 0x23, s16(-F1) | (s16(-F1) << 16)); put(&o, 0x23, s16(z));
	put(&o, 0x23, s16(F1) | (s16(-F1) << 16)); put(&o, 0x23, s16(z));
	put(&o, 0x23, s16(F1) | (s16(F1) << 16)); put(&o, 0x23, s16(z));
	put(&o, 0x23, s16(-F1) | (s16(F1) << 16)); put(&o, 0x23, s16(z));
	return o.n;
}

void r3d_vram(uint8_t* a, uint8_t* b, uint8_t* e)
{
	Rng r = { 0x7E57DA7Au };
	for (uint32_t i = 0; i < 0x20000; i += 4) {
		uint32_t v = next(&r);
		a[i] = (uint8_t)v; a[i + 1] = (uint8_t)(v >> 8); a[i + 2] = (uint8_t)(v >> 16); a[i + 3] = (uint8_t)(v >> 24);
		v = next(&r);
		b[i] = (uint8_t)v; b[i + 1] = (uint8_t)(v >> 8); b[i + 2] = (uint8_t)(v >> 16); b[i + 3] = (uint8_t)(v >> 24);
	}
	// The first 64 KiB of slot 0 also read as a 256x128 direct-colour
	// texture whose texels encode their coordinates (R = s, G = t, B = high
	// bits), so texel addressing errors can be read off.
	for (uint32_t t = 0; t < 128; t++)
		for (uint32_t s = 0; s < 256; s++) {
			uint32_t c = 0x8000 | (s & 31) | ((t & 31) << 5) | ((((s >> 5) & 7) | (((t >> 5) & 3) << 3)) << 10);
			a[2 * (t * 256 + s)] = (uint8_t)c;
			a[2 * (t * 256 + s) + 1] = (uint8_t)(c >> 8);
		}
	for (uint32_t i = 0; i < 0x10000; i += 4) {
		uint32_t v = next(&r);
		e[i] = (uint8_t)v; e[i + 1] = (uint8_t)(v >> 8); e[i + 2] = (uint8_t)(v >> 16); e[i + 3] = (uint8_t)(v >> 24);
	}
}
