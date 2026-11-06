// Shared result layout: all times are raw ARM7 TM0+TM1 system ticks.
#pragma once
#define PERF_CH PxiChannel_User0
#define PERF_MAGIC 0x50465431u
#define PERF_BAD 0x3ffffffu
#define PERF_LIMIT 3351398u // 100 ms; never an inferred hardware timing target
#define PERF_ROWS 160
#define PERF_SAMPLES 1024

enum { PERF_PING, PERF_SPI, PERF_AUX, PERF_WIFI, PERF_SOUND };
// Result-only kinds: timestamps around each channel enable and capture arm.
enum { PERF_SOUND_START = 5, PERF_SOUND_CAPTURE = 6, PERF_SOUND_CONFIG = 7 };
typedef struct {
    unsigned kind, arg, rep, ticks, before, after, timeout;
} PerfRow;
typedef struct {
    unsigned magic, command, n, status;
    PerfRow row[PERF_ROWS];
    short capture[2][PERF_SAMPLES];
} PerfResult;
