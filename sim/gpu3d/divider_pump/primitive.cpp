#include "Vtb_private_divider.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <stdexcept>
int main(int argc,char**argv) {
    VerilatedContext ctx;ctx.threads(1);ctx.commandArgs(argc,argv);
    Vtb_private_divider d{&ctx};
    uint64_t rng=0xa7d4413b9625ef10ULL,clocks=0,cases=0,resets=0,restarts=0;
    auto random=[&](){rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;return rng;};
    auto tick=[&](){
        ctx.timeInc(1);d.clk2=1;d.eval();
        ctx.timeInc(1);d.clk2=0;d.eval();
        ctx.timeInc(1);d.clk=1;d.clk2=1;d.eval();
        ctx.timeInc(1);d.clk=0;d.clk2=0;d.eval();++clocks;
    };
    auto reset=[&](){d.rst=1;d.start=0;for(int i=0;i<4;i++)tick();d.rst=0;++resets;};
    reset();
    for(unsigned qb=0;qb<4;++qb) for(unsigned test=0;test<2048;++test) {
        if(test%127==0) {d.qb=3;d.num=random();d.den=1;d.start=1;tick();d.start=0;tick();reset();}
        uint64_t n=random();uint32_t den=uint32_t(random());
        const uint64_t nums[]={0,1,UINT64_MAX,0x100000000ULL,0xffffffffULL,0x8000000000000000ULL,0x7fffffffffffffffULL,0xffffULL};
        const uint32_t dens[]={0,1,2,3,0xffffffffU,0x80000000U,0x7fffffffU,0x10000U};
        if(test%3==0)n=nums[(test/3)%8];
        if(test%4==0)den=dens[(test/4)%8];
        if(test%7==0)n&=0x3ff;
        if(test%101==0) {d.qb=3;d.num=~n;d.den=den;d.start=1;tick();d.start=0;tick();++restarts;}
        d.qb=qb;d.num=n;d.den=den;d.start=1;tick();d.start=0;
        unsigned steps=0;
        while(d.busy){if(++steps>20)throw std::runtime_error("divider timeout");tick();}
        uint32_t expected=den?uint32_t(n/den):0xffffffffU;
        if(d.q!=expected){std::fprintf(stderr,"functional quotient mismatch qb=%u n=%016llx d=%08x q=%08x want=%08x\n",qb,(unsigned long long)n,den,d.q,expected);return 1;}
        tick();++cases;
    }
    unsigned tasks=0;for(auto const&e:std::filesystem::directory_iterator("/proc/self/task")){(void)e;++tasks;}
    if(tasks!=1)throw std::runtime_error("thread count");
    std::printf("PASS private divider cases=%llu clocks=%llu qb_modes=4 dirty_resets=%llu start_replacements=%llu tasks=%u\n",(unsigned long long)cases,(unsigned long long)clocks,(unsigned long long)resets,(unsigned long long)restarts,tasks);
    d.final();
}
