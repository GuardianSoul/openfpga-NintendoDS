#pragma once
#include <stdint.h>
#define SL_MAGIC 0x534c5631u
#define SL_SAMPLES 8192
#define SL_CODE_BYTES 32768
#define SL_CH PxiChannel_User0
#define SL_PING 0x80
#define SL_RUN 0x100
#define TP_TIMEOUT (2u*33513982u) /* reuse the existing quiet ITCM helper */
#define SL_TIMEOUT 3351398u
typedef struct { uint32_t before,after,written,readback; } SlEvent;
typedef struct __attribute__((aligned(32))) {
 uint32_t magic,version,error,condition,cpsr,sp,code_base,code_bytes,
  code_before,code_after,wave_address[3],wave_before,wave_after,
  cap_timer,voice_timer,samples,epoch,finished,power_before,power_after;
 SlEvent clocks[2],capture,voices[2],switches[2],completion;
 uint32_t readable[16];
 uint8_t code[SL_CODE_BYTES];
 int16_t wave[2][16]; uint32_t silence[8];
 int16_t capture_pcm[2][SL_SAMPLES];
} SlResult;
typedef struct __attribute__((aligned(32))) {
 uint32_t magic,version,error,result_pointer,result_bytes,code_base,code_bytes,code_fnv;
} SlMeta;
extern SlResult sl_result;
extern unsigned char __wram_start[],__sl_code_end[];
void sl_measure(unsigned condition);
