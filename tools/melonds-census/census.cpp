// NDS_Pocket hardware census: runs melonDS headless with scripted input and
// logs what the hardware is asked to do. See README.md.

#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

#define private public
#include "SPU.h"
#undef private
#include "NDS.h"
#include "NDSCart.h"
#include "GPU.h"
#include "GPU3D.h"
#include "SPI_Firmware.h"
#include "Census.h"
#include "CensusRuleMode.h"
#include "Platform.h"
#include "Savestate.h"
#include "state2d.h"
#include "spu_trace.h"
#include "runtime_history.h"
#include "runtime_atomic.h"

using namespace melonDS;

namespace melonDS::Platform
{
extern std::string SavePath;
extern int MinLogLevel;
}

static NDS* nds = nullptr;
static bool runtimeHistory = false;
static u32 curFrame = 0;
static u32 curLine = 0;

// ---------------------------------------------------------------- helpers

static std::vector<u8> ReadFile(const std::string& path)
{
    std::vector<u8> data;
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path.c_str()); exit(1); }
    fseek(f, 0, SEEK_END);
    data.resize(ftell(f));
    fseek(f, 0, SEEK_SET);
    if (fread(data.data(), 1, data.size(), f) != data.size()) { fprintf(stderr, "short read %s\n", path.c_str()); exit(1); }
    fclose(f);
    return data;
}

struct Stat
{
    std::vector<double> v;
    void add(double x) { v.push_back(x); }
    double pct(double p)
    {
        if (v.empty()) return 0;
        std::vector<double> s = v;
        std::sort(s.begin(), s.end());
        size_t i = std::min(s.size() - 1, (size_t)std::ceil(p / 100.0 * s.size()) - (p > 0 ? 1 : 0));
        return s[i];
    }
    double mean() { double t = 0; for (double x : v) t += x; return v.empty() ? 0 : t / v.size(); }
    double max() { return v.empty() ? 0 : *std::max_element(v.begin(), v.end()); }
};

using Hist = std::map<std::string, u64>;

static void JsonStat(FILE* f, const char* name, Stat& s, bool comma = true)
{
    fprintf(f, "  \"%s\": {\"n\": %zu, \"mean\": %.2f, \"p50\": %.0f, \"p95\": %.0f, \"p99\": %.0f, \"max\": %.0f}%s\n",
            name, s.v.size(), s.mean(), s.pct(50), s.pct(95), s.pct(99), s.max(), comma ? "," : "");
}

static void JsonHist(FILE* f, const char* name, Hist& h, bool comma = true)
{
    std::vector<std::pair<std::string, u64>> items(h.begin(), h.end());
    std::sort(items.begin(), items.end(), [](auto& a, auto& b) { return a.second > b.second; });
    fprintf(f, "  \"%s\": {", name);
    for (size_t i = 0; i < items.size(); i++)
        fprintf(f, "%s\n    \"%s\": %llu", i ? "," : "", items[i].first.c_str(), (unsigned long long)items[i].second);
    fprintf(f, "\n  }%s\n", comma ? "," : "");
}

static std::string Fmt(const char* fmt, ...)
{
    char buf[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    return buf;
}

// ---------------------------------------------------------------- ARM9 caches
// ARM946E-S geometry on the DS: 8 KiB I-cache, 4 KiB D-cache, 4-way, 32-byte
// lines. Round-robin replacement. Reads allocate, writes do not.

struct Cache
{
    u32 sets, ways;
    std::vector<u32> tags;
    std::vector<u8> next;
    u64 accesses = 0, misses = 0;

    Cache(u32 size, u32 w = 4) : sets(size / 32 / w), ways(w), tags(sets * w, 0), next(sets, 0) {}

    bool Access(u32 addr, bool allocate)
    {
        accesses++;
        u32 line = addr >> 5;
        u32 set = line % sets;
        u32 tag = line / sets + 1;
        u32* t = &tags[set * ways];
        for (u32 w = 0; w < ways; w++)
            if (t[w] == tag) return true;
        misses++;
        if (allocate)
        {
            t[next[set]] = tag;
            next[set] = (next[set] + 1) % ways;
        }
        return false;
    }
};

static Cache ICache(8192), DCache(4096);

// ---------------------------------------------------------------- per-frame counters

enum Region { RMain, RWram, RIO, RPal, RVram, ROam, RSlot2, RBios, ROther, RCount };
static const char* RegionNames[RCount] = {"main", "wram", "io", "pal", "vram", "oam", "slot2", "bios", "other"};

static Region RegionOf(u32 addr)
{
    switch (addr >> 24)
    {
    case 0x02: return RMain;
    case 0x03: return RWram;
    case 0x04: return RIO;
    case 0x05: return RPal;
    case 0x06: return RVram;
    case 0x07: return ROam;
    case 0x08: case 0x09: case 0x0A: return RSlot2;
    case 0xFF: case 0x00: return RBios;
    default: return ROther;
    }
}

struct FrameCounters
{
    u64 busy[2] {};
    u64 insns[2] {};              // retired instructions (--count-insns)
    u64 bus[2][RCount] {};        // bytes on the CPU's external bus per region
    u64 tcm[2] {};                // ITCM/DTCM accesses (ARM9 only)
    u64 icacheAcc = 0, icacheMiss = 0, dcacheAcc = 0, dcacheMiss = 0;
    u64 gxEntries = 0;
    u64 dmaBytes[2] {};
    u64 gxDmaBytes = 0;
    u32 cartCmds = 0;
    u64 cartBytes = 0;
    u32 flushes = 0, polys = 0, verts = 0, overflow = 0;
    u64 area = 0;
    u64 polyLines = 0;      // sum of polygon heights in lines (per-line polygon re-fetch)
    u32 linePolysMax = 0;   // most polygons covering one line
    u32 sndMax = 0;
    u32 capture = 0;
    u32 objLineMax[2] {};         // OBJs on a line (all, then those that start within the budget)
    u32 objDrawnMax[2] {};
    u32 objDemandMax[2] {};       // OBJ cycles asked for, and spent (capped at the budget)
    u32 objNeedMax[2] {};         // cycles through the last OBJ with on-screen pixels
    u32 objCyclesMax[2] {};
    u32 objOverLines[2] {};       // lines over the budget, and lines that lose an on-screen OBJ
    u32 objDropLines[2] {};
    u32 vramcntChanges = 0;
};

static FrameCounters fc;

// ---------------------------------------------------------------- run-wide tallies

static Stat statBusy[2], statPolys, statVerts, statArea, statTexUnique, statGxCmds;
static Stat statObjLine[2], statObjDrawn[2], statObjDemand[2], statObjNeed[2], statObjCycles[2];
static u64 objOverLines[2], objDropLines[2];
static Stat statUnitFrame[4], statUnitLine[4], statBankFrame[10], statBankLine[10];
static Stat statTotalFrame, statTotalLine, statTotalSeq8, statTotalB32;
static Stat statCartGap, statCartPerFrame, statDma[2], statGxDma, statSnd, statBusMain[2];
static Stat statICache, statDCache;
static Hist hDisp3D, hPolyMode, hPolyFlags, hTexFmtPolys, hTexFmtArea, hTexSize, hGxCmds;
static Hist hVramcnt, h2D[2], h2DFeat[2], hDma, hCartCmd, hCartSize, hSndFmt, hCapture, hVerts;
static u32 flushCount = 0, overflowFlushes = 0, framesWithFlush = 0;
static u64 cartPrevLine = 0, cartPrevAddr = 0, cartPrevLen = 0, cartSequential = 0, cartReads = 0;
static u8 lastVramcnt[9];

// ---------------------------------------------------------------- GX trace

static FILE* gxTrace = nullptr;
static u32 gxFirst = 0, gxFrames = 0, vramEvery = 30;
static u32 gxFlushesTraced = 0;

static bool Tracing() { return gxTrace && curFrame >= gxFirst && curFrame < gxFirst + gxFrames; }

// Record layout (little endian):
//   'C' u8 cmd u32 param                    geometry FIFO entry as executed
//   'F' u32 frame u32 npolys u32 nverts     flush (SWAP_BUFFERS at VBlank), followed by
//       u32 disp3dcnt u32 flushattr u8 alpharef u16 toon[32] u16 edge[8]
//       u32 fogcolor u32 fogoffset u8 fogdensity[32] u32 clear1 u32 clear2
//   'V' u32 frame u8 vramcnt[9] then the 9 banks A..I raw (656 KiB)
static void TraceVram()
{
    GPU& gpu = nds->GPU;
    fputc('V', gxTrace);
    fwrite(&curFrame, 4, 1, gxTrace);
    fwrite(gpu.VRAMCNT, 1, 9, gxTrace);
    for (int i = 0; i < 9; i++)
        fwrite(gpu.VRAM[i], 1, gpu.VRAMMask[i] + 1, gxTrace);
}

// ---------------------------------------------------------------- hooks

static void SnapTouch(u32 addr);
static void OnMemAccess(int cpu, u32 kind, u32 addr, u32 size)
{
    u32 bytes = size / 8;
    if (cpu == 0) SnapTouch(addr);
    if (cpu == 0)
    {
        ARMv5& a = nds->ARM9;
        if (addr < a.ITCMSize) { fc.tcm[0]++; return; }
        if (kind != Census::Code && (addr & a.DTCMMask) == a.DTCMBase) { fc.tcm[0]++; return; }
        u8 pu = a.PU_Map ? a.PU_Map[addr >> 12] : 0;
        Region r = RegionOf(addr);
        if (kind == Census::Code && (pu & 0x40))
        {
            fc.icacheAcc++;
            if (!ICache.Access(addr, true)) { fc.icacheMiss++; fc.bus[0][r] += 32; }
            return;
        }
        if (kind != Census::Code && (pu & 0x10))
        {
            fc.dcacheAcc++;
            bool hit = DCache.Access(addr, kind == Census::Read);
            if (!hit) fc.dcacheMiss++;
            if (kind == Census::Read) { if (!hit) fc.bus[0][r] += 32; }
            else if (!hit || !(pu & 0x20)) fc.bus[0][r] += bytes;   // write-through or write miss
            return;
        }
        fc.bus[0][r] += bytes;
    }
    else
        fc.bus[1][RegionOf(addr)] += bytes;
}

static void OnBusy(int cpu, u32 cycles) { fc.busy[cpu] += cycles; }

static void OnGXCommand(u8 cmd, u32 param)
{
    fc.gxEntries++;
    hGxCmds[Fmt("%02X", cmd)]++;
    if (Tracing())
    {
        fputc('C', gxTrace);
        fputc(cmd, gxTrace);
        fwrite(&param, 4, 1, gxTrace);
    }
}

// Bytes per texel, for the per-flush texture working set.
static double TexelBytes(u32 fmt)
{
    switch (fmt)
    {
    case 1: return 1;        // A3I5
    case 2: return 0.25;     // 4 colours
    case 3: return 0.5;      // 16 colours
    case 4: return 1;        // 256 colours
    case 5: return 0.375;    // 4x4 compressed: 2 bits + 1/8 of a 16-bit index
    case 6: return 1;        // A5I3
    case 7: return 2;        // direct
    default: return 0;
    }
}

static void OnFlush3D(GPU3D& g)
{
    flushCount++;
    fc.flushes++;
    fc.polys = std::max(fc.polys, g.NumPolygons);
    fc.verts = std::max(fc.verts, g.NumVertices);
    statPolys.add(g.NumPolygons);
    statVerts.add(g.NumVertices);
    bool over = g.DispCnt & (1 << 13);
    if (over) { overflowFlushes++; fc.overflow++; }

    u32 dc = g.DispCnt;
    if (g.NumPolygons)
    {
        static const char* bits[] = {"texture", "toon_highlight_select", "alpha_test", "alpha_blend",
                                     "antialias", "edge_mark", "fog_alpha_only", "fog"};
        for (int i = 0; i < 8; i++)
            if (dc & (1 << i)) hDisp3D[bits[i]]++;
        if (dc & (1 << 14)) hDisp3D["rear_plane_bitmap"]++;
        if (g.FlushAttributes & 1) hDisp3D["manual_translucent_sort"]++;
        if (g.FlushAttributes & 2) hDisp3D["w_buffer"]++;
        hDisp3D["flushes_with_polygons"]++;
    }

    double area = 0;
    u64 polyLines = 0;
    std::vector<u16> linePolys(192, 0);
    std::set<u64> uniqueTex;
    double uniqueBytes = 0;
    std::set<u32> polyIds;
    for (u32 i = 0; i < g.NumPolygons; i++)
    {
        Polygon& p = g.CurPolygonRAM[i];
        u32 attr = p.Attr;
        if (!p.Degenerate)
        {
            s32 y0 = std::max(0, p.YTop), y1 = std::min(192, std::max(p.YBottom, p.YTop + 1));
            for (s32 y = y0; y < y1; y++) linePolys[y]++;
            if (y1 > y0) polyLines += y1 - y0;
        }
        static const char* modes[] = {"modulate", "decal", "toon_highlight", "shadow"};
        hPolyMode[modes[(attr >> 4) & 3]]++;
        u32 alpha = (attr >> 16) & 0x1F;
        if (alpha == 0) hPolyFlags["wireframe"]++;
        if (p.Translucent) hPolyFlags["translucent"]++;
        if (p.IsShadowMask) hPolyFlags["shadow_mask"]++;
        if (p.IsShadow) hPolyFlags["shadow"]++;
        if (attr & (1 << 11)) hPolyFlags["translucent_depth_write"]++;
        if (attr & (1 << 12)) hPolyFlags["far_plane_draw"]++;
        if (attr & (1 << 13)) hPolyFlags["one_dot_draw"]++;
        if (attr & (1 << 14)) hPolyFlags["depth_equal"]++;
        if (attr & (1 << 15)) hPolyFlags["fog_enable"]++;
        if (p.Type == 1) hPolyFlags["line"]++;
        if ((attr & 0xC0) == 0xC0) hPolyFlags["both_sides"]++;
        polyIds.insert((attr >> 24) & 0x3F);
        hVerts[Fmt("%u", p.NumVertices)]++;

        double a = 0;
        for (u32 k = 0; k < p.NumVertices; k++)
        {
            const s32* v0 = p.Vertices[k]->FinalPosition;
            const s32* v1 = p.Vertices[(k + 1) % p.NumVertices]->FinalPosition;
            a += (double)v0[0] * v1[1] - (double)v1[0] * v0[1];
        }
        a = std::fabs(a) / 2;
        area += a;

        u32 fmt = (p.TexParam >> 26) & 7;
        if (fmt && (dc & 1))
        {
            static const char* fmts[] = {"none", "a3i5", "4col", "16col", "256col", "4x4", "a5i3", "direct"};
            hTexFmtPolys[fmts[fmt]]++;
            hTexFmtArea[fmts[fmt]] += (u64)a;
            u32 s = 8 << ((p.TexParam >> 20) & 7), t = 8 << ((p.TexParam >> 23) & 7);
            hTexSize[Fmt("%ux%u", s, t)]++;
            u64 key = ((u64)(p.TexParam & 0x3FFFFFFF) << 16) | (p.TexPalette & 0x1FFF);
            if (uniqueTex.insert(key).second)
                uniqueBytes += s * t * TexelBytes(fmt);
        }
    }
    hPolyFlags[Fmt("polygon_ids_%s", polyIds.size() > 8 ? "gt8" : polyIds.size() > 1 ? "2to8" : "1")]++;
    fc.area = std::max<u64>(fc.area, (u64)area);
    fc.polyLines = std::max<u64>(fc.polyLines, polyLines);
    fc.linePolysMax = std::max<u32>(fc.linePolysMax, *std::max_element(linePolys.begin(), linePolys.end()));
    statArea.add(area);
    statTexUnique.add(uniqueBytes);

    if (Tracing())
    {
        fputc('F', gxTrace);
        fwrite(&curFrame, 4, 1, gxTrace);
        fwrite(&g.NumPolygons, 4, 1, gxTrace);
        fwrite(&g.NumVertices, 4, 1, gxTrace);
        fwrite(&g.DispCnt, 4, 1, gxTrace);
        fwrite(&g.FlushAttributes, 4, 1, gxTrace);
        fwrite(&g.AlphaRef, 1, 1, gxTrace);
        fwrite(g.ToonTable, 2, 32, gxTrace);
        fwrite(g.EdgeTable, 2, 8, gxTrace);
        fwrite(&g.FogColor, 4, 1, gxTrace);
        fwrite(&g.FogOffset, 4, 1, gxTrace);
        fwrite(g.FogDensityTable, 1, 32, gxTrace);
        fwrite(&g.ClearAttr1, 4, 1, gxTrace);
        fwrite(&g.ClearAttr2, 4, 1, gxTrace);
        if (gxFlushesTraced++ % vramEvery == 0) TraceVram();
    }
}

static void OnDMAStart(int cpu, u32 num, u32 mode, u32 src, u32 dst, u32 bytes)
{
    fc.dmaBytes[cpu] += bytes;
    if (cpu == 0 && dst == 0x04000400) fc.gxDmaBytes += bytes;
    hDma[Fmt("arm%d mode%u %s->%s", cpu ? 7 : 9, mode, RegionNames[RegionOf(src)], RegionNames[RegionOf(dst)])] += bytes;
    (void)num;
}

// Cartridge data-read trace (--cart-trace): one row per B7 read, for the SD
// latency probe. sys_cycle is the ARM9 clock in DS system cycles (33.514 MHz).
static FILE* cartTrace = nullptr;

static void OnCartCommand(const u8* cmd, u32 len)
{
    fc.cartCmds++;
    fc.cartBytes += len;
    hCartCmd[Fmt("%02X", cmd[0])]++;
    if (cmd[0] == 0xB7)
    {
        u32 addr = (cmd[1] << 24) | (cmd[2] << 16) | (cmd[3] << 8) | cmd[4];
        u64 line = (u64)curFrame * 263 + curLine;
        hCartSize[Fmt("%u", len)]++;
        if (cartTrace)
            fprintf(cartTrace, "%u,%u,%llu,%u,%u\n", curFrame, curLine,
                    (unsigned long long)(nds->ARM9Timestamp >> nds->ARM9ClockShift), addr, len);
        if (cartReads) statCartGap.add((double)(line - cartPrevLine));
        if (cartReads && addr == cartPrevAddr + cartPrevLen) cartSequential++;
        cartReads++;
        cartPrevLine = line;
        cartPrevAddr = addr;
        cartPrevLen = len;
    }
}

// ---------------------------------------------------------------- VRAM traffic
// Every VRAM read the soft renderers make (and display capture's reads and
// writes) is mapped from melonDS's flat VRAM copies back to a physical bank
// (A..I) and counted per unit, bank and line. Reads are de-duplicated within
// one line per unit and bank:
// - `bytes`: distinct bytes (what a core with a per-line cache must fetch)
// - `seq8`: changes of aligned 8-byte block in the unit's read stream (the
//   8-byte fetches of a core with no cache, which re-reads repeated tiles)
// - `b32`: distinct aligned 32-byte blocks (misses of a 32-byte line cache)
// 3D line y counts toward line y.

enum Unit { U2DA, U2DB, U3D, UCap, UCount };
static const char* UnitNames[UCount] = {"2da", "2db", "3d", "cap"};
static const int NBank = 10;   // A..I, then reads from unmapped space (no memory is read)
static const char BankNames[NBank + 1] = "ABCDEFGHI-";

struct VCnt { u32 bytes = 0, seq8 = 0, b32 = 0; };
static VCnt vLines[UCount][192][NBank];        // this frame (3D: last rendered frame)
static VCnt vCur[UCount][NBank];               // line in progress
static s32 vLine[UCount] = {-1, -1, -1, -1};
static u32 vLast[UCount] = {~0u, ~0u, ~0u, ~0u};  // bank << 24 | 8-byte block of the previous read
static bool rendered3D = false;

struct BankSeen
{
    std::vector<u8> bytes, blk32;              // bytes: bit per byte, one u8 per 8-byte block
    std::vector<u32> touched;                  // 8-byte blocks set this line
};
static BankSeen vSeen[UCount][9];

static void VAccess(int unit, int bank, u32 off, u32 n)
{
    VCnt& c = vCur[unit][bank];
    u32 key = (bank << 24) | (off >> 3);
    if (key != vLast[unit]) { c.seq8 += (n + 7) / 8; vLast[unit] = key; }
    if (bank == 9) { c.bytes += n; return; }
    BankSeen& s = vSeen[unit][bank];
    if (s.bytes.empty())
    {
        u32 size = nds->GPU.VRAMMask[bank] + 1;
        s.bytes.assign(size / 8, 0);
        s.blk32.assign(size / 32, 0);
    }
    u32 mask = nds->GPU.VRAMMask[bank];
    for (u32 i = 0; i < n; i++)
    {
        u32 a = (off + i) & mask, blk = a >> 3;
        u8 bit = 1 << (a & 7);
        if (s.bytes[blk] & bit) continue;
        if (!s.bytes[blk])
        {
            s.touched.push_back(blk);
            if (!s.blk32[blk >> 2]) { s.blk32[blk >> 2] = 1; c.b32++; }
        }
        s.bytes[blk] |= bit;
        c.bytes++;
    }
}

static void VAccessMask(int unit, u32 banks, u32 off, u32 n)
{
    if (!banks) { VAccess(unit, 9, off, n); return; }
    for (int b = 0; b < 9; b++)
        if (banks & (1 << b)) VAccess(unit, b, off, n);
}

static void VFlush(int unit)
{
    s32 line = vLine[unit];
    for (int b = 0; b < NBank; b++)
    {
        if (line >= 0 && line < 192)
        {
            VCnt& d = vLines[unit][line][b];
            d.bytes += vCur[unit][b].bytes;
            d.seq8 += vCur[unit][b].seq8;
            d.b32 += vCur[unit][b].b32;
        }
        vCur[unit][b] = VCnt {};
        if (b < 9)
        {
            BankSeen& s = vSeen[unit][b];
            for (u32 blk : s.touched) { s.bytes[blk] = 0; s.blk32[blk >> 2] = 0; }
            s.touched.clear();
        }
    }
    vLine[unit] = -1;
    vLast[unit] = ~0u;
}

static void OnVRAMRead(int unit, u32 space, u32 off, u32 n)
{
    GPU& g = nds->GPU;
    switch (space)
    {
    case Census::BG:
        VAccessMask(unit, unit ? g.VRAMMap_BBG[(off >> 14) & 7] : g.VRAMMap_ABG[(off >> 14) & 31], off, n);
        break;
    case Census::OBJ:
        VAccessMask(unit, unit ? g.VRAMMap_BOBJ[(off >> 14) & 7] : g.VRAMMap_AOBJ[(off >> 14) & 15], off, n);
        break;
    case Census::OBJExtPal:
        VAccessMask(unit, unit ? g.VRAMMap_BOBJExtPal : g.VRAMMap_AOBJExtPal, off * 2, n);
        break;
    case Census::Texture:
        VAccessMask(unit, g.VRAMMap_Texture[(off >> 17) & 3], off, n);
        break;
    case Census::TexPal:
        VAccessMask(unit, g.VRAMMap_TexPal[(off >> 14) & 7], off, n);
        break;
    }
}

// BG palette lookups: palette RAM is internal and not counted; the extended
// palette copy is VRAM.
static void OnBGPalRead(int engine, const void* p)
{
    GPU& g = nds->GPU;
    const u8* base = engine ? g.VRAMFlat_BBGExtPal : g.VRAMFlat_ABGExtPal;
    ptrdiff_t off = (const u8*)p - base;
    if (off < 0 || off >= 32 * 1024) return;
    u32 slot = off >> 13;
    VAccessMask(engine, engine ? g.VRAMMap_BBGExtPal[slot] : g.VRAMMap_ABGExtPal[slot], off, 2);
}


// ---------------------------------------------------------------- 2D state dump
// --gpu2d-dump F --gpu2d-at FRAME:N[,FRAME:N...]: for every visible line of
// the chosen frames, the state melonDS's 2D renderer draws that line from
// (sim/gpu2d/state2d.h, read by the 2D engine testbench), and the line
// melonDS displayed. Each FRAME:N window is one segment.

// Renderer::Rend3D is protected; a pointer to member formed through a
// derived class reads it without changing melonDS.
struct RendPeek : Renderer
{
    static Renderer3D* R3D(Renderer& r) { return (r.*(&RendPeek::Rend3D)).get(); }
};

struct G2DLine
{
    g2d::LineState st;
    std::vector<g2d::Chunk> chunks;
    bool swap;
};
static FILE* g2dFile = nullptr;
static std::vector<std::pair<u32, u32>> g2dWins;       // first frame, frames
static std::unique_ptr<g2d::Mem> g2dLast, g2dCur;
static std::vector<G2DLine> g2dPending;
static std::string g2dGame;

static bool G2DActiveAt(u32 f)
{
    for (auto& w : g2dWins)
        if (f >= w.first && f < w.first + w.second) return true;
    return false;
}
static bool G2DActive() { return G2DActiveAt(curFrame); }

static void G2DEng(const GPU2D& g, g2d::EngState& e, u16 mb)
{
    e.enabled = g.Enabled; e.forced_blank = g.ForcedBlank; e.layer_enable = g.LayerEnable; e.obj_enable = g.OBJEnable;
    e.dispcnt = g.DispCnt;
    for (int i = 0; i < 4; i++) { e.bgcnt[i] = g.BGCnt[i]; e.bgxpos[i] = g.BGXPos[i]; e.bgypos[i] = g.BGYPos[i]; }
    for (int i = 0; i < 2; i++)
    {
        e.xref[i] = g.BGXRefInternal[i]; e.yref[i] = g.BGYRefInternal[i];
        e.rota[i] = g.BGRotA[i]; e.rotc[i] = g.BGRotC[i];
    }
    memcpy(e.win0, g.Win0Coords, 4); memcpy(e.win1, g.Win1Coords, 4); memcpy(e.wincnt, g.WinCnt, 4);
    e.win0_active = g.Win0Active; e.win1_active = g.Win1Active;
    memcpy(e.bg_mosaic, g.BGMosaicSize, 2); memcpy(e.obj_mosaic, g.OBJMosaicSize, 2);
    e.bg_mosaic_line = g.BGMosaicLine; e.obj_mosaic_line = g.OBJMosaicLine;
    e.blendcnt = g.BlendCnt; e.eva = g.EVA; e.evb = g.EVB; e.evy = g.EVY;
    e.master_bright = mb;
}

static void G2DLine2D(u32 line)
{
    if (!g2dFile || !G2DActive()) return;
    if (g2dPending.empty() && line == 0 && !G2DActiveAt(curFrame - 1))
        memset(g2dLast.get(), 0, sizeof(g2d::Mem));    // a segment starts from zeroed memory
    GPU& g = nds->GPU;
    // make the flat views current now; the renderer would do this a moment
    // later in the same HBlank, with nothing able to write VRAM in between
    { auto d = g.VRAMDirty_ABG.DeriveState(g.VRAMMap_ABG, g); g.MakeVRAMFlat_ABGCoherent(d); }
    { auto d = g.VRAMDirty_BBG.DeriveState(g.VRAMMap_BBG, g); g.MakeVRAMFlat_BBGCoherent(d); }
    { auto d = g.VRAMDirty_AOBJ.DeriveState(g.VRAMMap_AOBJ, g); g.MakeVRAMFlat_AOBJCoherent(d); }
    { auto d = g.VRAMDirty_BOBJ.DeriveState(g.VRAMMap_BOBJ, g); g.MakeVRAMFlat_BOBJCoherent(d); }
    { auto d = g.VRAMDirty_ABGExtPal.DeriveState(g.VRAMMap_ABGExtPal, g); g.MakeVRAMFlat_ABGExtPalCoherent(d); }
    { auto d = g.VRAMDirty_BBGExtPal.DeriveState(g.VRAMMap_BBGExtPal, g); g.MakeVRAMFlat_BBGExtPalCoherent(d); }
    { auto d = g.VRAMDirty_AOBJExtPal.DeriveState(&g.VRAMMap_AOBJExtPal, g); g.MakeVRAMFlat_AOBJExtPalCoherent(d); }
    { auto d = g.VRAMDirty_BOBJExtPal.DeriveState(&g.VRAMMap_BOBJExtPal, g); g.MakeVRAMFlat_BOBJExtPalCoherent(d); }
    g2d::Mem& m = *g2dCur;
    memcpy(m.palette, g.Palette, 2048); memcpy(m.oam, g.OAM, 2048);
    memcpy(m.abg, g.VRAMFlat_ABG, sizeof(m.abg)); memcpy(m.bbg, g.VRAMFlat_BBG, sizeof(m.bbg));
    memcpy(m.aobj, g.VRAMFlat_AOBJ, sizeof(m.aobj)); memcpy(m.bobj, g.VRAMFlat_BOBJ, sizeof(m.bobj));
    memcpy(m.abgext, g.VRAMFlat_ABGExtPal, sizeof(m.abgext)); memcpy(m.bbgext, g.VRAMFlat_BBGExtPal, sizeof(m.bbgext));
    memcpy(m.aobjext, g.VRAMFlat_AOBJExtPal, sizeof(m.aobjext)); memcpy(m.bobjext, g.VRAMFlat_BOBJExtPal, sizeof(m.bobjext));
    for (int b = 0; b < 4; b++) memcpy(m.lcdc[b], g.VRAM[b], 128 * 1024);

    G2DLine l {};
    l.st.frame = curFrame; l.st.line = line;
    G2DEng(g.GPU2D_A, l.st.e[0], g.MasterBrightnessA);
    G2DEng(g.GPU2D_B, l.st.e[1], g.MasterBrightnessB);
    l.st.capcnt = g.CaptureCnt;
    l.st.cap_enable = g.CaptureEnable;
    l.st.lcdc = g.VRAMMap_LCDC & 0xF;
    memcpy(l.st.l3d, RendPeek::R3D(g.GetRenderer())->GetLine(line), sizeof(l.st.l3d));
    memcpy(l.st.fifo, g.DispFIFOBuffer, sizeof(l.st.fifo));
    l.swap = g.ScreenSwap;
    for (auto& r : g2d::mem_regions())
        for (u32 o = r.off; o < r.off + r.size; o += g2d::ChunkSize)
        {
            u32 n = std::min(g2d::ChunkSize, r.off + r.size - o);
            const u8* a = (const u8*)&m + o;
            if (!memcmp(a, (const u8*)g2dLast.get() + o, n)) continue;
            l.chunks.push_back({o, std::vector<u8>(a, a + n)});
            memcpy((u8*)g2dLast.get() + o, a, n);
        }
    g2dPending.push_back(std::move(l));
}

// After a dumped frame: the lines with melonDS's displayed output (6-bit
// channels, as before ExpandColor).
static void G2DFrameEnd()
{
    if (g2dPending.empty()) return;
    void *top, *bottom;
    nds->GPU.GetFramebuffers(&top, &bottom);
    bool newSeg = g2dPending.front().st.frame == 0 || !G2DActiveAt(g2dPending.front().st.frame - 1);
    if (newSeg)
    {
        std::string name = Fmt("%s-f%u", g2dGame.c_str(), g2dPending.front().st.frame);
        u32 n = name.size();
        fputc('S', g2dFile); fwrite(&n, 4, 1, g2dFile); fwrite(name.data(), 1, n, g2dFile);
    }
    for (auto& l : g2dPending)
    {
        for (auto& c : l.chunks)
        {
            u32 len = c.data.size();
            fputc('C', g2dFile); fwrite(&c.off, 4, 1, g2dFile); fwrite(&len, 4, 1, g2dFile);
            fwrite(c.data.data(), 1, len, g2dFile);
        }
        fputc('L', g2dFile); fwrite(&l.st, sizeof(l.st), 1, g2dFile);
        u32 ref[2][256];
        for (int e = 0; e < 2; e++)
        {
            // engine A is on the top screen when ScreenSwap is set
            const u32* fb = (const u32*)((e == 0) == l.swap ? top : bottom) + l.st.line * 256;
            for (int x = 0; x < 256; x++)
                ref[e][x] = ((fb[x] >> 18) & 0x3F) | ((fb[x] >> 10) & 0x3F) << 8 | ((fb[x] >> 2) & 0x3F) << 16;
        }
        fputc('R', g2dFile); fwrite(ref, sizeof(ref), 1, g2dFile);
    }
    g2dPending.clear();
}

// Visible 2D line: the soft renderer draws both engines, then display
// capture. The VRAM display mode and capture read or write whole lines of
// an LCDC bank, so they are counted here from the same state DoCapture uses.
static void OnLine2D(u32 line)
{
    G2DLine2D(line);
    for (int u : {U2DA, U2DB, UCap}) { VFlush(u); vLine[u] = line; }
    GPU& g = nds->GPU;
    u32 dc = g.GPU2D_A.DispCnt;
    if (((dc >> 16) & 3) == 2)
    {
        u32 bank = (dc >> 18) & 3;
        if (g.VRAMMap_LCDC & (1 << bank)) VAccess(U2DA, bank, line * 512, 512);
    }
    if (!g.CaptureEnable) return;
    u32 cc = g.CaptureCnt, sz = (cc >> 20) & 3;
    u32 width = sz ? 256 : 128, height = sz ? 64 * sz : 128;
    if (line >= height) return;
    u32 dst = (cc >> 16) & 3;
    if (!(g.VRAMMap_LCDC & (1 << dst))) return;
    VAccess(UCap, dst, ((((cc >> 18) & 3) << 14) + line * width) * 2, width * 2);
    u32 src = (cc >> 29) & 3;
    if (src != 0 && !(cc & (1 << 25)))
    {
        u32 sbank = (dc >> 18) & 3;
        if (g.VRAMMap_LCDC & (1 << sbank))
        {
            u32 off = line * 256;
            if (((dc >> 16) & 3) != 2) off += ((cc >> 26) & 3) << 14;
            VAccess(UCap, sbank, (off & 0xFFFF) * 2, width * 2);
        }
    }
}

// melonDS skips rendering a 3D frame whose inputs are unchanged; the hardware
// renders it again with the same fetches, so the last frame's lines stand.
static void OnFrame3D(bool identical)
{
    VFlush(U3D);
    rendered3D = true;
    if (!identical) memset(vLines[U3D], 0, sizeof(vLines[U3D]));
}

static void OnLine3D(s32 y) { VFlush(U3D); vLine[U3D] = y; }

// ---------------------------------------------------------------- SPU trace
// --spu-trace F --spu-first FRAME --spu-frames N: a snapshot of the SPU at the
// first mixer step of FRAME, then every register write, mixer step, sample
// fetch, capture write and output pair (sim/sound/spu_trace.h).

static FILE* spuTrace = nullptr;
static u32 spuFirst = 0, spuFrames = 0;
static bool spuOn = false;

static bool SpuActive() { return spuTrace && curFrame >= spuFirst && curFrame < spuFirst + spuFrames; }

static void SpuRec(u8 type, u32 size, u32 a, u32 b)
{
    spu::Rec r{type, (u8)size, 0, a, b};
    fwrite(&r, sizeof r, 1, spuTrace);
}

static void SpuSnapshot(SPU& s)
{
    spu::Snap sn{};
    sn.cnt = s.Cnt; sn.mastervol = s.MasterVolume; sn.bias = s.Bias; sn.mute = s.Mute;
    for (int i = 0; i < 16; i++)
    {
        const SPUChannel& c = s.Channels[i];
        spu::ChanSnap& o = sn.ch[i];
        o.cnt = c.Cnt; o.srcaddr = c.SrcAddr; o.timerreload = c.TimerReload;
        o.looppos = c.LoopPos; o.length = c.Length; o.keyon = c.KeyOn; o.timer = c.Timer;
        o.pos = c.Pos; o.cursample = c.CurSample; o.noise = c.NoiseVal;
        o.adpcmval = c.ADPCMVal; o.adpcmindex = c.ADPCMIndex;
        o.adpcmvalloop = c.ADPCMValLoop; o.adpcmindexloop = c.ADPCMIndexLoop;
        o.adpcmcurbyte = c.ADPCMCurByte;
        memcpy(o.fifo, c.FIFO, sizeof o.fifo);
        o.rp = c.FIFOReadPos; o.wp = c.FIFOWritePos; o.roff = c.FIFOReadOffset; o.level = c.FIFOLevel;
    }
    for (int i = 0; i < 2; i++)
    {
        const SPUCaptureUnit& c = s.Capture[i];
        spu::CapSnap& o = sn.cap[i];
        o.cnt = c.Cnt; o.dstaddr = c.DstAddr; o.timerreload = c.TimerReload; o.length = c.Length;
        o.timer = c.Timer; o.pos = c.Pos;
        memcpy(o.fifo, c.FIFO, sizeof o.fifo);
        o.rp = c.FIFOReadPos; o.wp = c.FIFOWritePos; o.woff = c.FIFOWriteOffset; o.level = c.FIFOLevel;
    }
    u8 type = spu::RecSnap;
    fwrite(&type, 1, 1, spuTrace);
    fwrite(&sn, sizeof sn, 1, spuTrace);
}

static void OnSPUMix(SPU& s)
{
    if (runtimeHistory) RuntimeHistoryMix(*nds, false);
    if (!SpuActive()) return;
    if (!spuOn) { SpuSnapshot(s); spuOn = true; }
    SpuRec(spu::RecMix, 0, 0, 0);
}
static void OnSPUMixEnd(const s16* out) { if (runtimeHistory) RuntimeHistoryMix(*nds, true); if (spuOn && SpuActive()) SpuRec(spu::RecOut, 0, (u16)out[0], (u16)out[1]); }
static void OnSPUWrite(u32 size, u32 addr, u32 val) { if (spuOn && SpuActive()) SpuRec(spu::RecWrite, size, addr, val); }
static void OnSPUPower(u32 val) { if (spuOn && SpuActive()) SpuRec(spu::RecPower, 0, 0, val); }
static void OnSPUFetch(u32 addr, u32 val) { if (spuOn && SpuActive()) SpuRec(spu::RecFetch, 0, addr, val); }
static void OnSPUCapture(u32 addr, u32 val) { if (runtimeHistory) RuntimeHistoryCapture(*nds, addr, val); if (spuOn && SpuActive()) SpuRec(spu::RecCap, 0, addr, val); }

// OBJ sizes [shape][size] -> w, h
static const u8 ObjW[3][4] = {{8, 16, 32, 64}, {16, 32, 32, 64}, {8, 8, 16, 32}};
static const u8 ObjH[3][4] = {{8, 16, 32, 64}, {8, 8, 16, 32}, {16, 32, 32, 64}};

// Line configuration, 2D features, and the OBJ render-time budget for one
// visible line, sampled at the start of the line.
//
// OBJ render time follows GBATEK "LCD OBJ - Overview" (the DS uses the GBA
// rule; GBATEK's DS pages add nothing):
// - normal OBJ: width cycles; affine OBJ: 10 + 2 x width, where width is the
//   doubled bounding box for double-size OBJs
// - an OBJ costs its cycles whenever it is on the line vertically, even when
//   it is horizontally off-screen
// - the budget is 1210 cycles per line, or 954 with DISPCNT bit 23
//   (H-blank interval free)
// - OBJs are processed in OAM order; the hardware stops when the budget runs
//   out, so later OBJs are not drawn (partially, for the one that straddles)
// Disabled OBJs (attr 0 bit 9 without affine) are taken to cost nothing.
// melonDS does not implement the budget, so `drop_visible` lines (an OBJ with
// on-screen pixels past the budget) are lines melonDS draws differently from
// the hardware. `need` is the cycles through the last OBJ with on-screen
// pixels: if games never lose a visible OBJ, the real budget is at least the
// largest `need` seen. (Mario Kart's character select needs 1518 on bottom
// line 52, eleven 64x64 affine portraits that the game shows, so the GBA
// figures above do not hold unchanged on the DS.)
static void Sample2D(int e)
{
    GPU& gpu = nds->GPU;
    auto& u = e ? gpu.GPU2D_B : gpu.GPU2D_A;
    u32 dc = u.DispCnt;
    u32 disp = (dc >> 16) & 3;
    if (e) disp &= 1;
    std::string key = Fmt("disp%u", disp);

    if (disp == 1 && !(dc & (1 << 7)))
    {
        u32 mode = dc & 7;
        key += Fmt(" mode%u", mode);
        for (int bg = 0; bg < 4; bg++)
        {
            if (!(dc & (1 << (8 + bg)))) continue;
            u16 cnt = u.BGCnt[bg];
            const char* type = "text";
            if (bg == 0 && !e && (dc & (1 << 3))) type = "3d";
            else if (bg >= 2)
            {
                static const char* t2[8] = {"text", "text", "affine", "text", "affine", "ext", "large", "none"};
                static const char* t3[8] = {"text", "affine", "affine", "ext", "ext", "ext", "none", "none"};
                type = bg == 2 ? t2[mode] : t3[mode];
            }
            else if (mode == 6) type = bg == 0 ? "text" : "none";
            std::string t = type;
            if (t == "text")
            {
                bool c8 = cnt & 0x80;
                if (c8 && (dc & (1u << 30))) t = "text8_extpal";
                else t = c8 ? "text8" : "text4";
            }
            else if (t == "ext")
            {
                if (!(cnt & 0x80)) t = (dc & (1u << 30)) ? "ext_affine16_extpal" : "ext_affine16";
                else if (cnt & 0x04) t = "ext_direct";
                else t = "ext_bmp256";
            }
            if (cnt & 0x40) h2DFeat[e]["bg_mosaic"]++;
            key += Fmt(" bg%d=%s", bg, t.c_str());
            h2DFeat[e]["bg_" + t]++;
        }

        if (dc & (1 << 12))
        {
            const u16* oam = (const u16*)&gpu.OAM[e ? 0x400 : 0];
            u32 limit = (dc & (1 << 23)) ? 954 : 1210;
            u32 nobj = 0, drawn = 0, demand = 0, need = 0;
            bool dropVisible = false;
            for (int i = 0; i < 128; i++)
            {
                u16 a0 = oam[i * 4], a1 = oam[i * 4 + 1];
                bool affine = a0 & 0x100;
                if (!affine && (a0 & 0x200)) continue;
                u32 shape = a0 >> 14, size = a1 >> 14;
                if (shape == 3) continue;
                u32 w = ObjW[shape][size], h = ObjH[shape][size];
                u32 bw = w, bh = h;
                if (affine && (a0 & 0x200)) { bw *= 2; bh *= 2; }
                u32 y = a0 & 0xFF;
                if (((curLine - y) & 0xFF) >= bh) continue;
                u32 objmode = (a0 >> 10) & 3;
                if (objmode == 2) { h2DFeat[e]["obj_window"]++; }
                nobj++;
                s32 x = (s32)(a1 << 23) >> 23;
                bool onscreen = x > -(s32)bw;
                if (demand < limit) drawn++;
                else if (onscreen) dropVisible = true;
                demand += affine ? 10 + 2 * bw : w;
                if (onscreen) need = demand;
                bool bitmap = objmode == 3, c8 = a0 & 0x2000;
                if (affine) h2DFeat[e]["obj_affine"]++;
                if (bitmap) h2DFeat[e]["obj_bitmap"]++;
                if (!bitmap && c8 && (dc & (1u << 31))) h2DFeat[e]["obj_extpal"]++;
                if (a0 & 0x1000) h2DFeat[e]["obj_mosaic"]++;
            }
            fc.objLineMax[e] = std::max(fc.objLineMax[e], nobj);
            fc.objDrawnMax[e] = std::max(fc.objDrawnMax[e], drawn);
            fc.objDemandMax[e] = std::max(fc.objDemandMax[e], demand);
            fc.objNeedMax[e] = std::max(fc.objNeedMax[e], need);
            fc.objCyclesMax[e] = std::max(fc.objCyclesMax[e], std::min(demand, limit));
            if (demand > limit) fc.objOverLines[e]++;
            if (dropVisible) fc.objDropLines[e]++;
            key += Fmt(" obj%s", (dc & (1 << 4)) ? "1d" : "2d");
        }
        if (dc & 0xE000) h2DFeat[e]["window"]++;
        if ((u.BlendCnt >> 6) & 3) h2DFeat[e][Fmt("blend_mode%u", (u.BlendCnt >> 6) & 3)]++;
    }
    u16 mb = e ? gpu.MasterBrightnessB : gpu.MasterBrightnessA;
    if ((mb >> 14) & 3 && (mb & 0x1F)) h2DFeat[e]["master_brightness"]++;

    h2D[e][key]++;
}

static bool mutate = false;

// --export-clean DIR [--export-after N]: export at the first line start, from frame N on, where the geometry
// engine is idle: no command queued or in the pipe, no swap pending, no polygon or vertex of the next frame yet
// (docs/state-import.md "A save point is not a 3D frame boundary"). The run goes on: its shots are the
// reference frames; DIR/clean.txt records the frame and line.
void ExportState(melonDS::NDS* nds, const std::string& dir, int vcount = -1, bool runtime = false);     // export_state.cpp
static std::string cleanDir;
static bool cleanRuntime = false;
static u32 cleanAfter = 0;
static int cleanFrame = -1;

// --swap-log FILE: the 3D swaps (a pending SwapBuffers carried out at a scanline: FlushRequest 1 -> 0),
// cumulative, one line per frame "FRAME SWAPS" (sim/pocket_ds/scenes.py's pace check)
static FILE* swapLog = nullptr;
static u32 swapCount = 0, swapPrev = 0;

static void OnScanline(u32 line)
{
    curLine = line;
    {
        u32 fr = nds->GPU.GPU3D.FlushRequest;
        if (swapPrev && !fr) swapCount++;
        swapPrev = fr;
    }
    if (!cleanDir.empty() && cleanFrame < 0 && curFrame >= cleanAfter)
    {
        GPU3D& g3 = nds->GPU.GPU3D;
        if (g3.CmdFIFO.IsEmpty() && g3.CmdPIPE.IsEmpty() && !g3.FlushRequest && g3.NumPolygons == 0 && g3.NumVertices == 0)
        {
            ExportState(nds, cleanDir, line, cleanRuntime);
            cleanFrame = curFrame;
            FILE* f = fopen((cleanDir + "/clean.txt").c_str(), "w");
            fprintf(f, "frame %u line %u\n", curFrame, line);
            fclose(f);
            fprintf(stderr, "export-clean: frame %u line %u\n", curFrame, line);
        }
    }
    if (mutate && line == 100) nds->GPU.Palette[0] ^= 1;   // deliberate perturbation for the observer check
    GPU& gpu = nds->GPU;
    if (line == 0)
    {
        hVramcnt[Fmt("%02X %02X %02X %02X %02X %02X %02X %02X %02X",
                     gpu.VRAMCNT[0], gpu.VRAMCNT[1], gpu.VRAMCNT[2], gpu.VRAMCNT[3], gpu.VRAMCNT[4],
                     gpu.VRAMCNT[5], gpu.VRAMCNT[6], gpu.VRAMCNT[7], gpu.VRAMCNT[8])]++;
        if (gpu.CaptureCnt & (1u << 31))
        {
            fc.capture = 1;
            u32 c = gpu.CaptureCnt;
            hCapture[Fmt("src%u size%u bank%u", (c >> 29) & 3, (c >> 20) & 3, (c >> 16) & 3)]++;
        }
    }
    if (memcmp(lastVramcnt, gpu.VRAMCNT, 9))
    {
        if (line != 0) fc.vramcntChanges++;
        memcpy(lastVramcnt, gpu.VRAMCNT, 9);
    }
    if (line < 192)
    {
        Sample2D(0);
        Sample2D(1);
    }

    u32 active = 0;
    for (int ch = 0; ch < 16; ch++)
    {
        u32 cnt = nds->SPU.Read32(0x04000400 + ch * 16);
        if (cnt & (1u << 31))
        {
            active++;
            if (line == 0)
            {
                static const char* fmts[] = {"pcm8", "pcm16", "adpcm", "psg"};
                u32 f = (cnt >> 29) & 3;
                hSndFmt[(f == 3 && ch < 8) ? "psg_on_pcm_channel" : fmts[f]]++;
            }
        }
    }
    fc.sndMax = std::max(fc.sndMax, active);
    if (line == 0 && (nds->SPU.Read8(0x04000508) & 0x80)) hSndFmt["capture0"]++;
    if (line == 0 && (nds->SPU.Read8(0x04000509) & 0x80)) hSndFmt["capture1"]++;
}

// ---------------------------------------------------------------- input script
// Lines: "<first> <last> KEY..." holds keys for frames first..last inclusive.
//        "<first> <last> touch <x> <y>" holds a touch (census only; the core has none).
// Keys: A B SELECT START RIGHT LEFT UP DOWN R L X Y. '#' starts a comment.

struct InputLine { u32 first, last, keys; int tx, ty; };

static std::vector<InputLine> LoadScript(const std::string& path)
{
    static const char* names[] = {"A", "B", "SELECT", "START", "RIGHT", "LEFT", "UP", "DOWN", "R", "L", "X", "Y"};
    std::vector<InputLine> out;
    FILE* f = fopen(path.c_str(), "r");
    if (!f) { fprintf(stderr, "cannot open script %s\n", path.c_str()); exit(1); }
    char buf[512];
    while (fgets(buf, sizeof(buf), f))
    {
        if (char* c = strchr(buf, '#')) *c = 0;
        char* tok = strtok(buf, " \t\r\n");
        if (!tok) continue;
        InputLine l {(u32)atoi(tok), 0, 0, -1, -1};
        tok = strtok(nullptr, " \t\r\n");
        if (!tok) { fprintf(stderr, "bad script line\n"); exit(1); }
        l.last = atoi(tok);
        while ((tok = strtok(nullptr, " \t\r\n")))
        {
            if (!strcasecmp(tok, "touch"))
            {
                l.tx = atoi(strtok(nullptr, " \t\r\n"));
                l.ty = atoi(strtok(nullptr, " \t\r\n"));
                continue;
            }
            bool found = false;
            for (int k = 0; k < 12; k++)
                if (!strcasecmp(tok, names[k])) { l.keys |= 1 << k; found = true; }
            if (!found) { fprintf(stderr, "unknown key %s\n", tok); exit(1); }
        }
        out.push_back(l);
    }
    fclose(f);
    return out;
}

static void WriteShot(const std::string& path)
{
    void *top, *bottom;
    if (!nds->GPU.GetFramebuffers(&top, &bottom)) return;
    FILE* f = fopen(path.c_str(), "wb");
    fprintf(f, "P6\n256 384\n255\n");
    for (const u32* fb : {(const u32*)top, (const u32*)bottom})
        for (int i = 0; i < 256 * 192; i++)
        {
            u8 px[3] = {(u8)(fb[i] >> 16), (u8)(fb[i] >> 8), (u8)fb[i]};
            fwrite(px, 1, 3, f);
        }
    fclose(f);
}

// ---------------------------------------------------------------- golden-model traces
// --trace-dir: per CPU, retired instructions (.trc), data writes (.wr) and IRQ
// entries (irq*.txt). Formats in tools/ds-trace/README.md.

#pragma pack(push, 1)
struct TrcRec { u32 pc, cpsr, r[15]; };
struct WrRec { u32 addr, val; u8 size, src; u16 rsvd; };
#pragma pack(pop)
static_assert(sizeof(TrcRec) == 68 && sizeof(WrRec) == 12, "trace record size");

struct TraceCPU
{
    FILE* trc = nullptr;
    FILE* wr = nullptr;
    FILE* irq = nullptr;
    FILE* op = nullptr;     // --trace-op: the instruction word of each record
    u64 n = 0;      // records written
};
static TraceCPU tcpu[2];
static bool traceOn = false;
static u64 traceMax = 20000000;

// --snap-pcs A[,B...] --snap-dir DIR [--snap-max N=64] [--snap-from-frame F=0]:
// a game function run in isolation (tools/hwref/mkkssumv.py). On each ARM9
// call of a listed function (outside IRQ mode unless --snap-irq, one at a time), DIR/snap_NNNN.bin
// gets the machine at entry (after the function's first instruction, which
// only pushes): header, main RAM, ITCM, DTCM, CP15, VRAMCNT. At its return:
// a trailer (with a checksum of a picture written to VRAM), the function's own CPU writes
// and a bitmap of the main RAM KiB it touched (reads, writes, code) (not those of IRQ handlers or
// DMA), so entry + writes is the state the function alone leaves.
#pragma pack(push, 1)
struct SnapHdr { char magic[4]; u32 idx, func, frame, line; u64 ts; u32 r[15], cpsr, ramSize, itcmSize, dtcmSize; };
struct SnapCP15 { u32 control, dtcmSetting, itcmSetting, dtcmBase, codeCacheable, dataCacheable, dataCacheWrite, codeRW, dataRW, region[8]; u8 vramcnt[9], pad[3]; };
struct SnapTrail { char magic[4]; u32 frame, line; u64 ts; u32 insns, irqInsns, nwrites, cksum, ckAddr, ckLen; };
struct SnapWr { u32 off, val; u8 space, size; u16 pad; };   // space 0 main RAM, 1 ITCM, 2 DTCM
#pragma pack(pop)
static std::vector<u32> snapPCs;
static std::string snapDir;
static u32 snapMax = 64, snapFrom = 0, snapN = 0;
static bool snapIrq = false;              // --snap-irq 1: functions that run in IRQ mode (handlers)
static u32 snapCkAddr = 0, snapCkLen = 0;  // --snap-cksum [*]ADDR:LEN: checksum this region (*: the word at ADDR
static bool snapCkInd = false;             // at entry is the region's start), not r1's picture
static u32 snapCkAt;
static u8 snapTouched[512];                // main RAM KiB the call's own accesses touched (not DTCM)
static FILE* snapF = nullptr;
static u32 snapLR, snapMode, snapInsns, snapIrqInsns, snapR1;
static std::vector<SnapWr> snapWr;
static size_t snapWrAtRetire;

static void SnapRetire(u32 pc, const u32* r, u32 cpsr)
{
    if (snapF)
    {
        if ((cpsr & 0x1F) != snapMode) { snapIrqInsns++; return; }
        if (pc == snapLR)
        {
            snapWr.resize(snapWrAtRetire);      // this instruction is the caller's
            // r1 in VRAM (the movie's picture output): a sampled checksum of the
            // 256x192 RGB15 picture, the same as sw/hwref/kssumv/run.c computes
            u32 ck = 0, ckAddr = snapCkAt, ckLen = snapCkLen ? snapCkLen : 256 * 192 * 2;
            if ((ckAddr >> 24) == 6)
                for (u32 i = 0; i < ckLen; i += 64) ck = ck * 31 + nds->ARM9Read32(ckAddr + i);
            SnapTrail t {{'K', 'S', 'E', 'X'}, curFrame, curLine, nds->ARM9Timestamp >> nds->ARM9ClockShift,
                         snapInsns, snapIrqInsns, (u32)snapWr.size(), ck, (ckAddr >> 24) == 6 ? ckAddr : 0, (ckAddr >> 24) == 6 ? ckLen : 0};
            fwrite(&t, sizeof t, 1, snapF);
            fwrite(snapWr.data(), sizeof(SnapWr), snapWr.size(), snapF);
            fwrite(snapTouched, 1, sizeof snapTouched, snapF);
            fclose(snapF);
            snapF = nullptr;
            return;
        }
        snapInsns++;
        SnapTouch(pc);
        snapWrAtRetire = snapWr.size();
        return;
    }
    if (snapN >= snapMax || curFrame < snapFrom || (!snapIrq && (cpsr & 0x1F) == 0x12)) return;
    if (std::find(snapPCs.begin(), snapPCs.end(), pc) == snapPCs.end()) return;
    snapF = fopen(Fmt("%s/snap_%04u.bin", snapDir.c_str(), snapN).c_str(), "wb");
    if (!snapF) { fprintf(stderr, "cannot write %s\n", snapDir.c_str()); exit(1); }
    ARMv5& a = nds->ARM9;
    SnapHdr h {{'K', 'S', 'N', 'P'}, snapN, pc, curFrame, curLine, nds->ARM9Timestamp >> nds->ARM9ClockShift, {},
               cpsr, nds->MainRAMMask + 1, ITCMPhysicalSize, DTCMPhysicalSize};
    memcpy(h.r, r, sizeof h.r);
    fwrite(&h, sizeof h, 1, snapF);
    fwrite(nds->MainRAM, 1, nds->MainRAMMask + 1, snapF);
    fwrite(a.ITCM, 1, ITCMPhysicalSize, snapF);
    fwrite(a.DTCM, 1, DTCMPhysicalSize, snapF);
    SnapCP15 c {a.CP15Control, a.DTCMSetting, a.ITCMSetting, a.DTCMBase, a.PU_CodeCacheable, a.PU_DataCacheable,
                a.PU_DataCacheWrite, a.PU_CodeRW, a.PU_DataRW, {}, {}, {}};
    memcpy(c.region, a.PU_Region, sizeof c.region);
    memcpy(c.vramcnt, nds->GPU.VRAMCNT, 9);
    fwrite(&c, sizeof c, 1, snapF);
    snapLR = r[14];
    snapR1 = r[1];
    snapCkAt = !snapCkLen ? r[1] : snapCkInd ? nds->ARM9Read32(snapCkAddr) : snapCkAddr;
    memset(snapTouched, 0, sizeof snapTouched);
    snapMode = cpsr & 0x1F;
    snapInsns = 1;
    snapIrqInsns = 0;
    snapWr.clear();
    snapWrAtRetire = 0;
    snapN++;
}

static void SnapTouch(u32 addr)
{
    if (!snapF || (nds->ARM9.CPSR & 0x1F) != snapMode || (addr >> 24) != 2) return;
    if ((addr & nds->ARM9.DTCMMask) == nds->ARM9.DTCMBase) return;
    u32 k = (addr & nds->MainRAMMask) >> 10;
    snapTouched[k >> 3] |= 1 << (k & 7);
}

static void SnapWrite(int cpu, u32 src, u32 addr, u32 val, u32 bytes)
{
    if (!snapF || cpu || src || (nds->ARM9.CPSR & 0x1F) != snapMode) return;
    ARMv5& a = nds->ARM9;
    addr &= ~(bytes - 1);
    SnapWr w {0, val, 0, (u8)bytes, 0};
    if ((addr & a.DTCMMask) == a.DTCMBase) { w.space = 2; w.off = addr & (DTCMPhysicalSize - 1); }
    else if (addr < a.ITCMSize) { w.space = 1; w.off = addr & (ITCMPhysicalSize - 1); }
    else if ((addr >> 24) == 2) w.off = addr & nds->MainRAMMask;
    else return;
    snapWr.push_back(w);
}

static void OnRetire(int cpu, u32 pc, const u32* r, u32 cpsr)
{
    fc.insns[cpu]++;
    if (!cpu && !snapPCs.empty()) SnapRetire(pc, r, cpsr);
    TraceCPU& t = tcpu[cpu];
    if (!traceOn || t.n >= traceMax) return;
    TrcRec rec;
    rec.pc = pc;
    rec.cpsr = cpsr;
    memcpy(rec.r, r, sizeof(rec.r));
    fwrite(&rec, sizeof(rec), 1, t.trc);
    if (t.op)
    {
        u32 op = cpu ? nds->ARM7.CurInstr : nds->ARM9.CurInstr;
        fwrite(&op, sizeof(op), 1, t.op);
    }
    t.n++;
}

static u32 ioWatch = 0;           // --iowatch ADDR [--iowatch-len N]: writes to ADDR..ADDR+N-1, with frame and line, on stderr
static u32 ioWatchLen = 4;
static u32 ioWatchFrom = 0;
static void OnDataWrite(int cpu, u32 src, u32 addr, u32 val, u32 bytes)
{
    if (runtimeHistory) RuntimeHistoryIntent(*nds, cpu, src, addr, val, bytes);
    if (!snapPCs.empty()) SnapWrite(cpu, src, addr, val, bytes);
    if (ioWatch && addr - ioWatch < ioWatchLen && curFrame >= ioWatchFrom)
        fprintf(stderr, "iowatch f%u line %u: arm%d %08x <= %08x (%u bytes)\n", curFrame, curLine, cpu ? 7 : 9, addr, val, bytes);
    TraceCPU& t = tcpu[cpu];
    if (!traceOn || t.n >= traceMax) return;
    WrRec rec {addr & ~(bytes - 1), val & (bytes == 4 ? ~0u : (1u << (8 * bytes)) - 1), (u8)bytes, (u8)src, 0};
    fwrite(&rec, sizeof(rec), 1, t.wr);
}

static void (*runtimePreviousRetire)(int,u32,const u32*,u32)=nullptr;
static void OnRuntimeRetire(int cpu,u32 pc,const u32* r,u32 cpsr) {
    RuntimeHistoryCompleteTCM(*nds);
    if(runtimePreviousRetire)runtimePreviousRetire(cpu,pc,r,cpsr);
}

static void OnIRQEntry(int cpu)
{
    TraceCPU& t = tcpu[cpu];
    if (!traceOn || t.n >= traceMax) return;
    fprintf(t.irq, "%llu %08x\n", (unsigned long long)t.n, nds->IE[cpu] & nds->IF[cpu]);
}

static void TraceOpen(const std::string& dir)
{
    if (system(("mkdir -p '" + dir + "'").c_str()) != 0) exit(1);
    for (int c = 0; c < 2; c++)
    {
        const char* n = c ? "arm7" : "arm9";
        tcpu[c].trc = fopen(Fmt("%s/%s.trc", dir.c_str(), n).c_str(), "wb");
        tcpu[c].wr = fopen(Fmt("%s/%s.wr", dir.c_str(), n).c_str(), "wb");
        tcpu[c].irq = fopen(Fmt("%s/irq%c.txt", dir.c_str(), c ? '7' : '9').c_str(), "w");
        if (!tcpu[c].trc || !tcpu[c].wr || !tcpu[c].irq) { fprintf(stderr, "cannot open trace files in %s\n", dir.c_str()); exit(1); }
        setvbuf(tcpu[c].trc, nullptr, _IOFBF, 1 << 22);
        setvbuf(tcpu[c].wr, nullptr, _IOFBF, 1 << 20);
    }
}

static void TraceClose()
{
    for (int c = 0; c < 2; c++)
        if (tcpu[c].trc)
        {
            fclose(tcpu[c].trc); fclose(tcpu[c].wr); fclose(tcpu[c].irq);
            if (tcpu[c].op) fclose(tcpu[c].op);
            fprintf(stderr, "trace: arm%d %llu instructions\n", c ? 7 : 9, (unsigned long long)tcpu[c].n);
        }
}


// --dump-boot: memories and registers right after direct-boot setup.
static void WriteBin(const std::string& path, const void* p, size_t n)
{
    FILE* f = fopen(path.c_str(), "wb");
    if (!f || fwrite(p, 1, n, f) != n) { fprintf(stderr, "cannot write %s\n", path.c_str()); exit(1); }
    fclose(f);
}

static void DumpCPU(FILE* f, const char* name, ARM& a, u32 entry)
{
    fprintf(f, "# %s: R[] is the current mode's view (mode %02X); banked slots hold\n"
               "# the registers of the modes not current (melonDS swaps on mode change)\n", name, a.CPSR & 0x1F);
    fprintf(f, "%s.pc %08x\n%s.melon_r15 %08x\n%s.cpsr %08x\n", name, entry, name, a.R[15], name, a.CPSR);
    for (int i = 0; i < 15; i++) fprintf(f, "%s.r%d %08x\n", name, i, a.R[i]);
    for (int i = 0; i < 7; i++) fprintf(f, "%s.r%d_fiq_slot %08x\n", name, 8 + i, a.R_FIQ[i]);
    fprintf(f, "%s.spsr_fiq %08x\n", name, a.R_FIQ[7]);
    struct { const char* m; u32* r; } banks[] = {{"svc", a.R_SVC}, {"abt", a.R_ABT}, {"irq", a.R_IRQ}, {"und", a.R_UND}};
    for (auto& b : banks)
        fprintf(f, "%s.r13_%s_slot %08x\n%s.r14_%s_slot %08x\n%s.spsr_%s %08x\n",
                name, b.m, b.r[0], name, b.m, b.r[1], name, b.m, b.r[2]);
    fprintf(f, "%s.exception_base %08x\n%s.halted %u\n", name, a.ExceptionBase, name, a.Halted);
}

static void DumpBoot(const std::string& dir, const std::vector<u8>& rom)
{
    if (system(("mkdir -p '" + dir + "'").c_str()) != 0) exit(1);
    WriteBin(dir + "/main.bin", nds->MainRAM, 0x400000);
    WriteBin(dir + "/swram.bin", nds->SharedWRAM, 0x8000);
    WriteBin(dir + "/wram7.bin", nds->ARM7WRAM, 0x10000);
    WriteBin(dir + "/itcm.bin", nds->ARM9.ITCM, ITCMPhysicalSize);
    WriteBin(dir + "/dtcm.bin", nds->ARM9.DTCM, DTCMPhysicalSize);
    FILE* f = fopen((dir + "/state.txt").c_str(), "w");
    u32 e9, e7;
    memcpy(&e9, &rom[0x24], 4);
    memcpy(&e7, &rom[0x34], 4);
    fprintf(f, "# melonDS state after NDS::SetupDirectBoot, before the first instruction\n");
    DumpCPU(f, "arm9", nds->ARM9, e9);
    DumpCPU(f, "arm7", nds->ARM7, e7);
    static const u32 cp15[] = {0x100, 0x200, 0x201, 0x300, 0x502, 0x503,
        0x600, 0x601, 0x610, 0x611, 0x620, 0x621, 0x630, 0x631, 0x640, 0x641,
        0x650, 0x651, 0x660, 0x661, 0x670, 0x671, 0x910, 0x911};
    fprintf(f, "# CP15 as CP15Read(0xNMO): c<N>, c<M>, opcode2 <O>\n");
    for (u32 id : cp15) fprintf(f, "cp15.%03x %08x\n", id, nds->ARM9.CP15Read(id));
    fprintf(f, "cp15.dtcm_base %08x\ncp15.dtcm_mask %08x\ncp15.itcm_size %08x\n",
            nds->ARM9.DTCMBase, nds->ARM9.DTCMMask, nds->ARM9.ITCMSize);
    struct IO { const char* name; int cpu; u32 addr; int bits; };
    static const IO io[] = {
        {"WRAMCNT", 0, 0x04000247, 8}, {"POWCNT1", 0, 0x04000304, 16}, {"EXMEMCNT", 0, 0x04000204, 16},
        {"POSTFLG9", 0, 0x04000300, 8}, {"ROMCTRL9", 0, 0x040001A4, 32}, {"AUXSPICNT9", 0, 0x040001A0, 16},
        {"IME9", 0, 0x04000208, 32}, {"IE9", 0, 0x04000210, 32}, {"IF9", 0, 0x04000214, 32},
        {"VRAMCNT_A-D", 0, 0x04000240, 32}, {"DISPCNT_A", 0, 0x04000000, 32}, {"DISPCNT_B", 0, 0x04001000, 32},
        {"KEYCNT9", 0, 0x04000132, 16},
        {"WRAMSTAT", 1, 0x04000241, 8}, {"POWCNT2", 1, 0x04000304, 16}, {"EXMEMSTAT", 1, 0x04000204, 16},
        {"POSTFLG7", 1, 0x04000300, 8}, {"ROMCTRL7", 1, 0x040001A4, 32}, {"AUXSPICNT7", 1, 0x040001A0, 16},
        {"IME7", 1, 0x04000208, 32}, {"IE7", 1, 0x04000210, 32}, {"IF7", 1, 0x04000214, 32},
        {"RCNT", 1, 0x04000134, 16}, {"SOUNDBIAS", 1, 0x04000504, 16}, {"WIFIWAITCNT", 1, 0x04000206, 16},
        {"SOUNDCNT", 1, 0x04000500, 16}, {"KEYCNT7", 1, 0x04000132, 16},
    };
    fprintf(f, "# I/O registers as read through the CPU's I/O read path\n");
    for (const IO& r : io)
    {
        u32 v;
        if (r.cpu == 0) v = r.bits == 8 ? nds->ARM9IORead8(r.addr) : r.bits == 16 ? nds->ARM9IORead16(r.addr) : nds->ARM9IORead32(r.addr);
        else            v = r.bits == 8 ? nds->ARM7IORead8(r.addr) : r.bits == 16 ? nds->ARM7IORead16(r.addr) : nds->ARM7IORead32(r.addr);
        fprintf(f, "io.%s %08x  # %08x arm%d %d-bit\n", r.name, v, r.addr, r.cpu ? 7 : 9, r.bits);
    }
    fprintf(f, "# WIFIWAITCNT reads 0 while POWCNT2 bit 1 is clear; SetupDirectBoot stores 0x0030\n");
    fprintf(f, "ARM7BIOSProt %04x\nARM9ClockShift %u\nMainRAMMask %08x\n",
            nds->ARM7BIOSProt, nds->ARM9ClockShift, nds->MainRAMMask);
    fprintf(f, "# header: arm9 entry/ram %08x %08x, arm7 entry/ram %08x %08x\n",
            e9, *(u32*)&rom[0x28], e7, *(u32*)&rom[0x38]);
    fclose(f);
}

// ---------------------------------------------------------------- main

static u64 FramebufferHash()
{
    void *top, *bottom;
    if (!nds->GPU.GetFramebuffers(&top, &bottom)) return 0;
    u64 h = 1469598103934665603ull;
    for (const u32* fb : {(const u32*)top, (const u32*)bottom})
        for (int i = 0; i < 256 * 192; i++) { h ^= fb[i]; h *= 1099511628211ull; }
    return h;
}

static constexpr const char* FrontendCapabilities[]={"final-state","final-save","save-state-save","clean-runtime","clean-runtime-history"};

static void PrintRuleMode(FILE* f)
{
    const auto& m=Census::GetCompiledRuleMode();
    fprintf(f,"  \"census_mode\": \"%s\", \"declared_mode\": \"%s\",\n",m.mode,Census::DeclaredMode);
    fprintf(f,"  \"compiled_rule_count\": %u, \"declared_rule_count\": %u, \"compiled_rules\": [",m.count,Census::DeclaredRuleCount);
    for(unsigned i=0;i<m.count;i++)fprintf(f,"%s\"%s\"",i?", ":"",m.rules[i]);
    fprintf(f,"], \"frontend_capabilities\": [");
    for(unsigned i=0;i<sizeof(FrontendCapabilities)/sizeof(FrontendCapabilities[0]);i++)
        fprintf(f,"%s\"%s\"",i?", ":"",FrontendCapabilities[i]);
    fprintf(f,"]");
}

static bool RuleModeCoherent()
{
    const auto& m=Census::GetCompiledRuleMode();
    return m.count==Census::DeclaredRuleCount && !strcmp(m.mode,Census::DeclaredMode);
}

static void Usage()
{
    fprintf(stderr,
        "usage: census --build-info\n"
        "       census [--expect-mode ds-rules-23] --bios9 F --bios7 F --firmware F --rom F --script F --out DIR\n"
        "              [--frames N=3600] [--save F] [--shot-every N=300]\n"
        "              [--gx-first FRAME --gx-frames N [--vram-every FLUSHES=30]]\n"
        "              [--vram-trace-first FRAME [--vram-trace-frames N=60]]\n"
        "              [--no-hooks 1] [--mutate 1] [--cart-trace 1]\n"
        "              [--gpu2d-dump F --gpu2d-at FRAME:N[,FRAME:N...] [--gpu2d-name NAME]]\n"
        "              [--sd-dir DIR [--sd-mb N=64]]\n"
        "              [--load-state F] [--save-state F --save-state-at FRAME [--save-state-save F]]\n"
        "              [--final-state F] [--final-save F]\n"
        "              [--require-capabilities final-state,final-save,save-state-save]\n"
        "              [--spu-trace F --spu-first FRAME [--spu-frames N=600]]\n"
        "              [--trace-dir DIR [--trace-insns N=20000000] [--trace-from-frame F=0]\n"
        "               [--trace-perturb CYCLES] [--trace-op 1]] [--dump-boot DIR] [--export-state DIR] [--cache-ways N=4]\n"
        "              [--swap-log FILE] (3D swaps per frame, cumulative)\n"
        "              [--final-bgx 1] [--export-clean DIR [--export-after N] [--export-runtime 1]]  (export where the geometry engine is idle; the run goes on)\n"
        "              [--snap-pcs A[,B...] --snap-dir DIR [--snap-max N=64] [--snap-from-frame F=0] [--snap-irq 1]\n"
        "               [--snap-cksum [*]ADDR:LEN]]\n"
        "              [--export-runtime-history 1024 --runtime-history-until SYS] (bound original clean epoch)\n"
        "Frame numbers (script, shots, traces) count from the loaded state.\n");
    exit(2);
}

// Reference-only observation: cart save bytes paired with a state or final epoch.
// This runs outside RunFrame and does not change emulated timing/state.
static bool ExportReferenceSave(NDS* machine, const std::string& path)
{
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) return false;
    const auto size = machine->NDSCartSlot.GetSaveMemoryLength();
    const bool ok = size == 0 || fwrite(machine->NDSCartSlot.GetSaveMemory(), 1, size, f) == size;
    const int closed = fclose(f);
    return ok && closed == 0;
}

int main(int argc, char** argv)
{
    if(argc==2 && !strcmp(argv[1],"--build-info")) {
        fprintf(stdout,"{\n");PrintRuleMode(stdout);fprintf(stdout,"\n}\n");
        return RuleModeCoherent()?0:3;
    }
    if(!RuleModeCoherent()) {
        fprintf(stderr,"census declared/compiled rule mode mismatch\n");return 3;
    }
    std::map<std::string, std::string> opt;
    for (int i = 1; i < argc; i++)
    {
        if (strncmp(argv[i], "--", 2) || i + 1 >= argc) Usage();
        opt[argv[i] + 2] = argv[i + 1];
        i++;
    }
    if (opt.count("export-runtime")) {
        if (opt["export-runtime"] != "1" || !opt.count("export-clean") || opt.count("export-state")) {
            fprintf(stderr, "--export-runtime 1 requires --export-clean DIR\n"); return 1;
        }
        cleanRuntime = true;
    }
    if (opt.count("export-atomic")) {
        if (opt["export-atomic"]!="1" || !cleanRuntime) { fprintf(stderr,"--export-atomic 1 requires --export-runtime 1\n");return 1; }
        ConfigureRuntimeAtomic(true);
    }
    if (opt.count("export-runtime-history")) {
        if (opt["export-runtime-history"] != "1024" || !opt.count("runtime-history-until") || !opt.count("export-runtime")) {
            fprintf(stderr,"--export-runtime-history 1024 requires --runtime-history-until SYS and --export-runtime 1\n"); return 1;
        }
        ConfigureRuntimeHistory(std::stoull(opt["runtime-history-until"]), 1024);
        runtimeHistory = true;
    }
    if(opt.count("expect-mode") && opt["expect-mode"]!=Census::GetCompiledRuleMode().mode) {
        fprintf(stderr,"census mode mismatch: expected %s, compiled %s\n",opt["expect-mode"].c_str(),Census::GetCompiledRuleMode().mode);return 3;
    }
    if(opt.count("require-capabilities")) {
        const std::string& required=opt["require-capabilities"];
        for(size_t pos=0;pos<required.size();) {
            size_t end=required.find(',',pos);
            std::string name=required.substr(pos,end==std::string::npos?end:end-pos);
            bool supported=false;
            for(const char* capability:FrontendCapabilities)if(name==capability)supported=true;
            if(!supported){fprintf(stderr,"unsupported required frontend capability: %s\n",name.c_str());return 3;}
            if(end==std::string::npos)break;
            pos=end+1;
        }
    }
    for (const char* req : {"bios9", "bios7", "firmware", "rom", "script", "out"})
        if (!opt.count(req)) Usage();
    u32 frames = opt.count("frames") ? atoi(opt["frames"].c_str()) : 3600;
    u32 shotEvery = opt.count("shot-every") ? atoi(opt["shot-every"].c_str()) : 300;
    std::string out = opt["out"];
    if (system(("mkdir -p '" + out + "/shots'").c_str()) != 0) return 1;

    auto script = LoadScript(opt["script"]);

    NDSArgs args;
    auto b9 = ReadFile(opt["bios9"]), b7 = ReadFile(opt["bios7"]), fw = ReadFile(opt["firmware"]);
    if (b9.size() != ARM9BIOSSize || b7.size() != ARM7BIOSSize) { fprintf(stderr, "bad BIOS size\n"); return 1; }
    args.ARM9BIOS = std::make_unique<ARM9BIOSImage>();
    args.ARM7BIOS = std::make_unique<ARM7BIOSImage>();
    memcpy(args.ARM9BIOS->data(), b9.data(), b9.size());
    memcpy(args.ARM7BIOS->data(), b7.data(), b7.size());
    args.Firmware = Firmware(fw.data(), fw.size());
    args.JIT = std::nullopt;

    nds = runtimeHistory ? CreateRuntimeHistoryNDS(std::move(args)) : new NDS(std::move(args));

    auto rom = ReadFile(opt["rom"]);
    NDSCart::NDSCartArgs cartargs;
    Platform::SavePath = out + "/game.sav";
    if (opt.count("save"))
    {
        auto sav = ReadFile(opt["save"]);
        cartargs.SRAM = std::make_unique<u8[]>(sav.size());
        memcpy(cartargs.SRAM.get(), sav.data(), sav.size());
        cartargs.SRAMLength = sav.size();
    }
    // Homebrew SD card (DLDI): the image is built from --sd-dir at load and
    // synced back to it when the cart is destroyed at exit.
    if (opt.count("sd-dir"))
        cartargs.SDCard = FATStorageArgs{out + "/sd.img", (opt.count("sd-mb") ? std::stoull(opt["sd-mb"]) : 64ull) << 20, false, opt["sd-dir"]};
    auto cart = NDSCart::ParseROM(rom.data(), rom.size(), nullptr, std::move(cartargs));
    if (!cart) { fprintf(stderr, "ROM not recognised\n"); return 1; }
    nds->SetNDSCart(std::move(cart));
    nds->Reset();
    nds->SetupDirectBoot(opt["rom"]);
    if (opt.count("dump-boot")) DumpBoot(opt["dump-boot"], rom);
    nds->Start();

    if (opt.count("load-state"))
    {
        auto st = ReadFile(opt["load-state"]);
        Savestate s(st.data(), st.size(), false);
        if (s.Error || !nds->DoSavestate(&s)) { fprintf(stderr, "cannot load state %s\n", opt["load-state"].c_str()); return 1; }
    }
    // --export-state DIR: the loaded state for a tb_ds start (export_state.cpp, docs/state-import.md)
    if (opt.count("export-state")) { ExportState(nds, opt["export-state"]); return 0; }
    u32 saveAt = opt.count("save-state-at") ? atoi(opt["save-state-at"].c_str()) : ~0u;
    if (opt.count("swap-log")) swapLog = fopen(opt["swap-log"].c_str(), "w");
    if (opt.count("export-clean")) { cleanDir = opt["export-clean"]; cleanAfter = opt.count("export-after") ? atoi(opt["export-after"].c_str()) : 0; }

    char gamecode[5] = {0};
    memcpy(gamecode, &rom[0x0C], 4);
    char title[13] = {0};
    memcpy(title, &rom[0], 12);

    if (opt.count("cart-trace"))
    {
        cartTrace = fopen((out + "/cart_trace.csv").c_str(), "w");
        fprintf(cartTrace, "frame,line,sys_cycle,addr,len\n");
    }
    if (opt.count("gpu2d-dump"))
    {
        g2dFile = fopen(opt["gpu2d-dump"].c_str(), "wb");
        fwrite("G2DDUMP1", 1, 8, g2dFile);
        for (const char* p = opt["gpu2d-at"].c_str(); *p; )
        {
            u32 f = strtoul(p, (char**)&p, 10), n = 1;
            if (*p == ':') n = strtoul(p + 1, (char**)&p, 10);
            g2dWins.push_back({f, n});
            if (*p == ',') p++;
            else if (*p) Usage();
        }
        g2dLast = std::make_unique<g2d::Mem>();
        g2dCur = std::make_unique<g2d::Mem>();
        memset(g2dLast.get(), 0, sizeof(g2d::Mem));
        g2dGame = opt.count("gpu2d-name") ? opt["gpu2d-name"] : std::string(gamecode);
    }
    if (opt.count("gx-first"))
    {
        gxFirst = atoi(opt["gx-first"].c_str());
        gxFrames = opt.count("gx-frames") ? atoi(opt["gx-frames"].c_str()) : 600;
        if (opt.count("vram-every")) vramEvery = std::max(1, atoi(opt["vram-every"].c_str()));
        gxTrace = fopen((out + "/gx.bin").c_str(), "wb");
        fwrite("NDSGX001", 1, 8, gxTrace);
    }

    if (opt.count("spu-trace"))
    {
        spuTrace = fopen(opt["spu-trace"].c_str(), "wb");
        fwrite("NDSSPU01", 1, 8, spuTrace);
        spuFirst = opt.count("spu-first") ? atoi(opt["spu-first"].c_str()) : 0;
        spuFrames = opt.count("spu-frames") ? atoi(opt["spu-frames"].c_str()) : 600;
    }

    Census::Hooks hooks;
    hooks.MemAccess = OnMemAccess;
    hooks.Busy = OnBusy;
    hooks.GXCommand = OnGXCommand;
    hooks.Flush3D = OnFlush3D;
    hooks.DMAStart = OnDMAStart;
    hooks.CartCommand = OnCartCommand;
    hooks.Scanline = OnScanline;
    hooks.VRAMRead = OnVRAMRead;
    hooks.BGPalRead = OnBGPalRead;
    hooks.Line2D = OnLine2D;
    hooks.Frame3D = OnFrame3D;
    hooks.Line3D = OnLine3D;
    hooks.SPUWrite = OnSPUWrite;
    hooks.SPUPower = OnSPUPower;
    hooks.SPUMix = OnSPUMix;
    hooks.SPUMixEnd = OnSPUMixEnd;
    hooks.SPUFetch = OnSPUFetch;
    hooks.SPUCapture = OnSPUCapture;
    u32 traceFrom = ~0u;
    // --cache-ways N: model the ARM9 caches with N ways at the same sizes (to
    // cost a cheaper cache; the hardware has 4)
    if (opt.count("cache-ways"))
    {
        u32 w = atoi(opt["cache-ways"].c_str());
        ICache = Cache(8192, w); DCache = Cache(4096, w);
    }
    if (opt.count("trace-dir"))
    {
        TraceOpen(opt["trace-dir"]);
        if (opt.count("trace-op") && atoi(opt["trace-op"].c_str()))
            for (int c = 0; c < 2; c++)
                tcpu[c].op = fopen(Fmt("%s/%s.op", opt["trace-dir"].c_str(), c ? "arm7" : "arm9").c_str(), "wb");
        if (opt.count("trace-insns")) traceMax = strtoull(opt["trace-insns"].c_str(), nullptr, 0);
        traceFrom = opt.count("trace-from-frame") ? atoi(opt["trace-from-frame"].c_str()) : 0;
        hooks.Retire = OnRetire;
        hooks.DataWrite = OnDataWrite;
        hooks.IRQEntry = OnIRQEntry;
    }
    if (opt.count("iowatch"))
    {
        ioWatch = strtoul(opt["iowatch"].c_str(), nullptr, 0) & ~3u;
        ioWatchFrom = opt.count("iowatch-from") ? atoi(opt["iowatch-from"].c_str()) : 0;
        if (opt.count("iowatch-len")) ioWatchLen = strtoul(opt["iowatch-len"].c_str(), nullptr, 0);
        hooks.DataWrite = OnDataWrite;
    }
    if (opt.count("snap-pcs"))
    {
        for (const char* p = opt["snap-pcs"].c_str(); *p; )
        {
            snapPCs.push_back(strtoul(p, (char**)&p, 0));
            if (*p == ',') p++;
            else if (*p) Usage();
        }
        if (!opt.count("snap-dir")) Usage();
        snapDir = opt["snap-dir"];
        if (system(("mkdir -p '" + snapDir + "'").c_str()) != 0) return 1;
        if (opt.count("snap-max")) snapMax = atoi(opt["snap-max"].c_str());
        if (opt.count("snap-from-frame")) snapFrom = atoi(opt["snap-from-frame"].c_str());
        snapIrq = opt.count("snap-irq") && atoi(opt["snap-irq"].c_str());
        if (opt.count("snap-cksum"))
        {
            const char* p = opt["snap-cksum"].c_str();
            if (*p == '*') { snapCkInd = true; p++; }
            snapCkAddr = strtoul(p, (char**)&p, 0);
            if (*p != ':') Usage();
            snapCkLen = strtoul(p + 1, nullptr, 0);
        }
        hooks.Retire = OnRetire;
        hooks.DataWrite = OnDataWrite;
        hooks.MemAccess = OnMemAccess;
    }
    if (opt.count("count-insns") && atoi(opt["count-insns"].c_str()))
        hooks.Retire = OnRetire;      // counts; writes nothing without --trace-dir
    if (!opt.count("no-hooks")) Census::Active = &hooks;
    mutate = opt.count("mutate");

    FILE* csv = fopen((out + "/frames.csv").c_str(), "w");
    fprintf(csv, "frame,arm9_busy_pct,arm7_busy_pct,arm9_tcm_acc,icache_acc,icache_miss,dcache_acc,dcache_miss");
    for (int c = 0; c < 2; c++)
        for (int r = 0; r < RCount; r++)
            fprintf(csv, ",arm%d_%s_bytes", c ? 7 : 9, RegionNames[r]);
    fprintf(csv, ",gx_entries,flushes,polys,verts,overflow,area_px,dma9_bytes,dma7_bytes,gxdma_bytes,"
                 "cart_cmds,cart_bytes,snd_channels_max,capture");
    for (int e = 0; e < 2; e++)
        fprintf(csv, ",obj%c_line_max,obj%c_drawn_max,obj%c_demand_max,obj%c_need_max,obj%c_cycles_max,obj%c_over_lines,obj%c_drop_lines",
                "AB"[e], "AB"[e], "AB"[e], "AB"[e], "AB"[e], "AB"[e], "AB"[e]);
    for (int u = 0; u < UCount; u++) fprintf(csv, ",vram_%s_bytes", UnitNames[u]);
    for (int b = 0; b < NBank; b++) fprintf(csv, ",vram_%c_bytes", b < 9 ? BankNames[b] : 'x');
    fprintf(csv, ",vram_line_max,vram_seq8,vram_b32,vramcnt_midframe,poly_lines,line_polys_max,fb_hash,arm9_insns,arm7_insns\n");

    FILE* vtrace = nullptr;
    u32 vtFirst = 0, vtFrames = 0;
    if (opt.count("vram-trace-first"))
    {
        vtFirst = atoi(opt["vram-trace-first"].c_str());
        vtFrames = opt.count("vram-trace-frames") ? atoi(opt["vram-trace-frames"].c_str()) : 60;
        vtrace = fopen((out + "/vram_lines.csv").c_str(), "w");
        fprintf(vtrace, "frame,line,unit,bank,bytes,seq8,b32\n");
    }

    if (runtimeHistory) { runtimePreviousRetire=hooks.Retire;hooks.Retire=OnRuntimeRetire;hooks.DataWrite=OnDataWrite; BeginRuntimeHistory(*nds); }
    u64 last9 = nds->ARM9Timestamp, last7 = nds->ARM7Timestamp;
    u64 t0 = Platform::GetMSCount();

    for (curFrame = 0; curFrame < frames; curFrame++)
    {
        if (curFrame == saveAt && opt.count("save-state"))
        {
            Savestate s;
            if (s.Error || !nds->DoSavestate(&s)) { fprintf(stderr, "cannot save state\n"); return 1; }
            FILE* f = fopen(opt["save-state"].c_str(), "wb");
            fwrite(s.Buffer(), 1, s.Length(), f);
            fclose(f);
            fprintf(stderr, "state saved at frame %u\n", curFrame);
            if (opt.count("save-state-save") && !ExportReferenceSave(nds, opt["save-state-save"])) return 1;
        }
        u32 keys = 0;
        int tx = -1, ty = -1;
        for (auto& l : script)
            if (curFrame >= l.first && curFrame <= l.last)
            {
                keys |= l.keys;
                if (l.tx >= 0) { tx = l.tx; ty = l.ty; }
            }
        nds->SetKeyMask(~keys & 0xFFF);
        if (tx >= 0)
        {
            // melonDS takes raw ADC/16; map pixels through the firmware's calibration
            const auto& ud = nds->GetFirmware().GetEffectiveUserData();
            auto adc = [&](int px, int i) {
                int a1 = ud.TouchCalibrationADC1[i], a2 = ud.TouchCalibrationADC2[i];
                int p1 = ud.TouchCalibrationPixel1[i], p2 = ud.TouchCalibrationPixel2[i];
                int a = p2 != p1 ? a1 + (px - p1) * (a2 - a1) / (p2 - p1) : px << 4;
                return (u16)std::clamp(a >> 4, 0, 255);
            };
            nds->TouchScreen(adc(tx, 0), adc(ty, 1));
        }
        else
            nds->ReleaseScreen();

        fc = FrameCounters {};
        rendered3D = false;
        for (int u : {U2DA, U2DB, UCap}) memset(vLines[u], 0, sizeof(vLines[u]));
        if (curFrame == traceFrom)
        {
            traceOn = true;
            // deliberate timing change for testing the compare tool: the ARM9
            // loses CYCLES (ARM9 clock) before its first traced instruction
            if (opt.count("trace-perturb")) nds->ARM9Timestamp += strtoull(opt["trace-perturb"].c_str(), nullptr, 0);
        }
        if (traceOn && tcpu[0].n >= traceMax && tcpu[1].n >= traceMax)
        {
            fprintf(stderr, "trace: both CPUs reached %llu instructions; stopping at frame %u\n",
                    (unsigned long long)traceMax, curFrame);
            frames = curFrame;
            break;
        }
        nds->RunFrame();
        G2DFrameEnd();
        for (int u = 0; u < UCount; u++) VFlush(u);
        if (!rendered3D) memset(vLines[U3D], 0, sizeof(vLines[U3D]));

        // VRAM traffic: per unit and bank for the frame, and the worst line
        u64 unitFrame[UCount] {}, bankFrame[NBank] {}, total = 0, seq8 = 0, b32 = 0;
        u32 unitLine[UCount] {}, bankLine[NBank] {}, lineMax = 0;
        for (int y = 0; y < 192; y++)
        {
            u32 lineTotal = 0, bankY[NBank] {};
            for (int u = 0; u < UCount; u++)
            {
                u32 unitY = 0;
                for (int b = 0; b < NBank; b++)
                {
                    const VCnt& c = vLines[u][y][b];
                    if (!c.bytes) continue;
                    bankY[b] += c.bytes;
                    if (b == 9) continue;   // unmapped: no memory behind it, kept out of the sums
                    unitY += c.bytes;
                    seq8 += c.seq8;
                    b32 += c.b32;
                    if (vtrace && curFrame >= vtFirst && curFrame < vtFirst + vtFrames)
                        fprintf(vtrace, "%u,%d,%s,%c,%u,%u,%u\n", curFrame, y, UnitNames[u], BankNames[b],
                                c.bytes, c.seq8, c.b32);
                }
                unitFrame[u] += unitY;
                unitLine[u] = std::max(unitLine[u], unitY);
                lineTotal += unitY;
            }
            for (int b = 0; b < NBank; b++)
            {
                bankFrame[b] += bankY[b];
                bankLine[b] = std::max(bankLine[b], bankY[b]);
            }
            total += lineTotal;
            lineMax = std::max(lineMax, lineTotal);
        }
        for (int u = 0; u < UCount; u++) { statUnitFrame[u].add(unitFrame[u]); statUnitLine[u].add(unitLine[u]); }
        for (int b = 0; b < NBank; b++) { statBankFrame[b].add(bankFrame[b]); statBankLine[b].add(bankLine[b]); }
        statTotalFrame.add(total);
        statTotalLine.add(lineMax);
        statTotalSeq8.add(seq8);
        statTotalB32.add(b32);

        u64 d9 = nds->ARM9Timestamp - last9, d7 = nds->ARM7Timestamp - last7;
        last9 = nds->ARM9Timestamp;
        last7 = nds->ARM7Timestamp;
        double b9p = d9 ? 100.0 * fc.busy[0] / d9 : 0, b7p = d7 ? 100.0 * fc.busy[1] / d7 : 0;
        statBusy[0].add(b9p);
        statBusy[1].add(b7p);
        if (fc.flushes) framesWithFlush++;
        statGxCmds.add(fc.gxEntries);
        statCartPerFrame.add(fc.cartBytes);
        statDma[0].add(fc.dmaBytes[0]);
        statDma[1].add(fc.dmaBytes[1]);
        statGxDma.add(fc.gxDmaBytes);
        statSnd.add(fc.sndMax);
        statBusMain[0].add(fc.bus[0][RMain]);
        statBusMain[1].add(fc.bus[1][RMain]);
        if (fc.icacheAcc) statICache.add(100.0 * (fc.icacheAcc - fc.icacheMiss) / fc.icacheAcc);
        if (fc.dcacheAcc) statDCache.add(100.0 * (fc.dcacheAcc - fc.dcacheMiss) / fc.dcacheAcc);
        for (int e = 0; e < 2; e++)
        {
            statObjLine[e].add(fc.objLineMax[e]);
            statObjDrawn[e].add(fc.objDrawnMax[e]);
            statObjDemand[e].add(fc.objDemandMax[e]);
            statObjNeed[e].add(fc.objNeedMax[e]);
            statObjCycles[e].add(fc.objCyclesMax[e]);
            objOverLines[e] += fc.objOverLines[e];
            objDropLines[e] += fc.objDropLines[e];
        }

        fprintf(csv, "%u,%.2f,%.2f,%llu,%llu,%llu,%llu,%llu", curFrame, b9p, b7p,
                (unsigned long long)fc.tcm[0], (unsigned long long)fc.icacheAcc, (unsigned long long)fc.icacheMiss,
                (unsigned long long)fc.dcacheAcc, (unsigned long long)fc.dcacheMiss);
        for (int c = 0; c < 2; c++)
            for (int r = 0; r < RCount; r++)
                fprintf(csv, ",%llu", (unsigned long long)fc.bus[c][r]);
        fprintf(csv, ",%llu,%u,%u,%u,%u,%llu,%llu,%llu,%llu,%u,%llu,%u,%u",
                (unsigned long long)fc.gxEntries, fc.flushes, fc.polys, fc.verts, fc.overflow,
                (unsigned long long)fc.area,
                (unsigned long long)fc.dmaBytes[0], (unsigned long long)fc.dmaBytes[1], (unsigned long long)fc.gxDmaBytes,
                fc.cartCmds, (unsigned long long)fc.cartBytes, fc.sndMax, fc.capture);
        for (int e = 0; e < 2; e++)
            fprintf(csv, ",%u,%u,%u,%u,%u,%u,%u", fc.objLineMax[e], fc.objDrawnMax[e], fc.objDemandMax[e],
                    fc.objNeedMax[e], fc.objCyclesMax[e], fc.objOverLines[e], fc.objDropLines[e]);
        for (int u = 0; u < UCount; u++) fprintf(csv, ",%llu", (unsigned long long)unitFrame[u]);
        for (int b = 0; b < NBank; b++) fprintf(csv, ",%llu", (unsigned long long)bankFrame[b]);
        fprintf(csv, ",%u,%llu,%llu,%u,%llu,%u", lineMax, (unsigned long long)seq8, (unsigned long long)b32, fc.vramcntChanges,
                (unsigned long long)fc.polyLines, fc.linePolysMax);
        fprintf(csv, ",%016llx,%llu,%llu\n", (unsigned long long)FramebufferHash(),
                (unsigned long long)fc.insns[0], (unsigned long long)fc.insns[1]);

        if (shotEvery && (curFrame % shotEvery == shotEvery - 1))
            WriteShot(Fmt("%s/shots/f%06u.ppm", out.c_str(), curFrame + 1));
        if (swapLog) fprintf(swapLog, "%u %u\n", curFrame + 1, swapCount);
        if (curFrame % 600 == 599)
            fprintf(stderr, "frame %u (%.0f fps)\n", curFrame + 1,
                    (curFrame + 1) * 1000.0 / std::max<u64>(1, Platform::GetMSCount() - t0));
    }
    Census::Active = nullptr;
    if (swapLog) fclose(swapLog);
    TraceClose();
    fclose(csv);
    if (gxTrace) fclose(gxTrace);
    if (g2dFile) fclose(g2dFile);
    if (cartTrace) fclose(cartTrace);
    if (vtrace) fclose(vtrace);
    if (spuTrace) fclose(spuTrace);

    // GX entries -> commands (multi-parameter commands take one entry per parameter)
    static const std::map<int, int> params = {
        {0x10, 1}, {0x12, 1}, {0x13, 1}, {0x14, 1}, {0x16, 16}, {0x17, 12}, {0x18, 16}, {0x19, 12},
        {0x1A, 9}, {0x1B, 3}, {0x1C, 3}, {0x20, 1}, {0x21, 1}, {0x22, 1}, {0x23, 2}, {0x24, 1},
        {0x25, 1}, {0x26, 1}, {0x27, 1}, {0x28, 1}, {0x29, 1}, {0x2A, 1}, {0x2B, 1}, {0x30, 1},
        {0x31, 1}, {0x32, 1}, {0x33, 1}, {0x34, 32}, {0x40, 1}, {0x50, 1}, {0x60, 1}, {0x70, 3},
        {0x71, 2}, {0x72, 1}};
    Hist gxCmds;
    for (auto& [k, n] : hGxCmds)
    {
        int c = strtol(k.c_str(), nullptr, 16);
        auto it = params.find(c);
        gxCmds[k] = n / (it == params.end() ? 1 : it->second);
    }

    FILE* js = fopen((out + "/summary.json").c_str(), "w");
    fprintf(js, "{\n  \"title\": \"%s\", \"gamecode\": \"%s\", \"frames\": %u,\n", title, gamecode, frames);
    PrintRuleMode(js);fprintf(js,",\n");
    fprintf(js, "  \"flushes\": %u, \"frames_with_flush\": %u, \"overflow_flushes\": %u,\n",
            flushCount, framesWithFlush, overflowFlushes);
    fprintf(js, "  \"cart_reads\": %llu, \"cart_sequential_reads\": %llu,\n",
            (unsigned long long)cartReads, (unsigned long long)cartSequential);
    JsonStat(js, "arm9_busy_pct", statBusy[0]);
    JsonStat(js, "arm7_busy_pct", statBusy[1]);
    JsonStat(js, "icache_hit_pct_per_frame", statICache);
    JsonStat(js, "dcache_hit_pct_per_frame", statDCache);
    JsonStat(js, "arm9_main_bus_bytes_per_frame", statBusMain[0]);
    JsonStat(js, "arm7_main_bus_bytes_per_frame", statBusMain[1]);
    JsonStat(js, "polys_per_flush", statPolys);
    JsonStat(js, "verts_per_flush", statVerts);
    JsonStat(js, "area_px_per_flush", statArea);
    JsonStat(js, "unique_texture_bytes_per_flush", statTexUnique);
    JsonStat(js, "gx_entries_per_frame", statGxCmds);
    JsonStat(js, "dma9_bytes_per_frame", statDma[0]);
    JsonStat(js, "dma7_bytes_per_frame", statDma[1]);
    JsonStat(js, "gxfifo_dma_bytes_per_frame", statGxDma);
    JsonStat(js, "cart_bytes_per_frame", statCartPerFrame);
    JsonStat(js, "cart_read_gap_lines", statCartGap);
    JsonStat(js, "snd_channels_max_per_frame", statSnd);
    for (int e = 0; e < 2; e++)
    {
        char E = "AB"[e];
        JsonStat(js, Fmt("obj%c_per_line_max", E).c_str(), statObjLine[e]);
        JsonStat(js, Fmt("obj%c_drawn_per_line_max", E).c_str(), statObjDrawn[e]);
        JsonStat(js, Fmt("obj%c_demand_cycles_line_max", E).c_str(), statObjDemand[e]);
        JsonStat(js, Fmt("obj%c_need_cycles_line_max", E).c_str(), statObjNeed[e]);
        JsonStat(js, Fmt("obj%c_cycles_line_max", E).c_str(), statObjCycles[e]);
        fprintf(js, "  \"obj%c_over_budget_lines\": %llu, \"obj%c_drop_visible_lines\": %llu,\n",
                E, (unsigned long long)objOverLines[e], E, (unsigned long long)objDropLines[e]);
    }
    for (int u = 0; u < UCount; u++)
    {
        JsonStat(js, Fmt("vram_%s_bytes_per_frame", UnitNames[u]).c_str(), statUnitFrame[u]);
        JsonStat(js, Fmt("vram_%s_bytes_line_max", UnitNames[u]).c_str(), statUnitLine[u]);
    }
    for (int b = 0; b < NBank; b++)
    {
        char B = b < 9 ? BankNames[b] : 'x';
        JsonStat(js, Fmt("vram_bank%c_bytes_per_frame", B).c_str(), statBankFrame[b]);
        JsonStat(js, Fmt("vram_bank%c_bytes_line_max", B).c_str(), statBankLine[b]);
    }
    JsonStat(js, "vram_bytes_per_frame", statTotalFrame);
    JsonStat(js, "vram_bytes_line_max", statTotalLine);
    JsonStat(js, "vram_seq8_per_frame", statTotalSeq8);
    JsonStat(js, "vram_b32_per_frame", statTotalB32);
    JsonHist(js, "disp3dcnt_flushes", hDisp3D);
    JsonHist(js, "polygon_modes", hPolyMode);
    JsonHist(js, "polygon_flags", hPolyFlags);
    JsonHist(js, "polygon_vertex_counts", hVerts);
    JsonHist(js, "texture_formats_polys", hTexFmtPolys);
    JsonHist(js, "texture_formats_area_px", hTexFmtArea);
    JsonHist(js, "texture_sizes_polys", hTexSize);
    JsonHist(js, "gx_commands", gxCmds);
    JsonHist(js, "vramcnt_frames", hVramcnt);
    JsonHist(js, "engineA_line_configs", h2D[0]);
    JsonHist(js, "engineB_line_configs", h2D[1]);
    JsonHist(js, "engineA_features_lines", h2DFeat[0]);
    JsonHist(js, "engineB_features_lines", h2DFeat[1]);
    JsonHist(js, "display_capture_frames", hCapture);
    JsonHist(js, "dma_bytes", hDma);
    JsonHist(js, "cart_commands", hCartCmd);
    JsonHist(js, "cart_read_sizes", hCartSize);
    JsonHist(js, "sound_formats_frames", hSndFmt, false);
    fprintf(js, "}\n");
    fclose(js);

    fprintf(stderr, "done: %u frames in %.1f s\n", frames, (Platform::GetMSCount() - t0) / 1000.0);
    // --final-bgx: engine A's BG X scroll at the end (a scripted player's progress: sim/ds/play_search.py)
    if (opt.count("final-bgx"))
    {
        auto& ga = nds->GPU.GPU2D_A;
        printf("final-bgx %u %u %u %u xref %d %d polys %u\n", ga.BGXPos[0], ga.BGXPos[1], ga.BGXPos[2], ga.BGXPos[3],
               ga.BGXRefInternal[0], ga.BGXRefInternal[1], nds->GPU.GPU3D.RenderNumPolygons);
    }
    if (opt.count("final-save") && !ExportReferenceSave(nds, opt["final-save"])) return 1;
    if (opt.count("final-state"))
    {
        Savestate state;
        if (state.Error || !nds->DoSavestate(&state)) return 1;
        FILE* f = fopen(opt["final-state"].c_str(), "wb");
        if (!f) return 1;
        const bool ok = fwrite(state.Buffer(), 1, state.Length(), f) == state.Length();
        if (fclose(f) != 0 || !ok) return 1;
    }
    delete nds;
    return 0;
}
