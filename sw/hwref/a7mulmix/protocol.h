#pragma once
#include <stdint.h>
#define MM_MAGIC 0x414d5831u
#define MM_VERSION 1
#define MM_CH PxiChannel_User0
#define MM_PING 0x90
#define MM_RUN 0x91
#define MM_BAD 0x03ffffffu
#define MM_CASES 3
#define MM_REPS 5
#define MM_SLOT_WORDS 1024
#define MM_CODE_WORDS 128
#define MM_TIMEOUT (2u*33513982u)
typedef struct { uint32_t pre[16],post[16]; } MmInvocation;
// Register order: r0..r12,sp,lr,cpsr. The wrapper uses private-WRAM output.
typedef struct {
 uint32_t loops,ticks,warm_value,value,warm_checksum,checksum,start_line,end_line;
 MmInvocation warm,timed;
} MmSample;
typedef struct {
 uint32_t cpsr,sp,ime,ie,iflags,exmemcnt,wramstat,tm0,tm0ctl,tm1,tm1ctl;
 uint32_t vcount,soundcnt,ipcsync,biosprot,powcnt2;
} MmContext;
typedef struct __attribute__((aligned(32))) {
 uint32_t magic,version,case_id,region,error,size,source_entry,source_body;
 uint32_t source_end,entry,body,end,source_fnv,copy_fnv,copy_match,rs2;
 uint32_t rs6,wrapper_return,reserved[6];
 MmContext before,after;
 MmSample samples[MM_REPS][2];
 uint32_t code_before[MM_CODE_WORDS],code_after[MM_CODE_WORDS];
} MmResult;
_Static_assert(sizeof(MmInvocation)==128,"invocation ABI");
_Static_assert(sizeof(MmSample)==288,"sample ABI");
_Static_assert(sizeof(MmContext)==64,"context ABI");
_Static_assert(sizeof(MmResult)==4128,"result ABI");
typedef uint32_t (*MmKernel)(uint32_t,uint32_t,uint32_t);
extern uint32_t mm_mul(uint32_t,uint32_t,uint32_t);
extern unsigned char mm_mul_body[],mm_mul_end[],mm_return[];
extern uint32_t mm_invoke(MmKernel,uint32_t,uint32_t,MmInvocation*,uint32_t);

// Operand classes: all-small anchor, all-large anchor, alternating-width case.
// r6 is a fifth AAPCS argument installed before the first snapshot, not per MUL.
static const uint32_t mm_rs2[MM_CASES]={0x7f,0x7fffffff,0x7f};
static const uint32_t mm_rs6[MM_CASES]={0x7f,0x7fffffff,0x7fffffff};
static inline int mm_valid_invocation(const MmInvocation* v,uint32_t n,
 uint32_t rs2,uint32_t rs6,uint32_t entry,uint32_t return_pc)
{
 if(v->pre[0]!=n||v->pre[1]!=3||v->pre[2]!=rs2||v->pre[6]!=rs6||
    v->post[0]||v->post[1]!=3||v->post[2]!=rs2||v->post[3]!=3u*rs6)return 0;
 for(int i=4;i<15;i++)if(v->pre[i]!=v->post[i])return 0;
 if(v->pre[4]!=entry||v->pre[14]!=return_pc||
    v->pre[5]<0x03800000||v->pre[5]>0x03810000-128||v->pre[5]%4||
    v->pre[13]<0x03800000||v->pre[13]>=0x03810000||v->pre[13]%8||
    (v->pre[15]&0xa0)!=0x80)return 0;
 return (v->post[15]&0xf0000000)==0x60000000&&
        (v->post[15]&0x0fffffff)==(v->pre[15]&0x0fffffff);
}

static inline int mm_complete(uint32_t complete,uint32_t fresh,uint32_t resumed,
 uint32_t failed,uint32_t interrupted)
{
 return complete==MM_CASES*2&&fresh+resumed==MM_CASES*2&&!failed&&!interrupted;
}
