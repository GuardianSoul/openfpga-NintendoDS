#include "protocol.h"
volatile u32 native_sp_before,native_sp_after,native_cpsr;
static u32 fnv(const void*p,u32 bytes){const u8*b=p;u32 h=2166136261u;while(bytes--)h=(h^*b++)*16777619u;return h;}
static u32 expected(u32 id,u32 n){return id==0?18+64*n:id==2?AT_INITIAL:id==4?AT_VALUE:id==6?(AT_INITIAL&65535):18;}
static void init(void){for(u32 i=0;i<8;i++){((u32*)0x038039a0)[i]=AT_GUARD;N_SCRATCH[1024+i]=AT_GUARD;}for(u32 i=0;i<1024;i++)N_SCRATCH[i]=AT_INITIAL;}
static u32 scratch_check(u32 id,u32 n){u32 error=0;for(u32 i=0;i<8;i++)if(((u32*)0x038039a0)[i]!=AT_GUARD||N_SCRATCH[1024+i]!=AT_GUARD)error|=1;for(u32 i=0;i<1024;i++){u32 e=AT_INITIAL;if((id==8&&i<64*n)||(!i&&(id==3||id==5)))e=AT_VALUE;if(!i&&id==7)e=(AT_INITIAL&0xffff0000)|(AT_VALUE&65535);if(N_SCRATCH[i]!=e)error|=2;}return error;}
static __attribute__((noinline)) void measure(u32 id){
 AtResult*out=N_RESULT;const NativeCase*c=&native_cases[id];memset(out,0,sizeof *out);
 out->magic=AT_MAGIC;out->version=1;out->id=id;out->entry=c->entry;out->body=c->body;out->end=c->end;out->code_bytes=c->end-(c->entry&~1u);out->scratch=(u32)N_SCRATCH;out->guard_before=(u32)(N_SCRATCH-8);out->guard_after=(u32)(N_SCRATCH+1024);
 out->code_before=fnv((void*)(c->entry&~1u),out->code_bytes);memcpy(out->code,(void*)(c->entry&~1u),out->code_bytes);if(out->code_before!=c->fnv)out->error=64;
 (void)*(volatile u32*)&out->magic;IPCSYNC=1<<8;u32 start=n_clock();while((IPCSYNC&15)!=1)if(n_clock()-start>AT_TIMEOUT){out->error|=4;goto done;}
 for(u32 rep=0;rep<5;rep++)for(u32 length=0;length<2;length++){
  AtSample*s=&out->samples[rep][length];s->loops=length?16:4;init();
  s->warm_return=native_invoke(c->entry,1,(u32)N_SCRATCH,0);s->sp_before=native_sp_before;s->cpsr=native_cpsr;
  u32 before=n_clock();s->returned=native_invoke(c->entry,s->loops,(u32)N_SCRATCH,0);s->ticks=n_clock()-before;s->sp_after=native_sp_after;s->scratch_fnv=fnv(N_SCRATCH,4096);
  if(s->warm_return!=expected(id,1)||s->returned!=expected(id,s->loops))s->error|=8;
  s->error|=scratch_check(id,s->loops);if(s->sp_before!=N_SP||s->sp_after!=N_SP||!(s->cpsr&0x80))s->error|=16;
  init();native_invoke(c->entry,s->loops,(u32)N_SCRATCH,(u32)s->signature);
  u32 e[7]={expected(id,s->loops),(u32)N_SCRATCH,AT_VALUE,0,N_SP-20,0,(u32)N_SCRATCH+(id==8?64*s->loops*4:0)};
  for(u32 r=0;r<7;r++)if(s->signature[r]!=e[r])s->error|=32;
  out->error|=s->error;
 }
 memcpy(out->scratch_final,N_SCRATCH,4096);out->code_after=fnv((void*)(c->entry&~1u),out->code_bytes);if(out->code_after!=out->code_before)out->error|=64;
done:
 (void)*(volatile u32*)&out->magic;IPCSYNC=2<<8;while(IPCFIFOCNT&FIFO_SEND_FULL){}IPCFIFOSEND=id;
}
int main(void){
 for(u32 i=0;i<9;i++)memcpy((void*)(native_cases[i].entry&~1u),native_cases[i].blob,native_cases[i].end-(native_cases[i].entry&~1u));
 for(u32 i=0;i<16;i++)R32(0x04000400+i*16)=0;R16(0x04000500)=0;
 TM_CNT_H(0)=0;TM_CNT_H(1)=0;TM_CNT_L(0)=0;TM_CNT_L(1)=0;TM_CNT_H(1)=0x84;TM_CNT_H(0)=0x80;
 IPCSYNC=0;IPCFIFOCNT=FIFO_ENABLE|FIFO_SEND_CLEAR|FIFO_ERROR;
 for(;;){while(IPCFIFOCNT&FIFO_RECV_EMPTY){}u32 id=IPCFIFORECV;if(id<9)measure(id);}
}
