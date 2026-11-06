// Geometry-stream playback and 3D-only capture, shared by rand3d and
// replay3d (docs/hw-reference.md "rand3d", "replay3d").
//
// Streams are census GX-trace entries (tools/melonds-census/census.cpp,
// gx.bin): one (command, parameter) per FIFO entry, written to the
// command's port. Render registers come from the trace's 'F' record.
#pragma once
#include "hwref.h"

// The 'F' record after its tag: frame, polys, verts, then the registers.
#define GXP_FREC_SIZE 149
typedef struct {
	u32 frame, polys, verts;
	u32 dispcnt, flushattr;
	u8 alpharef;
	u16 toon[32], edge[8];
	u32 fogcolor, fogoffset;
	u8 fog[32];
	u32 clear1, clear2;
} GxpRegs;

void gxp_parse_regs(GxpRegs* r, const u8* p);   // p = GXP_FREC_SIZE bytes
void gxp_set_regs(const GxpRegs* r);

bool gxp_valid_cmd(u8 cmd);   // a real geometry command (not 0x00-0x0F or unused)
// Writes one entry to its port, waiting (bounded) for room in the FIFO.
// Returns false, and sets gxp_timeouts, when the engine stopped draining.
bool gxp_put(u8 cmd, u32 param);
bool gxp_wait_idle(void);     // until GXSTAT busy clears (bounded)
// SWAP_BUFFERS with `attr`, then wait until the swap executed at VBlank.
bool gxp_swap(u32 attr);
extern u32 gxp_timeouts;

// Polygon count (bits 0-11) and vertex count (bits 16-28) of the list
// being built, read before its SWAP.
static inline u32 gxp_ramcount(void) { return REG32(0x04000604); }

// Matrix stacks back to level 0, every matrix identity and DISP_1DOT_DEPTH
// at its maximum, so playback starts from the state gx2scene's melonDS
// reset has.
void gxp_reset_geometry(void);

// Console on VRAM H (sub BG), leaving A-D free for textures and capture.
void gxp_console_on_h(void);

// One 256x192 3D-only capture into `bank` (0-3, mapped LCDC by the caller).
// Start it in the VBlank in which the frame's SWAP executed (right after
// gxp_swap): it then captures the first frame rendered from that list.
void gxp_capture_start(int bank);
bool gxp_capture_done(void);
void gxp_capture_finish(int bank, u16* dst);   // waits, then copies to dst
