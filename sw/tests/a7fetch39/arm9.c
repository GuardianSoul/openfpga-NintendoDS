#include "protocol.h"
extern const u32 captured_helper[];
extern const u32 captured_helper_end[];
/* Untimed host export only. Word copies avoid four separate uncached
   instruction/data transactions per output byte in the minimal runtime. */
__attribute__((noinline)) static void copy_words(void *destination,const void *source,u32 bytes) {
 volatile u32 *d=destination;const volatile u32 *s=source;
 for(u32 i=0;i<bytes/4;i++)d[i]=s[i];
}
__attribute__((naked,noinline,noreturn)) void af_native_done(void) {
 __asm__ volatile("b af_native_done");
}
int main(void) {
 /* Both engines forced blank; IRQs masked by crt0. DTCM stack means the
    captured helper uses only private memory and I/O between GO and DONE. */
 POWCNT1=0x820f;DISPCNT_A=1<<7;DISPCNT_B=1<<7;
 WRAMCNT=3;
 TM_CNT_H(0)=0;TM_CNT_H(1)=0;TM_CNT_L(0)=0;TM_CNT_L(1)=0;
 TM_CNT_H(1)=0x84;TM_CNT_H(0)=0x80;
 memcpy((void *)0x01ff8000,captured_helper,(u32)captured_helper_end-(u32)captured_helper);
 copy_words((void *)0x02231000,(const void *)0x01ff8000,2024);
 IPCSYNC=0;IPCFIFOCNT=FIFO_ENABLE|FIFO_SEND_CLEAR|FIFO_ERROR;
 AF_STATUS[0]=AF_MAGIC;AF_STATUS[1]=0;AF_STATUS[2]=0;
 u32 errors=0;
 for(u32 i=0;i<AF_CASES*2;i++) {
  while(IPCFIFOCNT&FIFO_SEND_FULL){}
  IPCFIFOSEND=i;
  u32 quiet=((u32 (*)(void))0x01ff8020)();
  while(IPCFIFOCNT&FIFO_RECV_EMPTY){}
  u32 reply=IPCFIFORECV;
  copy_words(AF_RECORD(i),AF_RESULT9,sizeof(AfResult));
  const AfResult *r=AF_RECORD(i);
  AF_STATUS[4+i]=quiet;
  if(quiet||reply!=i||r->error||r->magic!=AF_MAGIC||r->case_id!=i/2||r->region!=(i&1))errors++;
  AF_STATUS[1]=i+1;AF_STATUS[2]=errors;
 }
 copy_words((void *)0x02232000,(const void *)0x01ff8000,2024);
 /* Read the last shared writes before reaching the host's one-shot RAM dump. */
 (void)AF_STATUS[2];
 volatile u32 *verdict=(volatile u32 *)0x023f0000;
 verdict[0]=0x52545344;verdict[1]=1;verdict[2]=errors?0:1;
 verdict[4]=AF_STATUS[1];verdict[3]=1;(void)verdict[3];
 af_native_done();
}
