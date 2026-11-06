// A renderer-input scene: the latched 3D render registers, the flat
// texture/palette VRAM views and the sorted polygon list, i.e. exactly what
// melonDS's SoftRenderer3D::RenderFrame() reads. Both the golden model
// (golden.cpp, melonDS's GPU3D_Soft.cpp) and the RTL testbench consume it.
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace g3d
{

struct Vtx
{
    int x = 0, y = 0;          // FinalPosition: x 0..511, y 0..192
    uint32_t z = 0;            // FinalZ, 24 bits
    uint32_t w = 0x1000;       // FinalW, normalized to 16 bits, nonzero
    int r = 0, g = 0, b = 0;   // FinalColor, 9 bits each
    int16_t s = 0, t = 0;      // TexCoords, 12.4
};

struct Poly
{
    std::vector<Vtx> v;        // 3..10 vertices
    uint32_t attr = 0x001F0000;// POLYGON_ATTR (alpha 31, id 0)
    uint32_t texparam = 0;
    uint32_t texpal = 0;
    bool facing = true;        // FacingView
    bool wbuffer = false;      // SWAP_BUFFERS bit 1, latched per polygon
    // FinalW = 0 here comes from W normalization (a raw W far below the
    // polygon's largest), not a raw W of 0: not degenerate. Built-in scenes
    // only; scene files keep the FinalW == 0 -> degenerate approximation.
    bool w_shifted_out = false;
};

// Per-polygon values melonDS derives in GPU3D::SubmitPolygon.
struct PolyDerived
{
    unsigned vtop = 0, vbot = 0;
    int ytop = 0, ybot = 0, xtop = 0, xbot = 0;
    bool degenerate = false;
    bool shadow_mask = false, shadow = false, translucent = false;
};
PolyDerived derive(const Poly& p);

struct Scene
{
    std::string name;
    uint32_t dispcnt = 0;       // DISP3DCNT (fog shift in bits 8-11)
    uint32_t alpharef = 0;      // effective alpha-test reference (0 when off)
    uint32_t clear_attr1 = 0x3F000000;
    uint32_t clear_attr2 = 0x00007FFF;
    uint32_t fog_color = 0;
    uint32_t fog_offset = 0;    // FOG_OFFSET register (15 bits); renderer uses *0x200
    uint16_t toon[32] = {};
    uint16_t edge[8] = {};
    uint8_t fog_table[32] = {};
    std::vector<uint8_t> tex = std::vector<uint8_t>(512 * 1024);
    std::vector<uint8_t> pal = std::vector<uint8_t>(128 * 1024);
    std::vector<Poly> polys;    // render order (already Y-sorted)
};

// Output pixel as melonDS stores it: r | g<<8 | b<<16 | a<<24, 6/6/6/5 bits.
using Frame = std::vector<uint32_t>; // 256*192

Frame render_golden(const Scene& sc);
void golden_set_nolower(bool on);   // golden_hooks.py: no lower layer (FEAT_LOWER = 0)

std::vector<Scene> builtin_scenes();
Scene random_mix_scene(uint32_t seed);
bool save_scene(const Scene& sc, const std::string& path);
bool load_scene(Scene& sc, const std::string& path);

}
