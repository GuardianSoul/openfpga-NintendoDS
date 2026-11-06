// The DS WiFi block (ARM7 0x04800000+) for tb_ds --wifi: nds_top's wx_* bus
// (WIFI_EXT = 1). Written to behave as melonDS's Wifi.cpp does (register
// storage and masks, W_ID, the baseband and RF serial ports, interrupt flags,
// power-up with IRQ11, the microsecond counter with compare/beacon IRQ14/15
// and IRQ13), without frames: transmit and receive are logged, not modelled
// (docs/compat.md, "WiFi"). Used to find what games need before the RTL port.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>

struct WifiModel {
    uint16_t io[0x800];         // 0x000-0xFFF
    uint16_t ram[0x1000];       // 0x4000-0x5FFF
    uint8_t  bb[0x100], bb_ro[0x100];
    uint32_t rf[0x20];
    uint64_t us_count = 0, us_compare = 0;
    int64_t  until_on = 0;      // < 0: microseconds until the transceiver is on
    bool     enabled = false, power_on = false, block_beacon14 = false;
    uint16_t random = 1;
    uint32_t cmd_counter = 0;
    double   us_acc = 0;
    bool     irq_pulse = false;
    bool     log = false;
    unsigned long long tx_fires = 0, rx_starts = 0;

    uint16_t &R(uint32_t a) { return io[(a & 0xFFF) >> 1]; }

    void reset(uint8_t console_type) {
        memset(io, 0, sizeof io); memset(ram, 0, sizeof ram);
        memset(bb, 0, sizeof bb); memset(bb_ro, 0, sizeof bb_ro); memset(rf, 0, sizeof rf);
        auto fixed = [&](int i, uint8_t v) { bb[i] = v; bb_ro[i] = 1; };
        fixed(0x00, 0x6D);
        for (int i : {0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x27, 0x4D, 0x5E, 0x5F,
                      0x60, 0x61, 0x66}) fixed(i, 0x00);
        fixed(0x5D, 0x01); fixed(0x64, 0xFF);
        for (int i = 0x69; i < 0x100; i++) fixed(i, 0x00);
        // W_ID: DS 0x1440, DS Lite 0xC340 (firmware header byte 0x1D)
        R(0x000) = (console_type == 0x20 || console_type == 0x43) ? 0xC340 : 0x1440;
        for (int a = 0x018; a < 0x01E; a += 2) R(a) = 0xFFFF;
        for (int a = 0x020; a < 0x026; a += 2) R(a) = 0xFFFF;
        R(0x036) = 0x0001;
        us_count = us_compare = 0; until_on = 0; enabled = power_on = block_beacon14 = false;
        random = 1; cmd_counter = 0;
    }

    void set_irq(int n) {
        uint16_t old = R(0x010) & R(0x012);
        R(0x010) |= 1u << n;
        if (!old && (R(0x010) & R(0x012))) irq_pulse = true;
    }
    void set_status(int s) {
        static const uint16_t pins[10] = {0x04, 0x84, 0, 0x46, 0, 0x84, 0x87, 0, 0x46, 0x04};
        R(0x214) = s; R(0x19C) = pins[s];
    }
    void update_power_on() {
        bool on = enabled && !(R(0x036) & 1);
        if (on == power_on) return;
        power_on = on;
        if (log) printf("wifi: %s\n", on ? "ON" : "OFF");
    }
    void update_power_status(int power) {
        int cur = 0;
        if (R(0x034) == 1) cur |= 1;
        if (!(R(0x03C) & 0x200)) cur |= 2;
        int req = cur;
        if (R(0x040) & 0x8000) req = (R(0x040) & 1) ? 0 : 3;
        else if (!(R(0x004) & 1)) req = 0;
        else {
            if (power == 0) {
                if ((R(0x03C) & 0x0202) == 0x0202) power = 1;
                else if ((R(0x03C) & 0x0201) == 0x0001) power = -1;
            }
            if (power == -1 && (R(0x048) & 1)) power = 0;
            if (power == 1) req = 3;
            else if (power == -1) req = R(0x048) ? 3 : 0;
            else if (R(0x048) & 2) req = 3;
        }
        if (req == cur) return;
        if (req & 1) { if (!(cur & 1)) { R(0x034) = 1; set_status(1); } }
        else { R(0x034) = 2; R(0x034) = 0; set_status(9); }    // (no transfer in progress)
        if (req & 2) {
            R(0x03C) |= 0x100;
            if (!(cur & 2) && until_on == 0) { until_on = -2048; set_irq(11); }
        } else {
            R(0x03C) &= ~1; R(0x03C) &= ~0x100; R(0x03C) |= 0x200; until_on = 0;
        }
    }
    void set_irq13() {
        set_irq(13);
        if ((R(0x006) & 7) == 0 && !(R(0x038) & 2)) update_power_status(-1);
    }
    void set_irq14(int source) {
        if (source != 2) R(0x11C) = R(0x08C);
        if (block_beacon14 && source == 1) return;
        if (!(R(0x0EA) & 1)) return;
        set_irq(14);
        R(0x134) = 0xFFFF;
        R(0x0B0) &= 0xFFF2;
        if (R(0x080) & 0x8000 && log) printf("wifi: beacon TX (not modelled)\n");
        if (R(0x088) == 0) R(0x088) = R(0x08E);
        R(0x088)--;
    }
    void set_irq15() { set_irq(15); if (R(0x038) & 1) update_power_status(1); }
    void ms_timer() {
        if (R(0x0EA)) { if ((us_count & ~0x3FFull) == us_compare) { block_beacon14 = false; set_irq14(0); } }
        if (R(0x11C)) { R(0x11C)--; if (!R(0x11C)) set_irq14(1); }
        if (!R(0x11C)) R(0x11C) = R(0x08C);
        if (R(0x134)) { R(0x134)--; if (!R(0x134)) set_irq13(); }
    }
    // one 8 us step, as melonDS's USTimer
    void us_timer() {
        if (until_on < 0) {
            until_on += 8;
            if (until_on >= 0) { until_on = 0; R(0x03C) = 0; set_status(1); update_power_status(0); }
        }
        if (R(0x0E8)) {
            us_count += 8;
            uint32_t uspart = us_count & 0x3FF;
            if (R(0x0EA)) {
                uint32_t beaconus = (R(0x11C) << 10) | (0x3FF - uspart);
                if ((beaconus & ~7u) == (R(0x110) & ~7u)) set_irq15();
            }
            if (!(uspart & ~7u)) ms_timer();
        }
        if (R(0x0EE) & 1) cmd_counter = cmd_counter < 8 ? 0 : cmd_counter - 8;
        if (R(0x10C)) R(0x10C) = R(0x10C) < 8 ? 0 : R(0x10C) - 8;
    }
    // called once per DS clock (clk_hz cycles per second); returns the IRQ pulse
    bool clock(double clk_hz) {
        if (power_on) {
            us_acc += 1e6 / clk_hz;
            while (us_acc >= 8) { us_acc -= 8; us_timer(); }
        }
        bool p = irq_pulse; irq_pulse = false;
        return p;
    }
    void rf_transfer() {        // RF chip type 2
        uint32_t id = (R(0x17C) >> 2) & 0x1F;
        if (R(0x17C) & 0x80) { R(0x17E) = rf[id] & 0xFFFF; R(0x17C) = (R(0x17C) & 0xFFFC) | ((rf[id] >> 16) & 3); }
        else rf[id] = R(0x17E) | ((R(0x17C) & 3) << 16);
    }

    uint16_t read16(uint32_t addr) {
        if (addr >= 0x04810000) return 0;
        addr &= 0x7FFE;
        if (addr >= 0x4000 && addr < 0x6000) return ram[(addr & 0x1FFE) >> 1];
        if (addr >= 0x2000 && addr < 0x4000) return 0xFFFF;
        bool active = addr < 0x1000;
        switch (addr) {
        case 0x044: random = (random & 1) ^ (((random & 0x3FF) << 1) | (random >> 10)); return random;
        case 0x0BC: return R(0x0BC) & 3;
        case 0x0F8: return us_count; case 0x0FA: return us_count >> 16;
        case 0x0FC: return us_count >> 32; case 0x0FE: return us_count >> 48;
        case 0x0F0: return us_compare; case 0x0F2: return us_compare >> 16;
        case 0x0F4: return us_compare >> 32; case 0x0F6: return us_compare >> 48;
        case 0x118: return (cmd_counter + 9) / 10;
        case 0x15C: return (R(0x158) & 0xF000) == 0x6000 ? bb[R(0x158) & 0xFF] : 0;
        case 0x15E: case 0x180: return 0;
        case 0x060:
            if (active) {
                uint32_t rd = R(0x058); uint16_t ret = ram[(rd & 0x1FFE) >> 1];
                rd += 2;
                if (rd == (R(0x052) & 0x1FFE)) rd = R(0x050) & 0x1FFE;
                if (rd == R(0x062)) {
                    rd += R(0x064) << 1;
                    if (rd >= (R(0x052) & 0x1FFE)) rd = rd + (R(0x050) & 0x1FFE) - (R(0x052) & 0x1FFE);
                    if (R(0x000) == 0xC340) R(0x064) = 0;
                }
                R(0x058) = rd & 0x1FFE; R(0x060) = ret;
                if (R(0x05C) > 0) { R(0x05C)--; if (!R(0x05C)) set_irq(9); }
            }
            break;
        case 0x0B6: return R(0x0B6) & 0x1F;
        case 0x1D0: case 0x1D2: case 0x1D4: case 0x1D6: case 0x1D8: case 0x1DA: case 0x1DC: case 0x1DE: {
            uint16_t v = R(addr); R(addr) = 0; return v; }
        }
        return R(addr);
    }

    void write16(uint32_t addr, uint16_t val) {
        if (addr >= 0x04810000) return;
        addr &= 0x7FFE;
        if (addr >= 0x4000 && addr < 0x6000) { ram[(addr & 0x1FFE) >> 1] = val; return; }
        if (addr >= 0x2000 && addr < 0x4000) return;
        switch (addr) {
        case 0x004: {
            uint16_t old = R(0x004); R(0x004) = val & 1;
            if (!(old & 1) && (val & 1)) { R(0x27C) = 5; update_power_status(0); }
            else if ((old & 1) && !(val & 1)) { R(0x27C) = 0xA; update_power_status(0); }
            if (val & 0x2000) { R(0x056) = 0; R(0x0C0) = 0; R(0x0C4) = 0; R(0x1A4) = 0; R(0x278) = 0xF; }
            if (val & 0x4000) {
                for (int a : {0x006, 0x008, 0x00A, 0x018, 0x01A, 0x01C, 0x020, 0x022, 0x024, 0x028, 0x02A, 0x02E,
                              0x084, 0x194, 0x198}) R(a) = 0;
                R(0x02C) = 0x0707; R(0x050) = 0x4000; R(0x052) = 0x4800; R(0x0BC) = 1; R(0x0D0) = 0x0401;
                R(0x0D4) = 1; R(0x0E0) = 8; R(0x0EC) = 0x3F03; R(0x1A2) = 1; R(0x224) = 3; R(0x230) = 0x47;
            }
            return; }
        case 0x006:
            val &= 0x7F; R(0x006) = val;
            if (R(0x038) & 2) {
                if ((val & 7) == 1) R(0x048) |= 2;
                else if ((val & 7) == 2) R(0x048) = 3;
                if ((val & 7) != 3) R(0x03C) &= 0x0300;
                update_power_status(0);
            }
            return;
        case 0x012: { uint16_t old = R(0x010) & R(0x012); R(0x012) = val;
                      if (!old && (R(0x010) & R(0x012))) irq_pulse = true; return; }
        case 0x010: R(0x010) &= ~val; return;
        case 0x21C: { uint16_t old = R(0x010) & R(0x012); R(0x010) |= val & 0xFBFF;
                      if (!old && (R(0x010) & R(0x012))) irq_pulse = true; return; }   // (melonDS: IRQ14/15 side effects omitted)
        case 0x028: R(0x028) = val & 0xF; return;
        case 0x02A: R(0x02A) = val & 0x7FF; return;
        case 0x036: R(0x036) = val & 3; update_power_on(); return;
        case 0x038:
            R(0x038) = val & 3;
            if (val & 2) {
                if ((R(0x006) & 7) == 1) R(0x048) |= 2;
                else if ((R(0x006) & 7) == 2) R(0x048) = 3;
                update_power_status(0);
            }
            return;
        case 0x03C:
            if ((R(0x006) & 7) != 3) return;
            val = (R(0x03C) & 0x300) | (val & 3);
            if ((val & 0x300) == 0x200) val &= ~1; else val &= ~2;
            if (!(val & 0x200)) val &= ~0x100;
            R(0x03C) = val; update_power_status(0); return;
        case 0x040: R(0x040) = val & 0x8001; update_power_status(0); return;
        case 0x048:
            R(0x048) = val & 3;
            if (R(0x038) & 2) {
                if ((R(0x006) & 7) == 1) R(0x048) |= 2;
                else if ((R(0x006) & 7) == 2) R(0x048) = 3;
            }
            update_power_status(0); return;
        case 0x0E8: val &= 1; break;
        case 0x0EA: if (val & 2) set_irq14(2); val &= 1; break;
        case 0x0F8: us_count = (us_count & ~0xFFFFull) | val; return;
        case 0x0FA: us_count = (us_count & ~(0xFFFFull << 16)) | ((uint64_t)val << 16); return;
        case 0x0FC: us_count = (us_count & ~(0xFFFFull << 32)) | ((uint64_t)val << 32); return;
        case 0x0FE: us_count = (us_count & ~(0xFFFFull << 48)) | ((uint64_t)val << 48); return;
        case 0x0F0: us_compare = (us_compare & ~0xFFFFull) | (val & 0xFC00); if (val & 1) block_beacon14 = true; return;
        case 0x0F2: us_compare = (us_compare & ~(0xFFFFull << 16)) | ((uint64_t)val << 16); return;
        case 0x0F4: us_compare = (us_compare & ~(0xFFFFull << 32)) | ((uint64_t)val << 32); return;
        case 0x0F6: us_compare = (us_compare & ~(0xFFFFull << 48)) | ((uint64_t)val << 48); return;
        case 0x118: cmd_counter = val * 10; return;
        case 0x158:
            R(0x158) = val;
            if ((val & 0xF000) == 0x5000 && !bb_ro[val & 0xFF]) bb[val & 0xFF] = R(0x15A) & 0xFF;
            return;
        case 0x17C: R(0x17C) = val; rf_transfer(); return;
        case 0x184: val &= 0x413F; break;
        case 0x030:
            if (val & 1) R(0x054) = R(0x056);
            if (val & 0x80) { R(0x098) = R(0x094); R(0x094) = 0; }
            if (val & 0x8000) { tx_fires++; if (log) printf("wifi: RXCNT FireTX (not modelled)\n"); }
            val &= 0xFF0E; break;
        case 0x060: if (R(0x05C) > 0) { R(0x05C)--; if (!R(0x05C)) set_irq(9); } return;
        case 0x058: case 0x062: val &= 0x1FFE; break;
        case 0x064: case 0x05C: case 0x056: case 0x05A: val &= 0x0FFF; break;
        case 0x0AC: R(0x0B0) &= ~val; return;
        case 0x0AE: R(0x0B0) |= val; tx_fires++; if (log) printf("wifi: TXREQ_SET %04x FireTX (not modelled)\n", val); return;
        case 0x0B4:
            if (val & 1) R(0x0A0) &= 0x7FFF;
            if (val & 2) R(0x090) &= 0x7FFF;
            if (val & 4) R(0x0A4) &= 0x7FFF;
            if (val & 8) R(0x0A8) &= 0x7FFF;
            if (val & 0x40) R(0x098) &= 0x7FFF;
            if (val & 0x80) R(0x094) &= 0x7FFF;
            val = 0; break;
        case 0x070: {
            uint32_t wr = R(0x068); ram[(wr & 0x1FFE) >> 1] = val; wr += 2;
            if (wr == R(0x074)) wr += R(0x076) << 1;
            R(0x068) = wr & 0x1FFE;
            if (R(0x06C) > 0) { R(0x06C)--; if (!R(0x06C)) set_irq(8); }
            return; }
        case 0x068: case 0x074: val &= 0x1FFE; break;
        case 0x076: case 0x06C: val &= 0x0FFF; break;
        case 0x080: break;
        case 0x090:
            if (cmd_counter == 0) val = (val & 0x7FFF) | (R(0x090) & 0x8000);
            // fall through
        case 0x0A0: case 0x0A4: case 0x0A8:
            R(addr) = val; tx_fires++;
            if (log && (val & 0x8000)) printf("wifi: TX slot %03x = %04x FireTX (not modelled)\n", addr, val);
            return;
        case 0x000: case 0x034: case 0x044: case 0x054: case 0x098: case 0x0B0: case 0x0B6: case 0x0B8:
        case 0x15C: case 0x15E: case 0x180: case 0x19C: case 0x1A8: case 0x1AC: case 0x1C4: case 0x210:
        case 0x214: case 0x268:
            return;
        }
        R(addr) = val;
    }

    // a bus access of nds_top's wx_* port (32-bit word with byte enables)
    uint32_t access(bool we, uint32_t addr, uint8_t be, uint32_t wdata) {
        uint32_t r = 0;
        for (int h = 0; h < 2; h++) {
            uint8_t hbe = (be >> (2 * h)) & 3;
            if (!hbe) continue;
            uint32_t a = addr + 2 * h;
            if (we) {
                uint16_t v = wdata >> (16 * h);
                if (hbe != 3) {     // byte write: melonDS ignores 8-bit writes to WiFi I/O
                    if (log) printf("wifi: byte write %08x (ignored)\n", a);
                    continue;
                }
                write16(a, v);
            } else r |= (uint32_t)read16(a) << (16 * h);
        }
        return r;
    }
};
