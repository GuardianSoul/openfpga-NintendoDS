// Seeded random 3D scenes (docs/hw-reference.md "rand3d"). Portable C with
// integer arithmetic only, so the DS program and the host tool
// (tools/hwref/rand3d_gx.c) produce the same command streams bit for bit.
#pragma once
#include <stdint.h>

#define R3D_VERSION 2
#define R3D_MAX_ENTS 6144

typedef struct { uint8_t cmd; uint32_t param; } R3dEnt;

typedef struct {
	uint32_t dispcnt, flushattr;
	uint8_t alpharef;
	uint16_t toon[32], edge[8];
	uint32_t fogcolor, fogoffset;
	uint8_t fog[32];
	uint32_t clear1, clear2;
} R3dRegs;

// Scene `idx`: render registers, the SWAP parameter (regs->flushattr) and
// the geometry entries, ending with SWAP_BUFFERS. The SWAP parameter applies
// to the polygons after a swap, so a player first sends the latch frame
// (r3d_latch) and a SWAP with regs->flushattr, then the entries. Returns the
// entry count.
int r3d_scene(uint32_t idx, R3dRegs* regs, R3dEnt* ents, int max);

// The latch frame before every scene: the stencil reset (a tiny translucent
// triangle, then a full-screen shadow-mask quad that passes the depth test),
// without the SWAP. Shadow polygons read the stencil buffer, which carries
// over from frame to frame, so without it a scene's picture depends on the
// scene before. R3D_LATCH_POLYS / _VERTS: its polygon and vertex counts.
#define R3D_LATCH_POLYS 2
#define R3D_LATCH_VERTS 7
int r3d_latch(R3dEnt* ents, int max);

// Texture slots 0-1 (VRAM A, B: 128 KiB each) and palette slots 0-3
// (VRAM E: 64 KiB), fixed for every scene.
void r3d_vram(uint8_t* a, uint8_t* b, uint8_t* e);
