#include "Vtb_clip_input.h"
#include "verilated.h"
#include "addresses.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <stdexcept>

int main(int argc,char**argv){
 bool fault=argc>1&&std::strcmp(argv[1],"--consumer-fault")==0;
 VerilatedContext ctx;ctx.threads(1);ctx.commandArgs(argc,argv);Vtb_clip_input d{&ctx};
 uint32_t seed=0x71c632ab;auto random=[&](){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;};
 uint64_t clocks=0,accepted=0,injected=0,segments=0,starts=0,num_checks=0,qchecks=0,restarts=0,zeros=0,nmin=0,dvmin=0;
 uint64_t resets[3]{},run_drops=0;unsigned block=0,planes=0,sides=0;bool collisions=false,allow_abort=false,aborted=false,drop=false;unsigned abort_slot=3;
 uint64_t products[9]{};uint32_t denominator=0;uint64_t start_clock=0;bool prepared=false,active=false;
 auto error=[&](const char*what,unsigned i,uint64_t got,uint64_t want){std::fprintf(stderr,"clip oracle %s SYS=%llu word=%u got=%016llx expected=%016llx\n",what,(unsigned long long)clocks,i,(unsigned long long)got,(unsigned long long)want);throw std::runtime_error(what);};
 auto nums=[&](unsigned n){if(!prepared)return;for(unsigned i=0;i<n;++i)if(!(fault&&i==8)){if(d.num_word[i]!=products[i])error("NUM",i,d.num_word[i],products[i]);++num_checks;}};
 auto completed=[&](){if(!active)return;for(unsigned i=0;i<9;++i){unsigned duration=(products[i]>>32)>=denominator?17:8;bool expected_busy=clocks<start_clock+duration;
   if(bool((d.divbusy>>i)&1)!=expected_busy)error("busy edge",i,(d.divbusy>>i)&1,expected_busy);
   if(!expected_busy&&!(fault&&i==8)){uint32_t q=denominator?uint32_t(products[i]/denominator):0xffffffffU;if(d.quotient[i]!=q)error("quotient",i,d.quotient[i],q);++qchecks;}
  }nums(9);
 };
 auto tick=[&](bool external=false){
  d.clk=d.clk2=0;d.wfree=!external&&!block&&(random()%8==0);d.eval();
  if(!external&&collisions&&d.read_valid&&random()%3==0){unsigned p=random()%18;while(!(d.read_valid&(1U<<p)))p=(p+1)%18;d.we=1;d.wa=0x200|d.read_addr[p];d.wd=random();d.wfree=0;++injected;}
  else if(!external){d.we=d.cw&&d.wfree;d.wa=d.cwa;d.wd=d.cwd;}
  d.eval();bool reset0=allow_abort&&!aborted&&abort_slot==0&&d.seg;
  bool reset1=allow_abort&&!aborted&&abort_slot==1&&d.pending;
  bool reset2=allow_abort&&!aborted&&abort_slot==2&&d.pending;
  if(reset1){d.rst=1;d.eval();aborted=true;++resets[1];}
  if(drop&&d.start_div){d.run=0;drop=false;++run_drops;}
  ctx.timeInc(1);d.clk2=1;d.eval();ctx.timeInc(1);d.clk2=0;d.eval();
  if(!d.rst&&d.pending&&!d.mid)nums(6);
  if(reset0||reset2){d.rst=1;d.eval();aborted=true;++resets[reset0?0:2];}
  if(d.rst){prepared=active=false;}
  else{
   if(d.seg){
    unsigned c=d.component;uint32_t t=(d.halfplane&1)?d.inside_word[3]+d.inside_word[c]:d.inside_word[3]-d.inside_word[c];uint32_t n=(d.halfplane&1)?d.vw+d.vc:d.vw-d.vc;uint32_t den=n-t;uint32_t nm=(den>>31)?0U-n:n;denominator=(den>>31)?0U-den:den;
    for(unsigned i=0;i<9;++i){uint32_t iv=d.outside_word[i],ov=d.inside_word[i];if(i==4&&RED){iv-=iv&4095;ov-=ov&4095;}uint32_t dv=ov-iv;bool sg=((dv^nm)>>31)!=0;uint32_t m=sg?0U-nm:nm;products[i]=uint64_t(int64_t(int32_t(dv))*int64_t(int32_t(m)));dvmin+=dv==0x80000000U;}
    prepared=true;active=false;++segments;planes|=1U<<d.halfplane;sides|=1U<<d.side;zeros+=denominator==0;nmin+=nm==0x80000000U;
   }
   if(d.start_div){if(!prepared)throw std::runtime_error("start without independent segment");start_clock=clocks+1;active=true;++starts;for(auto v:products)restarts+=(v>>32)>=denominator;}
  }
  accepted+=!d.rst&&d.cw&&d.wfree;
  ctx.timeInc(1);d.clk=d.clk2=1;d.eval();ctx.timeInc(1);d.clk=d.clk2=0;d.eval();++clocks;
  if(!d.rst){if(d.pending&&d.mid)nums(3);completed();}
  if(block)--block;
 };
 auto write=[&](unsigned a,uint32_t w){d.we=1;d.wa=a;d.wd=w;tick(true);d.we=0;};
 auto reset=[&](){allow_abort=false;d.rst=1;d.run=0;tick();tick();d.rst=0;block=0;prepared=active=false;};
 reset();d.can=1;
 for(unsigned a=0x200;a<0x400;++a)write(a,random());
 const unsigned masks[]={1,2,4,8,16,32,63,0};
 for(unsigned job=0;job<144;++job){
  allow_abort=false;aborted=false;unsigned ln=job%17==16?0:job%7==6?10:3+job%2;unsigned cs=std::min(ln,job%5==4?2U:0U);
  collisions=job>=8&&job%3!=0;unsigned mask=job<2?1:masks[job%8];
  write(FU_A_LN,ln);write(FU_A_CS,cs);write(PU_A_OCM,mask);write(LU_A_CATTR,4096);write(PU_A_POOL,0x200+16*(job%5==0?31:job&1?16:12));
  for(unsigned i=0;i<ln;++i){
   write(FU_A_LA+i,0x200+16*i);
   for(unsigned w=0;w<16;++w){uint32_t v=random();if(w==3)v=4096;if(w<3){const int32_t pos[]={-8192,8192,0,4096,-4096,1,-1};v=uint32_t(pos[(job+i+w)%7]);}
    if(job==0){if(w==0)v=i==0?8192:0xffffe000U;if(w==1||w==2)v=0;if(w==8||w==9)v=200+1000*i;}
    if(job==1){if(w==0)v=i==1?0x80000000U:0;if(w==3)v=i==0?0x80000000U:0;if(w==8||w==9)v=i==1?0x80000000U:0;}
    write(0x200+16*i+w,v);
   }
  }
  d.can=0;d.run=1;block=300;for(unsigned i=0;i<7;++i)tick();d.can=1;tick();
  allow_abort=job>=8&&job%9<3;abort_slot=job%9;drop=job%7==3;
  for(unsigned n=0;d.cond&&!aborted;++n){if(n>100000)throw std::runtime_error("clip timeout");tick();}
  allow_abort=false;d.run=0;
  if(aborted||job%29==28)reset();
 }
 unsigned tasks=0;for(auto const&e:std::filesystem::directory_iterator("/proc/self/task")){(void)e;++tasks;}
 std::printf("SYS=%llu jobs=144 segments=%llu starts=%llu NUMchecks=%llu quotientChecks=%llu overflowRestarts=%llu den0=%llu nmMIN=%llu dvMIN=%llu resetSlots=%llu/%llu/%llu runDrops=%llu RF=%llu injected=%llu planes=%x sides=%x full=%u held=%u outcomes=%u tasks=%u\n",(unsigned long long)clocks,(unsigned long long)segments,(unsigned long long)starts,(unsigned long long)num_checks,(unsigned long long)qchecks,(unsigned long long)restarts,(unsigned long long)zeros,(unsigned long long)nmin,(unsigned long long)dvmin,(unsigned long long)resets[0],(unsigned long long)resets[1],(unsigned long long)resets[2],(unsigned long long)run_drops,(unsigned long long)accepted,(unsigned long long)injected,planes,sides,d.full_clocks,d.held,d.outcomes,tasks);std::fflush(stdout);
 if(tasks!=1||!injected||!restarts||!zeros||!nmin||!dvmin||!num_checks||!qchecks||!resets[0]||!resets[1]||!resets[2]||planes!=63||sides!=3||!d.full_clocks||!d.held)throw std::runtime_error("clip input coverage/thread guard");
 std::puts("PASS complete prior clip state+NUM/q/busy/RFconsumer relation and independent exact products/quotients");
}
