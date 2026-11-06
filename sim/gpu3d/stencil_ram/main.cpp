#include "Vtb_stencil_ram.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_stencil_ram m;
    std::array<uint8_t,512> words{}, initialized{};
    uint64_t clocks=0, checked=0, collisions=0, witnesses=0;
    bool negative=argc>1 && std::string(argv[1])=="+mutant";
    auto tick=[&](bool we, unsigned waddr, unsigned data, unsigned raddr) {
        m.we=we; m.waddr=waddr; m.wdata=data; m.raddr=raddr;
        const unsigned expected=words[raddr];
        m.clk=0; m.eval(); m.clk=1; m.eval(); clocks++;
        if (initialized[raddr]) {
            checked++; collisions+=we && waddr==raddr;
            if (m.before_q!=expected || m.after_q!=expected) {
                std::printf("FAIL old-data clock=%llu r=%u w=%u expected=%u before=%u after=%u\n",
                            (unsigned long long)clocks,raddr,waddr,expected,m.before_q,m.after_q);
                std::exit(2);
            }
            if (m.mutant_q!=expected) {
                witnesses++;
                if (negative) {
                    std::printf("MUTANT_CAUGHT actual stencil bit1 write removed clock=%llu expected=%u mutant=%u\n",
                                (unsigned long long)clocks,expected,m.mutant_q);
                    std::exit(1);
                }
            }
        }
        if (we) {words[waddr]=data;initialized[waddr]=1;}
    };
    for (unsigned a=0;a<512;a++) tick(true,a,0,a);
    for (unsigned data=0;data<4;data++)
        for (unsigned a=0;a<512;a++) {
            tick(true,a,data,a); // old value on the same write/read edge
            tick(false,0,0,a);   // new value exactly one edge later
        }
    uint32_t rng=0x50a1c019;
    auto next=[&](){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;};
    for (unsigned i=0;i<100000;i++) {
        auto x=next(),y=next();unsigned a=x&511;
        tick((x>>9)&1,a,(x>>10)&3,(i&3)?y&511:a);
    }
    for (unsigned a=0;a<512;a++) tick(false,0,0,a);
    if (negative || witnesses==0) return 3;
    std::printf("PASS_STENCIL_OLD_DATA clocks=%llu checked=%llu collisions=%llu mutant_witnesses=%llu addresses=512 values=4\n",
                (unsigned long long)clocks,(unsigned long long)checked,
                (unsigned long long)collisions,(unsigned long long)witnesses);
    m.final();
}
