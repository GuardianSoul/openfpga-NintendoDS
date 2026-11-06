/* Reuse the timerphase new-only journal/commit and quiet ITCM protocol. */
#include "../common/hwref.h"
#include "protocol.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <dirent.h>
#define GROUP "soundlabels-v1"
extern u32 tp_quiet(void);
extern unsigned char __itcm_start[],__itcm_end[];
static Mailbox mb;static u32 slots[4];
static SlMeta meta __attribute__((aligned(32)));
static SlResult result __attribute__((aligned(32)));
static u8 helper[32768] __attribute__((aligned(32)));
static u32 hash(const void*p,unsigned n){const u8*b=p;u32 h=2166136261u;while(n--){h^=*b++;h*=16777619u;}return h;}
static void refuse(const char*why){consoleDemoInit();hw_status("REFUSED - retained: %s",why);hw_done();}
static u32 reply(void){u32 value,before=now32();while(!mailboxTryRecv(&mb,&value))if(now32()-before>TP_TIMEOUT)return 0x03ffffffu;return value;}
static u32 alias(u32 p,u32 bytes){if((p>>24)!=2||(p&31)||bytes>0x400000)return 0;p=(p&0x003fffff)|0x02000000;return p+bytes<=0x02400000?p:0;}
static void path(char*out,const char*name){snprintf(out,160,HWREF_DIR "/" GROUP "/%s",name);}
static bool exists(const char*name){char p[160];struct stat st;path(p,name);return !stat(p,&st);}
static bool same(const char*name,const void*blob,unsigned bytes){char p[160];path(p,name);FILE*f=fopen(p,"rb");if(!f)return false;const u8*b=blob;unsigned i=0;int c;bool ok=true;while((c=fgetc(f))!=EOF){if(i>=bytes||b[i]!=(u8)c)ok=false;i++;}ok=ok&&i==bytes&&!ferror(f);if(fclose(f))ok=false;return ok;}
static bool write_new(const char*name,const void*data,unsigned bytes){if(exists(name))return false;char rel[160];snprintf(rel,sizeof rel,GROUP "/%s",name);return hw_write(rel,data,bytes);}
static bool text_new(const char*name,Buf*b){return write_new(name,b->p,b->len);}
static bool empty_dir(void){DIR*d=opendir(HWREF_DIR "/" GROUP);if(!d)return false;bool empty=true;struct dirent*e;while((e=readdir(d)))if(strcmp(e->d_name,".")&&strcmp(e->d_name,".."))empty=false;closedir(d);return empty;}
static __attribute__((target("arm"),noinline)) void context(Buf*b){
 u32 ctrl,dtcm,itcm;__asm__ volatile("mrc p15,0,%0,c1,c0,0":"=r"(ctrl));__asm__ volatile("mrc p15,0,%0,c9,c1,0":"=r"(dtcm));__asm__ volatile("mrc p15,0,%0,c9,c1,1":"=r"(itcm));
 buf_printf(b,"ARM9 ctrl=%08lx dtcm=%08lx itcm=%08lx dc=%08lx ic=%08lx wb=%08lx dp=%08lx ip=%08lx\n",ctrl,dtcm,itcm,armMpuGetDCacheConfig(),armMpuGetICacheConfig(),armMpuGetWrBufConfig(),armMpuGetDataPerm(),armMpuGetCodePerm());
 for(unsigned i=0;i<8;i++)buf_printf(b,"ARM9 region%u=%08lx\n",i,armMpuGetRegion(i));
}
static bool fingerprint(const char*name,unsigned*n,u32*h){char p[160];path(p,name);FILE*f=fopen(p,"rb");if(!f)return false;*n=0;*h=2166136261u;int c;while((c=fgetc(f))!=EOF){*h^=(u8)c;*h*=16777619u;(*n)++;}bool ok=!ferror(f);if(fclose(f))ok=false;return ok;}
static bool commit(unsigned condition,bool create){
 Buf b={0};buf_printf(&b,GROUP " source=%s condition=%u\n",SL_BUILD_ID,condition);
 const char*ext[]={"bin","events.csv","code.bin","context.txt","cap0.bin","cap1.bin"};
 for(unsigned i=0;i<6;i++){char n[64];unsigned bytes;u32 h;snprintf(n,sizeof n,"case%u.%s",condition,ext[i]);if(!fingerprint(n,&bytes,&h)){free(b.p);return false;}buf_printf(&b,"%s %u %08lx\n",n,bytes,h);}
 char name[64];snprintf(name,sizeof name,"case%u.commit",condition);bool ok=create?text_new(name,&b):same(name,b.p,b.len);free(b.p);return ok;
}
static void event(Buf*b,const char*name,SlEvent*e){buf_printf(b,"%s,%lu,%lu,%08lx,%08lx\n",name,e->before,e->after,e->written,e->readback);}
int main(void){
 hw_init("Labeled sound onset/crossover v1");if(!hw_fat_ok)refuse("FAT unavailable");
 mailboxPrepare(&mb,slots,4);pxiSetMailbox(SL_CH,&mb);pxiSend(SL_CH,SL_PING);u32 p=alias(reply(),sizeof meta);if(!p)refuse("metadata pointer");
 armDCacheInvalidate((void*)p,sizeof meta);memcpy(&meta,(void*)p,sizeof meta);
 if(meta.magic!=SL_MAGIC||meta.version!=1||meta.error||meta.result_bytes!=sizeof result||!alias(meta.result_pointer,sizeof result)||meta.code_base<0x03800000||meta.code_base+meta.code_bytes>0x0380f000||meta.code_bytes>SL_CODE_BYTES)refuse("metadata bounds");
 unsigned hb=__itcm_end-__itcm_start;if(!hb||hb>sizeof helper)refuse("quiet helper bounds");memcpy(helper,__itcm_start,hb);
 mkdir(HWREF_DIR "/" GROUP,0777);Buf tag={0};buf_printf(&tag,GROUP " source=%s cases=2 samples=%u\nmeta bytes=%u fnv=%08lx helper entry=%08lx base=%08lx bytes=%u fnv=%08lx\n",SL_BUILD_ID,SL_SAMPLES,(unsigned)sizeof meta,hash(&meta,sizeof meta),(u32)tp_quiet,(u32)__itcm_start,hb,hash(helper,hb));
 if(exists("manifest.txt")){if(!same("manifest.txt",tag.p,tag.len)||!same("metadata.bin",&meta,sizeof meta)||!same("helper.bin",helper,hb))refuse("source/code/helper identity");}
 else if(!empty_dir()||!text_new("manifest.txt",&tag)||!write_new("metadata.bin",&meta,sizeof meta)||!write_new("helper.bin",helper,hb))refuse("manifest persistence");
 free(tag.p);
 if(exists("progress.txt")){
  if(same("progress.txt","start 0\ndone 0\nstart 1\ndone 1\n",30)&&commit(0,false)&&commit(1,false)){hw_status("COMPLETE retained");hw_done();}
  refuse("existing incomplete/unqualified journal; no automatic repeat");
 }
 for(unsigned i=0;i<2;i++)for(unsigned j=0;j<7;j++){const char*ext[]={"bin","events.csv","code.bin","context.txt","cap0.bin","cap1.bin","commit"};char n[64];snprintf(n,sizeof n,"case%u.%s",i,ext[j]);if(exists(n))refuse("untracked prior result");}
 R_DISPCNT=0x10080;REG32(0x04001000)=0x10080;
 for(unsigned c=0;c<2;c++){
  char key[4];snprintf(key,sizeof key,"%u",c);if(!hw_step_begin(GROUP "/progress.txt",key))refuse("durable START");
  REG16(0x04000180)=0;pxiSend(SL_CH,SL_RUN|c);if(tp_quiet())refuse("quiet timeout; START retained");
  if(reply()!=meta.result_pointer)refuse("result identity");
  p=alias(meta.result_pointer,sizeof result);armDCacheInvalidate((void*)p,sizeof result);memcpy(&result,(void*)p,sizeof result);
  if(result.magic!=SL_MAGIC||result.version!=1||result.condition!=c||result.error||result.samples!=SL_SAMPLES||result.code_base!=meta.code_base||result.code_bytes!=meta.code_bytes||result.code_before!=meta.code_fnv||result.code_after!=meta.code_fnv)refuse("functional/code failure; START retained");
  Buf csv={0},info={0};buf_printf(&csv,"event,before,after,written,readback\n");event(&csv,"clock1",&result.clocks[0]);event(&csv,"clock3",&result.clocks[1]);event(&csv,"capture",&result.capture);event(&csv,"voice0",&result.voices[0]);event(&csv,"voice2",&result.voices[1]);event(&csv,"switch0",&result.switches[0]);event(&csv,"switch1",&result.switches[1]);event(&csv,"completion",&result.completion);
  buf_printf(&info,GROUP " source=%s condition=%u error=%lu cpsr=%08lx sp=%08lx epoch=%lu finished=%lu\n",SL_BUILD_ID,c,result.error,result.cpsr,result.sp,result.epoch,result.finished);context(&info);
  char n[64];snprintf(n,sizeof n,"case%u.bin",c);if(!write_new(n,&result,sizeof result))refuse("raw result save");snprintf(n,sizeof n,"case%u.events.csv",c);if(!text_new(n,&csv))refuse("CSV save");snprintf(n,sizeof n,"case%u.context.txt",c);if(!text_new(n,&info))refuse("context save");snprintf(n,sizeof n,"case%u.code.bin",c);if(!write_new(n,result.code,result.code_bytes))refuse("live code save");for(unsigned u=0;u<2;u++){snprintf(n,sizeof n,"case%u.cap%u.bin",c,u);if(!write_new(n,result.capture_pcm[u],sizeof result.capture_pcm[u]))refuse("capture save");}
  if(!commit(c,true)||!commit(c,false)||!hw_step_done(GROUP "/progress.txt",key))refuse("commit/DONE");
  free(csv.p);free(info.p);
 }
 consoleDemoInit();hw_status("COMPLETE2 conditions; protocol only, no DS timing verdict");hw_done();
}
