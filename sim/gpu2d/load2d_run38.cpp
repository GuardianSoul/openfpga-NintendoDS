// Exact stable register/memory workload from shipped sw/hwref/load2d/main.c.
// Unit state fixture only: no CPU/DMA timing or general OBJ budget is assumed.
#include "golden2d.h"
#include <cstring>
namespace g2d {
static void h16(u8* p, unsigned off, u16 v) { p[off]=v; p[off+1]=v>>8; }
static Segment fixture(int load, int sub) {
    Segment seg;
    seg.name="run38-load"+std::to_string(load)+"-b"+std::to_string(sub);
    seg.mem0=std::make_shared<Mem>();std::memset(seg.mem0.get(),0,sizeof(Mem));
    Mem& m=*seg.mem0;Sequencer seq;
    for(int e=0;e<2;e++) {
        u8* bg=e?m.bbg:m.abg;int layers=e?4:(load?4:1);
        for(int i=0;i<256;i++) h16(m.palette,e*1024+i*2,(i&31)|(((i>>3)&31)<<5)|(((i>>1)&31)<<10));
        for(int i=0;i<8192;i++) h16(bg,i*2,((i%255)+1)|(((i*7%255)+1)<<8));
        for(int b=0;b<4;b++) {
            seq.write16(e,8+b*2,(1<<7)|((28+b)<<8)|b);
            seq.write16(e,0x10+b*4,b*13);seq.write16(e,0x12+b*4,b*7);
            for(int i=0;i<1024;i++) h16(bg,(28+b)*0x800+i*2,(i+b*23)&255);
        }
        seq.write16(e,0x50,layers>1?0x0241:0);seq.write16(e,0x52,0x0808);
        seq.write32(e,0,0x10000|(((1u<<layers)-1)<<8)|(!e&&load==2?1<<12:0));
    }
    if(!sub)seq.write32(1,0,0x10080);
    for(int i=0;i<256;i++)h16(m.palette,0x200+i*2,0x001f|(i<<5));
    for(int i=0;i<8192;i++)h16(m.aobj,i*2,0x1111);
    for(int i=0;i<128;i++) {
        h16(m.oam,i*8,((i%6)*32)|0x0400);
        h16(m.oam,i*8+2,0xc000|((i*17)&255));
        h16(m.oam,i*8+4,0);h16(m.oam,i*8+6,0);
    }
    // Probe registers are stable before capture starts at the next VBlank.
    // Advance the qualified renderer's three-line enable pipeline first.
    for(u32 y=256;y<262;y++) { LineState warm{};seq.line(y,warm,{}); }
    seq.vblank_end();
    for(u32 y=0;y<192;y++) {
        Step step;step.st={};step.st.frame=0;
        step.st.capcnt=0x80330000;step.st.cap_enable=1;step.st.lcdc=8;
        seq.line(y,step.st,{});seg.steps.push_back(step);
    }
    return seg;
}
std::vector<Segment> builtin_scenes() {
    std::vector<Segment> out;
    for(int load=0;load<3;load++)for(int sub=0;sub<2;sub++)out.push_back(fixture(load,sub));
    return out;
}
}
