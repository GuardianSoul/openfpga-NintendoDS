#include "protocol.h"
static void words(void*d,const void*s,u32 n){volatile u32*a=d;const volatile u32*b=s;for(u32 i=0;i<n/4;i++)a[i]=b[i];}
static __attribute__((noinline)) void context(void){
 __asm__ volatile(
 "ldr r0,=0x04000033\nmcr p15,0,r0,c6,c0,0\nldr r0,=0x0200002b\nmcr p15,0,r0,c6,c1,0\nmov r0,#0\nmcr p15,0,r0,c6,c2,0\nmcr p15,0,r0,c6,c3,0\nldr r0,=0x02ff001f\nmcr p15,0,r0,c6,c4,0\nldr r0,=0x01ff801d\nmcr p15,0,r0,c6,c5,0\nldr r0,=0xffff001d\nmcr p15,0,r0,c6,c6,0\nmov r0,#0x17\nmcr p15,0,r0,c6,c7,0\n"
 "mov r0,#0x42\nmcr p15,0,r0,c2,c0,0\nmcr p15,0,r0,c2,c0,1\nmov r0,#2\nmcr p15,0,r0,c3,c0,0\nldr r0,=0x06330033\nmcr p15,0,r0,c5,c0,2\nldr r0,=0x66600060\nmcr p15,0,r0,c5,c0,3\nmov r0,#0\nmcr p15,0,r0,c7,c5,0\nmcr p15,0,r0,c7,c6,0\nmcr p15,0,r0,c7,c10,4\nldr r0,=0x0005507d\nmcr p15,0,r0,c1,c0,0\n":::"r0","memory");
}
static void read_context(volatile u32*p){u32 v;
#define READ(i,op) __asm__ volatile(op:"=r"(v));p[i]=v
 READ(0,"mrc p15,0,%0,c1,c0,0");READ(1,"mrc p15,0,%0,c9,c1,0");READ(2,"mrc p15,0,%0,c9,c1,1");READ(3,"mrc p15,0,%0,c2,c0,0");READ(4,"mrc p15,0,%0,c2,c0,1");READ(5,"mrc p15,0,%0,c3,c0,0");READ(6,"mrc p15,0,%0,c5,c0,2");READ(7,"mrc p15,0,%0,c5,c0,3");
 READ(8,"mrc p15,0,%0,c6,c0,0");READ(9,"mrc p15,0,%0,c6,c1,0");READ(10,"mrc p15,0,%0,c6,c2,0");READ(11,"mrc p15,0,%0,c6,c3,0");READ(12,"mrc p15,0,%0,c6,c4,0");READ(13,"mrc p15,0,%0,c6,c5,0");READ(14,"mrc p15,0,%0,c6,c6,0");READ(15,"mrc p15,0,%0,c6,c7,0");
#undef READ
}
__attribute__((naked,noinline,noreturn))void native42_done(void){__asm__ volatile("b native42_done");}
int main(void){
 POWCNT1=0x820f;DISPCNT_A=1<<7;DISPCNT_B=1<<7;WRAMCNT=3;
 TM_CNT_H(0)=0;TM_CNT_H(1)=0;TM_CNT_L(0)=0;TM_CNT_L(1)=0;TM_CNT_H(1)=0x84;TM_CNT_H(0)=0x80;
 memcpy((void*)0x01ff8000,captured_helper,(u32)captured_helper_end-(u32)captured_helper);words((void*)0x02220000,(void*)0x01ff8000,2128);
 IPCSYNC=0;IPCFIFOCNT=FIFO_ENABLE|FIFO_SEND_CLEAR|FIFO_ERROR;
 N_STATUS[0]=AT_MAGIC;N_STATUS[1]=0;N_STATUS[2]=0;u32 errors=0;
 for(u32 i=0;i<9;i++){
  while(IPCFIFOCNT&FIFO_SEND_FULL){}IPCFIFOSEND=i;
  volatile u32 before[16],after[16];context();read_context(before);
  u32 quiet=((u32(*)(void))0x01ff8020)();read_context(after);
  __asm__ volatile("ldr r0,=0x00055079\nmcr p15,0,r0,c1,c0,0":::"r0","memory");
  while(IPCFIFOCNT&FIFO_RECV_EMPTY){}u32 reply=IPCFIFORECV;
  words((void*)(N_CONTEXT+i*32),(void*)before,64);words((void*)(N_CONTEXT+i*32+16),(void*)after,64);
  words(N_RECORD(i),N_RESULT9,sizeof(AtResult));N_STATUS[4+i]=quiet;
  if(quiet||reply!=i||N_RECORD(i)->error||N_RECORD(i)->id!=i||N_RECORD(i)->magic!=AT_MAGIC)errors++;
  N_STATUS[1]=i+1;N_STATUS[2]=errors;
 }
 words((void*)0x02221000,(void*)0x01ff8000,2128);
 volatile u32*v=(volatile u32*)0x023f0000;v[0]=0x52545344;v[1]=1;v[2]=errors?0:1;v[4]=N_STATUS[1];v[3]=1;
 __asm__ volatile("mov r0,#0\nmcr p15,0,r0,c7,c10,4":::"r0","memory");(void)v[3];native42_done();
}
