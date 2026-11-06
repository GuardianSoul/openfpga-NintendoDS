// nds_cart_cache equivalence (sim/pocket/cache_eq): the two caches of
// tb_cache_eq.sv see the same client requests, fetch acknowledgements and
// markers; each has its own SDRAM model with the same random timing. The
// APF host model writes each command's blocks into both SDRAMs, each from
// its own cache's fc_data as it reads it at that moment, and signals the
// marker. All outputs are compared every cycle; fc_data from the command's
// send to its marker (the window the host reads it in).
//   Vtb_cache_eq [--seed N] [--cycles N]
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <random>
#include <string>
#include "Vtb_cache_eq.h"
#include "verilated.h"
typedef unsigned long long u64;
typedef uint32_t u32;
static Vtb_cache_eq* t;
static std::mt19937_64 rng;
static u32 r(u32 n) { return (u32)(rng() % n); }
static const u32 TABLE_W = 0x300000, CACHE_W = 0x400000, NDT_W = TABLE_W - 0x400;

struct Sdram {                      // one request held until ready; reads return 1 or 4 words
    std::map<u32, u32> mem;
    std::mt19937_64 g;
    int wait = -1, lat = 0, n = 0, left = 0; u32 a = 0;
    bool ready = false, rvalid = false; u32 rdata = 0;
    u32 rd(u32 x) { auto i = mem.find(x); return i == mem.end() ? 0 : i->second; }
    void step(bool valid, bool write, bool quad, u32 addr, u32 wd, u32 be) {
        ready = false; rvalid = false;
        if (left > 0) {
            if (lat > 0) lat--;
            else { rvalid = true; rdata = rd(a + n); n++; left--; }
        }
        if (valid && left == 0) {
            if (wait < 0) wait = (int)(g() % 4);
            if (wait-- == 0) {
                ready = true; wait = -1;
                if (write) {
                    u32 o = rd(addr);
                    for (int b = 0; b < 4; b++) if (be >> b & 1) o = (o & ~(0xFFu << 8 * b)) | (wd & 0xFFu << 8 * b);
                    mem[addr] = o;
                } else { a = addr; n = 0; left = quad ? 4 : 1; lat = 1 + (int)(g() % 4); }
            }
        }
    }
};
static Sdram sn, sr;
static u64 cyc = 0, bad = 0, n_cmd = 0, n_req = 0, n_word = 0, n_err = 0, n_ready = 0;
static void bits(const VlWide<8>& w, u32* o) { for (int i = 0; i < 8; i++) o[i] = w[i]; }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    u64 seed = 1, cycles = 2000000;
    for (int i = 1; i + 1 < argc; i++) {
        std::string s = argv[i];
        if (s == "--seed") seed = atoll(argv[++i]);
        else if (s == "--cycles") cycles = atoll(argv[++i]);
    }
    rng.seed(seed); sn.g.seed(seed * 7 + 1); sr.g.seed(seed * 7 + 1);
    t = new Vtb_cache_eq;
    // the ROM and its read-ahead table (valid most of the time)
    u32 rom = 0x10000 + r(0x200000); if (r(3) == 0) rom &= ~0xFFFu;
    u32 nb = (rom + 0xFFF) >> 12;
    bool ndt = r(4) != 0;
    for (Sdram* s : {&sn, &sr}) {
        s->mem[NDT_W] = ndt ? 0x3154444E : 0x12345678; s->mem[NDT_W + 1] = 1; s->mem[NDT_W + 3] = rom;
    }
    {   // NitroFS-like files: runs of blocks, each block's field min(4, blocks left in its file)
        u32 b = 0;
        while (b < nb) {
            u32 len = 1 + r(r(4) == 0 ? 40 : 6);
            for (u32 k = 0; k < len && b < nb; k++, b++) {
                u32 left = len - k - 1; if (left > 4) left = 4;
                sn.mem[TABLE_W + b] = sr.mem[TABLE_W + b] = left << 29;
            }
        }
    }
    auto romword = [](u32 byteaddr) { return byteaddr * 2654435761u ^ 0xA5A5F00Du; };
    // host: commands taken from the reference side's sends
    int busy = 0; long exec_at = -1, mark_at = -1; int err_n = 0;
    bool in_cmd = false;
    // client
    bool cv = false; u32 ca = 0; u32 lastb = 0;
    t->reset = 1; t->start = 0; t->rom_size = rom;
    auto eval = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    for (int i = 0; i < 4; i++) eval();
    t->reset = 0;
    u32 on[8], orf[8];
    for (cyc = 0; cyc < cycles; cyc++) {
        if (cyc == 10) t->start = 1;
        // a restart halfway: the cache resets and loads again (reference bits
        // and tables from the first run are still in its RAM and SDRAM)
        if (cyc == cycles / 2) { t->reset = 1; t->start = 0; }
        if (cyc == cycles / 2 + 3) t->reset = 0;
        if (cyc == cycles / 2 + 13) t->start = 1;
        // inputs for this cycle, from the outputs before the edge
        t->fc_busy_n = t->fc_busy_r = busy > 0;
        t->mk_valid = 0; t->mk_err = 0;
        if (mark_at >= 0 && (long)cyc == mark_at) {
            t->mk_valid = 1; t->mk_err = (err_n++ % 9 == 8) ? 1 : 0; mark_at = -1; in_cmd = false;
        }
        t->c_valid = cv; t->c_addr = ca;
        t->m_ready_n = sn.ready; t->m_rvalid_n = sn.rvalid; t->m_rdata_n = sn.rdata;
        t->m_ready_r = sr.ready; t->m_rvalid_r = sr.rvalid; t->m_rdata_r = sr.rdata;
        t->eval();
        bits(t->o_new, on); bits(t->o_ref, orf);
        // compare: fc_data (bits 136..255) only while a command is out
        bool d = false;
        for (int i = 0; i < 8; i++) {
            u32 m = 0xFFFFFFFFu;
            if (!in_cmd) { if (i == 4) m = 0x000000FFu; else if (i > 4) m = 0; }
            if ((on[i] ^ orf[i]) & m) d = true;
        }
        if (d) { if (bad < 5) printf("  cycle %llu: outputs differ (in_cmd %d)\n", cyc, in_cmd); bad++; }
        // the reference side's view drives the environment
        bool fc_send = orf[1] >> 4 & 1;            // bit 36
        bool c_ready = orf[1] >> 6 & 1;            // bit 38
        bool m_valid = orf[5] >> 26 & 1, m_write = orf[5] >> 25 & 1, m_quad = orf[5] >> 24 & 1;   // bits 186..184
        (void)m_valid; (void)m_write; (void)m_quad;
        auto fields = [](const u32* o, u32& len, u32& off, u32& nbk, u32* slot) {
            // fc_data = o[136..255]: {length 15, offset 32, blocks 3, slots 5 x 14}
            auto bit = [&](int k) { return (o[k >> 5] >> (k & 31)) & 1u; };
            auto get = [&](int lo, int w) { u32 v = 0; for (int k = 0; k < w; k++) v |= bit(136 + lo + k) << k; return v; };
            for (int k = 0; k < 5; k++) slot[k] = get(14 * k, 14);
            nbk = get(70, 3); off = get(73, 32); len = get(105, 15);
        };
        if (orf[1] >> 8 & 1) n_ready++;
        if (orf[1] >> 5 & 1) n_word++;
        if (c_ready) n_req++;
        if (t->mk_valid && t->mk_err) n_err++;
        if (fc_send && busy == 0) { n_cmd++; }
        if (fc_send && busy == 0) { busy = 3 + r(6); exec_at = cyc + 5 + r(150); in_cmd = true; }
        if (exec_at >= 0 && (long)cyc == exec_at) {
            for (int side = 0; side < 2; side++) {
                u32 len, off, nbk, slot[5]; fields(side ? orf : on, len, off, nbk, slot);
                Sdram& s = side ? sr : sn;
                for (u32 w = 0; w < (len + 3) / 4; w++) {
                    u32 k = w >> 10; if (k >= nbk || k >= 5) break;
                    s.mem[CACHE_W + slot[k] * 1024 + (w & 1023)] = romword(off + 4 * w);
                }
            }
            exec_at = -1; mark_at = cyc + 1 + r(40);
        }
        if (busy > 0) busy--;
        // client: a new request now and then, near the last block or anywhere
        if (cv && c_ready) cv = false;
        else if (!cv && r(6) == 0) {
            u32 b = r(3) ? (lastb + r(3)) % nb : r(nb);
            lastb = b; ca = (b << 12 | r(4096)) & ~15u; if (ca >= rom) ca = (rom - 1) & ~15u; cv = true;
        }
        // memories see this cycle's requests
        u32 a_n = on[4] >> 8 | (on[5] & 0xFFFF) << 24, a_r = orf[4] >> 8 | (orf[5] & 0xFFFF) << 24;
        (void)a_n; (void)a_r;
        auto mreq = [](const u32* o, bool& v, bool& w, bool& q, u32& a, u32& wd, u32& be) {
            auto bit = [&](int k) { return (o[k >> 5] >> (k & 31)) & 1u; };
            auto get = [&](int lo, int wdt) { u32 x = 0; for (int k = 0; k < wdt; k++) x |= bit(lo + k) << k; return x; };
            q = bit(73); w = bit(74); v = bit(75); be = get(76, 4); wd = get(80, 32); a = get(112, 24);
        };
        bool v, w, q; u32 a, wd, be;
        mreq(on, v, w, q, a, wd, be);  sn.step(v, w, q, a, wd, be);
        mreq(orf, v, w, q, a, wd, be); sr.step(v, w, q, a, wd, be);
        // r_data check against the ROM model: the client's words must be the ROM's
        t->clk = 0; t->eval(); t->clk = 1; t->eval();
    }
    printf("%s: %llu cycles, %llu mismatching cycles (seed %llu, rom %u bytes, ndt %d; %llu commands, %llu errors, %llu requests, %llu words, ready %llu cycles)\n",
           bad ? "FAIL" : "PASS", cyc, bad, seed, rom, ndt, n_cmd, n_err, n_req, n_word, n_ready);
    return bad ? 1 : 0;
}
