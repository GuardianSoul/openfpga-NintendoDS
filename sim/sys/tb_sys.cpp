// System blocks test bench (docs/system-blocks.md): nds_sys in Verilator
// against the melonDS-derived golden model (golden_sys.h).
//   Vnds_sys [--seed N] [--only div,sqrt,timers,ipc,irq,dma] [--scale K]
// Every register read is compared on the cycle it is made. Timer, IPC and
// IRQ runs also compare both IRQ lines every cycle. DMA runs compare the
// memory written (per address, in order), every channel's registers and IF.
#include "Vnds_sys.h"
#include "Vnds_sys___024root.h"
#include "verilated.h"
#include "golden_sys.h"
#include <cstdio>
#include <cstdlib>
#include <random>
#include <set>
#include <string>
#include <unordered_map>

using gold::u32; using gold::u64;

static Vnds_sys* top;
static gold::Sys G;
static u64 cyc = 0;
static std::mt19937_64 rng;
static long fails = 0, checks = 0;
static bool cmp_irq = false;
static bool tmr_lag = false;
static u64 tmr_n[8], tmr_cov[6];     // IRQs at F/1, F/64, F/256, F/1024, cascaded; with a write to the timer that clock
static u64 tmr_wcyc[8], tmr_w1 = 0;
static bool tmr_w1h[8];
static const char* phase = "";

static u32 rnd(u32 n) { return (u32)(rng() % n); }
static u64 r64() { return rng(); }

#define CHECK(c, ...) do { checks++; if (!(c)) { if (fails++ < 30) { printf("FAIL [%s] cyc %llu: ", phase, (unsigned long long)cyc); printf(__VA_ARGS__); printf("\n"); } } } while (0)

// ---- memory seen by the DMA (one map for RTL, one for the golden model)
struct Memory {
    std::unordered_map<u32, uint16_t> h;              // halfwords by address >> 1
    std::map<u32, std::vector<u32>> wlog;             // writes per aligned address
    u32 card = 0;                                     // 0x04100010 reads count up
    static uint16_t init(u32 a) { u32 x = a * 2654435761u; return (uint16_t)(x >> 13 ^ x); }
    uint16_t rh(u32 a) { auto it = h.find(a >> 1); return it == h.end() ? init(a & ~1u) : it->second; }
    u32 read(u32 a, bool w32) {
        if ((a & ~3u) == 0x04100010) { card++; return 0xCA000000u + card; }
        if (w32) { a &= ~3u; return rh(a) | (u32)rh(a + 2) << 16; }
        return rh(a & ~1u);
    }
    void write(u32 a, u32 v, bool w32) {
        if (w32) { a &= ~3u; h[a >> 1] = v; h[(a >> 1) + 1] = v >> 16; wlog[a].push_back(v); }
        else { a &= ~1u; h[a >> 1] = v; wlog[a].push_back(v & 0xFFFF); }
    }
};
static Memory rmem, gmem;

// ---- clocking. Cycle n: inputs set, then the edge that ends it. tick = n & 1.
static int mem_wait = -1;
static bool fill_pending = false;
static u32 fill_data = 0;
static int mem_lat_max = 2;
static u32 ext9 = 0, ext7 = 0;

static void eval_edge() {
    top->tick = cyc & 1;
    top->irq_ext9 = ext9; top->irq_ext7 = ext7;
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    cyc++;
    CHECK(!top->math_late, "divider/sqrt result missed its deadline");
    CHECK(!top->dma_lat_lost, "DMA enable-edge copy dropped");
    if (tmr_lag) {
        // every overflow's IRQ on the golden model's clock (docs/timer-exact-plan.md), none armed too late to fire on time
        G.at(cyc >> 1); G.RunTimers(0); G.RunTimers(1);
        for (int i = 0; i < 8; i++) {
            if (top->rootp->nds_sys__DOT__tirq >> i & 1) {
                tmr_n[i]++;
                tmr_cov[G.Timers[i].Cnt & 4 ? 4 : G.Timers[i].Cnt & 3]++;
                if (tmr_wcyc[i] + 1 == cyc) tmr_cov[5]++;
            }
            // (one exception: a write on the overflow's own tick edge, whose new state overflows there, fires a clock later)
            if (tmr_n[i] + 1 == G.IrqN[i] && tmr_wcyc[i] + 1 == cyc && !tmr_w1h[i]) { tmr_w1++; tmr_w1h[i] = true; continue; }
            tmr_w1h[i] = false;
            CHECK(tmr_n[i] == G.IrqN[i], "timer %d: IRQ %llu, the golden model's %llu", i,
                  (unsigned long long)tmr_n[i], (unsigned long long)G.IrqN[i]);
            if (tmr_n[i] != G.IrqN[i]) tmr_n[i] = G.IrqN[i];   // (one report per IRQ)
        }
        static int miss = 0;
        CHECK(top->rootp->nds_sys__DOT__u_tmr__DOT__miss == miss, "timer overflow came out at a visit, late");
        miss = top->rootp->nds_sys__DOT__u_tmr__DOT__miss;
    }
    if (cmp_irq) {
        G.at(cyc >> 1);
        CHECK(top->irq9 == G.IRQLine(0) && top->irq7 == G.IRQLine(1),
              "IRQ lines rtl %d/%d gold %d/%d (IF %08x/%08x)", top->irq9, top->irq7,
              G.IRQLine(0), G.IRQLine(1), G.IF[0], G.IF[1]);
    }
}

static bool io_by_dma = false;   // the DMA's fill read uses the register port this cycle
// One cycle: serve the memory port, optionally drive a CPU register access.
static void step(bool req = false, u32 cpu = 0, bool we = false, u32 be = 0, u32 addr = 0, u32 wd = 0) {
    top->m_ack = 0; top->m_rdata = 0;
    io_by_dma = false;
    if (top->m_req) {
        u32 a = top->m_addr;
        bool fill = !top->m_we && !top->m_cpu && a >= 0x040000E0 && a < 0x040000F0;
        if (fill) {
            if (fill_pending) {
                top->m_ack = 1;
                top->m_rdata = top->m_size32 ? fill_data : (fill_data >> ((a & 2) * 8)) & 0xFFFF;
                fill_pending = false;
            } else {
                io_by_dma = true;
                top->io_req = 1; top->io_pre = 1; top->tmr_oh = 0; top->io_cpu = 0; top->io_we = 0; top->io_be = 0xF;
                top->io_addr = (a & 0x1FFFFF) >> 2; top->io_wdata = 0;
            }
        } else {
            if (mem_wait < 0) mem_wait = rnd(mem_lat_max + 1);
            if (mem_wait == 0) {
                top->m_ack = 1;
                if (top->m_we) rmem.write(a, top->m_wdata, top->m_size32);
                else top->m_rdata = rmem.read(a, top->m_size32);
                mem_wait = -1;
            } else mem_wait--;
        }
    }
    if (ext9 | ext7) {
        G.at(cyc >> 1);
        for (int i = 0; i < 32; i++) { if (ext9 >> i & 1) G.SetIRQ(0, i); if (ext7 >> i & 1) G.SetIRQ(1, i); }
    }
    if (!io_by_dma) {
        top->io_req = req; top->io_pre = req; top->io_cpu = cpu; top->tmr_oh = (req && we && ((addr >> 12) & 0x1FF) == 0 && ((addr >> 4) & 0xFF) == 0x10) ? 1u << ((cpu << 2) | ((addr >> 2) & 3)) : 0; top->io_we = we; top->io_be = be;
        top->io_addr = addr >> 2; top->io_wdata = wd;
    }
    eval_edge();
    if (io_by_dma) { fill_pending = true; fill_data = top->io_rdata; }
    top->io_req = 0; top->io_pre = 0; top->tmr_oh = 0; ext9 = 0; ext7 = 0;
}

// A CPU register access at the current cycle, mirrored in the golden model.
static u32 io(u32 cpu, u32 addr, bool we, u32 be = 0xF, u32 wd = 0, bool check = true) {
    while (top->m_req && !top->m_we && !top->m_cpu && top->m_addr >= 0x040000E0 && top->m_addr < 0x040000F0)
        step();                                       // the DMA's fill read owns the port
    u64 n = cyc;
    G.at(n >> 1);
    u32 g = 0;
    if (we) G.write(cpu, addr, wd, be); else g = G.read(cpu, addr, be);
    if (we && addr >= 0x100 && addr < 0x110) tmr_wcyc[cpu * 4 + (addr - 0x100) / 4] = n;
    step(true, cpu, we, be, addr, wd);
    u32 r = top->io_rdata;
    if (!we && check) CHECK(r == g, "ARM%d read %07x: rtl %08x gold %08x", cpu ? 7 : 9, addr, r, g);
    return r;
}
static void idle(int n) { while (n-- > 0) step(); }
// An IRQ source pulse in the next cycle; in the golden model it lands after
// that cycle's register access (the RTL sets IF after a same-cycle clear).
static void ext_irq(u32 cpu, u32 bits) { (cpu ? ext7 : ext9) |= bits; }

// ================================================================ DIV / SQRT
static u32 pick32() {
    switch (rnd(8)) {
        case 0: return 0; case 1: return 0xFFFFFFFF; case 2: return 0x80000000; case 3: return 1;
        case 4: return rnd(256); case 5: return 0x7FFFFFFF; default: return (u32)r64();
    }
}
static void test_div(int n) {
    phase = "div";
    for (int i = 0; i < n; i++) {
        int k = rnd(6);
        if (k == 0) io(0, 0x280, true, rnd(4) ? 0xF : 0x3, rnd(4));
        else if (k == 5) io(0, 0x290 + 4 * rnd(4), true, 0x3, (u32)r64());      // ignored (16-bit)
        else io(0, 0x290 + 4 * rnd(4), true, 0xF, pick32());
        int polls = rnd(4) ? 75 : rnd(40);
        for (int p = 0; p < polls; p++) {
            if (rnd(3)) io(0, rnd(2) ? 0x280 : 0x2A0 + 4 * rnd(4), false);
            else step();
        }
    }
    // every mode against every edge operand, read back when done
    const u32 e[] = {0, 1, 2, 3, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFF, 0xFFFFFFFE, 12345678};
    for (u32 mode = 0; mode < 4; mode++)
        for (u32 a : e) for (u32 b : e) for (u32 hi = 0; hi < 3; hi++) {
            io(0, 0x280, true, 0x3, mode);
            u32 nh = hi == 0 ? 0 : hi == 1 ? 0xFFFFFFFF : 0x80000000;
            io(0, 0x290, true, 0xF, a); io(0, 0x294, true, 0xF, nh);
            io(0, 0x298, true, 0xF, b); io(0, 0x29C, true, 0xF, hi == 2 ? 0 : (b >> 31 ? 0xFFFFFFFF : 0));
            idle(68);
            for (u32 r = 0x280; r <= 0x2AC; r += 4) io(0, r, false);
        }
}
static void test_sqrt(int n) {
    phase = "sqrt";
    // Independent constant: the old RTL and reference both wrapped their
    // trial term here and incorrectly returned 0x80000001.
    io(0, 0x2B0, true, 0x3, 1);
    io(0, 0x2B8, true, 0xF, 1);
    io(0, 0x2BC, true, 0xF, 0x40000000);
    idle(28);
    u32 boundary_root = io(0, 0x2B4, false);
    CHECK(boundary_root == 0x80000000u, "64-bit sqrt trial overflow: %08x", boundary_root);
    for (int i = 0; i < n; i++) {
        int k = rnd(4);
        if (k == 0) io(0, 0x2B0, true, 0x3, rnd(2));
        else {
            u32 v;
            switch (rnd(6)) {
                case 0: v = 0xFFFFFFFF; break; case 1: v = 0; break; case 2: v = rnd(16); break;
                default: v = (u32)r64();
            }
            io(0, 0x2B8 + 4 * rnd(2), true, 0xF, v);
        }
        int polls = rnd(4) ? 30 : rnd(20);
        for (int p = 0; p < polls; p++) {
            if (rnd(3)) io(0, rnd(2) ? 0x2B0 : 0x2B4, false); else step();
        }
    }
    // squares, their neighbours, and the top of the range in both modes
    for (u32 mode = 0; mode < 2; mode++) {
        io(0, 0x2B0, true, 0x3, mode);
        for (int i = 0; i < 400; i++) {
            u64 v;
            if (i < 64) v = ~0ull - (u64)i * 0x123456789ull;
            else if (i < 128) { u64 s = (u64)(0xFFFFFFFFu - (i - 64)); v = s * s + (i & 1 ? 1 : -1); }
            else { u64 s = r64() >> rnd(33); v = s * s + rnd(3) - 1; }
            if (!mode) v &= 0xFFFFFFFF;
            // In 32-bit mode, the high parameter word must be ignored.
            io(0, 0x2B8, true, 0xF, (u32)v);
            io(0, 0x2BC, true, 0xF, mode ? (u32)(v >> 32) : 0xA5A5A5A5u);
            idle(26);
            u32 root = io(0, 0x2B4, false);
            // Independent of the RTL and golden recurrence: the root must
            // bracket v between consecutive squares. The next square is
            // beyond u64 only for the largest possible u32 root.
            u64 square = u64(root) * root, next = u64(root) + 1;
            CHECK(square <= v && (root == 0xFFFFFFFFu || v < next * next),
                  "sqrt floor bound: n=%016llx root=%08x", (unsigned long long)v, root);
            io(0, 0x2B0, false);
        }
    }
}

// ================================================================ timers
static void test_timers(int n) {
    phase = "timers"; tmr_lag = true;
    for (int i = 0; i < n; i++) {
        u32 cpu = rnd(2), t = rnd(4), a = 0x100 + 4 * t;
        switch (rnd(10)) {
            case 0: case 1: {                          // reload + control, word write
                u32 rl = rnd(3) ? 0x10000 - 1 - rnd(rnd(2) ? 64 : 3000) : (u32)r64() & 0xFFFF;
                if (rl > 0xFFEF) rl = 0xFFEF;           // (an overflow every few ticks is a known difference, docs/ds-rules.md)
                u32 c = rnd(4) | (rnd(3) == 0 ? 4 : 0) | (rnd(2) ? 0x40 : 0) | (rnd(4) ? 0x80 : 0);
                io(cpu, a, true, 0xF, rl | c << 16);
                break;
            }
            case 2: io(cpu, a, true, 0x3, 0x10000 - 16 - rnd(500)); break;    // reload only
            case 3: {                                  // control only (prescaler change, stop, cascade)
                u32 c = rnd(4) | (rnd(4) == 0 ? 4 : 0) | (rnd(2) ? 0x40 : 0) | (rnd(5) ? 0x80 : 0);
                io(cpu, a, true, 0xC, c << 16);
                break;
            }
            case 5: {                                  // TMCNT_H with its unused bits, or one of its bytes
                u32 c = (u32)r64() & 0xFF3B | rnd(4) | (rnd(4) == 0 ? 4 : 0) | (rnd(2) ? 0x40 : 0) | (rnd(4) ? 0x80 : 0);
                io(cpu, a, true, rnd(3) == 0 ? 0xC : rnd(2) ? 0x4 : 0x8, c << 16);
                break;
            }
            case 4: {                                  // a control write timed onto an F/1 overflow, a few clocks either way
                G.at(cyc >> 1); G.RunTimers(cpu);
                const gold::Timer& T = G.Timers[cpu * 4 + t];
                u32 left = 0x10000 - (T.Counter >> 10);
                if ((T.Cnt & 0x87) != 0x80 || left > 60) { io(cpu, a, false); break; }
                int w = 2 * (int)left - 4 + (int)rnd(7);
                idle(w > 0 ? w : 0);
                u32 c = rnd(4) | (rnd(4) == 0 ? 4 : 0) | (rnd(2) ? 0x40 : 0) | (rnd(5) ? 0x80 : 0);
                io(cpu, a, true, rnd(2) ? 0xC : 0xF, (u32)(0x10000 - 20 - rnd(400)) | c << 16);
                break;
            }
            default: io(cpu, a, false);
        }
        idle(rnd(4) == 0 ? rnd(300) : rnd(6));
    }
    for (u32 c = 0; c < 2; c++) for (u32 t = 0; t < 4; t++) io(c, 0x100 + 4 * t, true, 0xC, 0);
    idle(64);
    // directed, checked on every clock as above: each prescale from 0xFFFF and nearby reloads (the divider's phase
    // runs free, so every start lands somewhere new); a four-timer cascade chain overflowing together; a write swept
    // over every clock of the countdown window (stop, prescale change, IRQ enable off and on, restart)
    for (u32 c = 0; c < 2; c++) {
        u32 a = 0x100 + 4 * rnd(4);
        for (u32 p = 0; p < 4; p++) for (int k = 0; k < 12; k++) {
            io(c, a, true, 0xF, ((p ? 0xFFFFu : 0xFFEFu) - rnd(3)) | (0xC0 | p) << 16);   // (F/1 above 0xFFEF: see above)
            idle((2 << (p ? 2 * p + 4 : 0)) * (2 + rnd(3)) + rnd(9));
            io(c, a, true, 0xC, 0);
        }
        io(c, 0x100, true, 0xF, 0xFFF0 | 0xC0u << 16);
        io(c, 0x104, true, 0xF, 0xFFFE | 0xC4u << 16);
        io(c, 0x108, true, 0xF, 0xFFFF | 0xC4u << 16);
        io(c, 0x10C, true, 0xF, 0xFFFF | 0xC4u << 16);
        idle(2000);
        for (u32 t = 0; t < 4; t++) io(c, 0x100 + 4 * t, true, 0xC, 0);
        static const u32 to[6] = {0x00, 0xC1, 0x80, 0xC0, 0xC2, 0xC3};   // stop, F/64, IRQ off, as is, F/256, F/1024
        for (int off = 0; off < 72; off++) for (u32 m = 0; m < 6; m++) {
            io(c, 0x100, true, 0xF, 0xFFE0 | 0xC0u << 16);
            idle(off);
            io(c, 0x100, true, 0xC, to[m] << 16);
            idle(90);
            io(c, 0x100, true, 0xC, 0);
        }
    }
    idle(64);
    tmr_lag = false;
    for (u32 c = 0; c < 2; c++) io(c, 0x214, true, 0xF, 0xFFFFFFFF);
    printf("timers: %llu IRQs a clock late after a write on the overflow's tick edge (sys_timers wlate %d)\n",
           (unsigned long long)tmr_w1, (int)top->rootp->nds_sys__DOT__u_tmr__DOT__wlate);
    printf("timers: exact IRQs F/1 %llu, F/64 %llu, F/256 %llu, F/1024 %llu, cascaded %llu; on a write's clock %llu\n",
           (unsigned long long)tmr_cov[0], (unsigned long long)tmr_cov[1], (unsigned long long)tmr_cov[2],
           (unsigned long long)tmr_cov[3], (unsigned long long)tmr_cov[4], (unsigned long long)tmr_cov[5]);
    for (int k = 0; k < 6; k++) CHECK(tmr_cov[k] + (k == 5 ? tmr_w1 : 0) > 0, "timer IRQ case %d never hit", k);
}

// ================================================================ IPC
static void test_ipc(int n) {
    phase = "ipc"; cmp_irq = true;
    for (u32 c = 0; c < 2; c++) { io(c, 0x208, true, 0xF, 1); io(c, 0x210, true, 0xF, 0x70000); }
    for (int i = 0; i < n; i++) {
        u32 cpu = rnd(2);
        switch (rnd(12)) {
            case 0: io(cpu, 0x180, true, rnd(2) ? 0x3 : 0xF, (u32)r64() & 0x6F0F); break;
            case 1: io(cpu, 0x184, true, rnd(2) ? 0x3 : 0xF,
                       (rnd(5) ? 0x8000 : 0) | (rnd(2) ? 0x400 : 0) | (rnd(2) ? 4 : 0) |
                       (rnd(6) == 0 ? 8 : 0) | (rnd(3) == 0 ? 0x4000 : 0)); break;
            case 2: case 3: case 4: io(cpu, 0x188, true, rnd(6) ? 0xF : 0x3, (u32)r64()); break;
            case 5: case 6: case 7: io(cpu, 0x100000, false); break;
            case 8: io(cpu, 0x214, true, 0xF, (u32)r64()); break;
            case 9: io(cpu, 0x180, false); break;
            case 10: io(cpu, 0x184, false); break;
            default: io(cpu, 0x214, false);
        }
        idle(rnd(3));
    }
    cmp_irq = false;
}

// ================================================================ IRQ controller
static void test_irq(int n) {
    phase = "irq"; cmp_irq = true;
    for (int i = 0; i < n; i++) {
        u32 cpu = rnd(2);
        switch (rnd(8)) {
            case 0: io(cpu, 0x208, true, rnd(2) ? 0xF : 0x1, rnd(2)); break;
            case 1: io(cpu, 0x210, true, rnd(2) ? 0xF : rnd(2) ? 0x3 : 0xC, (u32)r64()); break;
            case 2: io(cpu, 0x214, true, rnd(2) ? 0xF : 0x3, (u32)r64() & (u32)r64()); break;
            case 3: io(cpu, 0x208 + 8 * rnd(2) + 4 * rnd(2), false); break;
            default: ext_irq(cpu, 1u << rnd(32)); step();
        }
        if (rnd(4) == 0) { ext_irq(cpu, 1u << rnd(32)); io(cpu, 0x214, true, 0xF, (u32)r64()); }
    }
    cmp_irq = false;
}

// ================================================================ DMA
static u32 dma_reg(u32 ch, u32 r) { return 0xB0 + 12 * ch + 4 * r; }
static void wait_dma_idle() {
    // idle for 8 cycles in a row (a GX FIFO DMA restarts after each chunk)
    for (int i = 0, quiet = 0; quiet < 8; i++) {
        quiet = (top->dma_busy || top->m_req) ? 0 : quiet + 1;
        step();
        if (i > 3000000) { CHECK(false, "DMA never finished"); return; }
    }
}
static void dma_compare(const char* what) {
    // per-address write sequences, and the registers and IF of both CPUs
    std::set<u32> addrs;
    for (auto& [a, v] : rmem.wlog) addrs.insert(a);
    for (auto& [a, v] : gmem.wlog) addrs.insert(a);
    int bad = 0;
    if (getenv("DBG")) for (u32 a : addrs) printf("  %08x rtl %zu gold %zu\n", a, rmem.wlog[a].size(), gmem.wlog[a].size());
    for (u32 a : addrs) {
        auto& r = rmem.wlog[a]; auto& g = gmem.wlog[a];
        if (r != g && bad++ < 5)
            CHECK(false, "%s: writes to %08x differ: rtl %zu (last %08x) gold %zu (last %08x)", what, a,
                  r.size(), r.empty() ? 0 : r.back(), g.size(), g.empty() ? 0 : g.back());
    }
    checks++;
    for (u32 cpu = 0; cpu < 2; cpu++) {
        for (u32 ch = 0; ch < 4; ch++) for (u32 r = 0; r < 3; r++) io(cpu, dma_reg(ch, r), false);
        io(cpu, 0x214, false);
        io(cpu, 0x214, true, 0xF, 0xF00);
    }
    rmem.wlog.clear(); gmem.wlog.clear();
}
static void trig(u32 cpu, u32 mode) {               // a start event, both models
    G.at(cyc >> 1);
    if (cpu == 0 && mode == 7) {                     // the FIFO is low for this one cycle only:
        G.gx_low = false;                             // low again when a chunk ends
        for (u32 i = 0; i < 4; i++) G.DMAs[i].StartIfNeeded(7);
        G.RunDMAs(0); top->dma_gx_low = 1;
    }
    else if (cpu == 0) { G.CheckDMAs(0, mode); top->dma_trig9 = 1 << (mode - 1); }
    else { G.CheckDMAs(1, 0x10 | mode); top->dma_trig7 = 1 << (mode - 1); }
    step();
    top->dma_trig9 = 0; top->dma_trig7 = 0; top->dma_gx_low = 0;
}
static void stop(u32 mode) {
    G.at(cyc >> 1); G.StopDMAs(0, mode);
    top->dma_stop9 = 1 << (mode - 1); step(); top->dma_stop9 = 0;
}
struct ChCfg { u32 cpu, ch, sad, dad, cnt; };
static void dma_setup(const ChCfg& c) {
    io(c.cpu, dma_reg(c.ch, 0), true, 0xF, c.sad);
    io(c.cpu, dma_reg(c.ch, 1), true, 0xF, c.dad);
    io(c.cpu, dma_reg(c.ch, 2), true, 0xF, c.cnt);
}
static u32 cnt_word(u32 count, u32 dctl, u32 sctl, bool rep, bool w32, u32 mode, bool irq, u32 cpu) {
    u32 m = cpu ? (mode & 3) << 28 : (mode & 7) << 27;
    return count | dctl << 21 | sctl << 23 | (rep ? 1u << 25 : 0) | (w32 ? 1u << 26 : 0) | m |
           (irq ? 1u << 30 : 0) | 1u << 31;
}
static bool running_mode(u32 cpu, u32 mode) {        // an RTL channel in this mode is still running
    for (u32 ch = 0; ch < 4; ch++) {
        u32 i = cpu * 4 + ch;
        const gold::DMA& d = G.DMAs[i];
        u32 m = cpu ? d.StartMode & 3 : d.StartMode;
        if ((top->dbg_dma_run >> i & 1) && m == mode) return true;
    }
    return false;
}

static u64 unit_cycles = 0, unit_count = 0;
static void test_dma_directed() {
    phase = "dma-directed";
    G.mem.read = [](u32, u32 a, bool w) -> u32 {
        if (a >= 0x040000E0 && a < 0x040000F0) {
            u32 f = G.DMA9Fill[(a - 0x040000E0) / 4];
            return w ? f : (f >> ((a & 2) * 8)) & 0xFFFF;
        }
        return gmem.read(a, w);
    };
    G.mem.write = [](u32, u32 a, u32 v, bool w) { gmem.write(a, v, w); };

    // 1. immediate word copy, both directions incrementing; cycles per unit at 1-cycle memory
    int lat = mem_lat_max; mem_lat_max = 0;
    dma_setup({0, 3, 0x02100000, 0x02200000, cnt_word(256, 0, 0, false, true, 0, true, 0)});
    u64 c0 = cyc; wait_dma_idle(); unit_cycles += cyc - c0 - 4; unit_count += 256;
    dma_compare("imm32");
    mem_lat_max = lat;
    // 2. halfwords: decrementing source, fixed destination
    dma_setup({0, 1, 0x02101000, 0x02201000, cnt_word(77, 2, 1, false, false, 0, false, 0)});
    wait_dma_idle(); dma_compare("imm16 dec/fixed");
    // 3. fill (source = DMA9FILL), 16- and 32-bit
    io(0, 0xE8, true, 0xF, 0xDEADBEEF);
    dma_setup({0, 2, 0x040000E8, 0x02202000, cnt_word(40, 0, 2, false, true, 0, false, 0)});
    wait_dma_idle();
    dma_setup({0, 2, 0x040000EA, 0x02203000, cnt_word(9, 0, 2, false, false, 0, false, 0)});
    wait_dma_idle(); dma_compare("fill");
    // 4. HBlank, repeat, destination reload, 8 lines
    dma_setup({0, 0, 0x02104000, 0x04000010, cnt_word(4, 3, 0, true, true, 2, false, 0)});
    for (int l = 0; l < 8; l++) { trig(0, 2); wait_dma_idle(); }
    io(0, dma_reg(0, 2), true, 0xC, 0); dma_compare("hblank repeat reload");
    // 5. VBlank with IRQ, no repeat: the second VBlank does nothing
    dma_setup({0, 1, 0x02105000, 0x02205000, cnt_word(16, 0, 0, false, true, 1, true, 0)});
    trig(0, 1); wait_dma_idle(); trig(0, 1); wait_dma_idle(); dma_compare("vblank irq");
    // 6. GX FIFO DMA, 300 words: three pulses of the FIFO-low level, 112 + 112 + 76
    dma_setup({0, 0, 0x02106000, 0x04000400, cnt_word(300, 2, 0, false, true, 7, true, 0)});
    for (int k = 0; k < 3; k++) { trig(0, 7); wait_dma_idle(); }
    dma_compare("gx fifo chunks");
    // 7. GX FIFO level held: all chunks back to back
    dma_setup({0, 1, 0x02107000, 0x04000400, cnt_word(250, 2, 0, false, true, 7, false, 0)});
    G.at(cyc >> 1); G.gx_low = true; G.CheckFIFODMA(); top->dma_gx_low = 1;
    wait_dma_idle(); G.gx_low = false; top->dma_gx_low = 0;
    dma_compare("gx fifo level");
    // 8. card: repeat, one word per pulse from 0x04100010
    dma_setup({0, 2, 0x04100010, 0x02208000, cnt_word(1, 0, 2, true, true, 5, false, 0)});
    for (int k = 0; k < 20; k++) { trig(0, 5); idle(rnd(30)); wait_dma_idle(); }
    io(0, dma_reg(2, 2), true, 0xC, 0); dma_compare("card");
    // 9. start-of-display stopped by its stop event; main-memory display
    dma_setup({0, 3, 0x02109000, 0x02209000, cnt_word(8, 0, 0, true, true, 3, false, 0)});
    trig(0, 3); wait_dma_idle(); trig(0, 3); wait_dma_idle(); stop(3); trig(0, 3); wait_dma_idle();
    dma_setup({0, 3, 0x0210A000, 0x0220A000, cnt_word(8, 0, 0, true, true, 4, false, 0)});
    trig(0, 4); wait_dma_idle(); stop(4); trig(0, 4); wait_dma_idle();
    dma_compare("display modes");
    // 10. preemption: a long ARM9 ch3 copy; HBlank ch0 and VBlank ch1 fire during it
    dma_setup({0, 0, 0x0210B000, 0x0220B000, cnt_word(6, 0, 0, true, true, 2, false, 0)});
    dma_setup({0, 1, 0x0210C000, 0x0220C000, cnt_word(5, 0, 0, true, false, 1, true, 0)});
    dma_setup({0, 3, 0x0210D000, 0x0220D000, cnt_word(600, 0, 0, false, true, 0, true, 0)});
    for (int k = 0; k < 6; k++) {
        idle(50 + rnd(100));
        if (!running_mode(0, 2)) {
            // ch0 must preempt ch3 at the next unit boundary: its first write
            // lands within a unit, a save and a load (about 20 clks here)
            size_t before = 0;
            for (auto& [a, v] : rmem.wlog) if (a >= 0x0220B000 && a < 0x0220C000) before += v.size();
            trig(0, 2);
            int waited = 0;
            for (;; waited++) {
                size_t now = 0;
                for (auto& [a, v] : rmem.wlog) if (a >= 0x0220B000 && a < 0x0220C000) now += v.size();
                if (now > before || waited > 40) break;
                step();
            }
            CHECK(waited <= 24, "HBlank DMA took %d clks to preempt the copy", waited);
        }
        if (!running_mode(0, 1)) trig(0, 1);
    }
    wait_dma_idle();
    io(0, dma_reg(0, 2), true, 0xC, 0); io(0, dma_reg(1, 2), true, 0xC, 0);
    dma_compare("preemption");
    // 11. ARM7: count 0 is 0x4000 on ch0-2 and 0x10000 on ch3; VBlank and card modes
    dma_setup({1, 0, 0x02110000, 0x02210000, cnt_word(0, 0, 0, false, false, 0, true, 1)});
    wait_dma_idle();
    dma_setup({1, 3, 0x02120000, 0x02280000, cnt_word(0, 0, 0, false, true, 0, true, 1)});
    wait_dma_idle(); dma_compare("arm7 count 0");
    dma_setup({1, 1, 0x02130000, 0x02230000, cnt_word(12, 0, 0, true, true, 1, true, 1)});
    dma_setup({1, 2, 0x04100010, 0x02231000, cnt_word(1, 0, 2, true, true, 2, false, 1)});
    for (int k = 0; k < 4; k++) { trig(1, 1); wait_dma_idle(); trig(1, 2); wait_dma_idle(); }
    io(1, dma_reg(1, 2), true, 0xC, 0); io(1, dma_reg(2, 2), true, 0xC, 0);
    dma_compare("arm7 vblank/card");
    // 12. ARM9 and ARM7 at once (one engine: ARM9 first)
    dma_setup({1, 3, 0x02140000, 0x02240000, cnt_word(40, 0, 0, true, true, 1, true, 1)});
    dma_setup({0, 2, 0x02141000, 0x02241000, cnt_word(40, 0, 0, true, true, 1, true, 0)});
    trig(0, 1); trig(1, 1); wait_dma_idle();
    io(1, dma_reg(3, 2), true, 0xC, 0); io(0, dma_reg(2, 2), true, 0xC, 0);
    dma_compare("both cpus");
    // 13. a GX chunk interrupted by disable/enable: the edge relatches SAD/DAD, the count carries on
    dma_setup({0, 1, 0x02150000, 0x04000400, cnt_word(200, 2, 0, false, true, 7, true, 0)});
    trig(0, 7); wait_dma_idle();
    io(0, dma_reg(1, 0), true, 0xF, 0x02158000);
    io(0, dma_reg(1, 2), true, 0xC, 0);
    io(0, dma_reg(1, 2), true, 0xC, cnt_word(200, 2, 0, false, true, 7, true, 0));
    trig(0, 7); wait_dma_idle();
    dma_compare("gx relatch");
    // 14. CNT written as halves; an immediate copy started by the upper half
    io(0, dma_reg(2, 0), true, 0xF, 0x02160000); io(0, dma_reg(2, 1), true, 0xF, 0x02260000);
    io(0, dma_reg(2, 2), true, 0x3, 33);
    io(0, dma_reg(2, 2) + 0, true, 0xC, cnt_word(0, 0, 0, false, true, 0, false, 0));
    wait_dma_idle(); dma_compare("cnt halves");
}

// 16. GX FIFO DMA with count 0 (0x200000 words): one FIFO-low pulse moves one
// 112-word chunk, then the channel is disabled between chunks. It stays in
// progress, so this runs after every other DMA test.
static void test_dma_gx_count0() {
    phase = "dma-gx0";
    dma_setup({0, 3, 0x02170000, 0x04000400, cnt_word(0, 2, 0, false, true, 7, false, 0)});
    trig(0, 7); wait_dma_idle();
    io(0, dma_reg(3, 2), true, 0xC, 0);
    dma_compare("gx count 0");
}

static void test_dma_random(int n) {
    phase = "dma-random";
    for (int s = 0; s < n; s++) {
        int nch = 1 + rnd(4);
        std::vector<u32> used;
        bool card_used[2] = {false, false};
        std::vector<std::pair<u32, u32>> armed;       // (cpu, mode) with triggers
        for (int c = 0; c < nch; c++) {
            u32 cpu = rnd(3) ? 0 : 1, ch = rnd(4), idx = cpu * 4 + ch;
            if (std::find(used.begin(), used.end(), idx) != used.end()) continue;
            used.push_back(idx);
            u32 mode = cpu ? rnd(4) : (u32[]){0, 1, 2, 3, 4, 5, 7, 0, 2}[rnd(9)];
            bool w32 = rnd(2), rep = mode != 0 && rnd(2), irq = rnd(2);
            u32 sctl = rnd(3), dctl = rnd(4);
            if (sctl == 2 && rep && rnd(2)) sctl = 3;
            u32 count = 1 + rnd(rnd(4) ? 40 : 300);
            u32 dst = 0x02400000 + idx * 0x10000 + 0x8000;
            u32 src = 0x02000000 + rnd(0x80000) * 2;
            if (mode == 7) { dst = 0x04000400; dctl = 2; }
            bool card = (cpu ? mode == 2 : mode == 5);
            // one card reader per run: both CPUs' reads share the card counter
            if (card) { if (card_used[0]) continue; card_used[0] = true; src = 0x04100010; sctl = 2; count = 1 + rnd(3); }
            else if (!cpu && rnd(6) == 0) { src = 0x040000E0 + 4 * rnd(4) + (w32 ? 0 : 2 * rnd(2)); sctl = 2; }
            dma_setup({cpu, ch, src, dst, cnt_word(count, dctl, sctl, rep, w32, mode, irq, cpu)});
            if (mode != 0) armed.push_back({cpu, mode});
            if (rnd(2)) idle(rnd(40));
        }
        // fire events while transfers run; a trigger that would meet its own
        // still-running channel is held back (melonDS would drop it, and the
        // golden model has no time to know)
        int ev = armed.empty() ? 0 : rnd(12);
        for (int e = 0; e < ev; e++) {
            auto [cpu, mode] = armed[rnd(armed.size())];
            if (!running_mode(cpu, mode)) trig(cpu, mode);
            idle(rnd(4) == 0 ? rnd(400) : rnd(20));
        }
        wait_dma_idle();
        for (u32 idx : used) io(idx >> 2, dma_reg(idx & 3, 2), true, 0xC, 0);   // disable
        // a GX channel left between chunks stays in progress in both models
        dma_compare("random");
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    u64 seed = 1; std::string only; int scale = 1;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--seed" && i + 1 < argc) seed = strtoull(argv[++i], nullptr, 0);
        else if (a == "--only" && i + 1 < argc) only = argv[++i];
        else if (a == "--scale" && i + 1 < argc) scale = atoi(argv[++i]);
    }
    rng.seed(seed);
    top = new Vnds_sys;
    top->rst = 1; idle(16); top->rst = 0; idle(2);
    auto want = [&](const char* t) { return only.empty() || only.find(t) != std::string::npos; };
    if (want("div"))    test_div(3000 * scale);
    if (want("sqrt"))   test_sqrt(3000 * scale);
    if (want("timers")) test_timers(20000 * scale);
    if (want("ipc"))    test_ipc(20000 * scale);
    if (want("irq"))    test_irq(20000 * scale);
    if (want("dma"))    { test_dma_directed(); test_dma_random(300 * scale); test_dma_gx_count0(); }
    if (unit_count) printf("DMA: %.2f clks per 32-bit unit with single-cycle memory (incl. load/save)\n",
                           (double)unit_cycles / unit_count);
    printf("%s: %ld checks, %ld failures (seed %llu, %llu cycles)\n", fails ? "FAIL" : "PASS",
           checks, fails, (unsigned long long)seed, (unsigned long long)cyc);
    delete top;
    return fails ? 1 : 0;
}
