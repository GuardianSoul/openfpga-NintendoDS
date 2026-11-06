// nds_cart equivalence (sim/ds_dev/cart_eq): random ARM-like register
// traffic (commands, ROMCTRL starts of every block size, data-port reads at
// random times, ownership flips, AUXSPI save commands of every kind) on two
// card interfaces; each answers from its own ROM-cache model and save memory
// with the same random latencies. Every output is compared every cycle.
//   Vtb_cart_eq [--seed N] [--ops N]
#include <cstdio>
#include <cstdlib>
#include <map>
#include <random>
#include <string>
#include "Vtb_cart_eq.h"
#include "verilated.h"
typedef unsigned long long u64;
typedef uint32_t u32;
static Vtb_cart_eq* t;
static std::mt19937_64 rng;
static u32 r(u32 n) { return (u32)(rng() % n); }
static u64 cyc = 0, bad = 0;
static u32 romw(u32 a) { return a * 2654435761u ^ 0x5EEDF00Du; }
struct Rom {        // 16-byte reads: request held until ack, then four words
    std::mt19937_64 g; int wait = -1, lat = 0, n = -1; u32 a = 0;
    bool ack = false, rv = false; u32 rd = 0;
    void step(bool req, u32 addr4) {
        ack = false; rv = false;
        if (n >= 0) { if (lat > 0) lat--; else { rv = true; rd = romw(a + 4 * n); if (++n == 4) n = -1; } }
        else if (req) {
            if (wait < 0) wait = (int)(g() % 5);
            if (wait-- == 0) { ack = true; wait = -1; a = addr4 << 4; n = 0; lat = 1 + (int)(g() % 6); }
        }
    }
};
static u64 nwr = 0, ner = 0, nrd = 0;
struct Sav {        // word memory, request held until ack
    std::map<u32, u32> m; std::mt19937_64 g; int wait = -1;
    bool ack = false; u32 rd = 0;
    void step(bool req, bool we, u32 a, u32 be, u32 wd) {
        ack = false;
        if (req) {
            if (wait < 0) wait = (int)(g() % 4);
            if (wait-- == 0) {
                ack = true; wait = -1;
                u32 o = m.count(a) ? m[a] : 0x12345678u ^ a;
                if (we && be != 0xF) nwr++; if (we && be == 0xF) ner++; if (!we) nrd++;
                if (we) { for (int b = 0; b < 4; b++) if (be >> b & 1) o = (o & ~(0xFFu << 8 * b)) | (wd & 0xFFu << 8 * b); m[a] = o; }
                rd = o;
            }
        }
    }
};
static Rom rn, rr; static Sav sn, sr;
static u32 on[4], orf[4];
static void step() {
    t->tick = cyc & 1;
    t->cr_ack_n = rn.ack; t->cr_rvalid_n = rn.rv; t->cr_rdata_n = rn.rd;
    t->cr_ack_r = rr.ack; t->cr_rvalid_r = rr.rv; t->cr_rdata_r = rr.rd;
    t->sv_ack_n = sn.ack; t->sv_rdata_n = sn.rd; t->sv_ack_r = sr.ack; t->sv_rdata_r = sr.rd;
    t->clk = 0; t->eval();
    for (int i = 0; i < 4; i++) { on[i] = t->o_new[i]; orf[i] = t->o_ref[i]; }
    bool d = false; for (int i = 0; i < 4; i++) if (on[i] != orf[i]) d = true;
    if (d) { if (bad < 5) printf("  cycle %llu: outputs differ: new %08x %08x %08x %08x ref %08x %08x %08x %08x\n", cyc, on[3], on[2], on[1], on[0], orf[3], orf[2], orf[1], orf[0]); bad++; }
    auto bit = [](const u32* o, int k) { return (o[k >> 5] >> (k & 31)) & 1u; };
    auto get = [&](const u32* o, int lo, int w) { u32 x = 0; for (int k = 0; k < w; k++) x |= bit(o, lo + k) << k; return x; };
    // layout (LSB first): pad 9, sv_we 9, sv_req 10, cr_req 11, drq 12, irq 13, sv_be 14, sv_addr 18, sv_wdata 36, cr_addr 68, io_rdata 96
    rn.step(bit(on, 11), get(on, 68, 28)); rr.step(bit(orf, 11), get(orf, 68, 28));
    sn.step(bit(on, 10), bit(on, 9), get(on, 18, 18), get(on, 14, 4), get(on, 36, 32));
    sr.step(bit(orf, 10), bit(orf, 9), get(orf, 18, 18), get(orf, 14, 4), get(orf, 36, 32));
    t->clk = 1; t->eval(); cyc++;
}
static void io(bool we, u32 reg, u32 be, u32 wd, bool cpu) {
    t->io_req = 1; t->io_we = we; t->io_reg = reg; t->io_be = be; t->io_wdata = wd; t->io_cpu = cpu; step();
    t->io_req = 0; t->io_we = 0;
    int g = 3 + (r(4) == 0 ? (int)r(60) : 0); while (g--) step();
}
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    u64 seed = 1, ops = 20000;
    for (int i = 1; i + 1 < argc; i++) {
        std::string a = argv[i];
        if (a == "--seed") seed = atoll(argv[++i]); else if (a == "--ops") ops = atoll(argv[++i]);
    }
    rng.seed(seed);
    for (auto* g : {&rn.g, &rr.g}) g->seed(seed * 3 + 1);
    for (auto* g : {&sn.g, &sr.g}) g->seed(seed * 5 + 2);
    t = new Vtb_cart_eq;
    t->rom_size = 0x40000 + r(0x800000); if (r(4) == 0) t->rom_size = 0x100000 + r(0x1FF00000); if (r(2)) t->rom_size &= ~0xFFFu;
    u32 rmask = t->rom_size - 1; for (int i = 0; i < 5; i++) rmask |= rmask >> (1 << i);   // (the new core doesn't wrap at the card's size: stay inside)
    t->save_type = r(8); t->sv_loaded = r(2) ? r(0x100000) & ~3u : 0; t->ir = r(4) == 0; t->raw = r(6) == 0;
    t->owner7 = 0;
    t->rst = 1; for (int i = 0; i < 4; i++) step(); t->rst = 0;
    for (int i = 0; i < 20; i++) step();
    for (u64 op = 0; op < ops; op++) {
        if (op % 16 == 0) {             // a save command, whole: every byte waited for, CS held to the last
            bool cpu = t->owner7;
            auto bw = [&](u32 v, bool last) {
                io(true, 0, 0x3, 0xA000 | (last ? 0 : 0x40) | r(2), cpu);
                io(true, 0, 0x4, v << 16, cpu);
                for (int i = 0; i < 300 + (int)r(40); i++) step();     // (64 or 128 ticks, the memory's latency)
            };
            io(true, 0, 0x2, 0x0000, cpu);
            u32 ab = t->save_type == 1 ? 1 : t->save_type <= 3 ? 2 : 3, a = r(0x100000), c;
            static const u32 dc[] = {0x06, 0x02, 0x03, 0x0A, 0x0B, 0xD8, 0xDB, 0x05, 0x04};
            c = dc[r(9)];
            if (c == 0xD8) a &= ~0xFFFFu;
            if (c == 0xDB) a &= ~0xFFu;
            if (t->ir) bw(0, false);
            u32 nd = c == 0x06 || c == 0x04 ? 0 : c == 0x05 ? 1 + r(3) : c == 0xD8 || c == 0xDB ? 0 : 1 + r(12);
            if (c == 0xD8 || c == 0xDB) ab = 3;
            bw(c, nd == 0 && ab == 0);
            if (c != 0x06 && c != 0x04 && c != 0x05) for (u32 i = 0; i < ab; i++) bw(a >> 8 * (ab - 1 - i) & 0xFF, nd == 0 && i + 1 == ab);
            for (u32 i = 0; i < nd; i++) bw(r(256), i + 1 == nd);
            if (c == 0xD8 || c == 0xDB) { int n = 200 + r(3000); while (n--) step(); }
            if (op % 128 == 0 && t->save_type >= 5) {     // the page erase and the sector erase, write enabled
                for (u32 ec : {0xDBu, 0xD8u}) {
                    if (t->ir) bw(0, false);
                    bw(0x06, true);
                    if (t->ir) bw(0, false);
                    u32 ea = r(0x100000) & (ec == 0xD8 ? ~0xFFFFu : ~0xFFu);
                    bw(ec, false);
                    bw(ea >> 16 & 0xFF, false); bw(ea >> 8 & 0xFF, false); bw(ea & 0xFF, true);
                    int n = (ec == 0xD8 ? 70000 : 1000) + r(100); while (n--) step();
                }
            }
        }
        bool cpu = t->owner7 ? (r(10) != 0) : (r(10) == 0);       // mostly the owner
        u32 k = r(100);
        if (k < 2) t->owner7 = !t->owner7;
        else if (k < 30) {            // a ROM transfer: command, start, then reads of its words
            if (r(8)) io(true, 0, 0x3, 0x8000 | (r(2) << 14), cpu);       // AUXSPICNT: ROM mode, IRQ sometimes
            u32 a = (r(4) == 0 ? r(0x8000) : r(t->rom_size + 0x4000)) & rmask;
            u32 c = r(10) < 8 ? 0xB7 : r(2) ? 0xB8 : r(256);
            io(true, 2, 0xF, c | (a >> 24 & 0xFF) << 8 | (a >> 16 & 0xFF) << 16 | (a >> 8 & 0xFF) << 24, cpu);
            io(true, 3, 0xF, a & 0xFF, cpu);
            u32 ds = r(8);
            io(true, 1, 0xF, 0x80000000u | ds << 24 | r(0x10000), cpu);
            u32 n = ds == 0 ? 0 : ds == 7 ? 1 : 64u << ds;
            n = n > 300 ? 300 : n;
            for (u32 w = 0; w < n + r(3); w++) io(false, r(20) ? 4 : 1, 0xF, 0, cpu);
        } else if (k < 40) io(false, r(5), 0xF, 0, cpu);
        else if (k < 50) io(true, 1, r(16), r(0x10000) << 16 | r(0x10000), cpu);
        else {                         // AUXSPI: enable SPI mode, then a save command's bytes
            io(true, 0, 0x2, 0x0000, cpu);                               // CS dropped: the command's first byte is its first
            io(true, 0, 0x3, 0xA000 | 0x40 | r(4), cpu);                 // enable, SPI mode, hold CS, baud
            static const u32 cmds[] = {0x03, 0x0B, 0x02, 0x0A, 0x05, 0x01, 0x04, 0x06, 0x9F, 0xD8, 0xDB, 0x00, 0x08};
            u32 nb = 1 + r(8);
            u32 ci = t->ir ? 1 : 0, cc = 0;   // the command's byte; an erase's address aligned (the chips align; nds_cart relies on it)
            for (u32 b = 0; b < nb; b++) {
                u32 v = b == 0 && !ci ? cmds[r(13)] : b == ci ? cmds[r(13)] : r(ci ? (b == 0 ? 2 : 256) : 256);
                if (b == ci) cc = v;
                if (b == 0 && ci) v = r(2) ? 0 : cmds[r(13)];
                if ((cc == 0xD8 && b >= ci + 2) || (cc == 0xDB && b >= ci + 3)) v = 0;
                if (b + 1 == nb) io(true, 0, 0x3, 0xA000 | r(4), cpu);    // last byte: CS released after
                io(true, 0, 0x4, v << 16, cpu);
                for (int i = 0; i < 300 && (t->o_ref[3] >> 0, true); i++) { io(false, 0, 0xF, 0, cpu); if (r(3)) break; }
                // an erase's bytes all arrive (a byte written while busy is dropped and would misalign its address)
                if (cc == 0xD8 || cc == 0xDB || (b == 0 && ci) || r(8)) { step(); for (int i = 0; i < 3000 && (io(false, 0, 0xF, 0, cpu), (t->o_ref[3] >> 7 & 1)); i++) ; }
            }
            if (r(3) == 0) io(true, 0, 0x2, 0x0000, cpu);                // drop CS
        }
    }
    printf("save type %u: byte writes %llu, erase words %llu, reads %llu (both instances)\n", (unsigned)t->save_type, nwr, ner, nrd);
    printf("%s: %llu ops, %llu cycles, %llu mismatching cycles (seed %llu)\n", bad ? "FAIL" : "PASS", ops, cyc, bad, seed);
    return bad ? 1 : 0;
}
