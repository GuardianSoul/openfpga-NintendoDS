// Quiet ARM9 MAIN bus: after GO, instruction fetches stay in ITCM and
// data accesses are I/O only until DONE. Timer/IPCSYNC reads remain traffic.
#include "../common/hwref.h"
#include "protocol.h"
static __attribute__((always_inline)) inline u32 clock9(void)
{
 u16 h=REG16(0x04000104),l=REG16(0x04000100),h2=REG16(0x04000104);
 if(h!=h2){l=REG16(0x04000100);h=h2;}return ((u32)h<<16)|l;
}
__attribute__((section(".itcm"),target("arm"),noinline))
u32 mp_quiet(void)
{
 u32 cpsr,masked;
 __asm__ volatile("mrs %0,cpsr\norr %1,%0,#0x80\nmsr cpsr_c,%1":"=&r"(cpsr),"=&r"(masked)::"cc","memory");
 u32 before=clock9(),status=0;
 while((REG16(0x04000180)&15)!=1)if(clock9()-before>MP_TIMEOUT){status=1;goto done;}
 REG16(0x04000180)=1<<8; // GO is issued only after entering quiet ITCM.
 before=clock9();
 while((REG16(0x04000180)&15)!=2)if(clock9()-before>MP_TIMEOUT){status=2;break;}
 REG16(0x04000180)=0;
done:
 __asm__ volatile("msr cpsr_c,%0"::"r"(cpsr):"cc","memory");
 return status;
}
