#include "Vtb_finalize_mlab.h"
#include "verilated.h"
#include "addresses.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <stdexcept>

int main(int argc,char**argv) {
    VerilatedContext ctx; ctx.threads(1); ctx.commandArgs(argc,argv);
    Vtb_finalize_mlab d{&ctx};
    uint32_t rng=0x7642e95a;
    auto random=[&]() {rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;};
    uint64_t cycles=0,acks=0,beats=0,starts=0;
    bool hold_output=false,arm_publication=false;
    int release_after=0,block_writes=0;
    auto tick=[&](bool external=false) {
        d.clk=0; d.wfree=!external && block_writes==0 && (random()%4!=0);
        d.ofree=(!hold_output || (d.pv && !d.ptype)) && (random()%4!=0); d.sct=random();
        d.eval();
        if(!external) {d.we=d.cw&&d.wfree;d.wa=d.cwa;d.wd=d.cwd;}
        d.eval(); bool was_q=d.q_active;
        acks+=!d.rst&&d.cw&&d.wfree; beats+=!d.rst&&d.pv&&d.ofree;
        ctx.timeInc(1);d.clk=1;d.eval();
        ctx.timeInc(1);d.clk=0;d.eval();++cycles;
        if(arm_publication&&!was_q&&d.q_active) {hold_output=true;arm_publication=false;release_after=0;}
        else if(release_after>0 && --release_after==0) hold_output=false;
        if(block_writes>0) --block_writes;
    };
    auto reset=[&]() {d.rst=1;d.run=0;d.hgo=0;tick();tick();d.rst=0;hold_output=false;arm_publication=false;release_after=0;block_writes=0;};
    auto write=[&](unsigned addr,uint32_t value) {d.we=1;d.wa=addr;d.wd=value;tick(true);d.we=0;};
    auto wait_ready=[&]() {for(unsigned n=0;!d.ready;++n){if(n>10000)throw std::runtime_error("ready timeout");tick();}};
    auto run_op=[&](unsigned xarg) {d.run=1;d.xarg=xarg;tick();for(unsigned n=0;d.cond;++n){if(n>10000)throw std::runtime_error("FRUN timeout");tick();}d.run=0;};
    reset();
    // Initialize every RF group, including arbitrary full-width reused
    // FZ/W1/W2/W3. This catches accidental narrowing of reused records.
    for(unsigned a=0x200;a<0x400;++a) write(a,random());
    for(unsigned test=0;test<240;++test) {
        wait_ready();
        bool fast=test%3!=0,manual=!fast && test%2==0;
        unsigned ln=fast ? 3+test%2 : test%11;
        unsigned cs=fast ? (test%4==0?2:0) : std::min(ln,test%4);
        bool wbuf=test&1;
        write(FU_A_LN,ln);write(FU_A_CS,cs);write(FU_A_FATTR,wbuf?2:0);
        write(FU_A_TEXPAL,random());write(FU_A_FACING,random());
        write(FU_A_TRT,random());write(FU_A_TRA,random());write(LU_A_CATTR,random());write(FU_A_TEXP,random());
        for(unsigned k=0;k<6;++k) write(FU_A_VP+k,random());
        for(unsigned i=0;i<ln;++i) {
            unsigned group=fast ? i : 6+i;
            write(FU_A_LA+i,0x200+16*group);
            if(i<4)d.h_la[i]=0x200+16*group;
            for(unsigned k=0;k<16;++k) {
                uint32_t v=random();
                if(k==3) {const uint32_t ws[]={0,1,0xffff,0x10000,0xffffff,0x123456};v=ws[(test+i)%6];}
                write(0x200+16*group+k,v);
            }
        }
        // Hold a preceding publication through the next start and early
        // result writes; hold new publications for the following case.
        release_after=120;
        arm_publication=!manual;
        block_writes=150;
        if(fast) {
            d.h_ln=ln;d.h_cs=cs;d.h_face=test&1;d.h_wb=(test/2)&1;
            d.hgo=1;tick();d.hgo=0;++starts;
            for(unsigned n=0;!d.ready;++n) {
                if(n>10000)throw std::runtime_error("fast timeout");
                // Real fast finishes read their snapshot while later
                // commands write the rotating source slots.
                if(n%3==0) write(0x200+(random()%96),random()); else tick();
            }
        } else {
            ++starts;
            if(manual) {run_op(0);run_op(1);} else run_op(3);
        }
        if(test%19==18) {
            // Abandon a live published bank; the next operation must not
            // depend on clearing RAM or on the previous bank selector.
            reset();
        }
    }
    hold_output=false;arm_publication=false;release_after=0;block_writes=0;
    for(unsigned n=0;d.busy;++n) {if(n>10000)throw std::runtime_error("drain timeout");tick();}
    unsigned tasks=0;for(auto const& e:std::filesystem::directory_iterator("/proc/self/task")){(void)e;++tasks;}
    std::printf("cycles=%llu starts=%llu total_cw=%llu total_beats=%llu tasks=%u final_window: cw=%u hdr=%u vertices=%u overlap=%u publish_pending=%u triple=%u reuse=%u new=%u zskip=%u holdcw=%u holdpv=%u\n",
      (unsigned long long)cycles,(unsigned long long)starts,(unsigned long long)acks,(unsigned long long)beats,tasks,d.cw_takes,d.headers,d.vertices,d.overlap_starts,d.publish_pending,d.triple,d.reuse_writes,d.new_writes,d.z_skips,d.hold_cw,d.hold_pv);
    std::fflush(stdout);
    if(tasks!=1||!d.overlap_starts||!d.publish_pending||!d.triple||!d.reuse_writes||!d.z_skips||!d.hold_cw||!d.hold_pv)throw std::runtime_error("coverage guard");
    std::puts("PASS complete finalize output/control/state/cycle equivalence");
}
