#pragma once
#include "ds.h"
#include "protocol.h"
#define N_PRIVATE 0x03800740u
#define N_MAIN 0x02fcd000u
#define N_WRAPPER 0x03800850u
#define N_RETURN 0x0380088cu
#define N_WARM 0x0380fd40u
#define N_TIMED 0x0380fdc0u
#define N_RESULT ((MmResult*)0x02fce000u)
#define N_RESULT9 ((const MmResult*)0x023ce000u)
#define N_RECORD(i) ((MmResult*)(0x02200000u+(i)*0x1800u))
#define N_STATUS ((volatile u32*)0x02230000u)
#define N_CONTEXT ((volatile u32*)0x02231000u)
extern const u8 captured_kernel[],captured_wrapper[],captured_helper[],captured_helper_end[];
u32 native_invoke(MmKernel,u32,u32,MmInvocation*,u32);
void *memcpy(void*,const void*,u32);
void *memset(void*,int,u32);
int memcmp(const void*,const void*,u32);
