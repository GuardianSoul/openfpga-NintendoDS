#include "Vtb_od_ram.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <stdexcept>
int main(int argc,char**argv){
 VerilatedContext ctx;ctx.threads(1);ctx.randReset(2);ctx.commandArgs(argc,argv);Vtb_od_ram d{&ctx};
 uint32_t rng=0x5ad731e9,mem[64]={};uint64_t clocks=0,pauses=0;
 auto random=[&](){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;};
 auto tick=[&](){uint32_t expected=mem[d.ra];if(d.we)mem[d.wa]=d.wd&0x1ffffff;
  ctx.timeInc(1);d.clk=1;d.eval();ctx.timeInc(1);d.clk=0;d.eval();++clocks;
  if(d.q25!=expected||d.q22!=(expected&0x3fffff)||d.state_bad)throw std::runtime_error("independent RAM result/state mismatch");};
 d.clk=0;d.we=0;d.wa=0;d.wd=0;d.ra=0;d.eval();
 for(unsigned a=0;a<64;++a){d.ra=a;tick();}
 unsigned previous=0;bool previous_we=false;
 for(unsigned n=0;n<100000;++n){
  d.we=n%11<9;d.wa=n%7<4?previous:random()%64;d.wd=random()&0x1ffffff;
  d.ra=n%3==0?d.wa:n%3==1?previous:random()%64;
  if(n%977==0&&previous_we){uint32_t q22=d.q22,q25=d.q25;auto we=d.we,wa=d.wa,ra=d.ra;uint32_t wd=d.wd;
   for(unsigned i=0;i<7;++i){d.we=random()&1;d.wa=random()%64;d.ra=random()%64;d.wd=random()&0x1ffffff;ctx.timeInc(1);d.eval();if(d.q22!=q22||d.q25!=q25||d.state_bad)throw std::runtime_error("stopped clock changed memory/result");}
   d.we=we;d.wa=wa;d.ra=ra;d.wd=wd;++pauses;
  }
  previous=d.wa;previous_we=d.we;tick();
 }
 d.we=0;for(unsigned a=0;a<64;++a){d.ra=a;tick();}
 if(d.pending22||d.pending25)throw std::runtime_error("last pending write did not drain");
 unsigned tasks=0;for(auto const&e:std::filesystem::directory_iterator("/proc/self/task")){(void)e;++tasks;}
 std::printf("PASS RAM clocks=%llu init_reads=64 final_reads=64 pauses=%llu current_collisions=%u prior_collisions=%u logical_words=128 tasks=%u\n",(unsigned long long)clocks,(unsigned long long)pauses,d.current_collisions,d.prior_collisions,tasks);
 if(tasks!=1||!pauses||!d.current_collisions||!d.prior_collisions)throw std::runtime_error("RAM coverage");d.final();
}
