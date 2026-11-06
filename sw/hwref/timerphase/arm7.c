#include <calico.h>
#include <string.h>
#include "protocol.h"
#define R16(a) (*(volatile u16*)(a))
#define R32(a) (*(volatile u32*)(a))
static TpMeta meta __attribute__((section(".main.d"),aligned(32)));
static TpResult out __attribute__((section(".main.d"),aligned(32)));
static TpRow samples[TP_ROWS] __attribute__((aligned(32)));
static u32 fnv(const void*p,u32 n){const u8*b=p;u32 h=2166136261u;while(n--){h^=*b++;h*=16777619u;}return h;}
static __attribute__((target("arm"),noinline))u32 flags(void){u32 x;__asm__ volatile("mrs %0,cpsr":"=r"(x));return x;}
static void measure(void){
 memset(&out,0,sizeof out);memset(samples,0,sizeof samples);
 out.magic=TP_MAGIC;out.version=1;out.rows=TP_ROWS;out.entry=meta.entry;out.end=meta.end;
 out.error=meta.error;if(meta.error)goto finish;
 memcpy(out.code,tp_timer,meta.end-meta.entry);out.code_before=fnv(tp_timer,meta.end-meta.entry);
 R16(0x04000180)=1<<8;
 // Bounded handshake as well as the ARM9 F/1 timeout. This iteration cap
 // is a liveness guard, not an instruction-time or DS measurement oracle.
 for(u32 attempts=0;(R16(0x04000180)&15)!=1;attempts++)
  if(attempts==1000000u){out.error|=8;goto finish;}
 ArmIrqState irq=armIrqLockByPsr();out.cpsr=flags();
 for(unsigned t=0;t<4;t++){out.controls_before[t]=R16(0x04000102+4*t);out.counts_before[t]=R16(0x04000100+4*t);}
 ((void(*)(TpRow*,TpResult*))tp_timer)(samples,&out);
#ifdef TP_OUTPUT_FAULT
 samples[0].guard^=1; // actual executed result fault, expected guard unchanged
#endif
 memcpy(out.samples,samples,sizeof samples);
 for(unsigned t=0;t<4;t++){R16(0x04000102+4*t)=0;R16(0x04000100+4*t)=out.counts_before[t];R16(0x04000102+4*t)=out.controls_before[t];out.controls_after[t]=R16(0x04000102+4*t);out.counts_after[t]=R16(0x04000100+4*t);if(out.controls_after[t]!=out.controls_before[t])out.error|=2;}
 armIrqUnlockByPsr(irq);out.code_after=fnv(tp_timer,meta.end-meta.entry);if(out.code_before!=out.code_after)out.error|=4;
finish:
 (void)*(volatile u32*)&out.magic;R16(0x04000180)=2<<8;pxiSend(TP_CH,(u32)&out);
}
int main(void){
 envReadNvramSettings();keypadStartExtServer();lcdSetIrqMask(DISPSTAT_IE_ALL,DISPSTAT_IE_VBLANK);irqEnable(IRQ_VBLANK);rtcInit();rtcSyncTime();pmInit();blkInit();
 for(unsigned i=0;i<16;i++)R32(0x04000400+i*16)=0;
 R16(0x04000500)=0;
 meta.magic=TP_MAGIC;meta.version=1;meta.result_pointer=(u32)&out;meta.result_bytes=sizeof out;meta.entry=(u32)tp_timer;meta.end=(u32)tp_timer_end;
 if(meta.entry<0x03800000||meta.end>0x0380f000||(meta.entry&31)||meta.end<=meta.entry||meta.end-meta.entry>sizeof out.code||(u32)samples<0x03800000||(u32)(samples+TP_ROWS)>0x0380f000)meta.error=1;
 else meta.fnv=fnv(tp_timer,meta.end-meta.entry);
 static u32 slots[4];static Mailbox mb;mailboxPrepare(&mb,slots,4);pxiSetMailbox(TP_CH,&mb);R16(0x04000180)=0;
 while(pmMainLoop()){u32 msg;while(mailboxTryRecv(&mb,&msg)){if(msg==TP_PING)pxiSend(TP_CH,(u32)&meta);else if(msg==TP_RUN)measure();}threadIrqWait(true,IRQ_VBLANK);}
 return 0;
}
