#include "native.h"
#define out (*N_RESULT)
#define mm_main_copy ((u32*)N_MAIN)
#define mm_mul ((MmKernel)N_PRIVATE)
#define mm_mul_body ((unsigned char*)(N_PRIVATE+4))
#define mm_mul_end ((unsigned char*)(N_PRIVATE+272))
#define mm_return ((unsigned char*)N_RETURN)

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
static __attribute__((target("arm"),noinline)) void context(MmContext* c)
{
 __asm__ volatile("mrs %0,cpsr\nmov %1,sp":"=r"(c->cpsr),"=r"(c->sp));
 c->ime=R32(0x04000208);c->ie=R32(0x04000210);c->iflags=R32(0x04000214);
 c->exmemcnt=R16(0x04000204);c->wramstat=*(volatile u8*)0x04000241;
 c->tm0=R16(0x04000100);c->tm0ctl=R16(0x04000102);
 c->tm1=R16(0x04000104);c->tm1ctl=R16(0x04000106);
 c->vcount=R16(0x04000006);c->soundcnt=R16(0x04000500);
 c->ipcsync=R16(0x04000180);c->biosprot=R16(0x04000308);c->powcnt2=R16(0x04000304);
}
static void measure(u32 command)
{
 memset(&out,0,sizeof out);out.magic=MM_MAGIC;out.version=MM_VERSION;
 out.case_id=(command>>8)&255;out.region=(command>>16)&1;
 if(out.case_id>=MM_CASES){out.error=1;goto ready;}
 out.rs2=mm_rs2[out.case_id];out.rs6=mm_rs6[out.case_id];
 out.wrapper_return=(u32)mm_return;out.source_entry=(u32)mm_mul;
 out.source_body=(u32)mm_mul_body;out.source_end=(u32)mm_mul_end;
 out.size=out.source_end-out.source_entry;
 if((out.source_entry&31)||out.source_entry<0x03800000||out.source_end>0x0380f000||
    !out.size||out.size>sizeof out.code_before){out.error=2;goto ready;}
 memcpy(mm_main_copy,(void*)out.source_entry,out.size);
 out.source_fnv=fnv((void*)out.source_entry,out.size);out.copy_fnv=fnv(mm_main_copy,out.size);
 out.copy_match=!memcmp((void*)out.source_entry,mm_main_copy,out.size);
 out.entry=out.region?(u32)mm_main_copy:out.source_entry;
 out.body=out.entry+out.source_body-out.source_entry;out.end=out.entry+out.size;
 memcpy(out.code_before,(void*)out.entry,out.size);
 if(!out.copy_match||out.source_fnv!=out.copy_fnv||((u32)mm_main_copy&4095)||
    ((u32)mm_main_copy>>24)!=2){out.error=4;goto ready;}
ready:
 __asm__ volatile("":::"memory");(void)*(volatile u32*)&out.magic;
 R16(0x04000180)=1<<8;
 u32 t=now();while((R16(0x04000180)&15)!=1)if(now()-t>MM_TIMEOUT){out.error|=8;goto finish;}
 if(out.error)goto finish;
 context(&out.before);
 MmKernel k=(MmKernel)out.entry;const u32 rs2=out.rs2,rs6=out.rs6;
 for(u32 rep=0;rep<MM_REPS;rep++)for(u32 length=0;length<2;length++){
  u32 n=length?16:4;MmInvocation* warm=(MmInvocation*)N_WARM;MmInvocation* observed=(MmInvocation*)N_TIMED;
  u32 warm_value=native_invoke(k,1,rs2,warm,rs6);
  u32 line=R16(0x04000006),before=now();
  u32 value=native_invoke(k,n,rs2,observed,rs6);
  u32 ticks=now()-before,endline=R16(0x04000006);
  // Shared output writes and checksums are outside the timed call.
  MmSample* s=&out.samples[rep][length];s->loops=n;s->ticks=ticks;
  s->warm_value=warm_value;s->value=value;s->warm=*warm;s->timed=*observed;
  s->warm_checksum=fnv(warm,sizeof *warm);s->checksum=fnv(observed,sizeof *observed);
  s->start_line=line;s->end_line=endline;
  if(warm_value!=3u*rs6||value!=3u*rs6||
     !mm_valid_invocation(warm,1,rs2,rs6,out.entry,out.wrapper_return)||
     !mm_valid_invocation(observed,n,rs2,rs6,out.entry,out.wrapper_return))out.error|=16;
 }
 context(&out.after);
 memcpy(out.code_after,(void*)out.entry,out.size);
 if(memcmp(out.code_before,out.code_after,out.size))out.error|=32;
finish:
 __asm__ volatile("":::"memory");(void)*(volatile u32*)&out.magic;
 R16(0x04000180)=2<<8;while(IPCFIFOCNT&FIFO_SEND_FULL){}IPCFIFOSEND=command;
}
int main(void)
{
 memcpy((void*)N_PRIVATE,captured_kernel,272);
 memcpy((void*)N_WRAPPER,captured_wrapper,100);
 EXMEMCNT=0xe880;IE=0x71061;IF=0xffffffffu;IME=1;
 R16(0x04000308)=0x1204;R16(0x04000304)=1;
 for(u32 i=0;i<16;i++)R32(0x04000400+i*16)=0;
 R16(0x04000500)=0;
 TM_CNT_H(0)=0;TM_CNT_H(1)=0;TM_CNT_L(0)=0;TM_CNT_L(1)=0;
 TM_CNT_H(1)=0x84;TM_CNT_H(0)=0x80;
 IPCSYNC=0;IPCFIFOCNT=FIFO_ENABLE|FIFO_SEND_CLEAR|FIFO_ERROR;
 for(;;){while(IPCFIFOCNT&FIFO_RECV_EMPTY){}u32 c=IPCFIFORECV;measure(c);}
}
