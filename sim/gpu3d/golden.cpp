// Golden model: melonDS's software 3D renderer, compiled unmodified from
// references/melonDS/src/GPU3D_Soft.{h,cpp} against the shims in
// melonds_shim/ (the Makefile copies both files next to the shims so their
// quoted includes resolve to the shims).
#include <memory>
#include <cstring>
#include "GPU3D_Soft.h"
#include "scene.h"

namespace g3d
{

PolyDerived derive(const Poly& p)
{
    // GPU3D::SubmitPolygon, "determine bounds of the polygon"
    PolyDerived d;
    int ytop = 192, ybot = 0, xtop = 256, xbot = 0;
    for (unsigned i = 0; i < p.v.size(); i++)
    {
        Vtx v = p.v[i];
        v.x &= 0x1FF; v.y &= 0xFF;
        if (v.y < ytop) { xtop = v.x; ytop = v.y; d.vtop = i; }
        if (v.y > ybot || (v.y == ybot && v.x > xbot)) { xbot = v.x; ybot = v.y; d.vbot = i; }
        if (v.w == 0 && !p.w_shifted_out) d.degenerate = true;
    }
    d.ytop = ytop; d.ybot = ybot; d.xtop = xtop; d.xbot = xbot;
    if (ybot > 192) d.degenerate = true;
    if (p.v.size() < 3 || p.v.size() > 10) d.degenerate = true;
    unsigned texfmt = (p.texparam >> 26) & 7, alpha = (p.attr >> 16) & 31;
    d.translucent = (texfmt == 1 || texfmt == 6) || (alpha > 0 && alpha < 31);
    d.shadow_mask = (p.attr & 0x3F000030) == 0x00000030;
    d.shadow = (p.attr & 0x30) == 0x30 && !d.shadow_mask;
    return d;
}

}
namespace melonDS { extern bool g3d_sim_nolower; }
namespace g3d
{
void golden_set_nolower(bool on) { melonDS::g3d_sim_nolower = on; }

Frame render_golden(const Scene& sc)
{
    using namespace melonDS;
    auto gpu = std::make_unique<GPU>();
    auto gpu3d = std::make_unique<GPU3D>(*gpu);
    SoftRenderer parent;
    auto rend = std::make_unique<SoftRenderer3D>(*gpu3d, parent);
    rend->Reset();

    memcpy(gpu->VRAMFlat_Texture, sc.tex.data(), sizeof(gpu->VRAMFlat_Texture));
    memcpy(gpu->VRAMFlat_TexPal, sc.pal.data(), sizeof(gpu->VRAMFlat_TexPal));

    // GPU3D::VBlank latching
    gpu3d->RenderDispCnt = sc.dispcnt;
    gpu3d->RenderAlphaRef = sc.alpharef;
    gpu3d->RenderClearAttr1 = sc.clear_attr1;
    gpu3d->RenderClearAttr2 = sc.clear_attr2;
    gpu3d->RenderFogColor = sc.fog_color;
    gpu3d->RenderFogOffset = sc.fog_offset * 0x200;
    gpu3d->RenderFogShift = (sc.dispcnt >> 8) & 0xF;
    gpu3d->RenderFogDensityTable[0] = sc.fog_table[0];
    memcpy(&gpu3d->RenderFogDensityTable[1], sc.fog_table, 32);
    memcpy(gpu3d->RenderToonTable, sc.toon, sizeof(sc.toon));
    memcpy(gpu3d->RenderEdgeTable, sc.edge, sizeof(sc.edge));
    gpu3d->RenderFrameIdentical = false;

    std::vector<Vertex> verts(sc.polys.size() * 10);
    std::vector<melonDS::Polygon> polys(sc.polys.size());
    for (size_t i = 0; i < sc.polys.size(); i++)
    {
        const Poly& p = sc.polys[i];
        PolyDerived d = derive(p);
        melonDS::Polygon& mp = polys[i];
        memset(&mp, 0, sizeof(mp));
        mp.NumVertices = p.v.size() > 10 ? 10 : p.v.size();
        for (unsigned j = 0; j < mp.NumVertices; j++)
        {
            Vertex& v = verts[i * 10 + j];
            memset(&v, 0, sizeof(v));
            // as GPU3D::SubmitPolygon stores them, and as the RTL sees them
            v.FinalPosition[0] = p.v[j].x & 0x1FF;
            v.FinalPosition[1] = p.v[j].y & 0xFF;
            v.FinalColor[0] = p.v[j].r;
            v.FinalColor[1] = p.v[j].g;
            v.FinalColor[2] = p.v[j].b;
            v.TexCoords[0] = p.v[j].s;
            v.TexCoords[1] = p.v[j].t;
            v.Position[3] = p.v[j].w;
            mp.Vertices[j] = &v;
            mp.FinalZ[j] = p.v[j].z;
            mp.FinalW[j] = p.v[j].w;
        }
        mp.WBuffer = p.wbuffer;
        mp.Attr = p.attr;
        mp.TexParam = p.texparam;
        mp.TexPalette = p.texpal;
        mp.Degenerate = d.degenerate;
        mp.FacingView = p.facing;
        mp.Translucent = d.translucent;
        mp.IsShadowMask = d.shadow_mask;
        mp.IsShadow = d.shadow;
        mp.VTop = d.vtop; mp.VBottom = d.vbot;
        mp.YTop = d.ytop; mp.YBottom = d.ybot;
        mp.XTop = d.xtop; mp.XBottom = d.xbot;
        gpu3d->RenderPolygonRAM[i] = &mp;
    }
    gpu3d->RenderNumPolygons = sc.polys.size();

    rend->RenderFrame();

    Frame f(256 * 192);
    for (int y = 0; y < 192; y++)
        memcpy(&f[y * 256], rend->GetLine(y), 256 * 4);
    return f;
}

}
