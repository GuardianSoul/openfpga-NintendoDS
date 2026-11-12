// Execute the same C probe against actual nds_rtc RTL. One test timer tick
// per simulation clock, SEC_TICKS=32728; this accelerates wall time only.
#include "Vnds_rtc.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
extern "C" {
#define RTC_PROBE_HOST
#include "probe.h"
}
static Vnds_rtc *top;
static u32 cycles;
static void step() {
    top->clk=0;top->eval();top->clk=1;top->eval();cycles++;
}
extern "C" u32 rtc_now(void) { step();return cycles; }
extern "C" u32 rtc_port_read(u32 offset,u32 width) {
    top->io_req=1;top->io_we=0;top->io_be=15;step();
    u32 value=top->io_rdata;top->io_req=0;
    for(int i=0;i<3;i++)step();
    return width==1?(value>>(8*offset))&255:width==2?value&65535:value;
}
extern "C" void rtc_port_write(u32 offset,u32 width,u32 value) {
    top->io_req=1;top->io_we=1;top->io_be=((1u<<width)-1)<<offset;
    top->io_wdata=value<<(8*offset);step();top->io_req=0;top->io_we=0;
    for(int i=0;i<3;i++)step();
}
static void require(bool condition,const char *why) {
    if(!condition){std::fprintf(stderr,"FAIL %s\n",why);std::exit(1);}
}
int main(int argc,char **argv) {
    Verilated::commandArgs(argc,argv);top=new Vnds_rtc;
    top->tick=1;top->rst=1;for(int i=0;i<4;i++)step();
    top->rst=0;for(int i=0;i<24;i++)step();
    rtc_log l;rtc_probe(&l,0);
    require(l.done&&l.outcome==RTC_DONE&&l.count==6,"IO-only completion");
    require(l.rows[0].c==0x50&&l.rows[3].c==0x50,"raw zero-high-byte RTL observation");
    rtc_probe(&l,1);
    require(l.done&&l.outcome==RTC_DONE&&l.count==13,"clock test and restoration");
    require(l.rows[6].a==0x01010523&&l.rows[6].b==0,"invalid-date carry raw observation");
    require(l.rows[7].a==0x03010100&&l.rows[7].b==0x090753,"invalid BCD raw observation");
    require((l.rows[8].b&255)==0x41,"24-to12 conversion");
    require((l.rows[9].b&255)==0x47&&(l.rows[10].b&255)==0x59,"PM write and 12-to24 conversion");
    require((l.rows[11].b&255)==0x40&&(l.rows[12].b&255)==0x40,"noon and invalid12 input");
    require((l.saved_s1&14)==(l.final_s1&14)&&l.saved_s2==l.final_s2,"writable status restored");
    std::printf("PASS 9 RTC RTL probe checks, %u cycles, added %u seconds, edge bracket %u ticks, restore %u ticks; no native CPU execution\n",cycles,l.added_seconds,l.edge_bracket_ticks,l.restore_ticks);
    delete top;
}
