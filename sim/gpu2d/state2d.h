// 2D engine harness (docs/2d-engine.md): the state one visible line is
// rendered from, shared by the census dump, the synthetic scenes, the
// melonDS golden model and the RTL testbench.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace g2d
{
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32; typedef uint64_t u64;
typedef int16_t s16; typedef int32_t s32;

// melonDS GPU2D fields at the start of a visible line (after
// UpdateRegistersPreDraw), as SoftRenderer2D reads them.
struct EngState
{
    u8  enabled, forced_blank, layer_enable, obj_enable;
    u32 dispcnt;
    u16 bgcnt[4], bgxpos[4], bgypos[4];
    s32 xref[2], yref[2];               // BGXRefInternal / BGYRefInternal
    s16 rota[2], rotc[2];
    u8  win0[4], win1[4], wincnt[4];
    u8  win0_active, win1_active;
    u8  bg_mosaic[2], obj_mosaic[2];
    u32 bg_mosaic_line, obj_mosaic_line;
    u16 blendcnt;
    u8  eva, evb, evy;
    u16 master_bright;                  // GPU::MasterBrightnessA/B
};

struct LineState
{
    u32 frame, line;
    EngState e[2];
    u32 capcnt;
    u8  cap_enable;                     // GPU::CaptureEnable
    u8  lcdc;                           // GPU::VRAMMap_LCDC bits for banks A-D
    u8  pad[2];
    u32 l3d[256];                       // 3D layer line (SoftRenderer::Output3D)
    u16 fifo[256];                      // GPU::DispFIFOBuffer
};

// melonDS's flat VRAM views (made coherent), palettes, OAM and banks A-D
struct Mem
{
    u8 palette[2048], oam[2048];
    u8 abg[512 * 1024], bbg[128 * 1024], aobj[256 * 1024], bobj[128 * 1024];
    u8 abgext[32 * 1024], bbgext[32 * 1024], aobjext[8 * 1024], bobjext[8 * 1024];
    u8 lcdc[4][128 * 1024];
};

// Region table for chunked dumps: each region is split into 16 KB chunks
// (smaller regions are one chunk).
struct Region { u32 off, size; };
inline std::vector<Region> mem_regions()
{
    Mem* m = nullptr;
    auto o = [&](const void* p) { return (u32)((const u8*)p - (const u8*)m); };
    return {
        {o(m->palette), 2048}, {o(m->oam), 2048},
        {o(m->abg), 512 * 1024}, {o(m->bbg), 128 * 1024}, {o(m->aobj), 256 * 1024}, {o(m->bobj), 128 * 1024},
        {o(m->abgext), 32 * 1024}, {o(m->bbgext), 32 * 1024}, {o(m->aobjext), 8 * 1024}, {o(m->bobjext), 8 * 1024},
        {o(m->lcdc[0]), 4 * 128 * 1024},
    };
}
constexpr u32 ChunkSize = 16 * 1024;

// One line's output: 18-bit colour per engine as melonDS keeps it before
// ExpandColor (r[5:0] g[13:8] b[21:16]), and capture writes.
struct CapWrite { u32 addr; u16 data; };   // addr = bank << 16 | halfword index
struct LineOut
{
    u32 px[2][256];
    std::vector<CapWrite> cap;
};

// A run of consecutive lines rendered from the same starting memory. Memory
// changes between lines are recorded as chunk updates applied before a line.
struct Chunk { u32 off; std::vector<u8> data; };
struct Step
{
    LineState st;
    std::vector<Chunk> mem;             // applied before this line
    bool have_ref = false;              // melonDS's own output for the line (dumps)
    u32 ref[2][256];
};
struct Segment
{
    std::string name;
    std::shared_ptr<Mem> mem0;          // memory before the first step
    std::vector<Step> steps;
};

// Dump file "G2DDUMP1": records
//   'S' name-len u32, name           start a segment (memory starts zeroed)
//   'C' off u32, len u32, data       memory chunk update before the next line
//   'L' LineState                    a line
//   'R' ref[2][256]                  melonDS's output for the last line
bool load_dump(const std::string& path, std::vector<Segment>& out);
}
