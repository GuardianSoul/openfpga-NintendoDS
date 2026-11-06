// New-only ARM7 Thumb/private-WRAM and timer-bank observation batch.
#include "../common/hwref.h"
#include "protocol.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <dirent.h>
#define GROUP "arm7thumb-v1"
#ifndef AT_BUILD_ID
#error AT_BUILD_ID must bind the durable return to producer sources
#endif
extern u32 at_quiet(void);
extern unsigned char __itcm_start[],__itcm_end[];
static Mailbox mb;static u32 slots[4];
static AtMeta meta __attribute__((aligned(32)));
static union {AtResult thumb;AtTimerResult timer;} result __attribute__((aligned(32)));
static u8 helper[32768] __attribute__((aligned(32)));
static const char* names[]={"alu","branch","ldr_sp","str_sp","ldr_pc","str_reg","ldrh","strh","stm1","timer_bank"};
static u32 hash(const void*p,unsigned n){const u8*b=p;u32 h=2166136261u;while(n--){h^=*b++;h*=16777619u;}return h;}
static void refuse(const char*why){consoleDemoInit();hw_status("REFUSED - existing files preserved: %s",why);hw_done();}
static u32 reply(void){u32 value,before=now32();while(!mailboxTryRecv(&mb,&value))if(now32()-before>AT_TIMEOUT)return AT_BAD;return value;}
static u32 alias(u32 p,u32 bytes){if((p>>24)!=2||(p&31)||bytes>0x400000)return 0;p=(p&0x003fffff)|0x02000000;return p+bytes<=0x02400000?p:0;}
static int marker(const char*name){char p[160];snprintf(p,sizeof p,"fat:/%s",name);FILE*f=fopen(p,"r");if(!f)return -1;int id=-1;if(fscanf(f,"%d",&id)!=1)id=-1;fclose(f);return id;}
static void path(char *out,const char *name) {snprintf(out,160,HWREF_DIR "/" GROUP "/%s",name);}
static bool exists(const char *name) {char p[160];struct stat st;path(p,name);return !stat(p,&st);}
static bool fingerprint(const char *name,unsigned *bytes,u32 *value) {
    char p[160];path(p,name);FILE *f=fopen(p,"rb");if(!f)return false;
    unsigned n=0;u32 h=2166136261u;int ch;
    while((ch=fgetc(f))!=EOF){h^=(u8)ch;h*=16777619u;n++;}
    bool ok=!ferror(f);if(fclose(f))ok=false;*bytes=n;*value=h;return ok;
}
static bool write_new(Buf *b,const char *name) {
    char rel[128];if(exists(name))return false;snprintf(rel,sizeof rel,GROUP "/%s",name);
    return buf_write(b,rel); // existing helper closes each file before returning
}
static bool same_file(const char *name,const char *text,unsigned len) {
    char p[160];path(p,name);FILE *f=fopen(p,"rb");if(!f)return false;
    unsigned i=0;int c;bool ok=true;
    while((c=fgetc(f))!=EOF){if(i>=len||(u8)c!=(u8)text[i])ok=false;i++;}
    ok=ok&&i==len&&!ferror(f);if(fclose(f))ok=false;return ok;
}
static bool empty_dir(void) {
    DIR *d=opendir(HWREF_DIR "/" GROUP);if(!d)return false;
    struct dirent *e;bool empty=true;
    while((e=readdir(d)))if(strcmp(e->d_name,".")&&strcmp(e->d_name,".."))empty=false;
    closedir(d);return empty;
}
static bool journal(unsigned state[AT_TOTAL_CASES]) {
    char p[160],line[96],verb[16],extra;path(p,"progress.txt");FILE *f=fopen(p,"rb");
    if(!f)return !exists("progress.txt");
    bool ok=true;
    while(fgets(line,sizeof line,f)) {
        unsigned id;size_t n=strlen(line);
        if(!n||line[n-1]!='\n'||sscanf(line,"%15s %u %c",verb,&id,&extra)!=2||id>=AT_TOTAL_CASES){ok=false;break;}
        if(!strcmp(verb,"start")&&state[id]==0)state[id]=1;
        else if(!strcmp(verb,"done")&&state[id]==1)state[id]=2;
        else {ok=false;break;}
    }
    ok=ok&&!ferror(f);if(fclose(f))ok=false;return ok;
}
static const char *suffixes[]={"bin","csv","code.bin","info.txt"};
static bool commit(unsigned id,bool create){
 Buf b={0};AtDescriptor*d=id<AT_CASES?&meta.d[id]:&meta.timer;
 buf_printf(&b,GROUP " source=%s case=%u code=%08lx\n",AT_BUILD_ID,id,(unsigned long)d->fnv);
 for(unsigned i=0;i<4;i++){char name[64];unsigned bytes;u32 h;snprintf(name,sizeof name,"case%u.%s",id,suffixes[i]);if(!fingerprint(name,&bytes,&h)){free(b.p);return false;}buf_printf(&b,"%s %u %08lx\n",name,bytes,(unsigned long)h);}
 char name[64];snprintf(name,sizeof name,"case%u.commit",id);bool ok=create?write_new(&b,name):same_file(name,b.p,b.len);free(b.p);return ok;
}
static bool binary_new(const char*name,const void*data,unsigned bytes){if(exists(name))return false;char relative[128];snprintf(relative,sizeof relative,GROUP "/%s",name);return hw_write(relative,data,bytes);}
static __attribute__((target("arm"),noinline)) void context(Buf*b){
 u32 ctrl,dtcm,itcm;__asm__ volatile("mrc p15,0,%0,c1,c0,0":"=r"(ctrl));__asm__ volatile("mrc p15,0,%0,c9,c1,0":"=r"(dtcm));__asm__ volatile("mrc p15,0,%0,c9,c1,1":"=r"(itcm));
 buf_printf(b,"ARM9 ctrl=%08lx dtcm=%08lx itcm=%08lx dc=%08lx ic=%08lx wb=%08lx dp=%08lx ip=%08lx\n",ctrl,dtcm,itcm,armMpuGetDCacheConfig(),armMpuGetICacheConfig(),armMpuGetWrBufConfig(),armMpuGetDataPerm(),armMpuGetCodePerm());
 for(unsigned i=0;i<8;i++)buf_printf(b,"ARM9 region%u=%08lx\n",i,armMpuGetRegion(i));
}
static void save_case(unsigned id){
 char name[64];unsigned bytes=id<AT_CASES?sizeof(AtResult):sizeof(AtTimerResult);
 snprintf(name,sizeof name,"case%u.bin",id);if(!binary_new(name,&result,bytes))refuse("raw sample persistence failed");
 Buf csv={0},info={0};const void*code;unsigned code_bytes;
 if(id<AT_CASES){
  AtResult*t=&result.thumb;code=t->code;code_bytes=t->code_bytes;
  buf_printf(&csv,"case,rep,loops,ticks,warm_return,returned,scratch_fnv,sp_before,sp_after,cpsr,r0,r1,r2,r3,r4,r5,r6,error\n");
  for(unsigned r=0;r<AT_REPS;r++)for(unsigned l=0;l<2;l++){
   AtSample*s=&t->samples[r][l];buf_printf(&csv,"%u,%u,%lu,%lu,%08lx,%08lx,%08lx,%08lx,%08lx,%08lx",id,r,(unsigned long)s->loops,(unsigned long)s->ticks,(unsigned long)s->warm_return,(unsigned long)s->returned,(unsigned long)s->scratch_fnv,(unsigned long)s->sp_before,(unsigned long)s->sp_after,(unsigned long)s->cpsr);
   for(unsigned reg=0;reg<7;reg++)buf_printf(&csv,",%08lx",(unsigned long)s->signature[reg]);
   buf_printf(&csv,",%lu\n",(unsigned long)s->error);
  }
  buf_printf(&info,"entry=%08lx body=%08lx end=%08lx bytes=%lu before=%08lx after=%08lx error=%lu\n",t->entry,t->body,t->end,t->code_bytes,t->code_before,t->code_after,t->error);
 }else{
  AtTimerResult*t=&result.timer;code=t->code;code_bytes=t->code_bytes;
  buf_printf(&csv,"case,mode,prescaler,delay,cpsr,before2,after2,before_action,after_action,count_before,count_after,count_after2,if_before,prev2,event2,prev3,event3,if_after,control2,control3,error,stopped2a,stopped2b,stopped3a,stopped3b\n");
  for(unsigned row=0;row<t->rows;row++){u32*w=(u32*)&t->samples[row];buf_printf(&csv,"%u",id);for(unsigned col=0;col<24;col++)buf_printf(&csv,",%lu",(unsigned long)w[col]);buf_printf(&csv,"\n");}
  buf_printf(&info,"entry=%08lx end=%08lx bytes=%lu before=%08lx after=%08lx error=%lu rows=%lu\n",t->entry,t->end,t->code_bytes,t->code_before,t->code_after,t->error,t->rows);
  for(unsigned bank=0;bank<2;bank++)buf_printf(&info,"TM%u control_before=%04lx control_after=%04lx current_before=%04lx current_after=%04lx\n",bank+2,t->control_before[bank],t->control_after[bank],t->value_before[bank],t->value_after[bank]);
 }
 buf_printf(&info,GROUP " source=%s case=%u name=%s\n",AT_BUILD_ID,id,names[id]);context(&info);
 snprintf(name,sizeof name,"case%u.csv",id);if(!write_new(&csv,name))refuse("CSV persistence failed");
 snprintf(name,sizeof name,"case%u.info.txt",id);if(!write_new(&info,name))refuse("context persistence failed");
 snprintf(name,sizeof name,"case%u.code.bin",id);if(!binary_new(name,code,code_bytes))refuse("live code persistence failed");
 // Unexpected values are saved and committed as completed observations. The
 // independent checker decides functional acceptance; timing is never graded here.
 if(!commit(id,true)||!commit(id,false))refuse("per-case readback/provenance failed");
}
int main(void){
 hw_init("ARM7 Thumb + timer bank v1 - new only");if(!hw_fat_ok)refuse("FAT unavailable");
 int stop_start=marker("arm7thumb-test-stop-start"),stop_done=marker("arm7thumb-test-stop-done");
 mailboxPrepare(&mb,slots,4);pxiSetMailbox(AT_CH,&mb);pxiSend(AT_CH,AT_PING);u32 pointer=reply();u32 read=alias(pointer,sizeof meta);if(!read)refuse("ARM7 metadata pointer invalid");
 armDCacheInvalidate((void*)read,sizeof meta);memcpy(&meta,(void*)read,sizeof meta);
 if(meta.magic!=AT_MAGIC||meta.version!=AT_VERSION||meta.cases!=AT_CASES||meta.error||!alias(meta.result_pointer,sizeof(AtResult))||!alias(meta.timer_result_pointer,sizeof(AtTimerResult))||meta.timer_rows!=AT_TIMER_ROWS||meta.timer_bytes!=sizeof(AtTimerResult))refuse("ARM7 metadata identity/bounds invalid");
 for(unsigned id=0;id<AT_TOTAL_CASES;id++){AtDescriptor*d=id<AT_CASES?&meta.d[id]:&meta.timer;u32 start=d->entry&~1u;if(start<0x03800000||d->end>0x0380f000||d->end<=start||(start&31)||d->body<start||d->body>=d->end||(d->body&3)||d->end-start>(id<AT_CASES?AT_CODE_WORDS*4:AT_TIMER_CODE_WORDS*4)||(id<AT_CASES?!(d->entry&1):!!(d->entry&1)))refuse("ARM7 code layout invalid");}
 unsigned helper_bytes=__itcm_end-__itcm_start;if(!helper_bytes||helper_bytes>sizeof helper)refuse("ARM9 ITCM helper bounds");memcpy(helper,__itcm_start,helper_bytes);
 mkdir(HWREF_DIR "/" GROUP,0777);Buf tag={0};
 buf_printf(&tag,GROUP " source=%s cases=%u thumb_reps=%u timer_rows=%u\nmeta bytes=%u fnv=%08lx helper entry=%08lx base=%08lx bytes=%u fnv=%08lx\n",AT_BUILD_ID,AT_TOTAL_CASES,AT_REPS,AT_TIMER_ROWS,(unsigned)sizeof meta,hash(&meta,sizeof meta),(u32)at_quiet,(u32)__itcm_start,helper_bytes,hash(helper,helper_bytes));
 for(unsigned id=0;id<AT_TOTAL_CASES;id++){AtDescriptor*d=id<AT_CASES?&meta.d[id]:&meta.timer;buf_printf(&tag,"case%u %s entry=%08lx body=%08lx end=%08lx fnv=%08lx\n",id,names[id],d->entry,d->body,d->end,d->fnv);}
 if(exists("manifest.txt")){if(!same_file("manifest.txt",tag.p,tag.len)||!same_file("metadata.bin",(const char*)&meta,sizeof meta)||!same_file("helper.bin",(const char*)helper,helper_bytes))refuse("source/code/context manifest mismatch");}
 else{if(!empty_dir())refuse("unbound preexisting directory");if(!write_new(&tag,"manifest.txt")||!binary_new("metadata.bin",&meta,sizeof meta)||!binary_new("helper.bin",helper,helper_bytes))refuse("manifest persistence failed");}free(tag.p);
 unsigned state[AT_TOTAL_CASES]={0};if(!journal(state))refuse("malformed/duplicate journal");
 for(unsigned id=0;id<AT_TOTAL_CASES;id++){
  if(state[id]==2&&!commit(id,false))refuse("completed case checksum/provenance mismatch");
  if(!state[id]){char name[64];for(unsigned s=0;s<4;s++){snprintf(name,sizeof name,"case%u.%s",id,suffixes[s]);if(exists(name))refuse("untracked case data");}snprintf(name,sizeof name,"case%u.commit",id);if(exists(name))refuse("untracked case commit");}
 }
 R_DISPCNT=0x10080;REG32(0x04001000)=0x10080;unsigned complete=0,skipped=0;
 for(unsigned id=0;id<AT_TOTAL_CASES;id++){
  if(state[id]){if(state[id]==2)complete++;else skipped++;continue;}char key[8];snprintf(key,sizeof key,"%u",id);
  if(!hw_step_begin(GROUP "/progress.txt",key))refuse("durable START failed");
  if((int)id==stop_start){consoleDemoInit();hw_status("TEST STOP after START%u",id);hw_done();}
  u32 stale;while(mailboxTryRecv(&mb,&stale)){}REG16(0x04000180)=0;pxiSend(AT_CH,AT_RUN|(id<<8));u32 quiet=at_quiet();
  if(quiet){consoleDemoInit();hw_status("Quiet timeout%lu; START retained; reboot skips this case",quiet);hw_done();}
  u32 returned=reply(),expected=id<AT_CASES?meta.result_pointer:meta.timer_result_pointer;unsigned bytes=id<AT_CASES?sizeof(AtResult):sizeof(AtTimerResult);
  if(returned!=expected)refuse("unexpected result pointer; START retained");
  read=alias(returned,bytes);armDCacheInvalidate((void*)read,bytes);memcpy(&result,(void*)read,bytes);
  if(result.thumb.magic!=AT_MAGIC||result.thumb.version!=AT_VERSION||result.thumb.id!=id)refuse("result identity mismatch");
  if(id<AT_CASES){if(result.thumb.code_bytes!=meta.d[id].end-(meta.d[id].entry&~1u))refuse("result code bounds mismatch");}
  else if(result.timer.code_bytes!=meta.timer.end-meta.timer.entry||result.timer.rows!=AT_TIMER_ROWS)refuse("timer result bounds/incomplete");
  save_case(id);if(!hw_step_done(GROUP "/progress.txt",key))refuse("durable DONE failed");complete++;
  if((int)id==stop_done){consoleDemoInit();hw_status("TEST STOP after DONE%u",id);hw_done();}
 }
 consoleDemoInit();hw_status("ARM7 %s complete=%u interrupted=%u",complete==AT_TOTAL_CASES?"COMPLETE":"INCOMPLETE",complete,skipped);hw_done();
}
