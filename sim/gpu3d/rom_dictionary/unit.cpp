#include "Vtb_rom_dict.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <stdexcept>
int main(int argc,char**argv) {
    VerilatedContext c;c.threads(1);c.commandArgs(argc,argv);Vtb_rom_dict d{&c};
    uint64_t clocks=0,normal=0,holds=0,resets=0;uint32_t rng=0x7b615ad3;
    auto random=[&](){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;};
    auto cycle=[&](bool assert_after_M=false){
        d.eval();c.timeInc(1);d.clk2=1;d.eval();c.timeInc(1);d.clk2=0;d.eval();
        if(assert_after_M){d.rst=1;d.eval();++resets;}
        c.timeInc(1);d.clk=d.clk2=1;d.eval();c.timeInc(1);d.clk=d.clk2=0;d.eval();
        ++clocks;if(!d.rst)++normal;
    };
    // The first E has no useful prior index, as at PLL acquisition.
    d.rst=1;c.timeInc(1);d.clk=d.clk2=1;d.eval();c.timeInc(1);d.clk=d.clk2=0;d.eval();++clocks;
    for(int i=0;i<6;++i)cycle();d.rst=0;d.eval();
    for(unsigned pc=0;pc<2048;++pc){d.addr=pc;cycle();if(pc%17==0){cycle();cycle();holds+=2;}}
    for(unsigned pc=2048;pc-->0;){d.addr=pc;cycle();}
    for(unsigned i=0;i<4096;++i){
        d.addr=random()&2047;cycle();
        if(i%127==0){cycle(true);for(int k=0;k<3;++k){d.addr=random()&2047;cycle();}d.rst=0;d.eval();}
        if(i%23==0){cycle();++holds;}
    }
    unsigned tasks=0;for(auto const&x:std::filesystem::directory_iterator("/proc/self/task")){(void)x;++tasks;}
    if(tasks!=1||normal<8192||resets<30)throw std::runtime_error("ROMDICT coverage");
    std::printf("PASS ROMDICT images7 PCs2048 increasing+descending full70 E+M comparisons; clocks%llu normal%llu holds%llu dirtyMtoEresets%llu firstEreset tasks%u\n",(unsigned long long)clocks,(unsigned long long)normal,(unsigned long long)holds,(unsigned long long)resets,tasks);
    d.final();
}
