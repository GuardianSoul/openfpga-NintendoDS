// Private-WRAM Thumb forms; arm7time's F/1 timer and five4/16 pairs.
#include <calico.h>
#include <string.h>
#include "protocol.h"
#define R16(a) (*(volatile u16*)(a))
#define R32(a) (*(volatile u32*)(a))
#define CASE(n) {at_##n,at_##n##_body,at_##n##_end}
static const struct {const u8*entry,*body,*end;} cases[AT_CASES]={CASE(alu),CASE(branch),CASE(ldr_sp),CASE(str_sp),CASE(ldr_pc),CASE(str_reg),CASE(ldrh),CASE(strh),CASE(stm1)};
static struct {u32 before[8],data[AT_DATA_WORDS],after[8];} scratch __attribute__((aligned(32)));
static AtMeta meta __attribute__((section(".main.d"),aligned(32)));
static AtResult out __attribute__((section(".main.d"),aligned(32)));
static AtTimerResult timer_out __attribute__((section(".main.d"),aligned(32)));
static u32 now(void){u16 h=R16(0x04000104),l=R16(0x04000100),h2=R16(0x04000104);if(h!=h2){l=R16(0x04000100);h=h2;}return ((u32)h<<16)|l;}
static u32 fnv(const void*p,u32 size){const u8*b=p;u32 h=2166136261u;while(size--){h^=*b++;h*=16777619u;}return h;}
static __attribute__((target("arm"),noinline))u32 get_sp(void){u32 x;__asm__ volatile("mov %0,sp":"=r"(x));return x;}
static __attribute__((target("arm"),noinline))u32 flags(void){u32 x;__asm__ volatile("mrs %0,cpsr":"=r"(x));return x;}
static void init(unsigned id){
 (void)id;
 for(unsigned i=0;i<8;i++)scratch.before[i]=scratch.after[i]=AT_GUARD;
 for(unsigned i=0;i<AT_DATA_WORDS;i++)scratch.data[i]=AT_INITIAL;
#ifdef THUMB_DATA_MUTANT
 if(id==2)scratch.data[0]^=1; // real input fault; immutable expected data unchanged
#endif
}
static u32 expected_return(unsigned id,unsigned loops){return id==0?0x12+64*loops:id==2?AT_INITIAL:id==4?AT_VALUE:id==6?(AT_INITIAL&65535):0x12;}
static u32 scratch_expected(unsigned id,unsigned n,unsigned index){
 if(id==8&&index<64*n)return AT_VALUE;
 if(!index&&(id==3||id==5))return AT_VALUE;
 if(!index&&id==7)return (AT_INITIAL&0xffff0000)|(AT_VALUE&65535);
 return AT_INITIAL;
}
static u32 scratch_check(unsigned id,unsigned n){
 u32 error=0;for(unsigned i=0;i<8;i++)if(scratch.before[i]!=AT_GUARD||scratch.after[i]!=AT_GUARD)error|=1;
 for(unsigned i=0;i<AT_DATA_WORDS;i++)if(scratch.data[i]!=scratch_expected(id,n,i))error|=2;
 return error;
}
static void prepare_meta(void){
 memset(&meta,0,sizeof meta);meta.magic=AT_MAGIC;meta.version=AT_VERSION;meta.cases=AT_CASES;meta.result_pointer=(u32)&out;meta.scratch=(u32)scratch.data;meta.guard_before=(u32)scratch.before;meta.guard_after=(u32)scratch.after;
 for(unsigned id=0;id<AT_CASES;id++){
  AtDescriptor*d=&meta.d[id];d->entry=(u32)cases[id].entry;d->body=(u32)cases[id].body;d->end=(u32)cases[id].end;
  u32 start=d->entry&~1u,size=d->end-start;
  if(!(d->entry&1)||start<0x03800000||d->end>0x0380f000||(start&31)||(d->body&3)||size>sizeof out.code||!size||d->body<start||d->body>=d->end)meta.error|=1;
  d->fnv=fnv((const void*)start,size);
 }
 if(meta.guard_before<0x03800000||meta.guard_after+32>0x0380f000)meta.error|=2;
 meta.timer.entry=(u32)at_timer;meta.timer.body=meta.timer.entry;meta.timer.end=(u32)at_timer_end;
 u32 bytes=meta.timer.end-meta.timer.entry;
 if((meta.timer.entry&31)||meta.timer.entry<0x03800000||meta.timer.end>0x0380f000||!bytes||bytes>sizeof timer_out.code)meta.error|=4;
 else meta.timer.fnv=fnv(at_timer,bytes);
 meta.timer_result_pointer=(u32)&timer_out;meta.timer_rows=AT_TIMER_ROWS;meta.timer_bytes=sizeof timer_out;
}
static void measure_timers(void){
 memset(&timer_out,0,sizeof timer_out);AtTimerResult*t=&timer_out;
 t->magic=AT_MAGIC;t->version=AT_VERSION;t->id=AT_CASES;t->entry=meta.timer.entry;t->end=meta.timer.end;t->code_bytes=t->end-t->entry;
 if(meta.error){t->error=1;goto timer_ready;}
 memcpy(t->code,at_timer,t->code_bytes);t->code_before=fnv(at_timer,t->code_bytes);
timer_ready:
 (void)*(volatile u32*)&t->magic;R16(0x04000180)=1<<8;
 u32 before=now();while((R16(0x04000180)&15)!=1)if(now()-before>AT_TIMEOUT){t->error|=4;goto timer_finish;}
 if(t->error)goto timer_finish;
 ArmIrqState irq=armIrqLockByPsr();
 for(unsigned bank=0;bank<2;bank++){t->control_before[bank]=R16(0x0400010a+4*bank);t->value_before[bank]=R16(0x04000108+4*bank);}
 for(unsigned mode=0;mode<3;mode++)for(unsigned p=mode?1:0;p<4;p++)for(unsigned delay=0;delay<32;delay++){
  AtTimerSample s={0};s.mode=mode;s.prescaler=p;s.delay=delay;s.cpsr=flags();
  ((void(*)(u32,u32,u32,AtTimerSample*))at_timer)(0xc0|p,mode,delay,&s);
#ifdef AT_TIMER_DATA_MUTANT
  if(mode==0&&p==0&&delay==0)s.stopped2b^=1;
#endif
  if(!(s.cpsr&0x80)||s.control2!=(0xc0|p)||s.control3!=(mode==2?(0xc0|p):0)||
    s.stopped2a!=s.stopped2b||s.stopped3a!=s.stopped3b||!(s.if_after&0x20)||(mode==2&&!(s.if_after&0x40)))s.error|=2;
  t->samples[t->rows++]=s;t->error|=s.error;
 }
 for(unsigned bank=0;bank<2;bank++){R16(0x0400010a+4*bank)=0;R16(0x04000108+4*bank)=t->value_before[bank];R16(0x0400010a+4*bank)=t->control_before[bank];t->control_after[bank]=R16(0x0400010a+4*bank);t->value_after[bank]=R16(0x04000108+4*bank);if(t->control_after[bank]!=t->control_before[bank])t->error|=8;}
 armIrqUnlockByPsr(irq);t->code_after=fnv(at_timer,t->code_bytes);if(t->code_before!=t->code_after)t->error|=64;
timer_finish:
 (void)*(volatile u32*)&t->magic;R16(0x04000180)=2<<8;pxiSend(AT_CH,(u32)t);
}
static void measure(unsigned id){
 memset(&out,0,sizeof out);out.magic=AT_MAGIC;out.version=AT_VERSION;out.id=id;
 if(id>=AT_CASES||meta.error){out.error=1;goto ready;}
 AtDescriptor*d=&meta.d[id];out.entry=d->entry;out.body=d->body;out.end=d->end;out.code_bytes=d->end-(d->entry&~1u);out.code_before=fnv((void*)(d->entry&~1u),out.code_bytes);memcpy(out.code,(void*)(d->entry&~1u),out.code_bytes);
 out.scratch=meta.scratch;out.guard_before=meta.guard_before;out.guard_after=meta.guard_after;
ready:
 (void)*(volatile u32*)&out.magic;R16(0x04000180)=1<<8;
 u32 before=now();while((R16(0x04000180)&15)!=1)if(now()-before>AT_TIMEOUT){out.error|=4;goto finish;}
 if(out.error)goto finish;
 ArmIrqState irq=armIrqLockByPsr();AtKernel k=(AtKernel)out.entry;
 for(unsigned rep=0;rep<AT_REPS;rep++)for(unsigned length=0;length<2;length++){
  AtSample s={0};s.loops=length?16:4;init(id);s.cpsr=flags();s.sp_before=get_sp();s.warm_return=k(1,meta.scratch,0);
  u32 t0=now();s.returned=k(s.loops,meta.scratch,0);s.ticks=now()-t0;s.sp_after=get_sp();s.scratch_fnv=fnv(scratch.data,sizeof scratch.data);
  if(s.warm_return!=expected_return(id,1)||s.returned!=expected_return(id,s.loops))s.error|=8;
  s.error|=scratch_check(id,s.loops);
  if(s.sp_before!=s.sp_after||!(s.cpsr&0x80))s.error|=16;
  init(id);u32 sp=get_sp();k(s.loops,meta.scratch,(u32)s.signature);
  u32 expected[7]={expected_return(id,s.loops),meta.scratch,AT_VALUE,0,sp-20,0,meta.scratch+(id==8?64*s.loops*4:0)};
  for(unsigned r=0;r<7;r++)if(s.signature[r]!=expected[r])s.error|=32;
  out.samples[rep][length]=s;out.error|=s.error;
 }
 armIrqUnlockByPsr(irq);memcpy(out.scratch_final,scratch.data,sizeof scratch.data);out.code_after=fnv((void*)(out.entry&~1u),out.code_bytes);if(out.code_before!=out.code_after)out.error|=64;
finish:
 (void)*(volatile u32*)&out.magic;R16(0x04000180)=2<<8;pxiSend(AT_CH,(u32)&out);
}
int main(void){
 envReadNvramSettings();keypadStartExtServer();lcdSetIrqMask(DISPSTAT_IE_ALL,DISPSTAT_IE_VBLANK);irqEnable(IRQ_VBLANK);rtcInit();rtcSyncTime();pmInit();blkInit();
 for(unsigned i=0;i<16;i++)R32(0x04000400+i*16)=0;
 R16(0x04000500)=0;
 R16(0x04000102)=0;R16(0x04000106)=0;R16(0x04000100)=0;R16(0x04000104)=0;R16(0x04000106)=0x84;R16(0x04000102)=0x80;
 prepare_meta();static u32 slots[4];static Mailbox mb;mailboxPrepare(&mb,slots,4);pxiSetMailbox(AT_CH,&mb);R16(0x04000180)=0;
 while(pmMainLoop()){
  u32 msg;while(mailboxTryRecv(&mb,&msg)){if((msg&255)==AT_PING)pxiSend(AT_CH,(u32)&meta);else if((msg&255)==AT_RUN){unsigned id=(msg>>8)&255;if(id==AT_CASES)measure_timers();else measure(id);}}
  threadIrqWait(true,IRQ_VBLANK);
 }
 return 0;
}
