// Perftime is standalone: its own ARM7 owns the peripheral registers.
// Output only; this source contains no assumed DS timing constants.
#include "../common/hwref.h"
#include "../common/mpu_map.h"
#include "perftime.h"
#include <stdio.h>

static Mailbox mb;
static u32 slots[4];
static u32 stress_buffer[2048] __attribute__((aligned(8192)));
static u32 request(u32 command, bool stress)
{
    HwUncachedMap map;
    if(stress){
        armDCacheFlush(stress_buffer,sizeof stress_buffer);
        if(!hw_uncached_begin(&map,(u32)stress_buffer,CP15_PU_8K))return PERF_BAD;
    }
    u32 reply;
    while (mailboxTryRecv(&mb,&reply)) {}
    pxiSend(PERF_CH,command);
    u32 start=now32();
    volatile u32 sum=0;
    while (!mailboxTryRecv(&mb,&reply)) {
        // Uncached main-RAM CPU traffic while ARM7 sound/capture is active.
        if (stress) for (u32 i=0;i<256;i++) sum += ((vu32*)stress_buffer)[i*8];
        if (now32()-start>2u*33513982u) {
            if(stress)hw_uncached_end(&map);
            return PERF_BAD;
        }
    }
    (void)sum;
    if(stress && !hw_uncached_end(&map))return PERF_BAD;
    return reply;
}
static void run(u32 command, bool stress)
{
    char key[64];
    snprintf(key,sizeof key,"c%lu_s%u",(unsigned long)command,stress);
    if (!hw_step_begin("perftime2_progress.txt",key)) return;
    u16 exmem=REG16(0x04000204);
    if ((command&255)==PERF_AUX) REG16(0x04000204)=exmem|(1u<<11);
    u32 ptr=request(command,stress);
    REG16(0x04000204)=exmem; // return card ownership before any FAT access
    if (ptr<0x02000000 || ptr>=0x03000000) {
        hw_status("command %lu failed/timeout",(unsigned long)command); return;
    }
    ptr = 0x02000000u | (ptr & 0x003fffffu); // calico ARM7 uses main-RAM mirrors
    if (ptr + sizeof(PerfResult) > 0x02400000) { hw_status("invalid result span"); return; }
    PerfResult* r=(PerfResult*)ptr;
    armDCacheInvalidate(r,sizeof *r);
    if (r->magic!=PERF_MAGIC || r->command!=command || r->n>PERF_ROWS) {
        hw_status("invalid result block"); return;
    }
    Buf csv={0};
    buf_printf(&csv,"command,stress,status,kind,arg,rep,arm7_ticks,before,after,timeout\n");
    for (u32 i=0;i<r->n;i++) {
        const PerfRow* p=&r->row[i];
        buf_printf(&csv,"%lu,%u,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu\n",
            (unsigned long)command,stress,(unsigned long)r->status,
            (unsigned long)p->kind,(unsigned long)p->arg,(unsigned long)p->rep,
            (unsigned long)p->ticks,(unsigned long)p->before,(unsigned long)p->after,(unsigned long)p->timeout);
    }
    char fn[64]; snprintf(fn,sizeof fn,"perftime_%lu_%u.csv",(unsigned long)command,stress);
    bool saved=buf_write(&csv,fn);
    if ((command&255)==PERF_SOUND) for (int u=0;u<2;u++) {
        snprintf(fn,sizeof fn,"perftime_%lu_%u_cap%d.bin",(unsigned long)command,stress,u);
        saved=hw_write(fn,r->capture[u],sizeof r->capture[u]) && saved;
    }
    if (saved && !r->status) hw_step_done("perftime2_progress.txt",key);
}
int main(void)
{
    hw_init("perftime 2 - uncaptured timing probes");
    for(u32 i=0;i<2048;i++)stress_buffer[i]=0x91a70000u^i;
    mailboxPrepare(&mb,slots,4); pxiSetMailbox(PERF_CH,&mb);
    if (request(PERF_PING,false)!=0x123456) { hw_status("ARM7 missing"); hw_done(); }
    // AUX is explicitly selected: do not send cartridge commands by default.
    hw_status("A: SPI/WiFi/sound; X: AUX RDSR only");
    for (;;) { scanKeys(); if (keysDown()&(KEY_A|KEY_X)) break; swiWaitForVBlank(); }
    if (keysDown()&KEY_X) run(PERF_AUX,false);
    else {
        run(PERF_SPI,false); run(PERF_WIFI,false);
        for (u32 fmt=0;fmt<3;fmt++) for (u32 load=0;load<4;load++) for (int stress=0;stress<2;stress++)
            run(PERF_SOUND|((fmt|((load&1)<<2)|((load&2)<<2))<<8),stress);
        // All sixteen voices, including the two capture clocks, decode
        // ADPCM at the selected timer. Capture rate therefore also changes.
        for (u32 fast=0;fast<2;fast++) for (int stress=0;stress<2;stress++)
            run(PERF_SOUND|((2u|4u|16u|(fast<<3))<<8),stress);
    }
    Buf info={0};
    buf_printf(&info,"perftime 2; built " __DATE__ " " __TIME__ "\nRaw ARM7 system ticks, bounded polls include MMIO/timestamp overhead. No timing targets. No RF writes/TX/RX. AUX requires X; firmware and AUX issue RDSR only. Capture files are 1024 PCM16 samples/unit. Sound arg bit4 selects all16 ADPCM, including capture-clock voices at selected timer16/512; other cases retain silent PCM16 clock voices at128. Kind5: channel enable timestamps before/after, rep=channel, ticks=enable write/read bracket. Kind7: requested/readback sound control words. Kind6: capture arm before/after; kind4: capture polling elapsed. Timestamp reads alter start phase versus v1; compare only matched v2 protocol. See docs/hw-reference.md.\n");
    buf_printf(&info,"Owned stress buffer %08lx size %lu; temporary uncached MPU aperture, exact register state restored before FAT.\n",(unsigned long)stress_buffer,(unsigned long)sizeof stress_buffer);
    buf_printf(&info,"ADPCM header predictor/index0; loopstart1+length127 words inside128-word buffer. If power was off, wait15ms before any voice starts, outside measurement.\n");
    buf_write(&info,"perftime_info.txt");
    hw_done();
}
