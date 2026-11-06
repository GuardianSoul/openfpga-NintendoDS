// nds_cart_scpu equivalence (sim/pocket/scpu_eq): both caches run their own firmware and serve the same list of
// client reads, each at its own pace (SERV's timing may differ). Every word the client gets must be the ROM's.
// --strict: the client's next read waits until the firmware and host are quiet, which fixes the commands' order
// (a held client versus a read just arriving depends on timing otherwise), and both must send the same APF
// commands in the same order: first block, length, blocks, slots. Without it reads race the firmware. Unwritten SDRAM is
// garbage (as the Pocket's): a firmware trusting an owner or a table it didn't set up fails. A restart halfway
// leaves the reference bits, owners and table of the first run behind.
//   Vtb_scpu_eq --seed N --ref ref.bin --new new.bin [--reads N] [--strict 1]
#include <cstdio>
#include <cstdlib>
#include <map>
#include <random>
#include <string>
#include <vector>
#include "Vtb_scpu_eq.h"
#include "verilated.h"
typedef uint32_t u32;
static const u32 TABLE_W = 0x300000, CACHE_W = 0x400000, NDT_W = TABLE_W - 0x400, FW_W = 0x2C0800;
static std::mt19937_64 rng;
static u32 r(u32 n) { return (u32)(rng() % n); }
static u32 romword(u32 a) { return a * 2654435761u ^ 0xA5A5F00Du; }

struct Cmd { u32 lb, len, n, slot[5]; bool operator==(const Cmd& o) const {
    if (lb != o.lb || len != o.len || n != o.n) return false;
    for (u32 k = 0; k < n && k < 5; k++) if (slot[k] != o.slot[k]) return false;
    return true; } };
struct Side {
    std::map<u32, u32> mem;
    std::mt19937_64 g;
    int wait = -1, lat = 0, n = 0, left = 0; u32 a = 0;
    bool ready = false, rvalid = false; u32 rdata = 0;
    size_t next = 0; bool cv = false; u32 ca = 0; int words = -1, idle = 0, quiet = 0;   // client
    long exec_at = -1, mark_at = -1; int busy = 0; Cmd cur{}; bool mk = false; u32 mkerr = 0;  // host
    std::vector<Cmd> cmds; unsigned long long bad = 0;
    u32 rd(u32 x) { auto i = mem.find(x); return i == mem.end() ? x * 0x9E3779B1u ^ 0x5BD1E995u : i->second; }
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
static void field(const VlWide<4>& w, u32& len, u32& off, u32& nb) {
    auto bit = [&](int k) { return (w[k >> 5] >> (k & 31)) & 1u; };
    auto get = [&](int lo, int wd) { u32 v = 0; for (int k = 0; k < wd; k++) v |= bit(lo + k) << k; return v; };
    nb = get(70, 3); off = get(73, 32); len = get(105, 15);
}
static void slotsold(const VlWide<4>& w, u32* s) {
    auto bit = [&](int k) { return (w[k >> 5] >> (k & 31)) & 1u; };
    for (int k = 0; k < 5; k++) { s[k] = 0; for (int i = 0; i < 14; i++) s[k] |= bit(14 * k + i) << i; }
}
static std::vector<unsigned char> slurp(const char* p) {
    std::vector<unsigned char> v; FILE* f = fopen(p, "rb"); if (!f) { perror(p); exit(2); }
    int c; while ((c = fgetc(f)) != EOF) v.push_back((unsigned char)c); fclose(f); return v;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    unsigned long long seed = 1; u32 reads = 3000; const char* fr = nullptr; const char* fn = nullptr; int strict = 0;
    for (int i = 1; i + 1 < argc; i++) {
        std::string s = argv[i];
        if (s == "--seed") seed = atoll(argv[++i]);
        else if (s == "--reads") reads = atoi(argv[++i]);
        else if (s == "--ref") fr = argv[++i];
        else if (s == "--new") fn = argv[++i];
        else if (s == "--strict") strict = atoi(argv[++i]);
    }
    rng.seed(seed);
    Vtb_scpu_eq* t = new Vtb_scpu_eq;
    Side sn, sr; sn.g.seed(seed * 7 + 1); sr.g.seed(seed * 13 + 5);
    auto load = [](Side& s, const std::vector<unsigned char>& b) {
        for (size_t i = 0; i + 3 < b.size() + 3; i += 4) {
            u32 w = 0; for (int k = 0; k < 4; k++) if (i + k < b.size()) w |= (u32)b[i + k] << 8 * k;
            s.mem[FW_W + (u32)(i / 4)] = w;
        }
    };
    load(sn, slurp(fn)); load(sr, slurp(fr));
    u32 rom = 0x10000 + r(0x200000); if (r(3) == 0) rom &= ~0xFFFu;
    u32 nb = (rom + 0xFFF) >> 12;
    bool ndt = r(4) != 0;
    for (Side* s : {&sn, &sr}) { s->mem[NDT_W] = ndt ? 0x3154444E : 0x12345678; s->mem[NDT_W + 1] = 1; s->mem[NDT_W + 3] = rom; }
    if (ndt) {  // NitroFS-like files: runs of blocks, each block's field min(4, blocks left in its file)
        u32 b = 0;
        while (b < nb) {
            u32 len = 1 + r(r(4) == 0 ? 40 : 6);
            for (u32 k = 0; k < len && b < nb; k++, b++) {
                u32 left = len - k - 1; if (left > 4) left = 4;
                sn.mem[TABLE_W + b] = sr.mem[TABLE_W + b] = left << 29;
            }
        }
    }
    std::vector<u32> list(reads);
    { u32 lastb = 0; for (auto& a : list) {
        u32 b = r(3) ? (lastb + r(3)) % nb : r(nb); lastb = b;
        a = (b << 12 | r(4096)) & ~15u; if (a >= rom) a = (rom - 1) & ~15u; } }
    t->reset = 1; t->start = 0; t->rom_size = rom;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    for (int i = 0; i < 4; i++) tick();
    t->reset = 0;
    unsigned long long cyc = 0, limit = (unsigned long long)reads * 60000 + 40000000ull;
    bool restarted = false; int restart_at = -1;
    for (; cyc < limit; cyc++) {
        if (cyc == 10) t->start = 1;
        // the restart: when both clients have done half the list and are idle
        if (!restarted && sn.next >= reads / 2 && sr.next >= reads / 2 && !sn.cv && !sr.cv && sn.words < 0 && sr.words < 0
            && sn.mark_at < 0 && sr.mark_at < 0 && sn.exec_at < 0 && sr.exec_at < 0 && (!strict || (sn.quiet > 256 && sr.quiet > 256))) { restarted = true; restart_at = (int)(cyc % 1000000); t->reset = 1; t->start = 0; tick(); tick(); t->reset = 0; for (int i = 0; i < 10; i++) tick(); t->start = 1; }
        t->fc_busy_n = sn.busy > 0; t->fc_busy_r = sr.busy > 0;
        t->mk_valid_n = sn.mk; t->mk_err_n = sn.mkerr; t->mk_valid_r = sr.mk; t->mk_err_r = sr.mkerr; sn.mk = sr.mk = false;
        t->c_valid_n = sn.cv; t->c_addr_n = sn.ca; t->c_valid_r = sr.cv; t->c_addr_r = sr.ca;
        t->m_ready_n = sn.ready; t->m_rvalid_n = sn.rvalid; t->m_rdata_n = sn.rdata;
        t->m_ready_r = sr.ready; t->m_rvalid_r = sr.rvalid; t->m_rdata_r = sr.rdata;
        t->eval();
        auto serve = [&](Side& s, bool c_ready, bool r_valid, u32 r_data, bool ready_c, bool fc_send, const VlWide<4>& fc, bool isnew) {
            // client
            if (s.cv && c_ready) { s.cv = false; s.words = 0; }
            else if (s.words >= 0 && r_valid) {
                if (s.ca + 4 * s.words < rom && r_data != romword(s.ca + 4 * s.words)) { if (s.bad++ < 5) printf("  %s cycle %llu: read %08x word %d = %08x, ROM %08x\n", isnew ? "new" : "ref", cyc, s.ca, s.words, r_data, romword(s.ca + 4 * s.words)); }
                if (++s.words == 4) { s.words = -1; s.idle = (int)(s.g() % 7); }
            } else if (!s.cv && s.words < 0 && ready_c && s.next < list.size() && !(restarted == false && s.next >= reads / 2)) {
                if (s.idle-- <= 0 && (!strict || (s.quiet > 256 && s.exec_at < 0 && s.mark_at < 0 && !s.mk))) { s.ca = list[s.next++]; s.cv = true; }
            }
            // host
            if (fc_send) {
                u32 len, off, n; field(fc, len, off, n);
                s.cur.lb = off >> 12; s.cur.len = len; s.cur.n = n;
                if (isnew) { for (int k = 0; k < 5; k++) { t->fc_sel_n = k; t->eval(); s.cur.slot[k] = t->fc_slot_n; } }
                else slotsold(fc, s.cur.slot);
                s.cmds.push_back(s.cur);
                s.busy = 3 + (int)(s.g() % 6); s.exec_at = (long)cyc + 5 + (long)(s.g() % 150);
            }
            if (s.exec_at >= 0 && (long)cyc == s.exec_at) {
                for (u32 w = 0; w < (s.cur.len + 3) / 4; w++) {
                    u32 k = w >> 10; if (k >= s.cur.n || k >= 5) break;
                    s.mem[CACHE_W + s.cur.slot[k] * 1024 + (w & 1023)] = romword((s.cur.lb << 12) + 4 * w);
                }
                s.exec_at = -1; s.mark_at = (long)cyc + 1 + (long)(s.g() % 40);
            }
            if (s.mark_at >= 0 && (long)cyc == s.mark_at) {
                s.mk = true; s.mkerr = (s.cmds.size() % 9 == 8) ? 1 : 0; s.mark_at = -1;
            }
            if (s.busy > 0) s.busy--;
        };
        serve(sn, t->c_ready_n, t->r_valid_n, t->r_data_n, t->ready_n, t->fc_send_n, t->fc_data_n, true);
        serve(sr, t->c_ready_r, t->r_valid_r, t->r_data_r, t->ready_r, t->fc_send_r, t->fc_data_r, false);
        sn.quiet = t->m_valid_n ? 0 : sn.quiet + 1; sr.quiet = t->m_valid_r ? 0 : sr.quiet + 1;
        sn.step(t->m_valid_n, t->m_write_n, t->m_quad_n, t->m_addr_n, t->m_wdata_n, t->m_be_n);
        sr.step(t->m_valid_r, t->m_write_r, t->m_quad_r, t->m_addr_r, t->m_wdata_r, t->m_be_r);
        t->clk = 0; t->eval(); t->clk = 1; t->eval();
        if (restarted && sn.next == list.size() && sr.next == list.size() && !sn.cv && !sr.cv && sn.words < 0 && sr.words < 0
            && sn.mark_at < 0 && sr.mark_at < 0 && sn.exec_at < 0 && sr.exec_at < 0) break;
    }
    size_t first = 0, nc = std::min(sn.cmds.size(), sr.cmds.size());
    while (first < nc && sn.cmds[first] == sr.cmds[first]) first++;
    bool done = cyc < limit, same = !strict || (first == nc && sn.cmds.size() == sr.cmds.size());
    if (strict && !same && first < nc) {
        const Cmd& a = sn.cmds[first]; const Cmd& b = sr.cmds[first];
        printf("  command %zu: new lb %u len %u n %u slot0 %u, ref lb %u len %u n %u slot0 %u\n", first, a.lb, a.len, a.n, a.slot[0], b.lb, b.len, b.n, b.slot[0]);
    }
    bool ok = done && same && !sn.bad && !sr.bad;
    printf("%s: %s %llu cycles, seed %llu, rom %u bytes, ndt %d; %zu/%zu commands, %zu same, bad words %llu/%llu; reads %zu/%zu, ready %d/%d\n",
           ok ? "PASS" : "FAIL", strict ? "strict" : "race", cyc, seed, rom, ndt, sn.cmds.size(), sr.cmds.size(), first, sn.bad, sr.bad, sn.next, sr.next, (int)t->ready_n, (int)t->ready_r);
    return ok ? 0 : 1;
}
