#include "probe.h"
#include "probe.c"
/* Explicit IO widths; pauses keep RTC serial edges comfortably separated. */
static void pause_io(void) { for (volatile int i=0;i<32;i++) __asm__ volatile("nop"); }
u32 rtc_port_read(u32 offset,u32 width) {
    u32 a=0x04000138+offset;
    u32 v=width==1 ? R8(a) : width==2 ? R16(a) : R32(a);
    pause_io(); return v;
}
void rtc_port_write(u32 offset,u32 width,u32 v) {
    u32 a=0x04000138+offset;
    if(width==1) R8(a)=v; else if(width==2) R16(a)=v; else R32(a)=v;
    pause_io();
}
u32 rtc_now(void) {
    u32 hi,lo,again;
    do { hi=TM_CNT_L(1); lo=TM_CNT_L(0); again=TM_CNT_L(1); } while(hi!=again);
    return (hi<<16)|lo;
}
int main(void) {
    MB->cmd=0; MB->ack=0;
    while((IPCSYNC & 15)!=9) ;
    IPCSYNC=7<<8;
    while(!MB->cmd) ;
    TM_CNT_H(0)=0; TM_CNT_H(1)=0; TM_CNT_L(0)=0; TM_CNT_L(1)=0;
    TM_CNT_H(1)=TM_ENABLE|TM_CASCADE; TM_CNT_H(0)=TM_ENABLE|3;
    rtc_probe((rtc_log *)RTC_LOG_ADDR,MB->cmd==2);
    TM_CNT_H(0)=0; TM_CNT_H(1)=0;
    MB->ack=MB->cmd;
    for(;;) __asm__ volatile("nop");
}
