// Passive input-only diagnostic. No DUT API, VPI, return value or driver.
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "fields.h"
extern "C" void pair_capture_emit(unsigned,unsigned,unsigned long long,unsigned,unsigned,unsigned,unsigned,unsigned long long);
namespace {
uint32_t bits(const uint32_t*p,unsigned o,unsigned n){uint64_t q=p[o/32];if(o%32&&n+o%32>32)q|=uint64_t(p[o/32+1])<<32;return uint32_t(q>>(o%32))&(n==32?0xffffffffu:((1u<<n)-1));}
#define V(n) bits(v,O_##n,W_##n)
struct Packet{std::vector<uint32_t>w;unsigned n=0;void add(uint64_t x,unsigned k){for(unsigned i=0;i<k;i++){if(n/32>=w.size())w.push_back(0);w[n/32]|=uint32_t((x>>i)&1)<<(n%32);n++;}}};
void emit(unsigned k,unsigned sub,uint64_t t,const uint32_t*p,unsigned o,unsigned n){
 for(unsigned c=0;c<(n+191)/192;c++){
  uint32_t w[6]{};for(unsigned j=0;j<6;j++){unsigned b=c*192+j*32;if(b<n)w[j]=bits(p,o+b,std::min(32u,n-b));}
#ifdef PUB70_MUTATE_EVENT
  static bool changed=false;if(k==62&&c==0&&!changed&&(w[0]&1)){w[0]^=2;changed=true;} // actual emitted RBuf address bit
#endif
  pair_capture_emit(k+5,(sub<<16)|c,t,w[0],w[1],w[2],w[3],uint64_t(w[4])|(uint64_t(w[5])<<32));
 }
}
void send(unsigned k,unsigned sub,uint64_t t,const Packet&p){emit(k,sub,t,p.w.data(),0,p.n);}
int window(uint64_t t){
#ifdef PUB70_UNIT
 return 0;
#else
 if(t>=357000000000ULL&&t<=361000000000ULL)return 0;
 if(t>=625000000000ULL&&t<=628000000000ULL)return 1;
 if(t>=642000000000ULL&&t<=645000000000ULL)return 2;
 return -1;
#endif
}
struct Cell{bool valid=false;std::array<uint32_t,3>d{};uint32_t source=0;uint64_t t=0;};
std::array<Cell,1024>top{},stage{};std::array<Cell,512>rb{};
struct Read{bool issued=false;unsigned addr=0;Cell c;uint64_t t=0;};Read tr,sr,rr;
std::array<uint32_t,(PUB70_BITS+31)/32>old{};int lastwin=-1;bool oldvalid=false;
void predecessor(unsigned mem,unsigned addr,const Cell&c,uint64_t t){Packet p;p.add(addr,10);p.add(c.valid,1);p.add(c.d[0],32);p.add(c.d[1],32);p.add(c.d[2],7);p.add(c.source,32);p.add(c.t,64);send(69,mem,t,p);}
void readproof(unsigned mem,const Read&r,uint32_t actual,uint64_t t){if(!r.issued)return;Packet p;p.add(r.addr,10);p.add(r.c.valid,1);p.add(r.c.d[0]&0x7fffff,23);p.add(actual,23);p.add(r.t,64);p.add(r.c.t,64);send(69,10+mem,t,p);
 if(r.c.valid&&(r.c.d[0]&0x7fffff)!=actual){std::fprintf(stderr,"PUB70_RAM_PROVENANCE_MISMATCH mem=%u addr=%u at=%llu\n",mem,r.addr,(unsigned long long)t);std::abort();}}
struct Writer{
 bool active=false,first=false;uint64_t begin=0,firstsum=0,lastsum=0,firstmax=0,lastmax=0,blocks=0,firstcount=0,wait=0,streak=0,maxstreak=0;
 void tick(bool req,bool ack,unsigned word,uint64_t t){
  if(req&&!active){active=true;first=false;begin=t;}
  if(req&&!ack){wait++;streak++;maxstreak=std::max(streak,maxstreak);}else streak=0;
  if(req&&ack&&active){if(!first){first=true;firstsum+=t-begin;firstmax=std::max(firstmax,t-begin);firstcount++;}if(word==7){blocks++;lastsum+=t-begin;lastmax=std::max(lastmax,t-begin);active=false;}}
 }
 void summary(unsigned kind,uint64_t t){uint64_t a[]={wait,maxstreak,firstsum,firstmax,firstcount,lastsum,lastmax,blocks,uint64_t(active),active?t-begin:0};for(unsigned i=0;i<10;i++){Packet p;p.add(i,32);p.add(a[i],64);send(kind,0,t,p);}}
}jw,rw;
uint64_t jc[12]{},thresholds[4][3]{},reasons[32]{},ringwait[8]{};
bool active=false;unsigned line=0;uint64_t linebegin=0,cycles=0;uint64_t store[16]{},phase[8]{},front[16]{},mask[1024]{},ca[8]{},flags[20]{};
uint64_t blocked_front[16]{},blocked_phase[8]{},blocked_mask[1024]{},span[8]{};
void countemit(unsigned kind,unsigned sub,uint64_t t,unsigned i,uint64_t value){Packet p;p.add(line,8);p.add(i,16);p.add(value,64);send(kind,sub,t,p);}
void lineend(uint64_t t){
 for(unsigned i=0;i<16;i++){countemit(75,0,t,i,store[i]);countemit(76,0,t,i,front[i]);}
 for(unsigned i=0;i<8;i++){countemit(76,1,t,i,phase[i]);countemit(78,0,t,i,ca[i]);}
 for(unsigned i=0;i<1024;i++)if(mask[i])countemit(76,2,t,i,mask[i]);
 for(unsigned i=0;i<20;i++)countemit(77,0,t,i,flags[i]);
 for(unsigned i=0;i<16;i++)countemit(76,3,t,i,blocked_front[i]);
 for(unsigned i=0;i<8;i++){countemit(76,4,t,i,blocked_phase[i]);countemit(76,6,t,i,span[i]);}
 for(unsigned i=0;i<1024;i++)if(blocked_mask[i])countemit(76,5,t,i,blocked_mask[i]);
 Packet p;p.add(line,8);p.add(linebegin,64);p.add(t,64);p.add(cycles,32);send(79,0,t,p);active=false;
}
}
extern "C" void publication70_tick(unsigned long long t,const uint32_t*v){
 int win=window(t);bool detail=win>=0;
 if(win!=lastwin){Packet p;p.add(win<0?255:win,8);p.add(V(video_frame),16);p.add(V(shot),16);p.add(V(frame_go),1);send(59,win<0?1:0,t,p);oldvalid=false;
  if(detail){for(unsigned i=0;i<1024;i++){predecessor(0,i,top[i],t);predecessor(1,i,stage[i],t);}for(unsigned i=0;i<512;i++)predecessor(2,i,rb[i],t);}}
 if(detail){
  for(const auto&g:pub70_groups){if(g.kind>=80)continue;bool changed=!oldvalid||(g.kind==62&&V(rb_we))||(g.kind==63&&V(st_we))||(g.kind==64&&V(top_we));for(unsigned b=0;b<g.n;b+=32)if(bits(v,g.o+b,std::min(32u,g.n-b))!=bits(old.data(),g.o+b,std::min(32u,g.n-b)))changed=true;
   if(changed)emit(g.kind,0,t,v,g.o,g.n);}
  readproof(0,tr,V(ll_q),t);readproof(1,sr,V(st_q),t);readproof(2,rr,V(rb_q),t);
 }
 tr={bool(V(ll_ack)),unsigned(V(ll_slot)*256+V(ll_x)),top[V(ll_slot)*256+V(ll_x)],t};
 sr={true,unsigned(V(st_ra)),stage[V(st_ra)],t};rr={true,unsigned(V(rb_ra)),rb[V(rb_ra)],t};
 uint32_t source=(V(video_frame)<<16)|(V(front_y)<<8)|V(top_flags);
 if(V(top_we))top[V(top_wa)]={true,{V(top_lo),V(top_mid),V(top_hi)},source,t};
 if(V(st_we))stage[V(st_wa)]={true,{V(st_wd),0,0},(V(video_frame)<<16)|(V(px_y)<<8),t};
 if(V(rb_we))rb[V(rb_wa)]={true,{V(rb_wd),0,0},(V(video_frame)<<16)|(V(px_y)<<8)|V(rb_source),t};
 if(detail){for(unsigned i=0;i<old.size();i++)old[i]=v[i];oldvalid=true;}lastwin=win;
 if(V(rst))return;
 bool opp=V(j_valid)&&V(j_credit)&&!V(j_copy)&&!V(j_sealed)&&!V(j_other);bool commit=V(j_valid)&&V(j_ready);
 jc[0]++;jc[1]+=opp;jc[2]+=V(j_valid);jc[3]+=V(j_ready);jc[4]+=commit;jc[5]+=V(j_wv);jc[6]+=V(j_valid)&&V(j_credit)&&!V(j_ready);
 jc[7]+=!V(j_tx)&&V(j_copied_pending)&&V(j_unsafe)>=7;jc[8]+=!V(j_drained);jc[9]+=V(j_drained)&&!V(j_req)&&V(j_quiet)<3;jc[10]=std::max(jc[10],uint64_t(V(j_used)));jc[11]=std::max(jc[11],uint64_t(V(j_unsafe)));
 unsigned reason=(!V(j_credit))|((V(j_used)>=1024)<<1)|(V(j_copy)<<2)|(V(j_sealed)<<3)|(V(j_other)<<4);if(V(j_valid))reasons[reason]++;
 for(unsigned i=0;i<4;i++)if(V(j_used)>=(i+1)*256){thresholds[i][0]++;thresholds[i][1]+=opp;thresholds[i][2]+=commit;}
 jw.tick(V(j_req),V(j_ack),V(j_word),t);rw.tick(V(q_req),V(q_ack),V(q_addr)&7,t);
 ringwait[0]+=V(w_resume);ringwait[1]+=V(w_resume)&&V(urgent_read);ringwait[2]+=V(w_resume)&&V(est)==6;ringwait[3]+=V(w_resume)&&V(est)==5;ringwait[4]+=V(fp_hold);ringwait[5]+=V(est)==6&&V(ll_rd)&&!V(ll_ack);ringwait[6]+=V(q_req)&&!V(q_ack);ringwait[7]+=V(w_resume)&&V(write_turn)&&V(est)==0;
 bool inservice=t>=324400000000ULL&&t<=325850000000ULL;
#ifdef PUB70_UNIT
 inservice=true;
#endif
 if(V(ps_req)&&inservice&&V(draw_gen)==23846&&V(ps_y)>=125&&V(ps_y)<=132){active=true;line=V(ps_y);linebegin=t;cycles=0;std::fill(std::begin(store),std::end(store),0);std::fill(std::begin(phase),std::end(phase),0);std::fill(std::begin(front),std::end(front),0);std::fill(std::begin(mask),std::end(mask),0);std::fill(std::begin(ca),std::end(ca),0);std::fill(std::begin(flags),std::end(flags),0);std::fill(std::begin(blocked_front),std::end(blocked_front),0);std::fill(std::begin(blocked_phase),std::end(blocked_phase),0);std::fill(std::begin(blocked_mask),std::end(blocked_mask),0);std::fill(std::begin(span),std::end(span),0);}
 if(active){if(V(ps_v)&&V(ps_r)&&V(ps_t)==3)lineend(t);else{
  cycles++;store[V(f_st)]++;phase[V(r_phase)]++;front[V(fr_st)]++;mask[V(pipe_mask)]++;ca[V(ca_st)]++;span[V(span_st)]++;if(V(ps_v)&&!V(ps_r)){blocked_front[V(fr_st)]++;blocked_phase[V(r_phase)]++;blocked_mask[V(pipe_mask)]++;}
  bool f[]={bool(V(ps_v)&&!V(ps_r)),bool(V(f_st)==7&&!V(h_fhit)),bool(V(f_st)==9&&!V(v_fhit)),bool((V(f_st)==7||V(f_st)==9)&&!V(out_free)),bool(V(bk_full)),bool(V(bk_commit)),bool(V(fp_hold)),bool(V(fp_at5)&&V(fp_hold)),bool(V(clr_req)&&!V(clr_ack)),bool(V(ll_rd)&&!V(ll_ack)),bool(V(ll20)),bool(V(adv)),bool(V(h_used)==1),bool(V(v_used)==2),bool(V(f_re)),bool(!V(f_ready)),bool(!V(f_lgo)),bool(!V(f_through)&&V(f_ly)<=V(f_y)),bool(V(e_res)),bool(V(span_st))};
  for(unsigned i=0;i<20;i++)flags[i]+=f[i];
 }}
}
extern "C" void publication70_boundary(int frame,unsigned long long t){
 for(unsigned i=0;i<12;i++){Packet p;p.add(frame,16);p.add(i,16);p.add(jc[i],64);send(70,0,t,p);}
 for(unsigned i=0;i<4;i++)for(unsigned j=0;j<3;j++){Packet p;p.add((i+1)*256,16);p.add(j,16);p.add(thresholds[i][j],64);send(71,0,t,p);}
 for(unsigned i=0;i<32;i++){Packet p;p.add(i,16);p.add(reasons[i],64);send(72,0,t,p);}
 jw.summary(73,t);rw.summary(74,t);for(unsigned i=0;i<8;i++){Packet p;p.add(i,16);p.add(ringwait[i],64);send(74,1,t,p);}
}
