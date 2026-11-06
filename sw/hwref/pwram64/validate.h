#pragma once
#include "protocol.h"
static inline uint32_t pw_expected_word(const PwResult* r,uint32_t i,int before,const uint16_t* next) {
 uint32_t x=pw_guard(i);
 if(r->nodes){if(i/8<r->nodes&&i%8==7)x=PW_BASE+next[i/8]*32+28;}
 else if(!before&&((r->fixed&&!i)||(!r->fixed&&((i%8)*2048+i/8)<r->stores)))x=PW_VALUE;
 return x;
}
static inline uint32_t pw_image_hash(const PwResult* r,int before,const uint16_t* next) {
 uint32_t h=2166136261u;
 for(uint32_t i=0;i<PW_WORDS;i++){uint32_t x=pw_expected_word(r,i,before,next);for(uint32_t j=0;j<4;j++)h=(h^((x>>(8*j))&255))*16777619u;}
 return h;
}
static inline uint32_t pw_ror(uint32_t x){return (x>>1)|(x<<31);}
static inline int pw_valid(const PwResult* r,uint32_t id) {
 if(id>=PW_CASES||r->magic!=PW_MAGIC||r->version!=1||r->case_id!=id||r->error||r->nodes!=(id<6?pw_counts[id]:0)||r->stores!=(id<6?0:pw_counts[id])||r->fixed!=(id==6)||r->seed!=(r->nodes?PW_SEED:0)||r->reserved||r->result_bytes!=sizeof *r||!r->restore_equal||r->backup_fnv!=r->restored_fnv||r->capture_timeout)return 0;
 if(r->stack_lo<0x037f8000||r->stack_hi>PW_BASE||r->stack_hi-r->stack_lo!=4096||r->entry_chain<0x037f8000||r->end_switch>PW_BASE||r->code_bytes!=r->end_switch-r->entry_chain||!r->code_bytes||r->code_bytes>PW_CODE)return 0;
 if(r->dma_src!=PW_BASE||r->dma_words!=PW_WORDS||r->dma_dst>>24!=2||r->dma_dst%4)return 0;
 for(uint32_t i=0;i<PW_CODE;i++)if(r->code_before[i]!=r->code_after[i]||(i>=r->code_bytes&&r->code_before[i]))return 0;
 const PwContext* c[2]={&r->before,&r->after};
 for(uint32_t i=0;i<2;i++)if((c[i]->cpsr&0xc0)!=0xc0||c[i]->sp<r->stack_lo||c[i]->sp>=r->stack_hi||c[i]->sp%8||c[i]->wramstat!=3||c[i]->tm0ctl!=0x80||c[i]->tm1ctl!=0x84||c[i]->soundcnt||c[i]->vcount>=263||(c[i]->ipcsync&15)!=1)return 0;
 static uint16_t order[2048],next[2048];
 if(r->nodes)pw_graph(r->nodes,order,next);
 uint32_t pre=pw_image_hash(r,1,next),post=pw_image_hash(r,0,next);
 if(r->guard_fnv!=pre)return 0;
 for(uint32_t i=0;i<PW_WORDS;i++)if(r->image[i]!=pw_expected_word(r,i,0,next))return 0;
 for(uint32_t rep=0;rep<PW_REPS;rep++)for(uint32_t phase=0;phase<3;phase++) {
  const PwSample* s=&r->samples[rep][phase];uint32_t n=r->nodes?(phase==0?1:r->nodes*(phase==2?4:1)):(phase==2?PW_WORDS:r->stores);
  if(s->operations!=n||s->ticks!=s->after-s->before||!s->ticks||s->ticks>PW_TIMEOUT||s->kind!=(r->nodes?phase:3+phase)||s->pre_fnv!=pre||s->post_fnv!=post||s->start_line>=263||s->end_line>=263)return 0;
  for(uint32_t i=0;i<5;i++)if(s->reserved[i])return 0;
  uint32_t expected=0,terminal=0;
  if(r->nodes){terminal=PW_BASE+28;for(uint32_t i=0;i<n;i++){terminal=PW_BASE+next[(terminal-PW_BASE-28)/32]*32+28;expected=terminal^pw_ror(expected);}}
  else if(!phase)expected=r->fixed?0:((n*32+(n/2048)*4)&65535);
  else if(phase==1)for(uint32_t i=0;i<n;i++)expected=PW_VALUE^pw_ror(expected);
  if(s->value!=expected||s->terminal!=terminal)return 0;
 }
 if(id==12){if(r->sound_src!=PW_BASE||r->sound_timer!=128||r->sound_ctrl!=0x86)return 0;for(uint32_t i=8;i<64;i++)if(r->capture[i]!=0x1234)return 0;}
 else {if(r->sound_src||r->sound_timer||r->sound_ctrl)return 0;for(uint32_t i=0;i<64;i++)if(r->capture[i])return 0;}
 return 1;
}
