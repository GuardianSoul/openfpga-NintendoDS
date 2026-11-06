// One new-only timer0/1 measurement; durable files never overwrite prior data.
#include "../common/hwref.h"
#include "protocol.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <dirent.h>
#define GROUP "timerphase-v1"
extern u32 tp_quiet(void);
extern unsigned char __itcm_start[],__itcm_end[];
static Mailbox mb;static u32 slots[4];
static TpMeta meta __attribute__((aligned(32)));
static TpResult result __attribute__((aligned(32)));
static u8 helper[32768] __attribute__((aligned(32)));
static u32 hash(const void*p,unsigned n){const u8*b=p;u32 h=2166136261u;while(n--){h^=*b++;h*=16777619u;}return h;}
static void refuse(const char*why){consoleDemoInit();hw_status("REFUSED - existing files preserved: %s",why);hw_done();}
static u32 reply(void){u32 value,before=now32();while(!mailboxTryRecv(&mb,&value))if(now32()-before>TP_TIMEOUT)return 0x03ffffffu;return value;}
static u32 alias(u32 p,u32 bytes){if((p>>24)!=2||(p&31)||bytes>0x400000)return 0;p=(p&0x003fffff)|0x02000000;return p+bytes<=0x02400000?p:0;}
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
static __attribute__((target("arm"),noinline)) void context(Buf*b){
 u32 ctrl,dtcm,itcm;__asm__ volatile("mrc p15,0,%0,c1,c0,0":"=r"(ctrl));__asm__ volatile("mrc p15,0,%0,c9,c1,0":"=r"(dtcm));__asm__ volatile("mrc p15,0,%0,c9,c1,1":"=r"(itcm));
 buf_printf(b,"ARM9 ctrl=%08lx dtcm=%08lx itcm=%08lx dc=%08lx ic=%08lx wb=%08lx dp=%08lx ip=%08lx\n",ctrl,dtcm,itcm,armMpuGetDCacheConfig(),armMpuGetICacheConfig(),armMpuGetWrBufConfig(),armMpuGetDataPerm(),armMpuGetCodePerm());
 for(unsigned i=0;i<8;i++)buf_printf(b,"ARM9 region%u=%08lx\n",i,armMpuGetRegion(i));
}
static bool binary_new(const char*name,const void*data,unsigned bytes){if(exists(name))return false;char rel[128];snprintf(rel,sizeof rel,GROUP "/%s",name);return hw_write(rel,data,bytes);}
static bool commit(bool create){
 Buf b={0};buf_printf(&b,GROUP " source=%s code=%08lx\n",TP_BUILD_ID,meta.fnv);
 const char*names[]={"result.bin","result.csv","code.bin","context.txt"};
 for(unsigned i=0;i<4;i++){unsigned n;u32 h;if(!fingerprint(names[i],&n,&h)){free(b.p);return false;}buf_printf(&b,"%s %u %08lx\n",names[i],n,h);}
 bool ok=create?write_new(&b,"result.commit"):same_file("result.commit",b.p,b.len);free(b.p);return ok;
}
int main(void){
 hw_init("ARM7 joint timer0/1 phase v1");if(!hw_fat_ok)refuse("FAT unavailable");
 mailboxPrepare(&mb,slots,4);pxiSetMailbox(TP_CH,&mb);pxiSend(TP_CH,TP_PING);u32 read=alias(reply(),sizeof meta);if(!read)refuse("metadata pointer");
 armDCacheInvalidate((void*)read,sizeof meta);memcpy(&meta,(void*)read,sizeof meta);
 if(meta.magic!=TP_MAGIC||meta.version!=1||meta.error||meta.result_bytes!=sizeof result||!alias(meta.result_pointer,sizeof result)||meta.entry<0x03800000||meta.end>0x0380f000||(meta.entry&31)||meta.end<=meta.entry||meta.end-meta.entry>sizeof result.code)refuse("metadata bounds");
 unsigned helper_bytes=__itcm_end-__itcm_start;if(!helper_bytes||helper_bytes>sizeof helper)refuse("helper bounds");memcpy(helper,__itcm_start,helper_bytes);
 mkdir(HWREF_DIR "/" GROUP,0777);Buf tag={0};
 buf_printf(&tag,GROUP " source=%s rows=%u\nmeta bytes=%u fnv=%08lx helper entry=%08lx base=%08lx bytes=%u fnv=%08lx\n",TP_BUILD_ID,TP_ROWS,(unsigned)sizeof meta,hash(&meta,sizeof meta),(u32)tp_quiet,(u32)__itcm_start,helper_bytes,hash(helper,helper_bytes));
 if(exists("manifest.txt")){if(!same_file("manifest.txt",tag.p,tag.len)||!same_file("metadata.bin",(const char*)&meta,sizeof meta)||!same_file("helper.bin",(const char*)helper,helper_bytes))refuse("source/code/helper binding");}
 else{if(!empty_dir())refuse("unbound directory");if(!write_new(&tag,"manifest.txt")||!binary_new("metadata.bin",&meta,sizeof meta)||!binary_new("helper.bin",helper,helper_bytes))refuse("manifest persistence");}free(tag.p);
 if(exists("progress.txt")){
  if(same_file("progress.txt","start 0\ndone 0\n",15)&&commit(false)){hw_status("COMPLETE retained");hw_done();}
  if(same_file("progress.txt","start 0\n",8)){hw_status("INTERRUPTED retained; no repeat");hw_done();}
  refuse("journal/completed checksum");
 }
 const char*names[]={"result.bin","result.csv","code.bin","context.txt","result.commit"};for(unsigned i=0;i<5;i++)if(exists(names[i]))refuse("untracked result data");
 if(!hw_step_begin(GROUP "/progress.txt","0"))refuse("durable START");
 R_DISPCNT=0x10080;REG32(0x04001000)=0x10080;REG16(0x04000180)=0;pxiSend(TP_CH,TP_RUN);
 if(tp_quiet()){consoleDemoInit();hw_status("Quiet timeout; START retained");hw_done();}
 if(reply()!=meta.result_pointer)refuse("result pointer");
 read=alias(meta.result_pointer,sizeof result);armDCacheInvalidate((void*)read,sizeof result);memcpy(&result,(void*)read,sizeof result);
 if(result.magic!=TP_MAGIC||result.version!=1||result.rows!=TP_ROWS||result.entry!=meta.entry||result.end!=meta.end)refuse("result identity/bounds");
 if(!binary_new("result.bin",&result,sizeof result)||!binary_new("code.bin",result.code,meta.end-meta.entry))refuse("raw/code persistence");
 Buf csv={0},info={0};buf_printf(&csv,"clear_before,clear_after,read_before,if_word,read_after,hi_before,hi_after,guard\n");
 for(unsigned i=0;i<TP_ROWS;i++){u32*w=(u32*)&result.samples[i];for(unsigned j=0;j<8;j++)buf_printf(&csv,j?",%lu":"%lu",w[j]);buf_printf(&csv,"\n");}
 buf_printf(&info,GROUP " source=%s error=%lu cpsr=%08lx\n",TP_BUILD_ID,result.error,result.cpsr);context(&info);
 if(!write_new(&csv,"result.csv")||!write_new(&info,"context.txt")||!commit(true)||!commit(false)||!hw_step_done(GROUP "/progress.txt","0"))refuse("result commit");
 free(csv.p);free(info.p);consoleDemoInit();hw_status("COMPLETE timer0/1 rows=%u",TP_ROWS);hw_done();
}
