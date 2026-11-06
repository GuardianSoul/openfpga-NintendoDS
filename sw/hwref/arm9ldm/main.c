// Standalone source-staged extension of memtime2; not in the all-probe chain.
// Retained memtime objects supply the original ITCM anchor and timer wrapper.
#include "../memtime/memtime.h"
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
extern u32 s_main[96 * 1024 / 4], s_itcm[256];
extern const u32 ldm1[], ldm1_end[], ldm2[], ldm2_end[], ldm4[], ldm4_end[];
extern const u32 fixed1[], fixed1_end[], fixed2[], fixed2_end[];
extern const u32 fixed4[], fixed4_end[], fixed8[], fixed8_end[];
extern const u32 split4[], split4_end[], split2[], split2_end[], scalar8[], scalar8_end[];
extern const u32 gap4[], gap4_end[], dep4[], dep4_end[], nop16[], nop16_end[];
static volatile u32 snapshot[8];
static Buf times, signatures, info;
typedef struct { const char *name; const u32 *body, *end; unsigned words, fixed; } Case;
#define CASE(n,w,f) {#n,n,n##_end,w,f}
static const Case cases[] = {
    CASE(ldm1,1,0), CASE(ldm2,2,0), CASE(ldm4,4,0),
    {"ldm8_anchor",0,0,8,0},
    CASE(fixed1,1,1), CASE(fixed2,2,1), CASE(fixed4,4,1), CASE(fixed8,8,1),
    CASE(split4,8,0), CASE(split2,8,0), CASE(scalar8,8,0),
    CASE(gap4,8,0), CASE(dep4,8,0), CASE(nop16,0,0)
};
static u32 pattern(unsigned index) { return index * 0x9e3779b9u; }
static void cp15(const char *tag) {
    Cp15 c; mt_cp15_read(&c);
    buf_printf(&info,"%s ctrl=%08lx dc=%08lx ic=%08lx wb=%08lx dp=%08lx ip=%08lx dtcm=%08lx itcm=%08lx\n",
        tag,c.ctrl,c.dcache,c.icache,c.wrbuf,c.dperm,c.iperm,c.dtcm,c.itcm);
    for(unsigned i=0;i<8;i++) buf_printf(&info,"%s region%u=%08lx\n",tag,i,c.region[i]);
}
// Exact timed prefix, including all zeroing, reset/loads, subs/bne. Only the
// untimed copy replaces pop/bx with a register snapshot followed by pop/bx.
// No register stores or checks are included between mt_time's two timer reads.
static bool check(const Case *c, const u32 *body, unsigned bytes, u32 base, unsigned loops) {
    unsigned prefix=bytes/4-2;
    memcpy(s_itcm,body,bytes);
    s_itcm[prefix+0]=0xe59f1008; // ldr r1,[pc,#8] => literal below
    s_itcm[prefix+1]=0xe88103fc; // stmia r1,{r2-r9}
    s_itcm[prefix+2]=0xe8bd03f0; // pop {r4-r9}
    s_itcm[prefix+3]=0xe12fff1e; // bx lr
    s_itcm[prefix+4]=(u32)snapshot;
    for(unsigned i=0;i<8;i++) snapshot[i]=0xdeadbeef;
    ((KFn)s_itcm)(base,loops);
    bool ok=true;
    unsigned offset=(base-(u32)s_main)/4;
    unsigned first=offset+(c->fixed?0:15*c->words);
    buf_printf(&signatures,"%s,%u,%u,%u",c->name,offset*4-(c->fixed?512:0),loops*16,c->words);
    for(unsigned r=0;r<8;r++) {
        u32 expected=r<c->words?pattern(first+r):0;
        if(snapshot[r]!=expected || (r<c->words && snapshot[r]==0)) ok=false;
        buf_printf(&signatures,",%08lx",snapshot[r]);
    }
    buf_printf(&signatures,",%u\n",ok);
    return ok;
}
int __attribute__((section(".text.native_envelope"))) main(void) {
    hw_init("ARM9 uncached LDM v1");
    mkdir("fat:/hwref/arm9ldm-v1",0777);
    mt_cfg_save();
    int region=mt_region_of((u32)s_main);
    u16 exmem=REG16(0x04000204), vram_b=R_VRAMCNT(1);
    buf_printf(&info,"arm9ldm-v1\nclock=33513982 tick=system-cycle reps=5 warm=full-length n1=256 n2=1024 blocks-per-loop=16\nfixed-base=main+512; offsets are relative to each case base; gap4=4NOP; dep4=4 ADD r2,r2,0\n");
    buf_printf(&info,"base=%08lx copied-kernel=%08lx anchor=%08lx timer=%08lx region=%d EXMEMCNT=%04x WRAMCNT=%02x VRAMCNT_B=%02x POWCNT1=%04x\n",
        (u32)s_main,(u32)s_itcm,(u32)g_kern[OP_LDM][KM_SEQ],(u32)mt_time,region,exmem,REG8(0x04000247),vram_b,R_POWCNT1);
    cp15("initial");
    // Same original data initializer and memtime2 preparation of bank B/EXMEM.
    R_VRAMCNT(1)=0x80;
    REG16(0x04000204)=exmem & ~(1u<<7);
    for(unsigned i=0;i<96*1024/4;i++) s_main[i]=pattern(i);
#ifdef LDM_DATA_MUTANT
    s_main[127]^=1; // loaded final r9 of the offset-zero LDM8 stream
#endif
    bool pass=region>=0, writes=true;
    if(pass) mt_cfg_set(region,0,0);
    cp15("uncached");
    buf_printf(&times,"case,words,offset_bytes,blocks,rep,ticks\n");
    buf_printf(&signatures,"case,offset_bytes,blocks,words,r2,r3,r4,r5,r6,r7,r8,r9,ok\n");
    unsigned measured=0, checks=0, failures=0;
    if(pass) for(unsigned k=0;k<sizeof cases/sizeof cases[0];k++) {
        const Case *c=&cases[k];
        const u32 *body=c->body?c->body:(const u32*)g_kern[OP_LDM][KM_SEQ];
        unsigned bytes=c->body?(unsigned)(c->end-c->body)*4:124;
        // All generated functions have the original anchor's prologue/epilogue.
        if(bytes+12>sizeof(s_itcm) || body[bytes/4-2]!=0xe8bd03f0 || body[bytes/4-1]!=0xe12fff1e) {pass=false;break;}
        for(unsigned off=0;off<(c->words?16:4);off+=4) {
            u32 base=(u32)s_main+off+(c->fixed?512:0);
            for(unsigned length=0;length<2;length++) {
                unsigned loops=length?64:16;
                memcpy(s_itcm,body,bytes);
                KFn timed=c->body?(KFn)s_itcm:g_kern[OP_LDM][KM_SEQ];
                u32 ticks[6];
                ticks[0]=mt_time(timed,base,loops,false); // full-length warm-up
                for(unsigned rep=0;rep<5;rep++) ticks[rep+1]=mt_time(timed,base,loops,false);
                for(unsigned rep=0;rep<6;rep++)
                    buf_printf(&times,"%s,%u,%u,%u,%d,%lu\n",c->name,c->words,off,loops*16,(int)rep-1,ticks[rep]);
                bool ok=check(c,body,bytes,base,loops);
                checks++; if(!ok) failures++;
            }
            measured++;
        }
        iprintf("%s done\n",c->name);
    }
    pass=pass && failures==0 && measured==53 && checks==106;
    mt_cfg_restore();
    REG16(0x04000204)=exmem; R_VRAMCNT(1)=vram_b;
    cp15("restored");
    buf_printf(&info,"cases=%u checks=%u failures=%u pass=%u\n",measured,checks,failures,pass);
    writes=buf_write(&times,"arm9ldm-v1/times.csv") && writes;
    writes=buf_write(&signatures,"arm9ldm-v1/signatures.csv") && writes;
    writes=buf_write(&info,"arm9ldm-v1/info.txt") && writes;
    if(pass && writes) hw_write("arm9ldm-v1/DONE.txt","PASS 53 cases 106 signatures\n",sizeof("PASS 53 cases 106 signatures\n")-1);
    else hw_write("arm9ldm-v1/FAILED.txt","functional/data/output failure\n",sizeof("functional/data/output failure\n")-1);
    iprintf("LDM %s\n",pass&&writes?"PASS":"FAIL");
    hw_done();
}
