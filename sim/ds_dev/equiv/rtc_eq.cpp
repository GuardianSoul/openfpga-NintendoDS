// RTC equivalence (sim/ds_dev/equiv): random ARM7-like traffic on 0x138
// (every command form, data bytes in and out, valid and invalid BCD, 12/24-hour
// switches, resets), bridge loads near rollovers and short seconds; io_rdata
// of the two RTCs must match on every cycle.
//   Vtb_rtc_eq [--seed N] [--ops N] [--gap N]   (gap: least clocks between writes)
#include <cstdio>
#include <cstdlib>
#include <random>
#include "Vtb_rtc_eq.h"
#include "verilated.h"
#include "Vtb_rtc_eq___024root.h"
typedef unsigned long long u64;
static Vtb_rtc_eq* t;
static std::mt19937_64 rng;
static u64 cyc = 0, bad = 0;
static char hist[64][96]; static int hn = 0;
static void note(const char* s) { snprintf(hist[hn++ % 64], 96, "%llu %s", cyc, s); }
static long init_cd = -1;           // a bridge load armed inside a transfer: clocks to go
static unsigned init_d, init_t;
static u64 init_fired;              // cycle the armed load fired: init_* held 40 clocks after it
static void step() {
    if (init_cd == 0) { t->init_date_bcd = init_d; t->init_time_bcd = init_t; t->init_valid = 1; init_fired = cyc; }
    if (init_cd >= 0) init_cd--;
    t->tick = cyc & 1;
    t->clk = 0; t->eval(); t->clk = 1; t->eval();
    static bool fdiv = false;
#ifndef RTC_VALID
    if (getenv("RTC_WIN")) {
        u64 w0 = atoll(getenv("RTC_WIN"));
        if (cyc >= w0 && cyc < w0 + 120) {
            auto& R = *t->rootp;
            printf("  %llu io_n %04x io_r %04x pend_n %d pend_r %d go %d ks %d se_n %02x se_r %02x req %d we %d wd %04x\n", cyc,
                (unsigned)R.tb_rtc_eq__DOT__u_new__DOT__io, (unsigned)R.tb_rtc_eq__DOT__u_ref__DOT__io,
                (int)R.tb_rtc_eq__DOT__u_new__DOT__pend, (int)R.tb_rtc_eq__DOT__u_ref__DOT__pend,
                (int)R.tb_rtc_eq__DOT__u_new__DOT__k_n, (int)R.tb_rtc_eq__DOT__u_new__DOT__ks,
                (unsigned)R.tb_rtc_eq__DOT__u_new__DOT__rm[0], (unsigned)R.tb_rtc_eq__DOT__u_ref__DOT__se,
                (int)t->io_req, (int)t->io_we, (unsigned)t->io_wdata);
        }
    }
    if (getenv("RTC_FIELDS") && !t->rst && !fdiv) {
        auto& R = *t->rootp;
        if (R.tb_rtc_eq__DOT__u_new__DOT__ks == 0 && !R.tb_rtc_eq__DOT__u_new__DOT__k_n &&
            !R.tb_rtc_eq__DOT__u_new__DOT__rw_v &&    // no write still on its way to the RAM
            !R.tb_rtc_eq__DOT__u_new__DOT__mo_pend && !R.tb_rtc_eq__DOT__u_new__DOT__adj_pend) {   // nor deferred arithmetic
            auto& m = R.tb_rtc_eq__DOT__u_new__DOT__rm;
            unsigned n[7] = {m[0], m[1], m[2], m[3], R.tb_rtc_eq__DOT__u_new__DOT__hr, R.tb_rtc_eq__DOT__u_new__DOT__mo, R.tb_rtc_eq__DOT__u_new__DOT__yr};
            unsigned o[7] = {R.tb_rtc_eq__DOT__u_ref__DOT__se, R.tb_rtc_eq__DOT__u_ref__DOT__mi, R.tb_rtc_eq__DOT__u_ref__DOT__dy, R.tb_rtc_eq__DOT__u_ref__DOT__dw,
                             R.tb_rtc_eq__DOT__u_ref__DOT__hr, R.tb_rtc_eq__DOT__u_ref__DOT__mo, R.tb_rtc_eq__DOT__u_ref__DOT__yr};
            for (int i = 0; i < 7; i++) if (n[i] != o[i]) {
                fdiv = true;
                printf("  fields differ at cycle %llu: field %d new %02x ref %02x\n", cyc, i, n[i], o[i]);
                for (int k = hn > 12 ? hn - 12 : 0; k < hn; k++) printf("    %s\n", hist[k % 64]);
                break;
            }
        }
    }
#endif
    if (!t->rst && t->q_new != t->q_ref) {
        if (bad == 0) for (int i = hn > 12 ? hn - 12 : 0; i < hn; i++) printf("    %s\n", hist[i % 64]);
        if (bad < 5) printf("  cycle %llu: new %08x ref %08x\n", cyc, t->q_new, t->q_ref);
#ifdef RTC_VALID
        if (bad == 0) { auto& R = *t->rootp; printf("  new hr %02x mo %02x yr %02x s1 %d ref hr %02x pm %d mo %02x yr %02x s1 %d\n",
            (unsigned)R.tb_rtc_eq__DOT__u_new__DOT__hr, (unsigned)R.tb_rtc_eq__DOT__u_new__DOT__mo, (unsigned)R.tb_rtc_eq__DOT__u_new__DOT__yr, (unsigned)R.tb_rtc_eq__DOT__u_new__DOT__s1,
            (unsigned)R.tb_rtc_eq__DOT__u_ref__DOT__hr, (unsigned)R.tb_rtc_eq__DOT__u_ref__DOT__pm, (unsigned)R.tb_rtc_eq__DOT__u_ref__DOT__mo, (unsigned)R.tb_rtc_eq__DOT__u_ref__DOT__yr, (unsigned)R.tb_rtc_eq__DOT__u_ref__DOT__s1); }
#endif
        bad++;
    }
    cyc++;
}
static int gap = 4;
static void wr(unsigned v, unsigned be = 3) {
    t->io_req = 1; t->io_we = 1; t->io_be = be; t->io_wdata = v; step();
    t->io_req = 0; t->io_we = 0;
    int g = gap - 1 + (int)(rng() % 4 == 0 ? rng() % 40 : 0);
    while (g--) step();
}
static unsigned r(unsigned n) { return (unsigned)(rng() % n); }
static unsigned bcd(unsigned v) { return (v / 10) << 4 | (v % 10); }
enum { CS0 = 0x40, CS1 = 0x44, SCK0 = 0x20, SCK1 = 0x22, SO = 0x10 };
static void sendb(unsigned b) { for (int i = 0; i < 8; i++) { unsigned d = (b >> i) & 1; wr(CS1 | SCK0 | SO | d); wr(CS1 | SCK1 | SO | d); } }
static void recvb() { for (int i = 0; i < 8; i++) { wr(CS1 | SCK0); wr(CS1 | SCK1); } }
#ifdef RTC_VALID
#define RTC24 2u
#else
#define RTC24 0u
#endif
static unsigned rbyte() {   // a data byte: valid BCD mostly, sometimes anything
#ifdef RTC_VALID
    return r(100) == 0 ? 0 : bcd(r(60));   // (register bytes only: the date and time fields only through the valid writes above)
#endif
    if (r(4) == 0) return r(256);
    static const unsigned lim[] = {99, 12, 31, 6, 23, 59, 59};
    return bcd(r(lim[r(7)] + 1));
}
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    u64 seed = 1, ops = 3000;
    for (int i = 1; i + 1 < argc; i++) {
        std::string a = argv[i];
        if (a == "--seed") seed = atoll(argv[++i]);
        else if (a == "--ops") ops = atoll(argv[++i]);
        else if (a == "--gap") gap = atoi(argv[++i]);
    }
    rng.seed(seed);
    t = new Vtb_rtc_eq;
    t->rst = 1; for (int i = 0; i < 4; i++) step(); t->rst = 0;
    for (int i = 0; i < 40; i++) step();
    for (u64 op = 0; op < ops; op++) {
        unsigned k = r(20);
        if (k == 0 && init_cd < 0) {   // a date+time write as the boot program's (was the bridge load), often near a rollover
            note("init");
            static const unsigned dd[][3] = {{23,12,31},{24,2,28},{23,2,28},{24,2,29},{25,4,30},{99,12,31},{0,1,1},{48,2,29}};
            auto& d = dd[r(8)];
            unsigned y = r(2) ? d[0] : r(100), m = r(2) ? d[1] : 1 + r(12), dy = r(2) ? d[2] : 1 + r(28);
#ifdef RTC_VALID
            { static const unsigned md[] = {31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
              unsigned l = m == 2 && y % 4 != 0 ? 28 : md[m - 1]; if (dy > l) dy = l; }
#endif
            unsigned h = r(2) ? 23 : r(24), mi = r(2) ? 59 : r(60), s = r(2) ? 58 + r(2) : r(60);
            static const unsigned cm[] = {0, 3, 3, 6, 1, 4, 6, 2, 5, 0, 3, 5};   // days before the month, mod 7
            unsigned dow = (5 + y + (y + 3) / 4 + cm[m - 1] + (y % 4 == 0 && m > 2) + dy) % 7;
            wr(CS0 | SCK1); wr(CS1 | SCK1);
            sendb(0x26);
            for (unsigned b : {bcd(y), bcd(m), bcd(dy), dow, bcd(h), bcd(mi), bcd(s)}) sendb(b);
            wr(CS0 | SCK1);
        } else if (k == 19 && false) {   // (the bridge load inside a transfer: gone with the load)
            note("init mid-transfer");
            t->init_valid = 0; for (int i = 0; i < 4; i++) step();
            init_d = 0x20000000 | bcd(r(100)) << 16 | bcd(1 + r(12)) << 8 | bcd(1 + r(28));
            init_t = bcd(r(24)) << 16 | bcd(r(60)) << 8 | bcd(r(60));
            init_cd = 8 + r(600);
            continue;
        } else if (k == 1) {   // idle a while: seconds count, maybe roll over
            note("idle"); int n = 20 + r(2000); while (n--) step();
#ifdef RTC_VALID
        } else if (k == 2) { continue;
#endif
        } else if (k == 2) {   // odd register writes (8-bit, CS changes, plain writes)
            unsigned v = r(0x10000); char s[32]; snprintf(s, 32, "write %04x", v); note(s); wr(v, r(2) ? 1 : 3);
        } else {               // a command
            unsigned reg = r(8), rd = r(3) != 0;
            unsigned cmd = r(2) ? (rd << 7 | reg << 4 | 6) : (6 << 4 | (reg & 1) << 3 | (reg >> 1 & 1) << 2 | (reg >> 2 & 1) << 1 | rd);
#ifdef RTC_VALID
            if (!rd && (reg == 2 || reg == 6)) continue;    // the date and time written only as the "init" case
#else
            if (r(10) == 0) cmd = r(256);
#endif
            { char b[64]; snprintf(b, 64, "cmd %02x", cmd); note(b); }
            wr(CS0 | SCK1); wr(CS1 | SCK1);
            sendb(cmd);
            int n = 1 + r(8);
            for (int i = 0; i < n; i++) {
                if (rd && (r(12) != 0 || (RTC24 && (reg == 2 || reg == 6)))) { note("recv"); recvb(); }
                else if (reg == 0 && !rd && r(3) == 0) { unsigned b = r(16) | RTC24; char s[32]; snprintf(s, 32, "send %02x", b); note(s); sendb(b); }
                else { unsigned b = rbyte() | (reg == 0 ? RTC24 : 0u); char s[32]; snprintf(s, 32, "send %02x", b); note(s); sendb(b); }
            }
            wr(CS0 | SCK1);
        }
    }
    printf("%s: %llu ops, %llu cycles, %llu mismatching cycles (seed %llu, gap %d)\n",
           bad ? "FAIL" : "PASS", ops, cyc, bad, seed, gap);
    delete t;
    return bad ? 1 : 0;
}
