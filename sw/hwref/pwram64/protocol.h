#pragma once
#include <stdint.h>
#define PW_MAGIC 0x50575231u
#define PW_VERSION 1
#define PW_CH PxiChannel_User0
#define PW_PING 0x90
#define PW_RUN 0x91
#define PW_BAD 0x03ffffffu
#define PW_CASES 13
#define PW_REPS 5
#define PW_TIMEOUT (2u*33513982u)
#define PW_SEED 0x6d2b79f5u
#define PW_BASE 0x03800000u
#define PW_WORDS 16384
#define PW_VALUE 0x12341234u
#define PW_CODE 1024
static const uint32_t pw_counts[PW_CASES]={1,8,64,256,1024,2048,16384,8,9,16,256,2048,16384};
typedef struct { uint32_t cpsr,sp,ime,ie,iflags,exmemcnt,wramstat,tm0,tm0ctl,tm1,tm1ctl,vcount,soundcnt,ipcsync,biosprot,powcnt2; } PwContext;
typedef struct { uint32_t operations,before,after,ticks,value,pre_fnv,post_fnv,start_line,end_line,terminal,kind,reserved[5]; } PwSample;
typedef struct __attribute__((aligned(32))) {
 uint32_t magic,version,case_id,error,nodes,stores,fixed,seed,stack_lo,stack_hi;
 uint32_t entry_chain,end_chain,entry_store,end_store,entry_read,end_read,entry_switch,end_switch;
 uint32_t backup_fnv,restored_fnv,guard_fnv,dma_src,dma_dst,dma_words;
 uint32_t capture_timeout,sound_src,sound_timer,sound_ctrl,restore_equal,result_bytes,code_bytes,reserved;
 PwContext before,after;
 PwSample samples[PW_REPS][3];
 uint8_t code_before[PW_CODE],code_after[PW_CODE];
 int16_t capture[64];
 uint32_t image[PW_WORDS];
} PwResult;
_Static_assert(sizeof(PwSample)==64,"sample ABI");
_Static_assert(sizeof(PwResult)==68928,"result ABI");
extern unsigned char pw_chain[],pw_chain_end[],pw_store[],pw_store_end[],pw_read[],pw_read_end[],pw_switch[],pw_switch_end[];
uint32_t pw_chase(uint32_t pointer,uint32_t count,uint32_t* terminal);
uint32_t pw_stores(uint32_t count,uint32_t distinct,uint32_t* unused);
uint32_t pw_reads(uint32_t count,uint32_t distinct,uint32_t* unused);
void pw_run_shared(void);
static inline uint32_t pw_fnv(const void* data,uint32_t n) { const uint8_t* p=data;uint32_t h=2166136261u;for(uint32_t i=0;i<n;i++)h=(h^p[i])*16777619u;return h; }
static inline uint32_t pw_guard(uint32_t i) { return 0x5a5a0000u^i; }

// Seeded Fisher-Yates cycle; this table is used only outside timed kernels.
static inline void pw_graph(uint32_t nodes,uint16_t* order,uint16_t* next) {
 uint32_t seed=PW_SEED;
 for(uint32_t i=0;i<nodes;i++)order[i]=i;
 for(uint32_t i=nodes;i>1;i--){seed=seed*1664525u+1013904223u;uint32_t j=seed%i;uint16_t x=order[i-1];order[i-1]=order[j];order[j]=x;}
 for(uint32_t i=0;i<nodes;i++)next[order[i]]=order[(i+1)%nodes];
}
