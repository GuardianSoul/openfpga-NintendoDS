// Geometry engine test bench (docs/geometry-engine.md): rtl/gpu3d/gpu3d_geom.sv
// in Verilator against melonDS's own GPU3D (the census build of melonDS).
//
//   tb_geom --trace gx.bin [--frames N] [--dump DIR]   census GX trace
//   tb_geom --synth N [--seed S]                         random command streams
//   tb_geom --timing N [--seed S]                        GXSTAT per system cycle against GPU3D::Run
//
// Trace and synth modes feed the same FIFO entries to both; melonDS executes
// them back to back (GPU3D::ExecuteCommand), the RTL as fast as its FIFO
// accepts. At every swap the sorted polygon list (RenderPolygonRAM) is
// compared field by field with the RTL's polygon records in its render
// order, and the polygon/vertex counts before the swap. Synth mode also
// compares the register-file reads (clip matrix, vector matrix, POS_TEST,
// VEC_TEST, BOX_TEST) after the test commands.
//
// Timing mode (run_timing) writes random frames to both, steps melonDS's
// GPU3D::Run one system cycle per tick and compares GXSTAT every cycle.
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <map>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include "Vgpu3d_geom.h"
#include "ucode.h"
#include "Vgpu3d_geom___024root.h"
#include "verilated.h"

#include "NDS.h"
#include "GPU.h"
#include "GPU3D.h"

// GEOM_USORT: the sort in the engine's microcode (gpu3d_geom USORT), no gpu3d_gxsort
#if GEOM_USORT
#define SORT_ST(r) 0
#define SORT_K(r) 0
#if GEOM_FF
#define UCODE_LABELS "build/geom/ucode_uf.labels"
#else
#define UCODE_LABELS "build/geom/ucode_us.labels"
#endif
#else
#define SORT_ST(r) (r)->gpu3d_geom__DOT__g_sort__DOT__u_sort__DOT__st
#define SORT_K(r) (r)->gpu3d_geom__DOT__g_sort__DOT__u_sort__DOT__k
#define UCODE_LABELS "build/geom/ucode.labels"
#endif

// gpu3d_gxfront's entry RAM (under g_ent, or g_spill with GEOM_SPILL)
#if GEOM_SPILL
#define UENT(x) gpu3d_geom__DOT__u_front__DOT__g_spill__DOT__u_ent__DOT__##x
#else
#define UENT(x) gpu3d_geom__DOT__u_front__DOT__g_ent__DOT__u_ent__DOT__##x
#endif
using namespace melonDS;

namespace
{
bool g_order_dump = false;
extern bool g_prof;
u64 g_rfw = 0;
int g_prof_from = 0, g_prof_to = 1 << 30, g_cur_frame = 0;
bool g_fstat = false;
u64 g_div_hist[100][128];
extern std::vector<u64> g_prof_hist;
extern u64 g_cmd_n[64], g_cmd_cyc[64];
extern std::string g_pct;
unsigned long long g_tr_from = ~0ull, g_tr_to = 0;

const u8 kNumParams[256] = {
    0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    1, 0, 1, 1, 1, 0, 16, 12, 16, 12, 9, 3, 3, 0, 0, 0,
    1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0,
    1, 1, 1, 1, 32, 0,0,0,0,0,0,0,0,0,0,0,
    1, 0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    1, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    1, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    3, 2, 1, 0,0,0,0,0,0,0,0,0,0,0,0,0,
};

#if defined(GEOM_CHEAP) && GEOM_CHEAP
#define GEOM_CHEAP_ON 1
#else
#define GEOM_CHEAP_ON 0
#endif
struct Entry { u8 cmd; u32 param; };

// ------------------------------------------------------------------ RTL
struct Rtl
{
    std::unique_ptr<Vgpu3d_geom> m;
    u64 cyc = 0;
    // polygon records of the frame being built, by index
    struct Rec { u32 h[4]; std::vector<std::array<u32, 4>> v; };
    std::map<int, Rec> recs;
    int cur = -1;
    std::vector<int> order;            // render position -> polygon index
    bool swapped = false, ovf = false;
    int so_n = 0;
    u64 sort_t0 = 0;
    std::vector<u64> sort_clk;     // clocks from the sort's start (the swap) to so_done, per swap
    u64 stall_cycles = 0, wait_cycles = 0, n_sub = 0, n_oc = 0, lost = 0, eq_bad = 0;
    std::vector<u32> msub;
    std::vector<Entry> fed;
    u64 n_exec = 0, bad_hd = 0, n_pop = 0, dbg_from = ~0ull, dbg_to = 0;

    Rtl()
    {
        m = std::make_unique<Vgpu3d_geom>();
        m->rst = 1; m->geom_en = 1; m->po_ready = 1;
        for (int i = 0; i < 8; i++) cycle();
        m->rst = 0;
        // reset microcode clears the register file
        for (int i = 0; i < 4000; i++) cycle();
    }
    // --poready P: the store refuses a record (po_ready low) P% of the clocks, as the system's store does while
    // its memory is busy
    int po_busy = 0;
    u32 pseed = 7;
    void cycle()
    {
        m->tick = cyc & 1;
        if (po_busy) { pseed = pseed * 1103515245u + 12345u; m->po_ready = (int)((pseed >> 16) % 100) >= po_busy; }
        m->clk = 0; m->clk_2x = 0;
        m->eval();
        // outputs valid in this cycle (transfers happen at the edge)
        if (m->po_valid && m->po_ready)
        {
            if (m->po_type == 0)
            {
                cur = m->po_index;
                Rec& r = recs[cur];
                r.v.clear();
                for (int i = 0; i < 4; i++) r.h[i] = m->po_data[i];
            }
            else if (cur >= 0)
            {
                std::array<u32, 4> b;
                for (int i = 0; i < 4; i++) b[i] = m->po_data[i];
                recs[cur].v.push_back(b);
            }
        }
        if (g_rfw && cyc < g_rfw)
        {
            auto* r = m->rootp;
            if (r->gpu3d_geom__DOT__u_eng__DOT__we_m)
                printf("W %llu upc %03x [%03x] = %08x\n", (unsigned long long)cyc, r->gpu3d_geom__DOT__u_eng__DOT__upc,
                       r->gpu3d_geom__DOT__u_eng__DOT__wa_m, r->gpu3d_geom__DOT__u_eng__DOT__R);
            if (r->gpu3d_geom__DOT__u_eng__DOT__pop)
                printf("POP %llu %02x %08x\n", (unsigned long long)cyc, (u32)(r->UENT(rdata) >> 32),
                       (u32)r->UENT(rdata));
        }
        if (g_prof && g_cur_frame >= g_prof_from && g_cur_frame < g_prof_to)
        {
            static u64 dstart = 0; static int dqb = 0; static bool dbusy = false;
            auto* r = m->rootp;
            bool b = r->gpu3d_geom__DOT__u_eng__DOT__div_busy;
            if (b && !dbusy) { dstart = cyc; dqb = r->gpu3d_geom__DOT__u_eng__DOT__u_div__DOT__dbg_cnt; }
            if (!b && dbusy) { g_div_hist[std::min<u64>(cyc - dstart, 99)][dqb & 127]++; }
            dbusy = b;
            u32 pc = m->rootp->gpu3d_geom__DOT__u_eng__DOT__upc;
            if (g_prof_hist.empty()) g_prof_hist.resize(4096);
            g_prof_hist[m->dbg_idle ? 4095 : pc]++;
            // --pct FILE: the busy cycles' {upc, xr1, xr2, xr3} as u16 (the engine-model study)
            static FILE* pct = g_pct.empty() ? nullptr : fopen(g_pct.c_str(), "wb");
            if (pct && !m->dbg_idle)
            {
                uint16_t w[4] = {(uint16_t)pc, (uint16_t)r->gpu3d_geom__DOT__u_eng__DOT__xr1,
                                 (uint16_t)r->gpu3d_geom__DOT__u_eng__DOT__xr2, (uint16_t)r->gpu3d_geom__DOT__u_eng__DOT__xr3};
                fwrite(w, 2, 4, pct);
            }
            // engine time per command: busy cycles go to the last command dispatched to its handler
            static int cur = -1;
            if (r->gpu3d_geom__DOT__u_eng__DOT__pop && (!r->gpu3d_geom__DOT__u_eng__DOT__mp || r->gpu3d_geom__DOT__u_eng__DOT__mp_last))
            {
                cur = (int)((r->UENT(rdata) >> 32) & 63);
                g_cmd_n[cur]++;
            }
            if (!m->dbg_idle && cur >= 0) g_cmd_cyc[cur]++;
        }
        if (cyc >= g_tr_from && cyc < g_tr_to)
        {
            u32 pc = m->rootp->gpu3d_geom__DOT__u_eng__DOT__upc;
            static std::map<u32, std::string> lab;
            if (lab.empty())
                if (FILE* f = fopen(UCODE_LABELS, "r"))
                {
                    char nm[128]; u32 a;
                    while (fscanf(f, "%u %127s", &a, nm) == 2) if (!lab.count(a)) lab[a] = nm;
                    fclose(f);
                }
            auto it = lab.upper_bound(pc);
            std::string nm = it == lab.begin() ? "?" : std::prev(it)->second;
            printf("T %llu upc %03x %s+%u R %08X\n", (unsigned long long)cyc, pc, nm.c_str(),
                   it == lab.begin() ? 0 : pc - std::prev(it)->first, m->rootp->gpu3d_geom__DOT__u_eng__DOT__R);
        }
        if (g_order_dump && m->rootp->gpu3d_geom__DOT__ks_we)
            printf("    KEY idx %u key %05X sort st %u\n", m->rootp->gpu3d_geom__DOT__ks_idx, m->rootp->gpu3d_geom__DOT__ks_key,
                   SORT_ST(m->rootp));
        if (m->so_we)
        {
            if ((int)order.size() <= m->so_pos) order.resize(m->so_pos + 1, -1);
            order[m->so_pos] = m->so_idx;
        }
        if (m->rootp->gpu3d_geom__DOT__sort_go) sort_t0 = cyc;
        if (m->so_done) { swapped = true; so_n = m->so_count; sort_clk.push_back(cyc - sort_t0); }
        if (m->ovf_set) ovf = true;
        if (m->dbg_stall) stall_cycles++;
        if (m->dbg_eq_bad && eq_bad++ < 3)
        {
            fprintf(stderr, "EQ: the reference front disagrees at cycle %llu\n", (unsigned long long)cyc);
#ifdef GEOM_EQ
            auto* r = m->rootp;
            fprintf(stderr, "  gxstat %08X/%08X mx %u/%u wait %u/%u stall %u/%u te %u/%u ds %u/%u edata %d tick %u\n",
                    r->gpu3d_geom__DOT__r_gxstat, r->gpu3d_geom__DOT__gxstat, r->gpu3d_geom__DOT__r_mx, r->gpu3d_geom__DOT__mx,
                    r->gpu3d_geom__DOT__r_wait, m->io_wait, r->gpu3d_geom__DOT__r_stall, r->gpu3d_geom__DOT__gx_stall,
                    r->gpu3d_geom__DOT__r_te, r->gpu3d_geom__DOT__test_exec, r->gpu3d_geom__DOT__r_ds, m->dbg_stall,
                    r->gpu3d_geom__DOT__r_e_code != r->gpu3d_geom__DOT__e_data, m->tick);
#endif
        }
        {
            auto* r = m->rootp;
            if (r->gpu3d_geom__DOT__u_front__DOT__do_exec) n_exec++;
            if (r->gpu3d_geom__DOT__u_front__DOT__do_exec && r->gpu3d_geom__DOT__u_front__DOT__x_sub) {
                n_sub++;
                msub.push_back(r->gpu3d_geom__DOT__u_front__DOT__mx);
            }
            if (r->gpu3d_geom__DOT__u_eng__DOT__pop) n_pop++;
            if (n_pop >= dbg_from && n_pop <= dbg_to)
                printf("E pops %llu upc %03x dp %u P %08x\n", (unsigned long long)n_pop,
                       r->gpu3d_geom__DOT__u_eng__DOT__upc, r->gpu3d_geom__DOT__u_eng__DOT__dp_r,
                       r->gpu3d_geom__DOT__u_eng__DOT__P);
            if (r->gpu3d_geom__DOT__oc_valid) {
                n_oc++;
                // (the cheap front takes no outcomes)
                if (!(GEOM_CHEAP_ON) && !((r->gpu3d_geom__DOT__u_front__DOT__tm >> 6) & 1) && lost++ < 5)
                    printf("outcome %llu lost at cycle %llu (model mx %u, engine dp %u, submissions %llu)\n",
                           (unsigned long long)n_oc, (unsigned long long)cyc, r->gpu3d_geom__DOT__u_front__DOT__mx,
                           r->gpu3d_geom__DOT__u_eng__DOT__dp_r, (unsigned long long)n_sub);
            }
        }
        // clk_2x (gpu3d_gxdiv P2X): its middle edge, then its edge with clk's
        m->clk_2x = 1; m->eval(); m->clk_2x = 0; m->eval();
        m->clk = 1; m->clk_2x = 1;
        m->eval();
        cyc++;
    }
    // --gap G: 0..G idle clocks after each write (the FIFO's writers are not flat out on the DS)
    int gap = 0;
    u32 gseed = 1;
    void write(u32 addr, u32 val)
    {
        write1(addr, val);
        if (gap) { gseed = gseed * 1103515245u + 12345u; for (u32 n = (gseed >> 16) % (u32)(gap + 1); n; n--) cycle(); }
    }
    void write1(u32 addr, u32 val)
    {
        m->io_req = 1; m->io_we = 1; m->io_be = 0xF;
        m->io_addr = (addr >> 2) & 0xFF; m->io_wdata = val;
        for (;;)
        {
            m->clk = 0; m->tick = cyc & 1; m->eval();
            bool wait = m->io_wait;
            cycle();
            if (!wait) break;
            wait_cycles++;
        }
        m->io_req = 0; m->io_we = 0;
    }
    u32 read(u32 addr)
    {
        m->io_req = 1; m->io_we = 0; m->io_be = 0xF; m->io_addr = (addr >> 2) & 0xFF;
        cycle();
        m->io_req = 0;
        for (int i = 0; i < 100000; i++)
        {
            m->clk = 0; m->tick = cyc & 1; m->eval();
            if (m->io_ack) { u32 v = m->io_rdata; cycle(); return v; }
            cycle();
        }
        fprintf(stderr, "read %08X timed out\n", addr);
        exit(3);
    }
    // --packed: each command through GXFIFO (0x04000400) as a packed word of its own, then its parameters,
    // as a display list's DMA sends them (the command ports otherwise)
    bool packed = false;
    int pk_left = 0;                        // parameters of the current packed command still to come
    static int nparams(u8 c)
    {
        switch (c)
        {
        case 0x11: case 0x15: case 0x41: return 0;
        case 0x16: case 0x18: return 16;
        case 0x17: case 0x19: return 12;
        case 0x1A: return 9;
        case 0x1B: case 0x1C: case 0x70: return 3;
        case 0x23: case 0x71: return 2;
        case 0x34: return 32;
        default: return 1;
        }
    }
    void entry(const Entry& e)
    {
        fed.push_back(e);
        if (packed && e.cmd >= 0x10 && e.cmd < 0x73)
        {
            if (pk_left == 0)
            {
                write(0x04000400, e.cmd);
                pk_left = nparams(e.cmd);
                if (pk_left == 0) return;
            }
            write(0x04000400, e.param);
            pk_left--;
            return;
        }
        if (e.cmd >= 0x10 && e.cmd < 0x73) write(0x04000440 + (e.cmd - 0x10) * 4, e.param);
        else write(0x04000400, e.cmd);       // a NOP / unknown command: one packed entry
    }
    bool wait_idle(u64 limit = 20000000)
    {
        for (u64 i = 0; i < limit; i++)
        {
            m->clk = 0; m->tick = cyc & 1; m->eval();
            auto* r = m->rootp;
            bool fe = r->gpu3d_geom__DOT__u_front__DOT__p == 0 && r->gpu3d_geom__DOT__u_front__DOT__f == 0 &&
                      r->gpu3d_geom__DOT__u_front__DOT__act == 0;
            if (m->dbg_idle && (fe || m->dbg_flush))
            {
                for (int k = 0; k < 8; k++) cycle();
                m->clk = 0; m->eval();
                if (m->dbg_idle) return true;
            }
            cycle();
        }
        return false;
    }
};

// ------------------------------------------------------------------ melonDS
struct Golden
{
    NDS* nds;
    GPU3D* g;
    Golden()
    {
        nds = new NDS(NDSArgs{});
        nds->Reset();
        g = &nds->GPU.GPU3D;
        g->SetEnabled(true, true);
    }
    void entry(const Entry& e)
    {
        decltype(g->CmdPIPE.Peek()) x {};
        x.Command = e.cmd;
        x.Param = e.param;
        g->CmdPIPE.Write(x);
        g->ExecuteCommand();
    }
};

// ------------------------------------------------------------------ compare
u32 bits(const u32* w, int lo, int n)
{
    u64 v = 0;
    for (int i = 0; i < n; i++) v |= (u64)((w[(lo + i) / 32] >> ((lo + i) % 32)) & 1) << i;
    return (u32)v;
}

bool g_prof = false;
std::string g_prof_dump, g_pct;      // --prof-dump FILE: executions per microinstruction address (4095: idle)
std::vector<u64> g_prof_hist;
u64 g_cmd_n[64], g_cmd_cyc[64];
void prof_report()
{
    if (!g_prof) return;
    if (!g_prof_dump.empty())
        if (FILE* f = fopen(g_prof_dump.c_str(), "w"))
        {
            for (u32 pc = 0; pc < g_prof_hist.size(); pc++) if (g_prof_hist[pc]) fprintf(f, "%u %llu\n", pc, (unsigned long long)g_prof_hist[pc]);
            fclose(f);
        }
    std::map<u32, std::string> lab;
    if (FILE* f = fopen(UCODE_LABELS, "r"))
    {
        char nm[128]; u32 a;
        while (fscanf(f, "%u %127s", &a, nm) == 2) if (!lab.count(a)) lab[a] = nm;
        fclose(f);
    }
    std::map<std::string, u64> by;
    u64 tot = 0;
    for (u32 pc = 0; pc < g_prof_hist.size(); pc++)
    {
        if (!g_prof_hist[pc]) continue;
        tot += g_prof_hist[pc];
        if (pc == 4095) { by["(idle)"] += g_prof_hist[pc]; continue; }
        auto it = lab.upper_bound(pc);
        by[it == lab.begin() ? "?" : std::prev(it)->second] += g_prof_hist[pc];
    }
    for (int len = 0; len < 100; len++)
        for (int q = 0; q < 128; q++)
            if (g_div_hist[len][q]) printf("  div bits %d: %d cycles x %llu\n", q, len, (unsigned long long)g_div_hist[len][q]);
    std::vector<std::pair<u64, std::string>> v;
    for (auto& [k, n] : by) v.push_back({n, k});
    std::sort(v.rbegin(), v.rend());
    for (auto& [n, k] : v) if (n * 200 >= tot) printf("  prof %-12s %12llu %5.1f%%\n", k.c_str(), (unsigned long long)n, 100.0 * n / tot);
    // engine cycles per command (by handler entry; the command codes of ucode.py HT)
    {
        static const int code[38] = {0x00, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C,
                                     0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B,
                                     0x30, 0x31, 0x32, 0x33, 0x34, 0x40, 0x41, 0x50, 0x60, 0x70, 0x71, 0x72};
        std::vector<std::pair<u64, int>> c;
        for (int i = 0; i < 38; i++) if (g_cmd_n[i]) c.push_back({g_cmd_cyc[i], i});
        std::sort(c.rbegin(), c.rend());
        for (auto& [cy, i] : c)
            printf("  cmd %02X %10llu x %8.1f cycles %5.1f%%\n", code[i], (unsigned long long)g_cmd_n[i],
                   (double)cy / g_cmd_n[i], 100.0 * cy / tot);
    }
    // how often a routine was entered: the execution count of its first instruction
    for (auto& [a, nm] : lab)
        if ((nm == "SUBP" || nm == "CULLOK" || nm == "PREJ" || nm == "DOCLIP" || nm == "CLIP" || nm == "NOCLIP") && a < g_prof_hist.size())
            printf("  entries %-8s %10llu\n", nm.c_str(), (unsigned long long)g_prof_hist[a]);
}
int g_fail_shown = 0;
u64 g_wide_colors = 0;

bool compare_frame(Golden& gd, Rtl& rtl, int frame, bool verbose)
{
    GPU3D& g = *gd.g;
    int n = g.RenderNumPolygons;
    bool ok = true;
    auto fail = [&](const char* what, int pos, long a, long b) {
        ok = false;
        if (g_fail_shown++ < 40)
            fprintf(stderr, "frame %d poly %d: %s melonDS %ld (%#lx) RTL %ld (%#lx)\n", frame, pos, what, a, a, b, b);
    };
    if (rtl.so_n != n) fail("count", -1, n, rtl.so_n);
    for (int i = 0; i < n && i < rtl.so_n; i++)
    {
        const Polygon* p = g.RenderPolygonRAM[i];
        if (i >= (int)rtl.order.size() || rtl.order[i] < 0 || !rtl.recs.count(rtl.order[i]))
        { fail("missing record", i, 0, i < (int)rtl.order.size() ? rtl.order[i] : -1); continue; }
        const Rtl::Rec& r = rtl.recs[rtl.order[i]];
        const u32* h = r.h;
        if (bits(h, 0, 32) != p->Attr) fail("Attr", i, p->Attr, bits(h, 0, 32));
        if (bits(h, 32, 32) != p->TexParam) fail("TexParam", i, p->TexParam, bits(h, 32, 32));
        if (bits(h, 64, 13) != p->TexPalette) fail("TexPalette", i, p->TexPalette, bits(h, 64, 13));
        if (bits(h, 77, 4) != p->NumVertices) { fail("NumVertices", i, p->NumVertices, bits(h, 77, 4)); continue; }
        if (bits(h, 81, 4) != p->VTop) fail("VTop", i, p->VTop, bits(h, 81, 4));
        if (bits(h, 85, 4) != p->VBottom) fail("VBottom", i, p->VBottom, bits(h, 85, 4));
        if (bits(h, 89, 8) != (u32)p->YTop) fail("YTop", i, p->YTop, bits(h, 89, 8));
        if (bits(h, 97, 8) != (u32)p->YBottom) fail("YBottom", i, p->YBottom, bits(h, 97, 8));
        if (bits(h, 105, 1) != p->FacingView) fail("FacingView", i, p->FacingView, bits(h, 105, 1));
        if (bits(h, 106, 1) != p->WBuffer) fail("WBuffer", i, p->WBuffer, bits(h, 106, 1));
        if (bits(h, 107, 1) != p->Degenerate) fail("Degenerate", i, p->Degenerate, bits(h, 107, 1));
        if (r.v.size() != p->NumVertices) { fail("vertex beats", i, p->NumVertices, r.v.size()); continue; }
        if (g_order_dump && i < 2)
            for (u32 j = 0; j < p->NumVertices; j++)
                printf("    poly %d v%u clipped %d pos %08X %08X %08X %08X color %08X %08X %08X\n", i, j, p->Vertices[j]->Clipped,
                       p->Vertices[j]->Position[0], p->Vertices[j]->Position[1], p->Vertices[j]->Position[2], p->Vertices[j]->Position[3],
                       p->Vertices[j]->Color[0], p->Vertices[j]->Color[1], p->Vertices[j]->Color[2]),
                printf("      tex %04X %04X final rgb %03X %03X %03X | RTL rgb %03X %03X %03X st %04X %04X\n",
                       (u16)p->Vertices[j]->TexCoords[0], (u16)p->Vertices[j]->TexCoords[1],
                       p->Vertices[j]->FinalColor[0], p->Vertices[j]->FinalColor[1], p->Vertices[j]->FinalColor[2],
                       bits(r.v[j].data(), 57, 9), bits(r.v[j].data(), 66, 9), bits(r.v[j].data(), 75, 9),
                       bits(r.v[j].data(), 84, 16), bits(r.v[j].data(), 100, 16));
        for (u32 j = 0; j < p->NumVertices; j++)
        {
            const Vertex* v = p->Vertices[j];
            const u32* b = r.v[j].data();
            char what[64];
            auto chk = [&](const char* f, long a, long bv) { if (a != bv) { snprintf(what, sizeof what, "v%u %s", j, f); fail(what, i, a, bv); } };
            chk("x", v->FinalPosition[0], bits(b, 0, 9));
            chk("y", v->FinalPosition[1], bits(b, 9, 8));
            chk("z", p->FinalZ[j], bits(b, 17, 24));
            chk("w", p->FinalW[j], bits(b, 41, 16));
            // the record carries the 9 bits the rasterizer reads
            for (int c = 0; c < 3; c++)
                if ((u32)v->FinalColor[c] > 0x1FF) g_wide_colors++;
            chk("r", v->FinalColor[0] & 0x1FF, bits(b, 57, 9));
            chk("g", v->FinalColor[1] & 0x1FF, bits(b, 66, 9));
            chk("b", v->FinalColor[2] & 0x1FF, bits(b, 75, 9));
            chk("s", (u16)v->TexCoords[0], bits(b, 84, 16));
            chk("t", (u16)v->TexCoords[1], bits(b, 100, 16));
        }
    }
    if (!ok && g_order_dump)
        for (int i = 0; i < n && i < 40; i++)
        {
            const Polygon* p = g.RenderPolygonRAM[i];
            int ri = i < (int)rtl.order.size() ? rtl.order[i] : -1;
            const Rtl::Rec* r = (ri >= 0 && rtl.recs.count(ri)) ? &rtl.recs[ri] : nullptr;
            printf("  %2d melonDS key %05X attr %08X tp %08X | RTL idx %d key %05X attr %08X tp %08X\n", i, p->SortKey, p->Attr, p->TexParam,
                   ri, r ? ((bits(r->h, 97, 8) << 8) | bits(r->h, 89, 8)) : 0, r ? r->h[0] : 0, r ? r->h[1] : 0);
        }
    if (verbose || !ok) printf("frame %d: %d polygons %s\n", frame, n, ok ? "ok" : "DIFFER");
    return ok;
}

// ------------------------------------------------------------------ trace mode
struct Trace
{
    std::vector<u8> d;
    size_t i = 0;
    bool load(const char* path)
    {
        FILE* f = fopen(path, "rb");
        if (!f) return false;
        fseek(f, 0, SEEK_END);
        d.resize(ftell(f));
        fseek(f, 0, SEEK_SET);
        bool ok = fread(d.data(), 1, d.size(), f) == d.size();
        fclose(f);
        return ok && d.size() >= 8 && !memcmp(d.data(), "NDSGX001", 8);
    }
    template<typename T> T get() { T v; memcpy(&v, &d[i], sizeof v); i += sizeof v; return v; }
};

// test results, read as a game does: wait for GXSTAT bit 0, then the registers
u64 g_tests = 0;
bool check_tests(Golden& gd, Rtl& rtl, u8 cmd, u64 at)
{
    GPU3D& g = *gd.g;
    u32 st;
    if (g.GXStat & 1)
    {
        // melonDS's test count is stuck (a parameter taken by another command): wait for the engine
        if (!rtl.wait_idle()) { fprintf(stderr, "entry %llu: not idle\n", (unsigned long long)at); return false; }
        st = rtl.read(0x04000600);
    }
    else
        for (int i = 0; (st = rtl.read(0x04000600)) & 1; i++)
            if (i > 100000) { fprintf(stderr, "entry %llu: test never finished\n", (unsigned long long)at); return false; }
    bool ok = true;
    g_tests++;
    if (cmd == 0x70 && ((st >> 1) & 1) != ((g.GXStat >> 1) & 1))
    {
        ok = false;
        fprintf(stderr, "entry %llu: BOX_TEST melonDS %u RTL %u\n", (unsigned long long)at, (g.GXStat >> 1) & 1, (st >> 1) & 1);
    }
    if (cmd == 0x71)
        for (int k = 0; k < 4; k++)
        {
            u32 v = rtl.read(0x04000620 + 4 * k);
            if (v != (u32)g.PosTestResult[k])
            { ok = false; fprintf(stderr, "entry %llu: POS_TEST[%d] melonDS %08X RTL %08X\n", (unsigned long long)at, k, g.PosTestResult[k], v); }
        }
    if (cmd == 0x72)
    {
        u32 a = rtl.read(0x04000630), b = rtl.read(0x04000634);
        u32 ea = (u16)g.VecTestResult[0] | ((u32)(u16)g.VecTestResult[1] << 16), eb = (u16)g.VecTestResult[2];
        if (a != ea || (b & 0xFFFF) != eb)
        { ok = false; fprintf(stderr, "entry %llu: VEC_TEST melonDS %08X %04X RTL %08X %04X\n", (unsigned long long)at, ea, eb, a, b & 0xFFFF); }
    }
    return ok;
}

bool check_matrices(Golden& gd, Rtl& rtl, int frame)
{
    GPU3D& g = *gd.g;
    bool ok = true;
    for (int k = 0; k < 16; k++)
    {
        u32 v = rtl.read(0x04000640 + 4 * k);
        u32 e = g.Read32(0x04000640 + 4 * k);
        if (v != e) { ok = false; fprintf(stderr, "frame %d: clip[%d] melonDS %08X RTL %08X\n", frame, k, e, v); }
    }
    for (int k = 0; k < 9; k++)
    {
        u32 v = rtl.read(0x04000680 + 4 * k);
        u32 e = g.Read32(0x04000680 + 4 * k);
        if (v != e) { ok = false; fprintf(stderr, "frame %d: vec[%d] melonDS %08X RTL %08X\n", frame, k, e, v); }
    }
    return ok;
}

int g_debug = 0;
size_t g_plog_from = ~(size_t)0, g_plog_to = 0;
bool g_counts = false;
void dbg(Rtl& rtl, const char* tag)
{
    auto* r = rtl.m->rootp;
    u64 tm = r->gpu3d_geom__DOT__u_front__DOT__tm;
    printf("%s cyc %llu mx %u dp %u f %u p %u CC %d vp %d np %d pp %d vsc %d vsf %x pend %d/%d flush %u upc %03x busy %u\n",
           tag, (unsigned long long)rtl.cyc,
           r->gpu3d_geom__DOT__u_front__DOT__mx, r->gpu3d_geom__DOT__u_eng__DOT__dp_r,
           r->gpu3d_geom__DOT__u_front__DOT__f, r->gpu3d_geom__DOT__u_front__DOT__p,
           (int)(short)(tm >> 28), (int)(tm >> 25) & 7, (int)(tm >> 22) & 7, (int)(tm >> 16) & 63,
           (int)(tm >> 12) & 15, (int)(tm >> 7) & 31, (int)(tm >> 6) & 1, (int)tm & 63,
           r->gpu3d_geom__DOT__u_front__DOT__flush,
           r->gpu3d_geom__DOT__u_eng__DOT__upc, r->gpu3d_geom__DOT__u_front__DOT__busy);
}

bool g_lock = false;
int g_gap = 0;
u32 g_gseed = 1;
bool g_packed = false;
int g_mread = 0;
bool g_mpoll = false;
int g_pobusy = 0;
bool g_rwall = false;
u64 g_rwp_from = ~0ull, g_rwp_to = 0;
u64 g_from = ~0ull, g_to = 0;
int g_lockframe = 0;

// --rwlog FILE: the system's geometry register writes and reads in order ("GW off data", "GR off data", offsets from
// 0x04000400, as a p_rdlog sim prints them); each read is compared with the logged word. A flush waiting for VBlank
// gets one as soon as it is reached (the system's VBlank comes later; the order of the stream is what counts here)
int run_rwlog(const char* path)
{
    FILE* f = fopen(path, "r");
    if (!f) { fprintf(stderr, "cannot read %s\n", path); return 1; }
    Rtl rtl;
    char k[8];
    unsigned a, d;
    u64 n = 0, nr = 0, bad = 0;
    auto vb = [&]() { rtl.m->vblank = 1; rtl.cycle(); rtl.m->vblank = 0; };
    while (fscanf(f, "%7s %x %x", k, &a, &d) == 3)
    {
        n++;
        if (!strcmp(k, "GW"))
        {
            auto* m = rtl.m.get();
            m->io_req = 1; m->io_we = 1; m->io_be = 0xF; m->io_addr = ((0x04000400 + a) >> 2) & 0xFF; m->io_wdata = d;
            for (u64 w = 0;; w++)
            {
                m->clk = 0; m->tick = rtl.cyc & 1; m->eval();
                bool wait = m->io_wait;
                rtl.cycle();
                if (!wait) break;
                if (m->dbg_flush) vb();
                if (w > 50000000) { fprintf(stderr, "line %llu: write never taken\n", (unsigned long long)n); return 2; }
            }
            m->io_req = 0; m->io_we = 0;
            if (n >= g_rwp_from && n <= g_rwp_to)
            {
                if (!rtl.wait_idle()) { printf("line %llu: not idle\n", (unsigned long long)n); return 2; }
                printf("P %llu %03X %08X:", (unsigned long long)n, a, d);
                for (int j = 0; j < 16; j++) printf(" %08X", rtl.read(0x04000640 + 4 * j));
                printf(" |");
                for (int j = 0; j < 9; j++) printf(" %08X", rtl.read(0x04000680 + 4 * j));
                printf("\n");
            }
        }
        else
        {
            nr++;
            u32 v = rtl.read(0x04000400 + a);
            // a GXSTAT read the game saw not busy: poll as it does until bit 27 clears
            if ((a & 0x3FC) == 0x200 && !(d & (1u << 27)))
                for (int t = 0; (v & (1u << 27)) && t < 2000000; t++) v = rtl.read(0x04000400 + a);
            if (g_rwall) printf("R %llu %03X %08X cyc %llu\n", (unsigned long long)n, a, v, (unsigned long long)rtl.cyc);
            if (v != d && (a & 0x3FC) != 0x200 && bad++ < 40 && !g_rwall)
                printf("line %llu: read %03X system %08X bench %08X\n", (unsigned long long)n, a, d, v);
        }
    }
    printf("%s: %llu lines, %llu reads, %llu differ (GXSTAT not compared)\n", path, (unsigned long long)n, (unsigned long long)nr, (unsigned long long)bad);
    return bad != 0;
}

int run_trace(const char* path, int max_frames, bool verbose)
{
    std::vector<u64> fcyc;
    std::vector<double> futil;
    Trace t;
    if (!t.load(path)) { fprintf(stderr, "cannot read %s\n", path); return 1; }
    t.i = 8;
    Golden gd;
    Rtl rtl;
    rtl.dbg_from = g_from; rtl.dbg_to = g_to;
    rtl.gap = g_gap; rtl.gseed = g_gseed; rtl.packed = g_packed;
    rtl.po_busy = g_pobusy;
    int frames = 0, bad = 0;
    u64 entries = 0;
    while (t.i < t.d.size())
    {
        u8 k = t.get<u8>();
        if (k == 'C')
        {
            Entry e;
            e.cmd = t.get<u8>();
            e.param = t.get<u32>();
            gd.entry(e);
            rtl.entry(e);
            entries++;
            if (e.cmd >= 0x70 && e.cmd <= 0x72 && gd.g->ExecParamCount == 0)
                if (!check_tests(gd, rtl, e.cmd, entries)) bad++;
            // --mread N: the clip and vector matrices read back (CLIPMTX_RESULT, VECMTX_RESULT) after every Nth
            // complete command, once the engine is idle, as a game reads them mid-frame
            if (g_mread && entries % g_mread == 0 && gd.g->ExecParamCount == 0)
            {
                // --mpoll: poll GXSTAT bit 27 as a game does (the DS timing model's busy), not the engine's idle: entries
                // the model executed can still wait in the engine's queue (on chip, in the gather or in the SDRAM spill),
                // and the read must not overtake them
                if (g_mpoll)
                {
                    u32 st = 0; int t = 0;
                    for (; ((st = rtl.read(0x04000600)) >> 27) & 1 && t < 2000000; t++) {}
                    if (t >= 2000000) { fprintf(stderr, "entry %llu: GXSTAT stays busy\n", (unsigned long long)entries); return 2; }
                }
                else if (!rtl.wait_idle()) { fprintf(stderr, "entry %llu: RTL not idle\n", (unsigned long long)entries); return 2; }
                if (!check_matrices(gd, rtl, frames)) { bad++; if (bad < 20) fprintf(stderr, "  (entry %llu, cmd %02X)\n", (unsigned long long)entries, e.cmd); }
            }
            if (g_lock && e.cmd != 0x50)
            {
                auto* r = rtl.m->rootp;
                if (!rtl.wait_idle(200000)) { printf("entry %llu %02X: not idle\n", (unsigned long long)entries, e.cmd); dbg(rtl, "ni"); return 2; }
                bool pend = (r->gpu3d_geom__DOT__u_front__DOT__tm >> 6) & 1;
                if (pend || rtl.m->dbg_npoly != gd.g->NumPolygons || rtl.m->dbg_nvert != gd.g->NumVertices)
                {
                    printf("entry %llu %02X %08X: pend %d counts melonDS %u/%u RTL %u/%u\n", (unsigned long long)entries,
                           e.cmd, e.param, pend, gd.g->NumPolygons, gd.g->NumVertices, rtl.m->dbg_npoly, rtl.m->dbg_nvert);
                    dbg(rtl, "lk");
                    return 2;
                }
            }
            if (g_debug && entries <= (u64)g_debug) { printf("entry %02X %08X: ", e.cmd, e.param); dbg(rtl, ""); }
            // --polylog FROM TO: melonDS's polygons as entries in that byte range of the trace submit them
            if (t.i >= g_plog_from && t.i <= g_plog_to)
            {
                static u32 lp = 0, lv = 0;
                GPU3D& g = *gd.g;
                if (g.NumPolygons != lp || g.NumVertices != lv)
                {
                    printf("  @%zu %02X %08X: polys %u verts %u (+%d)", t.i - 6, e.cmd, e.param, g.NumPolygons, g.NumVertices,
                           (int)(g.NumVertices - lv));
                    if (g.NumPolygons > lp)
                    {
                        Polygon* q = &g.CurPolygonRAM[g.NumPolygons - 1];
                        Polygon* pq = g.NumPolygons >= 2 ? &g.CurPolygonRAM[g.NumPolygons - 2] : nullptr;
                        printf(" | n %u clipped ", q->NumVertices);
                        for (u32 k = 0; k < q->NumVertices; k++) printf("%d", q->Vertices[k]->Clipped ? 1 : 0);
                        int shared = 0;
                        if (pq) for (u32 k = 0; k < q->NumVertices; k++) for (u32 j = 0; j < pq->NumVertices; j++) shared += q->Vertices[k] == pq->Vertices[j];
                        printf(" shared-with-prev %d facing %d", shared, (int)q->FacingView);
                        for (u32 k = 0; k < q->NumVertices; k++)
                            printf(" (%d,%d,%d,%d)", q->Vertices[k]->Position[0], q->Vertices[k]->Position[1], q->Vertices[k]->Position[2], q->Vertices[k]->Position[3]);
                    }
                    printf("\n");
                }
                lp = g.NumPolygons; lv = g.NumVertices;
            }
        }
        else if (k == 'F')
        {
            u32 fframe = t.get<u32>(); t.get<u32>(); t.get<u32>(); t.get<u32>();
            u32 fattr = t.get<u32>();
            t.i += 1 + 64 + 16 + 4 + 4 + 32 + 4 + 4;
            // a trace that starts inside a frame may reach a flush without a
            // SWAP_BUFFERS: give both one with the traced attributes
            if (!gd.g->FlushRequest) { Entry sw{0x50, fattr}; gd.entry(sw); rtl.entry(sw); }
            // the RTL must reach the flush, then VBlank swaps both
            for (u64 w = 0; !rtl.m->dbg_flush; w++)
            {
                rtl.cycle();
                if (g_debug && w < 40) dbg(rtl, "wf");
                if (w > 50000000) {
                    fprintf(stderr, "frame %d: RTL never reached the flush (entries %llu)\n", frames, (unsigned long long)entries);
                    dbg(rtl, "stuck");
                    printf("model submissions %llu, engine outcomes %llu\n", (unsigned long long)rtl.n_sub, (unsigned long long)rtl.n_oc);
                    auto* r = rtl.m->rootp;
                    printf("pend %d stall %u ev %u\n", (int)((r->gpu3d_geom__DOT__u_front__DOT__tm >> 0) & 0), rtl.m->dbg_stall,
                           r->gpu3d_geom__DOT__u_eng__DOT__dp_r != r->gpu3d_geom__DOT__u_front__DOT__mx);
                    return 2;
                }
            }
            if (!rtl.wait_idle()) { fprintf(stderr, "frame %d: RTL not idle\n", frames); return 2; }
            if (rtl.m->dbg_npoly != gd.g->NumPolygons || rtl.m->dbg_nvert != gd.g->NumVertices)
            {
                bad++;
                fprintf(stderr, "frame %d: counts melonDS %u/%u RTL %u/%u\n", frames, gd.g->NumPolygons,
                        gd.g->NumVertices, rtl.m->dbg_npoly, rtl.m->dbg_nvert);
            }
            if (g_counts) printf("counts %d %u %u\n", frames, (unsigned)rtl.m->dbg_npoly, (unsigned)rtl.m->dbg_nvert);
            gd.g->FlushRequest = 1;
            gd.g->FlushAttributes = fattr;
            gd.g->VBlank();
            rtl.swapped = false;
            rtl.order.assign(2048, -1);
            rtl.m->vblank = 1;
            rtl.cycle();
            rtl.m->vblank = 0;
            for (u64 w = 0; !rtl.swapped; w++)
            {
                rtl.cycle();
                if (w > 1000000) {
                    auto* r = rtl.m->rootp;
                    fprintf(stderr, "frame %d: no swap (sort st %d k %d swap_go %d upc %03x)\n", frames,
                            SORT_ST(r), SORT_K(r),
                            r->gpu3d_geom__DOT__swap_go, r->gpu3d_geom__DOT__u_eng__DOT__upc);
                    return 2;
                }
            }
            if (!compare_frame(gd, rtl, frames, verbose)) bad++;
            if (!check_matrices(gd, rtl, frames)) bad++;
            {
                // engine clocks for this flush's entries (the replay runs flat out)
                // against the time the game gave it: video frames since the last flush
                static u64 last = 0;
                static u32 lastf = 0;
                fcyc.push_back(rtl.cyc - last);
                if (frames > 0) futil.push_back((double)(rtl.cyc - last) / ((fframe - lastf) * 1120340.0));
                if (g_fstat && frames > 0)
                    printf("flush %d frame %u: %llu clocks, %u frames, util %.2f, polys %u verts %u\n", frames, fframe,
                           (unsigned long long)(rtl.cyc - last), fframe - lastf, (double)(rtl.cyc - last) / ((fframe - lastf) * 1120340.0),
                           gd.g->RenderNumPolygons, 0u);
                last = rtl.cyc;
                lastf = fframe;
            }
            rtl.recs.clear();
            frames++;
            g_cur_frame = frames;
            if (max_frames && frames >= max_frames) break;
        }
        else if (k == 'V')
        {
            t.get<u32>();
            t.i += 9;
            static const u32 sz[9] = {128, 128, 128, 128, 64, 16, 16, 32, 16};
            for (int b = 0; b < 9; b++) t.i += sz[b] * 1024;
        }
        else { fprintf(stderr, "bad record\n"); return 1; }
    }
    if (rtl.eq_bad) { bad++; printf("EQ: %llu cycles where the reference front disagrees\n", (unsigned long long)rtl.eq_bad); }
    printf("%s: %d frames, %llu entries, %llu test results, %d differ; RTL %llu cycles, model waited %llu, writes waited %llu\n",
           path, frames, (unsigned long long)entries, (unsigned long long)g_tests, bad, (unsigned long long)rtl.cyc,
           (unsigned long long)rtl.stall_cycles, (unsigned long long)rtl.wait_cycles);
    if (!futil.empty())
    {
        std::vector<double> u = futil;
        std::sort(u.begin(), u.end());
        printf("engine time / time between flushes: p50 %.2f p90 %.2f max %.2f\n", u[u.size() / 2], u[u.size() * 9 / 10], u.back());
    }
    if (!fcyc.empty())
    {
        std::vector<u64> v(fcyc.begin() + 1, fcyc.end());
        if (!v.empty())
        {
            std::sort(v.begin(), v.end());
            printf("clocks per flush (after the first): p50 %llu p90 %llu max %llu (a video frame is 1,120,340 at 67 MHz)\n",
                   (unsigned long long)v[v.size() / 2], (unsigned long long)v[v.size() * 9 / 10], (unsigned long long)v.back());
        }
    }
    if (!rtl.sort_clk.empty())
    {
        std::vector<u64> v = rtl.sort_clk;
        std::sort(v.begin(), v.end());
        printf("sort clocks (swap to so_done): p50 %llu max %llu\n", (unsigned long long)v[v.size() / 2], (unsigned long long)v.back());
    }
    prof_report();
    return bad ? 2 : 0;
}


// ------------------------------------------------------------------ synthetic streams
static bool g_edge = false;
// Random frames through the register port (command ports, packed FIFO writes,
// GXSTAT and DISP_1DOT_DEPTH), on melonDS by GPU3D::Write32 and draining the
// PIPE after every write.
struct Gen
{
    std::mt19937 rng;
    std::vector<std::pair<u32, u32>> w;     // (address, value)
    explicit Gen(u32 seed) : rng(seed) {}
    u32 r(u32 n) { return rng() % n; }
    bool chance(u32 pct) { return r(100) < pct; }
    s32 rs(s32 lo, s32 hi) { return lo + (s32)(rng() % (u32)(hi - lo + 1)); }
    u32 fx(s32 range) { return (u32)rs(-range, range); }
    // full-range matrices wrap positions, and wrapped polygons can need more
    // than the 10 clip vertices melonDS has room for (a stack overrun there):
    // only with --wild
    bool wild = false;
    u32 big() { return (wild && chance(20)) ? rng() : fx(chance(50) ? 0x1800 : (chance(50) ? 0x10000 : 0xFFFFF)); }
    void port(u8 c, u32 v) { w.push_back({0x04000440 + (c - 0x10) * 4, v}); }
    void cmd(u8 c, std::initializer_list<u32> ps)
    {
        if (ps.size() == 0) port(c, rng());
        for (u32 v : ps) port(c, v);
    }
    // a packed word of up to four commands followed by their parameters
    void packed(const std::vector<std::pair<u8, std::vector<u32>>>& cs)
    {
        u32 word = 0;
        for (size_t i = 0; i < cs.size(); i++) word |= (u32)cs[i].first << (8 * i);
        w.push_back({0x04000400, word});
        for (auto& c : cs) for (u32 v : c.second) w.push_back({0x04000400, v});
    }
    u32 v16(s32 range) { return (u32)(u16)rs(-range, range); }
    u32 n10() { return (u32)r(1 << 30); }
    u32 col() { return (u32)r(1 << 15); }
    void matrix(u8 c, int n, bool sane)
    {
        std::vector<u32> ps;
        for (int i = 0; i < n; i++) ps.push_back(sane ? fx((i % 5 == 0) ? 0x1400 : 0x0C00) : big());
        for (u32 v : ps) port(c, v);
    }
    void projection()
    {
        cmd(0x10, {0});
        if (chance(20)) { matrix(0x16, 16, false); return; }
        double fov = 0.5 + r(100) / 60.0, nearz = 0.05 + r(100) / 100.0, farz = nearz + 1 + r(400) / 10.0;
        double f = 1 / tan(fov / 2), a = 256.0 / 192.0;
        s32 m[16] = {0};
        m[0] = (s32)(f / a * 4096); m[5] = (s32)(f * 4096);
        m[10] = (s32)((nearz + farz) / (nearz - farz) * 4096); m[11] = -4096;
        m[14] = (s32)(2 * nearz * farz / (nearz - farz) * 4096);
        for (int i = 0; i < 16; i++) port(0x16, (u32)m[i]);
    }
    void modelview()
    {
        cmd(0x10, {r(2) ? 2u : 1u});
        cmd(0x15, {});
        if (chance(70)) cmd(0x1C, {fx(0x4000), fx(0x4000), (u32)rs(-0x30000, -0x1000)});
        if (chance(40)) matrix(0x19, 12, true);
        if (chance(30)) matrix(0x1A, 9, true);
        if (chance(30)) cmd(0x1B, {fx(0x2000), fx(0x2000), fx(0x2000)});
        if (chance(20)) matrix(0x18, 16, !chance(30));
        if (chance(10)) matrix(0x17, 12, !chance(30));
    }
    void stack()
    {
        u32 m = r(4);
        cmd(0x10, {m});
        switch (r(5))
        {
        case 0: cmd(0x11, {}); break;
        case 1: cmd(0x12, {chance(80) ? 1u : r(64)}); break;
        case 2: cmd(0x13, {r(32)}); break;
        case 3: cmd(0x14, {r(32)}); break;
        default: if (chance(50)) cmd(0x1C, {fx(0x2000), fx(0x2000), fx(0x2000)}); else cmd(0x1B, {fx(0x1800), fx(0x1800), fx(0x1800)});
        }
    }
    void lights()
    {
        for (int l = 0; l < 4; l++)
        {
            if (chance(60)) cmd(0x32, {(u32)(l << 30) | n10()});
            if (chance(60)) cmd(0x33, {(u32)(l << 30) | col()});
        }
        if (chance(70)) cmd(0x30, {(u32)rng() & 0x7FFFFFFF});
        if (chance(70)) cmd(0x31, {(u32)rng() & 0x7FFFFFFF});
        if (chance(20)) for (int i = 0; i < 32; i++) port(0x34, rng());
    }
    void vertex(s32 range)
    {
        switch (r(8))
        {
        case 0: case 1: cmd(0x23, {v16(range) | (v16(range) << 16), v16(range)}); break;
        case 2: cmd(0x24, {(u32)r(1 << 30)}); break;
        case 3: cmd(0x25, {v16(range) | (v16(range) << 16)}); break;
        case 4: cmd(0x26, {v16(range) | (v16(range) << 16)}); break;
        case 5: cmd(0x27, {v16(range) | (v16(range) << 16)}); break;
        default: cmd(0x28, {(u32)r(1 << 30) & 0x3F8FE3F8u}); break;   // small deltas
        }
    }
    void batch()
    {
        u32 attr = (u32)rng() & 0x3F1FF8FF;
        if (chance(60)) attr |= 0xC0;                                   // show both faces
        if (chance(50)) attr = (attr & ~0x1F0000u) | (31u << 16);
        cmd(0x29, {attr});
        u32 tp = (u32)rng();
        if (chance(50)) tp &= 0x3FFFFFFF;
        cmd(0x2A, {tp});
        if (chance(50)) cmd(0x2B, {(u32)rng()});
        if ((tp >> 30) && chance(60))
        {
            cmd(0x10, {3});
            if (chance(50)) cmd(0x15, {}); else matrix(0x17, 12, true);
            if (chance(50)) matrix(0x19, 12, true);
            cmd(0x10, {2});
        }
        cmd(0x40, {r(4)});
        int n = 3 + r(14);
        s32 range = chance(70) ? 0x1800 : 0x7FFF;
        for (int i = 0; i < n; i++)
        {
            if (chance(40)) cmd(0x20, {col()});
            if (chance(30)) cmd(0x21, {n10()});
            if (chance(40)) cmd(0x22, {(u32)rng()});
            if (chance(5)) cmd(0x30, {(u32)rng()});
            vertex(range);
        }
        if (chance(80)) cmd(0x41, {});
        if (chance(15)) cmd(0x70, {v16(0x2000) | (v16(0x2000) << 16), v16(0x2000) | (v16(0x1000) << 16), v16(0x1000) | (v16(0x1000) << 16)});
        if (chance(10)) cmd(0x71, {v16(0x2000) | (v16(0x2000) << 16), v16(0x2000)});
        if (chance(10)) cmd(0x72, {n10()});
    }
    // Directed frames: every vertex of a polygon is just outside one x or y plane (comp - w, or -w - comp,
    // 1..21 units), w varies with z and the other axis crosses its planes, so the clipper interpolates
    // before it reaches that plane: the rounding of ClipSegment decides whether a vertex survives.
    void frame_edge()
    {
        cmd(0x60, {0xBFFF0000});
        for (int b = 0; b < 24; b++)
        {
            int a = r(2), o = 1 - a;
            s32 sg = r(2) ? 1 : -1, d0 = 1 + r(6);
            s32 m[16] = {0};
            m[4 * a + a] = sg * 0x100; m[8 + a] = sg * 0x1000; m[12 + a] = sg * d0;
            m[4 * o + o] = 0x1000; m[10] = 0x1000; m[11] = 0x1000;
            cmd(0x10, {0});
            for (int i = 0; i < 16; i++) port(0x16, (u32)m[i]);
            cmd(0x10, {2}); cmd(0x15, {});
            cmd(0x29, {0xC0u | (31u << 16) | ((u32)r(64) << 24)});
            cmd(0x40, {r(2)});
            int n = 3 + r(2);
            for (int i = 0; i < n; i++)
            {
                s32 va = chance(50) ? r(24) : r(0x3001), vo = rs(-0x7000, 0x7000), vz = chance(70) ? rs(-0x7000, 0x7000) : rs(0x400, 0x7000); if (vz == 0) vz = 1;
                s32 xy[2]; xy[a] = va; xy[o] = vo;
                cmd(0x23, {(u32)(u16)xy[0] | ((u32)(u16)xy[1] << 16), (u32)(u16)vz});
            }
            cmd(0x41, {});
        }
        cmd(0x50, {0});
    }
    void frame()
    {
        if (g_edge) { frame_edge(); return; }
        if (chance(30)) cmd(0x60, {(u32)rng()}); else cmd(0x60, {0xBFFF0000});
        if (chance(15)) w.push_back({0x04000610, (u32)r(0x8000)});
        if (chance(10)) w.push_back({0x04000600, 0x8000u | ((u32)r(3) << 30)});   // clear the stack error
        projection();
        modelview();
        lights();
        int nb = 1 + r(12);
        for (int b = 0; b < nb; b++)
        {
            if (chance(30)) stack();
            if (chance(20)) modelview();
            if (chance(10))
            {
                // an incomplete multi-parameter command, then another one (ExecParamCount carries over)
                u8 c = (u8)(0x16 + r(7));
                for (int i = 0, k = 1 + r(5); i < k; i++) port(c, big());
            }
            if (chance(10))
                packed({{0x15, {}}, {0x1C, {fx(0x1000), fx(0x1000), fx(0x1000)}}, {0x11, {}}, {0x12, {1}}});
            batch();
        }
        cmd(0x50, {r(4)});
    }
};

bool drain(Golden& gd)
{
    for (int i = 0; !gd.g->CmdPIPE.IsEmpty(); i++)
    {
        if (i > 100000) return false;
        gd.g->ExecuteCommand();
    }
    return true;
}

bool g_wild = false;

int run_synth(int nframes, u32 seed, bool verbose)
{
    Golden gd;
    Rtl rtl;
    Gen gen(seed);
    gen.wild = g_wild;
    int bad = 0;
    u64 writes = 0;
    for (int f = 0; f < nframes; f++)
    {
        gen.w.clear();
        gen.frame();
        for (auto [a, v] : gen.w)
        {
            rtl.write(a, v);
            gd.g->Write32(a, v);
            writes++;
            if (!drain(gd)) { fprintf(stderr, "melonDS did not drain\n"); return 1; }
            u8 c = (a >= 0x04000440 && a < 0x040005CC) ? (u8)(((a & 0x1FC) >> 2)) : 0;
            if (c >= 0x70 && c <= 0x72 && gd.g->ExecParamCount == 0)
                if (!check_tests(gd, rtl, c, writes)) bad++;
            {
                auto* rr = rtl.m->rootp;
                if (rr->gpu3d_geom__DOT__u_front__DOT__pk_nc != gd.g->NumCommands ||
                    (gd.g->NumCommands && (rr->gpu3d_geom__DOT__u_front__DOT__pk_cur != gd.g->CurCommand ||
                                           rr->gpu3d_geom__DOT__u_front__DOT__pk_pc != gd.g->ParamCount)))
                {
                    printf("write %llu (%08X = %08X): packer melonDS %u %08X %u RTL %u %08X %u\n", (unsigned long long)writes, a, v,
                           gd.g->NumCommands, gd.g->CurCommand, gd.g->ParamCount, rr->gpu3d_geom__DOT__u_front__DOT__pk_nc,
                           rr->gpu3d_geom__DOT__u_front__DOT__pk_cur, rr->gpu3d_geom__DOT__u_front__DOT__pk_pc);
                    return 2;
                }
            }
            if (g_lock && c != 0x50 && f >= g_lockframe)
            {
                if (!rtl.wait_idle(200000)) { printf("write %llu: not idle\n", (unsigned long long)writes); return 2; }
                auto* rr = rtl.m->rootp;
                bool identok = true;
                auto RF = [&](u32 a) { return (u32)rr->gpu3d_geom__DOT__u_eng__DOT__u_rfa__DOT__mem[a & 2047]; };
                for (int k = 0; k < 16; k++)
                    if (RF(RF_IDENT + k) != ((k % 5 == 0) ? 0x1000u : 0u)) identok = false;
                if (!identok) printf("write %llu (%08X = %08X): IDENT rows changed\n", (unsigned long long)writes, a, v);
#if GEOM_FF
                // FF: CurVertex lives in its latch (the dispatcher decodes vertices without the words)
                auto CV = [&](int k) { return (u32)rr->gpu3d_geom__DOT__u_eng__DOT__at_v[k]; };
#else
                auto CV = [&](int k) { return RF(RF_CURV + k); };
#endif
                if ((u16)CV(0) != (u16)gd.g->CurVertex[0] ||
                    (u16)CV(1) != (u16)gd.g->CurVertex[1] ||
                    (u16)CV(2) != (u16)gd.g->CurVertex[2])
                {
                    printf("write %llu (%08X = %08X): CurVertex melonDS %04X %04X %04X RTL %04X %04X %04X (ExecParamCount %u pi %u)\n",
                           (unsigned long long)writes, a, v, (u16)gd.g->CurVertex[0], (u16)gd.g->CurVertex[1], (u16)gd.g->CurVertex[2],
                           (u16)CV(0), (u16)CV(1), (u16)CV(2),
                           gd.g->ExecParamCount, rr->gpu3d_geom__DOT__u_eng__DOT__pi);
                    return 2;
                }
                if (!identok || !check_matrices(gd, rtl, f) || rtl.m->dbg_npoly != gd.g->NumPolygons)
                {
                    printf("write %llu (%08X = %08X) cmd %02X: diverged (polys melonDS %u RTL %u) at cycle %llu\n", (unsigned long long)writes,
                           a, v, c, gd.g->NumPolygons, rtl.m->dbg_npoly, (unsigned long long)rtl.cyc);
                    u32 wrp = rr->gpu3d_geom__DOT__u_front__DOT__wr;
                    for (int k = 6; k >= 1; k--) {
                        u64 e = rr->UENT(mem)[(wrp - k) & 511];
                        printf("  RAM[%u] = %02X %08X\n", (wrp - k) & 511, (u32)(e >> 32), (u32)e);
                    }
                    printf("  mmode RTL %u melonDS %u; PolygonMode %u CurPolygonAttr %08X ZeroDotWLimit %06X DispCnt %08X\n",
                           RF(RF_MMODE), gd.g->MatrixMode, gd.g->PolygonMode, gd.g->CurPolygonAttr,
                           gd.g->ZeroDotWLimit, gd.g->DispCnt);
                    for (int k = 0; k < 4; k++)
                        printf("  TVB[%d] %08X %08X %08X %08X\n", k, gd.g->TempVertexBuffer[k].Position[0], gd.g->TempVertexBuffer[k].Position[1],
                               gd.g->TempVertexBuffer[k].Position[2], gd.g->TempVertexBuffer[k].Position[3]);
                    for (int sl = 0; sl < 6; sl++)
                    {
                        u32 g = RF(RF_SLOT + sl);
                        printf("  RTL slot %d (group %u) P %08X %08X %08X %08X\n", sl, (g - RF_GRP) / 16,
                               RF(g), RF(g + 1), RF(g + 2), RF(g + 3));
                    }
                    for (auto& [idx, rec] : rtl.recs)
                    {
                        printf("  RTL poly %d: n %u attr %08X\n", idx, bits(rec.h, 77, 4), rec.h[0]);
                        for (auto& b : rec.v) printf("    x %u y %u z %06X w %04X\n", bits(b.data(), 0, 9), bits(b.data(), 9, 8), bits(b.data(), 17, 24), bits(b.data(), 41, 16));
                    }
                    return 2;
                }
            }
        }
        for (u64 wt = 0; !rtl.m->dbg_flush; wt++)
        {
            rtl.cycle();
            if (wt > 50000000) { fprintf(stderr, "synth frame %d: RTL never reached the flush\n", f); dbg(rtl, "stuck"); return 2; }
        }
        if (!rtl.wait_idle()) { fprintf(stderr, "synth frame %d: not idle\n", f); dbg(rtl, "stuck"); return 2; }
        u32 st = rtl.read(0x04000600);
        u32 gst = gd.g->Read32(0x04000600);
        if ((st & 0xBF02) != (gst & 0xBF02))
        { bad++; fprintf(stderr, "synth frame %d: GXSTAT melonDS %08X RTL %08X\n", f, gst, st); }
        if (rtl.m->dbg_npoly != gd.g->NumPolygons || rtl.m->dbg_nvert != gd.g->NumVertices)
        {
            bad++;
            fprintf(stderr, "synth frame %d: counts melonDS %u/%u RTL %u/%u\n", f, gd.g->NumPolygons, gd.g->NumVertices,
                    rtl.m->dbg_npoly, rtl.m->dbg_nvert);
        }
        bool govf = gd.g->DispCnt & (1 << 13);
        if (govf != rtl.ovf) { bad++; fprintf(stderr, "synth frame %d: overflow melonDS %d RTL %d\n", f, govf, rtl.ovf); }
        gd.g->DispCnt &= ~(1u << 13);
        rtl.ovf = false;
        gd.g->VBlank();
        rtl.swapped = false;
        rtl.order.assign(2048, -1);
        rtl.m->vblank = 1;
        rtl.cycle();
        rtl.m->vblank = 0;
        for (u64 wt = 0; !rtl.swapped; wt++)
        {
            rtl.cycle();
            if (wt > 1000000) { fprintf(stderr, "synth frame %d: no swap\n", f); return 2; }
        }
        if (!compare_frame(gd, rtl, f, verbose)) bad++;
        if (!check_matrices(gd, rtl, f)) bad++;
        rtl.recs.clear();
    }
    if (rtl.eq_bad) { bad++; printf("EQ: %llu cycles where the reference front disagrees\n", (unsigned long long)rtl.eq_bad); }
    printf("synth seed %u: %d frames, %llu writes, %llu test results, %d differ (%llu vertex colours beyond 9 bits)\n", seed, nframes,
           (unsigned long long)writes, (unsigned long long)g_tests, bad, (unsigned long long)g_wide_colors);
    return bad ? 2 : 0;
}

// ------------------------------------------------------------------ timing
// The front's timing against melonDS's GPU3D::Run, system cycle by system
// cycle: melonDS's timestamp advances one cycle per tick and Run() is called;
// the synthetic writes go to the RTL's port, and to melonDS (Write32, after
// that cycle's Run) in the system cycle where the RTL counts the write's
// entries into the FIFO (phase B, after the cycle's step), or where the write
// completes if it stages none. The front's GXSTAT bits (FIFO level, empty,
// half, busy, push/pop and test bits, stack pointers, IRQ mode) are compared
// after every system cycle. Writes wait while the FIFO holds 240 entries or
// more, so the FIFO-full stall is not exercised here.
int g_timing = 0;
int run_timing(int nframes, u32 seed)
{
    Golden gd;
    Rtl rtl;
    Gen gen(seed);
    auto* r = rtl.m->rootp;
    if (!(rtl.cyc & 1)) rtl.cycle();            // the next clock is a tick
    u64 t = 0, writes = 0, bad = 0;
    auto mel_stat = [&]() {
        u32 lv = gd.g->CmdFIFO.Level();
        return gd.g->GXStat | ((gd.g->PosMatrixStackPointer & 0x1F) << 8) | ((gd.g->ProjMatrixStackPointer & 1) << 13) |
               (lv << 16) | (lv < 128 ? (1u << 25) : 0) | (lv == 0 ? (1u << 26) : 0);
    };
    auto syscycle = [&](bool req, u32 a, u32 v, bool& counted, bool& done, bool vb = false) {
        // RTL: the tick clock, then phase B
        counted = false; done = false;
        for (int k = 0; k < 2; k++)
        {
            rtl.m->vblank = vb && k == 0;
            rtl.m->io_req = req && !done; rtl.m->io_we = 1; rtl.m->io_be = 0xF;
            rtl.m->io_addr = (a >> 2) & 0xFF; rtl.m->io_wdata = v;
            rtl.m->clk = 0; rtl.m->tick = rtl.cyc & 1; rtl.m->eval();
            if (req && !done && !rtl.m->io_wait) done = true;
            if (r->gpu3d_geom__DOT__u_front__DOT__count_now) counted = true;
            rtl.cycle();
        }
        rtl.m->io_req = 0; rtl.m->io_we = 0; rtl.m->vblank = 0;
        // melonDS: this cycle's Run; the VBlank after it (the RTL's flush clears at the tick's edge, after
        // that tick's step)
        t++;
        gd.nds->ARM9Timestamp = t << gd.nds->ARM9ClockShift;
        gd.g->Run();
        if (vb) gd.g->VBlank();
    };
    for (int f = 0; f < nframes; f++)
    {
        gen.w.clear();
        gen.frame();
        size_t wi = 0;
        u32 gap = 0;
        bool pend = false, applied = false;
        u32 a = 0, v = 0;
        for (u64 guard = 0; wi < gen.w.size() || pend; guard++)
        {
            if (guard > 50000000)
            {
                printf("timing frame %d: stuck (write %zu/%zu pend %d %08X=%08X, RTL f %u p %u flush %d wait %d act %d; melonDS fifo %u pipe %u flush %d stall %d)\n",
                       f, wi, gen.w.size(), pend, a, v, r->gpu3d_geom__DOT__u_front__DOT__f, r->gpu3d_geom__DOT__u_front__DOT__p,
                       rtl.m->dbg_flush, rtl.m->io_wait, r->gpu3d_geom__DOT__u_front__DOT__act, gd.g->CmdFIFO.Level(), gd.g->CmdPIPE.Level(),
                       gd.g->FlushRequest, (gd.nds->CPUStop & CPUStop_GXStall) != 0);
                printf("  RTL wr %u dp %u mx %u upc %03x\n", r->gpu3d_geom__DOT__u_front__DOT__wr, r->gpu3d_geom__DOT__u_eng__DOT__dp_r,
                       r->gpu3d_geom__DOT__u_front__DOT__mx, r->gpu3d_geom__DOT__u_eng__DOT__upc);
                return 2;
            }
            if (!pend && gap == 0 && r->gpu3d_geom__DOT__u_front__DOT__f < 240)
            {
                a = gen.w[wi].first; v = gen.w[wi].second; wi++;
                pend = true; applied = false; writes++;
                gap = gen.r(8) == 0 ? gen.r(40) : gen.r(3);
            }
            else if (!pend && gap) gap--;
            bool counted, done;
            // a SWAP inside the frame (random packed bytes can hold 0x50) stops the geometry until VBlank,
            // and the cheap model can run up to 511 entries ahead of the engine: a VBlank every DS frame
            // (560,190 system cycles), as on the DS
            bool vb = t % 560190 == 560189;
            syscycle(pend, a, v, counted, done, vb);
            if (pend && !applied && (counted || done)) { gd.g->Write32(a, v); applied = true; }
            if (pend && done) pend = false;
            // melonDS takes a packed word's entries at once, the RTL as they are unpacked: no comparison
            // while the write's entries are partly counted
            bool partial = pend && applied && r->gpu3d_geom__DOT__u_front__DOT__st_a != r->gpu3d_geom__DOT__u_front__DOT__st_n;
            u32 ms = mel_stat() & 0xCFFFFF01u, rs = r->gpu3d_geom__DOT__gxstat & 0xCFFFFF01u;
            if (partial) ms = rs;
            static int cyc_bad = 0;
            if (getenv("TIMING_CYC") && cyc_bad < 3 && gd.g->CycleCount != (int)(short)(r->gpu3d_geom__DOT__u_front__DOT__tm >> 28) &&
                !(gd.g->CycleCount <= 0 && (short)(r->gpu3d_geom__DOT__u_front__DOT__tm >> 28) <= 0))
            {
                cyc_bad++;
                printf("  CYC t %llu w%llu %08X=%08X | mel cyc %d pipe %u fifo %u | rtl cyc %d p %u f %u | mel head %02X\n", (unsigned long long)t,
                       (unsigned long long)writes, a, v, gd.g->CycleCount, gd.g->CmdPIPE.Level(), gd.g->CmdFIFO.Level(),
                       (int)(short)(r->gpu3d_geom__DOT__u_front__DOT__tm >> 28), r->gpu3d_geom__DOT__u_front__DOT__p,
                       r->gpu3d_geom__DOT__u_front__DOT__f, gd.g->CmdPIPE.IsEmpty() ? 0xFFu : (u32)gd.g->CmdPIPE.Peek().Command);
            }
            if (getenv("TIMING_DBG") && t + 80 >= (u64)atoll(getenv("TIMING_DBG")) && t <= (u64)atoll(getenv("TIMING_DBG")))
                printf("  t %llu w%llu %08X=%08X cnt %d done %d | mel fifo %u pipe %u cyc %d | rtl f %u p %u cyc %d\n", (unsigned long long)t,
                       (unsigned long long)writes, a, v, counted, done, gd.g->CmdFIFO.Level(), gd.g->CmdPIPE.Level(), gd.g->CycleCount,
                       r->gpu3d_geom__DOT__u_front__DOT__f, r->gpu3d_geom__DOT__u_front__DOT__p,
                       (int)(short)(r->gpu3d_geom__DOT__u_front__DOT__tm >> 28));
            if (ms != rs)
            {
                if (bad < 10)
                    printf("timing: system cycle %llu (frame %d, write %llu %08X = %08X): GXSTAT melonDS %08X RTL %08X (CycleCount %d)\n",
                           (unsigned long long)t, f, (unsigned long long)writes, a, v, ms, rs, gd.g->CycleCount);
                bad++;
            }
        }
        // run until both are idle, then swap
        for (int k = 0; k < 200000 && (gd.g->GXStat & (1 << 27) || !gd.g->CmdPIPE.IsEmpty()); k++)
        {
            bool c_, d_;
            syscycle(false, 0, 0, c_, d_);
            u32 ms = mel_stat() & 0xCFFFFF01u, rs = r->gpu3d_geom__DOT__gxstat & 0xCFFFFF01u;
            if (ms != rs) { if (bad < 10) printf("timing: system cycle %llu (frame %d, drain): GXSTAT melonDS %08X RTL %08X\n",
                                                 (unsigned long long)t, f, ms, rs); bad++; }
        }
        // the swap at VBlank, in step on both
        {
            bool c_, d_;
            syscycle(false, 0, 0, c_, d_, true);
        }
    }
    printf("timing seed %u: %d frames, %llu writes, %llu system cycles, %llu differ\n", seed, nframes,
           (unsigned long long)writes, (unsigned long long)t, (unsigned long long)bad);
    return bad ? 2 : 0;
}

}  // namespace

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
#if defined(GEOM_CHEAP) && GEOM_CHEAP
    // the RTL has GX cheap timing (gpu3d_gxfront CHEAP): melonDS gets the same table (gx-timing.patch's
    // GX_CHEAP), from this repository unless the environment names one
    if (!getenv("GX_CHEAP")) {
        std::string root = __FILE__;
        root = root.substr(0, root.rfind("/sim/gpu3d/"));
        setenv("GX_CHEAP", (root + "/tools/melonds-census/gx-cheap-table-full.txt").c_str(), 1);
    }
#endif
    const char* trace = nullptr;
    const char* rwlog = nullptr;
    int synth = 0;
    u32 seed = 1;
    int frames = 0;
    bool verbose = false;
    for (int a = 1; a < argc; a++)
    {
        if (!strcmp(argv[a], "--trace") && a + 1 < argc) trace = argv[++a];
        else if (!strcmp(argv[a], "--frames") && a + 1 < argc) frames = atoi(argv[++a]);
        else if (!strcmp(argv[a], "-v")) verbose = true;
        else if (!strcmp(argv[a], "--order")) g_order_dump = true;
        else if (!strcmp(argv[a], "--prof")) g_prof = true;
        else if (!strcmp(argv[a], "--prof-dump") && a + 1 < argc) { g_prof = true; g_prof_dump = argv[++a]; }
        else if (!strcmp(argv[a], "--pct") && a + 1 < argc) { g_prof = true; g_pct = argv[++a]; }
        else if (!strcmp(argv[a], "--prof-frames") && a + 2 < argc) { g_prof = true; g_prof_from = atoi(argv[++a]); g_prof_to = atoi(argv[++a]); }
        else if (!strcmp(argv[a], "--fstat")) g_fstat = true;
        else if (!strcmp(argv[a], "--rfw") && a + 1 < argc) g_rfw = atoll(argv[++a]);
        else if (!strcmp(argv[a], "--trc") && a + 2 < argc) { g_tr_from = atoll(argv[++a]); g_tr_to = atoll(argv[++a]); }
        else if (!strcmp(argv[a], "--debug") && a + 1 < argc) g_debug = atoi(argv[++a]);
        else if (!strcmp(argv[a], "--lock")) g_lock = true;
        else if (!strcmp(argv[a], "--gap") && a + 1 < argc) g_gap = atoi(argv[++a]);
        else if (!strcmp(argv[a], "--gseed") && a + 1 < argc) g_gseed = atoi(argv[++a]);
        else if (!strcmp(argv[a], "--packed")) g_packed = true;
        else if (!strcmp(argv[a], "--rwlog") && a + 1 < argc) rwlog = argv[++a];
        else if (!strcmp(argv[a], "--rwall")) g_rwall = true;
        else if (!strcmp(argv[a], "--rwprobe") && a + 2 < argc) { g_rwp_from = atoll(argv[++a]); g_rwp_to = atoll(argv[++a]); }
        else if (!strcmp(argv[a], "--poready") && a + 1 < argc) g_pobusy = atoi(argv[++a]);
        else if (!strcmp(argv[a], "--mread") && a + 1 < argc) g_mread = atoi(argv[++a]);
        else if (!strcmp(argv[a], "--mpoll")) g_mpoll = true;
        else if (!strcmp(argv[a], "--lockframe") && a + 1 < argc) { g_lock = true; g_lockframe = atoi(argv[++a]); }
        else if (!strcmp(argv[a], "--synth") && a + 1 < argc) synth = atoi(argv[++a]);
        else if (!strcmp(argv[a], "--seed") && a + 1 < argc) seed = atoi(argv[++a]);
        else if (!strcmp(argv[a], "--timing") && a + 1 < argc) g_timing = atoi(argv[++a]);
        else if (!strcmp(argv[a], "--wild")) g_wild = true;
        else if (!strcmp(argv[a], "--edge")) g_edge = true;
        else if (!strcmp(argv[a], "--counts")) g_counts = true;
        else if (!strcmp(argv[a], "--polylog") && a + 2 < argc) { g_plog_from = strtoull(argv[++a], 0, 0); g_plog_to = strtoull(argv[++a], 0, 0); }
        else if (!strcmp(argv[a], "--pops") && a + 2 < argc) { g_from = atoll(argv[++a]); g_to = atoll(argv[++a]); }
    }
    if (rwlog) return run_rwlog(rwlog);
    if (trace) return run_trace(trace, frames, verbose);
    if (g_timing) return run_timing(g_timing, seed);
    if (synth) return run_synth(synth, seed, verbose);
    fprintf(stderr, "usage: tb_geom --trace gx.bin [--frames N] [-v]\n");
    return 1;
}
