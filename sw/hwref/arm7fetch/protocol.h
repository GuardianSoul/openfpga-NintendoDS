#pragma once
#include <stdint.h>
#define AF_MAGIC 0x41463731u
#define AF_VERSION 1
#define AF_CH PxiChannel_User0
#define AF_PING 0x80
#define AF_RUN 0x81
#define AF_BAD 0x03ffffffu
#define AF_SLOT_WORDS 1024
#define AF_REPS 5
#define AF_TIMEOUT (2u*33513982u)
typedef struct {
 uint32_t loops,ticks,warm_checksum,checksum,start_line,end_line;
} AfSample;
typedef struct __attribute__((aligned(32))) {
 uint32_t magic,version,case_id,region,error,size,source_entry,source_body;
 uint32_t source_end,entry,body,end,source_fnv,copy_fnv,copy_match,reserved;
 AfSample samples[AF_REPS][2];
 char name[24];
 uint32_t kind,offset,stride,nodes,checksum_per_loop;
 uint32_t code[AF_SLOT_WORDS];
} AfResult;
