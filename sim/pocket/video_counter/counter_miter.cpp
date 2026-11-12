// SPDX-License-Identifier: MIT
// Actual old/new module miter: public inputs only, all output pins every cycle.
#include "Vvideo_reset_miter.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <initializer_list>
struct Test {
 Vvideo_reset_miter d;uint64_t tickno=0,checks=0,reads=0,writes=0;uint32_t rng=0x49a81c27,read_addr=0;int phase,wp=0,rp=0,beat=-1,gap=0;int layout,rotation;
 Test(int l,int r,int p):phase(p),layout(l),rotation(r){d.layout_in=l;d.rotation=r;d.touch=1;d.cur_x=255;d.cur_y=191;}
 uint32_t random(){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
 void same(bool ok,const char*what){++checks;if(!ok){printf("FAIL public-pin-%s l=%d r=%d p=%d tick=%llu hc-input=%d vcount=%d reset=%d\n",what,layout,rotation,phase,(unsigned long long)tickno,int(d.line_start),int(d.vcount),int(d.reset));throw std::runtime_error(what);}}
 void tick(){
  d.clk=0;d.vid_t=((tickno+phase)/4)&1;d.eval();d.w_ack=d.r_ack=d.r_rvalid=0;
  if(d.reset){wp=rp=0;beat=-1;}
  else {
   if(d.w_req&&!wp)wp=1+(random()%23);
   if(wp&&!--wp){d.w_ack=1;++writes;}
   if(d.r_req&&!rp&&beat<0){rp=1+(random()%173);read_addr=d.r_addr;}
   if(rp&&!--rp){d.r_ack=1;beat=0;gap=1+(random()%13);++reads;}
   if(beat>=0&&!d.r_ack&&!--gap){d.r_rvalid=1;d.r_rdata=(read_addr+beat)*0x9e3779b9U+0x270a4411U;if(++beat==4)beat=-1;else gap=1+(random()%13);}
  }
  d.px_valid=(random()&3)==0;d.px_x=random();d.px_line=random()%192;d.px_eng=random()&1;d.px_rgb=random()&0x3ffff;d.swap=random()&1;d.pen=random()&1;
  d.eval();d.clk=1;d.eval();
  same(d.rgb==d.ref_rgb,"RGB");same(d.de==d.ref_de&&d.hs==d.ref_hs&&d.vs==d.ref_vs,"sync");same(d.layout==d.ref_layout&&d.frame_pulse==d.ref_frame_pulse&&d.underruns==d.ref_underruns,"status");same(d.w_req==d.ref_w_req&&d.w_addr==d.ref_w_addr&&d.w_data==d.ref_w_data,"write");same(d.r_req==d.ref_r_req&&d.r_addr==d.ref_r_addr,"read");++tickno;
 }
 void anchor(int vc,int length,int cut=-1,int width=1,bool changes=false){
  for(int t=0;t<length;++t){d.line_start=t==0;d.vcount=vc;d.reset=t>=cut&&t<cut+width&&cut>=0;
   // Unlatched rotation writes and queued layout selection are deliberately
   // exercised at output boundaries; comparison is not a new UI contract.
   if(changes&&(t==399||t==1423||t==1424||t==2047||t==8191)){d.rotation=(d.rotation+1)%3;d.layout_in=(d.layout_in+1)%3;}
   tick();
  }d.reset=0;d.line_start=0;
 }
 void run(){
  d.reset=1;for(int i=0;i<20;++i)tick();d.reset=0;
  anchor(0,7);anchor(2,20000);anchor(3,20000);anchor(194,20000);anchor(195,271000);anchor(511,20000);
  // Intervals straddle both new and old saturation limits and normal windows.
  int lengths[]={1,3,4,19,399,400,1023,1024,1263,1264,1399,1400,1423,1424,2046,2047,2048,4259,4260,8190,8191,8192,20000};
  for(int n:lengths){anchor(0,3);anchor(2,4);anchor(3,n,-1,1,true);anchor(194,n);anchor(195,n);}
  int cuts[]={0,1,3,399,400,600,1263,1264,1399,1423,1424,2046,2047,2048,8190,8191,12000};
  for(int cut:cuts)for(int width:{1,2,3,9}){anchor(0,5);anchor(2,4);anchor(3,cut+32,cut,width,true);anchor(0,3);anchor(2,1600);anchor(195,cut+1600,cut,width,true);}
  // Recovery under ordinary raster after all missing-anchor/reset histories.
  d.layout_in=layout;d.rotation=rotation;for(int vc=0;vc<263;++vc)anchor(vc,4260);
  printf("PASS long-lines l=%d r=%d p=%d cycles=%llu checks=%llu reads=%llu writes=%llu\n",layout,rotation,phase,(unsigned long long)tickno,(unsigned long long)checks,(unsigned long long)reads,(unsigned long long)writes);
 }
};
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);int pass=0,fail=0;for(int l=0;l<3;++l)for(int r=0;r<3;++r)for(int p=0;p<4;++p){try{Test(l,r,p).run();++pass;}catch(const std::exception&){++fail;}}printf("RESULT long-lines cases=36 passed=%d failed=%d\n",pass,fail);return fail?1:0;}
