/* Native adapter for the qualified run39 ARM7 fetch probe. */
#pragma once
#include "../common/ds.h"
#define AF_MAGIC 0x41463731u
#define AF_VERSION 1
#define AF_CASES 18
#define AF_REPS 5
#define AF_TIMEOUT (2u*33513982u)
#define AF_RESULT ((AfResult *)0x02fdf000u)
#define AF_RESULT9 ((const AfResult *)0x023df000u)
#define AF_RECORD(i) ((AfResult *)(0x02200000u+(i)*0x1200u))
#define AF_STATUS ((volatile u32 *)0x02230000u)
typedef struct { u32 loops,ticks,warm_checksum,checksum,start_line,end_line; } AfSample;
typedef struct __attribute__((aligned(32))) {
 u32 magic,version,case_id,region,error,size,source_entry,source_body;
 u32 source_end,entry,body,end,source_fnv,copy_fnv,copy_match,reserved;
 AfSample samples[AF_REPS][2];
 char name[24];
 u32 kind,offset,stride,nodes,checksum_per_loop;
 u32 code[1024];
} AfResult;
typedef struct { u32 source,body,end,main,fnv,kind,offset,stride,nodes,checksum;
 const char *name; const u32 *blob; } AfCase;
typedef u32 (*AfKernel)(u32);
_Static_assert(sizeof(AfResult)==4448,"captured run39 result layout");
static inline u32 af_clock(void) {
 u16 h=R16(0x04000104),l=R16(0x04000100),h2=R16(0x04000104);
 if(h!=h2){l=R16(0x04000100);h=h2;}return ((u32)h<<16)|l;
}
void *memcpy(void *,const void *,u32);
void *memset(void *,int,u32);
