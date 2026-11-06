// NDS_Pocket hardware census hooks (tools/melonds-census).
// Every hook is optional; with no hooks installed melonDS behaves as upstream.

#ifndef MELONDS_CENSUS_H
#define MELONDS_CENSUS_H

#include "types.h"

namespace melonDS
{
class GPU3D;
class SPU;

namespace Census
{

enum Access : u32
{
    Code = 0,
    Read = 1,
    Write = 2,
};

// melonDS's flat VRAM copies that the renderers read from.
enum Space : u32
{
    BG = 0,         // engine A/B BG VRAM, byte offset
    OBJ = 1,        // engine A/B OBJ VRAM, byte offset
    OBJExtPal = 2,  // engine A/B OBJ extended palette, halfword index
    Texture = 3,    // 3D texture image slots, byte offset
    TexPal = 4,     // 3D texture palette slots, byte offset
};

struct Hooks
{
    // cpu: 0 = ARM9, 1 = ARM7. size in bits. Called before the access.
    void (*MemAccess)(int cpu, u32 kind, u32 addr, u32 size) = nullptr;
    // Cycles the CPU actually executed (halt skips are not counted).
    void (*Busy)(int cpu, u32 cycles) = nullptr;
    // Every geometry FIFO entry as it is executed.
    void (*GXCommand)(u8 cmd, u32 param) = nullptr;
    // SWAP_BUFFERS taking effect at VBlank, before the polygon RAM is reset.
    void (*Flush3D)(GPU3D& gpu3d) = nullptr;
    // A DMA transfer starting (not resuming). bytes is the full length.
    void (*DMAStart)(int cpu, u32 num, u32 mode, u32 src, u32 dst, u32 bytes) = nullptr;
    // A cartridge ROM command with its transfer length.
    void (*CartCommand)(const u8* cmd, u32 len) = nullptr;
    // Start of every scanline (after VCount updates).
    void (*Scanline)(u32 line) = nullptr;

    // Renderer VRAM reads. unit: 0 = 2D engine A, 1 = 2D engine B, 2 = 3D.
    void (*VRAMRead)(int unit, u32 space, u32 offset, u32 bytes) = nullptr;
    // A 2D BG palette lookup; p points into either palette RAM or the BG
    // extended palette copy, so the census can tell which.
    void (*BGPalRead)(int engine, const void* p) = nullptr;
    // The soft renderer starts drawing visible 2D line `line` (both engines,
    // then display capture).
    void (*Line2D)(u32 line) = nullptr;
    // The 3D rasterizer starts line y; identical: melonDS skips rendering a
    // frame whose inputs did not change (called once per frame, before any
    // Line3D).
    void (*Frame3D)(bool identical) = nullptr;
    void (*Line3D)(s32 y) = nullptr;

    // Sound (SPU.cpp): register writes as the ARM7 makes them (size in bits),
    // POWCNT2, the start and end of every mixer step (end: the 16-bit output
    // pair), each 32-bit sample fetch with the value read, and each capture
    // word written.
    void (*SPUWrite)(u32 size, u32 addr, u32 val) = nullptr;
    void (*SPUPower)(u32 val) = nullptr;
    void (*SPUMix)(SPU& spu) = nullptr;
    void (*SPUMixEnd)(const s16* output) = nullptr;
    void (*SPUFetch)(u32 addr, u32 val) = nullptr;
    void (*SPUCapture)(u32 addr, u32 val) = nullptr;

    // Golden-model traces (ARM.cpp, CP15.cpp, DMA.cpp).
    // Retire: every interpreted instruction, including ones whose condition
    // failed, after it executed and before the IRQ check. pc is the
    // instruction's address; r is R[0..14] as seen in the current mode.
    void (*Retire)(int cpu, u32 pc, const u32* r, u32 cpsr) = nullptr;
    // A data write by the CPU (src 0, called on entry to DataWrite*, before
    // the MPU check) or by one of its DMA channels (src 1). bytes = 1, 2, 4;
    // addr as issued (not yet aligned).
    void (*DataWrite)(int cpu, u32 src, u32 addr, u32 val, u32 bytes) = nullptr;
    // An IRQ exception being taken (after the CPSR I-bit check).
    void (*IRQEntry)(int cpu) = nullptr;
};

extern Hooks* Active;

// Index wrappers for the renderers: report the read, return the index unchanged.
inline u32 VRAMIdx(int unit, u32 space, u32 offset, u32 bytes)
{
    if (Active && Active->VRAMRead) Active->VRAMRead(unit, space, offset, bytes);
    return offset;
}

inline u32 PalIdx(int engine, const u16* pal, u32 idx)
{
    if (Active && Active->BGPalRead) Active->BGPalRead(engine, &pal[idx]);
    return idx;
}

}
}

#define CENSUS_HOOK(name, ...) \
    do { if (melonDS::Census::Active && melonDS::Census::Active->name) \
        melonDS::Census::Active->name(__VA_ARGS__); } while (0)

#endif
