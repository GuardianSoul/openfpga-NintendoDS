#include "Vtb_clip_wordbanks.h"
#include "verilated.h"
#include "addresses.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <stdexcept>

int main(int argc,char**argv) {
    VerilatedContext ctx;ctx.threads(1);ctx.commandArgs(argc,argv);
    Vtb_clip_wordbanks d{&ctx};
    uint32_t rng=0x9c314f27;
    auto random=[&]() {rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;};
    uint64_t clocks=0,accepted=0,injected=0,events=0;
    uint64_t old_collisions=0,neighbours=0,heads=0,colours=0,full=0,held=0;
    unsigned block_write=0;
    bool collisions=false;
    auto tick=[&](bool external=false) {
        d.clk=0;d.wfree=!external&&!block_write&&(random()%8==0);d.eval();
        bool injected_now=false;
        if(!external && collisions && d.read_valid && random()%3==0) {
            unsigned port=random()%18;
            while(!(d.read_valid&(1u<<port)))port=(port+1)%18;
            d.we=1;d.wa=0x200|d.read_addr[port];d.wd=random();d.wfree=0;injected_now=true;++injected;
        } else if(!external) {d.we=d.cw&&d.wfree;d.wa=d.cwa;d.wd=d.cwd;}
        d.eval();accepted+=!d.rst&&d.cw&&d.wfree;events+=!d.rst&&d.nnew_v;
        ctx.timeInc(1);d.clk=1;d.eval();ctx.timeInc(1);d.clk=0;d.eval();++clocks;
        if(block_write)--block_write;
        (void)injected_now;
    };
    auto snapshot=[&]() {old_collisions+=d.old_data_collisions;neighbours+=d.neighbour_reads;heads+=d.head_reads;colours+=d.colour_reads;full+=d.full_clocks;held+=d.held_clocks;};
    auto reset=[&]() {snapshot();d.rst=1;d.run=0;tick();tick();d.rst=0;block_write=0;};
    auto write=[&](unsigned addr,uint32_t data) {d.we=1;d.wa=addr;d.wd=data;tick(true);d.we=0;};
    reset();d.can=1;
    for(unsigned addr=0x200;addr<0x400;++addr)write(addr,random());
    for(unsigned test=0;test<120;++test) {
        unsigned ln=test%13==0?0: test%7==0?10:3+test%2;
        unsigned cs=std::min(ln,(test%4==0?2u:0u));
        collisions=test%3!=0;
        write(FU_A_LN,ln);write(FU_A_CS,cs);
        const unsigned masks[]={1,2,4,8,16,32,63,0};
        write(PU_A_OCM,masks[test%8]);
        write(LU_A_CATTR,(test&1)?4096:0);
        write(PU_A_POOL,0x200+16*(test%5==0?31:test%2?16:8));
        for(unsigned i=0;i<ln;++i) {
            unsigned g=i;
            write(FU_A_LA+i,0x200+16*g);
            for(unsigned w=0;w<16;++w) {
                uint32_t v=random();
                if(w==3)v=4096;
                if(w<3) {
                    const int32_t xy[]={-8192,8192,0,4096,-4096,1,-1};
                    v=uint32_t(xy[(test+i+w)%7]);
                }
                write(0x200+16*g+w,v);
            }
        }
        d.can=0;d.run=1;block_write=300;
        for(unsigned i=0;i<7;++i)tick();
        d.can=1;tick();
        for(unsigned n=0;d.cond;++n) {
            if(n>100000)throw std::runtime_error("clip timeout");
            tick();
        }
        d.run=0;
        if(test%29==28) {
            // Reset with dirty memory and queue storage. Subsequent cases
            // initialize their real inputs, never all the mirror contents.
            reset();d.can=1;
        }
    }
    unsigned tasks=0;for(auto const&e:std::filesystem::directory_iterator("/proc/self/task")){(void)e;++tasks;}
    snapshot();
    std::printf("clocks=%llu cases=120 acceptedRF=%llu injectedRF=%llu result_events=%llu tasks=%u old_collisions=%llu neighbour=%llu head=%llu colour=%llu full=%llu held=%llu\n",
       (unsigned long long)clocks,(unsigned long long)accepted,(unsigned long long)injected,(unsigned long long)events,tasks,(unsigned long long)old_collisions,(unsigned long long)neighbours,(unsigned long long)heads,(unsigned long long)colours,(unsigned long long)full,(unsigned long long)held);
    std::fflush(stdout);
    if(tasks!=1||!injected||!old_collisions||!neighbours||!heads||!colours||!full||!held)throw std::runtime_error("coverage guard");
    std::puts("PASS complete clip bank/output/control/state/cycle equivalence");
}
