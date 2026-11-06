// Budget-3D study (docs/budget-3d.md): renders scenes with melonDS's
// software renderer exactly (GPU3D_SoftE) and with architecture 3's
// approximations (GPU3D_SoftA, apx_flags / apx_prec), and compares.
//   approx_cmp [--flags F] [--prec P] [--dump DIR] scene.scn...
// One line per scene:
//   name diffpx pct maxerr meanerr big idchg alphachg
// diffpx: pixels whose colour or alpha differ; maxerr: largest channel
// difference (6-bit colour, 5-bit alpha); meanerr: mean of the largest
// channel difference over the differing pixels; big: differing pixels with
// an error above 2 (a different texel or palette entry rather than rounding);
// idchg: pixels whose top polygon ID changed (depth ties, coverage);
// alphachg: pixels with a different alpha.
// --dump DIR writes DIR/<name>.e.rgba and .a.rgba (256x192, r g b a bytes);
// --raw555 DIR writes .e.bin / .a.bin as the display capture stores them.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
#include "GPU3D_SoftE.h"
#include "GPU3D_SoftA.h"
#include "scene.h"

int apx_flags = 0;
int apx_prec = 16;
int apx_xshift = 8, apx_yshift = 9;
int apx_toonidx = 0;
static int vcol_mode = 0;   // hardware experiments on the 9-bit vertex colours (approximate copy only)
static bool in_a = false;
long apx_fixsteps = 0, apx_divs = 0;
int apx_fixmax = 0, apx_fixmin = 0;

namespace g3d
{
PolyDerived derive(const Poly& p)
{
    // as golden.cpp (GPU3D::SubmitPolygon's bounds)
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

using namespace g3d;

struct Out { std::vector<uint32_t> col, attr; };

template <class R>
static Out render(const Scene& sc)
{
    using namespace melonDS;
    auto gpu = std::make_unique<GPU>();
    auto gpu3d = std::make_unique<GPU3D>(*gpu);
    SoftRenderer parent;
    auto rend = std::make_unique<R>(*gpu3d, parent);
    rend->Reset();
    memcpy(gpu->VRAMFlat_Texture, sc.tex.data(), sizeof(gpu->VRAMFlat_Texture));
    memcpy(gpu->VRAMFlat_TexPal, sc.pal.data(), sizeof(gpu->VRAMFlat_TexPal));
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
            v.FinalPosition[0] = p.v[j].x & 0x1FF;
            v.FinalPosition[1] = p.v[j].y & 0xFF;
            v.FinalColor[0] = p.v[j].r; v.FinalColor[1] = p.v[j].g; v.FinalColor[2] = p.v[j].b;
            if (in_a && vcol_mode)
                for (int k = 0; k < 3; k++)
                {
                    int c = v.FinalColor[k];
                    switch (vcol_mode)
                    {
                    case 1: c &= ~15; break;                 // low bits clear
                    case 2: c |= 15; break;                  // low bits set
                    case 3: c = c > 7 ? c - 8 : 0; break;
                    case 4: c = c + 8 > 511 ? 511 : c + 8; break;
                    case 5: c = (c >> 4) << 4 | ((c >> 4) ? 8 : 0); break;
                    }
                    v.FinalColor[k] = c;
                }
            v.TexCoords[0] = p.v[j].s; v.TexCoords[1] = p.v[j].t;
            v.Position[3] = p.v[j].w;
            mp.Vertices[j] = &v;
            mp.FinalZ[j] = p.v[j].z;
            mp.FinalW[j] = p.v[j].w;
        }
        mp.WBuffer = p.wbuffer; mp.Attr = p.attr; mp.TexParam = p.texparam; mp.TexPalette = p.texpal;
        mp.Degenerate = d.degenerate; mp.FacingView = p.facing; mp.Translucent = d.translucent;
        mp.IsShadowMask = d.shadow_mask; mp.IsShadow = d.shadow;
        mp.VTop = d.vtop; mp.VBottom = d.vbot; mp.YTop = d.ytop; mp.YBottom = d.ybot;
        mp.XTop = d.xtop; mp.XBottom = d.xbot;
        gpu3d->RenderPolygonRAM[i] = &mp;
    }
    gpu3d->RenderNumPolygons = sc.polys.size();
    rend->RenderFrame();
    Out o;
    o.col.resize(256 * 192); o.attr.resize(256 * 192);
    for (int y = 0; y < 192; y++)
    {
        memcpy(&o.col[y * 256], rend->GetLine(y), 256 * 4);
        for (int x = 0; x < 256; x++)
            o.attr[y * 256 + x] = rend->AttrBuffer[R::FirstPixelOffset + y * R::ScanlineWidth + x];
    }
    return o;
}

// as the DS's display capture stores the 3D layer: RGB555 (6-bit >> 1) and
// bit 15 for alpha != 0, u16 little-endian
static void dump555(const std::string& path, const std::vector<uint32_t>& c)
{
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) return;
    for (uint32_t p : c)
    {
        uint16_t v = ((p >> 1) & 31) | (((p >> 9) & 31) << 5) | (((p >> 17) & 31) << 10) | (((p >> 24) & 31) ? 0x8000 : 0);
        fwrite(&v, 2, 1, f);
    }
    fclose(f);
}

static void dump(const std::string& path, const std::vector<uint32_t>& c)
{
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) return;
    for (uint32_t p : c)
    {
        // 6-bit colour and 5-bit alpha to 8 bits
        unsigned char px[4] = {
            (unsigned char)(((p >> 0) & 63) * 255 / 63), (unsigned char)(((p >> 8) & 63) * 255 / 63),
            (unsigned char)(((p >> 16) & 63) * 255 / 63), (unsigned char)(((p >> 24) & 31) * 255 / 31)};
        fwrite(px, 1, 4, f);
    }
    fclose(f);
}

int main(int argc, char** argv)
{
    std::string dumpdir, rawdir;
    std::vector<std::string> files;
    for (int i = 1; i < argc; i++)
    {
        if (!strcmp(argv[i], "--flags") && i + 1 < argc) apx_flags = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--prec") && i + 1 < argc) apx_prec = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--xshift") && i + 1 < argc) apx_xshift = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--vcol") && i + 1 < argc) vcol_mode = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--yshift") && i + 1 < argc) apx_yshift = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--dump") && i + 1 < argc) dumpdir = argv[++i];
        else if (!strcmp(argv[i], "--raw555") && i + 1 < argc) rawdir = argv[++i];
        else files.push_back(argv[i]);
    }
    for (const auto& fn : files)
    {
        Scene sc;
        if (!load_scene(sc, fn)) { fprintf(stderr, "cannot load %s\n", fn.c_str()); continue; }
        int fl = apx_flags;
        apx_flags = 0;
        Out e = render<melonDS::SoftRenderer3D>(sc);
        apx_flags = fl;
        in_a = true;
        Out a = render<melonDS::SoftRenderer3DA>(sc);
        in_a = false;
        long diff = 0, big = 0, idchg = 0, achg = 0;
        int maxerr = 0;
        double sumerr = 0;
        for (int i = 0; i < 256 * 192; i++)
        {
            uint32_t pe = e.col[i], pa = a.col[i];
            if (((e.attr[i] >> 24) & 0x3F) != ((a.attr[i] >> 24) & 0x3F)) idchg++;
            if (pe == pa) continue;
            diff++;
            int m = 0;
            for (int k = 0; k < 3; k++)
            {
                int d = abs(int((pe >> (8 * k)) & 63) - int((pa >> (8 * k)) & 63));
                if (d > m) m = d;
            }
            int da = abs(int((pe >> 24) & 31) - int((pa >> 24) & 31));
            if (da) achg++;
            if (da > m) m = da;
            if (m > maxerr) maxerr = m;
            sumerr += m;
            if (m > 2) big++;
        }
        std::string name = fn.substr(fn.find_last_of('/') + 1);
        printf("%s %ld %.3f %d %.2f %ld %ld %ld\n", name.c_str(), diff, 100.0 * diff / (256 * 192), maxerr,
               diff ? sumerr / diff : 0.0, big, idchg, achg);
        if (apx_flags & APX_FIX)
            fprintf(stderr, "%s divisions %ld corrected %ld steps %d..%d\n", name.c_str(), apx_divs, apx_fixsteps, apx_fixmin, apx_fixmax);
        if (!rawdir.empty())
        {
            dump555(rawdir + "/" + name + ".e.bin", e.col);
            dump555(rawdir + "/" + name + ".a.bin", a.col);
        }
        if (!dumpdir.empty())
        {
            dump(dumpdir + "/" + name + ".e.rgba", e.col);
            dump(dumpdir + "/" + name + ".a.rgba", a.col);
        }
    }
}
