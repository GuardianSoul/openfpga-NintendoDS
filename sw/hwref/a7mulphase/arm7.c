// New-only internal-cycle discriminator; software timing is not DS truth.
#include <calico.h>
#include <string.h>
#include "protocol.h"
#define R16(a) (*(volatile u16*)(a))
#define R32(a) (*(volatile u32*)(a))
static MpResult out __attribute__((section(".main.d"),aligned(32)));
// A single slot, reused without changing address or bytes for any Rs.
uint32_t mp_main_copy[MP_SLOT_WORDS] __attribute__((section(".main.d"),aligned(4096)));
static const u32 multipliers[MP_CASES]={0x7f,0x7fff,0x7fffff,0x7fffffff};
static u32 now(void)
{
 u16 h=R16(0x04000104),l=R16(0x04000100),h2=R16(0x04000104);
 if(h!=h2){l=R16(0x04000100);h=h2;}return ((u32)h<<16)|l;
}
static u32 fnv(const void* data,u32 size)
{
 const u8* b=data;u32 v=2166136261u;
 for(u32 i=0;i<size;i++)v=(v^b[i])*16777619u;
 return v;
}
static __attribute__((target("arm"),noinline)) void context(MpContext* c)
{
 __asm__ volatile("mrs %0,cpsr\nmov %1,sp":"=r"(c->cpsr),"=r"(c->sp));
 c->ime=R32(0x04000208);c->ie=R32(0x04000210);c->iflags=R32(0x04000214);
 c->exmemcnt=R16(0x04000204);c->wramstat=*(volatile u8*)0x04000241;
 c->tm0=R16(0x04000100);c->tm0ctl=R16(0x04000102);
 c->tm1=R16(0x04000104);c->tm1ctl=R16(0x04000106);
 c->vcount=R16(0x04000006);c->soundcnt=R16(0x04000500);
 c->ipcsync=R16(0x04000180);c->biosprot=R16(0x04000308);c->powcnt2=R16(0x04000304);
}
static int valid(const MpInvocation* v,u32 n,u32 rs,u32 value)
{
 if(v->pre[0]!=n||v->pre[1]!=3||v->pre[2]!=rs||v->post[0]||
    v->post[1]!=3||v->post[2]!=rs||v->post[3]!=3*rs||value!=3*rs)return 0;
 for(int i=4;i<15;i++)if(v->pre[i]!=v->post[i])return 0;
 return (v->post[15]&0xf0000000)==0x60000000&&
        (v->post[15]&0x0fffffff)==(v->pre[15]&0x0fffffff);
}
static void measure(u32 command)
{
 memset(&out,0,sizeof out);out.magic=MP_MAGIC;out.version=MP_VERSION;
 out.case_id=(command>>8)&255;out.region=(command>>16)&1;
 if(out.case_id>=MP_CASES){out.error=1;goto ready;}
 out.rs=multipliers[out.case_id];out.source_entry=(u32)mp_mul;
 out.source_body=(u32)mp_mul_body;out.source_end=(u32)mp_mul_end;
 out.size=out.source_end-out.source_entry;
 if((out.source_entry&31)||out.source_entry<0x03800000||out.source_end>0x0380f000||
    !out.size||out.size>sizeof out.code_before){out.error=2;goto ready;}
 memcpy(mp_main_copy,(void*)out.source_entry,out.size);
 out.source_fnv=fnv((void*)out.source_entry,out.size);out.copy_fnv=fnv(mp_main_copy,out.size);
 out.copy_match=!memcmp((void*)out.source_entry,mp_main_copy,out.size);
 out.entry=out.region?(u32)mp_main_copy:out.source_entry;
 out.body=out.entry+out.source_body-out.source_entry;out.end=out.entry+out.size;
 memcpy(out.code_before,(void*)out.entry,out.size);
 if(!out.copy_match||out.source_fnv!=out.copy_fnv||((u32)mp_main_copy&4095)||
    ((u32)mp_main_copy>>24)!=2){out.error=4;goto ready;}
ready:
 __asm__ volatile("":::"memory");(void)*(volatile u32*)&out.magic;
 R16(0x04000180)=1<<8;
 u32 t=now();while((R16(0x04000180)&15)!=1)if(now()-t>MP_TIMEOUT){out.error|=8;goto finish;}
 if(out.error)goto finish;
 ArmIrqState irq=armIrqLockByPsr();context(&out.before);
 MpKernel k=(MpKernel)out.entry;const u32 rs=out.rs;
 for(u32 rep=0;rep<MP_REPS;rep++)for(u32 length=0;length<2;length++){
  u32 n=length?16:4;MpInvocation warm,observed;
  u32 warm_value=mp_invoke(k,1,rs,&warm);
  u32 line=R16(0x04000006),before=now();
  u32 value=mp_invoke(k,n,rs,&observed);
  u32 ticks=now()-before,endline=R16(0x04000006);
  // Shared output writes and checksums are outside the timed call.
  MpSample* s=&out.samples[rep][length];s->loops=n;s->ticks=ticks;
  s->warm_value=warm_value;s->value=value;s->warm=warm;s->timed=observed;
  s->warm_checksum=fnv(&warm,sizeof warm);s->checksum=fnv(&observed,sizeof observed);
  s->start_line=line;s->end_line=endline;
  if(!valid(&warm,1,out.rs,warm_value)||!valid(&observed,n,out.rs,value))out.error|=16;
 }
 context(&out.after);armIrqUnlockByPsr(irq);
 memcpy(out.code_after,(void*)out.entry,out.size);
 if(memcmp(out.code_before,out.code_after,out.size))out.error|=32;
finish:
 __asm__ volatile("":::"memory");(void)*(volatile u32*)&out.magic;
 R16(0x04000180)=2<<8;pxiSend(MP_CH,(u32)&out);
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
 static u32 slots[4];static Mailbox mb;mailboxPrepare(&mb,slots,4);pxiSetMailbox(MP_CH,&mb);
 out.magic=MP_MAGIC;out.version=MP_VERSION;R16(0x04000180)=0;
 while(pmMainLoop()){
  u32 msg;while(mailboxTryRecv(&mb,&msg)){
   if((msg&255)==MP_PING)pxiSend(MP_CH,(u32)&out);
   else if((msg&255)==MP_RUN)measure(msg);
  }
  threadIrqWait(true,IRQ_VBLANK);
 }
 return 0;
}
