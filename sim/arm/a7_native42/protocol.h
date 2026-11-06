#pragma once
#include "ds.h"
#include "case_protocol.h"
#define N_RESULT ((AtResult*)0x02fdf000u)
#define N_RESULT9 ((const AtResult*)0x023df000u)
#define N_RECORD(i) ((AtResult*)(0x02200000u+(i)*0x1800u))
#define N_STATUS ((volatile u32*)0x02230000u)
#define N_CONTEXT ((volatile u32*)0x02231000u)
#define N_SCRATCH ((u32*)0x038039c0u)
#define N_SP 0x0380fd88u
typedef struct {u32 entry,body,end,fnv;const u8*blob;} NativeCase;
extern const NativeCase native_cases[9];
extern const u8 captured_helper[],captured_helper_end[];
extern volatile u32 native_sp_before,native_sp_after,native_cpsr;
u32 native_invoke(u32 kernel,u32 loops,u32 scratch,u32 signature);
void *memcpy(void*,const void*,u32);
void *memset(void*,int,u32);
static inline u32 n_clock(void){u16 h=R16(0x04000104),l=R16(0x04000100),h2=R16(0x04000104);if(h!=h2){l=R16(0x04000100);h=h2;}return ((u32)h<<16)|l;}
_Static_assert(sizeof(AtResult)==5312,"DS42 raw result ABI");
