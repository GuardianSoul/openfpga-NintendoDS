// All private WRAM, including old stacks/BIOS words, is restored before IRQs.
#include <calico.h>
#include <string.h>
#include "protocol.h"
#define R8(a) (*(volatile u8*)(a))
#define R16(a) (*(volatile u16*)(a))
#define R32(a) (*(volatile u32*)(a))
static PwResult out __attribute__((section(".main.d"),aligned(32)));
static u32 backup[PW_WORDS] __attribute__((section(".main.d"),aligned(32)));
static u32 zero[8] __attribute__((section(".main.d"),aligned(32)));
static u16 order[2048] __attribute__((section(".main.d"),aligned(32)));
static u16 next[2048] __attribute__((section(".main.d"),aligned(32)));
u8 pw_stack[4096] __attribute__((aligned(8)));
static u32 now(void) { u16 h=R16(0x04000104),l=R16(0x04000100),h2=R16(0x04000104);if(h!=h2){l=R16(0x04000100);h=h2;}return ((u32)h<<16)|l; }
static __attribute__((target("arm"),noinline)) void context(PwContext* c) {
 __asm__ volatile("mrs %0,cpsr\nmov %1,sp":"=r"(c->cpsr),"=r"(c->sp));
 c->ime=R32(0x04000208);c->ie=R32(0x04000210);c->iflags=R32(0x04000214);
 c->exmemcnt=R16(0x04000204);c->wramstat=R8(0x04000241);
 c->tm0=R16(0x04000100);c->tm0ctl=R16(0x04000102);c->tm1=R16(0x04000104);c->tm1ctl=R16(0x04000106);
 c->vcount=R16(0x04000006);c->soundcnt=R16(0x04000500);c->ipcsync=R16(0x04000180);c->biosprot=R16(0x04000308);c->powcnt2=R16(0x04000304);
}
static u32 prepare(void) {
 volatile u32* p=(volatile u32*)PW_BASE;
 for(u32 i=0;i<PW_WORDS;i++)p[i]=pw_guard(i);
 if(out.nodes){pw_graph(out.nodes,order,next);for(u32 i=0;i<out.nodes;i++)p[i*8+7]=PW_BASE+next[i]*32+28;}
 // Exact prehistory: ascending full64KiB read after all initialization stores.
 return pw_fnv((void*)PW_BASE,65536);
}
static bool image_valid(void) {
 for(u32 i=0;i<PW_WORDS;i++) {
  u32 expected=pw_guard(i);
  if(out.nodes) { if(i/8<out.nodes&&i%8==7)expected=PW_BASE+next[i/8]*32+28; }
  else if(out.fixed) { if(!i)expected=PW_VALUE; }
  else { // Ascending32B lines, then next word lane after each2048 stores.
   if(((i%8)*2048+i/8)<out.stores)expected=PW_VALUE;
  }
  if(out.image[i]!=expected)return false;
 }
 return true;
}
static u32 dma_image(void) {
 R32(0x040000d4)=PW_BASE;R32(0x040000d8)=(u32)out.image;
 R32(0x040000dc)=0x84000000u|PW_WORDS;
 u32 start=now();while(R32(0x040000dc)&0x80000000u)if(now()-start>PW_TIMEOUT){out.error|=8;break;}
 return pw_fnv(out.image,65536);
}
static void capture_visible(void) {
 u16 power=R16(0x04000304);R16(0x04000304)=power|1;
 for(u32 i=0;i<64;i++)out.capture[i]=0x5a5a;
 out.sound_src=PW_BASE;out.sound_timer=128;out.sound_ctrl=0x86;
 R16(0x04000500)=0x807f;
 R32(0x04000414)=(u32)zero;R16(0x04000418)=-128;R16(0x0400041a)=0;R32(0x0400041c)=8;
 R32(0x04000410)=0xa8000000u;
 R32(0x04000404)=PW_BASE;R16(0x04000408)=-128;R16(0x0400040a)=0;R32(0x0400040c)=8;
 R32(0x04000400)=0xa800007fu;
 R32(0x04000510)=(u32)out.capture;R16(0x04000514)=32;R8(0x04000508)=0x86;
 u32 start=now();while(R8(0x04000508)&0x80)if(now()-start>PW_TIMEOUT){out.capture_timeout=1;break;}
 R8(0x04000508)=0;R32(0x04000400)=0;R32(0x04000410)=0;R16(0x04000500)=0;R16(0x04000304)=power;
 for(u32 i=8;i<64;i++)if(out.capture[i]!=0x1234)out.error|=16;
}
typedef u32 (*Kernel)(u32,u32,u32*);
static __attribute__((noinline)) void timed(Kernel fn,u32 a,u32 b,PwSample* s) {
 u32 terminal=0;
 u32 before=now(),value=fn(a,b,&terminal),after=now();
 s->before=before;s->after=after;s->ticks=after-before;s->value=value;s->terminal=terminal;
}
static __attribute__((noinline)) void timed_dma(PwSample* s) {
 u32 destination=(u32)out.image;
 u32 before=now();
 R32(0x040000d4)=PW_BASE;R32(0x040000d8)=destination;R32(0x040000dc)=0x84000000u|PW_WORDS;
 bool timeout=false;
 while(R32(0x040000dc)&0x80000000u)if(now()-before>PW_TIMEOUT){timeout=true;break;}
 u32 after=now();s->before=before;s->after=after;s->ticks=after-before;
 if(timeout)out.error|=8;
}
void pw_run_shared(void) {
 context(&out.before);
 memcpy(backup,(void*)PW_BASE,65536);out.backup_fnv=pw_fnv(backup,65536);
 for(u32 rep=0;rep<PW_REPS;rep++) {
  u32 pre=0;
  for(u32 phase=0;phase<3;phase++) {
   PwSample* s=&out.samples[rep][phase];
   if(out.nodes) { pre=prepare();s->operations=phase==0?1:out.nodes*(phase==2?4:1);s->kind=phase; }
   else { if(!phase)pre=prepare();s->operations=phase==2?PW_WORDS:out.stores;s->kind=3+phase; }
   out.guard_fnv=pre;s->pre_fnv=pre;s->start_line=R16(0x04000006);
   u32 operations=s->operations,distinct=!out.fixed;
   if(out.nodes)timed(pw_chase,PW_BASE+28,operations,s);
   else if(!phase)timed(pw_stores,operations,distinct,s);
   else if(phase==1)timed(pw_reads,operations,distinct,s);
   else timed_dma(s);
   s->end_line=R16(0x04000006);
  }
  u32 hash=out.nodes?dma_image():pw_fnv(out.image,65536);
  for(u32 i=0;i<3;i++)out.samples[rep][i].post_fnv=hash;
  if(!image_valid())out.error|=4;
 }
 if(out.case_id==12)capture_visible();
 memcpy((void*)PW_BASE,backup,65536);out.restored_fnv=pw_fnv((void*)PW_BASE,65536);
 out.restore_equal=!memcmp((void*)PW_BASE,backup,65536);
 context(&out.after);
 // Never return onto a corrupt saved stack/IRQ vector.
 if(!out.restore_equal){out.error|=32;for(;;){R16(0x04000180)=3<<8;}}
}
static void measure(u32 id) {
 memset(&out,0,sizeof out);out.magic=PW_MAGIC;out.version=PW_VERSION;out.case_id=id;out.result_bytes=sizeof out;
 if(id>=PW_CASES){out.error=1;return;}
 out.nodes=id<6?pw_counts[id]:0;out.seed=out.nodes?PW_SEED:0;out.stores=id<6?0:pw_counts[id];out.fixed=id==6;
 out.stack_lo=(u32)pw_stack;out.stack_hi=(u32)pw_stack+sizeof pw_stack;
 out.entry_chain=(u32)pw_chain;out.end_chain=(u32)pw_chain_end;out.entry_store=(u32)pw_store;out.end_store=(u32)pw_store_end;
 out.entry_read=(u32)pw_read;out.end_read=(u32)pw_read_end;out.entry_switch=(u32)pw_switch;out.end_switch=(u32)pw_switch_end;
 out.code_bytes=out.end_switch-out.entry_chain;out.dma_src=PW_BASE;out.dma_dst=(u32)out.image;out.dma_words=PW_WORDS;
 if(out.code_bytes>PW_CODE||out.entry_chain<0x037f8000||out.end_switch>PW_BASE||out.stack_lo<0x037f8000||out.stack_hi>PW_BASE||R8(0x04000241)!=3)out.error|=2;
 for(u32 i=0;i<4;i++)if(R32(0x040000b8+i*12)&0x80000000u)out.error|=64;
 if(!out.error)memcpy(out.code_before,pw_chain,out.code_bytes);
 R16(0x04000180)=1<<8;u32 t=now();while((R16(0x04000180)&15)!=1)if(now()-t>PW_TIMEOUT){out.error|=128;break;}
 if(!out.error)((void(*)(void))pw_switch)();
 if(!out.error){memcpy(out.code_after,pw_chain,out.code_bytes);if(memcmp(out.code_before,out.code_after,out.code_bytes))out.error|=256;}
 R16(0x04000180)=2<<8;pxiSend(PW_CH,(u32)&out);
}
int main(void) {
 envReadNvramSettings();keypadStartExtServer();lcdSetIrqMask(DISPSTAT_IE_ALL,DISPSTAT_IE_VBLANK);irqEnable(IRQ_VBLANK);rtcInit();rtcSyncTime();pmInit();blkInit();
 for(u32 i=0;i<16;i++){R32(0x04000400+i*16)=0;}
 R16(0x04000500)=0;R8(0x04000508)=0;R8(0x04000509)=0;
 R16(0x04000102)=0;R16(0x04000106)=0;R16(0x04000100)=0;R16(0x04000104)=0;R16(0x04000106)=0x84;R16(0x04000102)=0x80;
 static u32 slots[4];static Mailbox mb;mailboxPrepare(&mb,slots,4);pxiSetMailbox(PW_CH,&mb);R16(0x04000180)=0;
 while(pmMainLoop()) {u32 msg;while(mailboxTryRecv(&mb,&msg)){if((msg&255)==PW_PING)pxiSend(PW_CH,(u32)&out);else if((msg&255)==PW_RUN)measure(msg>>8);}threadIrqWait(true,IRQ_VBLANK);}return 0;
}
