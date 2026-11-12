/* Shared native/host probe logic. No reset command or alarm/status2 writes. */
#include "probe.h"
static void port(u32 v) { rtc_port_write(0, 2, v); }
static void begin(void) { port(0x62); port(0x66); }
static void end(void) { port(0x62); }
static void send(u8 b) {
    for (int i = 0; i < 8; i++) { port(0x74 | ((b >> i) & 1)); port(0x76 | ((b >> i) & 1)); }
}
static u8 recv(void) {
    u8 v = 0;
    for (int i = 0; i < 8; i++) { port(0x64); v |= (rtc_port_read(0, 2) & 1) << i; port(0x66); }
    return v;
}
static void read_reg(u8 command, u8 *v, int n) {
    begin(); send(command); for (int i = 0; i < n; i++) v[i] = recv(); end();
}
static void write_reg(u8 command, const u8 *v, int n) {
    begin(); send(command); for (int i = 0; i < n; i++) send(v[i]); end();
}
static void mode(u8 v) { v &= 0x0e; write_reg(0x06, &v, 1); }
static u32 pack(const u8 *p, int n) {
    u32 v = 0; for (int i = 0; i < n; i++) v |= (u32)p[i] << (8 * i); return v;
}
static void raw(rtc_log *l, u32 kind, u32 a, u32 b, u32 c, u32 d) {
    if (l->count < 16) l->rows[l->count++] = (rtc_observation){kind,a,b,c,d};
}
static void date_raw(rtc_log *l, u32 kind) {
    u8 d[7]; read_reg(0xa6, d, 7); raw(l, kind, pack(d, 4), pack(d + 4, 3), 0, 0);
}
static int dec(u8 v) { return 10 * (v >> 4) + (v & 15); }
static u8 bcd(int v) { return (u8)(((v / 10) << 4) | (v % 10)); }
static int valid(u8 v, int lo, int hi) {
    return (v & 15) < 10 && (v >> 4) < 10 && dec(v) >= lo && dec(v) <= hi;
}
static int days(int y, int m) {
    static const u8 n[] = {31,28,31,30,31,30,31,31,30,31,30,31};
    return n[m - 1] + (m == 2 && (y & 3) == 0);
}
static int valid_date(const u8 *d, u8 s1) {
    return valid(d[0], 0, 99) && valid(d[1], 1, 12) &&
        valid(d[2], 1, days(dec(d[0]), dec(d[1]))) && d[3] <= 6 &&
        !(d[4] & 0x80) && valid(d[4] & 0x3f, 0, (s1 & 2) ? 23 : 11) &&
        (!(s1 & 2) || !!(d[4] & 64) == (dec(d[4] & 63) >= 12)) &&
        valid(d[5], 0, 59) && valid(d[6], 0, 59);
}
static void advance(u8 *d, u8 s1, u32 seconds) {
    int y=dec(d[0]), m=dec(d[1]), day=dec(d[2]), dow=d[3];
    int h=dec(d[4] & 63), mi=dec(d[5]), se=dec(d[6]);
    if (!(s1 & 2) && (d[4] & 64)) h += 12;
    while (seconds--) {
        if (++se == 60) { se=0; if (++mi == 60) { mi=0; if (++h == 24) {
            h=0; dow=(dow+1)%7; if (++day > days(y,m)) {
                day=1; if (++m == 13) { m=1; y=(y+1)%100; }
            }
        } } }
    }
    d[0]=bcd(y); d[1]=bcd(m); d[2]=bcd(day); d[3]=(u8)dow;
    d[4]=bcd((s1 & 2) ? h : h%12) | (h >= 12 ? 64 : 0);
    d[5]=bcd(mi); d[6]=bcd(se);
}
void rtc_probe(rtc_log *l, int clock_tests) {
    *l = (rtc_log){0}; l->magic=RTC_LOG_MAGIC; l->mode=clock_tests;
    l->saved_io=rtc_port_read(0,2);
    if (l->saved_io & 4) { l->outcome=RTC_SKIP_CS; goto finish; }
    /* CS remains low through every width experiment: no chip command. */
    static const u32 widths[] = {2,1,1,4,2,1};
    static const u32 offsets[] = {0,0,1,0,0,1};
    static const u32 values[] = {0x1250,0x50,0xab,0xa55a3450,0x0050,0xff};
    for (int i=0;i<6;i++) {
        rtc_port_write(offsets[i],widths[i],values[i]);
        u32 lo=rtc_port_read(0,1), hi=rtc_port_read(1,1);
        raw(l, i, lo, hi, rtc_port_read(0,2), rtc_port_read(0,4));
    }
    port(l->saved_io);
    if (!clock_tests) { l->outcome=RTC_DONE; goto finish; }
    u8 s2, s1; read_reg(0xc6,&s2,1); l->saved_s2=s2;
    /* Conservatively refuse ALL nonzero status2, before reading status1. */
    if (s2) { l->outcome=RTC_SKIP_IRQ; goto restore_io; }
    read_reg(0x86,&s1,1); l->saved_s1=s1;
    /* Status1 reads clear transient flags; only bits1..3 can be restored. */
    read_reg(0xa6,l->saved,7);
    if (!valid_date(l->saved,s1)) { l->outcome=RTC_BAD_DATE; goto restore_io; }
    u32 start=rtc_now(), previous=start, edge=start;
    for (;;) {
        u8 d[7]; read_reg(0xa6,d,7); edge=rtc_now();
        if (d[6] != l->saved[6]) {
            if (!valid_date(d,s1)) { l->outcome=RTC_BAD_DATE; goto restore_io; }
            for (int i=0;i<7;i++) l->saved[i]=d[i];
            l->edge_bracket_ticks=edge-previous; break;
        }
        if (edge-start > 2*RTC_TIMER_HZ) { l->outcome=RTC_NO_EDGE; goto restore_io; }
        previous=edge;
    }
    /* From here every exit must restore date/time and writable status. */
    mode((s1 & 0x0c) | 2);
    static const u8 invalid1[]={0x23,0x04,0x31,0x09,0x25,0x5a,0x60};
    static const u8 invalid2[]={0xa0,0x13,0,3,0x13,7,9};
    static const u8 pm[]={0x47,0x10,0};
    static const u8 noon[]={0x40,0,0};
    static const u8 bad12[]={0x59,0x80,0x80};
    write_reg(0x26,invalid1,7); date_raw(l,0x10);
    write_reg(0x26,invalid2,7); date_raw(l,0x11);
    mode(s1 & 0x0c); date_raw(l,0x12);
    write_reg(0x66,pm,3); date_raw(l,0x13);
    mode((s1 & 0x0c)|2); date_raw(l,0x14);
    mode(s1 & 0x0c); write_reg(0x66,noon,3); date_raw(l,0x15);
    write_reg(0x66,bad12,3); date_raw(l,0x16);
    mode(s1);
    l->elapsed_ticks=rtc_now()-edge;
    l->added_seconds=l->elapsed_ticks/RTC_TIMER_HZ+1;
    for (int i=0;i<7;i++) l->expected[i]=l->saved[i];
    advance(l->expected,s1,l->added_seconds);
    /* Commit on the next measured second boundary. Remaining uncertainty:
       edge polling bracket + serial write duration + timer frequency error. */
    while (rtc_now()-edge < l->added_seconds*RTC_TIMER_HZ) ;
    u32 commit=rtc_now(); write_reg(0x26,l->expected,7);
    l->restore_ticks=rtc_now()-commit;
    read_reg(0xa6,l->restored,7);
    read_reg(0x86,&s1,1); l->final_s1=s1;
    read_reg(0xc6,&s2,1); l->final_s2=s2;
    l->outcome=RTC_DONE;
    for (int i=0;i<7;i++) if (l->restored[i]!=l->expected[i]) l->outcome=RTC_RESTORE_MISMATCH;
    if ((l->final_s1 & 14)!=(l->saved_s1 & 14) || l->final_s2!=l->saved_s2)
        l->outcome=RTC_RESTORE_MISMATCH;
restore_io:
    port(l->saved_io);
finish:
    l->done=1;
}
