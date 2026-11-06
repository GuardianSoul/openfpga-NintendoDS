// Sound engine testbench (docs/sound.md): runs rtl/sound against melonDS's
// SPU, output step by output step, and diffs every 16-bit output pair, the
// capture writes and the SOUNDxCNT reads.
//   Vsound [--synthetic] [--fuzz N] [--trace FILE]... [--only SUBSTR]
//          [--lat N] [--jitter N] [--steps N] [--seed N] [--verbose] [--ce-half]
// Synthetic tests and fuzz seeds start both models from reset. Census traces
// (sim/sound/spu_trace.h) start both from the trace's snapshot; register
// writes are replayed, and sample fetches are answered from the trace in
// order, so the RTL also has to issue melonDS's fetches in melonDS's order.
// Memory answers each read --lat (+0..--jitter) clocks after accepting it.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <deque>
#include <functional>
#include <map>
#include <random>
#include <string>
#include <vector>
#include "Vsound.h"
#include "Vsound___024root.h"
#include "verilated.h"
#include "golden_snd.h"
#include "spu_trace.h"

using u8 = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using u64 = uint64_t;
using s16 = int16_t;
using s32 = int32_t;
using s64 = int64_t;

static const int STEP_CLOCKS = 1024;     // 33.51 MHz / 32,728 Hz
static int g_lat = 24, g_jitter = 8;
static bool g_cehalf = false;              // --ce-half: a ce-low clock after every clock
// --ce-check (implies --ce-half): the whole model state (every flop and RAM
// word of the engine) must be byte-identical across each ce-low clock edge,
// the premise of build_ds.sh's two-cycle constraint inside u_snd
static bool g_cecheck = false;
static unsigned long long g_ce_bad = 0, g_ce_edges = 0;
static bool g_verbose = false;
static int g_watch = -1;
static u32 g_watch_from = 0;

// ---------------------------------------------------------------- memory
struct Mem
{
    std::vector<u8> main = std::vector<u8>(4 << 20), wram = std::vector<u8>(64 << 10);
    u8* ptr(u32 a)
    {
        switch (a >> 24)
        {
        case 0x02: return &main[a & 0x3FFFFC];
        case 0x03: return &wram[a & 0xFFFC];
        default: return nullptr;
        }
    }
    u32 rd(u32 a) { u8* p = ptr(a); u32 v = 0; if (p) memcpy(&v, p, 4); return v; }
    void wr(u32 a, u32 v) { u8* p = ptr(a); if (p) memcpy(p, &v, 4); }
};

// Bits of a Verilator wide word (VlWide: 32-bit words, least significant first)
template <typename W> static void wset(W& w, int lsb, int width, u64 v)
{
    for (int b = 0; b < width; b++)
    {
        u32& word = w[(lsb + b) / 32];
        u32 m = 1u << ((lsb + b) % 32);
        word = ((v >> b) & 1) ? (word | m) : (word & ~m);
    }
}
template <typename W> static u64 wget(const W& w, int lsb, int width)
{
    u64 v = 0;
    for (int b = 0; b < width; b++) v |= (u64)((w[(lsb + b) / 32] >> ((lsb + b) % 32)) & 1) << b;
    return v;
}

// ---------------------------------------------------------------- RTL wrapper
struct Rtl
{
    Vsound* m = new Vsound;
    u64 cyc = 0;
    std::mt19937 rng{1};
    std::function<u32(u32)> fetch;              // byte address -> word
    std::function<void(u32, u32)> capw;         // capture write
    struct Resp { u64 at; u32 data; };
    std::deque<Resp> resp;
    u64 reads = 0, max_busy = 0, busy_sum = 0, steps = 0, late = 0;   // late: busy > 1,024 clocks
    u64 reg_n = 0, reg_sum = 0, reg_max = 0;   // ARM7 register accesses: clocks to the ack
    u64 ent_max = 0, last_bound = 0; bool in_bound = false, seen_bound = false;
    bool power = true;

    Rtl()
    {
        m->clk = 0; m->ce = 1; m->rst = 1; m->tick = 0; m->power = 1; m->reg_req = 0;
        m->mem_ack = 0; m->mem_rvalid = 0;
        m->eval();
        for (int i = 0; i < 4; i++) clock();
        m->rst = 0;
        for (int i = 0; i < 300; i++) clock();  // state RAM clear
    }
    ~Rtl() { m->final(); delete m; }

    void clock()
    {
        m->clk = 0;
        m->power = power;
        // memory model: accept every request; reads answer in order after the latency
        m->mem_ack = m->mem_req;
        m->mem_rvalid = !resp.empty() && resp.front().at <= cyc;
        m->mem_rdata = m->mem_rvalid ? resp.front().data : 0;
        m->eval();
        bool req = m->mem_req, we = m->mem_we, rv = m->mem_rvalid;
        u32 addr = m->mem_addr << 2, wd = m->mem_wdata;
        m->clk = 1; m->eval();
        if (g_cehalf)
        {
            // the engine at half rate: a second clock edge with ce low must change nothing
            m->clk = 0; m->ce = 0; m->eval();
            static std::vector<unsigned char> before(sizeof(Vsound___024root));
            if (g_cecheck) memcpy(before.data(), (const void*)m->rootp, sizeof(Vsound___024root));
            m->clk = 1; m->eval();
            if (g_cecheck) {
                m->clk = 0; m->eval();          // back to the same inputs: only state can differ
                g_ce_edges++;
                if (memcmp(before.data(), (const void*)m->rootp, sizeof(Vsound___024root)) != 0) {
                    if (g_ce_bad++ < 3) {
                        const unsigned char* a = before.data(); const unsigned char* b = (const unsigned char*)m->rootp;
                        size_t i = 0; while (a[i] == b[i]) i++;
                        printf("  ce check: state changed on a ce-low edge (cycle %llu, byte %zu of %zu)\n",
                               (unsigned long long)cyc, i, sizeof(Vsound___024root));
                    }
                }
            }
            m->ce = 1;
        }
        cyc++;
        {   // the longest stretch between entry boundaries (S_BOUND = 2): an ARM7 access's worst wait
            bool b = m->rootp->sound__DOT__st == 2;
            if (b && !in_bound) { if (seen_bound) ent_max = std::max<u64>(ent_max, cyc - last_bound); seen_bound = true; }
            if (b) last_bound = cyc;
            if (m->rootp->sound__DOT__st == 1) seen_bound = false;   // S_IDLE: between steps
            in_bound = b;
        }
        if (rv) resp.pop_front();
        if (req)
        {
            if (we) capw(addr, wd);
            else
            {
                u64 at = std::max<u64>(cyc + g_lat + (g_jitter ? rng() % (g_jitter + 1) : 0),
                                       resp.empty() ? 0 : resp.back().at);
                resp.push_back({at, fetch(addr)});
                reads++;
            }
        }
    }

    u32 reg(bool we, int bits, u32 addr, u32 val)
    {
        m->reg_req = 1; m->reg_we = we; m->reg_size = bits == 8 ? 0 : bits == 16 ? 1 : 2;
        m->reg_addr = addr - 0x04000400;
        m->reg_wdata = bits == 32 ? val : val << ((addr & (bits == 8 ? 3 : 2)) * 8);   // byte lanes
        for (int i = 0; i < 4000; i++)
        {
            clock();
            if (m->reg_ack)
            {
                reg_n++; reg_sum += i + 1; reg_max = std::max<u64>(reg_max, i + 1);   // clocks to the ack
                m->reg_req = 0;
                u32 v = m->reg_rdata >> ((addr & 3) * 8);
                return bits == 32 ? v : bits == 16 ? v & 0xFFFF : v & 0xFF;
            }
        }
        fprintf(stderr, "register access %08X timed out\n", addr);
        exit(3);
    }

    // One output step: tick, wait for the output. Returns false on timeout.
    bool step(s16 out[2], u64& t0)
    {
        t0 = cyc;
        m->tick = 1; clock(); m->tick = 0;
        for (int i = 0; i < 20000; i++)
        {
            if (m->out_valid) break;
            clock();
        }
        if (!m->out_valid) return false;
        out[0] = (s16)m->out_l; out[1] = (s16)m->out_r;
        u64 busy = cyc - t0;
        max_busy = std::max(max_busy, busy); busy_sum += busy; steps++;
        if (busy > STEP_CLOCKS) late++;
        return true;
    }
    void pad(u64 t0) { while (cyc - t0 < STEP_CLOCKS) clock(); }

    // Backdoor state load (census snapshots)
    void load(const spu::Snap& sn, int skip[2]);
};

void Rtl::load(const spu::Snap& sn, int skip[2])
{
    auto& r = *m->rootp;
    auto& cram = r.sound__DOT__u_cpu__DOT__mem;   // word k of entry e at k*32 + e
    auto& run = r.sound__DOT__u_run__DOT__mem;   // row e: w4-w7 (40 bits each)
    auto& cb = r.sound__DOT__g_cb__DOT__u_cb__DOT__mem;     // capture buffers: 4u + word
    auto& ff = r.sound__DOT__u_fifo__DOT__mem;
    auto& tg = r.sound__DOT__u_tag__DOT__mem;
    for (int i = 0; i < 16; i++)
    {
        const spu::ChanSnap& c = sn.ch[i];
        u32 fmt = (c.cnt >> 29) & 3;
        bool noise = fmt == 3 && i >= 14;
        // the RTL counts nibbles: a sample is 2 (PCM8), 4 (PCM16) or 1
        s64 pos = (s64)c.pos * (fmt == 0 ? 2 : fmt == 1 ? 4 : 1);
        if (fmt != 3 && pos > 0x1FFFFFC) pos = 0x1FFFFFC;
        s32 level = (s32)c.level;
        s32 lev7 = std::clamp(level, -32, 63);
        u32 wabs = level >= 0 ? (c.rp + level) / 4 : c.wp;
        u32 wlap = level >= 0 ? (wabs / 8) & 3 : 0;
        if (level >= 0 && ((c.rp + level) % 4 || wabs % 8 != c.wp))
            fprintf(stderr, "warning: channel %d FIFO rp %u level %d wp %u inconsistent\n", i, c.rp, level, c.wp);
        u64 w[8];
        w[0] = c.cnt & 0xFF7F837Fu;
        if (c.cnt >> 31) r.sound__DOT__busy |= 1u << i;
        if (c.keyon) r.sound__DOT__keyon |= 1u << i;
        w[1] = c.srcaddr;
        w[2] = (c.timerreload & 0xFFFF) | (u64)((c.looppos >> 2) & 0xFFFF) << 16;
        w[3] = (c.length >> 2) & 0x1FFFFF;
        w[4] = (c.timer & 0xFFFF) | (u64)(u16)c.cursample << 16 | (u64)(c.adpcmindexloop & 0x7F) << 32;
        w[5] = ((u32)pos & 0x3FFFFFF) | (u64)(c.rp & 31) << 26 | (u64)(wabs & 7) << 31 | (u64)wlap << 36 |
               (u64)((c.timer >> 16) & 1) << 38;
        w[6] = ((c.roff >> 2) & 0x3FFFFF) | (u64)(lev7 & 0x7F) << 22 | (u64)(c.adpcmcurbyte & 0xFF) << 29;
        w[7] = ((noise ? c.noise : c.adpcmval) & 0xFFFF) | (u64)(c.adpcmindex & 0x7F) << 16 |
               (u64)(c.adpcmvalloop & 0xFFFF) << 24;
        for (int k = 0; k < 4; k++) { cram[k * 32 + i] = (u32)w[k]; wset(run[i], k * 40, 40, w[k + 4]); }
        // FIFO words in [rp, rp + level) belong to read lap 0 (and 1 after a wrap)
        for (int k = 0; k < 8; k++) { ff[i * 8 + k] = c.fifo[k]; tg[i * 8 + k] = 3; }
        if (level > 0)
            for (u32 k = c.rp / 4; k < wabs; k++) tg[i * 8 + (k & 7)] = (k / 8) & 3;
    }
    for (int u = 0; u < 2; u++)
    {
        const spu::CapSnap& c = sn.cap[u];
        u32 len = std::max<u32>(1, c.length >> 2);
        // complete words waiting in melonDS's FIFO go to the RTL's buffer
        u32 partial = c.wp & 3, complete = (c.level - partial) / 4;
        skip[u] = 0;
        // position in bytes (8-bit) or halfwords (16-bit); waiting words and
        // the byte in the word follow from it
        u32 pos = (u32)c.pos * 2;   // nibbles
        if (complete != ((pos >> 3) & 3) && (c.cnt & 0x80))
            fprintf(stderr, "warning: capture %d FIFO level %u does not follow its position %d\n", u, c.level, c.pos);
        u64 w[8] = {0, c.dstaddr, c.timerreload & 0xFFFF, (c.length >> 2) & 0xFFFF,
                    c.timer & 0xFFFF, (pos & 0x3FFFFFF) | (u64)((c.timer >> 16) & 1) << 38, (c.woff / 4) % len, 0};
        for (int k = 0; k < 4; k++) { cram[k * 32 + 16 + u] = (u32)w[k]; wset(run[16 + u], k * 40, 40, w[k + 4]); }
        for (u32 k = 0; k < complete && k < 4; k++) cb[u * 4 + k] = c.fifo[(c.rp + k) & 3];
        if (partial) cb[u * 4 + (complete & 3)] = c.fifo[(c.wp >> 2) & 3];   // the word being built
    }
    r.sound__DOT__soundcnt = sn.cnt & 0xBF7F;   // busy/keyon were set above
    r.sound__DOT__bias = sn.bias & 0x3FF;
    r.sound__DOT__capcnt0 = sn.cap[0].cnt;
    r.sound__DOT__capcnt1 = sn.cap[1].cnt;
    power = !sn.mute;
}

// ---------------------------------------------------------------- synthetic runs
struct Write { u32 step; int bits; u32 addr, val; };
struct Scenario
{
    std::string name;
    u32 steps = 2000;
    std::vector<Write> w;               // addr 0x04000304 = POWCNT2
    std::function<void(Mem&)> init;
    bool cap_feedback = false;          // channels read capture buffers
};

static const u32 SND = 0x04000400;
static u32 CH(int n, u32 off) { return SND + n * 16 + off; }

struct Builder
{
    Scenario s;
    u32 t = 0;
    Builder(const std::string& n, u32 steps) { s.name = n; s.steps = steps; }
    void at(u32 step) { t = step; }
    void w8(u32 a, u32 v) { s.w.push_back({t, 8, a, v}); }
    void w16(u32 a, u32 v) { s.w.push_back({t, 16, a, v}); }
    void w32(u32 a, u32 v) { s.w.push_back({t, 32, a, v}); }
    void power(u32 v) { s.w.push_back({t, 0, 0x04000304, v}); }
    // channel setup: cnt without the start bit, then start
    void chan(int n, u32 src, u16 tmr, u16 pnt, u32 len, u32 cnt)
    {
        w32(CH(n, 4), src); w32(CH(n, 8), tmr | (u32)pnt << 16); w32(CH(n, 12), len);
        w32(CH(n, 0), cnt);
    }
};

static u32 cntv(int vol, int div, int pan, int duty, int rep, int fmt, bool start, bool hold = false)
{
    return (vol & 0x7F) | (div & 3) << 8 | (hold ? 1u << 15 : 0) | (pan & 0x7F) << 16 | (duty & 7) << 24 |
           (rep & 3) << 27 | (fmt & 3) << 29 | (start ? 1u << 31 : 0);
}

static void fill_random(Mem& m, u32 addr, u32 bytes, u32 seed)
{
    std::mt19937 r(seed);
    for (u32 i = 0; i < bytes; i += 4) m.wr(addr + i, r());
}

// IMA-ADPCM block: header (value, index) + random nibbles
static void adpcm_block(Mem& m, u32 addr, u32 words, s16 v, u32 idx, u32 seed)
{
    m.wr(addr, (u16)v | idx << 16);
    fill_random(m, addr + 4, (words - 1) * 4, seed);
}

static std::vector<Scenario> synthetic()
{
    std::vector<Scenario> out;
    const u32 A = 0x02100000, B = 0x02200000, C = 0x02300000;
    auto mem_std = [=](Mem& m) {
        fill_random(m, A, 0x10000, 1);
        fill_random(m, B, 0x10000, 2);
        adpcm_block(m, C, 0x1000, 1234, 20, 3);
        adpcm_block(m, C + 0x8000, 0x400, -32768, 100, 4);
    };
    {
        Builder b("pcm8-loop-vol-pan", 3000);
        b.w16(SND + 0x100, 0x807F); b.w16(SND + 0x104, 0x200);
        b.chan(0, A, 0xFC00, 4, 60, cntv(127, 0, 64, 0, 1, 0, true));
        b.chan(1, A + 0x100, 0xFE00, 0, 33, cntv(100, 1, 0, 0, 1, 0, true));
        b.chan(2, A + 0x200, 0xFF80, 10, 10, cntv(64, 2, 127, 0, 1, 0, true));
        b.chan(3, A + 0x300, 0xFFE0, 1, 7, cntv(5, 3, 30, 0, 1, 0, true));
        b.s.init = mem_std; out.push_back(b.s);
    }
    {
        Builder b("pcm16-oneshot-busy", 3000);
        b.w16(SND + 0x100, 0x807F); b.w16(SND + 0x104, 0x200);
        b.chan(4, B, 0xFD00, 0, 40, cntv(127, 0, 100, 0, 2, 1, true));
        b.chan(5, B + 0x400, 0xFF00, 3, 9, cntv(90, 0, 20, 0, 2, 1, true));
        b.at(1500); b.chan(4, B + 0x800, 0xFE80, 0, 200, cntv(127, 0, 64, 0, 1, 1, true));
        b.s.init = mem_std; out.push_back(b.s);
    }
    {
        Builder b("adpcm-loop-oneshot", 4000);
        b.w16(SND + 0x100, 0x807F); b.w16(SND + 0x104, 0x200);
        b.chan(0, C, 0xFE00, 1, 0x200, cntv(127, 0, 64, 0, 1, 2, true));
        b.chan(1, C + 0x8000, 0xFC00, 1, 0x40, cntv(127, 0, 64, 0, 2, 2, true));
        b.chan(2, C, 0xFFC0, 9, 30, cntv(127, 0, 10, 0, 1, 2, true));
        b.chan(3, C + 0x8000, 0xFF00, 0, 20, cntv(80, 1, 120, 0, 1, 2, true));  // loop start at the header
        b.s.init = mem_std; out.push_back(b.s);
    }
    {
        Builder b("adpcm-manual-repeat", 3000);
        b.w16(SND + 0x100, 0x807F); b.w16(SND + 0x104, 0x200);
        b.chan(6, C, 0xFE00, 1, 20, cntv(127, 0, 64, 0, 0, 2, true));
        b.chan(7, A, 0xFE00, 2, 10, cntv(127, 0, 64, 0, 0, 0, true));
        b.chan(8, B, 0xFF00, 0, 12, cntv(127, 0, 64, 0, 0, 1, true));
        b.chan(9, A, 0xFF00, 0, 12, cntv(127, 0, 64, 0, 3, 0, true));
        b.s.init = mem_std; out.push_back(b.s);
    }
    {
        Builder b("psg-noise", 3000);
        b.w16(SND + 0x100, 0x807F); b.w16(SND + 0x104, 0x200);
        for (int n = 8; n < 14; n++)
            b.chan(n, 0, 0xF000 + n * 0x123, 0, 0, cntv(60 + n, n & 3, n * 9, n - 7, 0, 3, true));
        b.chan(14, 0, 0xFF00, 0, 0, cntv(127, 0, 30, 0, 0, 3, true));
        b.chan(15, 0, 0xFFF0, 0, 0, cntv(127, 0, 90, 0, 0, 3, true));
        b.chan(2, 0, 0xFF00, 0, 0, cntv(127, 0, 90, 0, 0, 3, true));        // PSG on a PCM channel: silent
        b.at(1000); b.w8(CH(8, 3), 0x3F);                                    // duty 7, stop
        b.at(1100); b.w8(CH(8, 3), 0xE0);                                    // restart duty 0
        b.s.init = mem_std; out.push_back(b.s);
    }
    {
        Builder b("high-rate-and-short", 1500);
        b.w16(SND + 0x100, 0x807F); b.w16(SND + 0x104, 0x200);
        b.chan(0, A, 0xFFF8, 0, 100, cntv(127, 0, 64, 0, 1, 0, true));      // 64 samples per step
        b.chan(1, B, 0xFFF0, 0, 100, cntv(127, 0, 64, 0, 1, 1, true));
        b.chan(2, C, 0xFFE0, 1, 300, cntv(127, 0, 64, 0, 1, 2, true));
        b.chan(3, A, 0xFF00, 1, 2, cntv(127, 0, 64, 0, 1, 0, true));        // 3 words: never plays
        b.chan(4, 0x02000000, 0xFF00, 0, 16, cntv(127, 0, 64, 0, 1, 0, true));
        b.chan(5, 0x00000000, 0xFF00, 0, 16, cntv(127, 0, 64, 0, 1, 0, true));  // BIOS: zeros
        b.chan(6, 0x00003FF0, 0xFF00, 0, 16, cntv(127, 0, 64, 0, 1, 1, true));  // crosses 0x4000
        b.s.init = mem_std; out.push_back(b.s);
    }
    {
        Builder b("register-sizes", 2500);
        b.w8(SND + 0x100, 0x7F); b.w8(SND + 0x101, 0xFF);                  // SOUNDCNT bytes
        b.w16(SND + 0x104, 0x1FF);
        b.w32(CH(0, 4), A); b.w16(CH(0, 8), 0xFE00); b.w16(CH(0, 10), 2);
        b.w16(CH(0, 12), 0x30); b.w16(CH(0, 14), 0);
        b.w16(CH(0, 0), 0x0050); b.w16(CH(0, 2), 0x0840 | 0x8000);          // halves: start
        b.w32(CH(1, 4), B); b.w32(CH(1, 8), 0xFF00); b.w32(CH(1, 12), 0x10000 | 40);
        b.w8(CH(1, 0), 0x7F); b.w8(CH(1, 1), 0x01); b.w8(CH(1, 2), 0x20); b.w8(CH(1, 3), 0xA8);
        b.w16(CH(1, 4), 0x1234);                                             // ignored by melonDS
        b.w8(CH(1, 8), 0x55);                                                // ignored by melonDS
        b.at(400); b.w16(CH(1, 14), 0x0000); b.w16(CH(1, 12), 0x0010);      // length halves
        b.at(450); b.w16(CH(1, 14), 0x0001);
        b.at(700); b.w8(SND + 0x100, 0x40); b.w16(SND + 0x100, 0x8060);
        b.at(900); b.w32(SND + 0x100, 0x8000 | 0x7F); b.w32(SND + 0x104, 0x3FF);
        b.at(1100); b.w8(CH(0, 2), 0x7F);                                    // pan 127 -> 128
        b.at(1200); b.w8(CH(1, 3), 0x28);                                    // stop
        b.at(1300); b.w8(CH(1, 3), 0xA8);                                    // restart
        b.at(1500); b.power(0); b.at(1600); b.power(1);
        b.at(1800); b.w16(SND + 0x100, 0x0000); b.at(1900); b.w16(SND + 0x100, 0x807F);
        b.s.init = mem_std; out.push_back(b.s);
    }
    {
        Builder b("output-select-and-exclude", 3000);
        b.w16(SND + 0x104, 0x200);
        b.chan(0, A, 0xFE00, 0, 100, cntv(127, 0, 10, 0, 1, 0, true));
        b.chan(1, B, 0xFD00, 0, 100, cntv(127, 0, 40, 0, 1, 1, true));
        b.chan(2, A + 0x800, 0xFC00, 0, 100, cntv(100, 0, 80, 0, 1, 0, true));
        b.chan(3, B + 0x800, 0xFB00, 0, 100, cntv(127, 0, 120, 0, 1, 1, true));
        u32 modes[] = {0x807F, 0x817F, 0x827F, 0x837F, 0x847F, 0x887F, 0x8C7F, 0x8F7F, 0x907F, 0xA07F, 0xB57F, 0x8040};
        for (u32 i = 0; i < 12; i++) { b.at(i * 250); b.w16(SND + 0x100, modes[i]); }
        b.s.init = mem_std; out.push_back(b.s);
    }
    {
        Builder b("capture-modes", 4000);
        b.w16(SND + 0x100, 0x807F); b.w16(SND + 0x104, 0x200);
        b.chan(0, A, 0xFE00, 0, 200, cntv(127, 0, 0, 0, 1, 0, true));
        b.chan(2, B, 0xFD80, 0, 200, cntv(127, 0, 127, 0, 1, 1, true));
        b.chan(4, C, 0xFF00, 1, 0x300, cntv(127, 0, 64, 0, 1, 2, true));
        const u32 D = 0x02380000, E = 0x02390000;
        b.w32(SND + 0x110, D); b.w16(SND + 0x114, 64);
        b.w32(SND + 0x118, E); b.w16(SND + 0x11C, 37);
        b.w32(CH(1, 8), 0xFE00); b.w32(CH(3, 8), 0xFF00);                   // capture timers
        b.w16(SND + 0x108, 0x8880);                                          // cap0 16-bit loop, cap1 8-bit loop
        b.at(1000); b.w8(SND + 0x108, 0x00); b.w8(SND + 0x108, 0x84);       // cap0 one-shot 16-bit
        // length 0 -> one word. Set while stopped: changing the length of a
        // running unit desynchronises melonDS's FIFO level (docs/sound.md).
        b.at(1200); b.w8(SND + 0x109, 0x08); b.w32(SND + 0x118, E + 0x400); b.w16(SND + 0x11C, 0);
        b.w8(SND + 0x109, 0x88);
        b.at(1500); b.w8(SND + 0x109, 0x0C); b.w8(SND + 0x109, 0x8C);       // cap1 one-shot 8-bit
        b.at(2000); b.w16(SND + 0x108, 0x0000); b.w16(SND + 0x10A, 0x1234);
        b.at(2100); b.w32(SND + 0x108, 0x8B8F);                              // reserved bits set
        b.at(2500); b.w16(SND + 0x100, 0xB07F);                              // capture without ch1/ch3
        b.s.init = mem_std; out.push_back(b.s);
    }
    {
        // Restarts of a 4-word sample rewrite only FIFO words 0-3, so the lap
        // tags of words 4-7 go stale; the fourth start reaches their old lap
        // again. Without the start retag, the fast looped PCM16 sample started
        // then reads stale words 4-7 before its second refill arrives. Timer
        // 0xFFE0 gives 16 ticks in the first step, so its 13th and last read
        // (word 6) is the sample the step outputs.
        Builder b("fifo-restart-tags", 400);
        b.w16(SND + 0x100, 0x807F); b.w16(SND + 0x104, 0x200);
        for (int k = 0; k < 3; k++)
        {
            b.at(k * 20); b.w8(CH(0, 3), 0);
            b.chan(0, B + k * 0x40, 0xFF00, 0, 4, cntv(127, 0, 64, 0, 2, 1, true));
        }
        b.at(80); b.w8(CH(0, 3), 0);
        b.chan(0, A, 0xFFE0, 0, 200, cntv(127, 0, 64, 0, 1, 1, true));
        b.s.init = mem_std; out.push_back(b.s);
    }
    {
        // Mario Kart style: channel 1 plays capture 0's buffer back
        Builder b("capture-feedback", 4000);
        b.w16(SND + 0x100, 0x907F); b.w16(SND + 0x104, 0x200);
        const u32 D = 0x02380000;
        b.chan(0, A, 0xFE00, 0, 400, cntv(127, 0, 64, 0, 1, 1, true));
        b.w32(SND + 0x110, D); b.w16(SND + 0x114, 256);
        b.w32(CH(1, 4), D); b.w32(CH(1, 8), 0xFE00); b.w32(CH(1, 12), 256);
        b.w16(SND + 0x108, 0x80);
        b.at(300); b.w32(CH(1, 0), cntv(100, 0, 64, 0, 1, 1, true));
        b.s.init = mem_std; b.s.cap_feedback = true; out.push_back(b.s);
    }
    return out;
}

// hwref run 32's capture-lag probe (sndq S2, docs/hw-reference.md): channel
// 0 plays PCM16 zeros, then 0x4000 from sample 256, at timer T; capture 0
// records the mixer at timer 512. `--caplag` runs one per T and prints the
// first captured sample that shows the step (the DS's numbers are in
// docs/ds-rules.md).
static std::vector<Scenario> caplag()
{
    std::vector<Scenario> out;
    const u32 A = 0x02100000, D = 0x02380000;
    for (u32 T : {512u, 513u, 520u, 540u, 560u, 600u, 640u, 700u, 768u, 800u, 900u, 1000u, 1024u, 1100u, 1234u, 1500u, 2048u})
    {
        Builder b("caplag-" + std::to_string(T), 1200 + T / 2);
        b.w16(SND + 0x100, 0x807F); b.w16(SND + 0x104, 0x200);
        b.w32(SND + 0x110, D); b.w16(SND + 0x114, 0x4000);
        b.w32(CH(1, 8), 0x10000 - 512);
        b.chan(0, A, (u16)(0x10000 - T), 0, 0x8000, cntv(127, 0, 64, 0, 2, 1, true));
        b.w16(SND + 0x108, 0x80);
        b.s.init = [=](Mem& m) { for (u32 i = 0; i < 0x10000; i++) m.wr(A + 4 * i, i < 128 ? 0 : 0x40004000); };
        out.push_back(b.s);
    }
    return out;
}

// Random register traffic: channels started, restarted, retuned and
// stopped with random formats, timers, lengths and volumes. A running
// channel keeps its format: changing it makes melonDS read the FIFO at
// unaligned offsets, which the RTL does not model (docs/sound.md).
static Scenario fuzz(u32 seed, u32 steps)
{
    std::mt19937 r(seed);
    Builder b("fuzz-" + std::to_string(seed), steps);
    auto rnd = [&](u32 n) { return (u32)(r() % n); };
    const u32 base = 0x02100000;
    b.w16(SND + 0x100, 0x8000 | rnd(128)); b.w16(SND + 0x104, rnd(0x400));
    u32 dur = 0, fmts[16] = {0}, reps[16] = {0};
    for (u32 t = 0; t < steps; t += 1 + rnd(dur ? 40 : 4))
    {
        b.at(t);
        dur++;
        u32 n = rnd(16), k = rnd(20);
        if (k < 9)
        {
            u32 fmt = rnd(4), rep = rnd(4);
            u32 tmr = 0x10000 - (fmt == 3 ? 16 + rnd(0x1000) : 32 + rnd(rnd(4) ? 0x800 : 0x8000));
            u32 pnt = rnd(4) ? rnd(64) : rnd(3), len = rnd(4) ? rnd(600) : rnd(8);
            u32 src = base + rnd(0x80000) * 4;
            if (rnd(30) == 0) src = rnd(0x1000) * 4;      // ARM7 BIOS: zeros
            b.w8(CH(n, 3), 0);
            fmts[n] = fmt; reps[n] = rep;
            b.chan(n, src, tmr, pnt, len, cntv(rnd(128), rnd(4), rnd(128), rnd(8), rep, fmt, rnd(8) != 0, rnd(2)));
        }
        else if (k < 12)
        {
            u32 v = (r() & 0x1F) | fmts[n] << 5 | (rnd(2) << 7);
            reps[n] = (v >> 3) & 3;
            b.w8(CH(n, 3), v);
        }
        else if (k < 14) b.w16(CH(n, 0), r());
        else if (k < 15) b.w16(CH(n, 8), 0x10000 - 32 - rnd(0x2000));
        else if (k < 16) b.w16(SND + 0x100, (r() & 0x3F7F) | 0x8000);
        else if (k < 17)
        {
            // reconfigured while stopped (see capture-modes)
            int u = rnd(2);
            b.w8(SND + 0x108 + u, 0);
            b.w32(SND + 0x110 + u * 8, 0x02380000 + u * 0x10000 + rnd(0x1000) * 4);
            b.w16(SND + 0x114 + u * 8, rnd(4) ? rnd(300) : rnd(3));
            b.w8(SND + 0x108 + u, r() & 0x8F);
        }
        // loop start / length of a running manual-repeat channel stay put
        // (melonDS's negative burst length, docs/sound.md)
        else if (k < 18 && reps[n]) b.w32(CH(n, 8), (0x10000 - 32 - rnd(0x4000)) | rnd(64) << 16);
        else if (k < 19 && reps[n]) b.w32(CH(n, 12), rnd(600));
        else b.w8(CH(n, 2), r());
    }
    b.s.init = [=](Mem& m) { fill_random(m, base, 0x200000, seed * 7 + 1); };
    return b.s;
}

static int run_scenario(const Scenario& sc)
{
    Mem gm, rm;
    if (sc.init) { sc.init(gm); sc.init(rm); }
    std::vector<std::pair<u32, u32>> gcap, rcap;
    gsnd::Golden g([&](u32 a) { return gm.rd(a); }, [&](u32 a, u32 v) { gm.wr(a, v); gcap.push_back({a, v}); });
    Rtl rtl;
    rtl.fetch = [&](u32 a) { return rm.rd(a); };
    rtl.capw = [&](u32 a, u32 v) { rm.wr(a, v); rcap.push_back({a, v}); };

    size_t wi = 0;
    u32 bad = 0, badcnt = 0;
    for (u32 s = 0; s < sc.steps; s++)
    {
        while (wi < sc.w.size() && sc.w[wi].step <= s)
        {
            const Write& w = sc.w[wi++];
            if (w.addr == 0x04000304) { g.power(w.val); rtl.power = w.val & 1; continue; }
            g.write(w.bits, w.addr, w.val);
            rtl.reg(true, w.bits, w.addr, w.val);
        }
        s16 go[2], ro[2];
        u64 t0;
        g.step(go);
        if (!rtl.step(ro, t0)) { printf("FAIL %s: step %u timed out\n", sc.name.c_str(), s); return 1; }
        if (g_verbose && !bad)
        {
            // first per-channel state divergence
            spu::Snap gs;
            g.save(gs);
            auto& cpu0 = rtl.m->rootp->sound__DOT__u_cpu__DOT__mem;   // word 0 of entry n at n
            auto& run = rtl.m->rootp->sound__DOT__u_run__DOT__mem;
            for (int n = 0; n < 16; n++)
            {
                const spu::ChanSnap& c = gs.ch[n];
                u64 w0 = cpu0[n], w4 = wget(run[n], 0, 40), w5 = wget(run[n], 40, 40),
                    w6 = wget(run[n], 80, 40), w7 = wget(run[n], 120, 40);
                bool rbusy = (rtl.m->rootp->sound__DOT__busy >> n) & 1;
                if (!(c.cnt >> 31) && !rbusy) continue;
                s32 rpos = ((s32)(w5 << 6)) >> 6;
                bool same = ((u32)w0 & 0x7F7F837F) == (c.cnt & 0x7F7F837F) && rbusy == (c.cnt >> 31) && (w4 & 0xFFFF) == c.timer &&
                            (s16)(w4 >> 16) == (s16)c.cursample && rpos == c.pos * (((c.cnt >> 29) & 3) == 0 ? 2 : ((c.cnt >> 29) & 3) == 1 ? 4 : 1) &&
                            ((w6 & 0x3FFFFF) << 2) == c.roff;
                if (n == g_watch && s >= g_watch_from) { same = false; }
                if (!same)
                {
                    printf("  step %u ch%d: melonDS cnt %08X timer %04X pos %d cs %d roff %X level %d rp %u val %d idx %d\n"
                           "  %*s RTL     cnt %08X timer %04X pos %d cs %d roff %X level %d rp %u val %d idx %d\n",
                           s, n, c.cnt, c.timer, c.pos, (s16)c.cursample, c.roff, (s32)c.level, c.rp, c.adpcmval, c.adpcmindex,
                           (int)(std::to_string(s).size() + std::to_string(n).size()), "",
                           (u32)w0, (u32)(w4 & 0xFFFF), rpos, (s16)(w4 >> 16), (u32)((w6 & 0x3FFFFF) << 2),
                           ((s32)(w6 >> 22 << 25)) >> 25, (u32)((w5 >> 26) & 31), (s16)w7, (u32)((w7 >> 16) & 0x7F));
                    auto& ff = rtl.m->rootp->sound__DOT__u_fifo__DOT__mem;
                    auto& tg = rtl.m->rootp->sound__DOT__u_tag__DOT__mem;
                    printf("  melonDS FIFO wp %u:", c.wp);
                    for (int k = 0; k < 8; k++) printf(" %08X", c.fifo[k]);
                    printf("\n  RTL FIFO wp %u rlap %u wlap %u:", (u32)((w5 >> 31) & 7), (u32)((w5 >> 34) & 3), (u32)((w5 >> 36) & 3));
                    for (int k = 0; k < 8; k++) printf(" %u:%08X", (u32)tg[n * 8 + k], (u32)ff[n * 8 + k]);
                    printf("\n  src %08X pnt %X len %X\n", c.srcaddr, c.looppos, c.length);
                    if (n != g_watch) { bad++; break; }
                }
            }
        }
        if (go[0] != ro[0] || go[1] != ro[1])
        {
            if (bad < 5) printf("  %s step %u: melonDS %d %d, RTL %d %d\n", sc.name.c_str(), s, go[0], go[1], ro[0], ro[1]);
            bad++;
        }
        if (s % 37 == 36)
            for (int n = 0; n < 16; n++)
            {
                u32 gv = g.read(32, CH(n, 0)), rv = rtl.reg(false, 32, CH(n, 0), 0);
                if (gv != rv) { if (badcnt < 5) printf("  %s step %u: SOUND%dCNT melonDS %08X RTL %08X\n", sc.name.c_str(), s, n, gv, rv); badcnt++; }
            }
        rtl.pad(t0);
    }
    for (int i = 0; i < 4000; i++) rtl.clock();   // let the last capture write drain
    // Capture writes per unit (unit u writes to 0x0238xxxx + u * 0x10000 in
    // these tests). melonDS writes words in groups of four; the RTL writes
    // each word when it is complete.
    u32 badcap = 0;
    bool capcount = true;
    for (u32 u = 0; u < 2; u++)
    {
        std::vector<std::pair<u32, u32>> gu, ru;
        for (auto& c : gcap) if (((c.first >> 16) & 1) == u) gu.push_back(c);
        for (auto& c : rcap) if (((c.first >> 16) & 1) == u) ru.push_back(c);
        size_t ncmp = std::min(gu.size(), ru.size());
        for (size_t i = 0; i < ncmp; i++) if (gu[i] != ru[i]) { if (!badcap) printf("  %s capture %u write %zu: melonDS %08X=%08X RTL %08X=%08X\n", sc.name.c_str(), u, i, gu[i].first, gu[i].second, ru[i].first, ru[i].second); badcap++; }
        if (ru.size() != gu.size()) capcount = false;
    }
    if (sc.name.rfind("caplag-", 0) == 0)
    {
        // first sample (16-bit, unit 0) that shows the step, melonDS's and the RTL's
        auto first = [](const std::vector<std::pair<u32, u32>>& cap) {
            long best = -1;
            for (auto& c : cap)
                if (c.first >> 16 == 0x0238 && c.second)
                {
                    long i = (long)(c.first - 0x02380000) / 2 + ((c.second & 0xFFFF) ? 0 : 1);
                    if (best < 0 || i < best) best = i;
                }
            return best;
        };
        printf("  %s: step at capture sample %ld (melonDS), %ld (RTL)\n", sc.name.c_str(), first(gcap), first(rcap));
    }
    bool ok = !bad && !badcnt && !badcap && capcount && !rtl.m->overrun;
    printf("%s %s: %u steps, %u output diffs, %u CNT diffs, %zu/%zu capture writes (%u diffs), "
           "busy max %llu avg %.0f clocks, %llu late, %llu reads%s\n",
           ok ? "PASS" : "FAIL", sc.name.c_str(), sc.steps, bad, badcnt, rcap.size(), gcap.size(), badcap,
           (unsigned long long)rtl.max_busy, (double)rtl.busy_sum / std::max<u64>(1, rtl.steps),
           (unsigned long long)rtl.late, (unsigned long long)rtl.reads, rtl.m->overrun ? ", OVERRUN" : "");
    return ok ? 0 : 1;
}

// ---------------------------------------------------------------- census traces
static int run_trace(const std::string& path, u32 maxsteps)
{
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) { printf("FAIL %s: cannot open\n", path.c_str()); return 1; }
    char magic[9] = {0};
    u8 type = 0;
    spu::Snap sn;
    if (fread(magic, 1, 8, f) != 8 || strcmp(magic, "NDSSPU01") || fread(&type, 1, 1, f) != 1 ||
        type != spu::RecSnap || fread(&sn, sizeof sn, 1, f) != 1)
    { printf("FAIL %s: bad header\n", path.c_str()); return 1; }
    std::vector<spu::Rec> recs;
    spu::Rec rec;
    while (fread(&rec, sizeof rec, 1, f) == 1) recs.push_back(rec);
    fclose(f);

    std::vector<spu::Rec> fetches, caps;
    for (auto& r : recs)
        if (r.type == spu::RecFetch) fetches.push_back(r);
        else if (r.type == spu::RecCap) caps.push_back(r);
    size_t gfi = 0, rfi = 0;
    u32 gfbad = 0, rfbad = 0;
    std::vector<std::pair<u32, u32>> gcap, rcap;
    gsnd::Golden g(
        [&](u32 a) {
            if (gfi >= fetches.size()) { gfbad++; return 0u; }
            const spu::Rec& r = fetches[gfi++];
            if (r.a != a) gfbad++;
            return r.b;
        },
        [&](u32 a, u32 v) { gcap.push_back({a, v}); });
    g.load(sn);
    Rtl rtl;
    int skip[2];
    rtl.load(sn, skip);
    rtl.fetch = [&](u32 a) {
        if (rfi >= fetches.size()) { rfbad++; return 0u; }
        const spu::Rec& r = fetches[rfi++];
        if (r.a != a) { if (rfbad < 3) printf("  fetch %zu: trace %08X, RTL %08X\n", rfi - 1, r.a, a); rfbad++; }
        return r.b;
    };
    rtl.capw = [&](u32 a, u32 v) { rcap.push_back({a, v}); };

    u32 steps = 0, bad = 0, gbad = 0;
    for (size_t i = 0; i < recs.size() && steps < maxsteps; i++)
    {
        const spu::Rec& r = recs[i];
        if (r.type == spu::RecWrite)
        {
            g.write(r.size, r.a, r.b);
            rtl.reg(true, r.size, r.a, r.b);
        }
        else if (r.type == spu::RecPower) { g.power(r.b); rtl.power = r.b & 1; }
        else if (r.type == spu::RecMix)
        {
            size_t j = i + 1;
            while (j < recs.size() && recs[j].type != spu::RecOut) j++;
            if (j >= recs.size()) break;
            s16 to[2] = {(s16)recs[j].a, (s16)recs[j].b}, go[2], ro[2];
            u64 t0;
            g.step(go);
            if (!rtl.step(ro, t0)) { printf("FAIL %s: step %u timed out\n", path.c_str(), steps); return 1; }
            if (go[0] != to[0] || go[1] != to[1]) { if (gbad < 3) printf("  golden step %u: trace %d %d, melonDS %d %d\n", steps, to[0], to[1], go[0], go[1]); gbad++; }
            if (ro[0] != to[0] || ro[1] != to[1]) { if (bad < 5) printf("  step %u: trace %d %d, RTL %d %d\n", steps, to[0], to[1], ro[0], ro[1]); bad++; }
            rtl.pad(t0);
            steps++;
            i = j;
        }
    }
    for (int i = 0; i < 4000; i++) rtl.clock();
    // capture writes per unit, in order: the trace's, minus the words the RTL
    // wrote before the snapshot (melonDS still held them in its FIFO)
    u32 badcap = 0;
    {
        for (int u = 0; u < 2; u++)
        {
            u32 lo = sn.cap[u].dstaddr, hi = lo + std::max<u32>(4, sn.cap[u].length);
            std::vector<std::pair<u32, u32>> t, rr;
            int sk = skip[u];
            for (auto& c : caps) if (c.a >= lo && c.a < hi && sk-- <= 0) t.push_back({c.a, c.b});
            for (auto& c : rcap) if (c.first >= lo && c.first < hi) rr.push_back(c);
            size_t n = std::min(t.size(), rr.size());
            for (size_t k = 0; k < n; k++) if (t[k] != rr[k]) { if (!badcap) printf("  capture %d word %zu: trace %08X=%08X RTL %08X=%08X\n", u, k, t[k].first, t[k].second, rr[k].first, rr[k].second); badcap++; }
            if (rr.size() != t.size()) { printf("  capture %d: trace %zu words, RTL %zu\n", u, t.size(), rr.size()); badcap++; }
        }
    }
    bool ok = !bad && !rfbad && !badcap && !rtl.m->overrun;
    printf("%s %s: %u steps, %u output diffs (golden replay %u), fetches %zu/%zu (%u diffs, golden %u), "
           "capture writes %zu/%zu (%u diffs), busy max %llu avg %.0f clocks, %llu late%s\n",
           ok ? "PASS" : "FAIL", path.c_str(), steps, bad, gbad, rfi, fetches.size(), rfbad, gfbad,
           rcap.size(), caps.size(), badcap, (unsigned long long)rtl.max_busy,
           (double)rtl.busy_sum / std::max<u64>(1, rtl.steps), (unsigned long long)rtl.late,
           rtl.m->overrun ? ", OVERRUN" : "");
    printf("  ARM7 register accesses: %llu, clocks to the ack max %llu avg %.2f; longest entry (boundary to boundary) %llu clocks\n",
           (unsigned long long)rtl.reg_n, (unsigned long long)rtl.reg_max, (double)rtl.reg_sum / std::max<u64>(1, rtl.reg_n),
           (unsigned long long)rtl.ent_max);
    return ok ? 0 : 1;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    bool syn = false, lag = false;
    u32 nfuzz = 0, steps = ~0u, seed = 1;
    std::string only;
    std::vector<std::string> traces;
    for (int i = 1; i < argc; i++)
    {
        std::string a = argv[i];
        auto next = [&]() { return std::string(i + 1 < argc ? argv[++i] : ""); };
        if (a == "--synthetic") syn = true;
        else if (a == "--caplag") lag = true;
        else if (a == "--fuzz") nfuzz = atoi(next().c_str());
        else if (a == "--seed") seed = atoi(next().c_str());
        else if (a == "--ce-half") g_cehalf = true;
        else if (a == "--ce-check") g_cehalf = g_cecheck = true;
        else if (a == "--trace") traces.push_back(next());
        else if (a == "--only") only = next();
        else if (a == "--lat") g_lat = atoi(next().c_str());
        else if (a == "--jitter") g_jitter = atoi(next().c_str());
        else if (a == "--steps") steps = atoi(next().c_str());
        else if (a == "--verbose") g_verbose = true;
        else if (a == "--watch") { g_verbose = true; g_watch = atoi(next().c_str()); g_watch_from = atoi(next().c_str()); }
    }
    if (!syn && !nfuzz && traces.empty() && !lag) { syn = true; nfuzz = 20; }
    int fails = 0, runs = 0;
    if (syn)
        for (auto& sc : synthetic())
            if (only.empty() || sc.name.find(only) != std::string::npos) { runs++; fails += run_scenario(sc); }
    for (u32 k = 0; k < nfuzz; k++)
    {
        Scenario sc = fuzz(seed + k, steps == ~0u ? 6000 : steps);
        if (only.empty() || sc.name.find(only) != std::string::npos) { runs++; fails += run_scenario(sc); }
    }
    if (lag) for (auto& sc : caplag()) { runs++; fails += run_scenario(sc); }
    for (auto& t : traces) { runs++; fails += run_trace(t, steps); }
    if (g_cecheck) printf("ce check: %llu ce-low edges, %llu changed state\n", g_ce_edges, g_ce_bad);
    printf("%d/%d runs pass\n", runs - fails, runs);
    return (fails || g_ce_bad) ? 1 : 0;
}
