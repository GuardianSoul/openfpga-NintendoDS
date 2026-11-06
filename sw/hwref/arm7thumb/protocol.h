#pragma once
#include <stdint.h>
#define AT_MAGIC 0x3754484du
#define AT_VERSION 1
#define AT_CASES 9
#define AT_REPS 5
#define AT_CODE_WORDS 128
#define AT_DATA_WORDS 1024
#define AT_TOTAL_CASES (AT_CASES+1)
#define AT_TIMER_ROWS 320
#define AT_TIMER_CODE_WORDS 256
#define AT_TIMEOUT (2u*33513982u)
#define AT_CH PxiChannel_User0
#define AT_PING 0x80
#define AT_RUN 0x81
#define AT_BAD 0x03ffffffu
#define AT_INITIAL 0x6ac3f19du
#define AT_VALUE 0x13579bdfu
#define AT_GUARD 0x5aa55aa5u
extern const unsigned char at_alu[],at_alu_body[],at_alu_end[];
extern const unsigned char at_branch[],at_branch_body[],at_branch_end[];
extern const unsigned char at_ldr_sp[],at_ldr_sp_body[],at_ldr_sp_end[];
extern const unsigned char at_str_sp[],at_str_sp_body[],at_str_sp_end[];
extern const unsigned char at_ldr_pc[],at_ldr_pc_body[],at_ldr_pc_end[];
extern const unsigned char at_str_reg[],at_str_reg_body[],at_str_reg_end[];
extern const unsigned char at_ldrh[],at_ldrh_body[],at_ldrh_end[];
extern const unsigned char at_strh[],at_strh_body[],at_strh_end[];
extern const unsigned char at_stm1[],at_stm1_body[],at_stm1_end[];
typedef uint32_t (*AtKernel)(uint32_t,uint32_t,uint32_t);
typedef struct {uint32_t entry,body,end,fnv;} AtDescriptor;
typedef struct __attribute__((aligned(32))) {uint32_t magic,version,cases,error,result_pointer,scratch,guard_before,guard_after;AtDescriptor d[AT_CASES];AtDescriptor timer;uint32_t timer_result_pointer,timer_rows,timer_bytes,reserved;} AtMeta;
typedef struct {uint32_t loops,ticks,warm_return,returned,scratch_fnv,sp_before,sp_after,cpsr,signature[7],error;} AtSample;
typedef struct __attribute__((aligned(32))) {
 uint32_t magic,version,id,error,entry,body,end,code_bytes,code_before,code_after,scratch,guard_before,guard_after,reserved[3];
 AtSample samples[AT_REPS][2];uint32_t code[AT_CODE_WORDS],scratch_final[AT_DATA_WORDS];
} AtResult;
extern const unsigned char at_timer[],at_timer_end[];
typedef struct {uint32_t mode,prescaler,delay,cpsr,before2,after2,before_action,after_action,
 count_before,count_after,count_after2,if_before,prev2,event2,prev3,event3,
 if_after,control2,control3,error,stopped2a,stopped2b,stopped3a,stopped3b;} AtTimerSample;
typedef struct __attribute__((aligned(32))) {
 uint32_t magic,version,id,error,entry,end,code_bytes,code_before,code_after,rows,
  control_before[2],value_before[2],control_after[2],value_after[2],reserved[14];
 AtTimerSample samples[AT_TIMER_ROWS];uint32_t code[AT_TIMER_CODE_WORDS];
} AtTimerResult;
typedef struct __attribute__((aligned(32))) {AtDescriptor leaf;uint32_t rows,bytes,reserved[2];} AtTimerMeta;
