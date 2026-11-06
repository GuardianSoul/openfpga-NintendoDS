// Standalone ARM9 controller. Own ARM7 does all timed accesses. Ownership
// is changed only during explicit handover tests; no concurrent ARM9 data
// access to a bank still owned by ARM7 is used as an arbitration proxy.
#include "../common/hwref.h"
#include "../common/mpu_map.h"
#include "wramarb.h"
#include <stdio.h>
#include <stdlib.h>
static Mailbox mb;static u32 slots[4];static WaResult* result;
static u32 request(u32 command,u32 delay,u32* switched,u32* lost,u32* back)
{
    u32 reply;
    while(mailboxTryRecv(&mb,&reply)){}
    if(result){result->control.go=0;armDCacheFlush(&result->control,sizeof result->control);}
    pxiSend(WA_CH,command);
    u32 start=now32();bool released=false;
    while(!mailboxTryRecv(&mb,&reply)){
        if(result && (command&255)==WA_HANDOVER){
            armDCacheInvalidate(&result->status,sizeof result->status);
            u32 phase=result->status.phase;
            if(phase==1 && !released){
                result->control.go=1;armDCacheFlush(&result->control,sizeof result->control);released=true;
            }
            if(phase==2 && !*switched){
                u32 t=now32();while(now32()-t<delay){}
                REG8(0x04000247)=0;*lost=now32()-start; // all shared WRAM to ARM9
                t=now32();while(now32()-t<64){}
                REG8(0x04000247)=3;*back=now32()-start; // all to ARM7 again
                *switched=1;
            }
        }
        if(now32()-start>2u*33513982u)return WA_BAD;
    }
    return reply;
}
static void run(u32 command,u32 rep,u32 delay,Buf* csv)
{
    char key[72];
    snprintf(key,sizeof key,"c%lu_r%lu_d%lu",(unsigned long)command,
             (unsigned long)rep,(unsigned long)delay);
    if(!hw_step_begin("wramarb_progress.txt",key))return;
    char active[96];
    int len=snprintf(active,sizeof active,"start command=%lu rep=%lu delay=%lu\n",
        (unsigned long)command,(unsigned long)rep,(unsigned long)delay);
    hw_write("wramarb_active.txt",active,len);
    u8 saved_mode=REG8(0x04000247);
    HwUncachedMap map;
    u32 shared_address=0,saved_word=0,switched=0,lost=0,back=0;
    if((command&255)==WA_HANDOVER){
        if(!hw_uncached_begin(&map,0x03000000,CP15_PU_32K)){
            hw_status("no unused MPU region for shared WRAM aperture");hw_done();
        }
        // Derive the shared alias of a word explicitly reserved in private
        // WRAM by this ARM7. The mode-0 fallback cannot corrupt its code.
        REG8(0x04000247)=0;
        shared_address=0x03000000|(result->private_addr&0x7fff);
        armDCacheInvalidate((void*)(shared_address&~31u),32);
        saved_word=REG32(shared_address);
        REG32(shared_address)=0x76547654;
        armDCacheFlush((void*)(shared_address&~31u),32);
        REG8(0x04000247)=3;
    }
    u32 ptr=request(command,delay,&switched,&lost,&back);
    if(ptr<0x02000000 || ptr>=0x03000000){
        hw_status("ARM7 timeout/invalid response; reboot. No further bank changes.");
        hw_done();
    }
    ptr=0x02000000|(ptr&0x3fffff);
    if((WaResult*)ptr!=result){hw_status("wrong result pointer");hw_done();}
    armDCacheInvalidate(result,sizeof *result);
    if(result->magic!=WA_MAGIC || result->command!=command || result->status.phase!=3){
        hw_status("invalid completed result; reboot");hw_done();
    }
    u32 shared_after=0;
    if((command&255)==WA_HANDOVER){
        REG8(0x04000247)=0;
        armDCacheInvalidate((void*)(shared_address&~31u),32);
        shared_after=REG32(shared_address);
        REG32(shared_address)=saved_word;
        armDCacheFlush((void*)(shared_address&~31u),32);
        REG8(0x04000247)=saved_mode;
        if(!hw_uncached_end(&map)){hw_status("MPU restore failed");hw_done();}
    }
    buf_printf(csv,"%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu\n",
        (unsigned long)command,(unsigned long)rep,(unsigned long)delay,(unsigned long)result->error,
        (unsigned long)result->ticks,(unsigned long)result->count,(unsigned long)result->checksum,
        (unsigned long)result->before,(unsigned long)result->after,(unsigned long)result->private_addr,
        (unsigned long)result->source_addr,(unsigned long)result->start_line,(unsigned long)result->end_line,
        (unsigned long)result->cap_timeout,(unsigned long)switched,(unsigned long)lost,(unsigned long)back,
        (unsigned long)shared_after,(unsigned long)saved_mode);
    bool saved=true;
    if((command&255)==WA_SOUND){
        char name[64];snprintf(name,sizeof name,"wramarb_%lu_r%lu.bin",(unsigned long)command,(unsigned long)rep);
        saved=hw_write(name,result->capture,sizeof result->capture);
    }
    saved=buf_append(csv,"wramarb.csv") && saved;
    if(saved && !result->error && !result->cap_timeout)hw_step_done("wramarb_progress.txt",key);
    hw_write("wramarb_active.txt","complete\n",9);
}
int main(void)
{
    hw_init("wramarb 1 - unmeasured WRAM arbitration");
    mailboxPrepare(&mb,slots,4);pxiSetMailbox(WA_CH,&mb);
    u32 dummy=0,ptr=request(WA_PING,0,&dummy,&dummy,&dummy);
    if(ptr<0x02000000 || ptr>=0x03000000){hw_status("ARM7 missing");hw_done();}
    ptr=0x02000000|(ptr&0x3fffff);
    if(ptr+sizeof(WaResult)>0x02400000){hw_status("invalid result span");hw_done();}
    result=(WaResult*)ptr;armDCacheInvalidate(result,sizeof *result);
    if(result->magic!=WA_MAGIC || (result->private_addr&0xff800000u)!=0x03800000u){
        hw_status("private WRAM buffer not mapped; inspect linker map");hw_done();
    }
    Buf csv={0};
    buf_printf(&csv,"command,rep,delay,error,arm7_ticks,operations,checksum,before,after,private_addr,source_addr,start_line,end_line,cap_timeout,switched,arm9_loss_ticks,arm9_return_ticks,shared_after,saved_wramcnt\n");
    hw_csv_header("wramarb.csv",csv.p);
    free(csv.p);csv.p=NULL;csv.len=csv.cap=0;
    for(u32 state=0;state<3;state++)for(u32 store=0;store<2;store++)for(u32 size=0;size<2;size++)for(u32 rep=0;rep<4;rep++)
        run(WA_SOUND|((store|(size<<1)|(state<<2))<<8),rep,0,&csv);
    static const u32 delays[]={0,2,4,8,16,32,64};
    for(u32 store=0;store<2;store++)for(unsigned d=0;d<sizeof delays/sizeof delays[0];d++)for(u32 rep=0;rep<4;rep++)
        run(WA_HANDOVER|(store<<8),rep,delays[d],&csv);
    if(csv.len)buf_write(&csv,"wramarb_pending.csv");
    Buf info={0};
    buf_printf(&info,"wramarb 1; built " __DATE__ " " __TIME__ "\nWRAM arbitration probe; raw observations only. Private buffer word0 CPU reads/stores, sound off/same/different WRAM source at channel timer16, channel1 silent MAIN-RAM timer128 capture clock. 32/128 iterations x8 accesses, rolling checksum; stores also toggle value. Four reps and 1024 PCM16 capture samples per sound case. Handover mode3->0->3, seven ARM9 delays, 64-tick mode0 dwell, 1024 ARM7 accesses; phase handshake brackets kernel activity but cannot certify an individual accepted request was in flight. Timers include software overhead. Preserve linker-map proof of private WRAM placement.\n");
    buf_write(&info,"wramarb_info.txt");hw_done();
}
