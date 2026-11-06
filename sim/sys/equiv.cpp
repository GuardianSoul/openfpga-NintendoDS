// Drives sys_equiv (equiv_top.sv) with random register traffic, events and
// memory acks, and reports every cycle where the two revisions differ.
//   [EQUIV_NO_DMA=1] Vsys_equiv [--cycles N] [--seed S]
#include "Vsys_equiv.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>

int main(int argc, char** argv) {
    long cycles = 2000000; unsigned long long seed = 1;
    for (int i = 1; i + 1 < argc; i++) {
        std::string a = argv[i];
        if (a == "--cycles") cycles = atol(argv[++i]);
        else if (a == "--seed") seed = strtoull(argv[++i], nullptr, 0);
    }
    std::mt19937_64 rng(seed);
    // EQUIV_NO_DMA=1: never enable a DMA, for changes that move DMA timing
    // but should leave everything else cycle-identical
    const bool no_dma = getenv("EQUIV_NO_DMA") != nullptr;
    auto r = [&](unsigned n) { return (unsigned)(rng() % n); };
    // the register map, as byte offsets; 0x100000 is IPCFIFORECV
    static const unsigned regs[] = {
        0xB0,0xB4,0xB8,0xBC,0xC0,0xC4,0xC8,0xCC,0xD0,0xD4,0xD8,0xDC,0xE0,0xE4,0xE8,0xEC,
        0x100,0x104,0x108,0x10C,0x180,0x184,0x188,0x100000,0x208,0x210,0x214,
        0x280,0x290,0x294,0x298,0x29C,0x2A0,0x2A4,0x2A8,0x2AC,0x2B0,0x2B4,0x2B8,0x2BC};
    static const unsigned bes[] = {0xF, 0xF, 0xF, 0x3, 0xC, 0x1, 0x2, 0x4, 0x8};
    Verilated::commandArgs(argc, argv);
    Vsys_equiv* t = new Vsys_equiv;
    long bad = 0;
    auto edge = [&](long c) {
        t->tick = c & 1;
        // clk2 = 2 x clk, phase 0: its middle edge after each clk edge (the new side's PUMP)
        t->clk = 0; t->clk2 = 0; t->eval(); t->clk = 1; t->clk2 = 1; t->eval();
        t->clk2 = 0; t->eval(); t->clk2 = 1; t->eval();
    };
    t->rst = 1; for (int i = 0; i < 4; i++) edge(i); t->rst = 0;
    for (long c = 0; c < cycles; c++) {
        t->io_req = r(3) == 0; t->io_cpu = r(2); t->io_we = r(2);
        unsigned a = r(16) ? regs[r(sizeof regs / sizeof *regs)] : (r(0x400) & ~3u);
        t->io_addr = a >> 2; t->io_be = bes[r(9)];
        unsigned w = (unsigned)rng();
        if (a >= 0xB0 && a < 0xE0 && (a - 0xB0) % 12 == 8) w = (w & 0xFFE00000u) | r(64);   // short DMAs
        if (a >= 0xB0 && a < 0xE0 && (a - 0xB0) % 12 < 8) w &= 0x0FFFFFFFu;                  // addresses are 28 bits (sys_dma)
        if (a >= 0xB0 && a < 0xE0 && (a - 0xB0) % 12 == 0 && r(2)) w = 0x02000000u | (w & 0x3FFFFCu);   // main RAM sources: FAST's units
        if (a >= 0xB0 && a < 0xE0 && (a - 0xB0) % 12 == 4 && r(2)) w = 0x06000000u | (w & 0x3FFFFCu);
        if (no_dma && a >= 0xB0 && a < 0xE0 && (a - 0xB0) % 12 == 8) w &= 0x7FFFFFFFu;      // never enabled
        if (a >= 0x100 && a < 0x110 && r(2)) w |= 0xFFC0;                                  // timers near overflow
        if (a >= 0x100 && a < 0x110) t->io_be = bes[r(5)];        // timers: the 16/32-bit writes melonDS takes
        if (a >= 0x290 && a < 0x2A0 && r(3) == 0) w = r(4) ? 0 : 0xFFFFFFFF;                // edge operands
        t->io_wdata = w;
        t->dma_trig9 = r(8) == 0 ? 1u << r(7) : 0; t->dma_stop9 = r(64) == 0 ? 1u << r(7) : 0;
        t->dma_trig7 = r(8) == 0 ? 1u << r(3) : 0;
        if (r(32) == 0) t->dma_gx_low = !t->dma_gx_low;
        t->m_ack = r(2); t->m_rdata = (unsigned)rng();
        t->irq_ext9 = r(16) == 0 ? 1u << r(32) : 0; t->irq_ext7 = r(16) == 0 ? 1u << r(32) : 0;
        unsigned q_req = t->io_req, q_we = t->io_we, q_cpu = t->io_cpu, q_be = t->io_be, q_a = a;
        edge(c);
        // read data counts only in the cycle after a read
        unsigned diff = t->diff & ((q_req && !q_we) ? 0x3FFu : 0x1FFu);
        if (diff && bad++ < 10)
            printf("cycle %ld: outputs differ (mask %03x, rdata new %08x old %08x; request %s ARM%d %07x be %x)\n",
                   c, diff, t->new_rdata, t->old_rdata, q_req ? (q_we ? "write" : "read") : "none",
                   q_cpu ? 7 : 9, q_a, q_be);
    }
    printf("%s: %ld cycles, %ld differing (seed %llu)\n", bad ? "DIFFER" : "EQUIVALENT", cycles, bad, seed);
    delete t;
    return bad ? 1 : 0;
}
