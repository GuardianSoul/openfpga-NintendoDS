// Four-case new-only timer-port I/O phase observation. No hardware timing target.
// Reuses hwref/calico timer save/restore and wbuf's generated ARM/ITCM method.
#include "../common/hwref.h"
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <dirent.h>
#include <stdlib.h>
#define VERSION "iophase-v2"
#define GROUP "iophase-v2"
#ifndef IOPHASE_BUILD_ID
#error IOPHASE_BUILD_ID must bind journal to producer sources
#endif
#define REPS 16
static u32 code[96] __attribute__((section(".itcm"),aligned(32)));
typedef struct { u32 r[4], timer; } Context;
static Context ctx DTCM_BSS __attribute__((aligned(32)));
static u32 hash(const void *p,unsigned n) {
    const u8 *s=p;u32 h=2166136261u;
    while(n--) {h^=*s++;h*=16777619u;}return h;
}
static unsigned generate(unsigned prefix,unsigned gap,unsigned *first,unsigned *last) {
    unsigned n=0;
#define E(w) code[n++]=(w)
    E(0xe92d40f0); // push {r4-r7,lr}
    E(0xe1a07000); // mov r7,r0: output DTCM pointer
    E(0xe5904010); // ldr r4,[r0,#16]: timer-low pointer
    E(0xe3a05000); // mov r5,#0: independent stop value
    for(unsigned i=0;i<64;i++) E(0xe1a08008); // settle startup before measured leaf
    *first=n;
    if(prefix) E(0xe1a08008);
    E(0xe1d400b0); // LDRH r0,[r4] count
    E(0xe1a08008); // independent MOV r8,r8 (ARMv5 NOP r0,r0 would load-use r0)
    E(0xe1d410b0); // LDRH r1,[r4] count
    if(gap) E(0xe1a08008);
    E(0xe1c450b2); // STRH r5,[r4,#2] stop; no dependency on r0/r1
    E(0xe1d420b0); // LDRH r2,[r4] stopped count
#ifdef IO_DATA_MUTANT
    E(0xe2223001); // actual producer fault: r3 = stopped r2 XOR1
#else
    E(0xe1d430b0); // LDRH r3,[r4] stopped count, consistency observation
#endif
    *last=n;
    E(0xe887000f); // stmia r7,{r0-r3}: result after the leaf
    E(0xe8bd40f0); E(0xe12fff1e); // restore; bx lr
#undef E
    return n;
}
static u32 cpsr(void) {u32 x;__asm__ volatile("mrs %0,cpsr":"=r"(x));return x;}
static void config(Buf *b,const char *tag) {
    u32 ctrl,dtcm,itcm;
    __asm__ volatile("mrc p15,0,%0,c1,c0,0":"=r"(ctrl));
    __asm__ volatile("mrc p15,0,%0,c9,c1,0":"=r"(dtcm));
    __asm__ volatile("mrc p15,0,%0,c9,c1,1":"=r"(itcm));
    buf_printf(b,"%s ctrl=%08lx dtcm=%08lx itcm=%08lx dc=%08lx ic=%08lx wb=%08lx dp=%08lx ip=%08lx\n",tag,ctrl,dtcm,itcm,armMpuGetDCacheConfig(),armMpuGetICacheConfig(),armMpuGetWrBufConfig(),armMpuGetDataPerm(),armMpuGetCodePerm());
    for(unsigned i=0;i<8;i++)buf_printf(b,"%s region%u=%08lx\n",tag,i,armMpuGetRegion(i));
}

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
    DIR *d=opendir(HWREF_DIR "/iophase-v2");if(!d)return false;
    struct dirent *e;bool empty=true;
    while((e=readdir(d)))if(strcmp(e->d_name,".")&&strcmp(e->d_name,".."))empty=false;
    closedir(d);return empty;
}
static bool journal(unsigned state[4]) {
    char p[160],line[96],verb[16],extra;path(p,"progress.txt");FILE *f=fopen(p,"rb");
    if(!f)return !exists("progress.txt");bool ok=true;
    while(fgets(line,sizeof line,f)) {
        unsigned id;size_t n=strlen(line);
        if(!n||line[n-1]!='\n'||sscanf(line,"%15s %u %c",verb,&id,&extra)!=2||id>=4){ok=false;break;}
        if(!strcmp(verb,"start")&&state[id]==0)state[id]=1;
        else if(!strcmp(verb,"done")&&state[id]==1)state[id]=2;
        else {ok=false;break;}
    }
    ok=ok&&!ferror(f);if(fclose(f))ok=false;return ok;
}
static const char *suffixes[]={"trials.csv","code.csv","registers.csv","info.txt"};
static bool commit(unsigned id,bool create) {
    Buf b={0};unsigned first,last,n=generate(id%2,id/2,&first,&last);
    buf_printf(&b,"%s source=%s case=%u code=%08lx reps=16\n",VERSION,IOPHASE_BUILD_ID,id,hash(code,n*4));
    for(unsigned i=0;i<4;i++) {
        char name[64];unsigned bytes;u32 h;snprintf(name,sizeof name,"case%u.%s",id,suffixes[i]);
        if(!fingerprint(name,&bytes,&h)){free(b.p);return false;}
        buf_printf(&b,"%s %u %08lx\n",name,bytes,h);
    }
    char name[64];snprintf(name,sizeof name,"case%u.commit",id);
    bool ok=create?write_new(&b,name):same_file(name,b.p,b.len);
    free(b.p);return ok;
}
static void refuse(const char *reason) {
    hw_status("REFUSED - preserve existing files: %s",reason);hw_done();
}
int main(void) {
    hw_init("Ordinary IO four-case phase v2 resumable");
    if(!hw_fat_ok)refuse("FAT unavailable");
    mkdir(HWREF_DIR "/iophase-v2",0777);
    Buf tag={0};buf_printf(&tag,"%s source=%s cases=4 reps=16\n",VERSION,IOPHASE_BUILD_ID);
    for(unsigned id=0;id<4;id++){unsigned first,last,n=generate(id%2,id/2,&first,&last);buf_printf(&tag,"case%u code=%08lx words=%u first=%u last=%u\n",id,hash(code,n*4),n,first,last);}
    if(exists("manifest.txt")) {
        if(!same_file("manifest.txt",tag.p,tag.len))refuse("version/source/code manifest mismatch");
    } else {
        if(!empty_dir())refuse("unbound existing directory");
        if(!write_new(&tag,"manifest.txt"))refuse("manifest persistence failed");
    }
    free(tag.p);
    unsigned state[4]={0};if(!journal(state))refuse("malformed/duplicate journal");
    // Validate every completed case before any append or measurement. Started
    // cases are preserved and skipped, matching the existing hang-safe helper.
    for(unsigned id=0;id<4;id++) {
        if(state[id]==2&&!commit(id,false))refuse("completed case checksum/provenance mismatch");
        if(state[id]==0) {
            char name[64];for(unsigned i=0;i<4;i++){snprintf(name,sizeof name,"case%u.%s",id,suffixes[i]);if(exists(name))refuse("untracked preexisting case data");}
            snprintf(name,sizeof name,"case%u.commit",id);if(exists(name))refuse("untracked preexisting commit");
        }
    }
    unsigned completed=0,skipped=0;
    for(unsigned id=0;id<4;id++) {
        if(state[id]){if(state[id]==2)completed++;else skipped++;continue;}
        char key[8];snprintf(key,sizeof key,"%u",id);
        if(!hw_step_begin(GROUP "/progress.txt",key))refuse("durable START failed");
#ifdef IO_STOP_AFTER_START
        if(id==IO_STOP_AFTER_START){hw_status("INJECTED INTERRUPTION after START%u",id);hw_done();}
#endif
        unsigned gap=id/2,prefix=id%2,first,last,n=generate(prefix,gap,&first,&last);
        unsigned trials=0,failures=0;Buf csv={0},words={0},info={0},regs={0};
        buf_printf(&csv,"case,prefix,gap,rep,r0,r1,r2,r3,irq_masked,timeout,control_before,control_after,cpsr,checksum,restore_ok\n");
        buf_printf(&words,"case,index,word,in_leaf\n");
        buf_printf(&regs,"case,rep,tag,tm2cnt,tm2val,dispcnt,bg0cnt,dispstat_stable\n");
        config(&info,"initial");
        buf_printf(&info,VERSION "\nsource=%s case=%u code=%08lx context=%08lx timer=04000108 reps=16\nreload0 F1 settled64ITCMNOP beforeleaf; rawcounts include sampleoverhead; no timing acceptance in software\n",IOPHASE_BUILD_ID,id,(u32)code,(u32)&ctx);
        for(unsigned i=0;i<n;i++)buf_printf(&words,"%u,%u,0x%08lx,%u\n",id,i,code[i],i>=first&&i<last);
        for(unsigned rep=0;rep<REPS;rep++) {
            // Calico borrows TM2/3; save and restore as existing tmcnt. No filesystem
            // work executes inside the straight-line leaf; results are written after unlock.
            ArmIrqState st=armIrqLockByPsr();
            u16 tc=REG16(0x0400010a),tv=REG16(0x04000108);
            u32 disp=R_DISPCNT;u16 bg=REG16(0x04000008),ds=REG16(0x04000004)&0xfff8;
            REG16(0x0400010a)=0;REG16(0x04000108)=0;REG16(0x0400010a)=0x80;
            u16 cb=REG16(0x0400010a);u32 ps=cpsr();
            memset(&ctx,0,sizeof(ctx));ctx.timer=0x04000108;
            ((void(*)(Context*))code)(&ctx);
            u16 ca=REG16(0x0400010a);
            REG16(0x0400010a)=0;REG16(0x04000108)=tv;REG16(0x0400010a)=tc;
            u16 tc2=REG16(0x0400010a),tv2=REG16(0x04000108),bg2=REG16(0x04000008),ds2=REG16(0x04000004)&0xfff8;u32 disp2=R_DISPCNT;
            bool restored=tc2==tc&&bg2==bg&&ds2==ds&&disp2==disp;
            armIrqUnlockByPsr(st);
            buf_printf(&regs,"%u,%u,before,0x%04x,0x%04x,0x%08lx,0x%04x,0x%04x\n",id,rep,tc,tv,disp,bg,ds);
            buf_printf(&regs,"%u,%u,restored,0x%04x,0x%04x,0x%08lx,0x%04x,0x%04x\n",id,rep,tc2,tv2,disp2,bg2,ds2);
            buf_printf(&csv,"%u,%u,%u,%u,0x%04lx,0x%04lx,0x%04lx,0x%04lx,%u,0,0x%04x,0x%04x,0x%08lx,0x%08lx,%u\n",id,prefix,gap,rep,ctx.r[0],ctx.r[1],ctx.r[2],ctx.r[3],!!(ps&0x80),cb,ca,ps,hash(ctx.r,16),restored);
            trials++;if(!restored)failures++;
        }

        config(&info,"restored");
        buf_printf(&info,"trials=%u restore_failures=%u complete=%u\n",trials,failures,trials==16&&!failures);
        char name[64];snprintf(name,sizeof name,"case%u.trials.csv",id);if(!write_new(&csv,name))refuse("case trials persistence failed");
        snprintf(name,sizeof name,"case%u.code.csv",id);if(!write_new(&words,name))refuse("case code persistence failed");
        snprintf(name,sizeof name,"case%u.registers.csv",id);if(!write_new(&regs,name))refuse("case register persistence failed");
        snprintf(name,sizeof name,"case%u.info.txt",id);if(!write_new(&info,name))refuse("case CP15 persistence failed");
        if(failures||trials!=16||!commit(id,true)||!commit(id,false))refuse("case persistence/integrity failed; START retained");
        if(!hw_step_done(GROUP "/progress.txt",key))refuse("durable DONE failed");
        completed++;
#ifdef IO_STOP_AFTER_DONE
        if(id==IO_STOP_AFTER_DONE){hw_status("INJECTED INTERRUPTION after DONE%u",id);hw_done();}
#endif
    }
    hw_status("iophase %s: complete_cases=%u interrupted_cases=%u",completed==4?"COMPLETE":"INCOMPLETE",completed,skipped);
    hw_done();
}
