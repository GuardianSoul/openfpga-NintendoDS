// Same quiet ITCM handshake as the qualified arm7fetch producer.
#include "../common/hwref.h"
#include "protocol.h"
#include <stdio.h>
#include <string.h>
extern u32 mp_quiet(void);
extern unsigned char __itcm_start[],__itcm_end[];
static Mailbox mb;static u32 slots[4];
static MpResult result __attribute__((aligned(32)));
static u8 helper_copy[32768] __attribute__((aligned(32)));
static u32 complete,fresh,resumed,failed,interrupted;
static u8 journal[MP_CASES*2]; // 0 absent,1 START only,2 DONE
#define CSV_HEADER "case_id,rs_hex,region,rep,loops,ticks,warm_value,value,warm_checksum,checksum,start_line,end_line,entry,body,end,error\n"
static u32 fnv(const void* p,u32 n)
{
 const u8* b=p;u32 v=2166136261u;for(u32 i=0;i<n;i++)v=(v^b[i])*16777619u;return v;
}
static bool read_journal(void)
{
 FILE* f=fopen(HWREF_DIR "/a7mulphase_v1_progress.txt","rb");if(!f)return true;
 char line[80],verb[12],key[24],tail;unsigned id,region,next=0,last=0;bool ok=true;
 while(fgets(line,sizeof line,f)){
  if(sscanf(line,"%11s %23s %c",verb,key,&tail)!=2||sscanf(key,"k%02u_r%u%c",&id,&region,&tail)!=2||id>=4||region>=2){ok=false;break;}
  char expected[48];snprintf(expected,sizeof expected,"%s k%02u_r%u\n",verb,id,region);
  if(strcmp(line,expected)){ok=false;break;}
  unsigned k=id*2+region;
  if(!strcmp(verb,"start")&&k==next&&!journal[k]){journal[k]=1;last=k;next++;}
  else if(!strcmp(verb,"done")&&k==last&&journal[k]==1)journal[k]=2;
  else {ok=false;break;}
 }
 if(ferror(f))ok=false;fclose(f);return ok;
}
static bool csv_saved(u32 id,u32 region)
{
 FILE* f=fopen(HWREF_DIR "/a7mulphase_v1.csv","rb");if(!f)return false;
 char line[384],extra;u8 seen[10]={0};bool ok=fgets(line,sizeof line,f)&&!strcmp(line,CSV_HEADER);
 while(ok&&fgets(line,sizeof line,f)){
  unsigned long a[16];int n=sscanf(line,"%lu,%lx,%lu,%lu,%lu,%lu,%lu,%lu,%lx,%lx,%lu,%lu,%lx,%lx,%lx,%lu %c",&a[0],&a[1],&a[2],&a[3],&a[4],&a[5],&a[6],&a[7],&a[8],&a[9],&a[10],&a[11],&a[12],&a[13],&a[14],&a[15],&extra);
  if(n!=16||a[0]>=4||a[2]>=2||a[3]>=5||(a[4]!=4&&a[4]!=16)){ok=false;break;}
  if(a[0]!=id||a[2]!=region)continue;
  unsigned k=a[3]*2+(a[4]==16);const MpSample* s=&result.samples[a[3]][a[4]==16];
  if(seen[k]++||a[1]!=result.rs||a[5]!=s->ticks||a[6]!=s->warm_value||a[7]!=s->value||a[8]!=s->warm_checksum||a[9]!=s->checksum||a[10]!=s->start_line||a[11]!=s->end_line||a[12]!=result.entry||a[13]!=result.body||a[14]!=result.end||a[15])ok=false;
 }
 if(ferror(f))ok=false;fclose(f);for(int i=0;i<10;i++)if(seen[i]!=1)ok=false;return ok;
}
static bool saved_group(u32 id,u32 region)
{
 char path[160];snprintf(path,sizeof path,HWREF_DIR "/a7mulphase_v1_k%02lu_r%lu.bin",(unsigned long)id,(unsigned long)region);
 FILE* f=fopen(path,"rb");if(!f)return false;size_t n=fread(&result,1,sizeof result,f);int extra=fgetc(f);bool ok=!ferror(f);fclose(f);
 static const u32 rs[4]={0x7f,0x7fff,0x7fffff,0x7fffffff};
 if(!ok||n!=sizeof result||extra!=EOF||result.magic!=MP_MAGIC||result.version!=1||result.case_id!=id||result.region!=region||result.error||result.rs!=rs[id]||result.size!=272||result.source_body!=result.source_entry+4||result.source_end!=result.source_entry+272||result.body!=result.entry+4||result.end!=result.entry+272||!result.copy_match||result.source_fnv!=result.copy_fnv)return false;
 if(memcmp(result.code_before,result.code_after,272)||fnv(result.code_before,272)!=result.source_fnv||result.code_before[0]!=0xe3a01003||result.code_before[65]!=0xe2500001||result.code_before[66]!=0x1affffbd||result.code_before[67]!=0xe12fff1e)return false;
 for(int i=1;i<=64;i++)if(result.code_before[i]!=0xe0030291)return false;
 for(int rep=0;rep<5;rep++)for(int length=0;length<2;length++){
  const MpSample* s=&result.samples[rep][length];
  if(s->loops!=(length?16:4)||!s->ticks||s->warm_value!=3*rs[id]||s->value!=3*rs[id]||s->warm_checksum!=fnv(&s->warm,sizeof s->warm)||s->checksum!=fnv(&s->timed,sizeof s->timed))return false;
 }
 return csv_saved(id,region);
}
static void finish(const char* why,bool sd_safe) __attribute__((noreturn));
static void finish(const char* why,bool sd_safe)
{
 bool ok=!why&&complete==8&&fresh+resumed==8&&!failed&&!interrupted;
 char text[256];snprintf(text,sizeof text,"status=%s\ncomplete=%lu\nnew=%lu\nresumed=%lu\nfailed=%lu\ninterrupted=%lu\n",ok?"SUCCESS":"INCOMPLETE",(unsigned long)complete,(unsigned long)fresh,(unsigned long)resumed,(unsigned long)failed,(unsigned long)interrupted);
 if(sd_safe&&!hw_write("a7mulphase_v1_completion.txt",text,strlen(text))){ok=false;failed++;why="Completion record write failed";}
 PrintConsole* screen=consoleDemoInit();consoleSetWindow(screen,0,0,32,24);
 bgSetScroll(screen->bgId,0,0);bgUpdate();consoleClear();
 hw_status("A7MULPHASE %s\ncomplete %lu/8\nnew %lu resumed %lu\nfailed %lu interrupted %lu",ok?"SUCCESS":"FAILURE",(unsigned long)complete,(unsigned long)fresh,(unsigned long)resumed,(unsigned long)failed,(unsigned long)interrupted);
 if(why)hw_status("%s",why);
 hw_done();
}
static void fail(const char* why,bool sd_safe) __attribute__((noreturn));
static void fail(const char* why,bool sd_safe){failed++;finish(why,sd_safe);}
static u32 reply(void)
{
 u32 msg,before=now32();while(!mailboxTryRecv(&mb,&msg))if(now32()-before>MP_TIMEOUT)return MP_BAD;
 return msg;
}
static u32 request(u32 command)
{
 u32 stale;while(mailboxTryRecv(&mb,&stale)){}pxiSend(MP_CH,command);return reply();
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
int main(void)
{
 hw_init("a7mulphase v1 - new-only internal-cycle discriminator");
 if(!hw_fat_ok)fail("SD unavailable",false);
 // The source binding prevents an old directory from silently mixing builds.
 const char binding[]=MP_BUILD_ID "\n";char old[sizeof binding+1]={0};
 FILE* f=fopen(HWREF_DIR "/a7mulphase_v1_build.txt","rb");
 if(f){size_t n=fread(old,1,sizeof old,f);fclose(f);if(n!=sizeof binding-1||memcmp(old,binding,n))fail("Different producer build",false);}
 else if(!hw_write("a7mulphase_v1_build.txt",binding,sizeof binding-1))fail("Build record write failed",false);
 if(!read_journal())fail("Completion journal invalid",false);
 mailboxPrepare(&mb,slots,4);pxiSetMailbox(MP_CH,&mb);
 u32 pointer=request(MP_PING);
 if(pointer==MP_BAD||(pointer>>24)!=2||(pointer&31))fail("ARM7 result pointer invalid",false);
 u32 alias=(pointer&0x003fffffu)|0x02000000u;
 u32 helper_size=(u32)(__itcm_end-__itcm_start);
 if(!helper_size||helper_size>sizeof helper_copy)fail("ITCM bounds invalid",false);
 memcpy(helper_copy,__itcm_start,helper_size);
 if(!hw_write("a7mulphase_v1_helper_itcm.bin",helper_copy,helper_size))fail("Helper write failed",false);
 Buf info={0};buf_printf(&info,"a7mulphase v1; build %s; built " __DATE__ " " __TIME__ "\nFour Rs values, same single MAIN body/address and paired private-WRAM control. Warm1 before each4/16 call, five independent pairs. All raw times, full pre/post r0-r12/SP/LR/CPSR, return values/checksums, contexts and live code retained. Kernel body has64MUL and SUBS/BNE bookkeeping; fixed wrapper register snapshots use private WRAM inside the timed call and add no per-iteration instructions. ARM9 GO/wait stays IRQ-masked in ITCM with only I/O polling. All shared result writes are outside timed calls. No DS timing truth, P7 waits, historical trip/menu or card staging.\n",MP_BUILD_ID);
 if(!buf_write(&info,"a7mulphase_v1_info.txt"))fail("Information write failed",false);
 // Both display engines blank before capturing setup or starting any sample.
 R_DISPCNT=0x10080;REG32(0x04001000)=0x10080;
 buf_printf(&info,"field,value_hex\nhelper_entry,%08lx\nitcm_base,%08lx\nitcm_bytes,%08lx\nresult_pointer,%08lx\nresult_bytes,%08lx\nresult_arm9_alias,%08lx\n",(unsigned long)mp_quiet,(unsigned long)__itcm_start,(unsigned long)helper_size,(unsigned long)pointer,(unsigned long)sizeof result,(unsigned long)alias);
 setup(&info);if(!buf_write(&info,"a7mulphase_v1_setup.csv"))fail("Setup write failed",false);
 if(!hw_csv_header("a7mulphase_v1.csv",CSV_HEADER))fail("CSV header failed",false);
 for(u32 id=0;id<MP_CASES;id++)for(u32 region=0;region<2;region++){
  char key[32];snprintf(key,sizeof key,"k%02lu_r%lu",(unsigned long)id,(unsigned long)region);
  unsigned index=id*2+region;
  if(journal[index]==2){if(saved_group(id,region)){complete++;resumed++;}else failed++;continue;}
  if(journal[index]==1){interrupted++;continue;}
  if(!hw_step_begin("a7mulphase_v1_progress.txt",key)){failed++;continue;}
  u32 stale;while(mailboxTryRecv(&mb,&stale)){}REG16(0x04000180)=0;
  pxiSend(MP_CH,MP_RUN|(id<<8)|(region<<16));u32 quiet_status=mp_quiet();
  if(quiet_status){interrupted++;finish("Quiet timeout; START incomplete",false);}
  if(reply()!=pointer)fail("ARM7 response differs",false);
  armDCacheInvalidate((void*)alias,sizeof result);memcpy(&result,(void*)alias,sizeof result);
  if(result.magic!=MP_MAGIC||result.version!=MP_VERSION||result.case_id!=id||result.region!=region)fail("Result identity invalid",true);
  char name[64];snprintf(name,sizeof name,"a7mulphase_v1_k%02lu_r%lu.bin",(unsigned long)id,(unsigned long)region);
  bool saved=hw_write(name,&result,sizeof result);Buf csv={0};
  for(u32 rep=0;rep<MP_REPS;rep++)for(u32 length=0;length<2;length++){
   const MpSample* s=&result.samples[rep][length];
   buf_printf(&csv,"%lu,%08lx,%lu,%lu,%lu,%lu,%lu,%lu,%08lx,%08lx,%lu,%lu,%08lx,%08lx,%08lx,%lu\n",
    (unsigned long)id,(unsigned long)result.rs,(unsigned long)region,(unsigned long)rep,(unsigned long)s->loops,(unsigned long)s->ticks,
    (unsigned long)s->warm_value,(unsigned long)s->value,(unsigned long)s->warm_checksum,(unsigned long)s->checksum,
    (unsigned long)s->start_line,(unsigned long)s->end_line,(unsigned long)result.entry,(unsigned long)result.body,(unsigned long)result.end,(unsigned long)result.error);
  }
  saved=buf_append(&csv,"a7mulphase_v1.csv")&&saved;
  if(saved&&!result.error&&saved_group(id,region)&&hw_step_done("a7mulphase_v1_progress.txt",key)){complete++;fresh++;journal[index]=2;}
  else failed++;
 }
 finish(NULL,true);
}
