// Replays a census GX trace (gx.bin, see census.cpp TraceVram) through
// melonDS's own geometry engine and writes one renderer-input scene
// (G3DSCN01, sim/gpu3d/scenes.cpp) per flush, for `Vgpu3d_raster --scene`.
//
//   gx2scene IN/gx.bin OUTDIR [--skip N=2] [--exact-vram] [--any]
//
// Every 'C' entry is executed in trace order by GPU3D::ExecuteCommand; at
// each 'F' the traced render registers are written back and GPU3D::VBlank()
// latches and Y-sorts the polygon list exactly as in the census run. The
// trace starts mid-frame without matrix state, so the first N flushes are
// skipped. Texture and palette VRAM come from the latest 'V' record (the
// census writes one every --vram-every flushes), rebuilt into melonDS's flat
// texture views from VRAMCNT and the raw banks. With --exact-vram only the
// flushes that carry their own 'V' record are written.
//
// Each replayed flush is checked against the polygon and vertex counts the
// census recorded; a mismatch means the replay lost state and is reported.

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "NDS.h"
#include "GPU.h"
#include "GPU3D.h"

using namespace melonDS;

namespace
{

struct Reader
{
    std::vector<u8> d;
    size_t i = 0;
    bool more() const { return i < d.size(); }
    template<typename T> T get() { T v; memcpy(&v, &d[i], sizeof v); i += sizeof v; return v; }
    void bytes(void* p, size_t n) { memcpy(p, &d[i], n); i += n; }
};

template<typename T> void put(FILE* f, const T& v) { fwrite(&v, sizeof v, 1, f); }

void LoadVram(GPU& gpu, const u8* cnt, Reader& r)
{
    for (u32 b = 0; b < 9; b++) gpu.VRAMCNT[b] = 0;   // force every Map call to remap
    for (u32 b = 0; b < 9; b++)
    {
        if (b < 2) gpu.MapVRAM_AB(b, cnt[b]);
        else if (b < 4) gpu.MapVRAM_CD(b, cnt[b]);
        else if (b == 4) gpu.MapVRAM_E(b, cnt[b]);
        else if (b < 7) gpu.MapVRAM_FG(b, cnt[b]);
        else if (b == 7) gpu.MapVRAM_H(b, cnt[b]);
        else gpu.MapVRAM_I(b, cnt[b]);
        r.bytes(gpu.VRAM[b], gpu.VRAMMask[b] + 1);
    }
    NonStupidBitField<512*1024/VRAMDirtyGranularity> tex;
    NonStupidBitField<128*1024/VRAMDirtyGranularity> pal;
    tex.SetRange(0, 512*1024/VRAMDirtyGranularity);
    pal.SetRange(0, 128*1024/VRAMDirtyGranularity);
    gpu.MakeVRAMFlat_TextureCoherent(tex);
    gpu.MakeVRAMFlat_TexPalCoherent(pal);
}

bool WriteScene(const std::string& path, GPU& gpu)
{
    GPU3D& g = gpu.GPU3D;
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) return false;
    fwrite("G3DSCN01", 8, 1, f);
    put(f, g.RenderDispCnt);
    put(f, (u32)g.RenderAlphaRef);
    put(f, g.RenderClearAttr1);
    put(f, g.RenderClearAttr2);
    put(f, g.RenderFogColor);
    put(f, g.RenderFogOffset / 0x200);
    fwrite(g.RenderToonTable, 2, 32, f);
    fwrite(g.RenderEdgeTable, 2, 8, f);
    fwrite(&g.RenderFogDensityTable[1], 1, 32, f);
    fwrite(gpu.VRAMFlat_Texture, 1, 512*1024, f);
    fwrite(gpu.VRAMFlat_TexPal, 1, 128*1024, f);
    put(f, g.RenderNumPolygons);
    for (u32 i = 0; i < g.RenderNumPolygons; i++)
    {
        const Polygon* p = g.RenderPolygonRAM[i];
        put(f, p->NumVertices); put(f, p->Attr); put(f, p->TexParam); put(f, p->TexPalette);
        put(f, (u8)p->FacingView); put(f, (u8)p->WBuffer);
        for (u32 j = 0; j < p->NumVertices; j++)
        {
            const Vertex* v = p->Vertices[j];
            put(f, v->FinalPosition[0]); put(f, v->FinalPosition[1]);
            put(f, p->FinalZ[j]); put(f, p->FinalW[j]);
            put(f, v->FinalColor[0]); put(f, v->FinalColor[1]); put(f, v->FinalColor[2]);
            put(f, v->TexCoords[0]); put(f, v->TexCoords[1]);
        }
    }
    fclose(f);
    return true;
}

}

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        fprintf(stderr, "usage: gx2scene gx.bin OUTDIR [--skip N=2] [--exact-vram]\n");
        return 1;
    }
    std::string out = argv[2];
    u32 skip = 2;
    bool exactVram = false, any = false;
    for (int a = 3; a < argc; a++)
    {
        if (!strcmp(argv[a], "--skip") && a + 1 < argc) skip = atoi(argv[++a]);
        else if (!strcmp(argv[a], "--exact-vram")) exactVram = true;
        else if (!strcmp(argv[a], "--any")) any = true;   // write mismatching flushes too (a trace from an older census)
    }

    Reader r;
    if (FILE* f = fopen(argv[1], "rb"))
    {
        fseek(f, 0, SEEK_END);
        r.d.resize(ftell(f));
        fseek(f, 0, SEEK_SET);
        if (fread(r.d.data(), 1, r.d.size(), f) != r.d.size()) return 1;
        fclose(f);
    }
    if (r.d.size() < 8 || memcmp(r.d.data(), "NDSGX001", 8)) { fprintf(stderr, "not a census GX trace\n"); return 1; }
    r.i = 8;
    if (system(("mkdir -p '" + out + "'").c_str()) != 0) return 1;

    NDS* nds = new NDS(NDSArgs{});
    nds->Reset();
    GPU& gpu = nds->GPU;
    GPU3D& g = gpu.GPU3D;
    g.SetEnabled(true, true);

    u32 flushes = 0, written = 0, mismatches = 0;
    bool haveVram = false;
    struct Pending { u32 frame, polys, verts, flushattr; std::string name; bool ok; } pend {};
    bool pending = false;
    auto finish = [&](bool vramHere)
    {
        if (!pending) return;
        pending = false;
        if (pend.ok && haveVram && (vramHere || !exactVram) && WriteScene(out + "/" + pend.name, gpu))
        {
            printf("%s frame %u polys %u verts %u%s\n", pend.name.c_str(), pend.frame, pend.polys, pend.verts,
                   vramHere ? " vram" : "");
            written++;
        }
    };

    while (r.more())
    {
        u8 t = r.get<u8>();
        if (t == 'C')
        {
            decltype(g.CmdPIPE.Peek()) e {};   // GPU3D::CmdFIFOEntry is private
            e.Command = r.get<u8>();
            e.Param = r.get<u32>();
            g.CmdPIPE.Write(e);
            g.ExecuteCommand();
        }
        else if (t == 'F')
        {
            finish(false);
            u32 frame = r.get<u32>(), np = r.get<u32>(), nv = r.get<u32>();
            g.DispCnt = r.get<u32>();
            u32 flushattr = r.get<u32>();
            g.AlphaRef = r.get<u8>();
            r.bytes(g.ToonTable, 64);
            r.bytes(g.EdgeTable, 16);
            g.FogColor = r.get<u32>();
            g.FogOffset = r.get<u32>();
            r.bytes(g.FogDensityTable, 32);
            g.ClearAttr1 = r.get<u32>();
            g.ClearAttr2 = r.get<u32>();

            u32 rp = g.NumPolygons, rv = g.NumVertices;
            bool match = g.FlushRequest && g.NumPolygons == np && g.NumVertices == nv && g.FlushAttributes == flushattr;
            g.FlushRequest = 1;
            g.FlushAttributes = flushattr;
            g.VBlank();
            u32 n = flushes++;
            if (n < skip) continue;
            if (!match)
            {
                mismatches++;
                fprintf(stderr, "flush %u frame %u: replay %u polys %u verts, census %u polys %u verts\n",
                        n, frame, rp, rv, np, nv);
            }
            char name[64];
            snprintf(name, sizeof name, "f%05u.scn", frame);
            pend = {frame, np, nv, flushattr, name, match || any};
            pending = true;
        }
        else if (t == 'V')
        {
            r.get<u32>();
            u8 cnt[9];
            r.bytes(cnt, 9);
            LoadVram(gpu, cnt, r);
            haveVram = true;
            finish(true);
        }
        else
        {
            fprintf(stderr, "bad record 0x%02X at %zu\n", t, r.i - 1);
            return 1;
        }
    }
    finish(false);
    printf("%u flushes, %u skipped, %u count mismatches, %u scenes written\n",
           flushes, std::min(flushes, skip), mismatches, written);
    return mismatches ? 2 : 0;
}
