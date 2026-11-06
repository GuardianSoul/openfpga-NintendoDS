#include "Vtb_coupled_pump.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <initializer_list>
#include <stdexcept>
int main(int argc,char**argv) {
    VerilatedContext ctx;ctx.threads(1);ctx.commandArgs(argc,argv);Vtb_coupled_pump d{&ctx};
    uint32_t rng=0x92b31843;uint64_t clocks=0,writes=0,reads=0,resets=0;
    auto random=[&](){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;};
    auto tick=[&](bool dirty_reset=false){
        d.tick=clocks&1;d.po_ready=random()%5!=0;d.eval();
        ctx.timeInc(1);d.clk_2x=1;d.eval();ctx.timeInc(1);d.clk_2x=0;d.eval();
        if(dirty_reset){d.rst=1;d.eval();++resets;}
        ctx.timeInc(1);d.clk=1;d.clk_2x=1;d.eval();ctx.timeInc(1);d.clk=0;d.clk_2x=0;d.eval();++clocks;
    };
    d.rst=1;for(int i=0;i<6;i++)tick();d.rst=0;
    auto write=[&](unsigned addr,uint32_t value){
        d.io_req=1;d.io_we=1;d.io_addr=(addr>>2)&255;d.io_wdata=value;d.eval();
        unsigned waits=0;while(d.io_wait){if(++waits>100000)throw std::runtime_error("write timeout");tick();}
        tick();d.io_req=0;tick();++writes;
    };
    auto read=[&](unsigned addr){
        d.io_req=1;d.io_we=0;d.io_addr=(addr>>2)&255;tick();unsigned waits=0;
        while(!d.io_ack){if(++waits>100000)throw std::runtime_error("read timeout");tick();}
        d.io_req=0;tick();++reads;
    };
    auto cmd=[&](unsigned code,std::initializer_list<uint32_t> args){
        if(args.size())for(uint32_t a:args)write(0x400+code*4,a);else write(0x400+code*4,0);
    };
    auto init=[&](){write(0x600,0x80000000U);cmd(0x10,{0});cmd(0x15,{});cmd(0x10,{2});cmd(0x15,{});cmd(0x60,{0xbfff0000});};
    init();
    for(unsigned frame=0;frame<4;++frame) {
        if(frame==1||frame==3){
            // A live partial matrix command and its pending engine state are
            // discarded by an assertion strictly after M, before E.
            cmd(0x10,{2});write(0x458,0x1000);write(0x458,random());tick(true);
            for(int k=0;k<4;++k)tick();d.rst=0;d.eval();init();
        }
        cmd(0x30,{0x7fff7fff});cmd(0x31,{0x7fff7fff});
        for(unsigned light=0;light<4;++light){cmd(0x32,{(light<<30)|0x200});cmd(0x33,{(light<<30)|0x7fff});}
        for(unsigned poly=0;poly<24;++poly) {
            unsigned kind=poly%4,n=kind==0?3:kind==1?4:kind==2?6:8;
            cmd(0x29,{0x1f00c0U|((poly%8)<<24)|((poly%3==0)?15:0)});cmd(0x2a,{(poly&1)?0x40000000U:0});cmd(0x40,{kind});
            for(unsigned v=0;v<n;++v) {
                const int xs[]={-8192,8192,0,-2048,4096,-4096,2048,0};
                const int ys[]={-2048,-2048,8192,2048,0,0,-4096,4096};
                int x=xs[(v+poly)%8],y=ys[v%8],z=poly%5==0?-8192:1024;
                if(poly%4==0){x/=4;y/=4;z=1024;}
                if(v==0)cmd(0x20,{random()&0x7fff});cmd(0x22,{random()});cmd(0x21,{random()&0x3fffffff});
                cmd(0x23,{uint32_t(uint16_t(x))|(uint32_t(uint16_t(y))<<16),uint16_t(z)});
                if(v==1&&poly%6==0)read(0x600);
            }
            cmd(0x41,{});
        }
        cmd(0x10,{2});for(unsigned i=0;i<16;++i)write(0x458,i%5==0?0x1000:0);read(0x640);read(0x604);
        for(unsigned n=0;!d.dbg_idle;++n){if(n>200000)throw std::runtime_error("caller drain timeout");tick();}

    }
    for(unsigned n=0;!d.dbg_idle;++n){if(n>200000)throw std::runtime_error("idle timeout");tick();}
    unsigned tasks=0;for(auto const&e:std::filesystem::directory_iterator("/proc/self/task")){(void)e;++tasks;}
    std::printf("PASS Cohort71 actual caller clocks=%llu writes=%llu reads=%llu starts=%u fast=%u slow=%u held=%u safe=%u CATTR=%u confirms=%u aborts=%u outcomes=%u tasks=%u\n",(unsigned long long)clocks,(unsigned long long)writes,(unsigned long long)reads,d.light_starts,d.fast_starts,d.slow_starts,d.held_cycles,d.safe_active,d.cattr_active,d.confirm_count,d.abort_count,d.outcomes,tasks);
    if(tasks!=1||d.light_starts<40||!d.fast_starts||!d.slow_starts||!d.held_cycles||!d.safe_active||!d.outcomes)throw std::runtime_error("caller coverage");
    if(!d.clip_starts||!d.fin_starts)throw std::runtime_error("cohort caller clip/finish coverage");
    std::printf("COHORT boundaries clip=%u finish=%u RF=%u headers=%u vertices=%u late=%u heldbeats=%u\n",d.clip_starts,d.fin_starts,d.rf_writes,d.headers,d.vertices,d.late_clocks,d.held_beats);
    d.final();
}
