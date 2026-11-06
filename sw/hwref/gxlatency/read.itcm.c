// Same instructions for idle control and busy read; retain timer and GXSTAT samples.
#include "read.h"
// unitgx v3's immediate, fixed-destination DMA3, with a second observation
// after GXSTAT busy clears. Timer1 cascades timer0; retain raw status at both.
void gxlat_dma(const u32* words, u32 count, GxDmaTime* result)
{
    ArmIrqState irq=armIrqLockByPsr();
    REG32(0x040000d4)=(u32)words;
    REG32(0x040000d8)=0x04000400;
    u32 start=now32(),i=0;
    REG32(0x040000dc)=count|(1u<<26)|(2u<<21)|(1u<<31);
    while ((REG32(0x040000dc)&(1u<<31)) && ++i<20000000) {}
    result->dma_sys=now32()-start;
    result->dma_stat=R_GXSTAT;
    result->timeout=i>=20000000;
    i=0;
    while ((R_GXSTAT&GXSTAT_BUSY) && ++i<20000000) {}
    result->idle_sys=now32()-start;
    result->idle_stat=R_GXSTAT;
    result->timeout|=(i>=20000000)<<1;
    REG32(0x040000dc)=0;
    armIrqUnlockByPsr(irq);
}
void gxlat_read(int load, int delay, u32 address, GxRead* result)
{
    if (!gx_wait(GXSTAT_BUSY)) {
        result->before=R_GXSTAT;result->after=R_GXSTAT;
        result->value=0;result->elapsed=~0u;return;
    }
    ArmIrqState irq=armIrqLockByPsr();
    if (load) {
        *GXPORT(0x10)=2;
        for (int i=0;i<16;i++) *GXPORT(0x16)=i==0 ? 0x2000 : i==5 || i==10 || i==15 ? 0x1000 : 0;
    }
    for (int i=0;i<delay;i++) __asm__ volatile("nop");
    u16 t0=R_TM0;
    u32 before=R_GXSTAT, value=REG32(address), after=R_GXSTAT;
    u16 t1=R_TM0;
    result->before=before; result->value=value; result->after=after; result->elapsed=(u16)(t1-t0);
    armIrqUnlockByPsr(irq);
    gx_wait(GXSTAT_BUSY);
}
