#include "Vtb_public_budget.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <initializer_list>
#include <stdexcept>
#include <string>
int main(int argc,char**argv){
 VerilatedContext ctx;ctx.threads(1);ctx.commandArgs(argc,argv);Vtb_public_budget d{&ctx};
 uint32_t rng=0x92b31843;uint64_t clocks=0;
 d.observer_disconnect=argc>1&&std::string(argv[1])=="disconnect";
 auto random=[&](){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;};
 auto tick=[&](){d.tick=clocks&1;d.po_ready=random()%5!=0;d.eval();
  ctx.timeInc(1);d.clk_2x=1;d.eval();ctx.timeInc(1);d.clk_2x=0;d.eval();
  ctx.timeInc(1);d.clk=1;d.clk_2x=1;d.eval();ctx.timeInc(1);d.clk=0;d.clk_2x=0;d.eval();++clocks;};
 d.rst=1;for(int i=0;i<6;i++)tick();d.rst=0;
 auto write=[&](unsigned a,uint32_t v){d.io_req=1;d.io_we=1;d.io_addr=(a>>2)&255;d.io_wdata=v;d.eval();
  for(unsigned n=0;d.io_wait;++n){if(n>200000)throw std::runtime_error("write timeout");tick();}
  tick();d.io_req=0;tick();};
 auto read=[&](unsigned a){d.io_req=1;d.io_we=0;d.io_addr=(a>>2)&255;tick();
  for(unsigned n=0;!d.io_ack;++n){if(n>200000)throw std::runtime_error("read timeout");tick();}
  auto q=d.io_rdata;d.io_req=0;tick();return q;};
 auto cmd=[&](unsigned c,std::initializer_list<uint32_t> p){if(p.size())for(auto v:p)write(0x400+4*c,v);else write(0x400+4*c,0);};
 auto drain=[&](){for(unsigned n=0;;++n){auto s=read(0x600);read(0x604);
   if(!(s&(1u<<27))&&d.dbg_idle)break;if(n>20000)throw std::runtime_error("drain timeout");}};
 write(0x600,0x80000000);cmd(0x10,{0});cmd(0x15,{});cmd(0x10,{3});cmd(0x15,{});
 cmd(0x10,{2});cmd(0x15,{});cmd(0x60,{0xbfff0000});cmd(0x29,{0x1f00c0});
 cmd(0x2a,{0});cmd(0x2b,{0});cmd(0x20,{0x7fff});drain();
 auto vertex=[&](int x,int y,int z){cmd(0x23,{uint32_t(uint16_t(x))|(uint32_t(uint16_t(y))<<16),uint16_t(z)});};
 // Existing gxtime8/gxpacked identity X-clip body, with no engine lead.
 d.case_id=1;cmd(0x40,{0});vertex(0xe00,0,0);vertex(0x1400,0,0);vertex(0xe00,0x400,0);cmd(0x41,{});drain();
 // The existing caller input recipe, one frame only. These are new passive
 // observations, not a replay of an old equivalence/acceptance campaign.
 d.case_id=2;cmd(0x30,{0x7fff7fff});cmd(0x31,{0x7fff7fff});
 for(unsigned l=0;l<4;++l){cmd(0x32,{(l<<30)|0x200});cmd(0x33,{(l<<30)|0x7fff});}
 for(unsigned p=0;p<24;++p){unsigned kind=p%4,n=kind==0?3:kind==1?4:kind==2?6:8;
  cmd(0x29,{0x1f00c0U|((p%8)<<24)|((p%3==0)?15:0)});cmd(0x2a,{(p&1)?0x40000000U:0});cmd(0x40,{kind});
  for(unsigned v=0;v<n;++v){const int xs[]={-8192,8192,0,-2048,4096,-4096,2048,0};const int ys[]={-2048,-2048,8192,2048,0,0,-4096,4096};
   int x=xs[(v+p)%8],y=ys[v%8],z=p%5==0?-8192:1024;if(p%4==0){x/=4;y/=4;z=1024;}
   cmd(0x20,{random()&0x7fff});cmd(0x22,{random()});cmd(0x21,{random()&0x3fffffff});vertex(x,y,z);
   if(v==1&&p%6==0)read(0x600);}
  cmd(0x41,{});}
 drain();
 // Existing gxcount tri_right_0: the two one-unit-outside vertices keep
 // the strong trivial-reject shortcut from firing; clip then rejects it.
 d.case_id=5;cmd(0x29,{0x1f00c0});cmd(0x40,{0});
 vertex(4097,1024,0);vertex(4097,-1024,0);vertex(4609,0,0);cmd(0x41,{});drain();
 d.case_id=3;for(unsigned b=0;b<8;++b){cmd(0x70,{0xf800e000U+b*17,0x4000f800U,0x10004000U});read(0x600);}drain();
 d.case_id=4;cmd(0x10,{2});for(unsigned i=0;i<16;++i)write(0x458,i%5==0?0x1000:0);read(0x640);read(0x604);
 cmd(0x50,{0});for(unsigned n=0;!d.dbg_flush;++n){if(n>200000)throw std::runtime_error("swap timeout");tick();}
 d.vblank=1;tick();d.vblank=0;
 for(unsigned n=0;!d.frame_done;++n){if(n>100000)throw std::runtime_error("frame publication timeout");tick();}
 tick();drain();
 unsigned tasks=0;for(auto const&e:std::filesystem::directory_iterator("/proc/self/task")){(void)e;++tasks;}
 std::printf("DRIVER,clocks,%llu,tasks,%u,disconnect,%u\n",(unsigned long long)clocks,tasks,d.observer_disconnect);
 if(tasks!=1)throw std::runtime_error("worker thread count");d.final();
}
