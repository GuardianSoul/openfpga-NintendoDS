// nds_g3d_cache unit test (FAST, MIF2 by -G): random 16-bit reads with
// locality against a memory model, the block port with random ack delay and
// latency (up to two blocks outstanding, beats in order), random flushes that
// change the memory. Every answer must be the memory's halfword; an answer to
// a request made after a flush must show the memory after it.
#include "Vnds_g3d_cache.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <deque>
#include <random>
#include <vector>

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    const int AW = 19;
    std::vector<uint16_t> mem(1u << (AW - 1));
    std::mt19937 rng(argc > 1 ? atoi(argv[1]) : 1);
    for (auto& v : mem) v = rng();
    auto m = std::make_unique<Vnds_g3d_cache>();
    uint64_t cyc = 0;
    auto tick = [&]() { m->clk = 0; m->eval(); m->clk = 1; m->eval(); cyc++; };
    m->rst = 1; m->req = 0; m->flush = 0; m->b_ack = 0; m->b_rvalid = 0;
    for (int i = 0; i < 80; i++) tick();     // the free lists / tag init
    m->rst = 0;
    for (int i = 0; i < 300; i++) tick();
    struct Req { uint32_t a; uint64_t gen; };
    std::deque<Req> pend;                    // requests not yet answered, in order
    struct Blk { uint32_t blk; uint64_t at; int beat; uint16_t d[16]; };   // data as read at the acknowledge
    std::deque<Blk> fly;                     // blocks acknowledged, beats pending
    uint64_t gen = 0, bad = 0, answers = 0, misses = 0;
    int ack_wait = 0;
    uint32_t base = rng() & ((1u << AW) - 1);
    const int MAXF = 2;
    for (int step = 0; step < 400000; step++)
    {
        // inputs for this cycle
        m->req = 0; m->flush = 0; m->b_ack = 0; m->b_rvalid = 0;
        if (pend.size() < 14 && (rng() % 3) == 0) {
            if ((rng() % 64) == 0) base = rng() & ((1u << AW) - 1);
            uint32_t a = (base + (rng() % 512)) & ((1u << AW) - 2);
            m->req = 1; m->addr = a; pend.push_back({a, gen});
        }
        if ((rng() % 3000) == 0) {            // a remap: memory changes
            m->flush = 1; gen++;
            for (int i = 0; i < 4096; i++) mem[rng() % mem.size()] = rng();
        }
        // port: ack the request after a random wait, beats after a latency
        if (m->b_req && (int)fly.size() < MAXF) {
            if (ack_wait == 0) ack_wait = 1 + rng() % 6;
            if (--ack_wait == 0) {
                Blk b{(uint32_t)m->b_blk, cyc + 1 + rng() % 28, 0, {}};
                for (int k = 0; k < 16; k++) b.d[k] = mem[b.blk * 16 + k];
                m->b_ack = 1; fly.push_back(b); misses++;
            }
        }
        if (!fly.empty() && fly.front().at <= cyc && (rng() % 4) != 0) {
            Blk& b = fly.front();
            uint64_t w = 0;
            for (int k = 0; k < 4; k++) w |= (uint64_t)b.d[b.beat * 4 + k] << (16 * k);
            m->b_rvalid = 1; m->b_rdata = w;
            if (++b.beat == 4) fly.pop_front();
        }
        m->clk = 0; m->eval();
        bool v = m->valid; uint16_t d = m->data;
        m->clk = 1; m->eval(); cyc++;
        if (v) {
            if (pend.empty()) { printf("answer with no request\n"); return 1; }
            Req r = pend.front(); pend.pop_front(); answers++;
            uint16_t want = mem[r.a / 2];
            // a request made before the last remap may see either contents
            if (d != want && r.gen == gen) { if (bad < 10) printf("bad: addr %05x got %04x want %04x\n", r.a, d, want); bad++; }
        }
        if (m->b_rvalid && fly.size() > MAXF) { printf("port overrun\n"); return 1; }
    }
    printf("%llu answers, %llu blocks, %llu bad, %zu pending\n", (unsigned long long)answers,
           (unsigned long long)misses, (unsigned long long)bad, pend.size());
    return bad || answers < 1000;
}
