#pragma once
#include <stdint.h>
#define MP_MAGIC 0x41504d31u
#define MP_VERSION 1
#define MP_CH PxiChannel_User0
#define MP_PING 0x90
#define MP_RUN 0x91
#define MP_BAD 0x03ffffffu
#define MP_CASES 4
#define MP_REPS 5
#define MP_SLOT_WORDS 1024
#define MP_CODE_WORDS 128
#define MP_TIMEOUT (2u*33513982u)
typedef struct { uint32_t pre[16],post[16]; } MpInvocation;
// Register order: r0..r12,sp,lr,cpsr. The wrapper uses private-WRAM output.
typedef struct {
 uint32_t loops,ticks,warm_value,value,warm_checksum,checksum,start_line,end_line;
 MpInvocation warm,timed;
} MpSample;
typedef struct {
 uint32_t cpsr,sp,ime,ie,iflags,exmemcnt,wramstat,tm0,tm0ctl,tm1,tm1ctl;
 uint32_t vcount,soundcnt,ipcsync,biosprot,powcnt2;
} MpContext;
typedef struct __attribute__((aligned(32))) {
 uint32_t magic,version,case_id,region,error,size,source_entry,source_body;
 uint32_t source_end,entry,body,end,source_fnv,copy_fnv,copy_match,rs;
 MpContext before,after;
 MpSample samples[MP_REPS][2];
 uint32_t code_before[MP_CODE_WORDS],code_after[MP_CODE_WORDS];
} MpResult;
_Static_assert(sizeof(MpInvocation)==128,"invocation ABI");
_Static_assert(sizeof(MpSample)==288,"sample ABI");
_Static_assert(sizeof(MpContext)==64,"context ABI");
_Static_assert(sizeof(MpResult)==4096,"result ABI");
typedef uint32_t (*MpKernel)(uint32_t,uint32_t,uint32_t);
extern uint32_t mp_mul(uint32_t,uint32_t,uint32_t);
extern unsigned char mp_mul_body[],mp_mul_end[],mp_return[];
extern uint32_t mp_invoke(MpKernel,uint32_t,uint32_t,MpInvocation*);
