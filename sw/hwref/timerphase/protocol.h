#pragma once
#include <stdint.h>
#define TP_MAGIC 0x50485437u
#define TP_ROWS 512
#define TP_CODE_WORDS 256
#define TP_TIMEOUT (2u*33513982u)
#define TP_CH PxiChannel_User0
#define TP_PING 0x80
#define TP_RUN 0x81
#define TP_GUARD 0x5aa55aa5u
typedef struct {uint32_t clear_before,clear_after,read_before,if_word,read_after,hi_before,hi_after,guard;} TpRow;
typedef struct __attribute__((aligned(32))) {
 uint32_t magic,version,error,rows,entry,end,code_before,code_after,
  controls_before[4],counts_before[4],controls_after[4],counts_after[4],
  cpsr,enable0_before,enable0_after,enable1_before,enable1_after,warm_before,warm_after,reserved;
 TpRow samples[TP_ROWS];uint32_t code[TP_CODE_WORDS];
} TpResult;
typedef struct __attribute__((aligned(32))) {uint32_t magic,version,error,result_pointer,result_bytes,entry,end,fnv;} TpMeta;
extern const unsigned char tp_timer[],tp_timer_end[];
