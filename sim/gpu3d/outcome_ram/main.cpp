#include "Vtb_outcome_ram.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <stdexcept>
#include <filesystem>

int main(int argc, char** argv) {
    VerilatedContext ctx;
    ctx.threads(1);
    ctx.commandArgs(argc,argv);
    Vtb_outcome_ram d{&ctx};
    uint32_t rng=0x9a31c624;
    auto random=[&]() { rng^=rng<<13; rng^=rng>>17; rng^=rng<<5; return rng; };
    uint64_t clocks=0,pushes=0,pops=0,collisions=0,full=0,replaces=0;
    bool covered[513]{};
    d.clk=0; d.rst=1; d.qen=1;
    d.f_geom_en=1;
    auto step=[&]() {
        d.clk=0; d.eval();
        ctx.timeInc(1); d.clk=1; d.eval();
        ctx.timeInc(1); d.clk=0; d.eval(); ++clocks;
    };
    auto reset=[&]() { d.rst=1; step(); step(); d.rst=0; };
    reset();
    auto qcycle=[&](bool push,bool pop) {
        covered[d.qcount]=true;
        if (pop && d.qcount==0) throw std::runtime_error("invalid pop");
        if (push && !pop && d.qcount==512) throw std::runtime_error("invalid push");
        if (push && (d.qcount==0 || (d.qcount==1 && pop))) ++collisions;
        if (d.qcount==1 && push && pop) ++replaces;
        if (d.qcount>=511) ++full;
        d.qpush=push; d.qtake=pop; d.qbits=random()&0x7ff;
        d.qovf=(random()&7)==0; d.qblank=(random()&63)==0;
        d.qflush=random()&1; d.qen=random()&1;
        d.qepop=random()&1; d.qexec=random()&1;
        pushes+=push; pops+=pop;
        step();
    };
    // Every starting occupancy, all four legal push/pop combinations,
    // across many pointer wraps, including full and singleton replacement.
    for (int round=0;round<4;++round) {
        while (d.qcount) qcycle(false,true);
        for (int n=0;n<=512;++n) {
            qcycle(false,false);
            if(n) { qcycle(false,true); qcycle(true,false); qcycle(true,true); }
            if(n<512) { qcycle(true,false); qcycle(false,true); qcycle(true,false); }
        }
        while (d.qcount) qcycle(false,true);
    }
    for (int i=0;i<250000;++i) {
        auto r=random(); bool pop=d.qcount && (r&1);
        bool push=(d.qcount<512 || pop) && (r&2);
        qcycle(push,pop);
        if (i%997==996) reset(); // dirty RAM survives reset; validity must not.
    }
    d.qpush=0; d.qtake=0; reset();
    // Complete front equations: direct command writes, real model take,
    // early and late physical-result inputs, LOAD44 and input pauses.
    // Five source pairs cover DSX/read-tail, legacy/cheap and the vm34 cache.
    uint64_t writes=0,oc=0;
    unsigned pending=0;
    unsigned pause_until=0;
    bool load_pause=false;
    bool saw_pending=false;
    unsigned outcome_release=0;
    for (unsigned c=0;c<180000;++c) {
        d.f_tick=c&1;
        d.f_vblank=(c%20000)==19999;
        if(d.front_pending && !saw_pending) { saw_pending=true; outcome_release=c+600; }
        d.f_oc_valid=saw_pending && c>=outcome_release && (c%7)==0 && d.front_pending;
        if(d.f_oc_valid) ++oc;
        d.f_oc_rej=(oc%5)==0; d.f_oc_quad=(oc%3)==0;
        d.f_oc_side=oc&1; d.f_oc_nv=3+oc%2; d.f_oc_ncl=oc%4;
        d.f_engine_ovf=(c%83)==0;
        d.f_wr_be=15;
        if(writes==17 && !load_pause) { load_pause=true; pause_until=c+256; }
        if(!d.f_wr_req && writes<2400 && c>=pause_until && !(c>=450 && c<650)) {
            // Matrix mode 2 + LOAD44, then repeated triangle vertices.
            if(writes==0) { d.f_wr_addr=0x10; d.f_wr_data=2; }
            else if(writes<=16) { d.f_wr_addr=0x16; d.f_wr_data=((writes-1)%5)==0?0x1000:0; }
            else if(writes==17) { d.f_wr_addr=0x40; d.f_wr_data=0; }
            else { d.f_wr_addr=0x24; d.f_wr_data=(writes*0x10201)&0x3fffffff; }
            d.f_wr_req=1;
            pending=31;
        }
        // Each mode accepts the write once, keeping its data held while
        // staging. The abstract engine consumes only advertised entries.
        d.f_wr_enable=pending;
        d.f_e_pop=1;
        d.eval();
        unsigned accepted=d.f_wr_req ? pending & ~d.front_wait : 0;
        step();
        pending &= ~accepted;
        if(d.f_wr_req && !pending) { ++writes; d.f_wr_req=0; }
    }
    unsigned tasks=0;
    for(auto const& entry:std::filesystem::directory_iterator("/proc/self/task")) { (void)entry; ++tasks; }
    for(bool seen:covered) if(!seen) throw std::runtime_error("missing occupancy");
    if(tasks!=1 || collisions==0 || replaces==0 || full==0 || writes<2400 || !d.front_takes || !d.front_late || !d.front_load44) {
        std::fprintf(stderr,"coverage tasks=%u collisions=%llu replaces=%llu highwater=%llu writes=%llu pending=%x waits=%x takes=%u late=%u load44=%u\n",tasks,(unsigned long long)collisions,(unsigned long long)replaces,(unsigned long long)full,(unsigned long long)writes,pending,d.front_wait,d.front_takes,d.front_late,d.front_load44);
        throw std::runtime_error("coverage/thread guard");
    }
    std::printf("PASS clocks=%llu pushes=%llu pops=%llu collisions=%llu singleton_replace=%llu highwater=%llu front_writes=%llu outcomes=%llu configs=5 tasks=%u front_takes=%u late=%u load44=%u\n",
        (unsigned long long)clocks,(unsigned long long)pushes,(unsigned long long)pops,(unsigned long long)collisions,(unsigned long long)replaces,(unsigned long long)full,(unsigned long long)writes,(unsigned long long)oc,tasks,d.front_takes,d.front_late,d.front_load44);
}
