// Bounded ARM7-only peripheral probes. No sound/WiFi/touch servers; SD
// services are idle during a command. No firmware or cartridge writes:
// SPI/AUX send RDSR (05), never WREN, program, erase or status-write.
#include <calico.h>
#include <calico/dev/mwl/regs.h>
#include "perftime.h"

#define R16(a) (*(volatile u16*)(a))
#define R32(a) (*(volatile u32*)(a))
#define R8(a) (*(volatile u8*)(a))
static PerfResult out __attribute__((aligned(32), section(".main.d")));
static u32 wave[128] __attribute__((aligned(32), section(".main.d")));
static u32 silent[8] __attribute__((aligned(32), section(".main.d")));

static u32 now(void)
{
    u16 h = R16(0x04000104), l = R16(0x04000100), h2 = R16(0x04000104);
    if (h != h2) { l = R16(0x04000100); h = h2; }
    return ((u32)h << 16) | l;
}
static void row(u32 kind, u32 arg, u32 rep, u32 ticks, u32 before, u32 after, u32 timeout)
{
    if (out.n < PERF_ROWS) out.row[out.n++] = (PerfRow){kind,arg,rep,ticks,before,after,timeout};
    else out.status |= 1;
}
static bool idle(volatile u16* cnt, u16 mask)
{
    u32 t = now();
    while (*cnt & mask) if (now() - t > PERF_LIMIT) return false;
    return true;
}
static void serial(bool aux)
{
    volatile u16* cnt = (volatile u16*)(aux ? 0x040001a0 : 0x040001c0);
    volatile u16* data = cnt + 1;
    u16 saved = *cnt;
    if (!idle(cnt, 0x80)) { out.status |= 2; return; }
    for (u32 baud = 0; baud < 4; baud++) for (u32 rep = 0; rep < 16; rep++) {
        // 0x100 = NVRAM device, 0x2000 = AUX SPI mode; IRQ stays disabled.
        u16 base = 0x8000 | (aux ? 0x2000 : 0x100) | baud;
        for (u32 byte = 0; byte < 2; byte++) {
            *cnt = base | (byte == 0 ? (aux ? 0x40 : 0x800) : 0);
            u32 t = now();
            *data = byte == 0 ? 5 : 0;
            bool ok = idle(cnt, 0x80);
            u32 elapsed = now() - t;
            row(aux ? PERF_AUX : PERF_SPI, baud | (byte << 8), rep, elapsed, 0, *data, !ok);
            if (!ok) { *cnt = 0; out.status |= 2; return; }
        }
        *cnt = 0;
    }
    *cnt = saved;
}
static void wifi(void)
{
    u16 power = R16(0x04000304);
    R16(0x04000304) = power | 2;
    u16 power_us = MWL_REG(W_POWER_US), cnt = MWL_REG(W_US_COUNTCNT);
    // No RF writes or transmit requests. This tests the powered counter
    // path only, not radio startup or link timing.
    MWL_REG(W_POWER_US) = 0;
    MWL_REG(W_US_COUNTCNT) = 1;
    for (u32 rep = 0; rep < 32; rep++) {
        u32 t = now();
        u16 id = MWL_REG(W_ID);
        u32 elapsed = now() - t;
        row(PERF_WIFI, W_ID, rep, elapsed, id, id, 0);
        u16 before = MWL_REG(W_US_COUNT0);
        t = now();
        while (now() - t < 8192) {}
        u16 after = MWL_REG(W_US_COUNT0);
        elapsed = now() - t;
        row(PERF_WIFI, W_US_COUNT0, rep, elapsed, before, after, 0);
        // Read-only BB register 0: no RF configuration is assumed.
        if (!idle((volatile u16*)(0x04808000 + W_BB_BUSY), 1)) { out.status |= 4; break; }
        t = now();
        MWL_REG(W_BB_CNT) = 0x6000;
        bool ok = idle((volatile u16*)(0x04808000 + W_BB_BUSY), 1);
        elapsed = now() - t;
        row(PERF_WIFI, W_BB_CNT, rep, elapsed, 0, MWL_REG(W_BB_READ), !ok);
        if (!ok) { out.status |= 4; break; }
    }
    MWL_REG(W_US_COUNTCNT) = cnt;
    MWL_REG(W_POWER_US) = power_us;
    R16(0x04000304) = power;
}
static void sound(u32 arg)
{
    // arg bits: format 0 PCM8 / 1 PCM16 / 2 ADPCM; bit2 sixteen channels;
    // bit3 fast timer 16 vs 512; bit4 all sixteen ADPCM, including 1/3.
    // Otherwise channels 1/3 clock capture at timer 128 as in v1.
    u32 fmt = arg & 3, channels = arg & 4 ? 16 : 4, timer = arg & 8 ? 16 : 512;
    bool all_adpcm = arg & 16;
    if (fmt > 2 || (arg & ~31u) || (all_adpcm && (fmt != 2 || channels != 16))) {
        out.status |= 8; return;
    }
    u32 start_before[16], start_after[16], written[16], readback[16];
    for (u32 i = 0; i < 128; i++) wave[i] = (i & 1) ? 0x12345678 : 0x87654321;
    wave[0] = 0; // legal ADPCM predictor/index header; also fixed PCM prefix
    u16 power = R16(0x04000304);
    R16(0x04000304) = power | 1;
    if(!(power&1)){
        // Published analogue power-settle interval, outside the measured
        // enable/capture protocol; every channel remains stopped here.
        for(int c=0;c<16;c++)R32(0x04000400+c*16)=0;
        u32 settle=now();while(now()-settle<502710u){}
    }
    R16(0x04000500) = 0x807f;
    for (int c = 0; c < 16; c++) R32(0x04000400 + c*16) = 0;
    R16(0x04000508) = 0;
    for (int u = 0; u < 2; u++) {
        for (int i = 0; i < PERF_SAMPLES; i++) out.capture[u][i] = 0x5a5a;
        R32(0x04000510 + u*8) = (u32)out.capture[u];
        R16(0x04000514 + u*8) = PERF_SAMPLES / 2; // length in words
    }
    for (u32 c = 0; c < channels; c++) {
        bool clock = !all_adpcm && (c == 1 || c == 3);
        R32(0x04000404 + c*16) = (u32)(clock ? silent : wave);
        R16(0x04000408 + c*16) = -(clock ? 128 : timer);
        bool adpcm=!clock && fmt==2;
        // ADPCM loops restart at the data, never the four-byte header.
        R16(0x0400040a + c*16) = adpcm ? 1 : 0;
        R32(0x0400040c + c*16) = clock ? 8 : adpcm ? 127 : 128;
        written[c] = 0x80000000u | (1u<<27) |
            ((clock ? 1u : fmt)<<29) | (64u<<16) | (clock ? 0 : 8);
        start_before[c] = now();
        R32(0x04000400 + c*16) = written[c];
        readback[c] = R32(0x04000400 + c*16);
        start_after[c] = now();
    }
    u32 t = now();
    R16(0x04000508) = 0x8484; // two one-shot PCM16 mixer captures
    u32 armed = now();
    bool timeout = false;
    while (R16(0x04000508) & 0x8080) if (now() - t > PERF_LIMIT) { timeout = true; break; }
    u32 elapsed = now() - t;
    R16(0x04000508) = 0;
    for (int c = 0; c < 16; c++) R32(0x04000400 + c*16) = 0;
    R16(0x04000500) = 0;
    R16(0x04000304) = power;
    // Publish events only after stopping playback, avoiding result-buffer
    // stores between enables. Timer reads themselves are part of v2's
    // explicit start protocol, not silently comparable with v1 ordering.
    for (u32 c = 0; c < channels; c++) {
        row(PERF_SOUND_START, arg, c, start_after[c]-start_before[c],
            start_before[c], start_after[c], 0);
        row(PERF_SOUND_CONFIG, arg, c, start_after[c]-start_before[c],
            written[c], readback[c], 0);
    }
    row(PERF_SOUND_CAPTURE, arg, 0, armed-t, t, armed, 0);
    row(PERF_SOUND, arg, 0, elapsed, channels, timer, timeout);
}
int main(void)
{
    envReadNvramSettings(); keypadStartExtServer();
    lcdSetIrqMask(DISPSTAT_IE_ALL, DISPSTAT_IE_VBLANK); irqEnable(IRQ_VBLANK);
    rtcInit(); rtcSyncTime(); pmInit(); blkInit();
    R16(0x04000102)=0; R16(0x04000106)=0;
    R16(0x04000100)=0; R16(0x04000104)=0;
    R16(0x04000106)=0x84; R16(0x04000102)=0x80;
    static u32 slots[4]; static Mailbox mb;
    mailboxPrepare(&mb,slots,4); pxiSetMailbox(PERF_CH,&mb);
    while (pmMainLoop()) {
        u32 msg;
        while (mailboxTryRecv(&mb,&msg)) {
            u32 cmd = msg & 255;
            if (cmd == PERF_PING) { pxiSend(PERF_CH,0x123456); continue; }
            out.magic=PERF_MAGIC; out.command=msg; out.n=0; out.status=0;
            ArmIrqState st = armIrqLockByPsr();
            // Empty read/timestamp control for this exact code/build.
            u32 t=now(); u32 v=R16(0x04000100); u32 elapsed=now()-t;
            row(0,0,0,elapsed,v,v,0);
            if (cmd==PERF_SPI || cmd==PERF_AUX) serial(cmd==PERF_AUX);
            else if (cmd==PERF_WIFI) wifi();
            else if (cmd==PERF_SOUND) sound(msg>>8);
            else out.status|=16;
            armIrqUnlockByPsr(st);
            pxiSend(PERF_CH,(u32)&out);
        }
        threadIrqWait(true,IRQ_VBLANK);
    }
    return 0;
}
