#include <calico.h>
#include "protocol.h"
#define R16(a) (*(volatile u16*)(a))
#define R32(a) (*(volatile u32*)(a))
static SlMeta meta __attribute__((aligned(32),section(".main.d")));
static u32 hash(const void*p,unsigned n){const u8*b=p;u32 h=2166136261u;while(n--){h^=*b++;h*=16777619u;}return h;}
int main(void) {
 envReadNvramSettings();keypadStartExtServer();lcdSetIrqMask(DISPSTAT_IE_ALL,DISPSTAT_IE_VBLANK);
 irqEnable(IRQ_VBLANK);rtcInit();rtcSyncTime();pmInit();blkInit();
 R16(0x04000102)=0;R16(0x04000106)=0;R16(0x04000100)=0;R16(0x04000104)=0;
 R16(0x04000106)=0x84;R16(0x04000102)=0x80;
 for(unsigned c=0;c<16;c++){R32(0x04000400+16*c)=0;}
 R16(0x04000500)=0;
 meta.magic=SL_MAGIC;meta.version=1;meta.result_pointer=(u32)&sl_result;
 meta.result_bytes=sizeof sl_result;meta.code_base=(u32)__wram_start;
 meta.code_bytes=__sl_code_end-__wram_start;meta.code_fnv=hash(__wram_start,meta.code_bytes);
 if(meta.code_base<0x03800000||meta.code_base+meta.code_bytes>0x0380f000||meta.code_bytes>SL_CODE_BYTES)meta.error=1;
 static u32 slots[4];static Mailbox mb;mailboxPrepare(&mb,slots,4);pxiSetMailbox(SL_CH,&mb);
 R16(0x04000180)=0;
 while(pmMainLoop()){u32 msg;while(mailboxTryRecv(&mb,&msg)) {
  if(msg==SL_PING)pxiSend(SL_CH,(u32)&meta);
  else if((msg&~1u)==SL_RUN) {
   R16(0x04000180)=1<<8;unsigned attempts=0;
   while((R16(0x04000180)&15)!=1)if(++attempts==1000000u)break;
   if(attempts==1000000u){sl_result.error=8;}else sl_measure(msg&1);
   R16(0x04000180)=2<<8;pxiSend(SL_CH,(u32)&sl_result);
  }
 }threadIrqWait(true,IRQ_VBLANK);}
 return 0;
}
