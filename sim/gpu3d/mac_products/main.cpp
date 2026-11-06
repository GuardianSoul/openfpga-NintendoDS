#include "Vtb_mac_products.h"
#include "verilated.h"
#include "constants.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <stdexcept>

constexpr uint64_t M44=(uint64_t(1)<<44)-1;
static uint64_t product(uint32_t a,uint32_t b){return uint64_t(int64_t(int32_t(a))*int64_t(int32_t(b)));}
static uint32_t sign16(uint32_t x){return uint32_t(int32_t(int16_t(x)));}

struct Model {
 uint32_t R=0,ma=0,mb=0,kreg=0,acc_m=0,acc_a=0,out_m=0,sm_m=0,wa_m=0,vcnt=0;
 uint64_t pr=0,acc=0;
 uint32_t vma[4]{};
 uint64_t vpr[4]{},vacc[4]{};
 bool we_m=false,fl_p=false,fz_h=false,fn=false,fc=false,flt=false,a63=false,az=false,nfit=false;
 bool fz()const{return fl_p?R==0:fz_h;}
 uint32_t lane(unsigned c)const{return uint32_t((c?vacc[c]:acc)>>12);}
 uint32_t xs(unsigned xsh)const{uint64_t v=(xsh&3)?vacc[xsh&3]:(acc&M44);return xsh&4?sign16(uint32_t(v>>24)):uint32_t(v>>12);}
 void edge(const Vtb_mac_products&d){
  Model n=*this;
  n.R=d.res;
  if(d.od_ro&(1U<<9))n.kreg=d.k4_k;
  n.fl_p=d.b_fl&&!d.fl_sort;n.fz_h=fz();
  if(d.b_fl&&!d.fl_sort){n.fn=d.res>>31;n.fc=!(d.sum>>32);n.flt=d.lt_s;}
  if(d.b_fl&&d.fl_sort)n.fn=d.s_sign;
  bool vop=d.b_acc==ACC_VLD||d.b_acc==ACC_VADD||d.b_acc==ACC_VLDT;
  n.ma=vop?d.vm_q[0]:d.b_ma?R:d.qa;
  n.mb=d.b_mb==MB_R?R:d.b_mb==MB_IMM?d.imm:d.b_mb==MB_MB3?((d.v_row&3)==3?4096:sign16(d.at_v[d.v_row&3])):d.qb;
  n.pr=product(ma,mb);
  if(d.rst){n.acc_m=n.acc_a=ACC_NONE;n.we_m=false;n.out_m=0;}
  else{n.acc_m=d.b_acc;n.acc_a=acc_m;n.we_m=d.we_o;n.out_m=d.b_out;}
  n.sm_m=d.b_xsh;n.wa_m=d.wa_o;
  switch(acc_a){
   case ACC_LD:case ACC_VLD:case ACC_VLDT:n.acc=pr;break;
   case ACC_ADD:case ACC_VADD:n.acc=acc+pr;break;
   case ACC_SUB:n.acc=acc-pr;break;
   case ACC_ADDM:n.acc=acc+(pr&0xfffff);break;
   default:break;
  }
  n.a63=acc>>63;n.az=acc==0;n.nfit=(acc>>31)!=((acc>>63)?((uint64_t(1)<<33)-1):0);
  if(vop)n.vcnt=(d.v_row+1)&31;
  for(unsigned c=1;c<4;++c){
   n.vma[c]=d.vm_q[c];n.vpr[c]=product(vma[c],mb)&M44;
   if(acc_a==ACC_VLD||acc_a==ACC_VLDT)n.vacc[c]=vpr[c];
   else if(acc_a==ACC_VADD)n.vacc[c]=(vacc[c]+vpr[c])&M44;
  }
  *this=n;
 }
};

int main(int argc,char**argv){
 bool mutant=argc>1&&std::strcmp(argv[1],"--consumer-fault")==0;
 VerilatedContext context;context.threads(1);context.commandArgs(argc,argv);Vtb_mac_products d{&context};
 uint32_t seed=0x7c613d5b;auto random=[&](){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;};
 Model model;uint64_t clocks=0,resets=0,mid_resets=0,late_inputs=0,full_mb=0,consecutive_vectors=0,product_checks=0,consumer_checks=0;
 unsigned modes=0,mbmodes=0,xshmodes=0,rows=0,signs[4]{};uint64_t transitions=0;unsigned last_mode=0;bool last_vop=false;
 auto fail=[&](const char*kind,unsigned cfg,unsigned lane,uint64_t got,uint64_t want){std::fprintf(stderr,"oracle %s SYS=%llu cfg=%u lane=%u got=%016llx expected=%016llx\n",kind,(unsigned long long)clocks,cfg,lane,(unsigned long long)got,(unsigned long long)want);throw std::runtime_error(kind);};
 auto check=[&](){
  for(unsigned i=0;i<2;++i){
   if(d.q_vx_q[i]!=model.xs(d.b_xsh))fail("consumer XS",i,d.b_xsh&3,d.q_vx_q[i],model.xs(d.b_xsh));
   for(unsigned c=1;c<4;++c){if(d.q_vacc[i][c]!=model.vacc[c])fail("consumer vacc",i,c,d.q_vacc[i][c],model.vacc[c]);if(d.q_vx_lane[i][c]!=model.lane(c))fail("consumer lane",i,c,d.q_vx_lane[i][c],model.lane(c));}
   if(d.q_acc[i]!=model.acc)fail("consumer acc",i,0,d.q_acc[i],model.acc);
   if(d.q_vx_lane[i][0]!=model.lane(0))fail("consumer lane0",i,0,d.q_vx_lane[i][0],model.lane(0));
#define CHECK(n) if(d.q_##n[i]!=model.n)fail(#n,i,0,d.q_##n[i],model.n)
   CHECK(R);CHECK(ma);CHECK(mb);CHECK(pr);CHECK(kreg);CHECK(acc_m);CHECK(acc_a);CHECK(we_m);CHECK(out_m);CHECK(sm_m);CHECK(wa_m);CHECK(fl_p);CHECK(fz_h);CHECK(fn);CHECK(fc);CHECK(flt);CHECK(a63);CHECK(az);CHECK(nfit);CHECK(vcnt);
#undef CHECK
   if(bool(d.q_fz[i])!=model.fz())fail("fz",i,0,d.q_fz[i],model.fz());
   for(unsigned c=1;c<4;++c){if(d.q_vma[i][c]!=model.vma[c])fail("vma",i,c,d.q_vma[i][c],model.vma[c]);if(!(mutant&&c==3)&&d.q_vpr[i][c]!=model.vpr[c])fail("vpr",i,c,d.q_vpr[i][c],model.vpr[c]);}
   product_checks+=4;consumer_checks+=9;
  }
 };
 auto cycle=[&](bool late=false,bool reset_after_m=false){
  d.clk=d.clk_2x=0;d.eval();context.timeInc(1);d.clk_2x=1;d.eval();context.timeInc(1);d.clk_2x=0;d.eval();check();
  if(late){d.qa^=random();d.qb^=random();d.imm^=random();d.res^=random();for(unsigned c=0;c<4;++c)d.vm_q[c]^=random();++late_inputs;d.eval();check();}
  if(reset_after_m){d.rst=1;d.eval();++mid_resets;}
  for(unsigned c=0;c<4;++c){uint32_t av=c?model.vma[c]:model.ma;signs[c]|=1U<<((av>>31)*2+(model.mb>>31));}
  if(model.mb!=sign16(model.mb))++full_mb;
  context.timeInc(1);d.clk=d.clk_2x=1;d.eval();model.edge(d);++clocks;
  context.timeInc(1);d.clk=d.clk_2x=0;d.eval();check();
  if(d.rst)++resets;
  modes|=1U<<d.b_acc;mbmodes|=1U<<d.b_mb;xshmodes|=1U<<d.b_xsh;rows|=1U<<d.v_row;transitions|=uint64_t(1)<<(last_mode*8+d.b_acc);last_mode=d.b_acc;
  bool vop=d.b_acc>=ACC_VLD;if(vop&&last_vop)++consecutive_vectors;last_vop=vop;
 };
 d.clk=d.clk_2x=0;d.check=1;d.rst=1;d.b_acc=ACC_VLD;d.b_xsh=3;
 for(unsigned k=0;k<8;++k){cycle(false,k==3);if(k==1)d.rst=0;}
 const std::array<uint32_t,20> edge={0,1,0xffffffff,0x7fffffff,0x80000000,0x0000ffff,0xffff0000,0x00010000,0x0007ffff,0xfff80000,0x00100000,0xfff00000,0x00001000,0xfffff000,0x55555555,0xaaaaaaaa,0x7ffff000,0x80000fff,0x40000000,0xc0000000};
 for(unsigned job=0;job<65536;++job){
  unsigned q=job%edge.size(),r=(job/edge.size())%edge.size();bool directed=job<400;
  d.rst=job%127==19||job%127==20;d.b_acc=job%64<16?ACC_VADD:job<400?job&7:random()&7;d.b_mb=job&3;d.b_ma=(job>>2)&1;d.b_xsh=(job>>3)&7;d.v_row=job&31;
  d.qa=directed?edge[q]:random();d.qb=directed?edge[r]:random();d.imm=directed?edge[(r+3)%edge.size()]:random();d.res=directed?edge[(q+7)%edge.size()]:random();
  for(unsigned c=0;c<4;++c)d.vm_q[c]=directed?edge[(q+3*c)%edge.size()]:random();
  for(unsigned c=0;c<3;++c)d.at_v[c]=uint16_t(random());
  d.od_ro=uint16_t(random())&1023;d.k4_k=random()&63;d.b_fl=random()&1;d.fl_sort=random()&1;d.lt_s=random()&1;d.s_sign=random()&1;d.sum=(uint64_t(random()&1)<<32)|random();d.we_o=random()&1;d.b_out=random()&15;d.wa_o=random()&2047;
  cycle(!directed&&job%7==3,job%251==31);
 }
 unsigned tasks=0;for(auto const&e:std::filesystem::directory_iterator("/proc/self/task")){(void)e;++tasks;}
 std::printf("coverage SYS=%llu modeMask=%x mbMask=%x xsMask=%x rowMask=%x transitionMask=%016llx tasks=%u\n",(unsigned long long)clocks,modes,mbmodes,xshmodes,rows,(unsigned long long)transitions,tasks);
 if(modes!=255||mbmodes!=15||xshmodes!=255||rows!=0xffffffffU||transitions!=~uint64_t(0)||tasks!=1||!mid_resets||!late_inputs||full_mb<1000||consecutive_vectors<1000)throw std::runtime_error("MAC coverage/thread guard");
 for(unsigned c=0;c<4;++c)if(signs[c]!=15)throw std::runtime_error("MAC signed product coverage");
 std::printf("PASS SYS=%llu configs=2 productChecks=%llu consumerChecks=%llu resets=%llu resetAfterM=%llu lateInputs=%llu full32MB=%llu consecutiveVector=%llu modes=8 transitions=64 MB=4 XS=8 rows=32 signedPairs=4x4 tasks=%u\n",(unsigned long long)clocks,(unsigned long long)product_checks,(unsigned long long)consumer_checks,(unsigned long long)resets,(unsigned long long)mid_resets,(unsigned long long)late_inputs,(unsigned long long)full_mb,(unsigned long long)consecutive_vectors,tasks);
}
