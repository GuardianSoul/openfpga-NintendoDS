// Geometry-engine load of a census GX trace, measured on melonDS's own
// geometry engine (docs/geometry-engine.md, "Measured load").
//
//   gxstats IN/gx.bin [--skip N=2]
//
// Replays every 'C' entry back to back through GPU3D::ExecuteCommand (the
// FIFO never runs dry, the worst case for throughput) and reports per flush:
// melonDS's modelled cycles (CycleCount growth, 33.5 MHz system cycles),
// polygons submitted / accepted, polygons with clipped vertices, vertices
// written, and the command mix.

#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include <algorithm>

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
    void skip(size_t n) { i += n; }
};

struct Flush
{
    u64 cycles = 0, submitted = 0, accepted = 0, clipped = 0, verts = 0, entries = 0, lightcmds = 0, lights = 0;
};

u64 pct(std::vector<u64> v, double p)
{
    if (v.empty()) return 0;
    std::sort(v.begin(), v.end());
    size_t k = std::min(v.size() - 1, (size_t)(p * (v.size() - 1) + 0.5));
    return v[k];
}
}

int main(int argc, char** argv)
{
    if (argc < 2) { fprintf(stderr, "usage: gxstats gx.bin [--skip N]\n"); return 1; }
    u32 skip = 2;
    for (int a = 2; a < argc; a++)
        if (!strcmp(argv[a], "--skip") && a + 1 < argc) skip = atoi(argv[++a]);

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

    NDS* nds = new NDS(NDSArgs{});
    nds->Reset();
    GPU3D& g = nds->GPU.GPU3D;
    g.SetEnabled(true, true);

    std::vector<Flush> fl;
    Flush cur;
    std::map<u8, u64> mix;
    u32 nflush = 0;
    while (r.more())
    {
        u8 t = r.get<u8>();
        if (t == 'C')
        {
            decltype(g.CmdPIPE.Peek()) e {};
            e.Command = r.get<u8>();
            e.Param = r.get<u32>();
            u32 np = g.NumPolygons;
            u32 nv = g.NumVertices;
            bool vtx = (e.Command >= 0x23 && e.Command <= 0x28);
            u32 before = g.VertexNumInPoly, mode = g.PolygonMode;
            s32 c0 = g.CycleCount;
            g.CmdPIPE.Write(e);
            g.ExecuteCommand();
            if (e.Command != 0x50) cur.cycles += g.CycleCount - c0;
            else cur.cycles += 325;
            cur.entries++;
            mix[e.Command]++;
            if (e.Command == 0x21)
            {
                cur.lightcmds++;
                cur.lights += __builtin_popcount(g.CurPolygonAttr & 0xF);
            }
            // a vertex completed a polygon when VertexNumInPoly wrapped or a strip advanced
            if (vtx && (e.Command != 0x23 || g.ExecParamCount == 0))
            {
                bool done = (mode == 0 && before == 2) || (mode == 1 && before == 3) ||
                            (mode == 2 && before >= 2) || (mode == 3 && before == 3);
                if (done) cur.submitted++;
            }
            if (g.NumPolygons > np)
            {
                cur.accepted++;
                cur.verts += g.NumVertices - nv;
                Polygon* p = &g.CurPolygonRAM[np];
                for (u32 j = 0; j < p->NumVertices; j++)
                    if (p->Vertices[j]->Clipped) { cur.clipped++; break; }
            }
        }
        else if (t == 'F')
        {
            r.get<u32>(); r.get<u32>(); r.get<u32>();
            r.get<u32>();
            u32 flushattr = r.get<u32>();
            r.skip(1 + 64 + 16 + 4 + 4 + 32 + 4 + 4);
            g.FlushRequest = 1;
            g.FlushAttributes = flushattr;
            g.VBlank();
            if (nflush++ >= skip) fl.push_back(cur);
            cur = Flush();
        }
        else if (t == 'V')
        {
            r.get<u32>();
            u8 cnt[9];
            memcpy(cnt, &r.d[r.i], 9);
            r.skip(9);
            static const u32 sz[9] = {128, 128, 128, 128, 64, 16, 16, 32, 16};
            for (int b = 0; b < 9; b++) r.skip(sz[b] * 1024);
        }
        else { fprintf(stderr, "bad record\n"); return 1; }
    }

    std::vector<u64> cyc, sub, acc, clp, ver, ent, lc, perpoly;
    Flush tot;
    for (auto& f : fl)
    {
        cyc.push_back(f.cycles); sub.push_back(f.submitted); acc.push_back(f.accepted);
        clp.push_back(f.clipped); ver.push_back(f.verts); ent.push_back(f.entries); lc.push_back(f.lightcmds);
        if (f.submitted) perpoly.push_back(f.cycles / f.submitted);
        tot.cycles += f.cycles; tot.submitted += f.submitted; tot.accepted += f.accepted;
        tot.clipped += f.clipped; tot.verts += f.verts; tot.entries += f.entries;
        tot.lightcmds += f.lightcmds; tot.lights += f.lights;
    }
    printf("%zu flushes\n", fl.size());
    printf("model cycles/flush p50 %llu p99 %llu max %llu\n", (unsigned long long)pct(cyc, .5), (unsigned long long)pct(cyc, .99), (unsigned long long)pct(cyc, 1));
    printf("submitted/flush p50 %llu max %llu; accepted p50 %llu max %llu; clipped max %llu; verts max %llu; entries max %llu; normals max %llu\n",
           (unsigned long long)pct(sub, .5), (unsigned long long)pct(sub, 1), (unsigned long long)pct(acc, .5), (unsigned long long)pct(acc, 1),
           (unsigned long long)pct(clp, 1), (unsigned long long)pct(ver, 1), (unsigned long long)pct(ent, 1), (unsigned long long)pct(lc, 1));
    printf("totals: cycles %llu submitted %llu accepted %llu (%.1f%%) clipped %llu (%.1f%% of accepted) verts %llu normals %llu avg lights %.2f\n",
           (unsigned long long)tot.cycles, (unsigned long long)tot.submitted, (unsigned long long)tot.accepted,
           100.0 * tot.accepted / std::max<u64>(1, tot.submitted), (unsigned long long)tot.clipped,
           100.0 * tot.clipped / std::max<u64>(1, tot.accepted), (unsigned long long)tot.verts,
           (unsigned long long)tot.lightcmds, (double)tot.lights / std::max<u64>(1, tot.lightcmds));
    printf("model cycles per submitted polygon: avg %.1f, flush p1 %llu\n", (double)tot.cycles / std::max<u64>(1, tot.submitted),
           (unsigned long long)pct(perpoly, .01));
    printf("mix:");
    for (auto& [c, n] : mix) printf(" %02X:%llu", c, (unsigned long long)n);
    printf("\n");
    return 0;
}
