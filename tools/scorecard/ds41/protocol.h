#pragma once
typedef unsigned int u32;
typedef unsigned short u16;
#define R32(a) (*(volatile u32*)(a))
#define R16(a) (*(volatile u16*)(a))
#define CODE 0x01ff8020u
#define CONTEXT 0x02ff0000u
#define MARKER 0x02ff0040u
#define RESULT 0x02ff0100u
#define DUMP 0x023d0000u
#define MAGIC 0x314f4944u
struct Expected {u32 r[4],cpsr,before[5],after[5];};
struct Trial {u32 id,rep,r[4],entry_cpsr,before[5],after[5],code_before,code_after,error;};
struct Result {u32 magic,version,rows,cases,errors,done,reserved[10];u32 cp15[4][2][16];struct Trial trials[64];u32 live_code[4][80];};
extern const u32 kernels[4][80],kernel_words[4],expected_cp15[16];
extern const struct Expected expected[64];
extern void invoke(u32 captured_cpsr);
extern void adapter_done(void);
