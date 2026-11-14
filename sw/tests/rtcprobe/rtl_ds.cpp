// The rtcprobe's date/time rows (kinds 10-16) run against nds_rtc's RTL and compared with the DS's own run
// (tools/hwref/results/ds-20261112-math-rtc/rtcprobe_v1.csv; docs/hw-reference.md "DS mathprobe v1 and rtcprobe
// v1"). One RTC tick per simulation clock (SEC_TICKS 32728). Prints each row and MATCH/DIFF; exit 0 if all 7 match.
#include "Vnds_rtc.h"
#include "verilated.h"
#include <cstdio>
extern "C" {
#define RTC_PROBE_HOST
#include "probe.h"
}
static Vnds_rtc *top;
static u32 cycles;
static void step() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); cycles++; }
extern "C" u32 rtc_now(void) { step(); return cycles; }
extern "C" u32 rtc_port_read(u32 offset, u32 width) {
    top->io_req = 1; top->io_we = 0; top->io_be = 15; step();
    u32 value = top->io_rdata; top->io_req = 0;
    for (int i = 0; i < 3; i++) step();
    return width == 1 ? (value >> (8 * offset)) & 255 : width == 2 ? value & 65535 : value;
}
extern "C" void rtc_port_write(u32 offset, u32 width, u32 value) {
    top->io_req = 1; top->io_we = 1; top->io_be = ((1u << width) - 1) << offset;
    top->io_wdata = value << (8 * offset); step(); top->io_req = 0; top->io_we = 0;
    for (int i = 0; i < 3; i++) step();
}
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv); top = new Vnds_rtc;
    top->tick = 1; top->rst = 1; for (int i = 0; i < 4; i++) step();
    top->rst = 0; for (int i = 0; i < 24; i++) step();
    rtc_log l; rtc_probe(&l, 1);
    static const u32 ds[7][3] = {   // kind, a, b: the DS (rtcprobe_v1.csv)
        {0x10, 0x01010523, 0x00600000}, {0x11, 0x03010100, 0x00090753}, {0x12, 0x03010100, 0x00090741},
        {0x13, 0x03010100, 0x00001047}, {0x14, 0x03010100, 0x00001059}, {0x15, 0x03010100, 0x00000040},
        {0x16, 0x03010100, 0x00000000}};
    int match = 0;
    for (int i = 0; i < 7; i++) {
        const rtc_observation &r = l.rows[6 + i];
        bool ok = r.kind == ds[i][0] && r.a == ds[i][1] && r.b == ds[i][2];
        match += ok;
        std::printf("row %02x: rtl %08x %08x  ds %08x %08x  %s\n", ds[i][0], r.a, r.b, ds[i][1], ds[i][2], ok ? "MATCH" : "DIFF");
    }
    std::printf("RTCDS %d of 7 date/time rows match the DS (outcome %u, %u rows, %u cycles)\n", match, l.outcome, l.count, cycles);
    delete top;
    return match == 7 ? 0 : 1;
}
