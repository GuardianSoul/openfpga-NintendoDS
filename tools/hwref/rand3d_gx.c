// Writes the rand3d scenes (sw/hwref/rand3d/gen.c) as a census GX trace
// (gx.bin, tools/melonds-census/census.cpp), for gx2scene and so the RTL:
//
//   rand3d_gx OUT.gx.bin FIRST COUNT [rand3d_scenes.csv]
//   rand3d_gx --features FIRST COUNT    per-scene feature CSV on stdout
//
// One 'V' record (the fixed texture and palette banks, with the rand3d ROM's
// VRAMCNT), then per scene the latch frame (the stencil reset) with its
// SWAP and flush (frame 2 * scene) and the scene with its flush (frame 2 * scene + 1). gx2scene
// only writes a flush whose polygon and vertex counts match the trace, so
// the counts come from a rand3d_scenes.csv (the melonDS run of the ROM);
// without it they're 0 and only the latch flushes match.
// Build: tools/hwref/rand3d.py builds and runs this (cc, no dependencies).
#include "../../sw/hwref/rand3d/gen.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void put32(FILE* f, uint32_t v) { fwrite(&v, 4, 1, f); }   // little-endian host

static void flush(FILE* f, uint32_t frame, uint32_t polys, uint32_t verts, const R3dRegs* g)
{
	fputc('F', f);
	put32(f, frame); put32(f, polys); put32(f, verts);
	put32(f, g->dispcnt); put32(f, g->flushattr);
	fputc(g->alpharef, f);
	fwrite(g->toon, 2, 32, f);
	fwrite(g->edge, 2, 8, f);
	put32(f, g->fogcolor); put32(f, g->fogoffset);
	fwrite(g->fog, 1, 32, f);
	put32(f, g->clear1); put32(f, g->clear2);
}

static void cmd(FILE* f, uint8_t c, uint32_t p) { fputc('C', f); fputc(c, f); put32(f, p); }

// What each scene uses, for correlating mismatches with features offline.
static int features(uint32_t first, uint32_t count)
{
	static R3dEnt e[R3D_MAX_ENTS];
	printf("scene,dispcnt,flushattr,modes,formats,texgen,prims,vtxcmds,attrbits,translucent,wireframe,entries\n");
	for (uint32_t s = first; s < first + count; s++) {
		R3dRegs g;
		int n = r3d_scene(s, &g, e, R3D_MAX_ENTS);
		uint32_t modes = 0, fmts = 0, gen = 0, prims = 0, vtx = 0, bits = 0, transl = 0, wire = 0;
		for (int i = 0; i < n; i++) {
			uint32_t p = e[i].param;
			switch (e[i].cmd) {
			case 0x29: {
				modes |= 1u << ((p >> 4) & 3);
				bits |= p & 0xF800;
				uint32_t a = (p >> 16) & 31;
				if (a == 0) wire = 1; else if (a < 31) transl = 1;
				break;
			}
			case 0x2A: fmts |= 1u << ((p >> 26) & 7); gen |= 1u << (p >> 30); break;
			case 0x40: prims |= 1u << (p & 3); break;
			default: if (e[i].cmd >= 0x23 && e[i].cmd <= 0x28) vtx |= 1u << (e[i].cmd - 0x23);
			}
		}
		printf("%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%d\n", s, g.dispcnt, g.flushattr, modes, fmts, gen, prims, vtx,
		       bits, transl, wire, n);
	}
	return 0;
}

int main(int argc, char** argv)
{
	if (argc == 4 && !strcmp(argv[1], "--features"))
		return features(strtoul(argv[2], 0, 0), strtoul(argv[3], 0, 0));
	if (argc < 4) { fprintf(stderr, "usage: rand3d_gx OUT FIRST COUNT [scenes.csv]\n"); return 1; }
	uint32_t first = strtoul(argv[2], 0, 0), count = strtoul(argv[3], 0, 0);
	uint32_t* counts = calloc(2 * (first + count), 4);
	if (argc > 4) {
		FILE* c = fopen(argv[4], "r");
		if (!c) { perror(argv[4]); return 1; }
		char line[256];
		while (fgets(line, sizeof line, c)) {
			unsigned s, p, v;
			if (sscanf(line, "%u,%u,%u", &s, &p, &v) == 3 && s < first + count) { counts[2 * s] = p; counts[2 * s + 1] = v; }
		}
		fclose(c);
	}
	FILE* f = fopen(argv[1], "wb");
	if (!f) { perror(argv[1]); return 1; }
	fwrite("NDSGX001", 1, 8, f);
	static const uint32_t size[9] = { 0x20000, 0x20000, 0x20000, 0x20000, 0x10000, 0x4000, 0x4000, 0x8000, 0x4000 };
	static const uint8_t cnt[9] = { 0x83, 0x8B, 0x80, 0x00, 0x83, 0x00, 0x00, 0x00, 0x00 };
	static uint8_t bank[9][0x20000];
	r3d_vram(bank[0], bank[1], bank[4]);
	fputc('V', f);
	put32(f, 0);
	fwrite(cnt, 1, 9, f);
	for (int b = 0; b < 9; b++) fwrite(bank[b], 1, size[b], f);
	static R3dEnt e[R3D_MAX_ENTS], l[64];
	int nl = r3d_latch(l, 64);
	for (uint32_t s = first; s < first + count; s++) {
		R3dRegs g;
		int n = r3d_scene(s, &g, e, R3D_MAX_ENTS);
		for (int i = 0; i < nl; i++) cmd(f, l[i].cmd, l[i].param);
		cmd(f, 0x50, g.flushattr);
		flush(f, 2 * s, R3D_LATCH_POLYS, R3D_LATCH_VERTS, &g);
		for (int i = 0; i < n; i++) cmd(f, e[i].cmd, e[i].param);
		flush(f, 2 * s + 1, counts[2 * s], counts[2 * s + 1], &g);
	}
	fclose(f);
	return 0;
}
