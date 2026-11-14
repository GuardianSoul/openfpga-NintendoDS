// nds_rtc (new: DS date/time sanitizing) against nds_rtc_old (e1d56be09) on valid 24-hour traffic: random date+time
// and time writes with valid BCD (days within the month), every register read, status 1 writes keeping 24-hour
// mode, seconds counting (SEC 3000 clocks) through minute/hour/day/month/year carries. io_rdata compared every clock.
#include "Vtb_rtc_lock.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
static Vtb_rtc_lock *t; static unsigned long long n = 0, diffs = 0;
static void step() {
    t->clk = 0; t->eval(); t->clk = 1; t->eval(); n++;
    if (t->a_rdata != t->b_rdata && ++diffs <= 5) printf("DIFF clock %llu: old %08x new %08x\n", n, t->a_rdata, t->b_rdata);
}
static void w(unsigned v) { t->io_req = 1; t->io_we = 1; t->io_be = 1; t->io_wdata = v; step(); t->io_req = 0; t->io_we = 0; for (int i = 0; i < 3; i++) step(); }
static unsigned r() { t->io_req = 1; t->io_we = 0; t->io_be = 15; step(); unsigned v = t->a_rdata; t->io_req = 0; for (int i = 0; i < 3; i++) step(); return v; }
enum { CS = 4, SCK = 2, SO = 16 };
static void begin() { w(SCK); w(CS | SCK); }
static void end() { w(SCK); }
static void send(unsigned b) { for (int i = 0; i < 8; i++) { unsigned d = (b >> i) & 1; w(CS | SO | d); w(CS | SCK | SO | d); } }
static unsigned recv() { unsigned b = 0; for (int i = 0; i < 8; i++) { w(CS); b |= (r() & 1) << i; w(CS | SCK); } return b; }
static unsigned bcd(unsigned v) { return ((v / 10) << 4) | (v % 10); }
static unsigned rnd(unsigned k) { return (unsigned)(rand() % k); }
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv); t = new Vtb_rtc_lock;
    unsigned seed = argc > 1 ? atoi(argv[1]) : 1, ops = argc > 2 ? atoi(argv[2]) : 3000; srand(seed);
    t->tick = 1; t->rst = 1; for (int i = 0; i < 4; i++) step(); t->rst = 0; for (int i = 0; i < 24; i++) step();
    static const int dim[13] = {0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    unsigned writes = 0, reads = 0;
    for (unsigned o = 0; o < ops; o++) {
        switch (rnd(8)) {
        case 0: case 1: {   // date + time, valid (often near a carry: 23:59:5x, the month's last day)
            unsigned y = rnd(100), m = 1 + rnd(12), lp = (y % 4) == 0, dm = dim[m] + (m == 2 && lp);
            unsigned d = rnd(3) ? dm - rnd(2) : 1 + rnd(dm), hh = rnd(2) ? 23 : rnd(24), mi = rnd(2) ? 59 : rnd(60), se = rnd(2) ? 55 + rnd(5) : rnd(60);
            begin(); send(0x26); for (unsigned b : {bcd(y), bcd(m), bcd(d), rnd(7), bcd(hh), bcd(mi), bcd(se)}) send(b); end(); writes++; break; }
        case 2: { begin(); send(0x66); for (unsigned b : {bcd(rnd(24)), bcd(rnd(60)), bcd(rnd(60))}) send(b); end(); writes++; break; }
        case 3: { begin(); send(0x06); send(0x02 | (rnd(4) << 2)); end(); break; }   // status 1: 24-hour, bits 3:2 random
        default: { static const unsigned rc[] = {0xA6, 0xE6, 0x86, 0xC6, 0x96, 0xD6, 0xB6, 0xF6};
            unsigned c = rc[rnd(8)]; begin(); send(c); for (int i = 0; i < 7; i++) recv(); end(); reads++;
            for (unsigned k = rnd(4000); k; k--) step();   // seconds count on
            break; }
        }
    }
    printf("RTCLOCK seed %u: %llu clocks, %u writes, %u reads, %llu differ\n", seed, n, writes, reads, diffs);
    printf(diffs == 0 ? "PASS\n" : "FAIL\n");
    return diffs != 0;
}
