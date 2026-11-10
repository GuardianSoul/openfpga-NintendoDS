// Request-ordering regression derived from scpu_eq.cpp. Actual SERV/cache firmware
// serves the same randomized client workload on two independent memory models.
// The reference uses ordinary ready-before-data ordering; the tested side can
// return the final read word before ready. A captured transaction remains owned
// until acknowledgement; meaningful request fields must not change meanwhile.
// --mutate injects a premature observed address change; --corrupt changes one
// returned cache word. The runner requires concrete witnesses for both controls.
#include <cstdio>
#include <cstdlib>
#include <map>
#include <random>
#include <string>
#include <vector>
#include "Vtb_scpu_ordering.h"
#include "verilated.h"
typedef uint32_t u32;
static const u32 TABLE_W = 0x300000, CACHE_W = 0x400000, NDT_W = TABLE_W - 0x400, FW_W = 0x2C0800;
static int ordering = -1, mutate = 0, corrupt=0; static unsigned long long cycle_now = 0;
static std::mt19937_64 rng;
static u32 r(u32 n) { return (u32)(rng() % n); }
static std::map<u32, u32> romover;   // --dsrom: the header's and FAT's words
static u32 romword(u32 a) { auto i = romover.find(a); return i != romover.end() ? i->second : a * 2654435761u ^ 0xA5A5F00Du; }

struct Cmd { u32 lb, len, n, slot[5]; bool operator==(const Cmd& o) const {
    if (lb != o.lb || len != o.len || n != o.n) return false;
    for (u32 k = 0; k < n && k < 5; k++) if (slot[k] != o.slot[k]) return false;
    return true; } };
struct Side {
    std::map<u32, u32> mem;
    std::mt19937_64 g;
    int n = 0, left = 0;
    bool ready = false, rvalid = false; u32 rdata = 0;
    size_t next = 0; bool cv = false; u32 ca = 0; int words = -1, idle = 0, quiet = 0;   // client
    long exec_at = -1, mark_at = -1; int busy = 0; Cmd cur{}; bool mk = false; u32 mkerr = 0;  // host
    std::vector<Cmd> cmds; unsigned long long bad = 0, misses = 0; bool wait_d = false;
    u32 rd(u32 x) { auto i = mem.find(x); return i == mem.end() ? x * 0x9E3779B1u ^ 0x5BD1E995u : i->second; }
    bool active=false, ack_sent=false, ack_seen=false, pw=false,pq=false; u32 pa=0,pd=0,pb=0;
    int age=0,ack_at=0,data_at=0,delay=-1; const char* label="ref";
    unsigned long long tx=0, delivered=0, violations=0, early=0,capture_cycle=0,last_data_cycle=0; bool injected=false,corrupted=false;
    // Called before the current positive edge. ready/rvalid generated here are
    // driven to the DUT on the following iteration. Compare even on the edge
    // that consumes ready; a legal client changes its outputs only afterwards.
    void step(bool valid, bool write, bool quad, u32 addr, u32 wd, u32 be) {
        bool ack_now=ready; ready=false; rvalid=false;
        if (active) {
            if (!ack_seen) {
                if (mutate && delay<0 && label[0]=='n' && !injected && !ack_now) {addr^=1;injected=true;}
                u32 mask=0;for(int b=0;b<4;b++)if(pb>>b&1)mask|=0xffu<<(8*b);
                bool changed=!valid || write!=pw || addr!=pa || (!pw && quad!=pq) || (pw && (be!=pb || ((wd^pd)&mask)));
                if(changed){violations++;if(violations<=4)printf("CONTRACT_FAIL %s cycle=%llu tx=%llu age=%d ack_at=%d data_at=%d ack_now=%d valid=%d write=%d/%d quad=%d/%d addr=%06x/%06x be=%x/%x data=%08x/%08x injected=%d capture=%llu last_data_input=%llu expected_ack_input=%llu\n",label,cycle_now,tx,age,ack_at,data_at,ack_now,valid,write,pw,quad,pq,addr,pa,be,pb,wd,pd,injected,capture_cycle,last_data_cycle,capture_cycle+ack_at+1);}
                if(ack_now)ack_seen=true;
            }
            age++;
            if(!ack_sent && age>=ack_at){ready=true;ack_sent=true;}
            if(!pw && left>0 && age>=data_at){rvalid=true;rdata=rd(pa+n);if(corrupt && label[0]=='n' && pq && !corrupted){rdata^=1;corrupted=true;printf("DATA_MUTANT cycle=%llu address=%06x xor=00000001\n",cycle_now,pa+n);}n++;left--;delivered++;last_data_cycle=cycle_now+1;if(!ack_seen&&!ack_now&&!ready)early++;}
            if(ack_seen && left==0 && !rvalid)active=false;
            return;
        }
        // Physical acceptance snapshots the request before its delayed client
        // acknowledgement. No later payload change is accepted as a new request.
        if(!valid)return;
        capture_cycle=cycle_now;last_data_cycle=0;active=true;ack_sent=false;ack_seen=false;age=0;tx++;pw=write;pq=quad;pa=addr;pd=wd;pb=be;n=0;
        left=write?0:(quad?4:1);data_at=delay<0?4:2;ack_at=(write||delay<0)?1:data_at+left-1+delay;
        if(write){u32 o=rd(pa);for(int b=0;b<4;b++)if(pb>>b&1)o=(o&~(0xffu<<(8*b)))|(pd&(0xffu<<(8*b)));mem[pa]=o;}
    }

};
static void field(const VlWide<4>& w, u32& len, u32& off, u32& nb) {
    auto bit = [&](int k) { return (w[k >> 5] >> (k & 31)) & 1u; };
    auto get = [&](int lo, int wd) { u32 v = 0; for (int k = 0; k < wd; k++) v |= bit(lo + k) << k; return v; };
    nb = get(70, 3); off = get(73, 32); len = get(105, 15);
}
static std::vector<unsigned char> slurp(const char* p) {
    std::vector<unsigned char> v; FILE* f = fopen(p, "rb"); if (!f) { perror(p); exit(2); }
    int c; while ((c = fgetc(f)) != EOF) v.push_back((unsigned char)c); fclose(f); return v;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    unsigned long long seed = 1; u32 reads = 3000; const char* fr = nullptr; const char* fn = nullptr; int strict = 0, pace = 0, files = 0, trace = 0, dsrom = 0;
    for (int i = 1; i + 1 < argc; i++) {
        std::string s = argv[i];
        if (s == "--ordering") ordering = atoi(argv[++i]);
        else if (s == "--corrupt") corrupt=atoi(argv[++i]);
        else if (s == "--mutate") mutate = atoi(argv[++i]);
        else if (s == "--seed") seed = atoll(argv[++i]);
        else if (s == "--reads") reads = atoi(argv[++i]);
        else if (s == "--ref") fr = argv[++i];
        else if (s == "--new") fn = argv[++i];
        else if (s == "--strict") strict = atoi(argv[++i]);
        else if (s == "--pace") pace = atoi(argv[++i]);
        else if (s == "--files") files = atoi(argv[++i]);
        else if (s == "--trace") trace = atoi(argv[++i]);
        else if (s == "--dsrom") dsrom = atoi(argv[++i]);
    }
    if (!fr || !fn || reads < 2 || ordering < -1) { fprintf(stderr, "invalid firmware/read/ordering arguments\n"); return 2; }
    rng.seed(seed);
    Vtb_scpu_ordering* t = new Vtb_scpu_ordering;
    Side sn, sr; sn.label="new"; sn.delay=ordering; sr.label="ref"; sr.delay=-1; sn.g.seed(seed * 7 + 1); sr.g.seed(seed * 13 + 5);
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
    // --dsrom: no .ndt, but a DS header (its CRC-16 right) and a FAT of files with byte sizes in the ROM; the new
    // firmware builds the read-ahead fields from them, which must equal the plugin's rule (tools/pocket-plugin
    // src/rom.rs Rom::table), checked at the end
    std::vector<u32> want;
    if (dsrom) {
        ndt = false;
        std::vector<std::pair<u32, u32>> spans;
        spans.push_back({0x4000 + 4 * r(0x400), 0}); spans[0].second = spans[0].first + 4 + 4 * r(0x4000);
        spans.push_back({spans[0].second + 4 * r(64), 0}); spans[1].second = spans[1].first + 4 + 4 * r(0x2000);
        u32 nf = 1 + r(300), fo = (spans[1].second + 0x200 + 3) & ~3u;
        u32 a = fo + 8 * nf;
        std::vector<std::pair<u32, u32>> fat;
        for (u32 k = 0; k < nf; k++) {
            u32 st = a + 4 * r(64), len = r(8) == 0 ? 0 : 1 + r(files ? 4096 * files : 0x8000);
            if (r(40) == 0) st = 0xFFFFFF00u;   // past the ROM's end (its end wraps)
            fat.push_back({st, st + len}); if (st < rom) a = st + len;
        }
        if (r(2)) std::swap(fat[0], fat[nf - 1]);   // out of order: later spans overwrite earlier ones
        for (u32 k = 0; k < nf; k++) { romover[fo + 8 * k] = fat[k].first; romover[fo + 8 * k + 4] = fat[k].second; }
        romover[0x20] = spans[0].first; romover[0x2C] = spans[0].second - spans[0].first;
        romover[0x30] = spans[1].first; romover[0x3C] = spans[1].second - spans[1].first;
        romover[0x48] = fo; romover[0x4C] = 8 * nf;
        for (auto& f : fat) spans.push_back(f);
        u32 c = 0xFFFF;
        for (u32 i = 0; i < 0x15E; i++) { c ^= romword(i & ~3u) >> 8 * (i & 3) & 0xFF; for (int k = 0; k < 8; k++) c = c & 1 ? c >> 1 ^ 0xA001 : c >> 1; }
        romover[0x15C] = (romword(0x15C) & 0xFFFF) | c << 16;
        want.assign(nb, 0); unsigned long long budget = 4ull * nb;
        for (auto& sp : spans) {
            u32 e = sp.second < rom ? sp.second : rom; if (sp.first >= e) continue;
            for (u32 b = (sp.first + 0xFFF) >> 12, se = (e + 0xFFF) >> 12; b < se && budget; b++, budget--) want[b] = std::min(se - 1 - b, 4u);
        }
    }
    for (Side* s : {&sn, &sr}) { s->mem[NDT_W] = ndt ? 0x3154444E : 0x12345678; s->mem[NDT_W + 1] = 1; s->mem[NDT_W + 3] = rom; }
    if (ndt) {  // NitroFS-like files: runs of blocks, each block's field min(4, blocks left in its file)
        u32 b = 0;
        while (b < nb) {
            u32 len = 1 + r(r(4) == 0 ? 40 : 6); if (files) len = 1 + r(files);
            for (u32 k = 0; k < len && b < nb; k++, b++) {
                u32 left = len - k - 1; if (left > 4) left = 4;
                sn.mem[TABLE_W + b] = sr.mem[TABLE_W + b] = left << 29;
            }
        }
    }
    std::vector<u32> list(reads);
    // interleaved streams (White 2's map archive reads two), each a cursor: blocks stepping 0-2 at a random
    // offset, or (smode) 512 bytes a read, as Pokemon's file reads, with a jump now and then
    u32 ns = 1 + r(3); bool smode = r(2);
    { u32 cur[3] = {r(rom), r(rom), r(rom)}; for (auto& a : list) {
        u32 k = r(ns);
        if (smode) { cur[k] = r(200) ? (cur[k] + 512) % rom : r(rom); a = cur[k] & ~15u; continue; }
        u32 b = r(3) ? ((cur[k] >> 12) + r(3)) % nb : r(nb); cur[k] = b << 12;
        a = (b << 12 | r(4096)) & ~15u; if (a >= rom) a = (rom - 1) & ~15u; } }
    t->reset = 1; t->start = 0; t->rom_size = rom;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    for (int i = 0; i < 4; i++) tick();
    t->reset = 0;
    unsigned long long cyc = 0, limit = (unsigned long long)reads * (60000 + 4ull * pace) + 40000000ull;
    bool restarted = false; int restart_at = -1;
    for (; cyc < limit; cyc++) {
        cycle_now=cyc;
        if (cyc == 10) t->start = 1;
        // the restart: when both clients have done half the list and are idle
        if (!restarted && sn.next >= reads / 2 && sr.next >= reads / 2 && !sn.cv && !sr.cv && sn.words < 0 && sr.words < 0
            && sn.mark_at < 0 && sr.mark_at < 0 && sn.exec_at < 0 && sr.exec_at < 0 && (!strict || (sn.quiet > 256 && sr.quiet > 256))) { restarted = true; restart_at = (int)(cyc % 1000000);
            for (Side* s : {&sn, &sr}) { s->left = 0; s->active=false; s->ready=false; s->rvalid=false; }   // the SDRAM port resets with the cache (rst_bus): a read in flight is dropped
            t->reset = 1; t->start = 0; tick(); tick(); t->reset = 0; for (int i = 0; i < 10; i++) tick(); t->start = 1; }
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
                if (++s.words == 4) { s.words = -1; s.idle = pace + (int)(s.g() % 7); }
            } else if (!s.cv && s.words < 0 && ready_c && s.next < list.size() && !(restarted == false && s.next >= reads / 2)) {
                if (s.idle-- <= 0 && (!strict || (s.quiet > 256 && s.exec_at < 0 && s.mark_at < 0 && !s.mk))) { s.ca = list[s.next++]; s.cv = true; if (trace > 1 && isnew) printf("  new %llu read %x\n", cyc, s.ca); }
            }
            // host
            if (fc_send) {
                u32 len, off, n; field(fc, len, off, n);
                s.cur.lb = off >> 12; s.cur.len = len; s.cur.n = n;
                for (int k = 0; k < 5; k++) {   // the slots from the MLAB (fc_data has none since 21c8d70e)
                    if (isnew) { t->fc_sel_n = k; t->eval(); s.cur.slot[k] = t->fc_slot_n; }
                    else { t->fc_sel_r = k; t->eval(); s.cur.slot[k] = t->fc_slot_r; }
                }
                s.cmds.push_back(s.cur);
                if (trace) printf("  %s %llu cmd %x+%u\n", isnew ? "new" : "ref", cyc, s.cur.lb, s.cur.n);
                s.busy = 3 + (int)(s.g() % 6); s.exec_at = (long)cyc + 5 + 2 * pace + (long)(s.g() % 150);
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
        { static bool rn = false, rr = false;
          if (t->ready_n && !rn) printf("  new ready at cycle %llu\n", cyc);
          if (t->ready_r && !rr) printf("  ref ready at cycle %llu\n", cyc);
          rn = t->ready_n; rr = t->ready_r; }
        if (t->dg_wait_n && !sn.wait_d) { sn.misses++; if (trace) printf("  new %llu miss %x\n", cyc, sn.ca >> 12); }
        if (t->dg_wait_r && !sr.wait_d) { sr.misses++; if (trace) printf("  ref %llu miss %x\n", cyc, sr.ca >> 12); }
        sn.wait_d = t->dg_wait_n; sr.wait_d = t->dg_wait_r;
        serve(sn, t->c_ready_n, t->r_valid_n, t->r_data_n, t->ready_n, t->fc_send_n, t->fc_data_n, true);
        serve(sr, t->c_ready_r, t->r_valid_r, t->r_data_r, t->ready_r, t->fc_send_r, t->fc_data_r, false);
        sn.quiet = t->m_valid_n ? 0 : sn.quiet + 1; sr.quiet = t->m_valid_r ? 0 : sr.quiet + 1;
        sn.step(t->m_valid_n, t->m_write_n, t->m_quad_n, t->m_addr_n, t->m_wdata_n, t->m_be_n);
        sr.step(t->m_valid_r, t->m_write_r, t->m_quad_r, t->m_addr_r, t->m_wdata_r, t->m_be_r);
        if(sn.violations||sr.violations){printf("ORDERING_FAIL delay=%d transactions=%llu/%llu returned_words=%llu/%llu early_words=%llu mutated=%d\n",ordering,sn.tx,sr.tx,sn.delivered,sr.delivered,sn.early,mutate);return 3;}
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
    u32 tbad = 0;
    for (u32 b = 0; b < want.size(); b++) if ((sn.rd(TABLE_W + b) >> 29) != want[b]) { if (tbad++ < 5) printf("  new table block %u: read-ahead %u, rule %u\n", b, sn.rd(TABLE_W + b) >> 29, want[b]); }
    if (dsrom) printf("  read-ahead fields: %u of %u blocks differ from the rule\n", tbad, (u32)want.size());
    bool ok = done && same && !sn.bad && !sr.bad && !tbad;
    printf("%s: %s %llu cycles, seed %llu, rom %u bytes, ndt %d, streams %u%s; %zu/%zu commands, %zu same, bad words %llu/%llu; reads %zu/%zu, misses %llu/%llu, ready %d/%d\n",
           ok ? "PASS" : "FAIL", strict ? "strict" : "race", cyc, seed, rom, ndt, ns, smode ? " x512" : "", sn.cmds.size(), sr.cmds.size(), first, sn.bad, sr.bad, sn.next, sr.next, sn.misses, sr.misses, (int)t->ready_n, (int)t->ready_r);
    printf("ORDERING_COUNTS delay=%d transactions=%llu/%llu returned_words=%llu/%llu early_words=%llu violations=%llu/%llu mutated=%d\n",ordering,sn.tx,sr.tx,sn.delivered,sr.delivered,sn.early,sn.violations,sr.violations,mutate);
    return ok ? 0 : 1;
}
