// New-only SDK envelope for CPU-owned PIC fetch kernels (6b001f58).
#include "../common/hwref.h"
#include "protocol.h"
#include "kernels.h"
#include <stdio.h>
#include <string.h>
extern u32 af_quiet(void);
extern unsigned char __itcm_start[],__itcm_end[];
static Mailbox mb;
static u32 slots[4];
static AfResult result __attribute__((aligned(32)));
static u8 helper_copy[32768] __attribute__((aligned(32)));
static u32 reply(void)
{
 u32 msg,before=now32();
 while(!mailboxTryRecv(&mb,&msg))if(now32()-before>AF_TIMEOUT)return AF_BAD;
 return msg;
}
static u32 request(u32 command)
{
 u32 stale;while(mailboxTryRecv(&mb,&stale)){}
 pxiSend(AF_CH,command);return reply();
}
int main(void)
{
 hw_init("arm7fetch v1 - new-only N/S and revisit question");
 mailboxPrepare(&mb,slots,4);pxiSetMailbox(AF_CH,&mb);
 u32 pointer=request(AF_PING);
 if(pointer==AF_BAD||(pointer>>24)!=2||(pointer&31)){
  hw_status("ARM7 probe did not return a valid result pointer");hw_done();
 }
 u32 readable_pointer=(pointer&0x003fffffu)|0x02000000u; // ARM9 MPU permits the canonical MAIN alias.
 u32 helper_size=(u32)(__itcm_end-__itcm_start);
 if(!helper_size||helper_size>sizeof helper_copy){hw_status("ITCM snapshot bounds invalid");hw_done();}
 memcpy(helper_copy,__itcm_start,helper_size);
 hw_write("arm7fetch_v1_helper_itcm.bin",helper_copy,helper_size);
 Buf info={0};buf_printf(&info,"arm7fetch v1; built " __DATE__ " " __TIME__ "\nCPU kernels6b001f58;18 cases, private-WRAM originals and distinct aligned4096-byte MAIN slots. Per-call warmup1 then timed4/16 loops,5 independent samples each; all warm/timed checksums retained. ARM7 TM0+TM1 F/1, IRQ masked across each sample block. ARM9 GO and completion wait in ITCM with IRQ masked: no MAIN instruction/data polling, only IPCSYNC/timer I/O and local ITCM literals. Shared results written outside timed intervals. No framebuffer/DMA/audio stress; SDK block/keypad/RTC services only outside the block. Ring units are whole rounds including SUBS/checksum ADD and2/3 branches; no isolated-B price or bookkeeping subtraction. Fresh FAT directory required per producer identity. No DS law, card staging or physical deployment implied.\n");
 buf_write(&info,"arm7fetch_v1_info.txt");
 buf_printf(&info,"field,value_hex\nhelper_entry,%08lx\nitcm_base,%08lx\nitcm_bytes,%08lx\nresult_pointer,%08lx\nresult_bytes,%08lx\nresult_arm9_alias,%08lx\n",
  (unsigned long)af_quiet,(unsigned long)__itcm_start,(unsigned long)helper_size,(unsigned long)pointer,(unsigned long)sizeof result,(unsigned long)readable_pointer);
 buf_write(&info,"arm7fetch_v1_setup.csv");
 hw_csv_header("arm7fetch_v1.csv","case_id,name,kind,offset,stride,nodes,region,rep,loops,ticks,warm_checksum,checksum,checksum_per_loop,start_line,end_line,entry,body,end,error\n");
 // Both engines forced blank before timed work. Console restoration is last.
 R_DISPCNT=0x10080;REG32(0x04001000)=0x10080;
 for(u32 id=0;id<AF_CASES;id++)for(u32 region=0;region<2;region++){
  char key[40];snprintf(key,sizeof key,"k%02lu_r%lu",(unsigned long)id,(unsigned long)region);
  if(!hw_step_begin("arm7fetch_v1_progress.txt",key))continue;
  u32 stale;while(mailboxTryRecv(&mb,&stale)){}
  REG16(0x04000180)=0;
  pxiSend(AF_CH,AF_RUN|(id<<8)|(region<<16));
  u32 quiet_status=af_quiet();
  if(quiet_status){
   // ARM7 might still have IRQs masked: do not risk a blocking SD write.
   consoleDemoInit();hw_status("Quiet helper timeout %lu; START remains unmeasured",(unsigned long)quiet_status);hw_done();
  }
  u32 returned=reply();
  if(returned!=pointer){consoleDemoInit();hw_status("Unexpected ARM7 response; START remains unmeasured");hw_done();}
  armDCacheInvalidate((void*)readable_pointer,sizeof result);
  memcpy(&result,(const void*)readable_pointer,sizeof result);
  if(result.magic!=AF_MAGIC||result.version!=AF_VERSION||result.case_id!=id||result.region!=region){
   consoleDemoInit();hw_status("Result identity invalid; START remains unmeasured");hw_done();
  }
  char name[80];snprintf(name,sizeof name,"arm7fetch_v1_k%02lu_r%lu.bin",(unsigned long)id,(unsigned long)region);
  bool saved=hw_write(name,&result,sizeof result);
  Buf csv={0};
  for(u32 rep=0;rep<AF_REPS;rep++)for(u32 length=0;length<2;length++){
   const AfSample* s=&result.samples[rep][length];
   buf_printf(&csv,"%lu,%s,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%08lx,%08lx,%08lx,%lu\n",
    (unsigned long)id,result.name,(unsigned long)result.kind,(unsigned long)result.offset,(unsigned long)result.stride,(unsigned long)result.nodes,
    (unsigned long)region,(unsigned long)rep,(unsigned long)s->loops,(unsigned long)s->ticks,(unsigned long)s->warm_checksum,
    (unsigned long)s->checksum,(unsigned long)result.checksum_per_loop,(unsigned long)s->start_line,(unsigned long)s->end_line,
    (unsigned long)result.entry,(unsigned long)result.body,(unsigned long)result.end,(unsigned long)result.error);
  }
  saved=buf_append(&csv,"arm7fetch_v1.csv")&&saved;
  if(saved&&!result.error)hw_step_done("arm7fetch_v1_progress.txt",key);
 }
 consoleDemoInit();hw_done();
}
