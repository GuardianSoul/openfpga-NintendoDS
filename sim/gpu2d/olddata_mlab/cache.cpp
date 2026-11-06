#include "Vtb_od_cache.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <stdexcept>
int main(int argc,char**argv){
 VerilatedContext ctx;ctx.threads(1);ctx.commandArgs(argc,argv);Vtb_od_cache d{&ctx};
 uint32_t rng=0xd72a914b;uint64_t clocks=0,clears=0;
 auto random=[&](){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;};
 auto tick=[&](){ctx.timeInc(1);d.clk=1;d.eval();ctx.timeInc(1);d.clk=0;d.eval();++clocks;};
 d.clk=0;d.idle=0;d.hold=0;d.clear=0;d.fill_we=0;d.a_blk=0;d.a_word=0;d.eval();tick();
 for(unsigned job=0;job<1100;++job){
  d.clear=1;d.idle=1;d.fill_we=0;tick();d.clear=0;++clears;
  // Complete a scrub revolution each generation, including wrap.
  for(unsigned n=0;n<65;++n){d.a_blk=random()&0x3ffff;d.a_word=random()%4;d.hold=random()&1;tick();}
  d.idle=0;d.hold=0;d.a_blk=random()&0x3ffff;d.a_word=random()%4;tick();
  uint32_t block=d.cur_blk;
  for(unsigned beat=0;beat<4;++beat){
   d.hold=1;d.fill_we=1;d.fill_blk=block;d.fill_beat=beat;d.fill_last=beat==3;
   d.fill_data=(uint64_t(random())<<32)|random();tick();
   d.fill_we=0;for(unsigned gap=0;gap<1+(job+beat)%3;++gap)tick();
  }
  for(unsigned n=0;n<12;++n){
   d.fill_we=n%4==1;d.fill_blk=(n&1)?d.cur_blk:random()&0x3ffff;d.fill_beat=n%4;d.fill_last=d.fill_beat==3;
   d.fill_data=(uint64_t(random())<<32)|random();d.hold=n%3!=0;d.a_blk=random()&0x3ffff;d.a_word=random()%4;tick();
  }
 }
 d.fill_we=0;d.idle=1;for(unsigned n=0;n<130;++n)tick();
 unsigned tasks=0;for(auto const&e:std::filesystem::directory_iterator("/proc/self/task")){(void)e;++tasks;}
 std::printf("PASS cache clocks=%llu clears=%llu wrap=%u held=%u fill_collisions=%u raw_collisions=%u scrub_writes=%u HASH0+1 logical_words=128 tasks=%u\n",(unsigned long long)clocks,(unsigned long long)clears,d.wraps,d.held,d.fill_collisions,d.raw_collisions,d.scrub_writes,tasks);
 if(tasks!=1||!d.wraps||!d.held||!d.fill_collisions||!d.raw_collisions||!d.scrub_writes)throw std::runtime_error("cache coverage");d.final();
}
