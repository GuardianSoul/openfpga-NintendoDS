#include "Vtb_clip_queue.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <deque>
#include <filesystem>
#include <stdexcept>

int main(int argc, char** argv) {
    VerilatedContext ctx; ctx.threads(1); ctx.commandArgs(argc, argv);
    Vtb_clip_queue d{&ctx};
    std::deque<uint64_t> expected;
    uint32_t rng=0x73af218d;
    auto random=[&](){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;};
    uint64_t clocks=0, ones=0, zeros=0;
    constexpr uint64_t mask=(1ULL<<43)-1;
    auto tick=[&](bool push, bool pop, bool reset=false) {
        uint64_t word=((uint64_t(random())<<32)|random())&mask;
        d.pu=push; d.wfree=pop; d.rst=reset; d.pa=word>>32; d.pd=word;
        d.eval();
        if(reset) expected.clear();
        else {
            if(pop&&!expected.empty()) expected.pop_front();
            if(push) {expected.push_back(word);ones|=word;zeros|=(~word)&mask;}
        }
        ctx.timeInc(1);d.clk=1;d.eval();ctx.timeInc(1);d.clk=0;d.eval();++clocks;
        if(d.level!=expected.size()||bool(d.cw)!=!expected.empty()||bool(d.full)!=(expected.size()>=31))
            throw std::runtime_error("independent queue control mismatch");
        if(!expected.empty()&&(((uint64_t(d.cwa)<<32)|d.cwd)!=expected.front()))
            throw std::runtime_error("independent queue head/order mismatch");
    };
    d.clk=0; d.rst=1; d.eval(); tick(false,false,true);
    for(unsigned rep=0;rep<100;++rep) {
        while(expected.size()<31)tick(true,false);
        for(unsigned n=0;n<7;++n)tick(false,false);
        for(unsigned n=0;n<50;++n)tick(!d.full,true);
        while(!expected.empty())tick(false,true);
        tick(true,false);tick(true,true);tick(false,true);
        // Reset suppresses a pending push and retains all written cells.
        tick(true,false,true);
    }
    for(unsigned n=0;n<150000;++n) {
        bool push=(random()%4!=0)&&!d.full, pop=random()%3!=0;
        tick(push,pop,n%977==0);
    }
    while(!expected.empty())tick(false,true);
    unsigned tasks=0;for(auto const&e:std::filesystem::directory_iterator("/proc/self/task")){(void)e;++tasks;}
    std::printf("PASS queue clocks=%llu occupancy=%08x written=%08x empty=%u singleton=%u full=%u held=%u pushwrap=%u popwrap=%u resets=%u bits43=%d tasks=%u\n",
        (unsigned long long)clocks,d.occupancies,d.written,d.empty_arrivals,d.singleton,d.full_clocks,d.held,d.pushwrap,d.popwrap,d.resets,int(ones==mask&&zeros==mask),tasks);
    if(tasks!=1||d.occupancies!=0xffffffffU||d.written!=0xffffffffU||!d.empty_arrivals||!d.singleton||!d.full_clocks||!d.held||!d.pushwrap||!d.popwrap||ones!=mask||zeros!=mask)
        throw std::runtime_error("queue coverage");
    d.final();
}
