// nds_wifi against the C++ model (wifi_model.h, melonDS's behaviour), access
// by access: replays a list of ARM7 WiFi accesses (sim/ds/wifi_test.py
// extracts HG's from a tb_ds trace) and compares every read. The SDRAM behind
// wm_* is a plain array with a configurable latency.
//   tb_wifi ACCESSES [--lat N] [--quiet]
// ACCESSES: lines "R|W ADDR BE WDATA [GAP]" (hex; GAP = idle clocks before it)
#include "Vnds_wifi.h"
#include "verilated.h"
#include "wifi_model.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>

int main(int argc, char** argv)
{
    if (argc < 2) { fprintf(stderr, "usage: tb_wifi ACCESSES [--lat N] [--quiet]\n"); return 2; }
    int lat = 6; bool quiet = false, dump = false;
    for (int i = 2; i < argc; i++)
    {
        if (!strcmp(argv[i], "--lat") && i + 1 < argc) lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--quiet")) quiet = true;
        else if (!strcmp(argv[i], "--dump")) dump = true;
    }
    struct Acc { bool we; uint32_t a; uint8_t be; uint32_t d; int gap; };
    std::vector<Acc> acc;
    FILE* f = fopen(argv[1], "r");
    if (!f) { perror(argv[1]); return 2; }
    char rw[4]; unsigned a, be, d; int gap;
    char line[256];
    while (fgets(line, sizeof line, f))
    {
        gap = 0;
        if (sscanf(line, "%3s %x %x %x %d", rw, &a, &be, &d, &gap) >= 4) acc.push_back({rw[0] == 'W', a, (uint8_t)be, d, gap});
    }
    fclose(f);

    Verilated::commandArgs(argc, argv);
    Vnds_wifi* t = new Vnds_wifi;
    std::vector<uint32_t> mem(1 << 19, 0x5A5A5A5A);   // 2 MiB VRAM-port space, garbage until the block clears it
    WifiModel m; m.reset(0x20);
    uint64_t cyc = 0;
    auto clock = [&]() {
        t->clk = 1; t->eval(); t->clk = 0; t->eval(); cyc++;
    };
    t->clk = 0; t->rst = 1; t->power = 0; t->id_lite = 1; t->wf_req = 0; t->wm_ack = 0; t->tick = 0;
    for (int i = 0; i < 10; i++) clock();
    t->rst = 0;
    // memory: answer each request after lat clocks
    int mcnt = -1;
    bool power = false;
    auto step = [&]() {
        t->tick = !t->tick;
        t->wm_ack = 0;
        if (t->wm_req && mcnt < 0) mcnt = lat;
        else if (mcnt > 0) mcnt--;
        else if (mcnt == 0)
        {
            uint32_t w = t->wm_addr;
            if (t->wm_we) { for (int b = 0; b < 4; b++) if (t->wm_be >> b & 1) mem[w] = (mem[w] & ~(0xFFu << 8 * b)) | (t->wm_wdata & (0xFFu << 8 * b)); }
            else t->wm_rdata = mem[w];
            t->wm_ack = 1; mcnt = -1;
        }
        t->power = power;
        if (power != m.enabled) { m.enabled = power; m.update_power_on(); }
        m.clock(33513982.0 * 2);
        clock();
    };
    // the block clears its memory after reset
    for (int i = 0; i < 60000; i++) step();
    power = true;                       // POWCNT2 bit 1, as games set before using WiFi
    unsigned long long reads = 0, bad = 0, timing = 0;
    for (auto& x : acc)
    {
        for (int g = 0; g < x.gap; g++) step();
        uint32_t exp = m.access(x.we, x.a & ~3u, x.be, x.d);   // the bus carries word addresses
        t->wf_req = 1; t->wf_we = x.we; t->wf_be = x.be; t->wf_addr = (x.a >> 2) & 0x3FFFFF; t->wf_wdata = x.d;
        step();
        t->wf_req = 0;
        int n = 0;
        while (!t->wf_ack && n < 100000) { step(); n++; }
        if (n >= 100000) { printf("TIMEOUT at %08x\n", x.a); return 1; }
        if (!x.we)
        {
            reads++;
            uint32_t got = t->wf_rdata;
            if (dump) printf("R %08x %08x\n", x.a, got);
            if (got != exp)
            {
                uint32_t r = x.a & 0x7FFE;
                bool tm = (r >= 0xF0 && r <= 0xFE) || r == 0x10 || r == 0x118 || r == 0x11C || r == 0x134 || r == 0x10C;
                if (tm) timing++; else bad++;
                if (!quiet && (bad + timing) <= 40)
                    printf("%s R %08x be %x rtl %08x model %08x\n", tm ? "(timing)" : "MISMATCH", x.a, x.be, got, exp);
            }
        }
        step();
    }
    printf("tb_wifi: %zu accesses, %llu reads, %llu mismatches, %llu timing-dependent differences\n", acc.size(), reads, bad, timing);
    delete t;
    return bad ? 1 : 0;
}
