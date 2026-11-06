// Own ARM7, no sound/touch/WiFi servers. Fixed-word private-WRAM kernel
// with sound reading the same/different 32-byte PCM loop; separate WRAMCNT
// ownership sweep. Audio capture is evidence of what was fetched, not an
// assumed priority oracle. No FIFO/DMA or CPU timing assumptions.
#include <calico.h>
#include "wramarb.h"
#define R8(a) (*(volatile u8*)(a))
#define R16(a) (*(volatile u16*)(a))
#define R32(a) (*(volatile u32*)(a))
static WaResult out __attribute__((section(".main.d"),aligned(32)));
static u32 zero[8] __attribute__((section(".main.d"),aligned(32)));
static volatile u32 sample[2][8] __attribute__((aligned(32)));
static u32 now(void)
{
    u16 h=R16(0x04000104),l=R16(0x04000100),h2=R16(0x04000104);
    if(h!=h2){l=R16(0x04000100);h=h2;}
    return ((u32)h<<16)|l;
}
#define R8X(s) s "\n" s "\n" s "\n" s "\n" s "\n" s "\n" s "\n" s "\n"
__attribute__((target("arm"),noinline,aligned(32)))
static u32 kernel(volatile u32* p,u32 n,bool store)
{
    u32 sum;
    if(store) __asm__ volatile(
        "mov r0,#0\nmov r1,#0x1300\n1:\n"
        R8X("str r1,[%2]\neor r1,r1,#0x100\neor r0,r1,r0,ror #1")
        "subs %0,%0,#1\nbne 1b\nmov %1,r0"
        : "+r"(n),"=r"(sum):"r"(p):"r0","r1","cc","memory");
    else __asm__ volatile(
        "mov r0,#0\n1:\n" R8X("ldr r1,[%2]\neor r0,r1,r0,ror #1")
        "subs %0,%0,#1\nbne 1b\nmov %1,r0"
        : "+r"(n),"=r"(sum):"r"(p):"r0","r1","cc","memory");
    return sum;
}
static void stop_sound(void)
{
    R8(0x04000508)=0;
    R32(0x04000400)=0; R32(0x04000410)=0;
    R16(0x04000500)=0;
}
static void sound_case(u32 arg)
{
    // arg: bit0 stores, bit1 n=128 rather than 32, bits2-3 source off/same/different.
    u32 state=(arg>>2)&3,n=arg&2 ? 128 : 32;
    if(state>2){out.error|=1;return;}
    u16 power=R16(0x04000304);
    R16(0x04000304)=power|1;
    for(int c=0;c<16;c++) R32(0x04000400+c*16)=0;
    for(int i=0;i<WA_SAMPLES;i++)out.capture[i]=0x5a5a;
    R16(0x04000500)=0x807f;
    // Channel 1 clocks capture from silent MAIN RAM in every case,
    // including the source-0-off control. It does not touch tested WRAM.
    R32(0x04000414)=(u32)zero;
    R16(0x04000418)=-128; R16(0x0400041a)=0; R32(0x0400041c)=8;
    R32(0x04000410)=0xa8000000u;
    out.source_addr=state==2 ? (u32)sample[1] : (u32)sample[0];
    if(state){
        R32(0x04000404)=out.source_addr;
        R16(0x04000408)=-16; R16(0x0400040a)=0; R32(0x0400040c)=8;
        R32(0x04000400)=0xa8000000u|(32u<<16)|127;
    }
    R32(0x04000510)=(u32)out.capture; R16(0x04000514)=WA_SAMPLES/2;
    R8(0x04000508)=0x84;
    u32 warm=now(); while(now()-warm<2048){}
    out.before=sample[0][0];out.count=n*8;out.start_line=R16(0x04000006);
    u32 t=now();out.checksum=kernel(sample[0],n,arg&1);out.ticks=now()-t;
    out.end_line=R16(0x04000006);out.after=sample[0][0];
    while(R8(0x04000508)&0x80)if(now()-warm>WA_LIMIT){out.cap_timeout=1;break;}
    stop_sound();R16(0x04000304)=power;
}
static void handover(u32 arg)
{
    // Same low 16-bit address as our reserved private word. When WRAMCNT
    // is 0, the ARM7 shared aperture maps back to that reserved private
    // word, not a code/stack address. Mode 3 maps shared WRAM instead.
    volatile u32* p=(volatile u32*)(0x03000000|((u32)sample[0]&0xffff));
    out.status.phase=1;
    u32 t=now();
    while(!out.control.go)if(now()-t>WA_LIMIT){out.error|=2;return;}
    out.status.phase=2;
    out.before=*p;out.count=1024;out.start_line=R16(0x04000006);
    t=now();out.checksum=kernel(p,128,arg&1);out.ticks=now()-t;
    out.end_line=R16(0x04000006);out.after=*p;
}
int main(void)
{
    envReadNvramSettings();keypadStartExtServer();
    lcdSetIrqMask(DISPSTAT_IE_ALL,DISPSTAT_IE_VBLANK);irqEnable(IRQ_VBLANK);
    rtcInit();rtcSyncTime();pmInit();blkInit();
    R16(0x04000102)=0;R16(0x04000106)=0;R16(0x04000100)=0;R16(0x04000104)=0;
    R16(0x04000106)=0x84;R16(0x04000102)=0x80;
    static u32 slots[4];static Mailbox mb;
    mailboxPrepare(&mb,slots,4);pxiSetMailbox(WA_CH,&mb);
    out.magic=WA_MAGIC;out.private_addr=(u32)sample[0];
    while(pmMainLoop()){
        u32 msg;
        while(mailboxTryRecv(&mb,&msg)){
            if((msg&255)==WA_PING){pxiSend(WA_CH,(u32)&out);continue;}
            out.command=msg;out.error=0;out.cap_timeout=0;out.status.phase=0;
            out.ticks=0;out.checksum=0;out.before=0;out.after=0;
            out.source_addr=0;out.count=0;out.start_line=0;out.end_line=0;
            out.private_addr=(u32)sample[0];
            for(int b=0;b<2;b++)for(int i=0;i<8;i++)sample[b][i]=0x12341234u+b*0x11111111u+i;
            ArmIrqState st=armIrqLockByPsr();
            if(((u32)sample&0xff800000u)!=0x03800000u)out.error|=4;
            else if((msg&255)==WA_SOUND)sound_case(msg>>8);
            else if((msg&255)==WA_HANDOVER)handover(msg>>8);
            else out.error|=8;
            out.status.phase=3;
            armIrqUnlockByPsr(st);pxiSend(WA_CH,(u32)&out);
        }
        threadIrqWait(true,IRQ_VBLANK);
    }
    return 0;
}
