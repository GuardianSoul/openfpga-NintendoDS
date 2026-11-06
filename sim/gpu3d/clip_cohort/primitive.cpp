#include "Vtb_clip_cohort.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <stdexcept>

int main(int argc,char**argv) {
    VerilatedContext ctx;ctx.threads(1);ctx.commandArgs(argc,argv);Vtb_clip_cohort d{&ctx};
    uint64_t clocks=0,jobs=0,checks=0;unsigned resets=0,seed=0x716aa812;
    auto random=[&](){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;};
    auto tick=[&](bool reset_after_M=false){
        d.clk=d.clk2=0;d.eval();ctx.timeInc(1);d.clk2=1;d.eval();
        ctx.timeInc(1);d.clk2=0;d.eval();
        if(reset_after_M){d.rst=1;d.eval();++resets;}
        ctx.timeInc(1);d.clk=d.clk2=1;d.eval();
        ctx.timeInc(1);d.clk=d.clk2=0;d.eval();++clocks;
    };
    auto reset=[&](){d.rst=1;d.start=d.go=0;tick();tick();d.rst=0;d.eval();};
    reset();
    for(unsigned job=0;job<1060;++job) {
        const unsigned mask=job>=1036?511:job<1024?job%512:((job&1)?511:0);
        d.nm=0x7fffffff;d.den=job<1024?0x10000000:job<1030?0:job<1036?0xffffffff:0x10000000;
        d.signs=0;
        uint64_t product[9];unsigned actual_mask=0;
        for(unsigned i=0;i<9;++i){
            d.dv[i]=(mask>>i&1)?(0x60000000|(random()&0xfffffff)):(1+(random()&0xffff));
            d.m0[i]=d.nm;
            product[i]=uint64_t(int64_t(int32_t(d.dv[i]))*int64_t(int32_t(d.nm)));
            actual_mask|=unsigned((product[i]>>32)>=d.den)<<i;
        }
        if(job<1024&&actual_mask!=mask)throw std::runtime_error("class construction");
        d.go=1;tick();d.go=0;d.start=1;const uint64_t start=clocks+1;tick();d.start=0;++jobs;
        const bool abort=job>=1036;const unsigned abort_age=(job-1036)%18;
        for(unsigned age=0;;++age) {
            if(abort&&age==abort_age){tick(true);reset();break;}
            for(unsigned i=0;i<9;++i) {
                const unsigned duration=(actual_mask>>i&1)?17:8;
                const bool expected=clocks<start+duration;
                if(bool(d.busy>>i&1)!=expected){std::fprintf(stderr,"busy job%u age%llu lane%u\n",job,(unsigned long long)(clocks-start),i);throw std::runtime_error("busy oracle");}
                if(!expected){const uint32_t want=d.den?uint32_t(product[i]/d.den):0xffffffffU;
                    if(d.q[i]!=want)throw std::runtime_error("quotient oracle");++checks;}
            }
            if(!d.busy)break;
            if(age>18)throw std::runtime_error("cohort drain");
            tick();
        }
    }
    unsigned tasks=0;for(auto const&e:std::filesystem::directory_iterator("/proc/self/task")){(void)e;++tasks;}
    if(tasks!=1||jobs!=1060||resets!=24||!checks)throw std::runtime_error("coverage/thread guard");
    std::printf("PASS cohort primitive SYS=%llu jobs=%llu masks=512 twice oracle=%llu M-resets=%u tasks=%u\n",(unsigned long long)clocks,(unsigned long long)jobs,(unsigned long long)checks,resets,tasks);
    d.final();
}
