// SPDX-License-Identifier: MIT
// Public-pin SDRAM and independent previous-frame LAST-slot scaler model.
#include "Vvideo_reset_miter.h"
#include "verilated.h"
#include <array>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>
struct Config {
 int layout=0,rot=0;
 int g()const{return 0;}
 int height()const{return layout==0?384+g():192;}
 int slot()const{return rot==1?(layout==0?2:4):rot==2?(layout==0?3:5):layout?1:0;}
};
struct Change {int frame,clock;Config config;};
struct Case {std::string name;Config initial;std::vector<Change> changes;int frames=3,phase=0,cursor=1,cx=255,cy=191,service=0;bool late=false;int reset_clock=-1;bool miter=false;};
struct Sim {
 Vvideo_reset_miter d;Case c;Config requested,active,next,staged;uint64_t cycle=0,checks=0,pixels=0,hash=1469598103934665603ULL;
 std::array<uint32_t,24576> ram{};std::array<bool,24576>written{};
 bool pin_de=false;int actual_lastslot=0;bool wp=false,rp=false,burst=false,last_toggle=false,prev_de=false,prev_hs=false,prev_vs=false;
 uint32_t wa=0,wd=0,ra=0,ba=0;int wdelay=0,rdelay=0,beat=0;
 int f=0,clock=0,frame=-1,row=0,col=0,slots=0,hscount=0,complete=0,lastslot=0,external_slot=0;
 uint64_t samples=0,hs_at=0,vs_at=0,writes=0,reads=0,row_start=0,max_row_service=0,frame_reads=0,frame_writes=0;
 static constexpr int LINE=4260,FRAME=263*LINE;static constexpr uint32_t BASE=0x380000;
 Sim(Case a):c(a),requested(a.initial){}
 void need(bool ok,const char*why,uint64_t got=0,uint64_t want=0){++checks;if(!ok){printf("FAIL %s %s cycle=%llu frame=%d row=%d x=%d got=%llu want=%llu\n",c.name.c_str(),why,(unsigned long long)cycle,frame,row,col,(unsigned long long)got,(unsigned long long)want);throw std::runtime_error(why);}}
 static int slotheight(int s){switch(s){case 0:case 2:case 3:return 384;case 1:case 4:case 5:return 192;case 6:return 392;case 7:return 432;default:return -1;}}
 int footer(const Config&a)const{return a.layout?195*LINE:195*LINE+1+(192+a.g())*(a.g()?1152:1400);}
 int route(int y)const{return(y/7)&1;}
 uint32_t engpixel(int y,int x,int eng)const{return((3*x+5*y+19*eng+7*f+1)&63)|(((5*x+7*y+23*eng+11*f+3)&63)<<6)|(((7*x+11*y+29*eng+13*f+5)&63)<<12);}
 uint32_t source(int y,int x,bool bottom)const{
  int eng=(route(y)?0:1)^int(bottom);auto v=engpixel(y,x,eng);
  int dx=(x-c.cx)&255,dy=(y-c.cy)&255;
  bool cross=(x==c.cx&&(dy<6||dy>250))||(y==c.cy&&(dx<6||dx>250));
  return c.cursor&&bottom&&cross?(c.cursor==2?0xfff:0x3f):v;
 }
 uint16_t packed(int y,int x,bool bottom)const{auto v=source(y,x,bottom);return((v&63)>>1)<<11|((v>>6)&63)<<5|((v>>12)&63)>>1;}
 uint32_t pixel(int rr,int x)const{
  if(rr==0||rr==active.height()+1)return 0;
  int yy=rr-1;bool stored=active.layout==0&&yy>=192+active.g();
  if(active.layout==0&&yy>=192&&yy<192+active.g())return 0;
  int y=stored?yy-192-active.g():yy;bool bottom=active.layout==2||(active.layout==0&&stored);
  auto v=source(y,x,bottom);int r=v&63,g=(v>>6)&63,b=(v>>12)&63;
  if(stored){r>>=1;b>>=1;return(((r<<3)|(r>>2))<<16)|(((g<<2)|(g>>4))<<8)|((b<<3)|(b>>2));}
  return(((r<<2)|(r>>4))<<16)|(((g<<2)|(g>>4))<<8)|((b<<2)|(b>>4));
 }
 void finish(){need(!prev_de,"frame-ended-in-DE");need(row==slotheight(external_slot)+2,"external-scaler-height",row,slotheight(external_slot)+2);need(row==active.height()+2,"DE-rows",row,active.height()+2);need(slots==row,"slots",slots,row);if(!active.layout)need(hscount==row,"HS-rows",hscount,row);need(d.underruns==0,"missing-row",d.underruns);++complete;}
 void observe(bool sample,uint32_t oldrgb,int oldflags){
  int flags=d.de|(d.hs<<1)|(d.vs<<2);if(!sample){need(d.rgb==oldrgb&&flags==oldflags,"output-phase");return;}++samples;
  if(d.vs){need(!prev_vs,"VS-width");if(frame>=0)finish();frame=f;row=col=slots=hscount=0;vs_at=samples;external_slot=lastslot;if(f>0)need(actual_lastslot==active.slot(),"previous-LAST-slot",actual_lastslot,active.slot());need(!d.hs,"HS-on-VS");}
  if(frame>=0){
   if(d.hs){need(!prev_hs,"HS-width");hs_at=samples;++hscount;if(row==0)need(samples-vs_at==4,"lead-HS",samples-vs_at,4);}
   if(d.de){if(!prev_de){need(d.underruns==0,"missing-row",d.underruns);col=0;int distance=row==0?96:!active.layout&&row>=193?(active.g()?4:60):100;need(samples-hs_at==uint64_t(distance),"HS-DE",samples-hs_at,distance);}need(col<256,"row-width-upper");auto want=pixel(row,col);need(d.rgb==want,"pixel",d.rgb,want);hash=(hash^d.rgb)*1099511628211ULL;++col;++pixels;}
   else if(prev_de){need(col==256,"row-width",col,256);int want=active.slot();need(d.rgb==uint32_t(want<<13),"last-slot-announcement",d.rgb,want<<13);lastslot=d.rgb>>13;++slots;++row;}
   else need(d.rgb==0,"RGB-outside-DE",d.rgb);
   need(d.layout==active.layout,"active-layout",d.layout,active.layout);
  }
  prev_de=d.de;prev_hs=d.hs;prev_vs=d.vs;
 }
 void memory(){
  d.w_ack=0;d.r_ack=0;d.r_rvalid=0;d.r_rdata=0;
  if(!wp&&d.w_req){wp=true;wa=d.w_addr;wd=d.w_data;wdelay=(writes*7+cycle)%4;}
  if(wp){need(d.w_req&&d.w_addr==wa&&d.w_data==wd,"write-held");if(wdelay--==0){need(active.layout==0,"write-single");need(wa>=BASE&&wa<BASE+24576,"write-address");unsigned a=wa-BASE,y=a/128,x=(a%128)*2;uint32_t want=packed(y,x,true)|(uint32_t(packed(y,x+1,true))<<16);need(wd==want,"write-data",wd,want);ram[a]=wd;written[a]=true;d.w_ack=1;wp=false;++writes;++frame_writes;}}
  if(!rp&&d.r_req){rp=true;ra=d.r_addr;rdelay=c.late?34:c.service?29:int((reads*3+cycle)%4);if((ra&127)==0)row_start=cycle;}
  if(rp){need(d.r_req&&d.r_addr==ra,"read-held");if(rdelay--==0){need(active.layout==0,"read-single");need(!burst,"overlap");need(ra>=BASE&&ra+3<BASE+24576&&!(ra&3),"read-address");need(ra==BASE+frame_reads*4,"read-row-sequence",ra,BASE+frame_reads*4);d.r_ack=1;rp=false;burst=true;ba=ra;beat=0;++reads;++frame_reads;}}
  if(burst&&!d.r_ack){unsigned a=ba-BASE+beat;need(written[a],"read-before-write");d.r_rvalid=1;d.r_rdata=ram[a];if(++beat==4){burst=false;if((ba&127)==124){auto duration=cycle-row_start+1;max_row_service=std::max(max_row_service,duration);need(duration<=1400,"row-service-1400",duration,1400);}}}
 }
 void tick(bool reset=false){d.clk=0;d.eval();auto old=d.rgb;int flags=d.de|(d.hs<<1)|(d.vs<<2);bool nv=((cycle+c.phase)/4)&1;bool sample=last_toggle;last_toggle=(nv!=bool(d.vid_t));d.vid_t=nv;if(reset){d.w_ack=d.r_ack=d.r_rvalid=0;}else memory();d.eval();d.clk=1;d.eval();
 if(c.miter) {
  need(d.rgb==d.ref_rgb && d.de==d.ref_de && d.hs==d.ref_hs && d.vs==d.ref_vs && d.layout==d.ref_layout,"reference-raster");
  need(d.w_req==d.ref_w_req && d.w_addr==d.ref_w_addr && d.w_data==d.ref_w_data && d.r_req==d.ref_r_req && d.r_addr==d.ref_r_addr,"reference-memory-all-pins");
  need(d.underruns==d.ref_underruns && d.frame_pulse==d.ref_frame_pulse,"reference-status");
 }
 // External slot state never stops observing because the DUT is reset.
 if(pin_de && !d.de){actual_lastslot=d.rgb>>13;need(d.rgb==uint32_t(active.slot()<<13),"reset-DE-fall-slot",d.rgb,uint32_t(active.slot()<<13));}
 pin_de=d.de;

 if(!reset)observe(sample,old,flags);++cycle;}
 void run(){
  d.reset=1;d.touch=c.cursor!=0;d.pen=c.cursor==2;d.cur_x=c.cx;d.cur_y=c.cy;for(int i=0;i<20;++i)tick(true);d.reset=0;
  for(f=0;f<c.frames;++f){active=requested;written.fill(false);frame_reads=frame_writes=0;
   bool interrupted=false;
   for(clock=0;clock<FRAME;++clock){int vc=clock/LINE,hc=clock%LINE;
    if(f==1&&clock==c.reset_clock){
     // PLL/global reset cancels backend work. Deliberately interrupt this raster;
     // the external scaler retains the last slot, while a new DS0 restarts output.
     wp=rp=burst=false;d.line_start=0;d.px_valid=0;d.reset=1;
     for(int z=0;z<8;++z)tick(true);d.reset=0;
     frame=-1;prev_de=prev_hs=prev_vs=false;interrupted=true;break;
    }
    for(auto&a:c.changes)if(a.frame==f&&a.clock==clock)requested=a.config;
    
    d.layout_in=requested.layout;d.rotation=requested.rot;
    d.line_start=hc==0;d.vcount=vc;d.swap=route(std::clamp(vc-1,0,191));if(hc>=528)d.swap=!d.swap;
    d.px_valid=vc>=1&&vc<=192&&hc>=16&&hc<1040&&!(hc&1);
    if(d.px_valid){int x=(hc-16)/4,eng=((hc-16)/2)&1;d.px_line=vc-1;d.px_x=x;d.px_eng=eng;d.px_rgb=engpixel(vc-1,x,eng);}
    // Finish the preceding frame before f/active change affects its oracle.
    tick();
   }
   if(interrupted)continue;
   finish();frame=-1;prev_de=prev_hs=prev_vs=false;
   need(frame_reads==uint64_t(active.layout?0:6144),"frame-read-count",frame_reads,active.layout?0:6144);
   need(frame_writes==uint64_t(active.layout?0:24576),"frame-write-count",frame_writes,active.layout?0:24576);
   need(!wp&&!rp&&!burst,"pending-end-frame");
  }
  printf("PASS %s frames=%d pixels=%llu reads=%llu writes=%llu max_row_service=%llu checks=%llu hash=%016llx cycles=%llu\n",c.name.c_str(),complete,(unsigned long long)pixels,(unsigned long long)reads,(unsigned long long)writes,(unsigned long long)max_row_service,(unsigned long long)checks,(unsigned long long)hash,(unsigned long long)cycle);
 }
};
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);std::string suite=argc>1?argv[1]:"reset";int cases=0,failed=0;
 auto one=[&](int layout,int rotation,int phase,int cut){
  Case c;c.name=suite+"-l"+std::to_string(layout)+"-r"+std::to_string(rotation)+"-p"+std::to_string(phase)+"-cut"+std::to_string(cut);c.initial={layout,rotation};c.phase=phase;c.reset_clock=cut;c.cursor=1+(layout+rotation+phase)%2;c.cx=phase%2?0:255;c.cy=phase%2?0:191;c.service=1;c.miter=suite=="steady";c.frames=cut<0?2:3;
  try{Sim(c).run();}catch(const std::exception&e){++failed;fprintf(stderr,"CASE_ERROR %s %s\n",c.name.c_str(),e.what());}++cases;
 };
 if(suite=="reset"||suite=="steady")for(int l=0;l<3;++l)for(int r=0;r<3;++r)for(int p=0;p<4;++p)one(l,r,p,suite=="steady"?-1:5*Sim::LINE+600);
 else if(suite=="boundaries")for(auto cfg:std::vector<Config>{{1,0},{0,1},{2,2}})for(int p=0;p<4;++p){
  int footer=cfg.layout?195*Sim::LINE:195*Sim::LINE+1+192*1400;
  for(int cut:std::vector<int>{0,2*Sim::LINE+399,2*Sim::LINE+600,2*Sim::LINE+1424,5*Sim::LINE+399,5*Sim::LINE+1424,194*Sim::LINE+200,footer+239,footer+600,footer+1424})one(cfg.layout,cfg.rot,p,cut);
  if(!cfg.layout)for(int cut:{195*Sim::LINE+239,195*Sim::LINE+600,195*Sim::LINE+1264})one(cfg.layout,cfg.rot,p,cut);
 }
 else return 2;
 printf("RESULT suite=%s cases=%d passed=%d failed=%d\n",suite.c_str(),cases,cases-failed,failed);return failed?1:0;
}
