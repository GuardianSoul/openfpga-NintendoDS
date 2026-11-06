#include "Vtb_texture_mac.h"
#include "verilated.h"
#include "addresses.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <stdexcept>

int main(int argc,char**argv){
 VerilatedContext ctx;ctx.threads(1);ctx.commandArgs(argc,argv);Vtb_texture_mac d{&ctx};
 uint32_t seed=0x384ad741;auto random=[&](){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;};
 uint64_t cycles=0,vertices=0,crosses=0,dots=0,discards=0,modes[7]{},forwards=0,future=0,resets=0;
 uint32_t P=0;std::array<int16_t,3> cur{};int32_t matrix[2][4]{};int16_t raw[2]{};
 std::array<int16_t,2> expected{};std::array<int64_t,2> exact{};bool pending=false;
 auto edge=[&](bool sys){d.eval();if(d.mode<7)++modes[d.mode];d.clk=sys;d.clk2=1;d.eval();ctx.timeInc(1);d.clk=0;d.clk2=0;d.eval();ctx.timeInc(1);};
 auto half=[&](){d.clk=0;d.clk2=0;d.eval();edge(false);};
 auto reset=[&](){d.rst=1;d.ff_hw=d.ff_vtx=d.ff_tex=d.ff_col=d.collect=d.rf_we=d.cross_edge=d.dot_edge=0;d.check_cross=d.check_dot=0;half();edge(true);half();edge(true);d.rst=0;pending=false;++resets;};
 reset();
 auto plain=[&](){d.P=P;half();edge(true);++cycles;};
 // Seed every actual matrix/latch word with complete signed source values.
 for(unsigned c=0;c<2;++c)for(unsigned k=0;k<4;++k){
  d.rf_we=1;d.rf_wa=FF_A_TEX+4*k+c;d.rf_wd=(k&1)?0x80000000U:0x7fffffffU;
  matrix[c][k]=int32_t(d.rf_wd);plain();
 }
 for(unsigned k=0;k<3;++k){d.rf_we=1;d.rf_wa=FF_A_CURV+k;d.rf_wd=uint32_t(int32_t(int16_t(0x8000+0x401*k)));cur[k]=int16_t(d.rf_wd);plain();}
 for(unsigned c=0;c<2;++c){d.rf_we=1;d.rf_wa=FF_A_RAWTC+c;d.rf_wd=uint32_t(int32_t(int16_t(0x1234+0x777*c)));raw[c]=int16_t(d.rf_wd);plain();}
 d.rf_we=0;
 unsigned kindseen=0,raw_pending=0;uint32_t raw_word=0,vp0=0;
 bool valid_gen=false,cross_live=false,dot_live=false,discarded=false;
 for(unsigned c=0;c<65536;++c){
  unsigned phase=c%32,block=c/32;
  if(c && c%997==0 && raw_pending==0){reset();valid_gen=false;cross_live=dot_live=false;}
  d.ff_hw=d.ff_vtx=d.ff_tex=d.ff_col=d.collect=d.rf_we=0;d.mat_m=d.lu_cv=0;
  d.check_cross=(phase==5||phase==25)&&cross_live&&!discarded;
  d.check_dot=(phase==7||phase==27)&&dot_live&&!discarded;
  d.cross_edge=phase==4||phase==16||phase==24;d.dot_edge=phase==6||phase==18||phase==26;
  if(d.cross_edge){d.d0x=random();d.d0y=random();d.d0w=random();d.d2x=random();d.d2y=random();d.d2w=random();d.v1x=random();d.v1y=random();d.v1w=random();++crosses;cross_live=true;dot_live=false;discarded=phase==16;}
  if(d.dot_edge){for(int k=0;k<3;++k)d.cn2[k]=random();++dots;dot_live=cross_live;if(phase==18)++discards;}
  d.b_xsh=phase&7;d.pu_q=random();d.P=P;d.e_data=random();d.pi=0;
  // The actual source captures parameter0 separately; parameter1 pops VTX16.
  if(phase==31||phase==8||phase==16){d.collect=1;d.pi=0;vp0=uint32_t(d.e_data);}
  if((block&1) && (phase==9||phase==17||phase==31)){d.ff_tex=1;d.ff_hw=1;d.e_hidx=FF_HTEXC;}
  bool vertex=phase==0||phase==10||phase==18;
  unsigned kind=(block+(phase==10?2:phase==18?4:0))%6;
  std::array<int16_t,3> v=cur;
  if(vertex){
   d.ff_vtx=d.ff_hw=1;d.ff_tex=0;
   constexpr unsigned h[6]={FF_HV16,FF_HV10,FF_HVXY,FF_HVXZ,FF_HVYZ,FF_HVDF};d.e_hidx=h[kind];kindseen|=1<<kind;
   uint32_t w=uint32_t(d.e_data);
   if(kind==0){d.collect=1;d.pi=1;v={int16_t(vp0),int16_t(vp0>>16),int16_t(w)};}
   if(kind==1)for(int k=0;k<3;++k)v[k]=int16_t(((w>>(10*k))&1023)<<6);
   if(kind==2){v[0]=int16_t(w);v[1]=int16_t(w>>16);}
   if(kind==3){v[0]=int16_t(w);v[2]=int16_t(w>>16);}
   if(kind==4){v[1]=int16_t(w);v[2]=int16_t(w>>16);}
   if(kind==5)for(int k=0;k<3;++k){int16_t dv=int16_t(((w>>(10*k))&1023)<<6);v[k]=int16_t(uint16_t(cur[k])+int16_t(dv>>6));}
  }
  // At Epop update row0/1: both earlier slots must forward this exact word.
  // At E1 update row2: last M must use the older matrix, not this future write.
  if(vertex||phase==1||phase==11||phase==19||((random()&7)==0)){
   unsigned col=(c>>5)&1,row=vertex?((c>>6)&1):pending?2:random()%4;
   d.rf_we=1;d.rf_wa=FF_A_TEX+4*row+col;d.rf_wd=(c%13==0)?0x80000000U:(c%13==1)?0x7fffffffU:random();
   if(vertex)++forwards;else if(pending)++future;
  }
  if(phase==3){d.rf_we=1;d.rf_wa=FF_A_TEXM;d.rf_wd=block&3;}
  d.P=P;half();
  // Existing sum for this vertex has completed before its original E1.
  if(pending&&!d.rst){
   for(int k=0;k<2;++k)if(int64_t(d.tex_sum[k]<<(64-49))>>(64-49)!=exact[k])throw std::runtime_error("independent exact49 fullsum mismatch");
  }
  // The RF update below occurs at this edge. An E1 consumer reads pre-edge.
  bool consumed=pending;
  auto old_expected=expected;
  edge(true);++cycles;
  if(consumed){for(int k=0;k<2;++k)if(uint16_t(d.gen_t[k])!=uint16_t(old_expected[k]))throw std::runtime_error("independent E1 texture/raw result mismatch");valid_gen=true;pending=false;}
  if(d.rf_we && d.rf_wa>=FF_A_TEX && d.rf_wa<FF_A_TEX+16 && !(d.rf_wa&2))matrix[d.rf_wa&1][(d.rf_wa-FF_A_TEX)>>2]=int32_t(d.rf_wd);
  // raw_t writes from the older TEXCOORD commit at M, while the immediate
  // predecessor's word bypasses at this E1. Track those two clocks exactly.
  if(raw_pending==1){raw[0]=int16_t(raw_word);raw[1]=int16_t(raw_word>>16);raw_pending=0;}
  else if(raw_pending>1)--raw_pending;
  if(vertex){
   cur=v;
   for(int coord=0;coord<2;++coord){
    exact[coord]=0;for(int k=0;k<3;++k)exact[coord]+=int64_t(v[k])*matrix[coord][k];
    int16_t r=raw_pending?int16_t(raw_word>>(16*coord)):raw[coord];
    expected[coord]=int16_t(uint16_t(uint64_t(exact[coord])>>24)+uint16_t(r));
   }
   pending=true;++vertices;
  }
  if(d.ff_tex){raw_word=uint32_t(d.e_data);raw_pending=2;}
  if(d.ff_hw||d.collect)P=uint32_t(d.e_data);
  d.P=P;d.eval();
 }
 unsigned tasks=0;for(auto const&x:std::filesystem::directory_iterator("/proc/self/task")){(void)x;++tasks;}
 if(tasks!=1||kindseen!=63||!valid_gen||vertices<6000||!discards||!forwards||!future||!modes[4]||!modes[5]||!modes[6])throw std::runtime_error("new-owner coverage guard");
 std::printf("PASS SYS=%llu vertices=%llu kinds=%x crossjobs=%llu dotjobs=%llu discarded=%llu RFedge=%llu futureRF=%llu resets=%llu modes=%llu/%llu/%llu/%llu/%llu/%llu/%llu tasks=%u\n",
 (unsigned long long)cycles,(unsigned long long)vertices,kindseen,(unsigned long long)crosses,(unsigned long long)dots,(unsigned long long)discards,(unsigned long long)forwards,(unsigned long long)future,(unsigned long long)resets,
 (unsigned long long)modes[0],(unsigned long long)modes[1],(unsigned long long)modes[2],(unsigned long long)modes[3],(unsigned long long)modes[4],(unsigned long long)modes[5],(unsigned long long)modes[6],tasks);
}
