/* Host protocol model, not native hardware evidence. It interprets complete
   serial bytes independently and tracks wall time separately from RTC writes. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "probe.h"
static unsigned ticks, wall_second, io, s1, s2, cmd, nbits, byte, pos, outbit;
static unsigned d[7], start_date[7], output[8], serial_writes, resets, alarms;
static int retain_high, frozen;
static unsigned decimal(unsigned v) { return 10*(v>>4)+(v&15); }
static unsigned encoded(unsigned v) { return 16*(v/10)+v%10; }
static unsigned cleaned(unsigned v,unsigned lo,unsigned hi) {
    unsigned n=decimal(v); return (v>>4)>9 || (v&15)>9 || n<lo || n>hi ? lo : n;
}
static unsigned mdays(unsigned y,unsigned m) {
    const unsigned v[]={31,28,31,30,31,30,31,31,30,31,30,31};
    return v[m-1]+(m==2 && y%4==0);
}
static void increment(unsigned *p) {
    if(++p[6]<60)return; p[6]=0;
    if(++p[5]<60)return; p[5]=0;
    if(++p[4]<24)return; p[4]=0; p[3]=(p[3]+1)%7;
    if(++p[2]<=mdays(p[0],p[1]))return; p[2]=1;
    if(++p[1]<=12)return; p[1]=1; p[0]=(p[0]+1)%100;
}
static void time_step(void) {
    ticks++;
    if(ticks/RTC_TIMER_HZ!=wall_second) {
        wall_second=ticks/RTC_TIMER_HZ;
        if(!frozen) increment(d);
    }
}
u32 rtc_now(void) { time_step(); return ticks; }
static void output_date(void) {
    for(int i=0;i<7;i++)output[i]=encoded(d[i]);
    output[3]=d[3]; output[4]=encoded((s1&2)?d[4]:d[4]%12)|(d[4]>=12?64:0);
}
static void command(unsigned value) {
    cmd=value; pos=0; outbit=0; memset(output,0,sizeof(output));
    if(cmd==0x86) { output[0]=s1; s1 &= 15; }
    else if(cmd==0xc6) output[0]=s2;
    else if(cmd==0xa6) output_date();
}
static void data(unsigned value) {
    serial_writes++;
    if(cmd==6) { if(value&1)resets++; s1=(s1&0xf0)|(value&14); }
    else if(cmd==0x26 || cmd==0x66) {
        unsigned field=pos+(cmd==0x66?4:0);
        switch(field) {
        case 0:d[0]=cleaned(value,0,99);break;
        case 1:d[1]=cleaned(value&31,1,12);break;
        case 2:d[2]=cleaned(value&63,1,31); if(d[2]>mdays(d[0],d[1])) {
            d[2]=1; if(++d[1]>12) {d[1]=1;d[0]=(d[0]+1)%100;} } break;
        case 3:d[3]=cleaned(value&7,0,6);break;
        case 4:d[4]=cleaned(value&63,0,(s1&2)?23:11)+(!(s1&2)&&(value&64)?12:0);break;
        case 5:d[5]=cleaned(value&127,0,59);break;
        case 6:d[6]=cleaned(value&127,0,59);break;
        }
    } else alarms++;
    pos++;
}
u32 rtc_port_read(u32 offset,u32 width) {
    time_step(); unsigned v=io;
    if(width==4)v|=0x5a5a0000;
    return width==1 ? (v>>(offset*8))&255 : v;
}
void rtc_port_write(u32 offset,u32 width,u32 value) {
    time_step();
    if(offset==1)return; /* Policy under investigation: high byte-only ignored. */
    unsigned old=io, v=value&255;
    if(retain_high && width>=2)io=value&0xff00; else io=retain_high?(io&0xff00):0;
    if((v&4) && !(old&4)) { nbits=0; byte=0; pos=0; cmd=0; outbit=0; }
    if((v&4)&&(old&4)&&!(v&2)) {
        if(v&16) {
            byte|=(v&1)<<nbits;
            if(++nbits==8) { if(!cmd) command(byte); else data(byte); nbits=0;byte=0; }
        } else {
            v=(v&~1u)|((output[outbit/8]>>(outbit%8))&1); outbit++;
        }
    } else if(!(v&16)) v=(v&~1u)|(old&1);
    io|=v;
}
static void require(int condition,const char *why) {
    if(!condition) { fprintf(stderr,"FAIL %s\n",why);exit(1); }
}
static void setup(int policy,unsigned status,unsigned interrupts) {
    ticks=wall_second=io=serial_writes=resets=alarms=0;
    s1=status;s2=interrupts;retain_high=policy;frozen=0;
    unsigned initial[]={99,12,31,5,23,59,58};
    memcpy(d,initial,sizeof(d));memcpy(start_date,d,sizeof(d));
}
int main(void) {
    rtc_log l;unsigned checks=0;
    for(int policy=0;policy<2;policy++) for(int mode=0;mode<2;mode++) {
        setup(policy,0x8c|(mode?2:0),0); rtc_probe(&l,1);
        require(l.outcome==RTC_DONE,"restoration outcome");
        require(l.count==13 && l.done,"all raw observations captured");
        require(!resets&&!alarms,"no reset/alarm writes");
        require((s1&14)==(0x0c|(mode?2:0))&&!s2,"writable status preserved");
        for(unsigned i=0;i<wall_second;i++)increment(start_date);
        require(!memcmp(d,start_date,sizeof(d)),"restored time accounts for elapsed midnight/year carry");
        require(l.rows[0].c==(policy?0x1250:0x50),"raw high-byte observation");
        require(l.saved_s1&128,"read-to-clear flag retained in record");
        checks+=7;
    }
    for(unsigned year=0;year<100;year++)for(unsigned month=1;month<=12;month++) {
        setup(year&1,0x0c|((month&1)?2:0),0);
        d[0]=year;d[1]=month;d[2]=mdays(year,month);
        memcpy(start_date,d,sizeof(d));rtc_probe(&l,1);
        for(unsigned i=0;i<wall_second;i++)increment(start_date);
        require(l.outcome==RTC_DONE&&!memcmp(d,start_date,sizeof(d)),"elapsed calendar carry across all 1200 months");checks++;
    }
    for(unsigned interrupts=1;interrupts<256;interrupts++) {
        setup(1,0x82,interrupts);rtc_probe(&l,1);
        require(l.outcome==RTC_SKIP_IRQ&&!serial_writes&&s1==0x82&&s2==interrupts,"interrupt configuration skip");checks++;
    }
    setup(1,0x82,0xff);rtc_probe(&l,0);
    require(l.outcome==RTC_DONE&&l.count==6&&!serial_writes&&s1==0x82&&s2==255,"IO-only does not read status/change chip");checks++;
    setup(0,2,0);io=4;rtc_probe(&l,1);
    require(l.outcome==RTC_SKIP_CS&&io==4&&!serial_writes,"active CS skip");checks++;
    setup(0,2,0);d[1]=0;rtc_probe(&l,1);
    require(l.outcome==RTC_BAD_DATE&&!serial_writes,"invalid original date skip");checks++;
    setup(0,2,0);frozen=1;rtc_probe(&l,1);
    require(l.outcome==RTC_NO_EDGE&&!serial_writes,"stopped RTC skip");checks++;
    printf("PASS %u host-model checks; no native execution\n",checks);
    return 0;
}
