// Source-staged experiment only. No DS arbitration rule or target latency.
#pragma once
#define WA_CH PxiChannel_User0
#define WA_MAGIC 0x57415231u
#define WA_BAD 0x3ffffffu
#define WA_LIMIT 3351398u
#define WA_SAMPLES 1024
#define WA_PING 0
#define WA_SOUND 1
#define WA_HANDOVER 2

typedef struct __attribute__((aligned(32))) {
    volatile unsigned go;
    unsigned reserved[7];
} WaControl;
typedef struct __attribute__((aligned(32))) {
    volatile unsigned phase; // 1 ready, 2 kernel starts, 3 complete
    unsigned reserved[7];
} WaStatus;
typedef struct __attribute__((aligned(32))) {
    unsigned magic, command, error, ticks, checksum, before, after, private_addr;
    unsigned source_addr, count, start_line, end_line, cap_timeout, reserved[3];
    WaControl control; // ARM9-owned line; flush independently
    WaStatus status;   // ARM7-owned line; invalidate independently
    short capture[WA_SAMPLES];
} WaResult;
