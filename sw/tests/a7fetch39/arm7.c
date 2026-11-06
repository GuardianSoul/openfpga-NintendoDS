/* Exact captured kernels/addresses; minimal boot and raw FIFO commands replace
   Calico/SD services outside the timed block. The timing wrapper is rebuilt. */
#include "protocol.h"
#include "cases.h"
static u32 fnv(const void *data,u32 size) {
 const u8 *p=data;u32 v=2166136261u;
 for(u32 i=0;i<size;i++)v=(v^p[i])*16777619u;
 return v;
}
__attribute__((noinline)) static void measure(u32 id,u32 region) {
 AfResult *out=AF_RESULT;const AfCase *c=&af_cases[id];
 memset(out,0,sizeof *out);
 out->magic=AF_MAGIC;out->version=AF_VERSION;out->case_id=id;out->region=region;
 for(u32 i=0;i<23&&c->name[i];i++)out->name[i]=c->name[i];
 out->kind=c->kind;out->offset=c->offset;out->stride=c->stride;
 out->nodes=c->nodes;out->checksum_per_loop=c->checksum;
 out->source_entry=c->source;out->source_body=c->body;out->source_end=c->end;
 out->size=c->end-c->source;
 memcpy((void *)c->main,(const void *)c->source,out->size);
 out->source_fnv=fnv((const void *)c->source,out->size);
 out->copy_fnv=fnv((const void *)c->main,out->size);
 out->copy_match=out->source_fnv==out->copy_fnv&&out->source_fnv==c->fnv;
 memcpy(out->code,(const void *)c->source,out->size);
 out->entry=region?c->main:c->source;out->body=out->entry+c->body-c->source;
 out->end=out->entry+out->size;
 if(!out->copy_match)out->error=4;
 __asm__ volatile("":::"memory");(void)*(volatile u32 *)&out->magic;
 IPCSYNC=1<<8;
 u32 before=af_clock();
 while((IPCSYNC&15)!=1)if(af_clock()-before>AF_TIMEOUT){out->error=8;goto finish;}
 if(out->error)goto finish;
 u32 cpsr,masked;
 __asm__ volatile("mrs %0,cpsr\norr %1,%0,#0x80\nmsr cpsr_c,%1":"=&r"(cpsr),"=&r"(masked)::"cc","memory");
 AfKernel k=(AfKernel)out->entry;
 for(u32 rep=0;rep<AF_REPS;rep++)for(u32 length=0;length<2;length++) {
  u32 loops=length?16:4,warm=k(1);
  u32 line=VCOUNT,start=af_clock();
  u32 value=k(loops);
  u32 ticks=af_clock()-start,endline=VCOUNT;
  AfSample *s=&out->samples[rep][length];
  s->loops=loops;s->ticks=ticks;s->warm_checksum=warm;s->checksum=value;
  s->start_line=line;s->end_line=endline;
  if(warm!=c->checksum||value!=c->checksum*loops)out->error|=16;
 }
 __asm__ volatile("msr cpsr_c,%0"::"r"(cpsr):"cc","memory");
finish:
 __asm__ volatile("":::"memory");(void)*(volatile u32 *)&out->magic;
 IPCSYNC=2<<8;
 while(IPCFIFOCNT&FIFO_SEND_FULL){}
 IPCFIFOSEND=(id<<1)|region;
}
int main(void) {
 for(u32 i=0;i<AF_CASES;i++)memcpy((void *)af_cases[i].source,af_cases[i].blob,af_cases[i].end-af_cases[i].source);
 for(u32 i=0;i<16;i++)R32(0x04000400+i*16)=0;
 R16(0x04000500)=0;
 TM_CNT_H(0)=0;TM_CNT_H(1)=0;TM_CNT_L(0)=0;TM_CNT_L(1)=0;
 TM_CNT_H(1)=0x84;TM_CNT_H(0)=0x80;
 IPCSYNC=0;IPCFIFOCNT=FIFO_ENABLE|FIFO_SEND_CLEAR|FIFO_ERROR;
 for(;;) {
  while(IPCFIFOCNT&FIFO_RECV_EMPTY){}
  u32 command=IPCFIFORECV;
  if(command<AF_CASES*2)measure(command>>1,command&1);
 }
}
