#include "Vtb_entry_banks.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <filesystem>
#include <stdexcept>
#include <utility>
#include <vector>

int main(int argc,char**argv) {
    VerilatedContext ctx; ctx.threads(1); ctx.commandArgs(argc,argv);
    Vtb_entry_banks d{&ctx};
    uint32_t seed=0x4102a981;
    auto random=[&](){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;};
    constexpr uint64_t mask=(1ULL<<40)-1;
    auto word=[&](){return ((uint64_t(random())<<8)|uint8_t(random()))&mask;};
    uint64_t clocks=0,ram_reads=0,same=0,cross=0,bank_turns=0,pushes=0,pops=0;
    uint64_t write_beats=0,read_beats=0,dirty=0,full=0,guarded=0,wraps=0;
    bool written[4096]{},popped_bank[2]{};
    auto step=[&](){d.clk=0;d.eval();ctx.timeInc(1);d.clk=1;d.eval();ctx.timeInc(1);d.clk=0;d.eval();++clocks;};
    d.rst=1;step();step();
    std::array<uint64_t,4096> memory{};
    unsigned last_ra=0;
    auto ram=[&](unsigned ra,bool we,unsigned wa,uint64_t wd,bool check=true){
        d.m_we=we;d.m_ra=ra;d.m_wa=wa;d.m_wd=wd;d.m_valid=check;
        auto expected=memory[ra];step();
        if(check && d.m_q!=expected)throw std::runtime_error("independent full40 OLD_DATA mismatch");
        if(we)memory[wa]=wd;
        if(check){++ram_reads;same+=we&&wa==ra;cross+=we&&((wa^ra)&2048);bank_turns+=((last_ra^ra)&2048)!=0;}
        last_ra=ra;
    };
    for(unsigned a=0;a<4096;++a)ram(a,true,a,word(),false);
    for(unsigned a=0;a<4096;++a){
        ram(a,false,0,0);ram(a,true,a,word());
        ram(a,true,a^1,word());ram(a,true,a^2048,word());
        ram(a^2048,false,0,0);
    }
    for(unsigned i=0;i<40000;++i){
        unsigned a=random()&4095,b=random()&4095;
        uint64_t v=i%43<40 ? (1ULL<<(i%43)) : i%43==40 ? 0 : mask;
        ram(a,true,b,v);
    }
    d.m_valid=0;d.m_we=0;
    std::deque<uint64_t> queue;
    std::vector<uint32_t> sdram(1<<19);
    std::vector<std::pair<unsigned,uint32_t>> pending;
    unsigned rp=0,wr=0,read_address=0,read_index=0,read_delay=0;
    bool read_active=false;
    auto reset=[&](){
        dirty+=!queue.empty();d.rst=1;d.ram_we=0;d.e_pop=0;d.sp_wack=0;d.sp_rack=0;d.sp_rvalid=0;
        step();step();queue.clear();pending.clear();read_active=false;rp=wr=0;
        d.dp=d.e_addr=d.wr=d.mx=0;d.rst=0;
    };
    reset();
    constexpr unsigned base=0x0c0000;
    unsigned highwater=0;
    for(unsigned c=0;c<160000;++c){
        if(c==6700 || c==58600 || c==109300)reset();
        bool drain=c%17==0;
        if(drain){for(auto [a,v]:pending)sdram.at(a)=v;pending.clear();}
        d.sp_wdrained=drain;
        d.sp_wack=(random()%5)!=0;
        d.sp_rack=!read_active && ((random()%5)!=0);
        d.sp_rvalid=read_active && read_delay==0 && ((random()%4)!=0);
        d.sp_rdata=d.sp_rvalid?sdram.at(read_address+read_index):0;
        d.oq_full=(c%137>=129); // independent outcome backpressure
        d.dp=rp&511;d.wr=wr&511;d.mx=wr&511;
        d.e_pop=0;d.ram_we=0;d.e_addr=d.dp;d.eval();
        unsigned segment=c%24000;
        bool want_write=segment<7000 || (segment>=10000&&segment<17000&&(random()&1));
        bool want_pop=segment>=7000 && ((random()%4)!=0);
        bool pop=want_pop&&d.e_avail;
        bool push=want_write&&!d.sp_full;
        full+=d.occupancy==4096;
        guarded+=d.occupancy && !d.e_avail && d.guards;
        if(pop){
            if(queue.empty() || d.e_data!=queue.front())throw std::runtime_error("independent spill full40 queue/order mismatch");
            popped_bank[(rp>>11)&1]=true;
        }
        d.e_pop=pop;d.ram_we=push;d.do_exec=push;d.ram_wd=word();
        d.e_addr=(d.dp+unsigned(pop))&511;d.eval();
        bool wtake=d.sp_wreq&&d.sp_wack;
        bool rack=d.sp_rreq&&d.sp_rack;
        bool rbeat=d.sp_rvalid;
        unsigned wa=d.sp_waddr-base,ra=d.sp_raddr-base;
        uint32_t wd=d.sp_wdata;
        if(d.mem_we)written[d.mem_wa]=true;
        if(pop){queue.pop_front();++pops;++rp;if((rp&4095)==0)++wraps;}
        if(push){queue.push_back(d.ram_wd);++pushes;++wr;}
        step();
        if(wtake){pending.emplace_back(wa,wd);++write_beats;}
        if(rack){read_active=true;read_address=ra;read_index=0;read_delay=2;}
        else if(read_active){
            if(read_delay)--read_delay;
            else if(rbeat){++read_beats;if(++read_index==8)read_active=false;}
        }
        highwater=std::max(highwater,unsigned(d.occupancy));
        if(queue.size()!=unsigned(d.occupancy)+unsigned(d.spilled) || d.sp_used!=queue.size())
            throw std::runtime_error("independent occupancy conservation mismatch");
        if(d.rp!=(rp&4095))throw std::runtime_error("physical/modulo pointer mismatch");
    }
    unsigned locations=0,tasks=0;
    for(bool x:written)locations+=x;
    for(auto const& x:std::filesystem::directory_iterator("/proc/self/task")){(void)x;++tasks;}
    if(tasks!=1 || locations!=4096 || !popped_bank[0] || !popped_bank[1] || !write_beats || !read_beats || dirty!=3 || !full || !guarded || wraps<2)
        throw std::runtime_error("coverage/one-thread guard");
    std::printf("PASS clocks=%llu RAM40=%llu sameOLD=%llu crossbank=%llu bankturns=%llu pushes=%llu pops=%llu writebeats=%llu readbeats=%llu dirtyresets=%llu fullclocks=%llu guarded=%llu wraps=%llu locations=%u highwater=%u tasks=%u\n",
      (unsigned long long)clocks,(unsigned long long)ram_reads,(unsigned long long)same,
      (unsigned long long)cross,(unsigned long long)bank_turns,(unsigned long long)pushes,
      (unsigned long long)pops,(unsigned long long)write_beats,(unsigned long long)read_beats,
      (unsigned long long)dirty,(unsigned long long)full,(unsigned long long)guarded,
      (unsigned long long)wraps,locations,highwater,tasks);
}
