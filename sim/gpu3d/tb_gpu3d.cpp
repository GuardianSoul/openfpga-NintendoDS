// Renders each scene through melonDS's software renderer (golden.cpp) and
// through rtl/gpu3d/gpu3d_raster.sv (Verilator), and diffs the 256x192
// frames pixel-exact. Usage:
//   tb_gpu3d [--only NAME] [--scene FILE]... [--lat N] [--cache LAT] [--all-polys] [--profile] [--feat-off LIST]
//            [--random N [--seed S]] [--dump-scenes DIR] [--out DIR]
//            [--cache2 [--cache-ways W] [--cache-occ N] [--cache-look N] [--cache-jitter N] [--cache-stall P L]] [--lead L]
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <random>
#include <string>
#include <vector>
#ifdef RCACHE
// --rcache build (g3d_rc.sv): the core's own texture/palette caches and block
// port mux; this testbench serves the block port with Port2's timing
#include "Vg3d_rc.h"
using Top = Vg3d_rc;
#else
#include "Vgpu3d_raster.h"
using Top = Vgpu3d_raster;
#endif
#include "verilated.h"
#include "scene.h"

using namespace g3d;

namespace
{

struct Beat { int type; uint32_t w[4]; };

void setbits(uint32_t* w, int lo, int n, uint64_t v)
{
    for (int i = 0; i < n; i++)
        if ((v >> i) & 1) w[(lo + i) / 32] |= 1u << ((lo + i) % 32);
}

Beat header_beat(const Poly& p, const PolyDerived& d)
{
    Beat b{0, {0, 0, 0, 0}};
    setbits(b.w, 0, 32, p.attr);
    setbits(b.w, 32, 32, p.texparam);
    setbits(b.w, 64, 13, p.texpal);
    setbits(b.w, 77, 4, p.v.size());
    setbits(b.w, 81, 4, d.vtop);
    setbits(b.w, 85, 4, d.vbot);
    setbits(b.w, 89, 8, d.ytop);
    setbits(b.w, 97, 8, d.ybot);
    setbits(b.w, 105, 1, p.facing);
    setbits(b.w, 106, 1, p.wbuffer);
    return b;
}

Beat vertex_beat(const Vtx& v)
{
    Beat b{1, {0, 0, 0, 0}};
    setbits(b.w, 0, 9, v.x);
    setbits(b.w, 9, 8, v.y);
    setbits(b.w, 17, 24, v.z);
    setbits(b.w, 41, 16, v.w);
    setbits(b.w, 57, 9, v.r);
    setbits(b.w, 66, 9, v.g);
    setbits(b.w, 75, 9, v.b);
    setbits(b.w, 84, 16, (uint16_t)v.s);
    setbits(b.w, 100, 16, (uint16_t)v.t);
    return b;
}

uint32_t rtl_to_melon(uint32_t c)
{
    return (c & 63) | (((c >> 6) & 63) << 8) | (((c >> 12) & 63) << 16) | (((c >> 18) & 31) << 24);
}

struct RtlResult { Frame f; uint64_t cycles = 0; bool timeout = false; uint64_t pixels = 0;
                   uint64_t phase[8] = {}; uint64_t spans = 0, span_px = 0;
                   uint64_t lph[192][8] = {}; int lpy = 0; size_t pf_i = 0;   // --line-profile: phases per line (the front's ps_line_y)
                   uint64_t tw_n = 0, tw_sum = 0, tw_max = 0;    // texel requests: request to answer (clocks)
                   int late = 0, late_first = -1; int64_t late_max = 0; int spilled = 0; };

// --cache LAT: the core's texture and palette caches (nds_g3d_cache: direct
// mapped, 2^6 / 2^4 blocks of 32 bytes, an in-order queue, two cycles per
// lookup, a miss holds the queue head for the block) on one shared block port
// (one block in flight, texture first), LAT cycles from the request to the
// first of four beats. Timing only: the data still comes from the scene.
struct CacheModel
{
    int lw; std::vector<int64_t> tag; std::deque<std::pair<uint32_t, uint16_t>> q;
    int st = 0; int64_t t = 0;      // 0 idle, 1 look, 2 waiting for the port, 3 filling until t
    uint64_t misses = 0;
    bool pf = false; uint32_t pf_blk = 0; int64_t pf_t = 0;   // --cache-mif 2: the next miss's block in flight
    CacheModel(int l) : lw(l), tag(1 << l, -1) {}
};
static int g_cache_lat = -1, g_cache_tlw = 6, g_cache_fast = 0, g_cache_mif = 1;   // --cache-lw N, --cache-fast: one lookup a cycle

// --cache2: a model of candidate texture/palette caches (design study, not
// the RTL): --cache-ways 1|2 (LRU), --cache-mif N blocks in flight on the
// shared block port (the lookups ahead of the queue head, up to
// --cache-look entries, request their blocks), a request issued every
// --cache-occ clocks at most, the blocks returning in order LAT + 4 clocks
// after their request (plus 0..--cache-jitter, and --cache-stall P L: one
// in P a further L). Timing only, as --cache.
static int g_c2 = 0, g_c2_ways = 1, g_c2_occ = 4, g_c2_look = 8, g_c2_jit = 0, g_c2_sp = 0, g_c2_sl = 0;
// --lead L: the line ring as in the core: line y streams once it is at most L
// lines ahead of the line the display composes (the frame starts at line
// 215, LINE clocks a line); line y is late when its last pixel comes after
// its composition starts. Off (-1): the raster runs free.
static int g_lead = -1;
// --store-pace: the stream at nds_g3d_store's fetcher pace (idle cycles
// before a header, a vertex beat and the end-of-line beat; 0: one beat a clock)
static int g_sp_h = 0, g_sp_v = 0, g_sp_e = 0;
// --vbank V: the hybrid spill ring's policy: lines up to V may stream from
// the frame start (VBlank), any other line once it is at most --lead lines
// ahead of the display (the on-chip ring)
static int g_vbank = -1;
// --budget B: the spill ring's per-frame budget: a line more than 6 ahead of
// the display (spilled) streams only while fewer than B have this frame
static int g_budget = -1;
static const int64_t LINE = 4260;
struct Port2 { int64_t next_issue = 0, last_ret = 0; int inflight = 0; std::mt19937 rng{7}; };
struct Cache2
{
    int lw, ways; std::vector<int64_t> tag[2]; std::vector<uint8_t> lru;
    std::deque<std::pair<uint32_t, uint16_t>> q;
    struct Fl { uint32_t blk; int64_t ready; };
    std::deque<Fl> fl;                  // this cache's blocks in flight
    int st = 0; uint64_t misses = 0;
    Cache2(int l, int w) : lw(l), ways(w), lru(1 << l, 0) { tag[0].assign(1 << l, -1); tag[1].assign(1 << l, -1); }
    int line(uint32_t blk) const { return blk & ((1u << lw) - 1); }
    int64_t tg(uint32_t blk) const { return blk >> lw; }
    bool has(uint32_t blk) {
        int l = line(blk);
        for (int w = 0; w < ways; w++) if (tag[w][l] == tg(blk)) { lru[l] = !w; return true; }
        return false;
    }
    bool flying(uint32_t blk) const { for (auto& f : fl) if (f.blk == blk) return true; return false; }
    void install(uint32_t blk) { int l = line(blk); int w = ways == 1 ? 0 : lru[l]; tag[w][l] = tg(blk); lru[l] = !w; }
    bool issue(uint32_t blk, Port2& p, int64_t now, int mif) {
        if (p.inflight >= mif || now < p.next_issue) return false;
        int64_t lat = g_cache_lat + 4;
        if (g_c2_jit) lat += p.rng() % (unsigned)(g_c2_jit + 1);
        if (g_c2_sp && p.rng() % (unsigned)g_c2_sp == 0) lat += g_c2_sl;
        int64_t r = std::max(now + lat, p.last_ret + 4);
        p.last_ret = r; p.next_issue = now + g_c2_occ; p.inflight++;
        fl.push_back({blk, r}); misses++;
        return true;
    }
    // one cycle: blocks that arrived are installed; the head answers on a hit
    void step(bool& out, uint16_t& od, Port2& p, int64_t now, bool may_req) {
        out = false;
        while (!fl.empty() && fl.front().ready <= now) { install(fl.front().blk); fl.pop_front(); p.inflight--; }
        if (st == 0) { if (!q.empty()) st = 1; if (!(g_cache_fast && st == 1)) goto ahead; }
        {
            uint32_t blk = q.front().first >> 5;
            if (has(blk)) { out = true; od = q.front().second; q.pop_front(); st = 0; }
            else if (!flying(blk) && may_req) issue(blk, p, now, g_cache_mif);
        }
    ahead:
        if (!may_req) return;
        for (size_t i = 1; i < q.size() && i <= (size_t)g_c2_look; i++) {
            uint32_t b2 = q[i].first >> 5;
            if (!has(b2) && !flying(b2)) { issue(b2, p, now, g_cache_mif); break; }
        }
    }
};

RtlResult render_rtl(const Scene& sc, int maxlat, bool all_polys, uint32_t seed)
{
    RtlResult res;
    res.f.assign(256 * 192, 0xDEADBEEF);
    auto m = std::make_unique<Top>();
    std::mt19937 rng(seed);

    std::vector<PolyDerived> der;
    for (auto& p : sc.polys) der.push_back(derive(p));

    auto tick = [&]() {
        m->clk = 0; m->eval();
        m->clk = 1; m->eval();
        res.cycles++;
    };

    m->rst = 1; m->frame_start = 0; m->ps_valid = 0; m->tex_valid = 0; m->pal_valid = 0; m->tbl_we = 0;
    tick(); tick();
    m->rst = 0;
    m->dispcnt = sc.dispcnt & 0xFFFF;
    m->alpharef = sc.alpharef & 31;
    m->clear_attr1 = sc.clear_attr1;
    m->clear_depth = sc.clear_attr2 & 0x7FFF;
    m->fog_color = sc.fog_color & 0x1F7FFF;
    m->fog_offset = sc.fog_offset & 0x7FFF;
    auto tbl = [&](int sel, int addr, int data) {
        m->tbl_we = 1; m->tbl_sel = sel; m->tbl_addr = addr; m->tbl_data = data; tick(); m->tbl_we = 0;
    };
    for (int i = 0; i < 32; i++) tbl(0, i, sc.toon[i] & 0x7FFF);
    for (int i = 0; i < 8; i++) tbl(1, i, sc.edge[i] & 0x7FFF);
    for (int i = 0; i < 32; i++) tbl(2, i, sc.fog_table[i] & 0x7F);
    res.cycles = 0;

    m->frame_start = 1; tick(); m->frame_start = 0;

    std::deque<Beat> q;
    struct Pending { uint64_t at; uint16_t data; };
    std::deque<Pending> texq, palq;
    CacheModel ctex(g_cache_tlw), cpal(4);
    Cache2 c2tex(g_cache_tlw, g_c2_ways), c2pal(4, 1);
    std::deque<uint64_t> tw_at;
    Port2 port2;
    struct RBlk { int64_t at; uint32_t blk; bool pal; int k; };
    std::deque<RBlk> rb;                        // RCACHE: blocks accepted on the port, in order
    uint64_t rc_tmiss = 0, rc_pmiss = 0;
    std::deque<std::pair<int, int64_t>> lreq;   // --lead: lines asked for, and when they may stream
    std::vector<int64_t> lastpx(192, -1);
    bool port_busy = false;
    // one cycle of a cache: returns true (and the data) when it answers
    auto cstep = [&](CacheModel& c, bool& out, uint16_t& od, bool may_req) {
        out = false;
        switch (c.st) {
        case 0: if (!c.q.empty()) c.st = 1; if (!(g_cache_fast && c.st == 1)) break; [[fallthrough]];
        case 1: {
            uint32_t a = c.q.front().first, line = (a >> 5) & ((1u << c.lw) - 1);
            if (c.tag[line] == (int64_t)(a >> (5 + c.lw))) { out = true; od = c.q.front().second; c.q.pop_front(); c.st = 0; }
            else if (c.pf && c.pf_blk == (a >> 5)) { c.st = 4; }      // its block is already on the way
            else c.st = 2;
            break; }
        case 2: if (may_req && !port_busy) { port_busy = true; c.st = 3; c.t = res.cycles + g_cache_lat + 4; c.misses++; } break;
        case 3: if (res.cycles >= c.t) { uint32_t a = c.q.front().first; c.tag[(a >> 5) & ((1u << c.lw) - 1)] = a >> (5 + c.lw);
                                          port_busy = false; c.st = 0; } break;
        case 4: if (res.cycles >= c.pf_t) { uint32_t a = c.q.front().first; c.tag[(a >> 5) & ((1u << c.lw) - 1)] = a >> (5 + c.lw);
                                             c.pf = false; c.st = 0; } break;
        }
        // a second miss in flight: while the head fills, the next entry's
        // block (another line) is requested; its beats follow the head's
        if (g_cache_mif > 1 && c.st == 3 && !c.pf && c.q.size() > 1) {
            uint32_t h = c.q.front().first, a = c.q[1].first;
            uint32_t lh = (h >> 5) & ((1u << c.lw) - 1), l1 = (a >> 5) & ((1u << c.lw) - 1);
            if ((a >> 5) != (h >> 5) && l1 != lh && c.tag[l1] != (int64_t)(a >> (5 + c.lw))) {
                c.pf = true; c.pf_blk = a >> 5; c.pf_t = std::max<int64_t>(res.cycles + g_cache_lat + 4, c.t + 4); c.misses++;
            }
        }
    };
    const uint64_t limit = 400000000ull;
    bool done = false;
    int sp_gap = -1;                     // --store-pace: idle cycles left before the head beat (-1: not set yet)
    while (!done && res.cycles < limit)
    {
        // drive inputs for this cycle
        if (!q.empty() && sp_gap < 0) {
            int t = q.front().type;
            sp_gap = t == 0 ? g_sp_h : t == 1 ? g_sp_v : g_sp_e;
        }
        m->ps_valid = !q.empty() && sp_gap <= 0;
        if (!q.empty())
        {
            m->ps_type = q.front().type;
            for (int i = 0; i < 4; i++) m->ps_data[i] = q.front().w[i];
        }
#ifdef RCACHE
        // the block port: beats of the blocks accepted so far, in order
        m->t_ack = 0; m->t_rvalid = 0;
        if (!rb.empty() && rb.front().at <= (int64_t)res.cycles) {
            RBlk& b = rb.front();
            uint64_t w = 0;
            for (int i = 7; i >= 0; i--) {
                uint32_t a = (b.blk << 5) + 8 * b.k + i;
                w = w << 8 | (b.pal ? sc.pal[a & 0x1FFFF] : sc.tex[a & 0x7FFFF]);
            }
            m->t_rvalid = 1; m->t_rdata = w;
            if (++b.k == 4) { rb.pop_front(); port2.inflight--; }
        }
#else
        m->tex_valid = 0; m->pal_valid = 0;
        if (g_c2) {
            bool o; uint16_t d;
            c2tex.step(o, d, port2, res.cycles, true); if (o) { m->tex_valid = 1; m->tex_data = d;
                uint64_t w = res.cycles - tw_at.front(); tw_at.pop_front(); res.tw_n++; res.tw_sum += w; res.tw_max = std::max(res.tw_max, w); }
            c2pal.step(o, d, port2, res.cycles, true); if (o) { m->pal_valid = 1; m->pal_data = d; }
        } else
        if (g_cache_lat >= 0) {
            bool o; uint16_t d;
            cstep(ctex, o, d, true); if (o) { m->tex_valid = 1; m->tex_data = d; }
            cstep(cpal, o, d, ctex.st != 2); if (o) { m->pal_valid = 1; m->pal_data = d; }
        } else
        if (!texq.empty() && texq.front().at <= res.cycles) { m->tex_valid = 1; m->tex_data = texq.front().data; texq.pop_front(); }
        if (g_cache_lat < 0 && !palq.empty() && palq.front().at <= res.cycles) { m->pal_valid = 1; m->pal_data = palq.front().data; palq.pop_front(); }
#endif
        m->clk = 0; m->eval();
#ifdef RCACHE
        if (m->t_req && (int64_t)res.cycles >= port2.next_issue) {
            int64_t lat = g_cache_lat;
            if (g_c2_jit) lat += port2.rng() % (unsigned)(g_c2_jit + 1);
            if (g_c2_sp && port2.rng() % (unsigned)g_c2_sp == 0) lat += g_c2_sl;
            int64_t at = std::max<int64_t>(res.cycles + lat, port2.last_ret + 4);
            port2.last_ret = at; port2.next_issue = res.cycles + g_c2_occ; port2.inflight++;
            bool pal = (m->t_blk >> 15) == 6;
            rb.push_back({at, m->t_blk & 0x3FFFu, pal, 0});
            (pal ? rc_pmiss : rc_tmiss)++;
            m->t_ack = 1; m->eval();
        }
        if (m->tex_valid) { uint64_t w = res.cycles - tw_at.front(); tw_at.pop_front(); res.tw_n++; res.tw_sum += w; res.tw_max = std::max(res.tw_max, w); }
        if (m->tex_req) tw_at.push_back(res.cycles);
        if (m->tex_req && getenv("TEXTRACE")) { static FILE* tf = fopen(getenv("TEXTRACE"), "w"); fprintf(tf, "%x\n", (unsigned)m->tex_addr); }
        // PFTRACE=FILE PFN=N (g3d_rc PF=1): an ideal prefetcher, the texel N requests
        // ahead of each request (from the same scene's TEXTRACE) as a hint
        {
            static std::vector<uint32_t> pft; static int pfn = -1;
            if (pfn < 0) { pfn = getenv("PFN") ? atoi(getenv("PFN")) : 0;
                           if (FILE* f = getenv("PFTRACE") ? fopen(getenv("PFTRACE"), "r") : nullptr) { unsigned x; while (fscanf(f, "%x", &x) == 1) pft.push_back(x); fclose(f); } }
            m->pf_v = 0;
            if (m->tex_req && pfn > 0 && res.pf_i + pfn < pft.size()) { m->pf_v = 1; m->pf_a = pft[res.pf_i + pfn]; }
            if (m->tex_req) res.pf_i++;
        }
#endif
        bool accept = m->ps_valid && m->ps_ready;
        res.phase[m->dbg_phase & 7]++;
        if (m->ps_line_req) res.lpy = m->ps_line_y;
        if (res.lpy < 192) res.lph[res.lpy][m->dbg_phase & 7]++;
        res.spans += m->dbg_span;
        res.span_px += m->dbg_pixel;
        m->clk = 1; m->eval();
        res.cycles++;
        if (accept) { q.pop_front(); sp_gap = -1; }
        else if (!q.empty() && sp_gap > 0) sp_gap--;

        if (m->ps_line_req)
            lreq.push_back({m->ps_line_y, g_lead < 0 || (g_vbank >= 0 && m->ps_line_y <= g_vbank) ? 0 : (48 + (int64_t)m->ps_line_y - g_lead) * LINE});
        bool go = !lreq.empty() && lreq.front().second <= (int64_t)res.cycles;
        if (go && g_budget >= 0) {
            int64_t d = (int64_t)res.cycles / LINE - 48;      // the line the display composes
            int y = lreq.front().first;
            if (y > d + 6) { if (res.spilled < g_budget) res.spilled++; else go = false; }
        }
        if (go)
        {
            int y = lreq.front().first;
            lreq.pop_front();
            for (size_t i = 0; i < sc.polys.size(); i++)
            {
                const PolyDerived& d = der[i];
                if (d.degenerate) continue;
                bool covers = y >= d.ytop && (y < d.ybot || (y == d.ytop && d.ybot == d.ytop));
                if (!covers && !all_polys) continue;
                q.push_back(header_beat(sc.polys[i], d));
                for (const Vtx& v : sc.polys[i].v) q.push_back(vertex_beat(v));
            }
            q.push_back(Beat{3, {0, 0, 0, 0}});
        }
#ifndef RCACHE
        int lat = maxlat ? std::uniform_int_distribution<int>(0, maxlat)(rng) : 0;
        if (g_c2) {
            if (m->tex_req) { uint32_t a = m->tex_addr & 0x7FFFE; c2tex.q.push_back({a, (uint16_t)(sc.tex[a] | (sc.tex[a + 1] << 8))}); tw_at.push_back(res.cycles); }
            if (m->pal_req) { uint32_t a = m->pal_addr & 0x1FFFE; c2pal.q.push_back({a, (uint16_t)(sc.pal[a] | (sc.pal[a + 1] << 8))}); }
        } else
        if (g_cache_lat >= 0) {
            if (m->tex_req) { uint32_t a = m->tex_addr & 0x7FFFE; ctex.q.push_back({a, (uint16_t)(sc.tex[a] | (sc.tex[a + 1] << 8))}); }
            if (m->pal_req) { uint32_t a = m->pal_addr & 0x1FFFE; cpal.q.push_back({a, (uint16_t)(sc.pal[a] | (sc.pal[a + 1] << 8))}); }
        } else
        if (m->tex_req)
        {
            uint32_t a = m->tex_addr & 0x7FFFE;
            texq.push_back({res.cycles + lat, (uint16_t)(sc.tex[a] | (sc.tex[a + 1] << 8))});
        }
        if (g_cache_lat < 0 && m->pal_req)
        {
            uint32_t a = m->pal_addr & 0x1FFFE;
            palq.push_back({res.cycles + lat, (uint16_t)(sc.pal[a] | (sc.pal[a + 1] << 8))});
        }
#endif
        if (m->px_valid)
        {
            res.f[m->px_y * 256 + m->px_x] = rtl_to_melon(m->px_color);
            if (m->px_y < 192) lastpx[m->px_y] = res.cycles;
            res.pixels++;
        }
        if (m->frame_done) done = true;
    }
    if (g_cache_lat >= 0) printf("     cache: texture misses %llu, palette misses %llu\n", (unsigned long long)ctex.misses, (unsigned long long)cpal.misses);
#ifdef RCACHE
    printf("     rcache: texture misses %llu, palette misses %llu\n", (unsigned long long)rc_tmiss, (unsigned long long)rc_pmiss);
#endif
    if (g_c2) printf("     cache2: texture misses %llu, palette misses %llu\n", (unsigned long long)c2tex.misses, (unsigned long long)c2pal.misses);
    for (int y = 0; y < 192; y++) {
        int64_t dl = (48 + (int64_t)y) * LINE;
        if (lastpx[y] > dl) { if (res.late_first < 0) res.late_first = y; res.late++; res.late_max = std::max(res.late_max, lastpx[y] - dl); }
    }
    res.timeout = !done;
    m->final();
    return res;
}

void write_ppm(const std::string& path, const Frame& f)
{
    FILE* o = fopen(path.c_str(), "wb");
    if (!o) return;
    fprintf(o, "P6 256 192 255\n");
    for (uint32_t p : f)
    {
        unsigned char c[3] = {(unsigned char)((p & 63) << 2), (unsigned char)(((p >> 8) & 63) << 2),
                              (unsigned char)(((p >> 16) & 63) << 2)};
        fwrite(c, 3, 1, o);
    }
    fclose(o);
}

} // namespace

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    std::string only, outdir = "build/gpu3d", dumpdir;
    std::vector<std::string> files;
    int maxlat = 3;
    bool all_polys = false, profile = false, line_profile = false;
    std::string feat_off;   // --feat-off aa,toon,fog,atest,edge,shadow,lower: the raster was built with those FEAT_* = 0
    int nrandom = 0;
    uint32_t seed0 = 100;
    for (int i = 1; i < argc; i++)
    {
        std::string a = argv[i];
        if (a == "--only" && i + 1 < argc) only = argv[++i];
        else if (a == "--scene" && i + 1 < argc) files.push_back(argv[++i]);
        else if (a == "--lat" && i + 1 < argc) maxlat = atoi(argv[++i]);
        else if (a == "--all-polys") all_polys = true;
        else if (a == "--profile") profile = true;
        else if (a == "--line-profile") line_profile = true;
        else if (a == "--feat-off" && i + 1 < argc) feat_off = argv[++i];
        else if (a == "--cache" && i + 1 < argc) g_cache_lat = atoi(argv[++i]);
        else if (a == "--cache-lw" && i + 1 < argc) g_cache_tlw = atoi(argv[++i]);
        else if (a == "--cache-fast") g_cache_fast = 1;
        else if (a == "--cache-mif" && i + 1 < argc) g_cache_mif = atoi(argv[++i]);
        else if (a == "--cache2") { g_c2 = 1; if (g_cache_lat < 0) g_cache_lat = 20; }
        else if (a == "--cache-ways" && i + 1 < argc) g_c2_ways = atoi(argv[++i]);
        else if (a == "--cache-occ" && i + 1 < argc) g_c2_occ = atoi(argv[++i]);
        else if (a == "--cache-look" && i + 1 < argc) g_c2_look = atoi(argv[++i]);
        else if (a == "--cache-jitter" && i + 1 < argc) g_c2_jit = atoi(argv[++i]);
        else if (a == "--cache-stall" && i + 2 < argc) { g_c2_sp = atoi(argv[++i]); g_c2_sl = atoi(argv[++i]); }
        else if (a == "--lead" && i + 1 < argc) g_lead = atoi(argv[++i]);
        else if (a == "--store-pace" && i + 3 < argc) { g_sp_h = atoi(argv[++i]); g_sp_v = atoi(argv[++i]); g_sp_e = atoi(argv[++i]); }
        else if (a == "--vbank" && i + 1 < argc) g_vbank = atoi(argv[++i]);
        else if (a == "--budget" && i + 1 < argc) g_budget = atoi(argv[++i]);
        else if (a == "--out" && i + 1 < argc) outdir = argv[++i];
        else if (a == "--dump-scenes" && i + 1 < argc) dumpdir = argv[++i];
        else if (a == "--random" && i + 1 < argc) nrandom = atoi(argv[++i]);
        else if (a == "--seed" && i + 1 < argc) seed0 = strtoul(argv[++i], nullptr, 0);
    }

    std::vector<Scene> scenes;
    if (nrandom)
        for (int i = 0; i < nrandom; i++) scenes.push_back(random_mix_scene(seed0 + i));
    else if (files.empty()) scenes = builtin_scenes();
    for (auto& f : files)
    {
        Scene sc;
        if (!load_scene(sc, f)) { fprintf(stderr, "cannot load scene %s\n", f.c_str()); return 2; }
        // dir/f01234.scn -> dir_f01234, so failure images land flat in --out
        std::string n = f.substr(0, f.rfind('.') == std::string::npos || f.rfind('.') < f.rfind('/') + 1 ? f.size() : f.rfind('.'));
        size_t s1 = n.rfind('/'), s0 = s1 == std::string::npos || s1 == 0 ? std::string::npos : n.rfind('/', s1 - 1);
        sc.name = s0 == std::string::npos ? n : n.substr(s0 + 1);
        for (char& c : sc.name) if (c == '/') c = '_';
        scenes.push_back(std::move(sc));
    }
    if (!dumpdir.empty())
    {
        for (auto& sc : scenes) save_scene(sc, dumpdir + "/" + sc.name + ".g3d");
        printf("wrote %zu scenes to %s\n", scenes.size(), dumpdir.c_str());
        return 0;
    }

    int fails = 0, run = 0;
    for (size_t si = 0; si < scenes.size(); si++)
    {
        const Scene& sc = scenes[si];
        if (!only.empty() && sc.name != only) continue;
        run++;
        Frame g;
        if (!feat_off.empty())
        {
            // the golden renders the scene with the switched-off features
            // disabled, as the raster built with those FEAT_* = 0 must draw it
            auto off = [&](const char* f) { return feat_off.find(f) != std::string::npos; };
            Scene f = sc;
            if (off("aa"))     f.dispcnt &= ~0x10u;
            if (off("edge"))   f.dispcnt &= ~0x20u;
            if (off("fog"))    f.dispcnt &= ~0xC0u;
            if (off("atest"))  f.alpharef = 0;
            f.polys.clear();
            for (auto p : sc.polys)
            {
                uint32_t mode = (p.attr >> 4) & 3;
                if (off("shadow") && mode == 3) continue;
                if (off("toon") && mode == 2) p.attr &= ~0x30u;
                f.polys.push_back(p);
            }
            golden_set_nolower(off("lower"));
            g = render_golden(f);
            golden_set_nolower(false);
        }
        else g = render_golden(sc);
        RtlResult r = render_rtl(sc, maxlat, all_polys, 1234 + si);
        int bad = 0;
        for (int i = 0; i < 256 * 192; i++)
            if (g[i] != r.f[i])
            {
                if (bad < 8)
                    printf("  %s: (%d,%d) golden %08x rtl %08x\n", sc.name.c_str(), i % 256, i / 256, g[i], r.f[i]);
                bad++;
            }
        size_t npolys = 0;
        for (auto& p : sc.polys) npolys += !derive(p).degenerate;
        printf("%-4s %-20s polys %4zu  cycles %9llu  %s%d px differ\n", bad || r.timeout ? "FAIL" : "ok",
               sc.name.c_str(), npolys, (unsigned long long)r.cycles, r.timeout ? "TIMEOUT " : "", bad);
        if (g_lead >= 0 || g_c2)
            printf("     late lines %d (first %d, worst by %lld clk) spilled %d\n", r.late, r.late_first, (long long)r.late_max, r.spilled);
        if (profile)
            printf("     spans %6llu  span pixels %7llu | cycles: clear %llu stream %llu edge %llu span %llu pixel %llu final %llu\n",
                   (unsigned long long)r.spans, (unsigned long long)r.span_px,
                   (unsigned long long)r.phase[1], (unsigned long long)r.phase[2], (unsigned long long)r.phase[3],
                   (unsigned long long)r.phase[4], (unsigned long long)r.phase[5], (unsigned long long)r.phase[6]);
        if (line_profile)
            for (int y = 0; y < 192; y += 8) {
                printf("     lines %3d-%3d:", y, y + 7);
                for (int k = 2; k <= 6; k++) { uint64_t t = 0; for (int j = y; j < y + 8; j++) t += r.lph[j][k]; printf(" %c %6llu", "  sepf  "[k], (unsigned long long)(t / 8)); }
                printf("  (per line: stream edge span pixel final)\n");
            }
        if (profile && r.tw_n)
            printf("     texel wait %.2f (max %llu) over %llu requests\n", (double)r.tw_sum / r.tw_n, (unsigned long long)r.tw_max, (unsigned long long)r.tw_n);
        if (bad || r.timeout)
        {
            fails++;
            Frame d(256 * 192);
            for (int i = 0; i < 256 * 192; i++) d[i] = g[i] == r.f[i] ? 0 : 0x003F3F3F;
            write_ppm(outdir + "/" + sc.name + "_golden.ppm", g);
            write_ppm(outdir + "/" + sc.name + "_rtl.ppm", r.f);
            write_ppm(outdir + "/" + sc.name + "_diff.ppm", d);
        }
    }
    printf("%d/%d scenes pixel-exact\n", run - fails, run);
    return fails ? 1 : 0;
}
