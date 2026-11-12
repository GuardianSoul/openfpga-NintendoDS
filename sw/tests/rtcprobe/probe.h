#ifndef RTC_PROBE_H
#define RTC_PROBE_H
#ifdef RTC_PROBE_HOST
#include <stdint.h>
typedef uint8_t u8;
typedef uint32_t u32;
#else
#include "../common/ds.h"
#endif
#define RTC_LOG_ADDR 0x023F2000u
#define RTC_LOG_MAGIC 0x31505452u /* RTP1 */
#define RTC_TIMER_HZ 32728u /* ARM7 33,513,982 Hz / 1024, rounded down */
enum { RTC_DONE = 1, RTC_SKIP_CS, RTC_SKIP_IRQ, RTC_BAD_DATE,
       RTC_NO_EDGE, RTC_RESTORE_MISMATCH };
typedef struct { u32 kind, a, b, c, d; } rtc_observation;
typedef struct {
    u32 magic, done, mode, outcome, count;
    u32 saved_io, saved_s1, saved_s2, final_s1, final_s2;
    u32 elapsed_ticks, added_seconds, edge_bracket_ticks, restore_ticks;
    u8 saved[7], expected[7], restored[7], pad[3];
    rtc_observation rows[16];
} rtc_log;
u32 rtc_port_read(u32 offset, u32 width);
void rtc_port_write(u32 offset, u32 width, u32 value);
u32 rtc_now(void);
void rtc_probe(rtc_log *log, int clock_tests);
#endif
