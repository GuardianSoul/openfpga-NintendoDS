/* Simulation-only caller/idle-ARM7 adapter. No timing fix or expected-time delay. */
#include "protocol.h"
#define OUT ((volatile struct Result*)RESULT)
typedef char fits_below_stack[(RESULT+sizeof(struct Result)<0x02ff3000)?1:-1];
static u32 hash_word(u32 h,u32 w){for(unsigned b=0;b<4;b++){h^=(w>>(8*b))&255;h*=16777619u;}return h;}
static void cp15(volatile u32*p){
#define GET(i,a,b,c) __asm__ volatile("mrc p15,0,%0," #a "," #b "," #c:"=r"(p[i]))
 GET(0,c1,c0,0);GET(1,c2,c0,0);GET(2,c2,c0,1);GET(3,c3,c0,0);
 GET(4,c5,c0,2);GET(5,c5,c0,3);GET(6,c9,c1,0);GET(7,c9,c1,1);
 GET(8,c6,c0,0);GET(9,c6,c1,0);GET(10,c6,c2,0);GET(11,c6,c3,0);
 GET(12,c6,c4,0);GET(13,c6,c5,0);GET(14,c6,c6,0);GET(15,c6,c7,0);
#undef GET
}
static void readable(volatile u32*p){p[0]=R16(0x0400010a);p[1]=R16(0x04000108);p[2]=R32(0x04000000);p[3]=R16(0x04000008);p[4]=R16(0x04000004)&0xfff8;}
static u32 active(unsigned id,volatile u32*errors){u32 h=2166136261u;for(unsigned i=0;i<kernel_words[id];i++){u32 actual=R32(CODE+4*i);h=hash_word(h,actual);if(actual!=kernels[id][i])(*errors)++;}return h;}
void driver(void){
 volatile struct Result*r=OUT;for(unsigned i=0;i<sizeof(*r)/4;i++)((volatile u32*)r)[i]=0;r->magic=MAGIC;r->version=1;
 R32(MARKER)=0;R32(CONTEXT+16)=0x04000108;
 R32(0x04000000)=0;R16(0x04000008)=0;R16(0x04000004)=8;
 R16(0x04000102)=0;R16(0x04000106)=0;R16(0x04000100)=0;R16(0x04000104)=0;R16(0x04000106)=0x84;R16(0x04000102)=0x80;R16(0x0400010a)=0;
 for(unsigned id=0;id<4;id++){
  for(unsigned w=0;w<kernel_words[id];w++)R32(CODE+4*w)=kernels[id][w];
  cp15(r->cp15[id][0]);for(unsigned c=0;c<16;c++)if(r->cp15[id][0][c]!=expected_cp15[c])r->errors++;
  for(unsigned rep=0;rep<16;rep++){
   unsigned row=id*16+rep;volatile struct Trial*t=&r->trials[row];t->id=id;t->rep=rep;
   readable(t->before);t->code_before=active(id,&t->error);
   // Marker is DTCM only and precedes timer start. It adds no operation to
   // the unchanged ITCM kernel or between its timer accesses.
   #ifdef ADAPTER_CODE_MUTANT
   if(!row)R32(CODE+4*4)=0xe2800000; // executed ADD r0,r0,#0 instead of settle MOVr8,r8
#endif
   R32(MARKER)=row+1;invoke(expected[row].cpsr);R32(MARKER)=0;
   t->entry_cpsr=R32(CONTEXT+20);for(unsigned v=0;v<4;v++)t->r[v]=R32(CONTEXT+4*v);
   readable(t->after);t->code_after=active(id,&t->error);
   for(unsigned c=0;c<5;c++)if(c!=1&&(t->before[c]!=expected[row].before[c]||t->after[c]!=expected[row].after[c]))t->error++;
   if((t->entry_cpsr&255)!=0xdf||R32(CONTEXT+24)!=0)t->error++;
   if(t->r[2]!=t->r[3])t->error++;
   // Raw intervals are NEVER made functional pass/fail bits here.
   r->errors+=t->error;r->rows=row+1;
  }
  for(unsigned w=0;w<kernel_words[id];w++)r->live_code[id][w]=R32(CODE+4*w);
  cp15(r->cp15[id][1]);for(unsigned c=0;c<16;c++)if(r->cp15[id][1][c]!=expected_cp15[c])r->errors++;
  r->cases=id+1;
 }
 r->done=1;for(unsigned i=0;i<sizeof(*r)/4;i++)R32(DUMP+i*4)=((volatile u32*)r)[i];
 R32(0x023f0000)=0x52545344;R32(0x023f0004)=3;R32(0x023f0008)=(!r->errors&&r->rows==64&&r->cases==4)?7:0;
 R32(0x023f0010)=r->rows;R32(0x023f0014)=r->cases;R32(0x023f0018)=r->errors;R32(0x023f000c)=1;
 // Captured MAIN is cacheable/writeback. Publish only AFTER all timed rows
 // and snapshots; the native dump reads physical PSRAM, not dirty D-cache.
 for(u32 address=DUMP;address<DUMP+sizeof(*r);address+=32)__asm__ volatile("mcr p15,0,%0,c7,c10,1"::"r"(address):"memory");
 u32 address=0x023f0000;__asm__ volatile("mcr p15,0,%0,c7,c10,1"::"r"(address):"memory");
 address=0;__asm__ volatile("mcr p15,0,%0,c7,c10,4"::"r"(address):"memory");
 adapter_done();
}
