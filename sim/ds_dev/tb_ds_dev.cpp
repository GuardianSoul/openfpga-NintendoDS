// ARM7 SPI bus and RTC (rtl/ds/nds_spi.sv, rtl/ds/nds_rtc.sv) driven through
// their register ports the way ARM7 code does: SPI bytes polled on busy, the
// RTC's serial protocol bit-banged. Expected values come from the firmware
// image, melonDS's documented device values and the C library's calendar.
//   Vtb_ds_dev [--seed N] [--only spi,fw,tsc,rtc] [--fw firmware.bin]
#include "Vtb_ds_dev.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <ctime>
#include <random>
#include <string>
#include <vector>

typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32; typedef uint64_t u64;

static Vtb_ds_dev* top;
static std::mt19937_64 rng;
static u64 cyc = 0, tsl = 0;    // cycles; DS ticks since the RTC's init load
static long checks = 0, fails = 0;
static const char* phase = "";
static const int SEC = 1000;    // tb_ds_dev SEC_TICKS
#define CHECK(c, ...) do { checks++; if (!(c)) { if (fails++ < 40) { printf("FAIL [%s] cyc %llu: ", phase, (unsigned long long)cyc); printf(__VA_ARGS__); printf("\n"); } } } while (0)

// ---- firmware memory model: random latency, fw_addr must hold while waiting
static std::vector<u8> fw;
static bool m_pend = false, m_ackq = false;
static int m_lat = 0, lat_lo = 10, lat_hi = 300;
static u32 m_addr = 0;
static long irqs = 0, pwroffs = 0;

static u32 fw_word(u32 wa) {
    u32 a = (wa << 2) & 0x3FFFF, w = 0;
    for (int i = 0; i < 4; i++) w |= (u32)(a + i < fw.size() ? fw[a + i] : 0) << (8 * i);
    return w;
}

static void step() {
    top->fw_ack = 0;
    if (m_pend) {
        if (m_lat == 0) { top->fw_ack = 1; top->fw_rdata = fw_word(m_addr); m_pend = false; }
        else m_lat--;
    }
    top->tick = cyc & 1;
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    if (top->tick) tsl++;
    if (top->spi_irq) irqs++;
    if (top->pwr_off) pwroffs++;
    if (top->fw_req && !m_pend && !top->fw_ack) {
        m_pend = true; m_addr = top->fw_addr;
        m_lat = lat_lo + (int)(rng() % (u64)(lat_hi - lat_lo + 1));
    } else if (m_pend) {
        CHECK(top->fw_req && top->fw_addr == m_addr, "fw_req/fw_addr changed while waiting (%x -> %x)",
              m_addr, top->fw_addr);
    }
    top->fw_rdata = 0xDEADBEEF;
    cyc++;
}
static void idle(int n) { while (n--) step(); }

// one register access, then a few idle cycles as an ARM7 IO access takes
static u32 io(bool spi, bool we, u8 be, u32 wd) {
    top->spi_req = spi; top->rtc_req = !spi; top->io_we = we; top->io_be = be; top->io_wdata = wd;
    step();
    top->spi_req = 0; top->rtc_req = 0; top->io_we = 0;
    u32 r = spi ? top->spi_rdata : top->rtc_rdata;
    idle(3);
    return r;
}

// ---- SPI
static u64 last_busy;   // cycles the last transfer was busy
static u8 xfer(int dev, u8 v, bool hold, int baud = 0, bool ie = false) {
    u16 cnt = 0x8000 | (ie ? 0x4000 : 0) | (hold ? 0x0800 : 0) | (dev << 8) | baud;
    io(true, true, 0x3, cnt);
    u64 c0 = cyc;
    io(true, true, 0x4, (u32)v << 16);
    u32 r;
    int guard = 0;
    while ((r = io(true, false, 0xF, 0)) & 0x80) {
        CHECK(((r >> 16) & 0xFF) == 0, "SPIDATA reads %02x while busy", (r >> 16) & 0xFF);
        if (++guard > 100000) { CHECK(false, "SPI busy stuck"); break; }
    }
    last_busy = cyc - c0;
    return (r >> 16) & 0xFF;
}

static void test_pm() {
    phase = "pm";
    const u8 def[8] = {0, 0, 0, 0, 0x40, 0, 0, 0};
    for (int r = 0; r < 8; r++) {
        xfer(0, 0x80 | r, true);
        u8 a = xfer(0, 0, true), b = xfer(0, 0, false);
        CHECK(a == def[r] && b == def[r], "reg %d reads %02x %02x, want %02x", r, a, b, def[r]);
    }
    // writes through the masks; reg 0 bit 6 pulses pwr_off
    const u8 want[8] = {0x7F, 0x00, 0x01, 0x03, 0x4F, 0, 0, 0};
    long p0 = pwroffs;
    for (int r = 0; r < 8; r++) { xfer(0, r, true); xfer(0, 0xFF, false); }
    CHECK(pwroffs == p0 + 1, "pwr_off pulses %ld, want 1", pwroffs - p0);
    for (int r = 0; r < 8; r++) {
        xfer(0, 0x80 | r, true);
        u8 a = xfer(0, 0, false);
        CHECK(a == want[r], "reg %d after write reads %02x, want %02x", r, a, want[r]);
    }
    xfer(0, 4, true); xfer(0, 0x23, true); xfer(0, 0x05, false);   // held: both bytes write
    xfer(0, 0x84, true);
    u8 a = xfer(0, 0, false);
    CHECK(a == 0x45, "backlight after held writes %02x, want 45", a);
    u8 z = xfer(0, 0x84, false);
    CHECK(z == 0, "index byte answers %02x, want 0", z);
}

static void test_spi_bus() {
    phase = "spi";
    io(true, true, 0x3, 0xFFFF);
    u32 r = io(true, false, 0xF, 0);
    CHECK((r & 0xFFFF) == 0xCF03, "SPICNT keeps %04x, want CF03", r & 0xFFFF);
    io(true, true, 0x1, 0x00); io(true, true, 0x2, 0x0000);   // 8-bit writes are ignored
    r = io(true, false, 0xF, 0);
    CHECK((r & 0xFFFF) == 0xCF03, "8-bit SPICNT writes changed it to %04x", r & 0xFFFF);
    io(true, true, 0x3, 0x0000);
    io(true, true, 0x4, 0x550000);                            // disabled: no transfer
    r = io(true, false, 0xF, 0);
    CHECK(r == 0, "disabled bus started a transfer: %08x", r);
    // transfer time 64 << baud DS clocks, IRQ only with bit 14
    for (int b = 0; b < 4; b++) {
        long i0 = irqs;
        xfer(0, 0x80, false, b, true);
        long want = 2L * (64 << b);
        CHECK(last_busy >= (u64)want && last_busy <= (u64)want + 12, "baud %d busy %llu cycles, want %ld",
              b, (unsigned long long)last_busy, want);
        CHECK(irqs == i0 + 1, "baud %d: %ld IRQs, want 1", b, irqs - i0);
        i0 = irqs;
        xfer(0, 0x80, false, b, false);
        CHECK(irqs == i0, "IRQ without SPICNT bit 14");
    }
    // a write during busy is dropped: hold, index "write reg 2", then 1 and at once 0
    xfer(0, 0x02, true); xfer(0, 0x00, false);
    xfer(0, 0x02, true);
    io(true, true, 0x4, 0x010000);
    io(true, true, 0x4, 0x000000);
    while (io(true, false, 0xF, 0) & 0x80) {}
    io(true, true, 0x3, 0x0000);        // disabling releases the chip select
    xfer(0, 0x82, true);
    u8 a = xfer(0, 0, false);
    CHECK(a == 0x01, "write during busy reached the device (reg 2 = %02x)", a);
    // 32-bit writes: SPICNT, then SPIDATA under the new SPICNT
    io(true, true, 0xF, 0x00048800);    // power manager, hold, index "write reg 4"
    while (io(true, false, 0xF, 0) & 0x80) {}
    io(true, true, 0xF, 0x000A8000);    // write 0A, release
    while (io(true, false, 0xF, 0) & 0x80) {}
    xfer(0, 0x84, true);
    a = xfer(0, 0, false);
    CHECK(a == 0x4A, "after 32-bit writes reg 4 = %02x, want 4A", a);
}

// ---- firmware flash
static void fw_read(u32 addr, int len, bool fast, int baud = 0) {
    xfer(1, fast ? 0x0B : 0x03, true, baud);
    for (int i = 2; i >= 0; i--) {
        u8 z = xfer(1, (addr >> (8 * i)) & 0xFF, true, baud);
        CHECK(z == 0, "address byte answers %02x", z);
    }
    if (fast) { u8 z = xfer(1, 0, true, baud); CHECK(z == 0, "dummy byte answers %02x", z); }
    for (int i = 0; i < len; i++) {
        u32 a = (addr + i) & 0x3FFFF;
        u8 d = xfer(1, 0, i != len - 1, baud);
        CHECK(d == fw[a], "%s %05x+%d: %02x, want %02x", fast ? "FAST" : "READ", addr, i, d, fw[a]);
    }
}

static void test_fw() {
    phase = "fw";
    xfer(1, 0x9F, true);
    u8 a = xfer(1, 0, true), b = xfer(1, 0, true), c = xfer(1, 0, true), d = xfer(1, 0, false);
    CHECK(a == 0x20 && b == 0x40 && c == 0x12 && d == 0, "RDID %02x %02x %02x %02x", a, b, c, d);
    xfer(1, 0x05, true); a = xfer(1, 0, true); b = xfer(1, 0, false);
    CHECK(a == 0 && b == 0, "RDSR after reset %02x %02x", a, b);
    xfer(1, 0x06, false);
    xfer(1, 0x05, true); a = xfer(1, 0, false);
    CHECK(a == 0x02, "RDSR after WREN %02x", a);
    xfer(1, 0x04, false);
    xfer(1, 0x05, true); a = xfer(1, 0, false);
    CHECK(a == 0x00, "RDSR after WRDI %02x", a);
    xfer(1, 0x02, true); a = xfer(1, 0, false);
    CHECK(a == 0xFF, "unknown command answers %02x", a);
    xfer(1, 0x0A, true); xfer(1, 0, true); xfer(1, 0, true); a = xfer(1, 0, true); b = xfer(1, 0x5A, false);
    CHECK(a == 0 && b == 0x5A, "PW answers %02x %02x", a, b);
    if (fw.empty()) { printf("SKIP firmware image reads (no image)\n"); return; }
    fw_read(0x00000, 64, false);
    fw_read(0x00023, 37, false);
    fw_read(0x3FFF6, 20, false);       // wraps to 0
    fw_read(0x3FE00, 0x70, false);     // user settings
    fw_read(0x7FF00, 16, false);       // masked to 256 KiB
    fw_read(0x00101, 23, true);
    fw_read(0x00200, 8, false, 3);
    for (int k = 0; k < 20; k++) fw_read(rng() & 0x3FFFF, 1 + rng() % 40, rng() & 1, rng() & 3);
    // abandoned reads with fetches in flight (the latency outlasts the next
    // command and address), then a new address
    lat_lo = 300; lat_hi = 900;
    for (int k = 0; k < 20; k++) {
        u32 x = rng() & 0x3FFFF;
        xfer(1, 0x03, true);
        xfer(1, x >> 16, true); xfer(1, x >> 8, true); xfer(1, x, (k & 1) != 0);
        if (k & 1) {
            if (k & 2) xfer(1, 0, false);
            else { xfer(1, 0, true); io(true, true, 0x3, 0x0000); }   // released by disabling
        }
        fw_read(rng() & 0x3FFFF, 1 + rng() % 9, false);
    }
    lat_lo = 10; lat_hi = 300;
    // the queue keeps ahead: with a latency above the byte time (128 cycles at
    // 4 MHz) but below a word's (512) only bytes of the first two words, which
    // are fetched back to back, may wait
    lat_lo = 100; lat_hi = 250;
    for (int k = 0; k < 4; k++) {
        u32 x = rng() & 0x3FFFF;
        xfer(1, 0x03, true);
        for (int i = 2; i >= 0; i--) xfer(1, (x >> (8 * i)) & 0xFF, true);
        u64 worst = 0;
        for (int i = 0; i < 48; i++) {
            u8 v = xfer(1, 0, i != 47);
            CHECK(v == fw[(x + i) & 0x3FFFF], "streamed byte %d", i);
            if (i >= 4 && last_busy > worst) worst = last_busy;
        }
        CHECK(worst <= 128 + 12, "sequential byte held busy %llu cycles", (unsigned long long)worst);
    }
    lat_lo = 10; lat_hi = 300;
}

// ---- touchscreen
static int tsc_conv(u8 ctl, bool rel = true) {
    xfer(2, ctl, true);
    u8 hi = xfer(2, 0, true), lo = xfer(2, 0, !rel);
    u8 z = rel ? 0 : xfer(2, 0, false);
    CHECK(z == 0, "third result byte %02x", z);
    return (hi << 5) | (lo >> 3);
}
// Fixed cursor mapping documented by nds_spi and boot7's replacement user
// calibration. Inputs are unsigned 8-bit coordinates: raw ranges 8..4088.
static int tsc_raw(int t) { return t * 16 + 8; }

static void test_tsc() {
    phase = "tsc";
    top->pen = 0;
    CHECK(top->pen_down == 0, "pen_down without pen");
    int x = tsc_conv(0xD0), y = tsc_conv(0x90);
    CHECK(x == 0 && y == 0xFFF, "pen up X %03x Y %03x", x, y);
    struct { int tx, ty; } cs[] = {
        {0, 0}, {255, 191}, {128, 96}, {10, 180}, {200, 20}, {3, 4},
        {0, 255}, {255, 0}, {1, 254}, {254, 1}, {255, 255},
        {32, 24}, {224, 168}, // the two boot calibration points
    };
    top->pen = 1;
    for (auto& c : cs) {
        top->tx = c.tx; top->ty = c.ty;
        x = tsc_conv(0xD0, (c.tx & 1) != 0); y = tsc_conv(0x90);
        CHECK(top->pen_down == 1, "pen_down with pen");
        int wx = tsc_raw(c.tx), wy = tsc_raw(c.ty);
        CHECK(x == wx && y == wy, "cursor %d,%d: X %03x Y %03x, want %03x %03x", c.tx, c.ty, x, y, wx, wy);
        int x8 = tsc_conv(0xD8);
        CHECK(x8 == (wx & 0xFF0), "8-bit X %03x, want %03x", x8, wx & 0xFF0);
        int y8 = tsc_conv(0x98);
        CHECK(y8 == (wy & 0xFF0), "8-bit Y %03x, want %03x", y8, wy & 0xFF0);
    }
    // libnds overlap: the next control byte goes out with the low byte
    top->tx = 100; top->ty = 50;
    xfer(2, 0x90, true);
    u8 h = xfer(2, 0, true), l = xfer(2, 0xD0, true);
    u8 h2 = xfer(2, 0, true), l2 = xfer(2, 0, false);
    y = (h << 5) | (l >> 3); x = (h2 << 5) | (l2 >> 3);
    CHECK(x == 1608 && y == 808, "overlapped X %d Y %d, want 1608 808", x, y);
    int t = tsc_conv(0xA0), m = tsc_conv(0xE0);
    CHECK(t == 0xFFF && m == 0x800, "channel 2 %03x, mic %03x", t, m);
    top->pen = 0;
}

// ---- RTC
enum { CS0 = 0x40, CS1 = 0x44, SCK0 = 0x20, SCK1 = 0x22, SO = 0x10 };
static void rtc_w(u16 v) { io(false, true, 0x3, v); }
static void rtc_begin() { rtc_w(CS0 | SCK1); rtc_w(CS1 | SCK1); }
static void rtc_end() { rtc_w(CS0 | SCK1); }
static void rtc_send(u8 b) {
    for (int i = 0; i < 8; i++) {
        int d = (b >> i) & 1;
        rtc_w(CS1 | SCK0 | SO | d); rtc_w(CS1 | SCK1 | SO | d);
    }
}
static u8 rtc_recv() {
    u8 b = 0;
    for (int i = 0; i < 8; i++) {
        rtc_w(CS1 | SCK0);
        b |= (io(false, false, 0x3, 0) & 1) << i;
        rtc_w(CS1 | SCK1);
    }
    return b;
}
static std::vector<u8> rtc_read(u8 cmd, int n) {
    std::vector<u8> v;
    rtc_begin(); rtc_send(cmd);
    for (int i = 0; i < n; i++) v.push_back(rtc_recv());
    rtc_end();
    return v;
}
static void rtc_write(u8 cmd, std::vector<u8> v) {
    rtc_begin(); rtc_send(cmd);
    for (u8 b : v) rtc_send(b);
    rtc_end();
}
static u8 bcd(int v) { return (u8)((v / 10) << 4 | (v % 10)); }

// expected date/time registers (24-hour) for a calendar time
static std::vector<u8> dt_regs(time_t t) {
    struct tm g; gmtime_r(&t, &g);
    int h = g.tm_hour;
    return {bcd(g.tm_year % 100), bcd(g.tm_mon + 1), bcd(g.tm_mday), (u8)g.tm_wday,
            (u8)(bcd(h) | (h >= 12 ? 0x40 : 0)), bcd(g.tm_min), bcd(g.tm_sec)};
}
static time_t mk(int y, int mo, int d, int h, int mi, int s) {
    struct tm g = {}; g.tm_year = y - 1900; g.tm_mon = mo - 1; g.tm_mday = d;
    g.tm_hour = h; g.tm_min = mi; g.tm_sec = s;
    return timegm(&g);
}
static std::string hex(const std::vector<u8>& v) {
    std::string s; char b[4];
    for (u8 x : v) { snprintf(b, sizeof b, "%02x ", x); s += b; }
    return s;
}
static void at_phase(int p) { while ((int)(tsl % SEC) != p) step(); }
static void at_sec(u64 s) { while (tsl / SEC < s || tsl % SEC < 30) step(); }   // early in second s
// write a date/time (24-hour mode) at the start of a second, return the second count then
static u64 rtc_set(time_t t) {
    at_phase(20);
    rtc_write(0x26, dt_regs(t));
    return tsl / SEC;
}
static void rtc_expect(time_t t0, u64 s0, const char* what) {
    at_phase(30);
    time_t t = t0 + (time_t)(tsl / SEC - s0);
    auto got = rtc_read(0xA6, 7), want = dt_regs(t);
    CHECK(got == want, "%s: %s, want %s", what, hex(got).c_str(), hex(want).c_str());
}

static void test_rtc() {
    phase = "rtc";
    u8 s1 = rtc_read(0x86, 1)[0];
    CHECK(s1 == 0x82, "status 1 after reset %02x, want 82", s1);
    s1 = rtc_read(0x61, 1)[0];   // the reversed command form
    CHECK(s1 == 0x02, "status 1 after reading it %02x, want 02", s1);
    auto v = rtc_read(0xA6, 4);
    CHECK(v == std::vector<u8>({0, 1, 1, 0}), "date before init %s", hex(v).c_str());

    // set (as the boot program does since the bridge load went, 2026-10-28), then counting
    time_t t0 = mk(2026, 10, 23, 14, 5, 30);
    u64 i0 = rtc_set(t0);
    rtc_expect(t0, i0, "after init");
    v = rtc_read(0x65, 7);       // reversed form of A6
    CHECK(v == dt_regs(t0 + (tsl / SEC - i0)), "reversed command: %s", hex(v).c_str());
    idle(2 * SEC * 3);
    rtc_expect(t0, i0, "init + 3 s");
    v = rtc_read(0xE6, 3);
    auto w = dt_regs(t0 + (tsl / SEC - i0));
    CHECK(v == std::vector<u8>(w.begin() + 4, w.end()), "time read %s", hex(v).c_str());

    // date writes and reads, many dates (the day of week the test computes; the boot program has its own)
    for (int k = 0; k < 150; k++) {
        time_t t = mk(2000, 1, 1, 0, 0, 0) + (time_t)(rng() % (100ULL * 36525 / 100 * 86400));
        t -= t % 60;   // whole minutes: no carry while reading
        rtc_set(t);
        v = rtc_read(0xA6, 4);
        w = dt_regs(t);
        CHECK(std::vector<u8>(w.begin(), w.begin() + 4) == v, "init %s: %s", hex(w).c_str(), hex(v).c_str());
    }

    // write + rollover across minute, day, month, year, leap day
    struct { int y, mo, d, h, mi, s, wait; } ro[] = {
        {2023, 12, 31, 23, 59, 58, 3}, {2024, 2, 28, 23, 59, 59, 2}, {2023, 2, 28, 23, 59, 59, 2},
        {2024, 4, 30, 23, 59, 59, 1}, {2025, 11, 30, 23, 59, 58, 2}, {2000, 2, 28, 23, 59, 59, 2},
        {2031, 7, 31, 11, 59, 59, 1}, {2048, 2, 29, 23, 59, 59, 1}, {2010, 9, 30, 23, 59, 59, 1},
    };
    for (auto& r : ro) {
        time_t t = mk(r.y, r.mo, r.d, r.h, r.mi, r.s);
        u64 s0 = rtc_set(t);
        rtc_expect(t, s0, "written");
        idle(2 * SEC * r.wait);
        rtc_expect(t, s0, "rolled over");
    }
    // a second that ends during a read is counted after it: one consistent time
    for (int k = 0; k < 3; k++) {
        time_t t = mk(2023 + k, 12, 31, 23, 59, 59);
        u64 s0 = rtc_set(t);
        at_phase(SEC - 120 - 60 * k);
        CHECK(tsl / SEC == s0, "late read setup");
        v = rtc_read(0xA6, 7);
        CHECK(tsl / SEC == s0 + 1, "read did not cross the second");
        CHECK(v == dt_regs(t), "read across a second: %s, want %s", hex(v).c_str(), hex(dt_regs(t)).c_str());
        rtc_expect(t, s0, "after the late read");
    }
    // 2099 -> 2000: the day of week keeps counting
    {
        u64 s0 = rtc_set(mk(2099, 12, 31, 23, 59, 59));
        at_sec(s0 + 1);
        v = rtc_read(0xA6, 7);
        CHECK(v == std::vector<u8>({0x00, 0x01, 0x01, 5, 0, 0, 0}), "2099 rollover %s", hex(v).c_str());
    }
    // range checks as melonDS's WriteDateTime
    at_phase(20);
    rtc_write(0x26, {0x23, 0x04, 0x31, 0x09, 0x25, 0x5A, 0x60});
    v = rtc_read(0xA6, 7);
    CHECK(v == std::vector<u8>({0x23, 0x05, 0x01, 0x01, 0x00, 0x00, 0x00}), "sanitised %s", hex(v).c_str());
    at_phase(20);
    rtc_write(0x26, {0xA0, 0x13, 0x00, 0x03, 0x13, 0x07, 0x09});
    v = rtc_read(0xA6, 7);
    CHECK(v == std::vector<u8>({0x00, 0x01, 0x01, 0x03, 0x53, 0x07, 0x09}), "sanitised 2 %s", hex(v).c_str());
    at_phase(20);
    rtc_write(0x66, {0x08, 0x30, 0x15});   // time only
    v = rtc_read(0xA6, 7);
    CHECK(v == std::vector<u8>({0x00, 0x01, 0x01, 0x03, 0x08, 0x30, 0x15}), "time write %s", hex(v).c_str());

    // 12-hour mode
    at_phase(20);
    rtc_write(0x26, {0x24, 0x03, 0x15, 0x05, 0x14, 0x05, 0x00});
    rtc_write(0x06, {0x00});
    v = rtc_read(0x86, 1);
    CHECK(v[0] == 0x00, "status 1 in 12-hour mode %02x", v[0]);
    v = rtc_read(0xE6, 1);
    CHECK(v[0] == 0x42, "14h in 12-hour mode %02x, want 42", v[0]);
    at_phase(20);
    rtc_write(0x26, {0x24, 0x03, 0x15, 0x05, 0x51, 0x59, 0x59});   // 11:59:59 PM
    at_sec(tsl / SEC + 1);
    v = rtc_read(0xA6, 7);
    CHECK(v == std::vector<u8>({0x24, 0x03, 0x16, 0x06, 0x00, 0x00, 0x00}), "12h midnight %s", hex(v).c_str());
    at_phase(20);
    rtc_write(0x66, {0x11, 0x59, 0x59});                           // 11:59:59 AM
    at_sec(tsl / SEC + 1);
    v = rtc_read(0xE6, 3);
    CHECK(v == std::vector<u8>({0x40, 0x00, 0x00}), "12h noon %s", hex(v).c_str());
    rtc_write(0x66, {0x47, 0x10, 0x00});                           // 7:10 PM
    rtc_write(0x06, {0x02});                                       // back to 24-hour
    v = rtc_read(0xE6, 1);
    CHECK(v[0] == 0x59, "7 PM in 24-hour mode %02x, want 59", v[0]);

    // status 2, alarms, clock adjust, free register
    rtc_write(0x46, {0x00});
    rtc_write(0x16, {0x81, 0x92, 0xA3});        // status 2 bit 2 clear: one byte, INT1 register 3
    v = rtc_read(0x96, 3);
    CHECK(v == std::vector<u8>({0x81, 0, 0}), "INT1 one-byte %s", hex(v).c_str());
    rtc_write(0x46, {0x44});
    v = rtc_read(0xC6, 1);
    CHECK(v[0] == 0x44, "status 2 %02x", v[0]);
    rtc_write(0x16, {0x11, 0x22, 0x33});
    v = rtc_read(0x96, 4);
    CHECK(v == std::vector<u8>({0x11, 0x22, 0x33, 0}), "INT1 %s", hex(v).c_str());
    rtc_write(0x56, {0x44, 0x55, 0x66, 0x77});
    v = rtc_read(0xD6, 3);
    CHECK(v == std::vector<u8>({0x44, 0x55, 0x66}), "INT2 %s", hex(v).c_str());
    rtc_write(0x36, {0x5C});
    rtc_write(0x76, {0xC5});
    v = rtc_read(0xB6, 2); w = rtc_read(0xF6, 1);
    CHECK(v == std::vector<u8>({0x5C, 0}) && w[0] == 0xC5, "adjust %s free %s", hex(v).c_str(), hex(w).c_str());
    v = rtc_read(0x0F, 2);
    CHECK(v == std::vector<u8>({0, 0}), "unknown command reads %s", hex(v).c_str());
    // register: 8-bit writes keep the high byte; read gives what was written
    io(false, true, 0x3, 0x1234 & ~0x04);
    io(false, true, 0x1, 0x50);
    u32 r = io(false, false, 0x3, 0);
    CHECK((r & 0xFFFF) == 0x1250, "RTC register %04x, want 1250", r & 0xFFFF);
    io(false, true, 0x2, 0xAB00);
    r = io(false, false, 0x3, 0);
    CHECK((r & 0xFFFF) == 0x1250, "8-bit write to 0x139 changed it to %04x", r & 0xFFFF);
    rtc_end();
    // status 1 reset bit
    rtc_write(0x06, {0x03});
    v = rtc_read(0xA6, 7); w = rtc_read(0xC6, 1);
    auto f = rtc_read(0xF6, 1); auto s = rtc_read(0x86, 1);
    CHECK(v[0] == 0 && v[1] == 1 && v[2] == 1 && v[3] == 0 && v[4] == 0 && v[5] == 0 && w[0] == 0 && f[0] == 0 && s[0] == 0x02,
          "after reset command %s / %02x %02x %02x", hex(v).c_str(), w[0], f[0], s[0]);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    u64 seed = 1; std::string only, fwpath = std::string(getenv("HOME") ? getenv("HOME") : "") + "/Git/NDS_Pocket/roms/firmware.bin";
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--seed" && i + 1 < argc) seed = strtoull(argv[++i], nullptr, 0);
        else if (a == "--only" && i + 1 < argc) only = argv[++i];
        else if (a == "--fw" && i + 1 < argc) fwpath = argv[++i];
    }
    rng.seed(seed);
    if (FILE* f = fopen(fwpath.c_str(), "rb")) {
        fw.resize(0x40000);
        size_t n = fread(fw.data(), 1, fw.size(), f);
        fclose(f);
        if (n != 0x40000) { printf("firmware image %s: %zu bytes, want 262144\n", fwpath.c_str(), n); fw.clear(); }
    }
    top = new Vtb_ds_dev;
    top->rst = 1; idle(4); top->rst = 0; idle(2);
    phase = "reset";
    u32 r0 = io(true, false, 0xF, 0), r1 = io(false, false, 0x3, 0);
    CHECK(r0 == 0 && r1 == 0, "after reset SPI %08x RTC %08x", r0, r1);
    auto want = [&](const char* t) { return only.empty() || only.find(t) != std::string::npos; };
    if (want("spi")) { test_pm(); test_spi_bus(); }
    if (want("fw"))  test_fw();
    if (want("tsc")) test_tsc();
    if (want("rtc")) test_rtc();
    printf("%s: %ld checks, %ld failures (seed %llu, %llu cycles)\n", fails ? "FAIL" : "PASS",
           checks, fails, (unsigned long long)seed, (unsigned long long)cyc);
    delete top;
    return fails ? 1 : 0;
}
