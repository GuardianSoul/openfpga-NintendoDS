#include "Vtb_light_products.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <stdexcept>

static int32_t sx(uint32_t x,unsigned n){uint32_t m=1U<<(n-1);return int32_t((x&((1U<<n)-1))^m)-int32_t(m);}
struct Inputs{
 uint32_t vec[16]{},lt[4][16]{};unsigned md[3]{},ma[3]{},ms[3]{},lc[4][3]{},emi[3]{},mask=0,ut=0;uint8_t table[128]{};
 void write(unsigned a,uint32_t w){
  if(a>=0x20&&a<0x30)vec[a&15]=w&0x7fffff;
  if(a>=0x100&&a<0x140){lt[(a>>4)&3][a&15]=w&0xfffff;if((a&15)>=4&&(a&15)<7)lc[(a>>4)&3][(a&15)-4]=w&31;}
  for(unsigned c=0;c<3;++c){if(a==0x158+c)md[c]=w&31;if(a==0x15b+c)ma[c]=(w>>9)&31;if(a==0x15e + c)ms[c]=w&31;if(a==0x161+c)emi[c]=w&31;}
  if(a==0xd3)mask=w&15;if(a==0xe1)ut=w&1;if(a>=0x180&&a<0x200)table[a&127]=uint8_t(w);
 }
 void material(unsigned kind,uint32_t w){
  for(unsigned c=0;c<3;++c){if(kind==0){md[c]=(w>>(5*c))&31;ma[c]=(w>>(16+5*c))&31;}if(kind==1){ms[c]=(w>>(5*c))&31;emi[c]=(w>>(16+5*c))&31;}if(kind==2)lc[w>>30][c]=(w>>(5*c))&31;}
  if(kind==1)ut=(w>>15)&1;
 }
 uint16_t color(bool mat,uint32_t nr,unsigned enabled,bool* addresses)const{
  int32_t nt[3]{};for(unsigned c=0;c<3;++c){uint32_t s=0;for(unsigned k=0;k<3;++k)s=(s+uint32_t(int64_t(sx(nr>>(10*k),10))*vec[4*k+c]))&0x7fffff;nt[c]=sx(s>>12,11);}
  uint32_t vb[3]={emi[0]<<14,emi[1]<<14,emi[2]<<14};
  for(unsigned i=0;i<4;++i){
   int32_t d=0;for(unsigned k=0;k<3;++k){int64_t p=int64_t(sx(lt[i][k],11))*nt[k];d=sx(uint32_t(d+int16_t(p>>9)),16);}
   int32_t dd=sx(d,11),d2=sx(uint32_t(int16_t(d+nt[2])),11);unsigned sq=(uint64_t(int64_t(d2)*d2)>>10)&1023;
   int64_t sh=(int64_t(sq)*sx(lt[i][3],20)>>8)-512;int32_t s14=sx(uint32_t(sh),14);
   unsigned s0=d<=0||sh<0||s14<0?0:s14>511?511:unsigned(s14);if(addresses)addresses[s0>>2]=true;
   unsigned shine=ut?unsigned(table[s0>>2])<<1:s0;
   for(unsigned c=0;c<3;++c){unsigned dl=mat?md[c]*lc[i][c]:(lt[i][7+c]&1023),sl=mat?ms[c]*lc[i][c]:(lt[i][10+c]&1023),al=mat?(ma[c]*lc[i][c])<<9:(lt[i][13+c]&0x7ffff);
    uint32_t dif=uint32_t(int64_t(dl)*dd)&0xfffff,sp=sl*shine;
    if(enabled&(1U<<i))vb[c]=(vb[c]+al+(d>0?dif:0)+sp)&0xffffff;
   }
  }
  uint16_t packed=0;for(unsigned c=0;c<3;++c){unsigned v=(vb[c]>>14)&1023;packed|=uint16_t(v>31?31:v)<<(5*c);}return packed;
 }
};
int main(int argc,char**argv){
 bool cancel_only=argc>1&&std::strcmp(argv[1],"--cancel-only")==0;
 VerilatedContext ctx;ctx.threads(1);ctx.commandArgs(argc,argv);Vtb_light_products d{&ctx};
 uint32_t seed=0x4a719021;auto random=[&](){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;};
 Inputs model[2];uint16_t expected[4]{};uint32_t job_nr[4]{};unsigned enabled[4]{};bool valid[4]{},seen_cv[4]{},job_fast[4]{},ever_held[4]{};uint64_t start_clock[4]{};
 uint64_t clocks=0,starts=0,cv[4]{},writes[4]{},fast_count=0,slow_count=0,aborts=0,resets=0,late=0,held=0,blocked=0,nominal=0;
 bool addresses[128]{},masks[16]{};unsigned abort_stages=0,reset_stages=0;
 d.start_mask=15;d.rst=1;d.clk=0;d.clk2=0;
 auto cycle=[&](bool abort_after_m=false,bool reset_after_m=false){
  d.clk=d.clk2=0;d.eval();unsigned old_st[4],old_cnt[4];for(unsigned i=0;i<4;++i){old_st[i]=d.state[i];old_cnt[i]=d.count[i];}
  for(unsigned i=0;i<4;++i)if(!d.rst&&!d.cancel){
   if(old_st[i]==0&&d.start&&(d.start_mask&(1U<<i))){job_nr[i]=d.nrm;enabled[i]=model[i/2].mask;valid[i]=false;seen_cv[i]=false;start_clock[i]=clocks+1;job_fast[i]=d.fast;ever_held[i]=false;}
   if(old_st[i]==1&&old_cnt[i]==2)enabled[i]=model[i/2].mask;
  }
  ctx.timeInc(1);d.clk2=1;d.eval();ctx.timeInc(1);d.clk2=0;d.eval();
  if(abort_after_m){d.cancel=1;d.eval();}
  if(reset_after_m){d.rst=1;d.eval();}
  ctx.timeInc(1);d.clk=d.clk2=1;d.eval();ctx.timeInc(1);d.clk=d.clk2=0;d.eval();++clocks;
  if(d.we)for(auto&m:model)m.write(d.wa,d.wd);if(d.material_valid)model[1].material(d.material_kind,d.material_word);
  for(unsigned i=0;i<4;++i){
   if(d.rst||d.cancel){valid[i]=false;continue;}
   if(d.state[i]==2&&d.count[i]==0&&(old_st[i]!=2)){expected[i]=model[i/2].color(i>=2,job_nr[i],enabled[i],addresses);valid[i]=true;}
   if(d.nr[i]!=job_nr[i]&&valid[i])throw std::runtime_error("independent retained NORMAL mismatch");
   ever_held[i]|=bool(d.hold);
   if(((d.cv>>i)&1)&&!seen_cv[i]&&!ever_held[i]&&clocks-start_clock[i]!=(job_fast[i]?6U:9U))throw std::runtime_error("visible ready edge changed");
   if((d.cv>>i)&1){if(!valid[i]||d.cvd[i]!=expected[i]){std::fprintf(stderr,"oracle color i=%u got=%04x expected=%04x state=%u count=%u\n",i,d.cvd[i],expected[i],d.state[i],d.count[i]);throw std::runtime_error("independent full lighting color mismatch");}++cv[i];seen_cv[i]=true;}
   if((d.cw>>i)&1){unsigned k=d.wn[i]&3;if(k>=3)throw std::runtime_error("write index");uint32_t color=(expected[i]>>(5*k))&31;if(!valid[i]||d.cwa[i]!=0x14b+k||d.cwd[i]!=((color<<12)|4095))throw std::runtime_error("independent ordered RF color mismatch");if(!d.we)++writes[i];else ++blocked;}
  }
 };
 auto defaults=[&](){d.rst=d.we=d.start=d.hold=d.cancel=d.material_valid=0;d.start_mask=15;};
 cycle();cycle();defaults();
 auto wr=[&](unsigned a,uint32_t w){d.we=1;d.wa=a;d.wd=w;cycle();d.we=0;};
 auto mat=[&](unsigned k,uint32_t w){d.material_valid=1;d.material_kind=k;d.material_word=w;cycle();d.material_valid=0;};
 for(unsigned k=0;k<128;++k)wr(0x180+k,(k*73+19)&255);
 for(unsigned k=0;k<16;++k)wr(0x20+k,k%5==0?4096:0);
 for(unsigned i=0;i<4;++i)for(unsigned k=0;k<16;++k)wr(0x100+16*i+k,k==2?512:k==3?512:k>=4&&k<7?4:k>=7&&k<13?16:0);
 for(unsigned c=0;c<3;++c){wr(0x158+c,4);wr(0x15b+c,0);wr(0x15e + c,4);wr(0x161+c,0);}wr(0xd3,1);wr(0xe1,0);
 for(unsigned job=0;job<(cancel_only?128U:1152U);++job){
  defaults();while(d.busy)cycle();bool regular=cancel_only||job<512;bool fast=cancel_only?((job/16)&1):job&1;
  unsigned mask=job==0?1:job&15;masks[mask]=true;wr(0xd3,mask);wr(0xe1,job&1);
  for(unsigned i=0;i<4;++i){wr(0x100+16*i+3,regular?512+(job&511):random()&0xfffff);
   if(!regular)for(unsigned k=0;k<16;++k)wr(0x100+16*i+k,random()&0xfffff);
  }
  if(!regular)for(unsigned k=0;k<16;++k)wr(0x20+k,random()&0x7fffff);
  if(!regular)for(unsigned c=0;c<3;++c){wr(0x158+c,random()&31);wr(0x15b+c,(random()&31)<<9);wr(0x15e + c,random()&31);wr(0x161+c,random()&31);}
  if(job%13==12){unsigned kind=job%3;uint32_t word=random();if(regular&&kind==1)word=(word&~0x8000U)|((job&1)<<15);mat(kind,word);}
  d.nrm=regular?(256U<<20):(random()&0x3fffffff);d.fast=fast;d.start=1;
  cycle();++starts;fast_count+=fast;slow_count+=!fast;d.start=0;
  bool want_abort=cancel_only?(job%2==0&&((job/32)&1)==0):job>0&&job%17<6;
  bool want_reset=cancel_only?(job%2==0&&((job/32)&1)!=0):job%29==19;
  unsigned cancel_at=cancel_only?(job/2)%8:1+(job%8);
  bool canceled=false;
  for(unsigned t=0;t<80&&d.busy;++t){
   d.hold=cancel_only?(want_abort||want_reset)&&t<13:job%5==2&&t<13;held+=d.hold;
   d.we=0;d.material_valid=0;
   if(d.state[0]==1){
    d.we=1;d.wa=regular?0x161+(t%3):(t%3==0?0x20+(job%16):0x100+(job%64));d.wd=random();++late;
    if(cancel_only&&d.count[0]==2){d.material_valid=1;d.material_kind=job%3;d.material_word=random();}
   }else if((random()&7)==0){d.we=1;d.wa=(t&1)?0xd3:0x50;d.wd=random();}
   if(!canceled&&t==cancel_at&&(want_abort||want_reset)){
    unsigned stage=d.state[0]==2?d.count[0]:7;
    if(want_reset){reset_stages|=1U<<stage;++resets;if(cancel_only)cycle(false,true);else{d.rst=1;cycle();}d.rst=0;}
    else{abort_stages|=1U<<stage;++aborts;cycle(true);d.cancel=0;}
    canceled=true;
   }else cycle();
   if(job%7==0&&!d.hold)++nominal;
  }
  defaults();for(unsigned k=0;k<3;++k)cycle();if(d.busy)throw std::runtime_error("lighting failed to finish");
 }
 // NOWR1's next NORMAL is admitted as soon as the retained sequencer frees.
 defaults();d.start_mask=10;d.fast=1;d.nrm=0;
 for(unsigned j=0;j<(cancel_only?16U:256U);++j){while(d.busy&10)cycle();if(j&&clocks+1-start_clock[1]!=8)throw std::runtime_error("next job II changed");d.start=1;cycle();d.start=0;++starts;while(d.busy&10)cycle();}
 unsigned ac=0,mc=0,tasks=0;for(bool b:addresses)ac+=b;for(bool b:masks)mc+=b;for(auto const&x:std::filesystem::directory_iterator("/proc/self/task")){(void)x;++tasks;}
 if(tasks!=1||mc!=16||(!cancel_only&&ac!=128)||!aborts||!resets||!late||!held||!blocked||!cv[0]||!cv[1]||!cv[2]||!cv[3]||(cancel_only&&((abort_stages&63)!=63||(reset_stages&63)!=63)))throw std::runtime_error("lighting coverage/thread guard");
 std::printf("PASS SYS=%llu starts=%llu fast=%llu slow=%llu cv=%llu/%llu/%llu/%llu RFwrites=%llu/%llu aborts=%llu resets=%llu lateDLY=%llu held=%llu blocked=%llu masks=%u SHINaddresses=%u abortStages=%x resetStages=%x nominal=%llu tasks=%u\n",
 (unsigned long long)clocks,(unsigned long long)starts,(unsigned long long)fast_count,(unsigned long long)slow_count,
 (unsigned long long)cv[0],(unsigned long long)cv[1],(unsigned long long)cv[2],(unsigned long long)cv[3],
 (unsigned long long)writes[0],(unsigned long long)writes[2],(unsigned long long)aborts,(unsigned long long)resets,
 (unsigned long long)late,(unsigned long long)held,(unsigned long long)blocked,mc,ac,abort_stages,reset_stages,(unsigned long long)nominal,tasks);
}
