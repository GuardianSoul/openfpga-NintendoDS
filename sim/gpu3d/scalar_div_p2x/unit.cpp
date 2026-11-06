#include "Vtb_scalar_divider.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <stdexcept>

int main(int argc, char** argv) {
    VerilatedContext ctx; ctx.threads(1); ctx.commandArgs(argc, argv);
    Vtb_scalar_divider d{&ctx};
    uint64_t state=0xa7d4413b9625ef10ULL, cycles=0, cases=0, resets=0, replacements=0, late=0;
    auto random=[&](){state^=state<<13;state^=state>>7;state^=state<<17;return state;};
    auto tick=[&](bool change=false,uint64_t n=0,uint32_t den=0,unsigned qb=0){
        ctx.timeInc(1); d.clk2=1; d.eval();
        ctx.timeInc(1); d.clk2=0; d.eval();
        if(change){d.num=n;d.den=den;d.qb=qb;d.eval();++late;}
        ctx.timeInc(1);d.clk=1;d.clk2=1;d.eval();
        ctx.timeInc(1);d.clk=0;d.clk2=0;d.eval();++cycles;
    };
    d.rst=1;for(unsigned i=0;i<6;++i)tick();d.rst=0;
    for(unsigned qb=0;qb<4;++qb)for(unsigned test=0;test<4096;++test){
        if(test%97==0){
            d.start=1;d.qb=3;d.num=random();d.den=1;tick();d.start=0;tick();
            d.rst=1;d.start=test&1;tick();d.rst=0;d.start=0;++resets;
        }
        uint64_t n=random();uint32_t den=uint32_t(random());
        const uint64_t nums[]={0,1,UINT64_MAX,0x100000000ULL,0xffffffffULL,0x8000000000000000ULL,0x7fffffffffffffffULL,0xffffULL};
        const uint32_t dens[]={0,1,2,3,0xffffffffU,0x80000000U,0x7fffffffU,0x10000U};
        if(test%3==0)n=nums[(test/3)%8];
        if(test%4==0)den=dens[(test/4)%8];
        if(test%7==0)n&=0x3ff;
        if(test%101==0){d.start=1;d.qb=3;d.num=~n;d.den=den;tick();++replacements;}
        d.start=1;d.num=~n;d.den=~den;d.qb=(qb+1)%4;
        tick(true,n,den,qb);d.start=0;
        unsigned steps=0;
        while(d.busy){if(++steps>20)throw std::runtime_error("scalar divider timeout");
            d.num=random();d.den=uint32_t(random());d.qb=random()%4;tick();}
        uint32_t expected=den?uint32_t(n/den):UINT32_MAX;
        if(d.q!=expected){std::fprintf(stderr,"scalar quotient qb%u n%016llx d%08x q%08x expected%08x\n",qb,(unsigned long long)n,den,d.q,expected);return 2;}
        tick();++cases;
    }
    std::printf("PASS scalar new wrapper vs actual before: cases%llu SYS%llu dirtyreset%llu replacements%llu lateoperands%llu allSYSq%u MIDholds%u qb4/zero/restart/priority\n",
      (unsigned long long)cases,(unsigned long long)cycles,(unsigned long long)resets,
      (unsigned long long)replacements,(unsigned long long)late,d.sys_checks,d.mid_checks);
    d.final();
}
