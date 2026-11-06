#include "Vtb_brom.h"
#include "verilated.h"
#include "oracle.h"
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <stdexcept>

int main(int argc,char**argv) {
    VerilatedContext c;c.threads(1);c.commandArgs(argc,argv);Vtb_brom d{&c};
    uint32_t rng=0x72b2418c;uint64_t clocks=0,checks=0,prev=0;
    unsigned resets=0,late=0;bool seen[2048]{};
    auto random=[&](){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;};
    auto cycle=[&](bool late_addr=false,bool after_M_reset=false){
        d.clk=d.clk2=0;d.eval();c.timeInc(1);d.clk2=1;d.eval();
        c.timeInc(1);d.clk2=0;d.eval();
        if(late_addr){d.addr=random()&2047;d.eval();++late;}
        if(after_M_reset){d.rst=1;d.eval();++resets;}
        const unsigned addr=d.addr;
        c.timeInc(1);d.clk=d.clk2=1;d.eval();
        if(d.q!=prev||d.operand!=IMM[(prev>>12)&127]||d.preview!=B[addr])throw std::runtime_error("independent full B/operand/preview oracle");
        prev=B[addr];seen[addr]=true;++checks;
        c.timeInc(1);d.clk=d.clk2=0;d.eval();++clocks;
    };
    d.rst=1;for(int i=0;i<6;++i)cycle();d.rst=0;
    for(unsigned a=0;a<2048;++a){d.addr=a;cycle();}
    for(unsigned a=2048;a-->0;){d.addr=a;cycle();}
    for(unsigned i=0;i<8192;++i){
        d.addr=random()&2047;cycle(i%3==0,i%127==0);
        if(d.rst){cycle(true);cycle();d.rst=0;}
        if(i%23==0){cycle();cycle();}
    }
    unsigned coverage=0;for(bool x:seen)coverage+=x;
    unsigned tasks=0;for(auto const&e:std::filesystem::directory_iterator("/proc/self/task")){(void)e;++tasks;}
    if(tasks!=1||coverage!=2048||late<2000||resets<60)throw std::runtime_error("BROM coverage/thread guard");
    std::printf("PASS BROM full35 B/full32 operand/originalpreview SYS+M; clocks%llu oracle%llu addresses%u lateMtoE%u dirtyresets%u tasks%u\n",(unsigned long long)clocks,(unsigned long long)checks,coverage,late,resets,tasks);
    d.final();
}
