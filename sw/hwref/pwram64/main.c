#include "../common/hwref.h"
#include "validate.h"
#include <stdio.h>
#include <string.h>
extern u32 pw_quiet(void);
extern unsigned char __itcm_start[],__itcm_end[];
static Mailbox mb;static u32 slots[4];
static PwResult result __attribute__((aligned(32)));
static u8 journal[PW_CASES],helper_copy[32768] __attribute__((aligned(32)));
static u32 complete,fresh,resumed,failed,interrupted;
static void finish(const char* why,bool safe) __attribute__((noreturn));
static void finish(const char* why,bool safe) {
 bool ok=!why&&complete==PW_CASES&&fresh+resumed==PW_CASES&&!failed&&!interrupted;
 char text[256];snprintf(text,sizeof text,"status=%s\ncomplete=%lu\nnew=%lu\nresumed=%lu\nfailed=%lu\ninterrupted=%lu\n",ok?"SUCCESS":"INCOMPLETE",(unsigned long)complete,(unsigned long)fresh,(unsigned long)resumed,(unsigned long)failed,(unsigned long)interrupted);
 if(safe&&!hw_write("pwram64_v1_completion.txt",text,strlen(text))){ok=false;why="Completion write failed";}
 consoleDemoInit();consoleClear();hw_status("PWRAM64 %s\ncomplete %lu/13\nnew %lu resumed %lu\nfailed %lu interrupted %lu",ok?"SUCCESS":"FAILURE",(unsigned long)complete,(unsigned long)fresh,(unsigned long)resumed,(unsigned long)failed,(unsigned long)interrupted);if(why)hw_status("%s",why);hw_done();
}
static void fail(const char* why,bool safe) __attribute__((noreturn));
static void fail(const char* why,bool safe){failed++;finish(why,safe);}
static bool read_journal(void) {
 FILE* f=fopen(HWREF_DIR "/pwram64_v1_progress.txt","rb");if(!f)return true;
 char line[64],verb[12],extra;unsigned id,next=0,last=0;bool ok=true;
 while(fgets(line,sizeof line,f)) {
  if(sscanf(line,"%11s k%02u %c",verb,&id,&extra)!=2||id>=PW_CASES){ok=false;break;}
  char exact[64];snprintf(exact,sizeof exact,"%s k%02u\n",verb,id);if(strcmp(exact,line)){ok=false;break;}
  if(!strcmp(verb,"start")&&id==next&&!journal[id]){journal[id]=1;last=id;next++;}
  else if(!strcmp(verb,"done")&&id==last&&journal[id]==1)journal[id]=2;
  else {ok=false;break;}
 }
 if(ferror(f)){ok=false;}
 fclose(f);return ok;
}
static u32 reply(void){u32 msg,start=now32();while(!mailboxTryRecv(&mb,&msg))if(now32()-start>PW_TIMEOUT)return PW_BAD;return msg;}
static bool saved(u32 id) {
 char path[160];snprintf(path,sizeof path,HWREF_DIR "/pwram64_v1_k%02lu.bin",(unsigned long)id);FILE* f=fopen(path,"rb");if(!f)return false;
 size_t n=fread(&result,1,sizeof result,f);int extra=fgetc(f);bool ok=!ferror(f);fclose(f);return ok&&n==sizeof result&&extra==EOF&&pw_valid(&result,id);
}
static __attribute__((target("arm"),noinline)) void setup(Buf* b)
{
 u32 cpsr,c1,c2d,c2i,c3,dtcm,itcm;
 __asm__ volatile("mrs %0,cpsr":"=r"(cpsr));
 __asm__ volatile("mrc p15,0,%0,c1,c0,0":"=r"(c1));
 __asm__ volatile("mrc p15,0,%0,c2,c0,0":"=r"(c2d));
 __asm__ volatile("mrc p15,0,%0,c2,c0,1":"=r"(c2i));
 __asm__ volatile("mrc p15,0,%0,c3,c0,0":"=r"(c3));
 __asm__ volatile("mrc p15,0,%0,c9,c1,0":"=r"(dtcm));
 __asm__ volatile("mrc p15,0,%0,c9,c1,1":"=r"(itcm));
 buf_printf(b,"cpsr9,%08lx\nc1,%08lx\nc2d,%08lx\nc2i,%08lx\nc3,%08lx\ndtcm,%08lx\nitcm,%08lx\n",(unsigned long)cpsr,(unsigned long)c1,(unsigned long)c2d,(unsigned long)c2i,(unsigned long)c3,(unsigned long)dtcm,(unsigned long)itcm);
#define REGION(n) do {u32 v;__asm__ volatile("mrc p15,0,%0,c6,c" #n ",0":"=r"(v));buf_printf(b,"region" #n ",%08lx\n",(unsigned long)v);}while(0)
 REGION(0);REGION(1);REGION(2);REGION(3);REGION(4);REGION(5);REGION(6);REGION(7);
#undef REGION
 buf_printf(b,"wramcnt,%08lx\nexmemcnt9,%08lx\nime9,%08lx\nie9,%08lx\ndispcntA,%08lx\ndispcntB,%08lx\n",
  (unsigned long)*(volatile u8*)0x04000247,(unsigned long)REG16(0x04000204),(unsigned long)REG32(0x04000208),(unsigned long)REG32(0x04000210),(unsigned long)R_DISPCNT,(unsigned long)REG32(0x04001000));
}
int main(void) {
 hw_init("private WRAM64 - new-only placement contract");if(!hw_fat_ok)fail("SD unavailable",false);
 const char binding[]=PW_BUILD_ID "\n";char old[sizeof binding+1]={0};FILE* f=fopen(HWREF_DIR "/pwram64_v1_build.txt","rb");
 if(f){size_t n=fread(old,1,sizeof old,f);fclose(f);if(n!=sizeof binding-1||memcmp(old,binding,n))fail("Different producer build",false);}
 else if(!hw_write("pwram64_v1_build.txt",binding,sizeof binding-1))fail("Build write failed",false);
 if(!read_journal())fail("Invalid journal",false);
 mailboxPrepare(&mb,slots,4);pxiSetMailbox(PW_CH,&mb);pxiSend(PW_CH,PW_PING);u32 pointer=reply();
 if(pointer==PW_BAD||pointer>>24!=2||pointer%32)fail("ARM7 pointer invalid",false);
 u32 alias=(pointer&0x003fffffu)|0x02000000u;if(alias+sizeof result>0x02400000)fail("ARM7 span invalid",false);
 for(u32 id=0;id<PW_CASES;id++)if(journal[id]==2){if(saved(id)){complete++;resumed++;}else failed++;}
 // A resumed directory is validated before any auxiliary file is rewritten.
 if(failed)finish("Saved DONE data invalid",true);
 u32 helper_size=__itcm_end-__itcm_start;if(!helper_size||helper_size>sizeof helper_copy)fail("ITCM size invalid",false);
 if(!resumed){memcpy(helper_copy,__itcm_start,helper_size);if(!hw_write("pwram64_v1_helper_itcm.bin",helper_copy,helper_size))fail("Helper write failed",false);}
 REG8(0x04000247)=3;R_DISPCNT=0x10080;REG32(0x04001000)=0x10080;
 if(!resumed){Buf info={0};buf_printf(&info,"field,value_hex\nhelper_entry,%08lx\nitcm_base,%08lx\nitcm_bytes,%08lx\nresult_pointer,%08lx\nresult_arm9_alias,%08lx\n",(unsigned long)pw_quiet,(unsigned long)__itcm_start,(unsigned long)helper_size,(unsigned long)pointer,(unsigned long)alias);setup(&info);if(!buf_write(&info,"pwram64_v1_setup.csv"))fail("Setup write failed",false);}
 for(u32 id=0;id<PW_CASES;id++) {
  if(journal[id]==2)continue;
  if(journal[id]==1){interrupted++;continue;}
  char key[16];snprintf(key,sizeof key,"k%02lu",(unsigned long)id);
  if(!hw_step_begin("pwram64_v1_progress.txt",key)){failed++;continue;}
  u32 stale;while(mailboxTryRecv(&mb,&stale)){}REG16(0x04000180)=0;pxiSend(PW_CH,PW_RUN|(id<<8));
  if(pw_quiet()){interrupted++;finish("Quiet timeout; START retained",false);}
  if(reply()!=pointer)fail("ARM7 response differs",false);
  armDCacheInvalidate((void*)alias,sizeof result);memcpy(&result,(void*)alias,sizeof result);
  char name[64];snprintf(name,sizeof name,"pwram64_v1_k%02lu.bin",(unsigned long)id);
  bool written=hw_write(name,&result,sizeof result);
  if(written&&pw_valid(&result,id)&&saved(id)&&hw_step_done("pwram64_v1_progress.txt",key)){complete++;fresh++;journal[id]=2;}else failed++;
 }
 finish(NULL,true);
}
