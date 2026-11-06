/* New standalone measurement. No timing value below is a DS verdict. */
#include <calico.h>
#include <string.h>
#include "protocol.h"
#define R8(a) (*(volatile u8*)(a))
#define R16(a) (*(volatile u16*)(a))
#define R32(a) (*(volatile u32*)(a))
SlResult sl_result __attribute__((aligned(32),section(".main.d")));
static s16 waves[2][16] __attribute__((aligned(32)));
static u32 silence[8] __attribute__((aligned(32)));
static __attribute__((always_inline)) inline u32 clock7(void) {
 u16 h=R16(0x04000104),l=R16(0x04000100),h2=R16(0x04000104);
 if(h!=h2){l=R16(0x04000100);h=h2;}return ((u32)h<<16)|l;
}
static __attribute__((always_inline)) inline void until(u32 target) {
 while((s32)(clock7()-target)<0){}
}
static u32 hash(const void*p,unsigned n) {
 const u8*b=p;u32 h=2166136261u;while(n--){h^=*b++;h*=16777619u;}return h;
}
static __attribute__((always_inline)) inline SlEvent enable(unsigned channel,u32 value) {
 SlEvent e;e.before=clock7();R32(0x04000400+16*channel)=value;
 e.readback=R32(0x04000400+16*channel);e.after=clock7();e.written=value;return e;
}
static __attribute__((always_inline)) inline SlEvent source(u8 value) {
 SlEvent e;e.before=clock7();R8(0x04000508)=value;
 e.readback=R8(0x04000508);e.after=clock7();e.written=value;return e;
}
__attribute__((target("arm"),noinline,aligned(32)))
void sl_measure(unsigned condition) {
 SlResult *o=&sl_result;memset(o,0,sizeof *o);
 o->magic=SL_MAGIC;o->version=1;o->condition=condition;
 o->code_base=(u32)__wram_start;o->code_bytes=__sl_code_end-__wram_start;
 if(condition>1||o->code_bytes>SL_CODE_BYTES){o->error=1;return;}
 for(unsigned i=0;i<16;i++){unsigned c=i<2?0:i-1;waves[0][i]=64*c;waves[1][i]=1024*c;}
 memset(silence,0,sizeof silence);
 for(unsigned u=0;u<2;u++)for(unsigned i=0;i<SL_SAMPLES;i++)o->capture_pcm[u][i]=0x5a5a;
 u16 power=R16(0x04000304);o->power_before=power;R16(0x04000304)=power|1;
 R16(0x04000508)=0;for(unsigned c=0;c<16;c++)R32(0x04000400+16*c)=0;
 if(!(power&1)){u32 t=clock7();until(t+502710u);} /* original15ms settle */
 R16(0x04000500)=0x807f;
 for(unsigned c=0;c<4;c++) {
  R32(0x04000404+16*c)=(u32)((c&1)?(void*)silence:(void*)waves[c/2]);
  R16(0x04000408+16*c)=-(c&1?127:512);
  R16(0x0400040a+16*c)=0;R32(0x0400040c+16*c)=8;
 }
 for(unsigned u=0;u<2;u++) {
  R32(0x04000510+8*u)=(u32)o->capture_pcm[u];
  R16(0x04000514+8*u)=SL_SAMPLES/2;
 }
 ArmIrqState irq=armIrqLockByPsr();
 __asm__ volatile("mrs %0,cpsr\nmov %1,sp":"=r"(o->cpsr),"=r"(o->sp));
 o->code_before=hash(__wram_start,o->code_bytes);
 memcpy(o->code,__wram_start,o->code_bytes);
 o->wave_address[0]=(u32)waves[0];o->wave_address[1]=(u32)waves[1];o->wave_address[2]=(u32)silence;
 memcpy(o->wave,waves,sizeof waves);memcpy(o->silence,silence,sizeof silence);
 o->wave_before=hash(waves,sizeof waves)^hash(silence,sizeof silence);
 o->cap_timer=127;o->voice_timer=512;o->samples=SL_SAMPLES;
 o->clocks[0]=enable(1,0xa8400000);o->clocks[1]=enable(3,0xa8400000);
 until(clock7()+4096u); /* clocks free-run across the entire capture */
 o->capture.before=clock7();R16(0x04000508)=0x8486;
 o->capture.readback=R16(0x04000508);o->capture.after=clock7();o->capture.written=0x8486;
 o->epoch=o->capture.after;
 until(o->epoch+2048u);o->voices[0]=enable(0,0xa8400008);
 until(o->voices[0].before+384u);o->voices[1]=enable(2,0xa8400008);
 until(o->epoch+600000u);o->switches[0]=source(condition?0x84:0x86);
 until(o->epoch+1200000u);o->switches[1]=source(0x86);
 o->completion.before=clock7();
 while(R16(0x04000508)&0x8080)if(clock7()-o->epoch>SL_TIMEOUT){o->error|=2;break;}
 o->completion.readback=R16(0x04000508);o->completion.after=clock7();
 o->finished=o->completion.after;
 for(unsigned c=0;c<4;c++) {
  o->readable[c*4]=R32(0x04000400+16*c);
  o->readable[c*4+1]=R16(0x04000408+16*c);
  o->readable[c*4+2]=R16(0x0400040a+16*c);
  o->readable[c*4+3]=R32(0x0400040c+16*c);
 }
 R16(0x04000508)=0;for(unsigned c=0;c<16;c++)R32(0x04000400+16*c)=0;
 R16(0x04000500)=0;R16(0x04000304)=power;o->power_after=R16(0x04000304);
 o->code_after=hash(__wram_start,o->code_bytes);
 o->wave_after=hash(waves,sizeof waves)^hash(silence,sizeof silence);
 if(o->code_before!=o->code_after||o->wave_before!=o->wave_after)o->error|=4;
 armIrqUnlockByPsr(irq);
}
