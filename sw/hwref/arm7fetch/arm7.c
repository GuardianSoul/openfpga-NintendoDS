// New-only ARM7 MAIN-fetch measurement; no assumed N/S or buffer-retention law.
#include <calico.h>
#include <string.h>
#include "protocol.h"
#include "kernels.h"
#define R16(a) (*(volatile u16*)(a))
#define R32(a) (*(volatile u32*)(a))
static AfResult out __attribute__((section(".main.d"),aligned(32)));
// One distinct MAIN slot per case; the linked private-WRAM originals are
// the paired controls. No copy or result storage aliases either code bank.
uint32_t af_main_copy[AF_CASES][AF_SLOT_WORDS]
 __attribute__((section(".main.d"),aligned(4096)));
static u32 now(void)
{
 u16 h=R16(0x04000104),l=R16(0x04000100),h2=R16(0x04000104);
 if(h!=h2){l=R16(0x04000100);h=h2;}return ((u32)h<<16)|l;
}
static u32 fnv(const void* data,u32 size)
{
 const u8* b=data;u32 value=2166136261u;
 for(u32 i=0;i<size;i++)value=(value^b[i])*16777619u;
 return value;
}
static void measure(u32 command)
{
 memset(&out,0,sizeof out);out.magic=AF_MAGIC;out.version=AF_VERSION;
 out.case_id=(command>>8)&255;out.region=(command>>16)&1;
 if(out.case_id>=AF_CASES){out.error=1;goto ready;}
 const A7FetchCase* c=&af_cases[out.case_id];
 strncpy(out.name,c->name,sizeof out.name-1);out.kind=c->kind;out.offset=c->offset;
 out.stride=c->stride;out.nodes=c->nodes;out.checksum_per_loop=c->checksum_per_loop;
 u32 src=(u32)c->entry,body=(u32)c->body,end=(u32)c->end;
 out.source_entry=src;out.source_body=body;out.source_end=end;out.size=end-src;
 if((src&31)||src<0x03800000u||end>0x0380f000u||!out.size||out.size>4096||
    body<src||body>=end||((body&15)!=c->offset)){out.error=2;goto ready;}
 memcpy(af_main_copy[c->id],(const void*)src,out.size);
 out.source_fnv=fnv((const void*)src,out.size);
 out.copy_fnv=fnv(af_main_copy[c->id],out.size);
 out.copy_match=!memcmp((const void*)src,af_main_copy[c->id],out.size);
 memcpy(out.code,(const void*)src,out.size);
 out.entry=out.region ? (u32)af_main_copy[c->id] : src;
 out.body=out.entry+body-src;out.end=out.entry+out.size;
 if(!out.copy_match||out.source_fnv!=out.copy_fnv||(out.entry&31)||
    (out.region&&((out.entry>>24)!=2))){out.error=4;goto ready;}
ready:
 // Drain posted metadata writes before announcing readiness. ARM9 will
 // assert GO only from its IRQ-masked ITCM helper, not from the SD wrapper.
 __asm__ volatile("":::"memory");
 (void)*(volatile u32*)&out.magic;
 R16(0x04000180)=1<<8;
 u32 t=now();while((R16(0x04000180)&15)!=1)if(now()-t>AF_TIMEOUT){out.error=8;goto finish;}
 if(out.error)goto finish;
 ArmIrqState irq=armIrqLockByPsr();
 A7FetchKernel k=(A7FetchKernel)out.entry;
 for(u32 rep=0;rep<AF_REPS;rep++)for(u32 length=0;length<2;length++){
  u32 loops=length ? 16 : 4;
  u32 warm=k(1);
  u32 line=R16(0x04000006),before=now();
  u32 value=k(loops);
  u32 ticks=now()-before,endline=R16(0x04000006);
  // Every shared result write occurs outside the timed interval.
  AfSample* s=&out.samples[rep][length];
  s->loops=loops;s->ticks=ticks;s->warm_checksum=warm;s->checksum=value;
  s->start_line=line;s->end_line=endline;
  if(warm!=c->checksum_per_loop||value!=c->checksum_per_loop*loops)out.error|=16;
 }
 armIrqUnlockByPsr(irq);
finish:
 __asm__ volatile("":::"memory");
 (void)*(volatile u32*)&out.magic;
 R16(0x04000180)=2<<8;
 pxiSend(AF_CH,(u32)&out);
}
int main(void)
{
 envReadNvramSettings();keypadStartExtServer();
 lcdSetIrqMask(DISPSTAT_IE_ALL,DISPSTAT_IE_VBLANK);irqEnable(IRQ_VBLANK);
 rtcInit();rtcSyncTime();pmInit();blkInit();
 for(int i=0;i<16;i++)R32(0x04000400+i*16)=0;
 R16(0x04000500)=0;
 R16(0x04000102)=0;R16(0x04000106)=0;R16(0x04000100)=0;R16(0x04000104)=0;
 R16(0x04000106)=0x84;R16(0x04000102)=0x80;
 static u32 slots[4];static Mailbox mb;
 mailboxPrepare(&mb,slots,4);pxiSetMailbox(AF_CH,&mb);
 out.magic=AF_MAGIC;out.version=AF_VERSION;R16(0x04000180)=0;
 while(pmMainLoop()){
  u32 msg;while(mailboxTryRecv(&mb,&msg)){
   if((msg&255)==AF_PING)pxiSend(AF_CH,(u32)&out);
   else if((msg&255)==AF_RUN)measure(msg);
  }
  threadIrqWait(true,IRQ_VBLANK);
 }
 return 0;
}
